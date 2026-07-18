#include "glitch_vpn_core_plugin.h"

#include <Windows.h>
#include <shellapi.h>
#include <shlobj.h>
#include <shobjidl.h>
#include <winsvc.h>
#include <VersionHelpers.h>
#include <objidl.h>
#include <gdiplus.h>

#include <iphlpapi.h>

#include <winrt/base.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Foundation.Collections.h>
#include <winrt/Windows.Networking.Connectivity.h>
#include <winrt/Windows.Networking.NetworkOperators.h>

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>
#include <flutter/standard_method_codec.h>

#include <algorithm>
#include <cwctype>
#include <functional>
#include <map>
#include <memory>
#include <mutex>
#include <optional>
#include <set>
#include <sstream>
#include <string>
#include <thread>
#include <utility>
#include <vector>

namespace glitch_vpn_core {


static bool IsProcessRunningAsAdmin() {
  return IsUserAnAdmin() == TRUE;
}

static std::wstring JoinArgsExcludingExe() {
  int argc = 0;
  LPWSTR* argv = CommandLineToArgvW(GetCommandLineW(), &argc);
  if (!argv) return L"";
  std::wstring params;
  for (int i = 1; i < argc; ++i) {
    if (i > 1) params += L" ";
    params += L"\"";
    params += argv[i];
    params += L"\"";
  }
  LocalFree(argv);
  return params;
}

static bool RelaunchAsAdministrator() {
  wchar_t modulePath[MAX_PATH];
  const DWORD len = GetModuleFileNameW(nullptr, modulePath, MAX_PATH);
  if (len == 0 || len == MAX_PATH) return false;

  std::wstring parameters = JoinArgsExcludingExe();
  if (!parameters.empty()) parameters += L" ";
  parameters += L"--glitch-admin-elevated";

  SHELLEXECUTEINFOW sei = { sizeof(sei) };
  sei.fMask        = SEE_MASK_NOCLOSEPROCESS;
  sei.hwnd         = nullptr;
  sei.lpVerb       = L"runas";
  sei.lpFile       = modulePath;
  sei.lpParameters = parameters.c_str();
  sei.nShow        = SW_SHOWNORMAL;

  if (!ShellExecuteExW(&sei)) {
    return false;
  }
  return true;
}


static bool IsServiceRunning(const wchar_t* service_name) {
  SC_HANDLE scm = OpenSCManagerW(nullptr, nullptr, SC_MANAGER_CONNECT);
  if (!scm) {
    return false;
  }
  SC_HANDLE service = OpenServiceW(scm, service_name, SERVICE_QUERY_STATUS);
  if (!service) {
    CloseServiceHandle(scm);
    return false;
  }

  SERVICE_STATUS_PROCESS status = {};
  DWORD bytes_needed = 0;
  const BOOL ok = QueryServiceStatusEx(
      service,
      SC_STATUS_PROCESS_INFO,
      reinterpret_cast<LPBYTE>(&status),
      sizeof(status),
      &bytes_needed);

  CloseServiceHandle(service);
  CloseServiceHandle(scm);

  if (!ok) {
    return false;
  }

  switch (status.dwCurrentState) {
    case SERVICE_RUNNING:
    case SERVICE_START_PENDING:
    case SERVICE_CONTINUE_PENDING:
      return true;
    default:
      return false;
  }
}

static bool IsCoreServiceAvailable() {
  return IsServiceRunning(L"GlitchVpnCore");
}

static constexpr UINT kAsyncDoneMessage = WM_APP + 0x51;

void GlitchVpnCorePlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  auto channel =
      std::make_shared<flutter::MethodChannel<flutter::EncodableValue>>(
          registrar->messenger(), "glitch_vpn_core",
          &flutter::StandardMethodCodec::GetInstance());

  auto plugin = std::make_unique<GlitchVpnCorePlugin>(registrar);

  channel->SetMethodCallHandler(
      [plugin_pointer = plugin.get()](const auto& call, auto result) {
        plugin_pointer->HandleMethodCall(call, std::move(result));
      });

  registrar->AddPlugin(std::move(plugin));
}

