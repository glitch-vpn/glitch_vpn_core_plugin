#include "hotspot.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <Windows.h>
#include <iphlpapi.h>
#include <shlobj.h>
#include <wincrypt.h>

#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.NetworkOperators.h>
#include <winrt/Windows.Networking.h>
#include <winrt/base.h>

#include <algorithm>
#include <cwctype>
#include <fstream>
#include <mutex>
#include <optional>
#include <string>
#include <vector>

namespace glitch_vpn_core::hotspot {

namespace winnet = winrt::Windows::Networking::Connectivity;
namespace winop = winrt::Windows::Networking::NetworkOperators;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// The tunnel's Wintun adapter; the name may carry a numeric suffix.
constexpr wchar_t kTunnelAdapterPrefix[] = L"GlitchVPN";

// Concurrent calls would race on the one tethering state Windows keeps.
std::mutex g_mutex;

struct MtaScope {
  HRESULT hr;
  MtaScope() { hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED); }
  ~MtaScope() {
    if (SUCCEEDED(hr)) CoUninitialize();
  }
};

EncodableValue Failure(const std::string& reason, const std::string& detail) {
  EncodableMap m;
  m[EncodableValue("reason")] = EncodableValue(reason);
  m[EncodableValue("detail")] = EncodableValue(detail);
  return EncodableValue(m);
}

EncodableValue Ok() {
  EncodableMap m;
  m[EncodableValue("ok")] = EncodableValue(true);
  return EncodableValue(m);
}

// === Adapters ===

struct AdapterInfo {
  winrt::guid id;
  std::wstring name;
  std::wstring description;
  DWORD type = 0;
  bool up = false;
  ULONG metric = 0;
};

std::vector<AdapterInfo> ListAdapters() {
  ULONG size = 32 * 1024;
  std::vector<BYTE> buffer(size);
  const ULONG flags = GAA_FLAG_SKIP_UNICAST | GAA_FLAG_SKIP_ANYCAST |
                      GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
  auto* addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
  ULONG rc = GetAdaptersAddresses(AF_UNSPEC, flags, nullptr, addresses, &size);
  if (rc == ERROR_BUFFER_OVERFLOW) {
    buffer.resize(size);
    addresses = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data());
    rc = GetAdaptersAddresses(AF_UNSPEC, flags, nullptr, addresses, &size);
  }
  std::vector<AdapterInfo> out;
  if (rc != NO_ERROR) return out;
  for (auto* a = addresses; a != nullptr; a = a->Next) {
    const int wide_length =
        MultiByteToWideChar(CP_ACP, 0, a->AdapterName, -1, nullptr, 0);
    if (wide_length <= 0) continue;
    std::wstring guid_text(static_cast<size_t>(wide_length), L'\0');
    MultiByteToWideChar(CP_ACP, 0, a->AdapterName, -1, guid_text.data(),
                        wide_length);
    GUID guid;
    if (FAILED(CLSIDFromString(guid_text.c_str(), &guid))) continue;
    AdapterInfo info;
    info.id = winrt::guid(guid);
    info.name = a->FriendlyName ? a->FriendlyName : L"";
    info.description = a->Description ? a->Description : L"";
    info.type = a->IfType;
    info.up = a->OperStatus == IfOperStatusUp;
    info.metric = a->Ipv4Metric;
    out.push_back(std::move(info));
  }
  return out;
}

std::wstring Lower(std::wstring s) {
  for (auto& c : s) c = static_cast<wchar_t>(towlower(c));
  return s;
}

bool IsTunnel(const AdapterInfo& a) {
  return a.name.rfind(kTunnelAdapterPrefix, 0) == 0;
}

// A physical Wi-Fi or Ethernet adapter that is up. Software adapters (the
// tunnel, Hyper-V and WSL switches, VM and VPN adapters, the hotspot's own
// Wi-Fi Direct adapter) are not.
bool IsPhysical(const AdapterInfo& a) {
  if (!a.up || IsTunnel(a)) return false;
  if (a.type != IF_TYPE_IEEE80211 && a.type != IF_TYPE_ETHERNET_CSMACD) {
    return false;
  }
  const std::wstring description = Lower(a.description);
  for (const wchar_t* soft : {L"virtual", L"hyper-v", L"wintun", L"tap-",
                              L"wireguard", L"vpn", L"loopback"}) {
    if (description.find(soft) != std::wstring::npos) return false;
  }
  return true;
}

