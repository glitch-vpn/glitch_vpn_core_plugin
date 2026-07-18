import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';
import 'package:glitch_vpn_core/vpn_stats_channel.dart';
import 'package:glitch_vpn_core/vpn_conn_channel.dart';

void main() {
  runZonedGuarded(() => runApp(const CoreTestApp()), (error, stack) {
    debugPrint('Uncaught error: $error\n$stack');
  });
}

const _sampleVlessReality =
    'vless://00000000-0000-0000-0000-000000000000@192.0.2.10:8443?type=tcp&security=reality&encryption=none&sni=www.bing.com&fp=chrome&pbk=AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA&sid=0123456789abcdef&flow=xtls-rprx-vision#reality-sample';

const _sampleAwg = '''
[Interface]
PrivateKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
Jc = 4
Jmin = 40
Jmax = 70
S1 = 50
S2 = 100
H1 = 1000000001
H2 = 1000000002
H3 = 1000000003
H4 = 1000000004
Address = 10.10.0.2/32
DNS = 1.1.1.1
MTU = 1420

[Peer]
PublicKey = AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 192.0.2.20:51820
PersistentKeepalive = 25
''';

class CoreTestApp extends StatelessWidget {
  const CoreTestApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Glitch Core Test',
    theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
    home: const CoreTestPage(),
  );
}

class CoreTestPage extends StatefulWidget {
  const CoreTestPage({super.key});
  @override
  State<CoreTestPage> createState() => _CoreTestPageState();
}

class _CoreTestPageState extends State<CoreTestPage> {
  final _configCtrl = TextEditingController(text: _sampleVlessReality);
  final _directRulesCtrl = TextEditingController();
  final _proxyRulesCtrl = TextEditingController();
  final _blockRulesCtrl = TextEditingController();
  final _dnsServersCtrl = TextEditingController(text: '1.1.1.1');
  final _fakeIpFilterCtrl = TextEditingController();
  final _proxyPortCtrl = TextEditingController(text: '10808');
  final _proxyUserCtrl = TextEditingController();
  final _proxyPassCtrl = TextEditingController();
  final _probeUrlCtrl = TextEditingController();
  final _muxCtrl = TextEditingController();
  final _xudpCtrl = TextEditingController();
  String _fingerprint = '';
  bool _proxyMode = false;
  bool _proxyAuth = true;

  VpnEngine _engine = VpnEngine.xray;
  List<VpnEngine> _availableEngines = VpnEngine.values;
  String _balancerStrategy = ''; // '', leastping, random, roundrobin
  String _routingMode = ''; // '', proxy-all, direct-all
  bool _localNetworksDirect = false;
  bool _disableIPv6 = false;
  bool _disableUDP = false;
  bool _sniffing = true;
  VpnDnsMode _dnsMode = VpnDnsMode.fakeIp;
  int _verbosity = -1; // logs OFF by default (matches the core default)
  MemoryLimit _memoryLimit = MemoryLimit.unlimited;

  String _capabilities = '(loading…)';
  String _geoInfo = '';
  String _activeEngine = '';
  final List<String> _logs = [];
  StreamSubscription? _logSub;
  final List<VpnConnEvent> _conns = [];
  StreamSubscription? _connSub;
  bool _inspector = false;
  String _logFilter = '';
  bool _fileLog = false;

  bool _pinging = false;
  List<PingResult>? _pingResults;

  final _hotspotSsidCtrl = TextEditingController(
    text: GlitchVpnCore.defaultHotspotSsid,
  );
  final _hotspotPassCtrl = TextEditingController();
  bool _hotspotOpen = false;
  bool _hotspotBusy = false;
  HotspotCredentials? _hotspot;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    await _ensureNotificationPermission();
    await GlitchVpnCore.ensureAdmin();
    GlitchVpnCore.instance.configure(logLevel: 3, dnsAddress: '1.1.1.1');
    await GlitchVpnCore.initialize();
    await GlitchVpnCore.setLogsVerbosity(_verbosity);

    _logSub = GlitchVpnCore.instance.onLogsChanged.listen((log) {
      String line = log.message;
      try {
        final m = jsonDecode(log.message);
        if (m is Map) {
          line = '[${m['level']}] ${m['component']}: ${m['message']}';
        }
      } catch (_) {}
      if (!mounted) return;
      setState(() {
        _logs.insert(0, line);
        if (_logs.length > 300) _logs.removeLast();
      });
    });

    _connSub = GlitchVpnCore.instance.onConnEvent.listen((c) {
      if (!mounted) return;
      setState(() {
        _conns.insert(0, c);
        if (_conns.length > 200) _conns.removeLast();
      });
    });

