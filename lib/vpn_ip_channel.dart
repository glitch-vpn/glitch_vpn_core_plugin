import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// External addresses observed through the tunnel (IPEvent 303).
///
/// A missing address always comes with its error: 'disabled' (IPv6 was turned
/// off for the session), 'unsupported' (no in-tunnel HTTP path - awg on
/// Android), or the fetch failure text.
class VpnExternalIp {
  final String? ipv4;
  final String? ipv6;
  final String? ipv4Error;
  final String? ipv6Error;
  final DateTime at;

  const VpnExternalIp({
    required this.ipv4,
    required this.ipv6,
    required this.ipv4Error,
    required this.ipv6Error,
    required this.at,
  });

  bool get hasAny => ipv4 != null || ipv6 != null;
  bool get unsupported => ipv4Error == 'unsupported';

  static VpnExternalIp? tryParse(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      String? opt(String k) {
        final v = (m[k] ?? '').toString();
        return v.isEmpty ? null : v;
      }

      return VpnExternalIp(
        ipv4: opt('ipv4'),
        ipv6: opt('ipv6'),
        ipv4Error: opt('ipv4Error'),
        ipv6Error: opt('ipv6Error'),
        at: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

class VpnIpChannel {
  VpnIpChannel._();
  static final instance = VpnIpChannel._();

  final _ctrl = StreamController<VpnExternalIp>.broadcast(sync: true);
  final _notifier = ValueNotifier<VpnExternalIp?>(null);
  VpnExternalIp? _last;

  Stream<VpnExternalIp> get stream => _ctrl.stream;
  ValueListenable<VpnExternalIp?> get listenable => _notifier;
  VpnExternalIp? get value => _last;

  void emit(VpnExternalIp ip) {
    _last = ip;
    _notifier.value = ip;
    _ctrl.add(ip);
  }

  void reset() {
    _last = null;
    _notifier.value = null;
  }
}