GlitchVpnCorePlugin::GlitchVpnCorePlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {
  if (registrar_ == nullptr) return;  // e.g. unit tests (sync methods only)
  // Hook the top-level window proc so worker threads can marshal completions
  // back to the platform thread via kAsyncDoneMessage.
  proc_delegate_id_ = registrar_->RegisterTopLevelWindowProcDelegate(
      [this](HWND, UINT message, WPARAM, LPARAM) -> std::optional<LRESULT> {
        if (message == kAsyncDoneMessage) {
          DrainCompleted();
          return 0;
        }
        return std::nullopt;
      });
}

GlitchVpnCorePlugin::~GlitchVpnCorePlugin() {
  if (proc_delegate_id_ != -1 && registrar_ != nullptr) {
    registrar_->UnregisterTopLevelWindowProcDelegate(proc_delegate_id_);
  }
}

void GlitchVpnCorePlugin::RunAsync(
    Result result, std::function<flutter::EncodableValue()> work) {
  if (message_window_ == nullptr && registrar_->GetView() != nullptr) {
    message_window_ = GetAncestor(registrar_->GetView()->GetNativeWindow(), GA_ROOT);
  }
  if (message_window_ == nullptr) {
    // No window to marshal through (e.g. headless) - run inline as a fallback.
    result->Success(work());
    return;
  }
  const uint64_t id = next_id_++;
  pending_[id] = std::move(result);  // platform thread owns the MethodResult
  HWND hwnd = message_window_;
  std::thread([this, id, hwnd, work = std::move(work)]() {
    flutter::EncodableValue value = work();
    {
      std::lock_guard<std::mutex> lock(done_mutex_);
      done_.emplace(id, std::move(value));
    }
    PostMessageW(hwnd, kAsyncDoneMessage, 0, 0);
  }).detach();
}

void GlitchVpnCorePlugin::DrainCompleted() {
  std::map<uint64_t, flutter::EncodableValue> ready;
  {
    std::lock_guard<std::mutex> lock(done_mutex_);
    ready.swap(done_);
  }
  for (auto& entry : ready) {
    auto it = pending_.find(entry.first);
    if (it != pending_.end()) {
      it->second->Success(entry.second);
      pending_.erase(it);
    }
  }
}

struct ComScope {
  HRESULT hr;
  ComScope() { hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED); }
  ~ComScope() { if (SUCCEEDED(hr)) CoUninitialize(); }
};

static std::string WideToUtf8(const std::wstring& w) {
  if (w.empty()) return {};
  int n = WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), nullptr, 0,
                              nullptr, nullptr);
  std::string s(n, 0);
  WideCharToMultiByte(CP_UTF8, 0, w.c_str(), (int)w.size(), s.data(), n, nullptr,
                      nullptr);
  return s;
}

static std::wstring LowerExt(const std::wstring& name) {
  if (name.size() < 4) return L"";
  std::wstring ext = name.substr(name.size() - 4);
  for (auto& c : ext) c = (wchar_t)towlower(c);
  return ext;
}

static std::wstring ResolveShortcut(const std::wstring& lnk) {
  IShellLinkW* link = nullptr;
  if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                              IID_IShellLinkW, (void**)&link))) {
    return L"";
  }
  std::wstring target;
  IPersistFile* pf = nullptr;
  if (SUCCEEDED(link->QueryInterface(IID_IPersistFile, (void**)&pf))) {
    if (SUCCEEDED(pf->Load(lnk.c_str(), STGM_READ))) {
      wchar_t buf[MAX_PATH] = {0};
      WIN32_FIND_DATAW fd = {0};
      if (SUCCEEDED(link->GetPath(buf, MAX_PATH, &fd, SLGP_RAWPATH)) && buf[0]) {
        target = buf;
      }
    }
    pf->Release();
  }
  link->Release();
  return LowerExt(target) == L".exe" ? target : L"";
}

static ULONG_PTR gdiplusToken = 0;
static std::once_flag gdiplusOnce;
static void EnsureGdiplus() {
  std::call_once(gdiplusOnce, []() {
    Gdiplus::GdiplusStartupInput input;
    Gdiplus::GdiplusStartup(&gdiplusToken, &input, nullptr);
  });
}

