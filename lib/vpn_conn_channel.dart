import 'dart:async';
import 'dart:convert';
import 'package:glitch_vpn_core/src/core_time.dart';

/// One routed connection from the connection inspector (ConnEvent 402).
class VpnConnEvent {
  final String engine; // xray | mihomo
  final String src;
  final String status; // accepted | rejected
  final String network; // tcp | udp
  final String host;
  final String port;
  final String inbound;
  final String outbound; // proxy | direct | block | proxy-N | ...
  final String rule; // mihomo only

  /// The core's time, UTC.
  final DateTime at;

  const VpnConnEvent({
    required this.engine,
    required this.src,
    required this.status,
    required this.network,
    required this.host,
    required this.port,
    required this.inbound,
    required this.outbound,
    required this.rule,
    required this.at,
  });

  bool get blocked => outbound == 'block' || status == 'rejected';

  static VpnConnEvent? tryParse(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      String s(String k) => (m[k] ?? '').toString();
      return VpnConnEvent(
        engine: s('engine'),
        src: s('src'),
        status: s('status'),
        network: s('network'),
        host: s('host'),
        port: s('port'),
        inbound: s('inbound'),
        outbound: s('outbound'),
        rule: s('rule'),
        at: coreTime(m['ts']),
      );
    } catch (_) {
      return null;
    }
  }
}

class VpnConnChannel {
  VpnConnChannel._();
  static final instance = VpnConnChannel._();

  final _ctrl = StreamController<VpnConnEvent>.broadcast(sync: true);

  Stream<VpnConnEvent> get stream => _ctrl.stream;

  void emit(VpnConnEvent event) => _ctrl.add(event);
}
