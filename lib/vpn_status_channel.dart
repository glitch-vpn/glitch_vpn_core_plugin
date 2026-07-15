import 'dart:async';
import 'package:flutter/foundation.dart';

enum VpnStatus { disconnected, connecting, connected, disconnecting, error }

class VpnStatusUpdate {
  final VpnStatus status;
  final String? reason;
  final DateTime at;
  const VpnStatusUpdate(this.status, {this.reason, required this.at});
  factory VpnStatusUpdate.now(VpnStatus s, {String? reason}) =>
      VpnStatusUpdate(s, reason: reason, at: DateTime.now());
}

class VpnStatusChannel {
  VpnStatusChannel._();
  static final instance = VpnStatusChannel._();

  final _ctrl = StreamController<VpnStatusUpdate>.broadcast(sync: true);
  final _notifier = ValueNotifier<VpnStatusUpdate>(
    VpnStatusUpdate.now(VpnStatus.disconnected),
  );
  VpnStatusUpdate _last = VpnStatusUpdate.now(VpnStatus.disconnected);

  Stream<VpnStatusUpdate> get stream => _ctrl.stream;
  ValueListenable<VpnStatusUpdate> get listenable => _notifier;
  VpnStatusUpdate get value => _last;

  void emit(VpnStatus s, {String? reason}) {
    if (_last.status == s && (reason == null || reason == _last.reason)) return;
    final next = VpnStatusUpdate.now(s, reason: reason);
    _last = next;
    _notifier.value = next;
    _ctrl.add(next);
  }
}
