# Bottlenecks

What the plugin does not do, and the behaviour that surprises people. Engine
internals live in the [core's
wiki](https://github.com/glitch-vpn/libglitchcore/wiki/Bottlenecks);
this page is what matters from Dart.

## Platforms

| | Android | Windows | Linux | iOS / macOS |
|---|---|---|---|---|
| Engines | xray, awg, mihomo | xray, awg, mihomo | xray, awg, mihomo | — |
| Data path | VpnService TUN | Wintun or system service | TUN | none |
| Split tunneling | per app | per process | per process | none |

iOS and macOS are stubs: the Dart API compiles, the platform side does
nothing. A Network Extension is a different data path than the one here.

## One engine at a time, and only through connect

Switching engines means disconnecting first — a start against a live different
engine is refused. Routing and DNS reach the engine only through `connect()`;
changing a rule means reconnecting. There is no live-update path, deliberately.

## awg ignores most of the config

`VpnRouting`, `VpnDns.hosts`, `VpnDns.directServers`, `domainStrategy`,
fingerprints, Mux and proxy mode do not apply to AmneziaWG: it is an L3 tunnel
that takes one plain resolver. `balancerStrategy`, the probe URL, liveness and
external-IP resolution do apply. `connect()` rejects `proxyPort` on awg rather
than pretending.

## Geo databases are your job

Nothing is bundled and nothing is downloaded, by design — the plugin used to
own a downloader and no longer does.

* Empty `geoAssetsDir` falls back to the engine default: beside the core binary
  on desktop, **nothing on Android**. Geo rules on Android need the path.
* A path that is not absolute *for the running platform* is rejected before
  dispatch, because the core would ignore it and quietly keep the default.
* mihomo validates a .dat by loading its `cn` list; a trimmed file that xray
  accepts can fail there. The connect fails with the file intact.
* mihomo memoises geo matchers per directory: overwriting the files in place
  and reconnecting keeps the old data until the process restarts. Write a new
  directory per version.
* The Windows service reads the directory as LocalSystem — keep it somewhere
  that account can reach (ProgramData, not a mapped drive or a UNC share).

## DNS behaviour that is not obvious

* `domainStrategy` other than `asis` makes xray resolve domain-form requests
  for routing, and under fake-ip those lookups go out through the direct
  outbound in the clear. It buys IP-rule matching for domain traffic and costs
  the privacy fake-ip was giving you.
* `VpnDns.hosts` keys may carry xray matcher prefixes (`domain:`, `geosite:`);
  mihomo ignores prefixed keys. An entry with several values keeps only IPs.
  A hosts entry also opts that name out of fake-ip.
* `VpnDns.directServers` covers every direct dial in fake-ip mode on both
  engines. In xray's normal mode it falls back to scoping by your direct
  **domain** rules, so a direct list of only `geoip:`/CIDR entries leaves
  nothing to scope; `direct-all` inverts the split instead.
* xray has no DoT: `tls://` resolvers are dropped with a log line.

## Sniffing and fake-ip

With `dns: normal` and sniffing off, domain rules stop matching flows that
bypass the plugin's DNS (in-app DoH, hardcoded IPs) — there is no name to match
on. fake-ip is what keeps domain routing reliable; sniffing is the recovery
path for what escapes it.

## Per-process rules are tier-blind on desktop

`process:` matchers are applied by the desktop dialer from a flat map, so tier
order does not reach them: block beats direct beats proxy globally. Domain and
IP matchers honour tier order.

## Version pinning

The plugin talks to a pinned core release; new options exist only in the core
that ships them. If you fork or bump, move `libglitchcore_version` and
`libglitchcore_sha256` together — a plugin that emits keys an older core does
not read will have those settings silently ignored.
