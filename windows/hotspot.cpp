#include <winsock2.h>
#include <ws2tcpip.h>
#include <Windows.h>
#include <iphlpapi.h>
#include <shlobj.h>
#include <wincrypt.h>

#include "hotspot.h"
#include "hotspot_internal.h"

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

namespace detail {

namespace {
constexpr wchar_t kTunnelAdapterPrefix[] = L"GlitchVPN";
constexpr uint32_t kIfTypeWifi = 71;
constexpr uint32_t kIfTypeEthernet = 6;

std::wstring Lower(std::wstring s) {
  for (auto& c : s) c = static_cast<wchar_t>(towlower(c));
  return s;
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
  if (n > in.size() - pos) return false;
  s.assign(in, pos, n);
  pos += n;
  return true;
}
}  // namespace

bool IsTunnel(const AdapterInfo& adapter) {
  return adapter.name.rfind(kTunnelAdapterPrefix, 0) == 0;
}

bool IsPhysical(const AdapterInfo& adapter) {
  if (!adapter.up || IsTunnel(adapter)) return false;
  if (adapter.type != kIfTypeWifi && adapter.type != kIfTypeEthernet) {
    return false;
  }
  const std::wstring description = Lower(adapter.description);
  for (const wchar_t* soft : {L"virtual", L"hyper-v", L"wintun", L"tap-",
                              L"wireguard", L"vpn", L"loopback"}) {
    if (description.find(soft) != std::wstring::npos) return false;
  }
  return true;
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

std::string EncodeSavedState(const SavedState& state) {
  std::string out;
  AppendString(out, state.ssid);
  AppendString(out, state.passphrase);
  out.push_back(static_cast<char>(state.band));
  out.push_back(state.timeout_was_enabled ? 1 : 0);
  return out;
}

std::optional<SavedState> DecodeSavedState(const std::string& bytes) {
  SavedState state;
  size_t pos = 0;
  if (!ReadString(bytes, pos, state.ssid) ||
      !ReadString(bytes, pos, state.passphrase) || pos + 2 != bytes.size()) {
    return std::nullopt;
  }
  state.band = static_cast<int>(static_cast<signed char>(bytes[pos]));
  state.timeout_was_enabled = bytes[pos + 1] != 0;
  return state;
}

}  // namespace detail

namespace winnet = winrt::Windows::Networking::Connectivity;
namespace winop = winrt::Windows::Networking::NetworkOperators;
using detail::AdapterInfo;
using detail::SavedState;
using flutter::EncodableList;
using flutter::EncodableMap;
using flutter::EncodableValue;

namespace {

// Concurrent calls would race on the one tethering state Windows keeps.
std::mutex g_mutex;

struct MtaScope {
  HRESULT hr;
  MtaScope() { hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED); }
  ~MtaScope() {
    if (SUCCEEDED(hr)) CoUninitialize();
  }
};

// A failure. running, when given, is whether the hotspot runs afterwards.
EncodableValue Failure(const std::string& reason, const std::string& detail,
                       std::optional<bool> running = std::nullopt) {
  EncodableMap m;
  m[EncodableValue("reason")] = EncodableValue(reason);
  m[EncodableValue("detail")] = EncodableValue(detail);
  if (running) m[EncodableValue("running")] = EncodableValue(*running);
  return EncodableValue(m);
}

EncodableValue Ok(bool running, bool restarted = false) {
  EncodableMap m;
  m[EncodableValue("running")] = EncodableValue(running);
  m[EncodableValue("restarted")] = EncodableValue(restarted);
  return EncodableValue(m);
}

bool IsRunning(winop::NetworkOperatorTetheringManager& manager) {
  return manager.TetheringOperationalState() !=
         winop::TetheringOperationalState::Off;
}

// === Adapters ===

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
    AdapterInfo info;
    if (FAILED(CLSIDFromString(guid_text.c_str(), &info.id))) continue;
    info.name = a->FriendlyName ? a->FriendlyName : L"";
    info.description = a->Description ? a->Description : L"";
    info.type = a->IfType;
    info.up = a->OperStatus == IfOperStatusUp;
    info.metric = a->Ipv4Metric;
    out.push_back(std::move(info));
  }
  return out;
}

