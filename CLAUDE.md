# CLAUDE.md

Rules for agents working in this repository. These override default behaviour.

## 1. What this project is

glitch_vpn_core is a Flutter FFI plugin around the
[libglitchcore](https://github.com/glitch-vpn/libglitchcore) Go core. One Dart
API drives the xray / awg / mihomo engines on Android, Windows and Linux. The
app repo (`Glitch-VPN/mobile`) consumes it as a pinned git dependency.

This plugin is about **connectivity, not UI**. The `example/` app is a test
client that must exercise the whole API; it uses plain Material and no design
system on purpose.

The local checkout of the core usually sits next to this repo at
`../libglitchcore` — read it when a question is about what the core actually
does.

### Decisions already made — do not re-litigate

| Topic | Decision |
|---|---|
| Native provisioning | `flutter build` downloads the core release pinned by `libglitchcore_version` + `libglitchcore_sha256` in `pubspec.yaml` (`android/build.gradle`, `windows/CMakeLists.txt`). Unreleased core: `LIBGLITCHCORE_LOCAL=/path/to/build_output/ffi` |
| FFI bindings | `lib/src/bindings_generated.dart` is ffigen output, committed; regenerated only when the core header changes (CI fails on drift). A PreToolUse hook blocks direct edits |
| Core communication | Events over the status port + `Opts` map on `EngineStart`. New core knobs should not need new bindings |
| Public API | Files under `lib/` imported directly — there is no barrel file. The facade is `GlitchVpnCore.instance` plus channel singletons |
| Transitions | connect/disconnect are serialized by `_AsyncMutex`; no additional queues |
| Language | Everything in the repo is **English** (code, comments, commits, docs) |
| Docs tone | Dry, human, no AI-writing tells, no product branding — technical names only |
| License | Plugin MIT; loaded core binaries are a separate work (GPL for xray/mihomo compositions) |

## 2. Hard rules

1. **Never edit `lib/src/bindings_generated.dart`.** It is generated; the fix
   is a new pinned header + `dart run ffigen`.
2. **The core contract is mirrored, not improvised.** Event codes in
   `GlitchVpnCoreFfiEventCode` match `internal/core/controller.go` consts by
   value; opts keys match the core's `optsFromRequest`; payload field names
   match the core structs' json tags. When either side changes, both repos
   change in the same working session.
3. **Event parsing never throws.** Payloads cross a process/language boundary
   — models expose `tryParse(String) → T?` and the dispatcher drops nulls.
   A malformed event must not kill the isolate.
4. **Session-scoped channels reset on session end.** Whatever is cached for
   the UI (status, server selection, external IP) is cleared on
   disconnect/error and at the start of a new connect, or a new session shows
   the previous session's data.
5. **No secrets in logs.** Share links and configs carry credentials — never
   `debugPrint` a config, never embed one in an exception message or a
   notification.
6. **An engine-agnostic `connect()` option reaches all three engine paths.**
   `_connectXrayCore`, `_connectAwgCore` and `_connectMihomoCore` assemble
   opts separately; a param added to one and silently dropped in another is
   how awg lost `balancerStrategy`.
7. **A feature is not done without the example app.** Core event → Dart API →
   example UI, one change. The owner verifies hands-on; an API without
   example plumbing is not checkable.
8. **Comments: prefer silence.** Public API dartdoc carries contracts (null
   semantics, units, when a stream fires); internals get a comment only for a
   non-obvious WHY or a trap. Never restate code.
9. **Report honestly.** If `flutter test` fails, say so with output. Never
   claim a check passed without running it.

## 3. Repository layout

```
lib/
  glitch_vpn_core.dart        # facade: connect/disconnect, opts assembly,
                              # _onCoreEvent dispatch, platform helpers
  glitch_vpn_core_ffi.dart    # FFI wrapper + GlitchVpnCoreFfiEventCode
  src/bindings_generated.dart # ffigen output - do not edit
  vpn_status_channel.dart     # VpnStatus stream/listenable
  vpn_stats_channel.dart      # traffic/memory/liveness stats
  vpn_logs_channel.dart       # structured logs
  vpn_conn_channel.dart       # connection inspector (opt-in)
  vpn_server_channel.dart     # connected server / balancer pick (302)
  vpn_ip_channel.dart         # external IPv4/IPv6 (303)
android/  windows/            # platform glue: VpnService/TUN, UAC/service
linux/ ios/ macos/            # stubs (Linux engines still run via FFI)
example/                      # full-API test client
test/                         # pure Dart unit tests (no native library)
wiki/                         # user-facing docs (GitHub wiki page names);
                              # README stays short and links here
```

## 4. Core contract essentials

- Event codes: 300 stats, 301 statsError, 302 server, 303 ip, 400/401 logs,
  402 conn, 500–507 engine lifecycle. Payload shapes live in the core's
  `CLAUDE.md` §4 — that table is canonical.
- On reattach (hot restart, app relaunch over a live tunnel, Windows service)
  the core **replays** connected + 302 + 303 + stats when the status port is
  registered — `initialize()` is all an app needs to restore state.
- Proxy mode (`proxyPort`) has no TUN and no elevation; awg rejects it.
- awg ignores routing/DNS config apart from one plain resolver; validate
  `balancerStrategy`/`fingerprint`/`domainStrategy` via
  `balancerStrategiesFor` / `fingerprintsFor` / `domainStrategiesFor` before
  connecting.
- Geo assets are the app's responsibility: `connect(geoAssetsDir:)` points the
  engine at a caller-owned dir with geoip.dat/geosite.dat; the plugin neither
  downloads nor caches them, and `initialize()` performs no network I/O.
- Android `prepareTunnel` returns a TUN fd; the whole app package is excluded
  from the VPN (`addDisallowedApplication`), so in-app HTTP does **not**
  traverse the tunnel — external-IP resolution happens core-side for this
  reason.
- Unit tests never load the native library; anything end-to-end lives in the
  core repo's `internal/smoke`.

## 5. Definition of done

1. `flutter analyze` — clean.
2. `flutter test` — green (new models/parsers ship with tests, including a
   garbage-input case).
3. Example app exercises the new surface.
4. If the core changed: the core repo's own gate passed there (tag-matrix
   tests + smoke), and the contract mirror (§2.2) is intact.
5. Preparing a commit includes running the `style-reviewer` and
   `contract-reviewer` agents over the diff.

## 6. Commits and releases

- Conventional commits, English, imperative. Never commit or push unless
  asked.
- Consuming a new core: tag `v*` in libglitchcore → CI release → bump
  `libglitchcore_version` + `libglitchcore_sha256` **together** in
  `pubspec.yaml`; regenerate bindings only if the header changed.

## 7. Commands

```bash
flutter pub get
flutter analyze
flutter test
cd example && flutter run -d windows        # live client against a real core

dart run ffigen --config ffigen.yaml        # only after a header change;
                                            # needs dart_api*.h next to
                                            # build/libglitchcore.h
                                            # (wiki/For-Maintainers.md)

LIBGLITCHCORE_LOCAL=/path/to/libglitchcore/build_output/ffi flutter build ...
```
