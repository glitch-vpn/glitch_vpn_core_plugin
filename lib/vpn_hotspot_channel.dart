import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'glitch_vpn_core_ffi.dart';

/// Where a hotspot stands. [starting] covers a start and a reconfiguration.
enum HotspotState { off, starting, on, failed }

/// Wi-Fi band of the access point. [auto] is always offered; the others only
/// where [HotspotCapability.bands] lists them.
enum HotspotBand {
  auto('auto'),
  ghz2_4('2.4'),
  ghz5('5');

  const HotspotBand(this.wire);
  final String wire;

  static HotspotBand? fromWire(String? wire) {
    for (final band in values) {
      if (band.wire == wire) return band;
    }
    return null;
  }
}

enum HotspotFailureReason {
  /// The system cannot host a hotspot; [HotspotFailure.detail] says why.
  unsupported,

  /// No Wi-Fi or Ethernet connection with internet access to share.
  noConnection,
  wifiOff,
  operationInProgress,
  startFailed,
  configureFailed,
  bandUnsupported,
  invalidCredentials,

  /// A stop that Windows refused or could not complete.
  stopFailed,

  /// The core did not answer: a transport or timeout failure, or no core.
  coreUnreachable,

  /// Windows' sharing state is stale and repairing it needs administrator
  /// rights the core does not have.
  sharingNeedsElevation,
  sharingRepairFailed,

  /// The core cannot block the hotspot's clients while the tunnel is down, so
  /// the hotspot was stopped; [HotspotFailure.detail] carries its error.
  sharingFailed,
  unknown;

  static HotspotFailureReason parse(String? code) {
    for (final reason in values) {
      if (reason.name == code) return reason;
    }
    return unknown;
  }
}

class HotspotFailure {
  final HotspotFailureReason reason;

  /// Diagnostic text from the system; not for display as it is.
  final String detail;
  const HotspotFailure(this.reason, [this.detail = '']);

  @override
  String toString() => 'HotspotFailure(${reason.name}: $detail)';
}

class HotspotUpdate {
  final HotspotState state;

  /// Set exactly when [state] is [HotspotState.failed].
  final HotspotFailure? failure;
  final DateTime at;
  const HotspotUpdate(this.state, {this.failure, required this.at});
}

/// One device on the hotspot, or a blocked device that is not connected now
/// ([ipv4] and [name] then come from the last time it was seen, or are null).
class HotspotClient {
  final String? name;

  /// Upper case, colon-separated.
  final String mac;
  final String? ipv4;
  final bool blocked;
  const HotspotClient({
    required this.mac,
    this.name,
    this.ipv4,
    this.blocked = false,
  });

  HotspotClient copyWith({bool? blocked}) => HotspotClient(
    mac: mac,
    name: name,
    ipv4: ipv4,
    blocked: blocked ?? this.blocked,
  );

  @override
  bool operator ==(Object other) =>
      other is HotspotClient &&
      other.mac == mac &&
      other.name == name &&
      other.ipv4 == ipv4 &&
      other.blocked == blocked;

  @override
  int get hashCode => Object.hash(mac, name, ipv4, blocked);

  /// Parses one entry of the native client list; null when it has no MAC.
  static HotspotClient? tryParse(Object? raw) {
    if (raw is! Map) return null;
    final mac = normalizeMac((raw['mac'] ?? '').toString());
    if (mac == null) return null;
    String? opt(String key) {
      final v = (raw[key] ?? '').toString();
      return v.isEmpty ? null : v;
    }

    return HotspotClient(mac: mac, name: opt('name'), ipv4: opt('ipv4'));
  }

  /// "aa-bb-cc-dd-ee-ff", "AABBCCDDEEFF" and "aa:bb:…" all become
  /// "AA:BB:CC:DD:EE:FF"; null when the text is not six bytes of hex.
  static String? normalizeMac(String text) {
    final hex = text.replaceAll(RegExp(r'[^0-9A-Fa-f]'), '').toUpperCase();
    if (hex.length != 12) return null;
    return [for (var i = 0; i < 12; i += 2) hex.substring(i, i + 2)].join(':');
  }
}

