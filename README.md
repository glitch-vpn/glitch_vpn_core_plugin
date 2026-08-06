# glitch_vpn_core

[![CI](https://github.com/glitch-vpn/glitch_vpn_core_plugin/actions/workflows/ci.yml/badge.svg)](https://github.com/glitch-vpn/glitch_vpn_core_plugin/actions/workflows/ci.yml)

A Flutter plugin for building VPN clients. You write the app; the plugin brings
up the tunnel, routes traffic and streams back what a UI needs to show — status,
speed, the server you are on, the exit IP as seen from outside.

One Dart API drives three protocol engines — **Xray** (VLESS, VMess, Trojan,
Shadowsocks), **AmneziaWG** and **mihomo** (Hysteria2) — on Android, Windows and
Linux. Switching engines is a parameter, not a rewrite.

```dart
await GlitchVpnCore.initialize();
GlitchVpnCore.instance.onStatusChanged.listen((s) => print(s.status));

await GlitchVpnCore.instance.connect(
  engine: VpnEngine.xray,
  config: 'vless://…',
);
```

Ordered routing tiers, fake-ip DNS, split tunneling, balancer pools, a loopback
proxy mode that needs no admin rights, and session restore when the app
relaunches over a live tunnel — all through the same call.

## Documentation

* **[Getting Started](https://github.com/glitch-vpn/glitch_vpn_core_plugin/wiki/Getting-Started)** — install, connect, and the
  platform setup each OS needs
* **[Bottlenecks](https://github.com/glitch-vpn/glitch_vpn_core_plugin/wiki/Bottlenecks)** — limits and behaviour worth knowing
  before you build a screen around it
* **[Benchmarks](https://github.com/glitch-vpn/glitch_vpn_core_plugin/wiki/Benchmarks)** — app size, memory, startup
* **[For Maintainers](https://github.com/glitch-vpn/glitch_vpn_core_plugin/wiki/For-Maintainers)** — working on the plugin itself

The app under `example/` exercises the whole API and doubles as a test client.

## Contributing

Help is most useful on iOS/macOS support, on split tunneling and per-process
routing across platforms, and on testing the routing and DNS paths — the places
where a wrong rule is a leak rather than a bug report.

`flutter test` needs no native library and runs anywhere; the example app is
the fastest way to see a change work end to end. What we ask of a change is in
[For Maintainers](https://github.com/glitch-vpn/glitch_vpn_core_plugin/wiki/For-Maintainers), including how we work with LLM
assistance — openly, and held to the same gate as anything else.

## License

Plugin: MIT ([LICENSE](LICENSE)). The loaded core binaries are a separate work —
compositions containing xray or mihomo are GPL-3.0, an awg-only build is
permissive. See the [core repo](https://github.com/glitch-vpn/libglitchcore) for
per-composition attribution.
