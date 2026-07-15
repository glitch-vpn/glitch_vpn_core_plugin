# glitch_vpn_core

[![CI](https://github.com/glitch-vpn/glitch_vpn_core_plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/glitch-vpn/glitch_vpn_core_plugin/actions/workflows/ci.yml)

Flutter FFI plugin around the
[libglitchcore](https://github.com/glitch-vpn/libglitchcore) VPN core. One
Dart API drives the Xray (VLESS, Trojan, Shadowsocks), AmneziaWG and mihomo
(Hysteria2) engines on Android, Windows and Linux.

## Usage

```dart
final core = GlitchVpnCore.instance;
await GlitchVpnCore.initialize();

core.onStatusChanged.listen((s) => print(s.status));
core.onStatsChanged.listen((s) => print('${s.downloadBytes}/${s.uploadBytes}'));

await core.connect(
  engine: VpnEngine.xray,
  config: 'vless://...',          // a share link; awg takes INI or awg://
  routing: const VpnRouting(
    direct: ['geoip:ru', 'speedtest.net'],
    block: ['geosite:category-ads-all'],
    localNetworksDirect: true,
  ),
  dns: const VpnDns(mode: VpnDnsMode.fakeIp, servers: ['1.1.1.1']),
);

await core.disconnect();
```

The app under `example/` covers the whole API and doubles as a test client.

## What the API covers

* `connect`/`disconnect` with routing rules, DNS settings, balancer strategy,
  uTLS fingerprint, Mux, sniffing and probe-URL options.
* Routing matchers: `geoip:`, `geosite:`, `domain:`, `full:`, `keyword:`,
  `regexp:`, `process:app.exe`, bare IP/CIDR. IPv6 and UDP kill switches, LAN
  bypass.
* DNS over UDP, TLS, HTTPS or QUIC, and a fake-ip mode.
* Proxy mode: `connect(proxyPort: ...)` opens an authenticated loopback SOCKS
  proxy instead of a TUN. No admin rights involved; the credentials come back
  in `proxyCredentials`.
* Streams for status, traffic and memory stats, liveness, structured logs and
  a per-connection inspector (off by default).
* `measurePings(links)`: url-test latency for a server list without
  connecting.
* Runtime geo provisioning: `GeoManager` downloads geoip.dat/geosite.dat from
  a pinned source into a content-addressed cache; `refreshGeoAssets` and
  `checkGeoUpdate` handle updates. Nothing is bundled.
* Several links in one config make a balancer, awg included.
* Split tunneling: per-app on Android, per-process on desktop, with
  installed-app pickers (`listInstalledApps`, `appIcons`, `pickExecutable`).
* Android runs a foreground service with a live notification and can
  disconnect headlessly. Windows handles UAC elevation or talks to the system
  service. `availableEngines` reports what the loaded binary supports.

## Platforms

|                 | Android           | Windows           | Linux             | iOS/macOS |
|-----------------|-------------------|-------------------|-------------------|-----------|
| Engines         | xray, awg, mihomo | xray, awg, mihomo | xray, awg, mihomo | stub      |
| Data path       | VpnService TUN    | Wintun or service | TUN               | none      |
| Split tunneling | per app           | per process       | per process       | none      |

## Windows: admin rights

TUN mode needs elevation. On connect, `ensureAdmin()` first looks for the
`GlitchVpnCore` system service: the core release ships it as a separate
binary, and when it is installed and running the plugin drives the tunnel
through it with no UAC prompt. Without the service, `ensureAdmin()` relaunches
the process elevated. Installing the service is the app installer's job - the
plugin never touches the system. Debug builds run the core in-process and
always take the UAC route. Proxy mode (`proxyPort`) needs neither.

## Native binaries

Not in git. `flutter build` downloads the release pinned by `libglitchcore_version`
in `pubspec.yaml` (Android: `android/build.gradle`, Windows: `windows/CMakeLists.txt`).

Bump the core: edit `libglitchcore_version` (and optional `libglitchcore_sha256`),
then regenerate bindings if the header changed (drop `libglitchcore.h` from the
release zip, or a local build, at `build/libglitchcore.h`):

    dart run ffigen --config ffigen.yaml

The core header includes `"dart_api_dl.h"`, so ffigen also needs the Dart SDK
headers next to it in `build/`: copy `dart_api_dl.h`, `dart_api.h` and
`dart_native_api.h` from `$FLUTTER_ROOT/bin/cache/dart-sdk/include`
(the Dart SDK bundled with Flutter; any `<dart-sdk>/include` works).

CI fails if `lib/src/bindings_generated.dart` drifts from the pinned header.

Local unreleased core (skip download):

    LIBGLITCHCORE_LOCAL=/path/to/libglitchcore/build_output/ffi flutter build ...

## License

Plugin: MIT ([LICENSE](LICENSE)). Loaded core binaries are a separate work —
mihomo/xray compositions are GPL-3.0; awg-only is permissive. See the core
repo's LICENSE and THIRD_PARTY_NOTICES.
