# Getting Started

## Install

```yaml
dependencies:
  glitch_vpn_core:
    git:
      url: https://github.com/glitch-vpn/glitch_vpn_core_plugin.git
      ref: v0.2.3
```

Pin a release tag; a branch name moves under you. Each tag carries the core
release it was built against.

The native library is not in git. `flutter build` downloads the release pinned
in the plugin's `pubspec.yaml` and bundles it — nothing to install by hand.

## Connect

```dart
final core = GlitchVpnCore.instance;
await GlitchVpnCore.initialize();          // idempotent; call on every UI restore

core.onStatusChanged.listen((s) => setState(() => _status = s.status));
core.onStatsChanged.listen((s) => print('${s.downloadBytes}/${s.uploadBytes}'));
core.onServerSelectionChanged.listen((s) => print('via ${s.selected?.displayName}'));
core.onExternalIpChanged.listen((ip) => print('${ip.ipv4} / ${ip.ipv6}'));

// The Android notification's words, in your app's language.
const texts = VpnNotificationTexts(
  title: 'My VPN',
  channel: 'Connection status',
  connecting: 'Connecting…',
  connected: 'Connected',
  disconnecting: 'Disconnecting…',
  disconnectAction: 'Disconnect',
  byteUnits: VpnByteUnits(
    bytes: 'B',
    kilobytes: 'KB',
    megabytes: 'MB',
    gigabytes: 'GB',
    terabytes: 'TB',
  ),
);

await core.connect(
  engine: VpnEngine.xray,
  config: 'vless://…',                     // a share link; awg takes INI or awg://
  notification: texts,
  routing: const VpnRouting(
    tiers: [
      VpnRoutingTier(
        direct: ['geoip:ru', 'speedtest.net'],
        block: ['geosite:category-ads-all'],
      ),
    ],
    localNetworksDirect: true,
  ),
  dns: const VpnDns(mode: VpnDnsMode.fakeIp, servers: ['1.1.1.1']),
);

await core.disconnect();
```

Several links in one `config` (newline-separated) make a balancer pool; pick a
strategy with `balancerStrategy` and let `onServerSelectionChanged` tell the UI
which server won.

`connect()` throws a `PlatformException` when the start is refused, and its
`code` says why; the method lists them all. `BUSY` leaves the session in
progress and its status alone. Every other refusal also sets `onStatusChanged`
to error: for the plugin's own checks (`ENGINE_NOT_IN_BUILD`,
`UNSUPPORTED_STRATEGY`, `ELEVATION_REQUIRED`, ...) the status reason is the
exception's message; for Android's codes (`DENIED`, ...) and the engines'
`*_START_FAILED` the exception keeps its source's message, and the status
names the platform's code or the core's result. A start the core accepts can still fail afterwards — a bad link,
missing geo files, a failed handshake — and that failure arrives on
`onStatusChanged` only.

`initialize()` does no network I/O and no work you have to sequence around. It
also restores state: called over a tunnel that is still up — after a hot
restart, an app relaunch, or against the Windows service — it replays the
connected status, the server, the exit IP and the stats stream, so a fresh UI
comes back in sync without reconnecting.

## Routing

Rules are ordered tiers, evaluated first to last; within a tier block beats
direct beats proxy. That ordering is the point: a specific rule in tier 1 wins
over a broad one in tier 2, whatever their outcomes.

```dart
routing: const VpnRouting(
  tiers: [
    VpnRoutingTier(proxy: ['domain:vk.ru']),   // this one wins…
    VpnRoutingTier(direct: ['domain:ru']),     // …over the whole .ru zone
  ],
),
```

Matchers: `geoip:cn`, `geosite:category-ads-all`, `domain:example.com` (the
zone and its subdomains), `full:exact.host`, `keyword:str`, `regexp:expr`,
`process:App.exe`, or a bare IP/CIDR. Plus `localNetworksDirect`,
`disableIPv6` and `disableUDP` as switches above every tier. On Android, IPv6
goes through the tunnel unless `disableIPv6` is set, and is then blocked rather
than let past it. awg reads only this switch of the routing, and it changes
the tunnel only on Android. A country that should bypass the tunnel is a
`geoip:<cc>` entry in a tier's `direct` list; there is no separate country
option.

Geo matchers need geoip.dat/geosite.dat — you supply them, see below.

