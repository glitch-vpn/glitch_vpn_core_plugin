import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Where a hotspot stands. [starting] covers a start, a reconfiguration and a
/// restart on another connection.
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

/// The connection the hotspot shares: the physical Wi-Fi or Ethernet
/// connection, or the tunnel adapter's.
enum HotspotConnection { wifi, tunnel }

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

class HotspotCapability {
  final bool supported;

  /// Why the system cannot host a hotspot; null when it can. "noConnection"
  /// when no connection with internet access exists to share.
  final String? unsupportedReason;

  /// The bands the adapter offers; empty when unsupported.
  final List<HotspotBand> bands;
  const HotspotCapability({
    required this.supported,
    this.unsupportedReason,
    this.bands = const [],
  });

  static const unavailable = HotspotCapability(
    supported: false,
    unsupportedReason: 'platform',
  );

  static HotspotCapability parse(Object? raw) {
    if (raw is! Map) return unavailable;
    if (raw['supported'] != true) {
      return HotspotCapability(
        supported: false,
        unsupportedReason: (raw['reason'] ?? '').toString(),
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

  /// IPv4 addresses of the blocked devices that are connected now.
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

/// A Wi-Fi hotspot that shares a connection, on Windows through the Mobile
/// hotspot. The plugin owns its lifecycle, configuration and device list; what
/// the clients' traffic does (through the tunnel, blocked while it is down) is
/// the core's, reached through [sharingSink].
///
/// The hotspot outlives the process that started it: [reconcile] adopts one
/// that is running, and [start] keeps one that already has the wanted
/// configuration. The user's own Mobile hotspot settings are saved before the
/// first start and put back by [stop].
class VpnHotspotChannel {
  VpnHotspotChannel._(this._native, this._clientPollInterval);
  static final instance = VpnHotspotChannel._(
    const MethodChannelHotspotNative(),
    const Duration(seconds: 3),
  );

  /// A channel over another transport; a null [clientPollInterval] turns
  /// polling off, and [refreshClients] is then the only way to read devices.
  @visibleForTesting
  factory VpnHotspotChannel.withNative(
    HotspotNative native, {
    Duration? clientPollInterval,
  }) => VpnHotspotChannel._(native, clientPollInterval);

  /// The one seam to the core. Called with the whole wanted state on each
  /// change, only when it differs from the last call. Until the bridge to the
  /// core sets it, the wanted state is recorded and goes nowhere.
  void Function(HotspotSharingWanted wanted)? sharingSink;

  final HotspotNative _native;
  final Duration? _clientPollInterval;

  final _ctrl = StreamController<HotspotUpdate>.broadcast(sync: true);
  final _notifier = ValueNotifier<HotspotUpdate>(
    HotspotUpdate(HotspotState.off, at: DateTime.now()),
  );
  final _clientsNotifier = ValueNotifier<List<HotspotClient>>(const []);
  final _capabilityNotifier = ValueNotifier<HotspotCapability?>(null);

  String? _ssid;
  String? _passphrase;
  HotspotBand _band = HotspotBand.auto;
  bool _blockWhileTunnelDown = true;
  final _blockedMacs = <String>{};
  final _seen = <String, HotspotClient>{};
  HotspotSharingWanted? _lastSharing;
  Timer? _poll;
  Future<void>? _transition;

  Stream<HotspotUpdate> get stream => _ctrl.stream;
  ValueListenable<HotspotUpdate> get listenable => _notifier;
  HotspotUpdate get value => _notifier.value;

  /// Connected devices, then blocked ones that are not connected.
  ValueListenable<List<HotspotClient>> get clients => _clientsNotifier;

  /// Null until [refreshCapability] has answered.
  ValueListenable<HotspotCapability?> get capability => _capabilityNotifier;

  /// The block applied while the tunnel is down; on until changed.
  bool get blockWhileTunnelDown => _blockWhileTunnelDown;

  Set<String> get blockedMacs => Set.unmodifiable(_blockedMacs);

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
  /// [start]; while the hotspot is on or starting it is applied at once, which
  /// restarts the access point. Throws [ArgumentError] on an invalid name or
  /// password.
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
    _ssid = ssid;
    _passphrase = passphrase;
    _band = band;
    if (value.state == HotspotState.on ||
        value.state == HotspotState.starting) {
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
    if (pending != null) {
      return pending.then((_) => start());
    }
    return _transition = _run(() async {
      _emit(HotspotState.starting);
      final answer = await _native.invoke('hotspotStart', {
        'ssid': ssid,
        'passphrase': passphrase,
        'band': _band.wire,
      });
      _settle(answer);
    });
  }

  /// Stops the hotspot and puts the user's own Mobile hotspot settings back.
  Future<void> stop() {
    final pending = _transition;
    if (pending != null) return pending.then((_) => stop());
    return _transition = _run(() async {
      final answer = await _native.invoke('hotspotStop');
      final failure = _failureOf(answer);
      if (failure != null) {
        _emit(HotspotState.failed, failure: failure);
        return;
      }
      _poll?.cancel();
      _poll = null;
      _seen.clear();
      _emit(HotspotState.off);
      _publishClients(const []);
      _pushSharing();
    });
  }

  /// Restarts the running hotspot on [connection]'s profile, keeping its
  /// configuration; the access point is down for several seconds. For the
  /// core's bridge, when the live switch of the shared connection is
  /// unavailable.
  Future<void> restartOn(HotspotConnection connection) {
    final pending = _transition;
    if (pending != null) return pending.then((_) => restartOn(connection));
    return _transition = _run(() async {
      _emit(HotspotState.starting);
      final answer = await _native.invoke('hotspotRestartOn', {
        'connection': connection.name,
      });
      _settle(answer);
    });
  }

  /// Adopts a hotspot a previous process started and left running; call it
  /// once when the app starts. Does nothing when none of ours runs.
  Future<void> reconcile() async {
    final answer = await _native.invoke('hotspotStatus');
    if (answer == null) return;
    if (answer['state'] == 'on' && answer['ours'] == true) {
      _emit(HotspotState.on);
      _startPolling();
      await refreshClients();
      _pushSharing();
    }
  }

  /// Whether the clients lose the internet while the tunnel is down (true) or
  /// go out directly (false).
  void setBlockWhileTunnelDown(bool block) {
    if (_blockWhileTunnelDown == block) return;
    _blockWhileTunnelDown = block;
    _pushSharing();
  }

  /// Blocks the device with [mac]; it stays listed as blocked.
  void blockClient(String mac) {
    final normalized = HotspotClient.normalizeMac(mac);
    if (normalized == null || !_blockedMacs.add(normalized)) return;
    _publishClients(_seen.values.toList());
    _pushSharing();
  }

  void unblockClient(String mac) {
    final normalized = HotspotClient.normalizeMac(mac);
    if (normalized == null || !_blockedMacs.remove(normalized)) return;
    _publishClients(_seen.values.toList());
    _pushSharing();
  }

  /// Reads the devices now and returns the list [clients] holds.
  Future<List<HotspotClient>> refreshClients() async {
    final answer = await _native.invoke('hotspotClients');
    final raw = answer?['clients'];
    if (raw is List) {
      // A device that left is dropped from the connected list; its entry
      // lives on only while it is blocked.
      _seen.clear();
      for (final entry in raw) {
        final client = HotspotClient.tryParse(entry);
        if (client != null) _seen[client.mac] = client;
      }
      _publishClients(_seen.values.toList());
      _pushSharing();
    }
    return _clientsNotifier.value;
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

  void _settle(Map<Object?, Object?>? answer) {
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
    if (failure != null) {
      _emit(HotspotState.failed, failure: failure);
      _pushSharing();
      return;
    }
    _emit(HotspotState.on);
    _startPolling();
    _pushSharing();
    unawaited(refreshClients());
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
    if (last.state == state && last.failure?.reason == failure?.reason) return;
    final next = HotspotUpdate(state, failure: failure, at: DateTime.now());
    _notifier.value = next;
    _ctrl.add(next);
  }

  void _startPolling() {
    final interval = _clientPollInterval;
    if (interval == null || _poll != null) return;
    _poll = Timer.periodic(interval, (_) {
      if (value.state == HotspotState.on) unawaited(refreshClients());
    });
  }

  void _publishClients(List<HotspotClient> connected) {
    final listed = <HotspotClient>[
      for (final c in connected)
        c.copyWith(blocked: _blockedMacs.contains(c.mac)),
      for (final mac in _blockedMacs)
        if (!connected.any((c) => c.mac == mac))
          HotspotClient(mac: mac, blocked: true),
    ];
    _clientsNotifier.value = List.unmodifiable(listed);
  }

  /// The block and per-device calls only record the wanted state; the core
  /// applies it once the bridge sets [sharingSink].
  void _pushSharing() {
    final wanted = HotspotSharingWanted(
      on:
          value.state == HotspotState.on ||
          value.state == HotspotState.starting,
      blockWhileTunnelDown: _blockWhileTunnelDown,
      blockedClients: [
        for (final c in _seen.values)
          if (_blockedMacs.contains(c.mac) && c.ipv4 != null) c.ipv4!,
      ]..sort(),
    );
    if (wanted == _lastSharing) return;
    _lastSharing = wanted;
    sharingSink?.call(wanted);
  }

  /// The wanted state last pushed, for the example app and tests.
  HotspotSharingWanted? get wantedSharing => _lastSharing;
}
