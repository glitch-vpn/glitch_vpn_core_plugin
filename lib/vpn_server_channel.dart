import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';

/// One server of the pool passed to connect() (ServerEvent 302).
class VpnServerInfo {
  /// Position in the link list passed to connect() (empties skipped).
  final int index;
  final String name; // #fragment remark, '' if the link had none
  final String host;
  final int port; // 0 if unknown
  final String protocol; // vless | trojan | ss | hysteria2 | awg

  const VpnServerInfo({
    required this.index,
    required this.name,
    required this.host,
    required this.port,
    required this.protocol,
  });

  String get displayName => name.isNotEmpty ? name : host;

  factory VpnServerInfo.fromJson(Map<dynamic, dynamic> m) => VpnServerInfo(
    index: m['index'] as int? ?? 0,
    name: (m['name'] ?? '').toString(),
    host: (m['host'] ?? '').toString(),
    port: m['port'] as int? ?? 0,
    protocol: (m['protocol'] ?? '').toString(),
  );
}

/// The connected server: a single link reports itself, a multi-link pool the
/// balancer's current pick. [selected] is null while the strategy dispatches
/// per connection (xray random/roundrobin, mihomo load-balance) - the pool
/// and strategy are still reported.
class VpnServerSelection {
  final String engine; // xray | awg | mihomo
  final String strategy; // '' for a single link
  final int total;
  final VpnServerInfo? selected;
  final List<VpnServerInfo> servers;
  final DateTime at;

  const VpnServerSelection({
    required this.engine,
    required this.strategy,
    required this.total,
    required this.selected,
    required this.servers,
    required this.at,
  });

  static VpnServerSelection? tryParse(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      final sel = m['selected'];
      final servers = <VpnServerInfo>[
        for (final s in (m['servers'] as List? ?? const []))
          if (s is Map) VpnServerInfo.fromJson(s),
      ];
      return VpnServerSelection(
        engine: (m['engine'] ?? '').toString(),
        strategy: (m['strategy'] ?? '').toString(),
        total: m['total'] as int? ?? servers.length,
        selected: sel is Map ? VpnServerInfo.fromJson(sel) : null,
        servers: servers,
        at: DateTime.now(),
      );
    } catch (_) {
      return null;
    }
  }
}

class VpnServerChannel {
  VpnServerChannel._();
  static final instance = VpnServerChannel._();

  final _ctrl = StreamController<VpnServerSelection>.broadcast(sync: true);
  final _notifier = ValueNotifier<VpnServerSelection?>(null);
  VpnServerSelection? _last;

  Stream<VpnServerSelection> get stream => _ctrl.stream;
  ValueListenable<VpnServerSelection?> get listenable => _notifier;
  VpnServerSelection? get value => _last;

  void emit(VpnServerSelection s) {
    _last = s;
    _notifier.value = s;
    _ctrl.add(s);
  }

  void reset() {
    _last = null;
    _notifier.value = null;
  }
}
