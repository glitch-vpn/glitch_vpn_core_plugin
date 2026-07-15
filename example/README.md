# glitch_vpn_core example

Test client for the plugin. One screen wires up the whole API: engine
selection (xray / awg / mihomo), routing rules, DNS modes, proxy mode,
split tunneling, pings, geo updates, traffic stats, structured logs and
the connection inspector.

## Run

    flutter run

The config inputs are seeded with dead placeholders. Paste your own
`vless://` or `ss://` link, or an AmneziaWG INI, before connecting.
Several links separated by newlines make a balancer.

For AmneziaWG supported link format. Encode INI config into base64. Fragment (string at the end of link with `#`) can be added as server name. `awg://<base64(INI config)>#<server name>`.

On Windows, TUN mode asks for elevation on connect (or uses the installed
`GlitchVpnCore` service when present); proxy mode needs neither.