/// Why the system cannot host a hotspot now.
enum HotspotUnsupportedReason {
  /// No Wi-Fi adapter with access point support.
  noAdapter,

  /// The adapter, a policy or the edition of Windows does not allow one.
  cannotHost,

  /// No Wi-Fi or Ethernet connection with internet access to share.
  noConnection,

  /// This platform has no hotspot.
  platform,
  unknown;

  static HotspotUnsupportedReason parse(String? code) {
    for (final reason in values) {
      if (reason.name == code) return reason;
    }
    return unknown;
  }
}

class HotspotCapability {
  final bool supported;

  /// Why the system cannot host a hotspot; null when it can.
  final HotspotUnsupportedReason? unsupportedReason;

  /// The bands the adapter offers; empty when unsupported.
  final List<HotspotBand> bands;
  const HotspotCapability({
    required this.supported,
    this.unsupportedReason,
    this.bands = const [],
  });

  static const unavailable = HotspotCapability(
    supported: false,
    unsupportedReason: HotspotUnsupportedReason.platform,
  );

  static HotspotCapability parse(Object? raw) {
    if (raw is! Map) return unavailable;
    if (raw['supported'] != true) {
      return HotspotCapability(
        supported: false,
        unsupportedReason: HotspotUnsupportedReason.parse(
          raw['reason']?.toString(),
        ),
      );
    }
    final bands = raw['bands'];
    return HotspotCapability(
      supported: true,
      bands: [
        if (bands is List)
          for (final b in bands) ?HotspotBand.fromWire(b.toString()),
      ],
    );
  }
}

/// What the hotspot's clients get, as the plugin wants it applied by the
/// core. The whole state travels on every change.
class HotspotSharingWanted {
  final bool on;
  final bool blockWhileTunnelDown;

  /// IPv4 addresses of the blocked devices, each the one it was last seen
  /// with, listed or not.
  final List<String> blockedClients;
  const HotspotSharingWanted({
    required this.on,
    required this.blockWhileTunnelDown,
    required this.blockedClients,
  });

  /// The core's `SetHotspotSharing` payload.
  String toJson() => jsonEncode({
    'on': on,
    'blockWhileTunnelDown': blockWhileTunnelDown,
    'blockedClients': blockedClients,
  });

  @override
  bool operator ==(Object other) =>
      other is HotspotSharingWanted &&
      other.on == on &&
      other.blockWhileTunnelDown == blockWhileTunnelDown &&
      listEquals(other.blockedClients, blockedClients);

  @override
  int get hashCode =>
      Object.hash(on, blockWhileTunnelDown, Object.hashAll(blockedClients));
}

/// The calls the platform answers. Windows implements them with WinRT; any
/// other platform answers `null` (the method is missing).
abstract class HotspotNative {
  Future<Map<Object?, Object?>?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]);
}

class MethodChannelHotspotNative implements HotspotNative {
  const MethodChannelHotspotNative();
  static const _channel = MethodChannel('glitch_vpn_core');

  @override
  Future<Map<Object?, Object?>?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    try {
      return await _channel.invokeMapMethod<Object?, Object?>(
        method,
        arguments,
      );
    } on MissingPluginException {
      return null;
    }
  }
}

/// The core's two hotspot exports. Both answer through the core's own path, so
/// in service mode they reach the service over its pipe.
abstract class HotspotCore {
  /// `PrepareHotspot`: 0 ok, 1 transport or timeout, 3 unsupported, 4 a
  /// hotspot runs, 5 stale and not elevated, 6 repair failed. Can take
  /// minutes.
  Future<int> prepare();

  /// `SetHotspotSharing` with the JSON of [HotspotSharingWanted]: 0 ok, 1
  /// transport, 2 bad request, 3 unsupported.
  Future<int> setSharing(String json);
}

class FfiHotspotCore implements HotspotCore {
  const FfiHotspotCore();

  @override
  Future<int> prepare() => GlitchVpnCoreFfi.prepareHotspot();

  @override
  Future<int> setSharing(String json) =>
      GlitchVpnCoreFfi.setHotspotSharing(json);
}

/// Event 600: what the core did with the hotspot's sharing.
class HotspotSharingEvent {
  /// The connection ICS shares: "tunnel", "wifi", or "none".
  final String shared;