static int PngEncoderClsid(CLSID* clsid) {
  UINT num = 0, size = 0;
  Gdiplus::GetImageEncodersSize(&num, &size);
  if (size == 0) return -1;
  std::vector<BYTE> buf(size);
  auto* codecs = reinterpret_cast<Gdiplus::ImageCodecInfo*>(buf.data());
  Gdiplus::GetImageEncoders(num, size, codecs);
  for (UINT i = 0; i < num; ++i) {
    if (wcscmp(codecs[i].MimeType, L"image/png") == 0) {
      *clsid = codecs[i].Clsid;
      return (int)i;
    }
  }
  return -1;
}

static std::vector<uint8_t> pngFromArgb(uint32_t* pixels, int w, int h) {
  std::vector<uint8_t> out;
  EnsureGdiplus();
  CLSID pngClsid;
  if (PngEncoderClsid(&pngClsid) < 0) return out;
  Gdiplus::Bitmap bmp(w, h, w * 4, PixelFormat32bppARGB,
                      reinterpret_cast<BYTE*>(pixels));
  if (bmp.GetLastStatus() != Gdiplus::Ok) return out;
  IStream* stream = nullptr;
  if (SUCCEEDED(CreateStreamOnHGlobal(nullptr, TRUE, &stream))) {
    if (bmp.Save(stream, &pngClsid, nullptr) == Gdiplus::Ok) {
      HGLOBAL hg = nullptr;
      if (SUCCEEDED(GetHGlobalFromStream(stream, &hg)) && hg) {
        SIZE_T n = GlobalSize(hg);
        void* p = GlobalLock(hg);
        if (p && n > 0) out.assign((uint8_t*)p, (uint8_t*)p + n);
        GlobalUnlock(hg);
      }
    }
    stream->Release();
  }
  return out;
}

static std::vector<uint8_t> IconToPng(const std::wstring& exePath) {
  std::vector<uint8_t> out;
  SHFILEINFOW sfi = {0};
  if (!SHGetFileInfoW(exePath.c_str(), 0, &sfi, sizeof(sfi),
                      SHGFI_ICON | SHGFI_LARGEICON) ||
      sfi.hIcon == nullptr) {
    return out;
  }
  HICON hIcon = sfi.hIcon;

  ICONINFO ii = {0};
  if (!GetIconInfo(hIcon, &ii) || ii.hbmColor == nullptr) {
    if (ii.hbmColor) DeleteObject(ii.hbmColor);
    if (ii.hbmMask) DeleteObject(ii.hbmMask);
    DestroyIcon(hIcon);
    return out;
  }
  BITMAP bm = {0};
  int w = 32, h = 32;
  if (GetObject(ii.hbmColor, sizeof(bm), &bm)) {
    w = bm.bmWidth;
    h = bm.bmHeight;
  }

  BITMAPINFO bi = {0};
  bi.bmiHeader.biSize = sizeof(BITMAPINFOHEADER);
  bi.bmiHeader.biWidth = w;
  bi.bmiHeader.biHeight = -h;  // top-down
  bi.bmiHeader.biPlanes = 1;
  bi.bmiHeader.biBitCount = 32;
  bi.bmiHeader.biCompression = BI_RGB;

  std::vector<uint32_t> pixels(static_cast<size_t>(w) * h, 0);
  HDC dc = GetDC(nullptr);
  if (GetDIBits(dc, ii.hbmColor, 0, h, pixels.data(), &bi, DIB_RGB_COLORS)) {
    bool hasAlpha = false;
    for (size_t i = 0; i < pixels.size(); ++i) {
      if (pixels[i] & 0xFF000000u) { hasAlpha = true; break; }
    }
    if (!hasAlpha) {
      std::vector<uint32_t> mask(pixels.size(), 0);
      if (GetDIBits(dc, ii.hbmMask, 0, h, mask.data(), &bi, DIB_RGB_COLORS)) {
        // AND-mask: white (set) = transparent, black (clear) = opaque.
        for (size_t i = 0; i < pixels.size(); ++i) {
          pixels[i] = (mask[i] & 0x00FFFFFFu) ? (pixels[i] & 0x00FFFFFFu)
                                              : (pixels[i] | 0xFF000000u);
        }
      } else {
        for (size_t i = 0; i < pixels.size(); ++i) pixels[i] |= 0xFF000000u;
      }
    }
    out = pngFromArgb(pixels.data(), w, h);
  }
  ReleaseDC(nullptr, dc);
  DeleteObject(ii.hbmColor);
  if (ii.hbmMask) DeleteObject(ii.hbmMask);
  DestroyIcon(hIcon);
  return out;
}

