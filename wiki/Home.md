# glitch_vpn_core

A Flutter plugin for building VPN clients. You write the app; the plugin
brings up the tunnel, routes traffic and streams back everything a UI needs to
show — status, speed, the server you are on, the exit IP.

One Dart API drives three protocol engines — Xray (VLESS, VMess, Trojan,
Shadowsocks), AmneziaWG and mihomo (Hysteria2) — on Android, Windows and
Linux. Which engine is running is a parameter, not a rewrite.

```dart
await GlitchVpnCore.initialize();
GlitchVpnCore.instance.onStatusChanged.listen((s) => print(s.status));

await GlitchVpnCore.instance.connect(
  engine: VpnEngine.xray,
  config: 'vless://…',
);
```

## Pages

* **[Getting Started](Getting-Started)** — from an empty app to a working
  tunnel, including the platform setup each OS needs.
* **[Bottlenecks](Bottlenecks)** — platform limits and behaviour worth
  knowing before you design a screen around it.
* **[Benchmarks](Benchmarks)** — what the tunnel costs in app size, memory
  and startup.
* **[For Maintainers](For-Maintainers)** — working on the plugin itself.

The native side is [libglitchcore](https://github.com/glitch-vpn/libglitchcore);
you do not have to think about it to use this plugin, but its wiki is where the
engine-level details live.
