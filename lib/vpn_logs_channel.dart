import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:glitch_vpn_core/src/core_time.dart';

/// A line's level as the engine that wrote it gave it. [error] and [fatal]
/// arrive as LogError (401), the rest as LogEvent (400).
enum VpnLogLevel {
  debug,
  info,
  warn,
  error,
  fatal;

  /// The core's level string; one it does not name reads as [info].
  static VpnLogLevel fromCore(String level) => switch (level) {
    'debug' => debug,
    'warn' => warn,
    'error' => error,
    'fatal' => fatal,
    _ => info,
  };
}

/// One core log line (LogEvent 400 / LogError 401).
class VpnLog {
  /// The core's time, UTC.
  final DateTime at;
  final VpnLogLevel level;

  /// The engine or subsystem that wrote the line (`mihomo`, `AWG`,
  /// `Xray/Inbound`, ...); empty when the core names none.
  final String component;
  final String message;

  const VpnLog({
    required this.at,
    required this.level,
    required this.component,
    required this.message,
  });

  /// Null for garbage and for a payload with no message: an unknown event code
  /// lands here too, and must not show up as a blank line.
  static VpnLog? tryParse(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      final message = (m['message'] ?? '').toString();
      if (message.isEmpty) return null;
      return VpnLog(
        at: coreTime(m['ts']),
        level: VpnLogLevel.fromCore((m['level'] ?? '').toString()),
        component: (m['component'] ?? '').toString(),
        message: message,
      );
    } catch (_) {
      return null;
    }
  }
}

class VpnLogsChannel {
  VpnLogsChannel._();
  static final instance = VpnLogsChannel._();

  final _ctrl = StreamController<VpnLog>.broadcast(sync: true);
  final _notifier = ValueNotifier<VpnLog?>(null);
  VpnLog? _last;

  Stream<VpnLog> get stream => _ctrl.stream;

  /// Null until the first line arrives.
  ValueListenable<VpnLog?> get listenable => _notifier;
  VpnLog? get value => _last;

  void emit(VpnLog log) {
    _last = log;
    _notifier.value = log;
    _ctrl.add(log);
  }
}
