#ifndef FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_H_
#define FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_H_

#include <flutter/encodable_value.h>

#include <string>

// Windows Mobile Hotspot through WinRT's NetworkOperatorTetheringManager,
// with no administrator rights. Every call blocks and runs on a worker thread.
// A failure is a map {"reason": <code>, "detail": <text>} and, where the call
// knows whether the hotspot runs afterwards, "running": bool. The codes are
// the ones lib/vpn_hotspot_channel.dart parses.
namespace glitch_vpn_core::hotspot {

// {"supported": bool, "reason": "noAdapter" | "cannotHost" | "noConnection" |
// "unknown" (when unsupported), "bands": [string] (when supported)}
flutter::EncodableValue Capability();

// Saves the user's own Mobile hotspot configuration and no-connections
// timeout on first use, applies ours, turns the timeout off and starts on the
// physical connection's profile. A hotspot already running with ours is kept.
// band is "auto", "2.4" or "5". Answers {"running": bool, "restarted": bool}:
// restarted when a running hotspot was stopped to apply another
// configuration.
flutter::EncodableValue Start(const std::string& ssid,
                              const std::string& passphrase,
                              const std::string& band);

// Stops the hotspot, puts the user's configuration and timeout back. A stop
// that turned the hotspot off but could not restore the settings is a failure
// with running false.
flutter::EncodableValue Stop();

// {"state": "on" | "off" | "transition" | "unknown", "ssid": string,
// "ours": bool}. "unknown" when the state could not be read.
flutter::EncodableValue Status();

// {"clients": [{"name": string, "mac": string, "ipv4": string}]}
flutter::EncodableValue Clients();

}  // namespace glitch_vpn_core::hotspot

#endif  // FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_H_