    await _refreshCapabilities();
  }

  Future<void> _ensureNotificationPermission() async {
    await GlitchVpnCore.requestNotificationPermission();
  }

  Future<void> _refreshCapabilities() async {
    try {
      final caps = await GlitchVpnCore.getCapabilitiesJson();
      final active = GlitchVpnCore.activeEngine();
      final engines = await GlitchVpnCore.availableEngines();
      if (!mounted) return;
      setState(() {
        _capabilities = caps;
        _activeEngine = active;
        _availableEngines = engines;
        // If the current pick isn't in this build (composition-dependent),
        // snap to the first available engine.
        if (engines.isNotEmpty && !engines.contains(_engine)) {
          _engine = engines.first;
        }
      });
    } catch (e) {
      if (mounted) setState(() => _capabilities = 'error: $e');
    }
  }

  List<String> _csv(String s) => s
      .split(',')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();

  Future<void> _toggle(VpnStatus status) async {
    if (status == VpnStatus.connected ||
        status == VpnStatus.connecting ||
        status == VpnStatus.error) {
      await GlitchVpnCore.instance.disconnect();
      await _refreshCapabilities();
      return;
    }
    try {
      final routing = VpnRouting(
        mode: _routingMode,
        direct: _csv(_directRulesCtrl.text),
        proxy: _csv(_proxyRulesCtrl.text),
        block: _csv(_blockRulesCtrl.text),
        localNetworksDirect: _localNetworksDirect,
        disableIPv6: _disableIPv6,
        disableUDP: _disableUDP,
      );
      final dns = VpnDns(
        mode: _dnsMode,
        servers: _csv(_dnsServersCtrl.text),
        fakeIpFilter: _csv(_fakeIpFilterCtrl.text),
      );
      await GlitchVpnCore.instance.connect(
        engine: _engine,
        config: _configCtrl.text.trim(),
        balancerStrategy: _balancerStrategy,
        routing: _engine == VpnEngine.awg ? null : routing,
        dns: dns,
        sniffing: _sniffing,
        probeUrl: _probeUrlCtrl.text.trim(),
        fingerprint: _fingerprint,
        muxConcurrency: int.tryParse(_muxCtrl.text.trim()),
        xudpConcurrency: int.tryParse(_xudpCtrl.text.trim()),
        proxyPort: (_proxyMode && _engine != VpnEngine.awg)
            ? (int.tryParse(_proxyPortCtrl.text.trim()) ?? 10808)
            : null,
        proxyAuth: _proxyAuth,
        // Empty → plugin generates random creds (read via proxyCredentials).
        proxyUser: _proxyUserCtrl.text.trim().isEmpty
            ? null
            : _proxyUserCtrl.text.trim(),
        proxyPass: _proxyPassCtrl.text.trim().isEmpty
            ? null
            : _proxyPassCtrl.text.trim(),
      );
      await _refreshCapabilities();
    } on PlatformException catch (e) {
      debugPrint('Connect failed: ${e.code} ${e.message}');
    }
  }

  /// Splits the config box into measurable links: one awg INI/awg:// entry, or
  /// N newline-separated xray links (the balancer input).
  List<String> _linksFromConfig() {
    final text = _configCtrl.text.trim();
    if (text.isEmpty) return const [];
    if (text.contains('[Interface]') || text.startsWith('awg://')) {
      return [text];
    }
    return text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();
  }

  Future<void> _measurePings() async {
    final links = _linksFromConfig();
    if (links.isEmpty) return;
    setState(() {
      _pinging = true;
      _pingResults = null;
    });
    final probe = _probeUrlCtrl.text.trim();
    final results = await GlitchVpnCore.measurePings(
      links,
      probeUrl: probe.isEmpty ? null : probe,
      timeoutMs: 5000,
    );
    if (!mounted) return;
    setState(() {
      _pinging = false;
      _pingResults = results;
    });
  }

  Future<void> _refreshGeo() async {
    await GlitchVpnCore.refreshGeoAssets();
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('Geo assets refreshed')));
  }

  @override
  void dispose() {
    _logSub?.cancel();
    _connSub?.cancel();
    _configCtrl.dispose();
    _directRulesCtrl.dispose();
    _proxyRulesCtrl.dispose();
    _blockRulesCtrl.dispose();
    _dnsServersCtrl.dispose();
    _fakeIpFilterCtrl.dispose();
    _probeUrlCtrl.dispose();
    _muxCtrl.dispose();
    _xudpCtrl.dispose();
    _proxyPortCtrl.dispose();
    _proxyUserCtrl.dispose();
    _proxyPassCtrl.dispose();
    _hotspotSsidCtrl.dispose();
    _hotspotPassCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Glitch Core Test'),
        actions: [
          IconButton(
            onPressed: _refreshCapabilities,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: ValueListenableBuilder<VpnStatusUpdate>(
        valueListenable: VpnStatusChannel.instance.listenable,
        builder: (context, upd, _) {
          final s = upd.status;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _capabilitiesCard(),
              const SizedBox(height: 12),
              _statusCard(upd),
              const SizedBox(height: 12),
              _configCard(),
              const SizedBox(height: 12),
              if (_engine != VpnEngine.awg) _routingCard(),
              const SizedBox(height: 12),
              _dnsCard(),
              const SizedBox(height: 12),
              _pingCard(),
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: (s == VpnStatus.disconnecting)
                    ? null
                    : () => _toggle(s),
                icon: Icon(
                  s == VpnStatus.connected ? Icons.stop : Icons.play_arrow,
                ),
                label: Text(_buttonText(s)),
              ),
              const SizedBox(height: 12),
              if (Platform.isWindows) ...[
                _hotspotCard(),
                const SizedBox(height: 12),
              ],
              _inspectorCard(),
              const SizedBox(height: 12),
              _logsCard(),
            ],
          );
        },
      ),
    );
  }

  Widget _capabilitiesCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'CoreCapabilities',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              Chip(
                label: Text(
                  _activeEngine.isEmpty ? 'idle' : 'active: $_activeEngine',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            _capabilities,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
          ),
          const Divider(),
          // Geo is not bundled - downloaded on demand by the plugin. These
          // exercise the runtime geo API (pinned default source).
          Row(
            children: [
              const Text('Geo:', style: TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () async {
                  final upd = await GlitchVpnCore.checkGeoUpdate();
                  if (!mounted) return;
                  setState(() {
                    _geoInfo = upd.entries
                        .map((e) => '${e.key}: ${e.value ?? "?"}')
                        .join('\n');
                  });
                },
                child: const Text('check update'),
              ),
              TextButton(
                onPressed: () async {
                  setState(() => _geoInfo = 'downloading…');
                  await GlitchVpnCore.refreshGeoAssets();
                  if (mounted) setState(() => _geoInfo = 'geo refreshed');
                },
                child: const Text('refresh'),
              ),
            ],
          ),
          if (_geoInfo.isNotEmpty)
            Text(
              _geoInfo,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
        ],
      ),
    ),
  );

  Widget _statusCard(VpnStatusUpdate upd) => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            _statusText(upd.status),
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.bold,
              color: _statusColor(upd.status),
            ),
          ),
          if (upd.reason != null && upd.reason!.isNotEmpty)
            Text(
              upd.reason!,
              style: const TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ValueListenableBuilder<VpnStats>(
            valueListenable: VpnStatsChannel.instance.listenable,
            builder: (context, st, _) => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '↓ ${_fmt(st.downloadBytes)}   ↑ ${_fmt(st.uploadBytes)}\n'
                  'RSS ${_fmt(st.rssBytes)} (proc)   Go ${_fmt(st.goMemBytes)} (engine)',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
                ),
                if (st.linkUp != null)
                  Row(
                    children: [
                      Icon(
                        st.linkUp! ? Icons.check_circle : Icons.cancel,
                        size: 14,
                        color: st.linkUp! ? Colors.green : Colors.red,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        st.linkUp!
                            ? 'internet${st.probeMs >= 0 ? ' ${st.probeMs} ms' : ''}'
                            : 'no internet through tunnel',
                        style: TextStyle(
                          fontSize: 12,
                          color: st.linkUp! ? Colors.green : Colors.red,
                        ),
                      ),
                    ],
                  ),
              ],
            ),
          ),
        ],
      ),
    ),
  );

  Widget _configCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Engine:'),
              const SizedBox(width: 8),
              DropdownButton<VpnEngine>(
                value: _engine,
                // Only engines this native build links (per-composition core).
                items: _availableEngines
                    .map((e) => DropdownMenuItem(value: e, child: Text(e.name)))
                    .toList(),
                onChanged: (e) => setState(() {
                  _engine = e!;
                  // strategy + fingerprint sets differ per engine
                  _balancerStrategy = '';
                  _fingerprint = '';
                }),
              ),
              const Spacer(),
              TextButton(
                onPressed: () =>
                    setState(() => _configCtrl.text = _sampleVlessReality),
                child: const Text('vless'),
              ),
              TextButton(
                onPressed: () => setState(() => _configCtrl.text = _sampleAwg),
                child: const Text('awg'),
              ),
              TextButton(
                onPressed: () => setState(() {
                  final t = _configCtrl.text.trim();
                  if (t.isNotEmpty && !t.startsWith('awg://')) {
                    _configCtrl.text = 'awg://${base64Url.encode(utf8.encode(t))}';
                  }
                }),
                child: const Text('→awg://'),
              ),
              TextButton(
                onPressed: _refreshGeo,
                child: const Text('geo↻'),
              ),
            ],
          ),
          TextField(
            controller: _configCtrl,
            maxLines: 5,
            minLines: 2,
            style: const TextStyle(fontFamily: 'monospace', fontSize: 12),
            decoration: const InputDecoration(
              border: OutlineInputBorder(),
              isDense: true,
              helperText:
                  'xray/awg: one link, or several awg://|vless:// (newline) → balancer. awg raw INI = single.',
            ),
          ),
          const SizedBox(height: 8),
          // Balancer strategy applies to every engine (awg is a pick-a-winner
          // balancer over multiple awg:// links); fingerprint/mux stay non-awg.
          Row(
            children: [
              const Text('Balancer:'),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _balancerStrategy,
                items: [
                  const DropdownMenuItem(value: '', child: Text('default')),
                  ...balancerStrategiesFor(_engine).map(
                    (s) => DropdownMenuItem(value: s, child: Text(s)),
                  ),
                ],
                onChanged: (v) => setState(() => _balancerStrategy = v!),
              ),
              const Expanded(
                child: Text(
                  '  (2+ links)',
                  style: TextStyle(fontSize: 11, color: Colors.grey),
                ),
              ),
            ],
          ),
          if (_engine != VpnEngine.awg) ...[
            Row(
              children: [
                const Text('Fingerprint:'),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: _fingerprint,
                  items: [
                    const DropdownMenuItem(value: '', child: Text('(link default)')),
                    ...fingerprintsFor(_engine).map(
                      (f) => DropdownMenuItem(value: f, child: Text(f)),
                    ),
                  ],
                  onChanged: (v) => setState(() => _fingerprint = v!),
                ),
              ],
            ),
            if (_engine == VpnEngine.xray)
              Row(
                children: [
                  const Text('Mux:'),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _muxCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: 'conc',
                        helperText: '0 off, <0 XUDP only',
                        isDense: true,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _xudpCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: 'xudp',
                        isDense: true,
                      ),
                    ),
                  ),
                ],
              ),
            Row(
              children: [
                Switch(
                  value: _proxyMode,
                  onChanged: (v) => setState(() => _proxyMode = v),
                ),
                const Text('Proxy mode (no TUN)'),
                const SizedBox(width: 8),
                if (_proxyMode)
                  SizedBox(
                    width: 90,
                    child: TextField(
                      controller: _proxyPortCtrl,
                      keyboardType: TextInputType.number,
                      style: const TextStyle(fontSize: 13),
                      decoration: const InputDecoration(
                        labelText: 'port',
                        isDense: true,
                        border: OutlineInputBorder(),
                      ),
                    ),
                  ),
                if (_proxyMode)
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Checkbox(
                        value: _proxyAuth,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) =>
                            setState(() => _proxyAuth = v ?? true),
                      ),
                      const Text('auth', style: TextStyle(fontSize: 12)),
                    ],
                  ),
                if (_proxyMode && _proxyAuth)
                  SizedBox(
                    width: 110,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: TextField(
                        controller: _proxyUserCtrl,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: 'user (rnd)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
                if (_proxyMode && _proxyAuth)
                  SizedBox(
                    width: 110,
                    child: Padding(
                      padding: const EdgeInsets.only(left: 6),
                      child: TextField(
                        controller: _proxyPassCtrl,
                        style: const TextStyle(fontSize: 13),
                        decoration: const InputDecoration(
                          labelText: 'pass (rnd)',
                          isDense: true,
                          border: OutlineInputBorder(),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (_proxyMode)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 4),
                child: Builder(
                  builder: (_) {
                    final creds = GlitchVpnCore.instance.proxyCredentials;
                    final port = _proxyPortCtrl.text.trim();
                    final String url;
                    if (!_proxyAuth) {
                      url = 'socks5://127.0.0.1:$port - no auth (open to local apps)';
                    } else if (creds != null) {
                      url =
                          'socks5://${creds.user}:${creds.pass}@127.0.0.1:$port';
                    } else {
                      url =
                          'socks5://<user>:<pass>@127.0.0.1:$port - empty fields = random; creds shown here after connect';
                    }
                    return SelectableText(
                      url,
                      style: const TextStyle(
                        fontSize: 11,
                        color: Colors.grey,
                        fontFamily: 'monospace',
                      ),
                    );
                  },
                ),
              ),
          ],
        ],
      ),
    ),
  );

  Widget _routingCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text('Routing mode:'),
              const SizedBox(width: 8),
              DropdownButton<String>(
                value: _routingMode,
                items: const [
                  DropdownMenuItem(value: '', child: Text('proxy-all (def)')),
                  DropdownMenuItem(
                    value: 'proxy-all',
                    child: Text('proxy-all'),
                  ),
                  DropdownMenuItem(
                    value: 'direct-all',
                    child: Text('direct-all'),
                  ),
                ],
                onChanged: (v) => setState(() => _routingMode = v!),
              ),
            ],
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
              'Rules: one matcher per line/comma. Prefix sets the type - '
              'geoip:cn · geosite:category-ru · domain:youtube.com · domain:рф · '
              'full:x · keyword:x · regexp:x · process:App.exe · 1.2.3.4 · '
              '10.0.0.0/8 · ::/0. Priority: block → direct → proxy → catch-all.',
              style: TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          _geoField('direct (bypass VPN)', _directRulesCtrl, 'domain:gov.ru, geoip:ru'),
          _geoField('proxy (force via VPN)', _proxyRulesCtrl, 'domain:youtube.com, geosite:youtube'),
          _geoField('block (drop)', _blockRulesCtrl, 'domain:ads.example, geosite:category-ads-all'),
          if (Platform.isWindows)
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  icon: const Icon(Icons.apps, size: 16),
                  label: const Text('+ app → direct'),
                  onPressed: () => _pickAppInto(_directRulesCtrl),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.apps, size: 16),
                  label: const Text('+ app → proxy'),
                  onPressed: () => _pickAppInto(_proxyRulesCtrl),
                ),
                OutlinedButton.icon(
                  icon: const Icon(Icons.apps, size: 16),
                  label: const Text('+ app → block'),
                  onPressed: () => _pickAppInto(_blockRulesCtrl),
                ),
              ],
            ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Checkbox(
                value: _localNetworksDirect,
                onChanged: (v) =>
                    setState(() => _localNetworksDirect = v ?? false),
              ),
              const Text('LAN direct'),
              const SizedBox(width: 12),
              Checkbox(
                value: _disableIPv6,
                onChanged: (v) => setState(() => _disableIPv6 = v ?? false),
              ),
              const Text('no IPv6'),
              const SizedBox(width: 12),
              Checkbox(
                value: _disableUDP,
                onChanged: (v) => setState(() => _disableUDP = v ?? false),
              ),
              const Text('no UDP (except :53)'),
              const SizedBox(width: 12),
              Checkbox(
                value: _sniffing,
                onChanged: (v) => setState(() => _sniffing = v ?? true),
              ),
              const Tooltip(
                message: 'Recover domains from TLS/HTTP/QUIC for flows that '
                    'bypass our DNS (in-app DoH, hardcoded IPs). With '
                    'dns=normal, domain routing does not work without it.',
                child: Text('sniffing'),
              ),
            ],
          ),
        ],
      ),
    ),
  );

  // Appends process:<exe> to a rule field, chosen from installed apps (with a
  // classic file-picker fallback). Windows per-process routing.
  Future<void> _pickAppInto(TextEditingController target) async {
    final apps = await GlitchVpnCore.instance.listInstalledApps();
    if (!mounted) return;
    final proc = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final searchCtrl = TextEditingController();
        var filtered = apps;
        final icons = <String, Uint8List>{};
        return StatefulBuilder(
          builder: (ctx, setInner) {
            // Lazily load icons once (like Android's appsIcon), then refresh.
            if (icons.isEmpty) {
              GlitchVpnCore.instance
                  .appIcons(apps.map((a) => a.path).toList())
                  .then((m) {
                if (m.isNotEmpty && ctx.mounted) setInner(() => icons.addAll(m));
              });
            }
            return AlertDialog(
              title: const Text('Pick an application'),
              content: SizedBox(
                width: 420,
                height: 460,
                child: Column(
                  children: [
                    TextField(
                      controller: searchCtrl,
                      decoration: const InputDecoration(
                        hintText: 'filter…',
                        prefixIcon: Icon(Icons.search),
                        isDense: true,
                      ),
                      onChanged: (q) => setInner(() {
                        final lq = q.toLowerCase();
                        filtered = apps
                            .where((a) =>
                                a.name.toLowerCase().contains(lq) ||
                                a.process.toLowerCase().contains(lq))
                            .toList();
                      }),
                    ),
                    Expanded(
                      child: ListView.builder(
                        itemCount: filtered.length,
                        itemBuilder: (_, i) {
                          final icon = icons[filtered[i].path];
                          return ListTile(
                            dense: true,
                            leading: icon != null
                                ? Image.memory(icon, width: 24, height: 24)
                                : const Icon(Icons.apps, size: 24),
                            title: Text(filtered[i].name),
                            subtitle: Text(filtered[i].process,
                                style: const TextStyle(fontSize: 11)),
                            onTap: () => Navigator.pop(ctx, filtered[i].process),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            actions: [
              TextButton(
                child: const Text('Browse .exe…'),
                onPressed: () async {
                  final exe = await GlitchVpnCore.instance.pickExecutable();
                  if (ctx.mounted) Navigator.pop(ctx, exe);
                },
              ),
              TextButton(
                child: const Text('Cancel'),
                onPressed: () => Navigator.pop(ctx, null),
              ),
            ],
          );
        }
        );
      },
    );
    if (proc == null || proc.isEmpty) return;
    final entry = 'process:$proc';
    final cur = target.text.trim();
    setState(() {
      target.text = cur.isEmpty ? entry : '$cur, $entry';
    });
  }

  Widget _geoField(String label, TextEditingController c, String hint) =>
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: TextField(
          controller: c,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(
            labelText: label,
            hintText: hint,
            border: const OutlineInputBorder(),
            isDense: true,
          ),
        ),
      );

  Widget _dnsCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'DNS',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 12),
              DropdownButton<VpnDnsMode>(
                value: _dnsMode,
                items: const [
                  DropdownMenuItem(
                    value: VpnDnsMode.fakeIp,
                    child: Text('fake-ip'),
                  ),
                  DropdownMenuItem(
                    value: VpnDnsMode.normal,
                    child: Text('normal'),
                  ),
                ],
                onChanged: (v) => setState(() => _dnsMode = v!),
              ),
              if (_engine != VpnEngine.mihomo)
                Expanded(
                  child: Text(
                    _engine == VpnEngine.awg
                        ? '  (awg: first plain server only)'
                        : '  (xray: mode ignored)',
                    style: const TextStyle(fontSize: 11, color: Colors.grey),
                  ),
                ),
            ],
          ),
          _geoField(
            'servers (csv): 1.1.1.1, https://…, tls://… (mihomo), quic://…',
            _dnsServersCtrl,
            '1.1.1.1, https://dns.google/dns-query',
          ),
          if (_dnsMode == VpnDnsMode.fakeIp)
            _geoField(
              'fake-ip filter (csv)',
              _fakeIpFilterCtrl,
              '*.lan, geosite:private',
            ),
        ],
      ),
    ),
  );

  Widget _pingCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Ping (url-test)',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const Spacer(),
              if (_pinging)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              TextButton.icon(
                onPressed: _pinging ? null : _measurePings,
                icon: const Icon(Icons.speed),
                label: const Text('Measure'),
              ),
            ],
          ),
          TextField(
            controller: _probeUrlCtrl,
            decoration: const InputDecoration(
              labelText: 'Probe URL',
              hintText: 'https://www.gstatic.com/generate_204 (default)',
              helperText:
                  'Used by Measure and by the balancer health-check on connect',
              isDense: true,
            ),
          ),
          if (_pingResults != null && _pingResults!.isEmpty)
            const Text('no links', style: TextStyle(color: Colors.grey)),
          if (_pingResults != null) ..._pingResults!.map(_pingRow),
        ],
      ),
    ),
  );

  Widget _pingRow(PingResult r) {
    final links = _linksFromConfig();
    final label = r.index < links.length
        ? _shortLink(links[r.index])
        : 'link ${r.index}';
    final Widget trailing = r.alive
        ? Text(
            '${r.delayMs} ms',
            style: TextStyle(
              color: _pingColor(r.delayMs),
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          )
        : Text(
            r.error ?? 'dead',
            style: const TextStyle(color: Colors.red, fontSize: 11),
            overflow: TextOverflow.ellipsis,
          );
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        children: [
          SizedBox(
            width: 44,
            child: Text(
              r.engine.isEmpty ? '?' : r.engine,
              style: const TextStyle(fontSize: 11, color: Colors.grey),
            ),
          ),
          Expanded(
            child: Text(
              label,
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 160),
            child: trailing,
          ),
        ],
      ),
    );
  }

  String _shortLink(String link) {
    if (link.contains('[Interface]')) return 'awg config';
    final hash = link.indexOf('#');
    if (hash >= 0 && hash < link.length - 1) {
      return Uri.decodeComponent(link.substring(hash + 1));
    }
    return link.length > 48 ? '${link.substring(0, 48)}…' : link;
  }

  Color _pingColor(int ms) {
    if (ms < 150) return Colors.green;
    if (ms < 400) return Colors.orange;
    return Colors.red;
  }

  Future<void> _startHotspot() async {
    setState(() => _hotspotBusy = true);
    try {
      final creds = await GlitchVpnCore.instance.startHotspot(
        ssid: _hotspotSsidCtrl.text,
        password: _hotspotPassCtrl.text.trim().isEmpty
            ? null
            : _hotspotPassCtrl.text.trim(),
        open: _hotspotOpen,
      );
      if (!mounted) return;
      setState(() => _hotspot = creds);
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hotspot: ${e.code} - ${e.message}')),
      );
    } on ArgumentError catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Hotspot: $e')));
    } finally {
      if (mounted) setState(() => _hotspotBusy = false);
    }
  }

  Future<void> _stopHotspot() async {
    setState(() => _hotspotBusy = true);
    try {
      await GlitchVpnCore.instance.stopHotspot();
      if (!mounted) return;
      setState(() => _hotspot = null);
    } on PlatformException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Hotspot: ${e.code} - ${e.message}')),
      );
    } finally {
      if (mounted) setState(() => _hotspotBusy = false);
    }
  }

  Widget _hotspotCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Wi-Fi Hotspot (via VPN tunnel)',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              SizedBox(
                width: 180,
                child: TextField(
                  controller: _hotspotSsidCtrl,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'SSID',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              SizedBox(
                width: 160,
                child: TextField(
                  controller: _hotspotPassCtrl,
                  enabled: !_hotspotOpen,
                  style: const TextStyle(fontSize: 13),
                  decoration: const InputDecoration(
                    labelText: 'password (rnd)',
                    isDense: true,
                    border: OutlineInputBorder(),
                  ),
                ),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Checkbox(
                    value: _hotspotOpen,
                    visualDensity: VisualDensity.compact,
                    onChanged: (v) =>
                        setState(() => _hotspotOpen = v ?? false),
                  ),
                  const Text('open (no password)',
                      style: TextStyle(fontSize: 12)),
                ],
              ),
              FilledButton.icon(
                icon: Icon(
                  _hotspot == null ? Icons.wifi_tethering : Icons.wifi_off,
                  size: 16,
                ),
                label: Text(_hotspot == null ? 'Start' : 'Stop'),
                onPressed: _hotspotBusy
                    ? null
                    : (_hotspot == null ? _startHotspot : _stopHotspot),
              ),
            ],
          ),
          if (_hotspot != null)
            Padding(
              padding: const EdgeInsets.only(top: 6, left: 4),
              child: SelectableText(
                'SSID: ${_hotspot!.ssid}'
                '${_hotspot!.isOpen ? ' - open' : ' - password: ${_hotspot!.password}'}'
                '${_hotspot!.tunneled ? ' - via VPN tunnel' : ' - NOT tunneled (connect VPN first)'}',
                style: const TextStyle(
                  fontSize: 11,
                  color: Colors.grey,
                  fontFamily: 'monospace',
                ),
              ),
            ),
        ],
      ),
    ),
  );

  Widget _inspectorCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Connections',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              Switch(
                value: _inspector,
                onChanged: (v) {
                  setState(() => _inspector = v);
                  GlitchVpnCore.setConnectionInspector(v);
                },
              ),
              const Text('inspect', style: TextStyle(fontSize: 12)),
              const Spacer(),
              TextButton(
                onPressed: () => setState(_conns.clear),
                child: const Text('clear'),
              ),
            ],
          ),
          if (!_inspector)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: Text(
                'Toggle on to see each routed connection (host → outbound).',
                style: TextStyle(fontSize: 11, color: Colors.grey),
              ),
            )
          else
            SizedBox(
              height: 200,
              child: ListView.builder(
                itemCount: _conns.length,
                itemBuilder: (_, i) {
                  final c = _conns[i];
                  final color = c.blocked
                      ? Colors.red
                      : (c.outbound == 'direct' ? Colors.orange : Colors.green);
                  return Row(
                    children: [
                      Container(width: 8, height: 8, margin: const EdgeInsets.only(right: 6),
                        decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
                      Expanded(
                        child: Text(
                          '${c.network} ${c.host}:${c.port}  →  ${c.outbound}'
                          '${c.rule.isNotEmpty ? '  (${c.rule})' : ''}',
                          style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
        ],
      ),
    ),
  );

  Widget _logsCard() => Card(
    child: Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'Logs',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              const SizedBox(width: 8),
              DropdownButton<int>(
                value: _verbosity,
                items: const [
                  DropdownMenuItem(value: -1, child: Text('off')),
                  DropdownMenuItem(value: 0, child: Text('v0 errors')),
                  DropdownMenuItem(value: 1, child: Text('v1 info')),
                  DropdownMenuItem(value: 2, child: Text('v2 all')),
                ],
                onChanged: (v) {
                  setState(() => _verbosity = v!);
                  GlitchVpnCore.setLogsVerbosity(_verbosity);
                },
              ),
              const SizedBox(width: 8),
              const Text('mem:'),
              DropdownButton<MemoryLimit>(
                value: _memoryLimit,
                items: const [
                  DropdownMenuItem(value: MemoryLimit.unlimited, child: Text('∞')),
                  DropdownMenuItem(value: MemoryLimit.mb64, child: Text('64M')),
                  DropdownMenuItem(value: MemoryLimit.mb128, child: Text('128M')),
                  DropdownMenuItem(value: MemoryLimit.mb256, child: Text('256M')),
                  DropdownMenuItem(value: MemoryLimit.mb512, child: Text('512M')),
                ],
                onChanged: (v) {
                  setState(() => _memoryLimit = v!);
                  GlitchVpnCore.setMemoryLimit(_memoryLimit);
                },
              ),
              const Spacer(),
              // File logging OFF by default; toggle mirrors log lines to a temp
              // file (getLogFilePath / clearLogFile via the plugin).
              IconButton(
                tooltip: _fileLog ? 'File logging ON - tap path to view' : 'Log to file',
                visualDensity: VisualDensity.compact,
                icon: Icon(_fileLog ? Icons.save : Icons.save_outlined),
                color: _fileLog ? Colors.green : null,
                onPressed: () async {
                  await GlitchVpnCore.instance.configureLogging(toFile: !_fileLog);
                  if (mounted) setState(() => _fileLog = !_fileLog);
                },
              ),
              IconButton(
                tooltip: 'Show log file path',
                visualDensity: VisualDensity.compact,
                icon: const Icon(Icons.folder_open),
                onPressed: () async {
                  final path = await GlitchVpnCore.instance.getLogFilePath();
                  if (!mounted) return;
                  ScaffoldMessenger.of(context).showSnackBar(
                    SnackBar(content: Text(path ?? 'file logging not enabled yet')),
                  );
                },
              ),
              TextButton(
                onPressed: () async {
                  await GlitchVpnCore.instance.clearLogFile();
                  if (mounted) setState(_logs.clear);
                },
                child: const Text('clear'),
              ),
            ],
          ),
          TextField(
            decoration: const InputDecoration(
              isDense: true,
              prefixIcon: Icon(Icons.search, size: 18),
              hintText: 'filter logs…',
            ),
            style: const TextStyle(fontSize: 12),
            onChanged: (v) => setState(() => _logFilter = v.trim().toLowerCase()),
          ),
          const SizedBox(height: 4),
          SizedBox(
            height: 220,
            child: Builder(
              builder: (_) {
                final shown = _logFilter.isEmpty
                    ? _logs
                    : _logs
                          .where((l) => l.toLowerCase().contains(_logFilter))
                          .toList();
                return ListView.builder(
                  reverse: true,
                  itemCount: shown.length,
                  itemBuilder: (_, i) => Text(
                    shown[i],
                    style: const TextStyle(
                      fontFamily: 'monospace',
                      fontSize: 11,
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    ),
  );

  String _buttonText(VpnStatus s) => switch (s) {
    VpnStatus.connected => 'Disconnect',
    VpnStatus.connecting => 'Connecting… (tap to cancel)',
    VpnStatus.disconnecting => 'Disconnecting…',
    VpnStatus.error => 'Error - retry',
    VpnStatus.disconnected => 'Connect (${_engine.name})',
  };

  String _statusText(VpnStatus s) => switch (s) {
    VpnStatus.connected => 'CONNECTED',
    VpnStatus.connecting => 'CONNECTING…',
    VpnStatus.disconnecting => 'DISCONNECTING…',
    VpnStatus.error => 'ERROR',
    VpnStatus.disconnected => 'DISCONNECTED',
  };

  Color _statusColor(VpnStatus s) => switch (s) {
    VpnStatus.connected => Colors.green,
    VpnStatus.connecting => Colors.orange,
    VpnStatus.disconnecting => Colors.amber,
    VpnStatus.error => Colors.red,
    VpnStatus.disconnected => Colors.grey,
  };

  String _fmt(int b) {
    if (b < 1024) return '$b B';
    if (b < 1 << 20) return '${(b / 1024).toStringAsFixed(1)} KB';
    if (b < 1 << 30) return '${(b / (1 << 20)).toStringAsFixed(2)} MB';
    return '${(b / (1 << 30)).toStringAsFixed(2)} GB';
  }
}