## Platform setup

**Android.** The plugin runs the tunnel in a foreground service with a live
notification and can disconnect from it headlessly. Ask for the notification
permission (`requestNotificationPermission`). The notification's words are the
app's, the traffic counter's units among them:
`connect(notification: VpnNotificationTexts(...))` carries them, and
`updateNotification` changes them or the line under the title mid-session. The
counter shows the app's own network traffic since the tunnel came up: the
engine's, proxied and direct alike, with the protocols' overhead, and anything
else the app fetches meanwhile, such as a subscription refresh.
`onStatsChanged` counts the proxied traffic only.
The whole app package is excluded from the VPN, so in-app HTTP does not
traverse the tunnel — this is why the exit IP is resolved core-side.

Android also starts the tunnel by itself: always-on (at boot, when the user
switches it on, after an app update) and a restart after the app's process
died. No app session asked for that tunnel, so the plugin hands it to the
handler the app registered, which reconnects or declines:

```dart
@pragma('vm:entry-point')
Future<void> onSystemStart(VpnSystemStart start) async {
  // A background isolate, no UI: read the last selection, then connect.
  await GlitchVpnCore.instance.connect(
    engine: engine,
    config: link,
    notification: texts,
  );
}

await GlitchVpnCore.registerSystemStartHandler(onSystemStart);   // once, at startup
```

The handler runs in the UI's isolate when one is up, and otherwise in a fresh
one with none of the UI's state, so it calls `configure()` itself. With no
handler registered, or one that returns without connecting, the service stops
instead of holding a tunnel with no engine behind it.
`GlitchVpnCore.alwaysOn()` reads the always-on and lockdown switches while a
tunnel runs.

**Windows.** TUN mode needs elevation. `ensureAdmin()` first looks for the
`GlitchVpnCore` system service that the core release ships: with it installed,
the tunnel runs without a UAC prompt; without it, the process relaunches
elevated. The build puts `glitch_vpn_core_service.exe` next to the app's
executable; installing it as the service is the app installer's job. Debug
builds always take the UAC route.

**Linux.** TUN via the native adapter; same API, no service.

**Any platform, no privileges:** `connect(proxyPort: 10808)` opens a loopback
SOCKS proxy instead of a TUN — useful for testing a config, and the only mode
that needs no elevation anywhere. Credentials come back in `proxyCredentials`.

## Geo databases

The plugin neither bundles nor downloads geoip.dat/geosite.dat. Your app
provisions them — bundle as assets, or fetch on your own schedule — and points
the engine at the directory:

```dart
await core.connect(
  engine: VpnEngine.xray,
  config: link,
  notification: texts,
  geoAssetsDir: r'C:\ProgramData\myapp\geo',   // absolute path
);
```

The directory is also mihomo's home for the session, where it keeps its
`cache.db`, so the engine has to be able to write there. Empty falls back to
the engine default: the directory of the core binary on Windows, and on
Android a private directory of the app's that holds no geo files. Linux has no
default, so mihomo there needs the path on every connect. With geo rules and no
usable files the connect fails loudly — nothing is downloaded behind your back.
`pickDirectory()` opens a folder picker on Windows if you want the user to
choose.

## What else is there

`measurePings(links)` for url-test latency without connecting (a link that
fails carries its own `error`; a run the core refuses throws `PING_FAILED`);
`listInstalledApps` / `appIcons` / `pickExecutable` for building a
split-tunneling picker; `setConnectionInspector` for a per-connection event
stream; `setLogsVerbosity` and `setMemoryLimit`; `availableEngines()` to hide
what a given build does not contain; `getCoreVersions()` for the engines'
versions, where `xrayCore`, `amneziawg` and `mihomo` are each null for an engine
the build lacks.

Log lines arrive on `onLogsChanged` once `setLogsVerbosity` turns them on. Each
`VpnLog` carries `at` (the core's time, in UTC), `level` (a `VpnLogLevel`:
debug, info, warn, error or fatal, as the engine that wrote the line gave it),
`component` (the engine or subsystem that wrote it, empty when none) and
`message`. A connection event's `at` is the core's time too; its `inbound` is
the listener the connection arrived on, and a connection a block rule refused
arrives with `status: rejected`.

The app under `example/` exercises the whole API and doubles as a test client.