  /// Whether the clients' traffic is blocked (nothing beyond the PC).
  final bool blocked;

  /// Non-empty when the core could not find or settle the hotspot.
  final String error;
  const HotspotSharingEvent({
    required this.shared,
    required this.blocked,
    required this.error,
  });

  /// Lenient: unknown or missing fields take their empty values; null only
  /// when [json] is not an object.
  static HotspotSharingEvent? tryParse(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      return HotspotSharingEvent(
        shared: (m['shared'] ?? 'none').toString(),
        blocked: m['blocked'] == true,
        error: (m['error'] ?? '').toString(),
      );
    } catch (_) {
      return null;
    }
  }
}

/// A Wi-Fi hotspot that shares a connection, on Windows through the Mobile
/// hotspot. The plugin owns its lifecycle, configuration and device list; the
/// core owns what the clients' traffic does (through the tunnel, blocked while
/// it is down) and is told the wanted state through [HotspotCore].
///
/// The order: [start] asks the core to repair Windows' sharing state, starts
/// the hotspot through WinRT, and only once WinRT reports it on sends the core
/// `{on, blockWhileTunnelDown, blockedClients}`. `on` follows WinRT's
/// operational state and nothing else: `on: false` goes out once WinRT
/// confirms the hotspot off, whatever caused it. The state is sent again on
/// every change and when the core comes back ([coreReattached],
/// [coreSessionStarting]); a state the core did not take is sent again every
/// poll until it does. Nothing is sent before the first start.
///
/// The hotspot outlives the process that started it: [reconcile] adopts one
/// that is running, and [start] keeps one that already has the wanted
/// configuration. The user's own Mobile hotspot settings are saved before the
/// first start and put back by [stop].
class VpnHotspotChannel {
  VpnHotspotChannel._(this._native, this._core, this._pollInterval);
  static VpnHotspotChannel _instance = VpnHotspotChannel._(
    const MethodChannelHotspotNative(),
    const FfiHotspotCore(),
    const Duration(seconds: 3),
  );
  static VpnHotspotChannel get instance => _instance;

  /// A channel over another transport and core; a null [pollInterval] turns
  /// the timer off, and [pollOnce] is then the only poll.
  @visibleForTesting
  factory VpnHotspotChannel.withNative(
    HotspotNative native, {
    HotspotCore core = const FfiHotspotCore(),
    Duration? pollInterval,
  }) => VpnHotspotChannel._(native, core, pollInterval);

  /// Makes [channel] the one the facade talks to, for tests of the facade.
  @visibleForTesting
  static set debugInstance(VpnHotspotChannel channel) => _instance = channel;

  /// Polls without the core taking `on: true` before the hotspot is stopped
  /// and reported failed: about ten seconds.
  static const untakenPollLimit = 3;

  /// The core's sharing takes at most this many blocked clients.
  static const maxBlockedClients = 8;

  final HotspotNative _native;
  final HotspotCore _core;
  final Duration? _pollInterval;

  final _ctrl = StreamController<HotspotUpdate>.broadcast(sync: true);
  final _notifier = ValueNotifier<HotspotUpdate>(
    HotspotUpdate(HotspotState.off, at: DateTime.now()),
  );
  final _clientsNotifier = ValueNotifier<List<HotspotClient>>(const []);
  final _capabilityNotifier = ValueNotifier<HotspotCapability?>(null);
  final _sharingNotifier = ValueNotifier<HotspotSharingEvent?>(null);

  String? _ssid;
  String? _passphrase;
  HotspotBand _band = HotspotBand.auto;
  bool _blockWhileTunnelDown = true;
  final _blockedMacs = <String>{};
  final _seen = <String, HotspotClient>{};

  // Every device seen, with the name and address it had last, so a blocked
  // device that is not listed now stays blocked by the address it had.
  final _lastKnown = <String, HotspotClient>{};
  Timer? _timer;
  bool _polling = false;
  Future<void>? _transition;

  // WinRT's word on the hotspot: the one thing `on` follows.
  bool _winrtOn = false;