static void CollectShortcuts(
    const std::wstring& dir,
    std::vector<std::pair<std::wstring, std::wstring>>& out) {
  WIN32_FIND_DATAW fd;
  HANDLE h = FindFirstFileW((dir + L"\\*").c_str(), &fd);
  if (h == INVALID_HANDLE_VALUE) return;
  do {
    std::wstring name = fd.cFileName;
    if (name == L"." || name == L"..") continue;
    std::wstring full = dir + L"\\" + name;
    if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
      CollectShortcuts(full, out);
    } else if (LowerExt(name) == L".lnk") {
      std::wstring target = ResolveShortcut(full);
      if (!target.empty()) {
        out.push_back({name.substr(0, name.size() - 4), target});  // strip .lnk
      }
    }
  } while (FindNextFileW(h, &fd));
  FindClose(h);
}

// === Windows Mobile Hotspot ===
// Shares a connection over the built-in Mobile Hotspot (SoftAP + DHCP + NAT).
// The tethering manager is created from the VPN tunnel adapter's connection
// profile when the tunnel is up, so client traffic egresses through the VPN.

namespace winnet = winrt::Windows::Networking::Connectivity;
namespace winop = winrt::Windows::Networking::NetworkOperators;

// The WinTun adapter created by libglitchcore (friendly name may get a
// numeric suffix, hence prefix match).
static constexpr wchar_t kVpnAdapterPrefix[] = L"GlitchVPN";

// C++/WinRT .get() must not block an STA thread; hotspot workers use MTA.
struct MtaScope {
  HRESULT hr;
  MtaScope() { hr = CoInitializeEx(nullptr, COINIT_MULTITHREADED); }
  ~MtaScope() { if (SUCCEEDED(hr)) CoUninitialize(); }
};

// Errors travel to Dart as {errorCode, errorMessage} because RunAsync only
// delivers Success results; the Dart side rethrows them as PlatformException.
static flutter::EncodableValue HotspotError(const std::string& code,
                                            const std::string& message) {
  flutter::EncodableMap m;
  m[flutter::EncodableValue("errorCode")] = flutter::EncodableValue(code);
  m[flutter::EncodableValue("errorMessage")] = flutter::EncodableValue(message);
  return flutter::EncodableValue(m);
}

// Interface GUID of the WinTun adapter ("GlitchVPN*"), if present.
static std::optional<GUID> FindVpnAdapterId() {
  ULONG size = 16 * 1024;
  std::vector<BYTE> buf(size);
  const ULONG flags = GAA_FLAG_SKIP_UNICAST | GAA_FLAG_SKIP_ANYCAST |
                      GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER;
  auto* addrs = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
  ULONG rc = GetAdaptersAddresses(AF_UNSPEC, flags, nullptr, addrs, &size);
  if (rc == ERROR_BUFFER_OVERFLOW) {
    buf.resize(size);
    addrs = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buf.data());
    rc = GetAdaptersAddresses(AF_UNSPEC, flags, nullptr, addrs, &size);
  }
  if (rc != NO_ERROR) return std::nullopt;
  for (auto* a = addrs; a != nullptr; a = a->Next) {
    if (a->FriendlyName == nullptr) continue;
    if (wcsncmp(a->FriendlyName, kVpnAdapterPrefix,
                wcslen(kVpnAdapterPrefix)) != 0) {
      continue;
    }
    // AdapterName is the interface GUID string, e.g. "{9A2B...}".
    const int wlen =
        MultiByteToWideChar(CP_ACP, 0, a->AdapterName, -1, nullptr, 0);
    std::wstring wname(wlen, 0);
    MultiByteToWideChar(CP_ACP, 0, a->AdapterName, -1, wname.data(), wlen);
    GUID id;
    if (SUCCEEDED(CLSIDFromString(wname.c_str(), &id))) return id;
  }
  return std::nullopt;
}

