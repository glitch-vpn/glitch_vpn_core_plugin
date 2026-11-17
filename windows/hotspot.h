#ifndef FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_H_
#define FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_H_

#include <flutter/encodable_value.h>

#include <string>

// Windows Mobile Hotspot through WinRT's NetworkOperatorTetheringManager,
// with no administrator rights. Every call blocks and runs on a worker thread.
// A failure is a map {"reason": <code>, "detail": <text>}; the codes are the
// ones lib/vpn_hotspot_channel.dart parses.
namespace glitch_vpn_core::hotspot {

// {"supported": bool, "reason": string (when unsupported), "bands": [string]}
flutter::EncodableValue Capability();

// Saves the user's own Mobile hotspot configuration and no-connections
// timeout on first use, applies ours, turns the timeout off and starts on the
// physical connection's profile. A hotspot already running with ours is kept.
// band is "auto", "2.4" or "5".
flutter::EncodableValue Start(const std::string& ssid,
                              const std::string& passphrase,
                              const std::string& band);

// Stops the hotspot, puts the user's configuration and timeout back.
flutter::EncodableValue Stop();

// {"state": "on" | "off" | "transition", "ssid": string, "ours": bool}
flutter::EncodableValue Status();

// {"clients": [{"name": string, "mac": string, "ipv4": string}]}
flutter::EncodableValue Clients();

// Restarts the running hotspot on "tunnel" or "wifi" (the physical
// connection), keeping its configuration.
flutter::EncodableValue RestartOn(const std::string& connection);

}  // namespace glitch_vpn_core::hotspot

#endif  // FLUTTER_PLUGIN_GLITCH_VPN_CORE_HOTSPOT_H_