  // The core's side: the last state asked for, whether the core took it, the
  // asks in flight, and whether it took an `on: true` since the last reattach.
  HotspotSharingWanted? _lastRequested;
  bool _coreTookLast = true;
  bool _coreTookOn = false;
  int _untakenPolls = 0;
  int _inFlight = 0;
  int _requestSequence = 0;
  Future<void> _sharingQueue = Future.value();

  Stream<HotspotUpdate> get stream => _ctrl.stream;
  ValueListenable<HotspotUpdate> get listenable => _notifier;
  HotspotUpdate get value => _notifier.value;

  /// Connected devices, then blocked ones that are not connected.
  ValueListenable<List<HotspotClient>> get clients => _clientsNotifier;

  /// Null until [refreshCapability] has answered.
  ValueListenable<HotspotCapability?> get capability => _capabilityNotifier;

  /// The core's last report on the sharing; null while the hotspot is off.
  ValueListenable<HotspotSharingEvent?> get sharing => _sharingNotifier;

  /// The block applied while the tunnel is down; on until changed.
  bool get blockWhileTunnelDown => _blockWhileTunnelDown;

  Set<String> get blockedMacs => Set.unmodifiable(_blockedMacs);

  /// The state last sent to the core; null before the first start.
  HotspotSharingWanted? get wantedSharing => _lastRequested;

  static bool isValidSsid(String ssid) {
    final bytes = utf8.encode(ssid).length;
    return bytes >= 1 && bytes <= 32;
  }

  /// WPA2: 8 to 63 printable ASCII characters.
  static bool isValidPassphrase(String passphrase) =>
      RegExp(r'^[\x20-\x7e]{8,63}$').hasMatch(passphrase);

  /// Asks the system whether it can host a hotspot now, and with which bands.
  Future<HotspotCapability> refreshCapability() async {
    final answer = HotspotCapability.parse(
      await _native.invoke('hotspotCapability'),
    );
    _capabilityNotifier.value = answer;
    return answer;
  }

  /// Sets the network's name, password and band. Takes effect at the next
  /// [start]; while the hotspot is on or starting a change is applied at
  /// once, which restarts the access point, and a call that changes nothing
  /// does nothing. Throws [ArgumentError] on an invalid name or password.
  Future<void> configure({
    required String ssid,
    required String passphrase,
    HotspotBand band = HotspotBand.auto,
  }) async {
    if (!isValidSsid(ssid)) {
      throw ArgumentError.value(ssid, 'ssid', 'must be 1 to 32 bytes of UTF-8');
    }
    if (!isValidPassphrase(passphrase)) {
      throw ArgumentError.value(
        '(hidden)',
        'passphrase',
        'must be 8 to 63 printable ASCII characters',
      );
    }
    final changed = ssid != _ssid || passphrase != _passphrase || band != _band;
    _ssid = ssid;
    _passphrase = passphrase;
    _band = band;
    if (changed &&
        (value.state == HotspotState.on ||
            value.state == HotspotState.starting)) {
      await start();
    }
  }

  /// Starts the hotspot on the physical connection with the configured name,
  /// password and band. A running hotspot with the same configuration is
  /// kept, one with another is restarted. The outcome is in [listenable];
  /// a failure does not throw. Throws [StateError] before [configure].
  Future<void> start() {
    final ssid = _ssid;
    final passphrase = _passphrase;
    if (ssid == null || passphrase == null) {
      throw StateError('configure() must run before start()');
    }
    final pending = _transition;
    if (pending != null) return pending.then((_) => start());
    return _transition = _run(() async {
      _emit(HotspotState.starting);
      final refusal = await _prepare();
      if (refusal != null) {
        _emit(HotspotState.failed, failure: refusal);
        return;
      }
      final answer = await _native.invoke('hotspotStart', {
        'ssid': ssid,
        'passphrase': passphrase,
        'band': _band.wire,
      });
      await _settle(answer);
    });
  }

  /// Stops the hotspot and puts the user's own Mobile hotspot settings back.
  Future<void> stop() {
    final pending = _transition;
    if (pending != null) return pending.then((_) => stop());
    return _transition = _run(() => _stopNow());
  }

