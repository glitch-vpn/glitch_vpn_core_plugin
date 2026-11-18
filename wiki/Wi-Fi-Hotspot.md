# Wi-Fi hotspot

Windows only. `VpnHotspotChannel` (`lib/vpn_hotspot_channel.dart`) runs the
built-in Mobile hotspot, so devices without a VPN client can join the PC's
Wi-Fi. It needs no administrator rights: it goes through WinRT's
`NetworkOperatorTetheringManager`. Other platforms answer
`HotspotCapability.unavailable`, and `start()` ends in `failed` with the reason
`unsupported`.

```dart
final hotspot = VpnHotspotChannel.instance;
final capability = await hotspot.refreshCapability();
if (capability.supported) {
  await hotspot.configure(
    ssid: 'my-network',
    passphrase: 'at-least-8-chars',
    band: HotspotBand.auto, // only the bands in capability.bands
  );
  await hotspot.start();
}
hotspot.listenable.addListener(() => print(hotspot.value.state));
hotspot.clients.addListener(() => print(hotspot.clients.value));
await hotspot.stop();
```

## State

`HotspotState` is `off`, `starting`, `on` or `failed`. A `failed` update carries
a `HotspotFailure`: a `reason` (`unsupported`, `noConnection`, `wifiOff`,
`operationInProgress`, `startFailed`, `stopFailed`, `configureFailed`,
`bandUnsupported`, `invalidCredentials`, `coreUnreachable`,
`sharingNeedsElevation`, `sharingRepairFailed`, `sharingFailed`, `unknown`) and
the system's `detail` text. `start()` does
not throw on a failure; it throws `StateError` before `configure()`, and
`configure()` throws `ArgumentError` on a name over 32 bytes of UTF-8 or a
password outside 8 to 63 printable ASCII characters. A `configure()` that
changes nothing does nothing; a change while the hotspot is on restarts the
access point.

`HotspotCapability.unsupportedReason` is a code, not text: `noAdapter` (no Wi-Fi
adapter with access point support), `cannotHost` (the adapter, a policy or the
edition of Windows does not allow one), `noConnection` (no connection with
internet access to share), `platform` or `unknown`.

Calls are serialized: a `stop()` during a `start()` runs after it.

## Which connection is shared

The hotspot shares the PC's physical connection, Wi-Fi or Ethernet with
internet access (the one with the lowest metric), never the tunnel adapter.
Windows turns a hotspot off within a second of the adapter it shares going
away, and the tunnel's adapter is recreated on every disconnect and server
switch.

## What Windows keeps

* There is one Mobile hotspot configuration, and `start()` overwrites it. The
  user's own name, password, band and no-connections timeout are saved
  (encrypted for the current user, in `%LOCALAPPDATA%\glitch_vpn_core`) before
  the first overwrite and put back by `stop()`.
* The no-connections timeout is off while the hotspot runs, so it does not
  switch itself off with no device on it.
* The hotspot outlives the process that started it. `reconcile()`, called when
  the app starts and before `configure()`, adopts one that is running, and when
  none runs but the user's settings are still saved from one that did, puts
  them back, as `stop()` does. `start()` keeps a running hotspot that has the
  wanted configuration and restarts one that has another.
* At most eight devices can join. WPA3 and an open network are not available.
* The password is stored by Windows readable to any local user; it is not a
  secret from the machine.
* Two radios on one channel can fail together: a 5 GHz hotspot beside a 5 GHz
  station may not start (`wifiOff`). Try 2.4 GHz.

## Devices

`clients` lists the connected devices (name, MAC, IPv4) and, after them, blocked
devices that are not connected, with the name and address they had when last
seen. It is read every three seconds while the hotspot is on, and by
`refreshClients()`. Windows lists the devices ICS has leased an address to, so
a device with a static address is never listed and cannot be blocked by
address.

## The core's sharing

What the clients' traffic does is the core's, and the plugin tells it. `start()`
first calls the core's `PrepareHotspot`, which repairs a stale Windows sharing
state (a refusal ends in `coreUnreachable`, `sharingNeedsElevation`,
`sharingRepairFailed` or `unsupported`; a hotspot that already runs is kept).
Then WinRT starts the hotspot. Only once WinRT reports it on does the plugin
send `SetHotspotSharing` with the whole state,
`{on, blockWhileTunnelDown, blockedClients}`. Nothing is sent before the first
start. Both calls go through the core's own exports, so in service mode they
reach the service over its pipe.

`on` follows WinRT's operational state and nothing else. `on: false` goes out
only once WinRT confirms the hotspot off: a stop that turned it off (even when
restoring the user's settings then failed), one turned off from Windows'
settings (the plugin polls the state every three seconds while it is on). A
reconfigure that restarts the access point is never told as `false`: the whole
state goes again as `on: true`, so the core keeps blocking meanwhile, and one
Windows refuses before stopping leaves the hotspot on and the state `on: true`.
A stop whose outcome is unknown leaves what the plugin believed. The state is sent again on every change and whenever the
core may be a new one: `GlitchVpnCore.initialize`, a status port reclaim, every
engine connecting event, and the service reattached event (508). A state the
core did not take is sent again at every poll until it does, whatever the
hotspot is doing. A core that has not taken `on: true` within three polls
(about ten seconds) leaves the hotspot stopped and `failed` (`coreUnreachable`).

The core answers with event 600, kept in `sharing`: the connection ICS shares
(`tunnel`, `wifi`, `none`), whether the clients are blocked, and an error. An
error with `none` while the hotspot is on stops it and ends in `failed`
(`sharingFailed`): a hotspot the core cannot block is not left running.
Nothing restarts the hotspot on the tunnel's profile: Windows turns a hotspot
shared from it off with the tunnel.

`setBlockWhileTunnelDown` (on by default), `blockClient` and `unblockClient`
change the wanted state. At most eight blocked clients are sent, by the IPv4
each was last seen with, listed or not. The Windows Mobile hotspot cannot
disconnect a device, so a blocked device stays joined and its traffic is
dropped. The core is Windows-only here; other platforms answer `unsupported`.
