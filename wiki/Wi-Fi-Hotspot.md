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
`operationInProgress`, `startFailed`, `configureFailed`, `bandUnsupported`,
`invalidCredentials`, `unknown`) and the system's `detail` text. `start()` does
not throw on a failure; it throws `StateError` before `configure()`, and
`configure()` throws `ArgumentError` on a name over 32 bytes of UTF-8 or a
password outside 8 to 63 printable ASCII characters.

Calls are serialized: a `stop()` during a `start()` runs after it.

## Which connection is shared

The hotspot shares the PC's physical connection, Wi-Fi or Ethernet with
internet access (the one with the lowest metric), never the tunnel adapter.
Windows turns a hotspot off within a second of the adapter it shares going
away, and the tunnel's adapter is recreated on every disconnect and server
switch. `restartOn(HotspotConnection.tunnel)` restarts the hotspot on the
tunnel adapter's profile, and `restartOn(HotspotConnection.wifi)` back on the
physical one; the access point is down for several seconds each time.

## What Windows keeps

* There is one Mobile hotspot configuration, and `start()` overwrites it. The
  user's own name, password, band and no-connections timeout are saved
  (encrypted for the current user, in `%LOCALAPPDATA%\glitch_vpn_core`) before
  the first overwrite and put back by `stop()`.
* The no-connections timeout is off while the hotspot runs, so it does not
  switch itself off with no device on it.
* The hotspot outlives the process that started it. `reconcile()` adopts one
  that is running; `start()` keeps a running hotspot that has the wanted
  configuration and restarts one that has another.
* At most eight devices can join. WPA3 and an open network are not available.
* The password is stored by Windows readable to any local user; it is not a
  secret from the machine.
* Two radios on one channel can fail together: a 5 GHz hotspot beside a 5 GHz
  station may not start (`wifiOff`). Try 2.4 GHz.

## Devices

`clients` lists the connected devices (name, MAC, IPv4) and, after them, blocked
devices that are not connected. It is read every three seconds while the
hotspot is on, and by `refreshClients()`. Windows lists the devices ICS has
leased an address to, so a device with a static address may be missing.

## The core's sharing

What the clients' traffic does is the core's, and the plugin tells it. `start()`
first calls the core's `PrepareHotspot`, which repairs a stale Windows sharing
state (it answers a failure the hotspot reports as `sharingNeedsElevation`,
`sharingRepairFailed`, `coreUnreachable` or `unsupported`; a hotspot that
already runs is kept). Then WinRT starts the hotspot. Only once WinRT reports it
on does the plugin send `SetHotspotSharing` with the whole state,
`{on, blockWhileTunnelDown, blockedClients}`, and it sends it again on every
change, after the core is attached again (`GlitchVpnCore.initialize`, a status
port reclaim), and with `on: false` as soon as the hotspot is off for any cause,
including one turned off from Windows' settings (the plugin polls the state
every three seconds while it is on). Nothing is sent before the first start.
Both calls go through the core's own exports, so in service mode they reach the
service over its pipe.

The core answers with event 600, kept in `sharing`: the connection ICS shares
(`tunnel`, `wifi`, `none`), whether the clients are blocked, an error, and a
connection to restart the hotspot on. An error with `none` while the hotspot is
on stops it and ends in `failed` (`sharingFailed`): a hotspot the core cannot
block is not left running. A restart request restarts the hotspot on that
connection, at most once every 30 seconds.

`setBlockWhileTunnelDown` (on by default), `blockClient` and `unblockClient`
change the wanted state. At most eight blocked clients are sent, by IPv4. The
Windows Mobile hotspot cannot disconnect a device, so a blocked device stays
joined and its traffic is dropped. The core is Windows-only here; other
platforms answer `unsupported`.
