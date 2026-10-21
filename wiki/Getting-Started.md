# Getting Started

## Install

```yaml
dependencies:
  glitch_vpn_core:
    git:
      url: https://github.com/glitch-vpn/glitch_vpn_core_plugin.git
      ref: <commit>                        # a full commit hash from main
```

No version of the plugin is tagged yet, so pin a commit from `main` until one
is; a branch name moves under you.

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

await core.connect(
  engine: VpnEngine.xray,
  config: 'vless://…',                     // a share link; awg takes INI or awg://
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
`disableIPv6` and `disableUDP` as switches above every tier.

Geo matchers need geoip.dat/geosite.dat — you supply them, see below.

## Platform setup

**Android.** The plugin runs the tunnel in a foreground service with a live
notification and can disconnect from it headlessly. Ask for the notification
permission (`requestNotificationPermission`) and set the notification texts via
`configure`. The whole app package is excluded from the VPN, so in-app HTTP
does not traverse the tunnel — this is why the exit IP is resolved core-side.

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
  geoAssetsDir: r'C:\ProgramData\myapp\geo',   // absolute path
);
```

Empty falls back to the engine default, which exists on desktop (beside the
core binary) but not on Android. With geo rules and no usable files the connect
fails loudly — nothing is downloaded behind your back. `pickDirectory()` opens
a folder picker on Windows if you want the user to choose.

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
`VpnLog` carries `at` (the core's time, in UTC), `level` (a `VpnLogLevel`),
`component` (the engine or subsystem that wrote it, empty when none) and
`message`. A connection event's `at` is the core's time too.

The app under `example/` exercises the whole API and doubles as a test client.