  /// Adopts a hotspot a previous process started and left running; call it
  /// once when the app starts, before [configure]. When none runs but settings
  /// of the user's are still saved from one that did (the process ended, or
  /// Windows turned it off), puts them back, as [stop] does.
  Future<void> reconcile() async {
    final answer = await _native.invoke('hotspotStatus');
    if (answer == null || answer['ours'] != true) return;
    switch (answer['state']) {
      case 'on':
        await _readClients();
        _setWinrtOn(true);
        _emit(HotspotState.on);
        _ensureTimer();
      case 'off':
        if (value.state == HotspotState.off) await stop();
    }
  }

  /// Tells the channel the core was attached again (the app restored, the
  /// status port was reclaimed, the service reconnected). A new core has lost
  /// the per-client filters, so the state is sent again if the hotspot is on.
  void coreReattached() {
    _forgetSent();
    _pushSharing();
  }

  /// Forgets what was sent, so the whole state goes again and must be taken.
  void _forgetSent() {
    _lastRequested = null;
    _coreTookOn = false;
    _untakenPolls = 0;
  }

  void _setWinrtOn(bool on) {
    _winrtOn = on;
    // An ack for an on: true that arrives after the hotspot went off is not
    // the core taking the next one.
    if (!on) {
      _coreTookOn = false;
      _untakenPolls = 0;
    }
  }

  /// The core reports an engine connecting. A service that crashed and came
  /// back has no hotspot state, so the state is sent again if the hotspot is
  /// on, before the tunnel is up. The core turns forwarding off at connecting
  /// and shares again at every tunnel-up, so this adds no extra switch.
  void coreSessionStarting() => coreReattached();

  /// Event 600 from the core. A malformed payload is dropped. An error with no
  /// share stops the hotspot and reports it failed: a hotspot the core cannot
  /// block is not left running.
  void handleCoreEvent(String json) {
    final event = HotspotSharingEvent.tryParse(json);
    if (event == null || !_winrtOn) return;
    _sharingNotifier.value = event;
    if (event.shared == 'none' && event.error.isNotEmpty) {
      unawaited(
        _failSharing(
          HotspotFailure(HotspotFailureReason.sharingFailed, event.error),
        ),
      );
    }
  }

  /// Whether the clients lose the internet while the tunnel is down (true) or
  /// go out directly (false).
  void setBlockWhileTunnelDown(bool block) {
    if (_blockWhileTunnelDown == block) return;
    _blockWhileTunnelDown = block;
    _pushSharing();
  }

  /// Blocks the device with [mac]; it stays listed as blocked, and blocked by
  /// the address it was last seen with while it is not listed.
  void blockClient(String mac) {
    final normalized = HotspotClient.normalizeMac(mac);
    if (normalized == null || !_blockedMacs.add(normalized)) return;
    _publishClients();
    _pushSharing();
  }

  void unblockClient(String mac) {
    final normalized = HotspotClient.normalizeMac(mac);
    if (normalized == null || !_blockedMacs.remove(normalized)) return;
    _publishClients();
    _pushSharing();
  }

  /// Reads the devices now and returns the list [clients] holds.
  Future<List<HotspotClient>> refreshClients() async {
    await _readClients();
    _pushSharing();
    return _clientsNotifier.value;
  }

  /// One poll, run by the timer every few seconds. It sends again a state the
  /// core did not take, whatever the hotspot is doing; and while the hotspot
  /// runs it reads WinRT's state (a hotspot Windows turned off ends here as
  /// off), then the devices, and stops the hotspot when the core has not taken
  /// `on: true` within [untakenPollLimit] polls.
  Future<void> pollOnce() async {
    if (_polling) return;
    _polling = true;
    try {
      final last = _lastRequested;
      if (last != null && !_coreTookLast && _inFlight == 0) _request(last);
      if (_winrtOn && _transition == null) await _watchHotspot();
      if (!_winrtOn && _coreTookLast) _cancelTimer();
    } on PlatformException {
      // The next poll reads again.
    } finally {
      _polling = false;
    }
  }