const AdapterInfo* FindAdapter(const std::vector<AdapterInfo>& adapters,
                               const winrt::guid& id) {
  const GUID wanted = id;
  for (const auto& a : adapters) {
    if (IsEqualGUID(a.id, wanted)) return &a;
  }
  return nullptr;
}

std::optional<winnet::ConnectionProfile> PickPhysicalProfile() {
  const auto adapters = ListAdapters();
  std::optional<winnet::ConnectionProfile> best;
  uint32_t best_metric = 0;
  for (const auto& profile : winnet::NetworkInformation::GetConnectionProfiles()) {
    try {
      const auto adapter = profile.NetworkAdapter();
      if (!adapter) continue;
      const auto* info = FindAdapter(adapters, adapter.NetworkAdapterId());
      if (!info || !detail::IsPhysical(*info)) continue;
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

// The reason code of a system that cannot host a hotspot.
std::string CapabilityCode(winop::TetheringCapability c) {
  if (c == winop::TetheringCapability::DisabledByHardwareLimitation) {
    return "noAdapter";
  }
  return "cannotHost";
}

EncodableValue OperationFailure(winop::TetheringOperationStatus status,
                                const winrt::hstring& extra, bool running) {
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
  return Failure(reason, detail, running);
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

// The folder is made only when create is set, for a write.
std::wstring SavedStatePath(bool create) {
  PWSTR folder = nullptr;
  std::wstring path;
  if (SUCCEEDED(SHGetKnownFolderPath(FOLDERID_LocalAppData, 0, nullptr, &folder))) {
    path = folder;
    CoTaskMemFree(folder);
    path += L"\\glitch_vpn_core";
    if (create) CreateDirectoryW(path.c_str(), nullptr);
    path += L"\\hotspot-saved.bin";
  }
  return path;
}

bool WriteSavedState(const SavedState& state) {
  const std::wstring path = SavedStatePath(true);
  if (path.empty()) return false;
  std::string plain = detail::EncodeSavedState(state);
  DATA_BLOB in{static_cast<DWORD>(plain.size()),
               reinterpret_cast<BYTE*>(plain.data())};
  DATA_BLOB out{};
  if (!CryptProtectData(&in, L"hotspot", nullptr, nullptr, nullptr,
                        CRYPTPROTECT_UI_FORBIDDEN, &out)) {
    SecureZeroMemory(plain.data(), plain.size());
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
  const std::wstring path = SavedStatePath(false);
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
  auto state = detail::DecodeSavedState(plain);
  SecureZeroMemory(plain.data(), plain.size());
  return state;
}

void DeleteSavedState() {
  const std::wstring path = SavedStatePath(false);
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

bool SameConfiguration(
    const winop::NetworkOperatorTetheringAccessPointConfiguration& config,
    const std::string& ssid, const std::string& passphrase,
    winop::TetheringWiFiBand band) {
  return winrt::to_string(config.Ssid()) == ssid &&
         winrt::to_string(config.Passphrase()) == passphrase &&
         config.Band() == band;
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
      out[EncodableValue("reason")] = EncodableValue(CapabilityCode(capability));
      return EncodableValue(out);
    }
    auto manager =
        winop::NetworkOperatorTetheringManager::CreateFromConnectionProfile(
            *profile);
    out[EncodableValue("supported")] = EncodableValue(true);
    out[EncodableValue("bands")] = EncodableValue(
        SupportedBands(manager.GetCurrentAccessPointConfiguration()));
  } catch (const winrt::hresult_error&) {
    out[EncodableValue("supported")] = EncodableValue(false);
    out[EncodableValue("reason")] = EncodableValue("unknown");
  }
  return EncodableValue(out);
}

EncodableValue Start(const std::string& ssid, const std::string& passphrase,
                     const std::string& band_name) {
  if (!detail::IsValidSsid(ssid) || !detail::IsValidPassphrase(passphrase)) {
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
      return Failure("unsupported", CapabilityCode(capability));
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
    const bool was_running =
        manager.TetheringOperationalState() == winop::TetheringOperationalState::On;
    if (was_running && SameConfiguration(config, ssid, passphrase, *band)) {
      if (winop::NetworkOperatorTetheringManager::IsNoConnectionsTimeoutEnabled()) {
        winop::NetworkOperatorTetheringManager::DisableNoConnectionsTimeoutAsync()
            .get();
      }
      return Ok(true);
    }
    if (was_running) {
      const auto stopped = manager.StopTetheringAsync().get();
      if (stopped.Status() != winop::TetheringOperationStatus::Success) {
        return OperationFailure(stopped.Status(), stopped.AdditionalErrorMessage(),
                                IsRunning(manager));
      }
    }

    config.Ssid(winrt::to_hstring(ssid));
    config.Passphrase(winrt::to_hstring(passphrase));
    config.Band(*band);
    try {
      manager.ConfigureAccessPointAsync(config).get();
    } catch (const winrt::hresult_error& e) {
      RestoreUserState(manager);
      return Failure("configureFailed", winrt::to_string(e.message()),
                     IsRunning(manager));
    }
    if (winop::NetworkOperatorTetheringManager::IsNoConnectionsTimeoutEnabled()) {
      winop::NetworkOperatorTetheringManager::DisableNoConnectionsTimeoutAsync()
          .get();
    }
    const auto result = manager.StartTetheringAsync().get();
    if (result.Status() != winop::TetheringOperationStatus::Success) {
      RestoreUserState(manager);
      return OperationFailure(result.Status(), result.AdditionalErrorMessage(),
                              IsRunning(manager));
    }
    return Ok(true, was_running);
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
      // Nothing can be read or stopped, so nothing is known about the
      // hotspot, and the saved settings wait for a connection.
      return Failure("noConnection", "no connection gives a tethering manager");
    }
    WaitOutTransition(*manager);
    if (manager->TetheringOperationalState() !=
        winop::TetheringOperationalState::Off) {
      const auto result = manager->StopTetheringAsync().get();
      if (result.Status() != winop::TetheringOperationStatus::Success) {
        return OperationFailure(result.Status(), result.AdditionalErrorMessage(),
                                IsRunning(*manager));
      }
    }
    if (!RestoreUserState(*manager)) {
      return Failure("configureFailed",
                     "the previous hotspot settings could not be restored",
                     false);
    }
    return Ok(false);
  } catch (const winrt::hresult_error& e) {
    return Failure("stopFailed", winrt::to_string(e.message()));
  }
}

EncodableValue Status() {
  std::lock_guard<std::mutex> lock(g_mutex);
  MtaScope com;
  EncodableMap out;
  out[EncodableValue("state")] = EncodableValue("unknown");
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
      case winop::TetheringOperationalState::Off:
        out[EncodableValue("state")] = EncodableValue("off");
        break;
      default:
        break;
    }
    out[EncodableValue("ssid")] = EncodableValue(
        winrt::to_string(manager->GetCurrentAccessPointConfiguration().Ssid()));
  } catch (const winrt::hresult_error&) {
    out[EncodableValue("state")] = EncodableValue("unknown");
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
  } catch (const winrt::hresult_error& e) {
    // A read error is not an empty list: the caller keeps what it had.
    return Failure("unknown", winrt::to_string(e.message()));
  }
  EncodableMap out;
  out[EncodableValue("clients")] = EncodableValue(list);
  return EncodableValue(out);
}

}  // namespace glitch_vpn_core::hotspot