const AdapterInfo* FindAdapter(const std::vector<AdapterInfo>& adapters,
                               const winrt::guid& id) {
  for (const auto& a : adapters) {
    if (a.id == id) return &a;
  }
  return nullptr;
}

std::optional<winnet::ConnectionProfile> PickPhysicalProfile() {
  const auto adapters = ListAdapters();
  std::optional<winnet::ConnectionProfile> best;
  ULONG best_metric = 0;
  for (const auto& profile : winnet::NetworkInformation::GetConnectionProfiles()) {
    try {
      const auto adapter = profile.NetworkAdapter();
      if (!adapter) continue;
      const auto* info = FindAdapter(adapters, adapter.NetworkAdapterId());
      if (!info || !IsPhysical(*info)) continue;
      if (profile.GetNetworkConnectivityLevel() !=
          winnet::NetworkConnectivityLevel::InternetAccess) {
        continue;
      }
      if (!best || info->metric < best_metric) {
        best = profile;
        best_metric = info->metric;
      }
    } catch (const winrt::hresult_error&) {
      // A profile without an adapter is skipped.
    }
  }
  return best;
}

std::optional<winnet::ConnectionProfile> PickTunnelProfile() {
  const auto adapters = ListAdapters();
  for (const auto& profile : winnet::NetworkInformation::GetConnectionProfiles()) {
    try {
      const auto adapter = profile.NetworkAdapter();
      if (!adapter) continue;
      const auto* info = FindAdapter(adapters, adapter.NetworkAdapterId());
      if (info && info->up && IsTunnel(*info)) return profile;
    } catch (const winrt::hresult_error&) {
    }
  }
  return std::nullopt;
}

// Any manager reads and stops the one hotspot Windows has: the physical
// profile's if there is one, else any profile that yields a manager.
std::optional<winop::NetworkOperatorTetheringManager> AnyManager() {
  if (auto profile = PickPhysicalProfile()) {
    try {
      return winop::NetworkOperatorTetheringManager::
          CreateFromConnectionProfile(*profile);
    } catch (const winrt::hresult_error&) {
    }
  }
  for (const auto& profile : winnet::NetworkInformation::GetConnectionProfiles()) {
    try {
      return winop::NetworkOperatorTetheringManager::
          CreateFromConnectionProfile(profile);
    } catch (const winrt::hresult_error&) {
    }
  }
  return std::nullopt;
}

// === Messages ===

std::string CapabilityDetail(winop::TetheringCapability c) {
  using winop::TetheringCapability;
  switch (c) {
    case TetheringCapability::DisabledByGroupPolicy:
      return "disabled by group policy";
    case TetheringCapability::DisabledByHardwareLimitation:
      return "no Wi-Fi adapter with access point support";
    case TetheringCapability::DisabledByOperator:
      return "disabled by the network operator";
    case TetheringCapability::DisabledBySku:
      return "not available in this edition of Windows";
    case TetheringCapability::DisabledByRequiredAppNotInstalled:
      return "a required system app is not installed";
    case TetheringCapability::DisabledDueToUnknownCause:
      return "disabled for an unknown reason";
    case TetheringCapability::DisabledBySystemCapability:
      return "disabled by the system";
    default:
      return "capability " + std::to_string(static_cast<int>(c));
  }
}

EncodableValue OperationFailure(winop::TetheringOperationStatus status,
                                const winrt::hstring& extra) {
  using winop::TetheringOperationStatus;
  std::string reason = "startFailed";
  std::string detail;
  switch (status) {
    case TetheringOperationStatus::WiFiDeviceOff:
      reason = "wifiOff";
      detail = "Wi-Fi is turned off";
      break;
    case TetheringOperationStatus::OperationInProgress:
      reason = "operationInProgress";
      detail = "another hotspot operation is in progress";
      break;
    case TetheringOperationStatus::MobileBroadbandDeviceOff:
      detail = "the mobile broadband device is turned off";
      break;
    case TetheringOperationStatus::BluetoothDeviceOff:
      detail = "Bluetooth is turned off";
      break;
    default:
      detail = "tethering status " + std::to_string(static_cast<int>(status));
      break;
  }
  if (!extra.empty()) detail += ": " + winrt::to_string(extra);
  return Failure(reason, detail);
}

