#ifndef FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_INTERNAL_H_
#define FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_INTERNAL_H_

#include <guiddef.h>

#include <cstdint>
#include <optional>
#include <string>

// The parts of the hotspot that need no WinRT, so a unit test can reach them.
namespace glitch_vpn_core::hotspot::detail {

struct AdapterInfo {
  GUID id{};
  std::wstring name;
  std::wstring description;
  uint32_t type = 0;  // IANA ifType: 71 Wi-Fi, 6 Ethernet
  bool up = false;
  uint32_t metric = 0;
};

// The tunnel's Wintun adapter, by its friendly name (a numeric suffix may
// follow).
bool IsTunnel(const AdapterInfo& adapter);

// A physical Wi-Fi or Ethernet adapter that is up. Software adapters (the
// tunnel, Hyper-V and WSL switches, VM and VPN adapters, the hotspot's own
// Wi-Fi Direct adapter) are not.
bool IsPhysical(const AdapterInfo& adapter);

// 1 to 32 bytes.
bool IsValidSsid(const std::string& ssid);

// 8 to 63 printable ASCII characters.
bool IsValidPassphrase(const std::string& passphrase);

// What is kept of the user's own Mobile hotspot settings.
struct SavedState {
  std::string ssid;
  std::string passphrase;
  int band = 0;
  bool timeout_was_enabled = false;
};

std::string EncodeSavedState(const SavedState& state);

// Null for text that is not a whole encoded state.
std::optional<SavedState> DecodeSavedState(const std::string& bytes);

}  // namespace glitch_vpn_core::hotspot::detail

#endif  // FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_INTERNAL_H_