  Future<void> _watchHotspot() async {
    final status = await _native.invoke('hotspotStatus');
    if (_transition != null || !_winrtOn) return;
    if (status != null && status['state'] == 'off') {
      await stop();
      return;
    }
    await _readClients();
    _pushSharing();
    if (_coreTookOn) {
      _untakenPolls = 0;
    } else if (++_untakenPolls >= untakenPollLimit) {
      await _failSharing(
        const HotspotFailure(HotspotFailureReason.coreUnreachable),
      );
    }
  }

  Future<void> _run(Future<void> Function() body) async {
    try {
      await body();
    } on PlatformException catch (e) {
      _emit(
        HotspotState.failed,
        failure: HotspotFailure(HotspotFailureReason.unknown, e.message ?? ''),
      );
    } finally {
      _transition = null;
    }
  }

  /// `PrepareHotspot` before a start; null when the start may go on. A code of
  /// 4 (a hotspot runs) goes on: the WinRT start keeps one with our
  /// configuration, as [reconcile] does.
  Future<HotspotFailure?> _prepare() async {
    final int code;
    try {
      code = await _core.prepare();
    } catch (e) {
      return HotspotFailure(
        HotspotFailureReason.coreUnreachable,
        e.runtimeType.toString(),
      );
    }
    return switch (code) {
      0 || 4 => null,
      1 => const HotspotFailure(HotspotFailureReason.coreUnreachable),
      3 => const HotspotFailure(HotspotFailureReason.unsupported, 'core'),
      5 => const HotspotFailure(HotspotFailureReason.sharingNeedsElevation),
      6 => const HotspotFailure(HotspotFailureReason.sharingRepairFailed),
      _ => HotspotFailure(
        HotspotFailureReason.unknown,
        'PrepareHotspot returned $code',
      ),
    };
  }

  Future<void> _stopNow({HotspotFailure? failure}) async {
    final answer = await _native.invoke('hotspotStop');
    final stopFailure = _failureOf(answer);
    if (stopFailure != null) {
      // A stop that turned the hotspot off but could not restore the user's
      // settings is off, one that did not turn it off leaves it on, and one
      // whose outcome is not known leaves what the plugin believed.
      _setWinrtOn(
        answer?['running'] is bool ? answer!['running'] as bool : _winrtOn,
      );
      if (!_winrtOn) _clearDevices();
      _emit(HotspotState.failed, failure: failure ?? stopFailure);
      return;
    }
    _setWinrtOn(false);
    _clearDevices();
    if (failure == null) {
      _emit(HotspotState.off);
    } else {
      _emit(HotspotState.failed, failure: failure);
    }
  }

  void _clearDevices() {
    _seen.clear();
    _publishClients();
  }

  /// The core cannot block the clients: a hotspot it cannot block is stopped
  /// and reported failed.
  Future<void> _failSharing(HotspotFailure failure) {
    final pending = _transition;
    if (pending != null) return pending.then((_) => _failSharing(failure));
    if (!_winrtOn) return Future.value();
    return _transition = _run(() => _stopNow(failure: failure));
  }

  Future<void> _settle(Map<Object?, Object?>? answer) async {
    if (answer == null) {
      _emit(
        HotspotState.failed,
        failure: const HotspotFailure(
          HotspotFailureReason.unsupported,
          'platform',
        ),
      );
      return;
    }
    final failure = _failureOf(answer);
    final running = answer['running'];
    if (failure != null) {
      if (running is bool) _setWinrtOn(running);
      if (!_winrtOn) _clearDevices();
      _emit(HotspotState.failed, failure: failure);
      return;
    }
    // A running hotspot that was stopped to apply another configuration is
    // never told off: the core is sent the whole state again, on, which it
    // takes as it takes every state, and keeps blocking meanwhile.
    if (answer['restarted'] == true && _winrtOn) _forgetSent();
    // The devices are read before the core hears the hotspot is on, so a
    // blocked device that is already joined is in the first state it gets.
    await _readClients();
    _setWinrtOn(true);
    _emit(HotspotState.on);
    _ensureTimer();
  }

  static HotspotFailure? _failureOf(Map<Object?, Object?>? answer) {
    final reason = answer?['reason'];
    if (reason == null) return null;
    return HotspotFailure(
      HotspotFailureReason.parse(reason.toString()),
      (answer?['detail'] ?? '').toString(),
    );
  }