// === Bands ===

std::optional<winop::TetheringWiFiBand> ParseBand(const std::string& band) {
  if (band == "auto") return winop::TetheringWiFiBand::Auto;
  if (band == "2.4") return winop::TetheringWiFiBand::TwoPointFourGigahertz;
  if (band == "5") return winop::TetheringWiFiBand::FiveGigahertz;
  return std::nullopt;
}

EncodableList SupportedBands(
    const winop::NetworkOperatorTetheringAccessPointConfiguration& config) {
  EncodableList bands;
  bands.push_back(EncodableValue("auto"));
  try {
    if (config.IsBandSupported(winop::TetheringWiFiBand::TwoPointFourGigahertz)) {
      bands.push_back(EncodableValue("2.4"));
    }
    if (config.IsBandSupported(winop::TetheringWiFiBand::FiveGigahertz)) {
      bands.push_back(EncodableValue("5"));
    }
  } catch (const winrt::hresult_error&) {
  }
  return bands;
}

// === The user's own configuration, kept across processes ===
//
// Windows 23H2 has one Mobile hotspot configuration and no per-session one, so
// ours overwrites it. The user's is saved before the first overwrite and put
// back on stop. The hotspot outlives the process that started it, so the copy
// lives in a file, protected with DPAPI for the current user.

struct SavedState {
  std::string ssid;
  std::string passphrase;
  int band = 0;
  bool timeout_was_enabled = false;
};

std::wstring SavedStatePath() {
  PWSTR folder = nullptr;
  std::wstring path;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder))) {
    path = folder;
    CoTaskMemFree(folder);
    path += L"\\glitch_vpn_core";
    CreateDirectoryW(path.c_str(), nullptr);
    path += L"\\hotspot-saved.bin";
  }
  return path;
}

void AppendString(std::string& out, const std::string& s) {
  const uint32_t n = static_cast<uint32_t>(s.size());
  out.append(reinterpret_cast<const char*>(&n), sizeof(n));
  out += s;
}

bool ReadString(const std::string& in, size_t& pos, std::string& s) {
  uint32_t n = 0;
  if (pos + sizeof(n) > in.size()) return false;
  memcpy(&n, in.data() + pos, sizeof(n));
  pos += sizeof(n);
  if (pos + n > in.size()) return false;
  s.assign(in, pos, n);
  pos += n;
  return true;
}

bool WriteSavedState(const SavedState& state) {
  const std::wstring path = SavedStatePath();
  if (path.empty()) return false;
  std::string plain;
  AppendString(plain, state.ssid);
  AppendString(plain, state.passphrase);
  plain.push_back(static_cast<char>(state.band));
  plain.push_back(state.timeout_was_enabled ? 1 : 0);
  DATA_BLOB in{static_cast<DWORD>(plain.size()),
               reinterpret_cast<BYTE*>(plain.data())};
  DATA_BLOB out{};
  if (!CryptProtectData(&in, L"hotspot", nullptr, nullptr, nullptr,
                        CRYPTPROTECT_UI_FORBIDDEN, &out)) {
    return false;
  }
  std::ofstream file(path, std::ios::binary | std::ios::trunc);
  file.write(reinterpret_cast<const char*>(out.pbData),
             static_cast<std::streamsize>(out.cbData));
  const bool written = file.good();
  LocalFree(out.pbData);
  SecureZeroMemory(plain.data(), plain.size());
  return written;
}

