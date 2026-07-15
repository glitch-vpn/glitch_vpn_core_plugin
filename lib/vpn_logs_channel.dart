import 'dart:async';
import 'package:flutter/foundation.dart';

class VpnLog {
  final String message;
  final DateTime at;
  const VpnLog({required this.message, required this.at});
  factory VpnLog.now(String message) =>
      VpnLog(message: message, at: DateTime.now());
}

class VpnLogsChannel {
  VpnLogsChannel._();
  static final instance = VpnLogsChannel._();

  final _ctrl = StreamController<VpnLog>.broadcast(sync: true);
  final _notifier = ValueNotifier<VpnLog>(VpnLog.now(''));
  VpnLog _last = VpnLog.now('');

  Stream<VpnLog> get stream => _ctrl.stream;
  ValueListenable<VpnLog> get listenable => _notifier;
  VpnLog get value => _last;

  void emit(String message) {
    if (_last.message == message) {
      return;
    }
    final next = VpnLog.now(message);
    _last = next;
    _notifier.value = next;
    _ctrl.add(next);
  }
}