// Picks the connection profile to share: the VPN tunnel's profile when the
// tunnel is up, else the internet profile. |tunneled| reports whether the
// chosen profile belongs to the VPN adapter.
static winnet::ConnectionProfile PickShareProfile(bool& tunneled) {
  tunneled = false;
  const std::optional<GUID> vpn_id = FindVpnAdapterId();
  if (vpn_id) {
    const winrt::guid vpn_guid(*vpn_id);
    for (const auto& profile :
         winnet::NetworkInformation::GetConnectionProfiles()) {
      try {
        const auto adapter = profile.NetworkAdapter();
        if (adapter && adapter.NetworkAdapterId() == vpn_guid) {
          tunneled = true;
          return profile;
        }
      } catch (const winrt::hresult_error&) {
        // Some profiles expose no adapter; skip them.
      }
    }
  }
  auto internet = winnet::NetworkInformation::GetInternetConnectionProfile();
  if (internet && vpn_id) {
    try {
      const auto adapter = internet.NetworkAdapter();
      tunneled = adapter && adapter.NetworkAdapterId() == winrt::guid(*vpn_id);
    } catch (const winrt::hresult_error&) {
    }
  }
  return internet;
}

static std::string TetheringCapabilityMessage(winop::TetheringCapability c) {
  using winop::TetheringCapability;
  switch (c) {
    case TetheringCapability::DisabledByGroupPolicy:
      return "Hotspot is disabled by group policy.";
    case TetheringCapability::DisabledByHardwareLimitation:
      return "No Wi-Fi adapter with hotspot (SoftAP) support is available.";
    case TetheringCapability::DisabledByOperator:
      return "Hotspot is disabled by the network operator.";
    case TetheringCapability::DisabledBySku:
      return "Hotspot is disabled in this edition of Windows.";
    case TetheringCapability::DisabledByRequiredAppNotInstalled:
      return "A required system app for hotspot is not installed.";
    case TetheringCapability::DisabledOnSimError:
      return "Hotspot is disabled due to a SIM error.";
    default:
      return "Hotspot is not available on this system (capability code " +
             std::to_string(static_cast<int>(c)) + ").";
  }
}

static std::string TetheringStatusMessage(winop::TetheringOperationStatus s,
                                          const winrt::hstring& extra) {
  using winop::TetheringOperationStatus;
  std::string msg;
  switch (s) {
    case TetheringOperationStatus::WiFiDeviceOff:
      msg = "Wi-Fi is turned off.";
      break;
    case TetheringOperationStatus::MobileBroadbandDeviceOff:
      msg = "The mobile broadband device is turned off.";
      break;
    case TetheringOperationStatus::BluetoothDeviceOff:
      msg = "Bluetooth is turned off.";
      break;
    case TetheringOperationStatus::OperationInProgress:
      msg = "Another hotspot operation is in progress.";
      break;
    case TetheringOperationStatus::EntitlementCheckTimeout:
    case TetheringOperationStatus::EntitlementCheckFailure:
      msg = "The operator entitlement check failed.";
      break;
    default:
      msg = "Tethering operation failed (status code " +
            std::to_string(static_cast<int>(s)) + ").";
      break;
  }
  if (!extra.empty()) msg += " " + winrt::to_string(extra);
  return msg;
}