  void _emit(HotspotState state, {HotspotFailure? failure}) {
    final last = _notifier.value;
    if (last.state != state ||
        last.failure?.reason != failure?.reason ||
        last.failure?.detail != failure?.detail) {
      final next = HotspotUpdate(state, failure: failure, at: DateTime.now());
      _notifier.value = next;
      _ctrl.add(next);
    }
    if (state != HotspotState.on) _sharingNotifier.value = null;
    _pushSharing();
  }

  void _ensureTimer() {
    final interval = _pollInterval;
    if (interval == null || _timer != null) return;
    _timer = Timer.periodic(interval, (_) => unawaited(pollOnce()));
  }

  void _cancelTimer() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> _readClients() async {
    final answer = await _native.invoke('hotspotClients');
    final raw = answer?['clients'];
    if (raw is! List) return;
    // A device that left is dropped from the connected list; it stays known
    // by the name and address it had.
    _seen.clear();
    for (final entry in raw) {
      final client = HotspotClient.tryParse(entry);
      if (client == null) continue;
      _seen[client.mac] = client;
      _lastKnown[client.mac] = client;
    }
    _publishClients();
  }

  void _publishClients() {
    final listed = <HotspotClient>[
      for (final c in _seen.values)
        c.copyWith(blocked: _blockedMacs.contains(c.mac)),
      for (final mac in _blockedMacs)
        if (!_seen.containsKey(mac))
          (_lastKnown[mac] ?? HotspotClient(mac: mac)).copyWith(blocked: true),
    ];
    _clientsNotifier.value = List.unmodifiable(listed);
  }

  /// The address a blocked device is blocked by: its own while it is listed,
  /// else the one it was last seen with, unless a device that is listed now
  /// holds that address (Windows leased it on).
  String? _blockedAddress(String mac) {
    final listed = _seen[mac];
    if (listed != null) return listed.ipv4;
    final remembered = _lastKnown[mac]?.ipv4;
    if (remembered == null) return null;
    final heldByAnother = _seen.values.any((c) => c.ipv4 == remembered);
    return heldByAnother ? null : remembered;
  }

  HotspotSharingWanted _wanted() => HotspotSharingWanted(
    on: _winrtOn,
    blockWhileTunnelDown: _blockWhileTunnelDown,
    blockedClients: ([
      for (final mac in _blockedMacs) ?_blockedAddress(mac),
    ]..sort()).take(maxBlockedClients).toList(),
  );

  /// Sends the core the wanted state when it differs from the last one sent.
  /// Nothing goes before the hotspot has been on: an `on: false` with no
  /// `on: true` before it has nothing to undo.
  void _pushSharing() {
    final wanted = _wanted();
    if (!wanted.on && !(_lastRequested?.on ?? false)) return;
    if (wanted == _lastRequested) return;
    _request(wanted);
  }

  void _request(HotspotSharingWanted wanted) {
    _lastRequested = wanted;
    final sequence = ++_requestSequence;
    _coreTookLast = false;
    _inFlight++;
    _ensureTimer();
    _sharingQueue = _sharingQueue.then((_) => _send(wanted, sequence));
  }

  Future<void> _send(HotspotSharingWanted wanted, int sequence) async {
    int? code;
    try {
      code = await _core.setSharing(wanted.toJson());
    } catch (_) {
      // No answer is sent again by the next poll.
    } finally {
      _inFlight--;
    }
    // A newer ask has replaced this one; only its answer counts.
    final current = sequence == _requestSequence;
    switch (code) {
      case null || 1:
        return;
      case 0:
        if (current) _coreTookLast = true;
        if (wanted.on && _winrtOn) _coreTookOn = true;
      case 3:
        if (current) _coreTookLast = true;
        if (wanted.on) {
          unawaited(
            _failSharing(
              const HotspotFailure(HotspotFailureReason.unsupported, 'core'),
            ),
          );
        }
      default:
        if (current) _coreTookLast = true;
        if (wanted.on) {
          unawaited(
            _failSharing(
              HotspotFailure(
                HotspotFailureReason.sharingFailed,
                'SetHotspotSharing returned $code',
              ),
            ),
          );
        }
    }
  }
}
