# Benchmarks

What the tunnel costs an app that embeds it. Numbers are from the native core;
the Dart layer is a thin wrapper over the FFI and does not move them.

## App size

The plugin bundles one native library per platform. Full composition
(xray + awg + mihomo):

| Platform | Bundled |
|---|---|
| Android arm64 | 63.1 MB `.so` per ABI |
| Windows amd64 | 59.8 MB `.dll` + 0.4 MB `wintun.dll` |
| Linux amd64 | 69.4 MB `.so` |

An APK that carries arm64 and x86_64 pays for both unless you split per ABI.
Play Store delivery does that automatically; a bare APK does not.

This is the number to attack if size matters: a build with fewer engines is
much smaller (awg alone is 11.2 MB, xray alone 32.6 MB against 59.8 MB for all
three). See [Engine
Compositions](https://github.com/glitch-vpn/libglitchcore/wiki/Engine-Compositions)
— it needs a custom core build and a pin change, not a plugin change.

## Memory and startup

Loopback session in proxy mode, measured from the engine's own stats three
seconds after connect:

| Engine | Connect → connected | Go heap | Process RSS |
|---|---|---|---|
| xray | ~50 ms | 12.4 MB | 32.6 MB |
| mihomo | ~50 ms | 12.7 MB | 33.7 MB |

Read them as an order of magnitude:

* The heap column is the engine's own footprint; RSS is the whole host
  process. In a Flutter app the Dart VM and the engine share that process, so
  expect the tunnel to add roughly the heap figure plus the runtime the Go
  library brings with it, not to replace your app's memory.
* The connect time is a loopback handshake with no network in it. Against a
  real exit the round trip to that server dominates; this measures the
  library's own startup, which is what you can actually influence.
* Windows 11, Go 1.26.4, full composition. Method and how to retake them:
  [core Benchmarks](https://github.com/glitch-vpn/libglitchcore/wiki/Benchmarks).

## Throughput

Not published: it is set by the server and the path, not by this plugin. If
you need a number for capacity planning, measure through `connect(proxyPort:)`
against your own exit — that takes the platform TUN stack out of the picture
and leaves the engine.