static flutter::EncodableValue StartHotspotWork(const std::string& ssid,
                                                const std::string& password,
                                                bool open) {
  if (open) {
    return HotspotError(
        "HOTSPOT_OPEN_NOT_SUPPORTED",
        "Windows Mobile Hotspot requires a WPA2 passphrase; open "
        "(passwordless) hotspots are not supported by the OS.");
  }
  MtaScope com;
  try {
    bool tunneled = false;
    auto profile = PickShareProfile(tunneled);
    if (!profile) {
      return HotspotError("HOTSPOT_NO_CONNECTION",
                          "No shareable network connection was found.");
    }
    const auto capability = winop::NetworkOperatorTetheringManager::
        GetTetheringCapabilityFromConnectionProfile(profile);
    if (capability != winop::TetheringCapability::Enabled) {
      return HotspotError("HOTSPOT_NOT_SUPPORTED",
                          TetheringCapabilityMessage(capability));
    }

    winop::NetworkOperatorTetheringManager manager{nullptr};
    try {
      manager = winop::NetworkOperatorTetheringManager::
          CreateFromConnectionProfile(profile);
    } catch (const winrt::hresult_error&) {
      if (!tunneled) throw;
      // The tunnel profile cannot be shared directly; fall back to the
      // internet profile (post-NAT traffic still follows the host routing
      // table into the tunnel while the VPN is up).
      auto internet =
          winnet::NetworkInformation::GetInternetConnectionProfile();
      if (!internet) throw;
      manager = winop::NetworkOperatorTetheringManager::
          CreateFromConnectionProfile(internet);
      tunneled = false;
    }

    auto config = manager.GetCurrentAccessPointConfiguration();
    config.Ssid(winrt::to_hstring(ssid));
    config.Passphrase(winrt::to_hstring(password));
    manager.ConfigureAccessPointAsync(config).get();

    if (manager.TetheringOperationalState() !=
        winop::TetheringOperationalState::On) {
      const auto res = manager.StartTetheringAsync().get();
      if (res.Status() != winop::TetheringOperationStatus::Success) {
        return HotspotError(
            "HOTSPOT_START_FAILED",
            TetheringStatusMessage(res.Status(), res.AdditionalErrorMessage()));
      }
    }

    flutter::EncodableMap out;
    out[flutter::EncodableValue("ssid")] =
        flutter::EncodableValue(winrt::to_string(config.Ssid()));
    out[flutter::EncodableValue("password")] =
        flutter::EncodableValue(winrt::to_string(config.Passphrase()));
    out[flutter::EncodableValue("open")] = flutter::EncodableValue(false);
    out[flutter::EncodableValue("tunneled")] =
        flutter::EncodableValue(tunneled);
    return flutter::EncodableValue(out);
  } catch (const winrt::hresult_error& e) {
    return HotspotError("HOTSPOT_START_FAILED", winrt::to_string(e.message()));
  } catch (const std::exception& e) {
    return HotspotError("HOTSPOT_START_FAILED", e.what());
  }
}

static flutter::EncodableValue StopHotspotWork() {
  MtaScope com;
  try {
    bool tunneled = false;
    auto profile = PickShareProfile(tunneled);
    if (!profile) {
      // Nothing shareable means nothing can be running.
      return flutter::EncodableValue(true);
    }
    winop::NetworkOperatorTetheringManager manager{nullptr};
    try {
      manager = winop::NetworkOperatorTetheringManager::
          CreateFromConnectionProfile(profile);
    } catch (const winrt::hresult_error&) {
      return flutter::EncodableValue(true);
    }
    if (manager.TetheringOperationalState() ==
        winop::TetheringOperationalState::Off) {
      return flutter::EncodableValue(true);
    }
    const auto res = manager.StopTetheringAsync().get();
    if (res.Status() != winop::TetheringOperationStatus::Success) {
      return HotspotError(
          "HOTSPOT_STOP_FAILED",
          TetheringStatusMessage(res.Status(), res.AdditionalErrorMessage()));
    }
    return flutter::EncodableValue(true);
  } catch (const winrt::hresult_error& e) {
    return HotspotError("HOTSPOT_STOP_FAILED", winrt::to_string(e.message()));
  } catch (const std::exception& e) {
    return HotspotError("HOTSPOT_STOP_FAILED", e.what());
  }
}

