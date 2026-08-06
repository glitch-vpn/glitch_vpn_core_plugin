# For Maintainers

## Environment

Flutter (stable, matching `environment.sdk` in `pubspec.yaml`) plus the usual
per-platform toolchain — Visual Studio with the C++ workload for Windows,
Android SDK/NDK for Android. Nothing else: the native library is downloaded
from the pinned core release at build time.

```sh
flutter pub get
flutter analyze
flutter test                                  # pure Dart, no native library
cd example && flutter run -d windows          # live client against a real core
```

Working against an unreleased core, build the core first and point the plugin
at it:

```powershell
$env:LIBGLITCHCORE_LOCAL = "C:\path\to\libglitchcore\build_output\ffi"
flutter run -d windows
```

Use an absolute, native path. A relative or POSIX-style one gets baked into
the generated CMake config and then every later build fails at the install
step with a wall of `MSB3073` — run
`cmake -DBUILD_TYPE=Debug -P cmake_install.cmake` in
`example/build/windows/x64` to see the real reason. The other cause of that
same wall is a still-running example (debug builds relaunch elevated, and
`flutter run` loses track of that child): `taskkill /F /IM
glitch_vpn_core_example.exe` from an elevated shell.

## The gate before a commit

1. `flutter analyze` — clean.
2. `flutter test` — green. New parsers ship with a full payload, a minimal one
   and a garbage case.
3. The example app exercises the new surface. A knob without example plumbing
   cannot be checked by hand, so it is not done.
4. If the core changed too: its own gate passed there, and the contract mirror
   is intact — opts keys, `dnsConfig` fields and event codes match the core
   source, not memory.
5. The two review agents in `.claude/agents/` over the diff.

## How the pieces fit

`lib/glitch_vpn_core.dart` is the facade: `connect`/`disconnect`, opts
assembly, event dispatch, platform helpers. Each stream lives in its own
channel file (`vpn_status_channel.dart`, `vpn_stats_channel.dart`, …) with the
same anatomy, documented in `docs/code-style.md`.
`lib/src/bindings_generated.dart` is ffigen output — never edited by hand; a
header change means a new pinned core and `dart run ffigen --config
ffigen.yaml`, and CI fails on drift. ffigen needs `libglitchcore.h` at
`build/libglitchcore.h` (take it from the release archive or a local core
build) plus the Dart SDK headers beside it — copy `dart_api_dl.h`,
`dart_api.h` and `dart_native_api.h` from
`$FLUTTER_ROOT/bin/cache/dart-sdk/include`, because the core header includes
them.

Anything session-scoped that the UI can see (server selection, external IP)
resets on disconnect, on error and at the start of a new connect. Missing that
is how a new session shows the previous one's data.

## Bumping the core

Tag the core, let its CI publish the release, then move
`libglitchcore_version` **and** `libglitchcore_sha256` in `pubspec.yaml` in the
same commit. New opts keys only work against the core that reads them; shipping
the plugin first means those settings are silently ignored.

## Working with LLM assistance

We use it deliberately and the repository is set up for it: `CLAUDE.md` holds
the hard rules and the settled decisions, `docs/code-style.md` holds the idioms
to copy instead of inventing, and `.claude/agents/` holds two reviewers — one
for style drift, one for the plugin's contracts with the core. They run over
the diff before a commit.

The gate above decides whether a change is good, whoever wrote it. Human PRs
are held to exactly the same bar; telling us what you ran ("analyze and tests
green, example exercised on Windows") is worth more than a description of the
diff.
