# Code style

How this plugin solves the problems it keeps running into. Every rule here was
derived from code already in the tree, and every example is a real one,
simplified.

`CLAUDE.md` is the rulebook — the core contract, the hard rules, the gate.
This file is narrower: given that a thing is allowed, it says which of the
several working ways to write it this repository has settled on. Sections are
numbered so a review finding can point at one.

---

## 1. Channels

One channel per event family, all shaped like `VpnStatusChannel`:

```dart
class VpnServerChannel {
  VpnServerChannel._();
  static final instance = VpnServerChannel._();

  final _ctrl = StreamController<VpnServerSelection>.broadcast(sync: true);
  final _notifier = ValueNotifier<VpnServerSelection?>(null);
  VpnServerSelection? _last;

  Stream<VpnServerSelection> get stream => _ctrl.stream;
  ValueListenable<VpnServerSelection?> get listenable => _notifier;
  VpnServerSelection? get value => _last;

  void emit(VpnServerSelection s) { _last = s; _notifier.value = s; _ctrl.add(s); }
  void reset() { _last = null; _notifier.value = null; }
}
```

- Private constructor + `static final instance`. Broadcast controller,
  `sync: true`.
- Session-scoped channels hold a **nullable** value (null = no session data)
  and expose `reset()`; process-scoped ones (status) hold a non-null default.
- Dedupe belongs to whoever knows the semantics: status dedupes in `emit`
  (same enum + reason), core-fed channels rely on the core's payload dedupe
  and re-emit whatever arrives — a replay must reach new listeners.
- The facade re-exports each channel as the triple `onXxxChanged` (stream) +
  `xxxListenable` + `xxx` (last value). A channel reachable only through the
  singleton, or a facade getter without its stream twin, is drift.

## 2. Event models

Models for core payloads parse with a static `tryParse` and never throw:

```dart
static VpnConnEvent? tryParse(String json) {
  try {
    final m = jsonDecode(json);
    if (m is! Map) return null;
    String s(String k) => (m[k] ?? '').toString();
    return VpnConnEvent(engine: s('engine'), ..., at: DateTime.now());
  } catch (_) {
    return null;
  }
}
```

- `is! Map` guard first; per-field defaults (`as int? ?? 0`, `(m[k] ??
  '').toString()`); optional strings normalize empty → null when null carries
  meaning.
- Timestamps are stamped at parse (`DateTime.now()`), not carried in the
  payload.
- Fields are final, constructors const where possible. No `fromJson` that
  throws — this boundary receives whatever a future core version sends.
- Partial results use the core's sentinel error strings (`'disabled'`,
  `'unsupported'`) surfaced as semantic getters (`VpnExternalIp.unsupported`)
  — a shared vocabulary with the core; new partial-result models reuse these
  literals, never invent parallel ones.

## 3. Event dispatch

`_onCoreEvent` is the single switch over `GlitchVpnCoreFfiEventCode`. A new
code lands in three places in this repo: the enum value, the `fromCode` case,
the `_onCoreEvent` case. Unknown codes fall back to `logError` — never throw.
Handler bodies stay thin: parse → channel emit; state transitions go through
`VpnStatusChannel` and the reset helper, not ad-hoc flags.

## 4. `connect()` and opts assembly

- Optional string params default to `''`, not null; numeric/bool tri-states
  are nullable. Guards at the assembly site:

```dart
if (probeUrl.trim().isNotEmpty) opts['probeUrl'] = probeUrl.trim();
if (livenessIntervalSec != null) opts['livenessIntervalSec'] = '$livenessIntervalSec';
```

- Opts keys are the core's camelCase names, verbatim. The comment on a param
  states the value domain and default (`// empty → engine default`), nothing
  else.
- A shared helper (`_applyIpResolveOpts` style) owns any opt group that all
  three engine paths need — three inline copies is how they diverge.
- Validation that saves a doomed connect happens before dispatch and emits
  `VpnStatus.error` with a readable reason (see the `balancerStrategy` and
  engine-availability checks).

## 5. Errors and status

- Failure paths emit `VpnStatus.error` with a `reason` string, then throw
  `PlatformException(code: 'UPPER_SNAKE')` when the caller must see it.
- Platform-channel calls that are best-effort (notifications, pickers) wrap
  in `try {} catch (_) {}` — a missing platform impl must not break connect.
- Status transitions are only emitted through `VpnStatusChannel.instance` —
  no direct notifier writes.

## 6. Dartdoc and comments

- Public API dartdoc is one or two lines of **contract**: null semantics,
  units, when the stream fires, platform limits. Not a restatement of the
  name.
- Internals follow the silence rule: a comment carries a WHY or a trap
  (`// awg is L3 - only a plain resolver applies`), or it does not exist.
- No comments on one-line getters and trivial functions.

## 7. Tests

- Pure Dart only — nothing in `test/` loads the native library or touches
  platform channels. End-to-end lives in the core repo's smoke suite.
- Every `tryParse` model gets: a full payload, a minimal payload (defaults
  exercised), and garbage (`'not json'`, wrong JSON type) expecting null.
- Channel tests assert the cache/reset cycle (`value`, `listenable.value`,
  after `reset()` both null).
- Test names are behaviour sentences; `group` carries the subject.

## 8. Example app

- Every public API addition appears in `example/lib/main.dart` the same day —
  a stream renders somewhere, a knob has a control.
- Plain Material widgets, `ValueListenableBuilder` over the channel
  listenables, monospace for payload-ish text. No design tokens, no theming
  work — this is a test client, not the product.
- Sample configs in the example are placeholders, never real servers or live
  credentials.
