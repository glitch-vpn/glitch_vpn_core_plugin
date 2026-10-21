import 'dart:async';
import 'package:flutter/foundation.dart';

/// [downloadBytes] and [uploadBytes] are the session's proxied bytes, on every
/// engine; direct-routed traffic is not counted.
class VpnStats {
  final int downloadBytes;
  final int uploadBytes;
  final int durationMs;
  final int rssBytes; // process RSS; 0 if unavailable
  final int goMemBytes; // Go heap from OS; 0 if unavailable
  final bool? linkUp; // null until first conclusive liveness observation
  final int probeMs; // -1 unknown / passive (awg Android)
  final DateTime at;
  const VpnStats({
    required this.downloadBytes,
    required this.uploadBytes,
    required this.durationMs,
    this.rssBytes = 0,
    this.goMemBytes = 0,
    this.linkUp,
    this.probeMs = -1,
    required this.at,
  });
  factory VpnStats.now(
    int downloadBytes,
    int uploadBytes,
    int durationMs, {
    int rssBytes = 0,
    int goMemBytes = 0,
    bool? linkUp,
    int probeMs = -1,
  }) => VpnStats(
    downloadBytes: downloadBytes,
    uploadBytes: uploadBytes,
    durationMs: durationMs,
    rssBytes: rssBytes,
    goMemBytes: goMemBytes,
    linkUp: linkUp,
    probeMs: probeMs,
    at: DateTime.now(),
  );
}

class VpnStatsChannel {
  VpnStatsChannel._();
  static final instance = VpnStatsChannel._();

  final _ctrl = StreamController<VpnStats>.broadcast(sync: true);
  final _notifier = ValueNotifier<VpnStats>(VpnStats.now(0, 0, 0));
  VpnStats _last = VpnStats.now(0, 0, 0);

  Stream<VpnStats> get stream => _ctrl.stream;
  ValueListenable<VpnStats> get listenable => _notifier;
  VpnStats get value => _last;

  void emit(
    int downloadBytes,
    int uploadBytes,
    int durationMs, {
    int rssBytes = 0,
    int goMemBytes = 0,
    bool? linkUp,
    int probeMs = -1,
  }) {
    final next = VpnStats.now(
      downloadBytes,
      uploadBytes,
      durationMs,
      rssBytes: rssBytes,
      goMemBytes: goMemBytes,
      linkUp: linkUp,
      probeMs: probeMs,
    );
    final changed =
        _last.downloadBytes != downloadBytes ||
        _last.uploadBytes != uploadBytes ||
        _last.durationMs != durationMs ||
        _last.rssBytes != rssBytes ||
        _last.goMemBytes != goMemBytes ||
        _last.linkUp != linkUp ||
        _last.probeMs != probeMs;
    _last = next; // Always update for heartbeat tracking
    if (!changed) return;
    _notifier.value = next;
    _ctrl.add(next);
  }
}