static flutter::EncodableValue GetHotspotConfigWork() {
  MtaScope com;
  flutter::EncodableMap out;
  out[flutter::EncodableValue("active")] = flutter::EncodableValue(false);
  try {
    bool tunneled = false;
    auto profile = PickShareProfile(tunneled);
    if (!profile) return flutter::EncodableValue(out);
    auto manager = winop::NetworkOperatorTetheringManager::
        CreateFromConnectionProfile(profile);
    auto config = manager.GetCurrentAccessPointConfiguration();
    out[flutter::EncodableValue("active")] = flutter::EncodableValue(
        manager.TetheringOperationalState() ==
        winop::TetheringOperationalState::On);
    out[flutter::EncodableValue("ssid")] =
        flutter::EncodableValue(winrt::to_string(config.Ssid()));
    out[flutter::EncodableValue("password")] =
        flutter::EncodableValue(winrt::to_string(config.Passphrase()));
    out[flutter::EncodableValue("tunneled")] =
        flutter::EncodableValue(tunneled);
  } catch (const winrt::hresult_error&) {
    // Leave active=false.
  }
  return flutter::EncodableValue(out);
}

static flutter::EncodableValue IsHotspotSupportedWork() {
  MtaScope com;
  try {
    bool tunneled = false;
    auto profile = PickShareProfile(tunneled);
    if (!profile) return flutter::EncodableValue(false);
    return flutter::EncodableValue(
        winop::NetworkOperatorTetheringManager::
            GetTetheringCapabilityFromConnectionProfile(profile) ==
        winop::TetheringCapability::Enabled);
  } catch (const winrt::hresult_error&) {
    return flutter::EncodableValue(false);
  } catch (const std::exception&) {
    return flutter::EncodableValue(false);
  }
}