std::optional<SavedState> ReadSavedState() {
  const std::wstring path = SavedStatePath();
  if (path.empty()) return std::nullopt;
  std::ifstream file(path, std::ios::binary);
  if (!file) return std::nullopt;
  std::string cipher((std::istreambuf_iterator<char>(file)),
                     std::istreambuf_iterator<char>());
  DATA_BLOB in{static_cast<DWORD>(cipher.size()),
               reinterpret_cast<BYTE*>(cipher.data())};
  DATA_BLOB out{};
  if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &out)) {
    return std::nullopt;
  }
  std::string plain(reinterpret_cast<const char*>(out.pbData), out.cbData);
  SecureZeroMemory(out.pbData, out.cbData);
  LocalFree(out.pbData);
  SavedState state;
  size_t pos = 0;
  if (!ReadString(plain, pos, state.ssid) ||
      !ReadString(plain, pos, state.passphrase) || pos + 2 > plain.size()) {
    return std::nullopt;
  }
  state.band = plain[pos];
  state.timeout_was_enabled = plain[pos + 1] != 0;
  SecureZeroMemory(plain.data(), plain.size());
  return state;
}

void DeleteSavedState() {
  const std::wstring path = SavedStatePath();
  if (!path.empty()) DeleteFileW(path.c_str());
}

// Puts the user's configuration and timeout back. False when it could not,
// and then the saved copy stays for the next attempt.
bool RestoreUserState(winop::NetworkOperatorTetheringManager& manager) {
  const auto saved = ReadSavedState();
  if (!saved) return true;
  try {
    auto config = manager.GetCurrentAccessPointConfiguration();
    config.Ssid(winrt::to_hstring(saved->ssid));
    config.Passphrase(winrt::to_hstring(saved->passphrase));
    config.Band(static_cast<winop::TetheringWiFiBand>(saved->band));
    manager.ConfigureAccessPointAsync(config).get();
    if (saved->timeout_was_enabled &&
        !winop::NetworkOperatorTetheringManager::IsNoConnectionsTimeoutEnabled()) {
      winop::NetworkOperatorTetheringManager::EnableNoConnectionsTimeoutAsync()
          .get();
    }
  } catch (const winrt::hresult_error&) {
    return false;
  }
  DeleteSavedState();
  return true;
}

void WaitOutTransition(winop::NetworkOperatorTetheringManager& manager) {
  for (int i = 0; i < 40; ++i) {
    if (manager.TetheringOperationalState() !=
        winop::TetheringOperationalState::InTransition) {
      return;
    }
    Sleep(250);
  }
}

bool IsValidSsid(const std::string& ssid) {
  return !ssid.empty() && ssid.size() <= 32;
}

bool IsValidPassphrase(const std::string& passphrase) {
  if (passphrase.size() < 8 || passphrase.size() > 63) return false;
  return std::all_of(passphrase.begin(), passphrase.end(), [](unsigned char c) {
    return c >= 0x20 && c <= 0x7e;
  });
}

bool SameConfiguration(
    const winop::NetworkOperatorTetheringAccessPointConfiguration& config,
    const std::string& ssid, const std::string& passphrase,
    winop::TetheringWiFiBand band) {
  return winrt::to_string(config.Ssid()) == ssid &&
         winrt::to_string(config.Passphrase()) == passphrase &&
         config.Band() == band;
}

EncodableValue StartOn(winop::NetworkOperatorTetheringManager& manager) {
  const auto result = manager.StartTetheringAsync().get();
  if (result.Status() != winop::TetheringOperationStatus::Success) {
    return OperationFailure(result.Status(), result.AdditionalErrorMessage());
  }
  return Ok();
}

}  // namespace

EncodableValue Capability() {
  MtaScope com;
  EncodableMap out;
  try {
    const auto profile = PickPhysicalProfile();
    if (!profile) {
      out[EncodableValue("supported")] = EncodableValue(false);
      out[EncodableValue("reason")] = EncodableValue("noConnection");
      return EncodableValue(out);
    }
    const auto capability = winop::NetworkOperatorTetheringManager::
        GetTetheringCapabilityFromConnectionProfile(*profile);
    if (capability != winop::TetheringCapability::Enabled) {
      out[EncodableValue("supported")] = EncodableValue(false);
      out[EncodableValue("reason")] = EncodableValue(CapabilityDetail(capability));
      return EncodableValue(out);
    }
    auto manager =
        winop::NetworkOperatorTetheringManager::CreateFromConnectionProfile(
            *profile);
    out[EncodableValue("supported")] = EncodableValue(true);
    out[EncodableValue("bands")] = EncodableValue(
        SupportedBands(manager.GetCurrentAccessPointConfiguration()));
  } catch (const winrt::hresult_error& e) {
    out[EncodableValue("supported")] = EncodableValue(false);
    out[EncodableValue("reason")] = EncodableValue(winrt::to_string(e.message()));
  }
  return EncodableValue(out);
}

EncodableValue Start(const std::string& ssid, const std::string& passphrase,
                     const std::string& band_name) {
  if (!IsValidSsid(ssid) || !IsValidPassphrase(passphrase)) {
    return Failure("invalidCredentials",
                   "the name is 1 to 32 bytes, the password 8 to 63 characters");
  }
  const auto band = ParseBand(band_name);
  if (!band) return Failure("bandUnsupported", "unknown band " + band_name);

  std::lock_guard<std::mutex> lock(g_mutex);
  MtaScope com;
  try {
    const auto profile = PickPhysicalProfile();
    if (!profile) {
      return Failure("noConnection",
                     "no Wi-Fi or Ethernet connection with internet access");
    }
    const auto capability = winop::NetworkOperatorTetheringManager::
        GetTetheringCapabilityFromConnectionProfile(*profile);
    if (capability != winop::TetheringCapability::Enabled) {
      return Failure("unsupported", CapabilityDetail(capability));
    }
    auto manager =
        winop::NetworkOperatorTetheringManager::CreateFromConnectionProfile(
            *profile);
    WaitOutTransition(manager);
    auto config = manager.GetCurrentAccessPointConfiguration();
    if (*band != winop::TetheringWiFiBand::Auto &&
        !config.IsBandSupported(*band)) {
      return Failure("bandUnsupported", "the adapter lacks " + band_name);
    }

    if (!ReadSavedState()) {
      SavedState saved;
      saved.ssid = winrt::to_string(config.Ssid());
      saved.passphrase = winrt::to_string(config.Passphrase());
      saved.band = static_cast<int>(config.Band());
      saved.timeout_was_enabled =
          winop::NetworkOperatorTetheringManager::IsNoConnectionsTimeoutEnabled();
      if (!WriteSavedState(saved)) {
        return Failure("configureFailed",
                       "the current hotspot settings could not be saved");
      }
    }

    // A hotspot of an earlier process with this configuration is kept; one
    // with another configuration is stopped before it is reconfigured.
    const bool running =
        manager.TetheringOperationalState() == winop::TetheringOperationalState::On;
    if (running && SameConfiguration(config, ssid, passphrase, *band)) {
      if (winop::NetworkOperatorTetheringManager::IsNoConnectionsTimeoutEnabled()) {
        winop::NetworkOperatorTetheringManager::DisableNoConnectionsTimeoutAsync()
            .get();
      }
      return Ok();
    }
    if (running) {
      const auto stopped = manager.StopTetheringAsync().get();
      if (stopped.Status() != winop::TetheringOperationStatus::Success) {
        return OperationFailure(stopped.Status(), stopped.AdditionalErrorMessage());
      }
    }

    config.Ssid(winrt::to_hstring(ssid));
    config.Passphrase(winrt::to_hstring(passphrase));
    config.Band(*band);
    try {
      manager.ConfigureAccessPointAsync(config).get();
    } catch (const winrt::hresult_error& e) {
      RestoreUserState(manager);
      return Failure("configureFailed", winrt::to_string(e.message()));
    }
    if (winop::NetworkOperatorTetheringManager::IsNoConnectionsTimeoutEnabled()) {
      winop::NetworkOperatorTetheringManager::DisableNoConnectionsTimeoutAsync()
          .get();
    }
    EncodableValue started = StartOn(manager);
    if (std::holds_alternative<EncodableMap>(started)) {
      const auto& map = std::get<EncodableMap>(started);
      if (map.find(EncodableValue("reason")) != map.end()) {
        RestoreUserState(manager);
      }
    }
    return started;
  } catch (const winrt::hresult_error& e) {
    return Failure("startFailed", winrt::to_string(e.message()));
  }
}