void GlitchVpnCorePlugin::HandleMethodCall(
    const flutter::MethodCall<flutter::EncodableValue>& method_call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const std::string& method = method_call.method_name();

  if (method == "listInstalledApps") {
    RunAsync(std::move(result), []() -> flutter::EncodableValue {
      ComScope com;  // per-worker-thread COM (IShellLink)
      std::vector<std::pair<std::wstring, std::wstring>> apps;
      for (const KNOWNFOLDERID& folder :
           {FOLDERID_CommonPrograms, FOLDERID_Programs}) {
        PWSTR dir = nullptr;
        if (SUCCEEDED(SHGetKnownFolderPath(folder, 0, nullptr, &dir))) {
          CollectShortcuts(dir, apps);
          CoTaskMemFree(dir);
        }
      }
      std::set<std::wstring> seen;
      flutter::EncodableList list;
      for (auto& a : apps) {
        std::wstring base = a.second.substr(a.second.find_last_of(L"\\/") + 1);
        std::wstring key = base;
        for (auto& c : key) c = (wchar_t)towlower(c);
        if (!seen.insert(key).second) continue;
        flutter::EncodableMap m;
        m[flutter::EncodableValue("name")] = flutter::EncodableValue(WideToUtf8(a.first));
        m[flutter::EncodableValue("path")] = flutter::EncodableValue(WideToUtf8(a.second));
        m[flutter::EncodableValue("process")] = flutter::EncodableValue(WideToUtf8(base));
        list.push_back(flutter::EncodableValue(m));
      }
      return flutter::EncodableValue(list);
    });
    return;
  }

  if (method == "appIcons") {
    std::vector<std::string> paths;
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("paths"));
      if (it != args->end()) {
        if (const auto* list = std::get_if<flutter::EncodableList>(&it->second)) {
          for (const auto& v : *list) {
            if (const auto* s = std::get_if<std::string>(&v)) {
              if (!s->empty()) paths.push_back(*s);
            }
          }
        }
      }
    }
    RunAsync(std::move(result), [paths = std::move(paths)]() -> flutter::EncodableValue {
      ComScope com;  // SHGetFileInfo/icon may touch COM on this worker thread
      flutter::EncodableMap out;
      for (const auto& s : paths) {
        int wlen = MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), nullptr, 0);
        std::wstring wpath(wlen, 0);
        MultiByteToWideChar(CP_UTF8, 0, s.c_str(), (int)s.size(), wpath.data(), wlen);
        std::vector<uint8_t> png = IconToPng(wpath);
        if (!png.empty()) {
          out[flutter::EncodableValue(s)] = flutter::EncodableValue(png);
        }
      }
      return flutter::EncodableValue(out);
    });
    return;
  }

  if (method == "pickExecutable") {
    ComScope com;
    std::string picked;
    IFileOpenDialog* dlg = nullptr;
    if (SUCCEEDED(CoCreateInstance(CLSID_FileOpenDialog, nullptr,
                                   CLSCTX_INPROC_SERVER, IID_IFileOpenDialog,
                                   (void**)&dlg))) {
      COMDLG_FILTERSPEC filters[] = {{L"Applications", L"*.exe"},
                                     {L"All files", L"*.*"}};
      dlg->SetFileTypes(2, filters);
      dlg->SetTitle(L"Select an application");
      if (SUCCEEDED(dlg->Show(nullptr))) {
        IShellItem* item = nullptr;
        if (SUCCEEDED(dlg->GetResult(&item))) {
          PWSTR p = nullptr;
          if (SUCCEEDED(item->GetDisplayName(SIGDN_FILESYSPATH, &p))) {
            picked = WideToUtf8(p);
            CoTaskMemFree(p);
          }
          item->Release();
        }
      }
      dlg->Release();
    }
    if (picked.empty()) {
      result->Success(flutter::EncodableValue());  // null → user cancelled
    } else {
      result->Success(flutter::EncodableValue(picked));
    }
    return;
  }

  if (method == "checkAdmin") {
    const bool is_admin = IsProcessRunningAsAdmin();
    result->Success(flutter::EncodableValue(is_admin));
    return;
  }

  if (method == "appsListing") {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "appsIcon") {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "getPlatformVersion") {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
    return;
  }

  if (method == "updateNotification") {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "prepareTunnel") {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "stopTunnel") {
    result->Success(flutter::EncodableValue(true));
    return;
  }

  if (method == "requestAdmin") {
    if (IsProcessRunningAsAdmin()) {
      result->Success(flutter::EncodableValue(true));
      return;
    }
    const bool launched = RelaunchAsAdministrator();
    result->Success(flutter::EncodableValue(launched));
    if (launched) {
      PostQuitMessage(0);
    }
    return;
  }

  if (method == "serviceAvailable") {
    result->Success(flutter::EncodableValue(IsCoreServiceAvailable()));
    return;
  }

  if (method == "isHotspotSupported") {
    RunAsync(std::move(result),
             []() -> flutter::EncodableValue { return IsHotspotSupportedWork(); });
    return;
  }

  if (method == "startHotspot") {
    std::string ssid;
    std::string password;
    bool open = false;
    const auto* args = std::get_if<flutter::EncodableMap>(method_call.arguments());
    if (args) {
      auto it = args->find(flutter::EncodableValue("ssid"));
      if (it != args->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) ssid = *s;
      }
      it = args->find(flutter::EncodableValue("password"));
      if (it != args->end()) {
        if (const auto* s = std::get_if<std::string>(&it->second)) password = *s;
      }
      it = args->find(flutter::EncodableValue("open"));
      if (it != args->end()) {
        if (const auto* b = std::get_if<bool>(&it->second)) open = *b;
      }
    }
    RunAsync(std::move(result),
             [ssid = std::move(ssid), password = std::move(password),
              open]() -> flutter::EncodableValue {
               return StartHotspotWork(ssid, password, open);
             });
    return;
  }

  if (method == "stopHotspot") {
    RunAsync(std::move(result),
             []() -> flutter::EncodableValue { return StopHotspotWork(); });
    return;
  }

  if (method == "getHotspotConfig") {
    RunAsync(std::move(result),
             []() -> flutter::EncodableValue { return GetHotspotConfigWork(); });
    return;
  }

  if (method == "getPlatformVersion") {
    std::ostringstream version_stream;
    version_stream << "Windows ";
    if (IsWindows10OrGreater()) {
      version_stream << "10+";
    } else if (IsWindows8OrGreater()) {
      version_stream << "8";
    } else if (IsWindows7OrGreater()) {
      version_stream << "7";
    }
    result->Success(flutter::EncodableValue(version_stream.str()));
    return;
  }

  result->NotImplemented();
}

}  // namespace glitch_vpn_core