EncodableValue Stop() {
  std::lock_guard<std::mutex> lock(g_mutex);
  MtaScope com;
  try {
    auto manager = AnyManager();
    if (!manager) {
      // No connection gives a manager, so nothing can be running; the saved
      // settings wait for one.
      return Ok();
    }
    WaitOutTransition(*manager);
    if (manager->TetheringOperationalState() !=
        winop::TetheringOperationalState::Off) {
      const auto result = manager->StopTetheringAsync().get();
      if (result.Status() != winop::TetheringOperationStatus::Success) {
        return OperationFailure(result.Status(), result.AdditionalErrorMessage());
      }
    }
    if (!RestoreUserState(*manager)) {
      return Failure("configureFailed",
                     "the previous hotspot settings could not be restored");
    }
    return Ok();
  } catch (const winrt::hresult_error& e) {
    return Failure("startFailed", winrt::to_string(e.message()));
  }
}

EncodableValue Status() {
  std::lock_guard<std::mutex> lock(g_mutex);
  MtaScope com;
  EncodableMap out;
  out[EncodableValue("state")] = EncodableValue("off");
  out[EncodableValue("ours")] = EncodableValue(ReadSavedState().has_value());
  try {
    auto manager = AnyManager();
    if (!manager) return EncodableValue(out);
    switch (manager->TetheringOperationalState()) {
      case winop::TetheringOperationalState::On:
        out[EncodableValue("state")] = EncodableValue("on");
        break;
      case winop::TetheringOperationalState::InTransition:
        out[EncodableValue("state")] = EncodableValue("transition");
        break;
      default:
        break;
    }
    out[EncodableValue("ssid")] = EncodableValue(
        winrt::to_string(manager->GetCurrentAccessPointConfiguration().Ssid()));
  } catch (const winrt::hresult_error&) {
  }
  return EncodableValue(out);
}

EncodableValue Clients() {
  std::lock_guard<std::mutex> lock(g_mutex);
  MtaScope com;
  EncodableList list;
  try {
    auto manager = AnyManager();
    if (manager &&
        manager->TetheringOperationalState() == winop::TetheringOperationalState::On) {
      for (const auto& client : manager->GetTetheringClients()) {
        std::string name;
        std::string ipv4;
        for (const auto& host : client.HostNames()) {
          using winrt::Windows::Networking::HostNameType;
          if (host.Type() == HostNameType::Ipv4 && ipv4.empty()) {
            ipv4 = winrt::to_string(host.CanonicalName());
          } else if (host.Type() == HostNameType::DomainName && name.empty()) {
            name = winrt::to_string(host.DisplayName());
          }
        }
        EncodableMap m;
        m[EncodableValue("name")] = EncodableValue(name);
        m[EncodableValue("mac")] =
            EncodableValue(winrt::to_string(client.MacAddress()));
        m[EncodableValue("ipv4")] = EncodableValue(ipv4);
        list.push_back(EncodableValue(m));
      }
    }
  } catch (const winrt::hresult_error&) {
  }
  EncodableMap out;
  out[EncodableValue("clients")] = EncodableValue(list);
  return EncodableValue(out);
}

EncodableValue RestartOn(const std::string& connection) {
  if (connection != "tunnel" && connection != "wifi") {
    return Failure("startFailed", "unknown connection " + connection);
  }
  std::lock_guard<std::mutex> lock(g_mutex);
  MtaScope com;
  try {
    const auto profile =
        connection == "tunnel" ? PickTunnelProfile() : PickPhysicalProfile();
    if (!profile) {
      return Failure("noConnection", "no " + connection + " connection to share");
    }
    auto manager =
        winop::NetworkOperatorTetheringManager::CreateFromConnectionProfile(
            *profile);
    WaitOutTransition(manager);
    if (manager.TetheringOperationalState() ==
        winop::TetheringOperationalState::On) {
      const auto stopped = manager.StopTetheringAsync().get();
      if (stopped.Status() != winop::TetheringOperationStatus::Success) {
        return OperationFailure(stopped.Status(), stopped.AdditionalErrorMessage());
      }
    }
    return StartOn(manager);
  } catch (const winrt::hresult_error& e) {
    return Failure("startFailed", winrt::to_string(e.message()));
  }
}

}  // namespace glitch_vpn_core::hotspot
