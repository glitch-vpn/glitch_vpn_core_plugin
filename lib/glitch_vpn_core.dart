import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:glitch_vpn_core/glitch_vpn_core_ffi.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';
import 'package:glitch_vpn_core/vpn_stats_channel.dart';
import 'package:glitch_vpn_core/vpn_logs_channel.dart';
import 'package:glitch_vpn_core/vpn_conn_channel.dart';
import 'package:glitch_vpn_core/vpn_server_channel.dart';
import 'package:glitch_vpn_core/vpn_ip_channel.dart';

/// Plugin-wide defaults; per-call [connect] args override them.
class GlitchVpnCoreConfig {
  static const int defaultTunMtu = 1420;
  static const int defaultTunUdpTimeoutSeconds = 30;

  final int logLevel;
  final String dnsAddress;
  final int tunMtu;
  final int tunUdpTimeoutSeconds;
  final SplitTunnelingType splitTunnelingType;
  final List<String> splitTunnelingApps;

  const GlitchVpnCoreConfig({
    this.logLevel = 0,
    this.dnsAddress = '1.1.1.1',
    this.tunMtu = defaultTunMtu,
    this.tunUdpTimeoutSeconds = defaultTunUdpTimeoutSeconds,
    this.splitTunnelingType = SplitTunnelingType.blacklist,
    this.splitTunnelingApps = const <String>[],
  });

  GlitchVpnCoreConfig copyWith({
    int? logLevel,
    String? dnsAddress,
    int? tunMtu,
    int? tunUdpTimeoutSeconds,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
  }) => GlitchVpnCoreConfig(
    logLevel: logLevel ?? this.logLevel,
    dnsAddress: dnsAddress ?? this.dnsAddress,
    tunMtu: tunMtu ?? this.tunMtu,
    tunUdpTimeoutSeconds: tunUdpTimeoutSeconds ?? this.tunUdpTimeoutSeconds,
    splitTunnelingType: splitTunnelingType ?? this.splitTunnelingType,
    splitTunnelingApps: splitTunnelingApps ?? this.splitTunnelingApps,
  );
}

/// The words of the Android tunnel notification, in the app's language: the
/// plugin has none of its own. [channel] names the notification channel in
/// the system's settings; [title] is also the session name the system's VPN
/// settings show. [connected] stands as the line while no `countryLine` has
/// been sent ([GlitchVpnCore.updateNotification]).
class VpnNotificationTexts {
  final String title;
  final String channel;
  final String connecting;
  final String connected;
  final String disconnecting;
  final String disconnectAction;

  const VpnNotificationTexts({
    required this.title,
    required this.channel,
    required this.connecting,
    required this.connected,
    required this.disconnecting,
    required this.disconnectAction,
  });

  Map<String, String> toMap() => {
    'title': title,
    'channel': channel,
    'connecting': connecting,
    'connected': connected,
    'disconnecting': disconnecting,
    'disconnectAction': disconnectAction,
  };
}

enum VpnEngine { xray, awg, mihomo }

enum SplitTunnelingType { whitelist, blacklist }

enum MemoryLimit {
  unlimited(0),
  mb64(64 * 1024 * 1024),
  mb128(128 * 1024 * 1024),
  mb256(256 * 1024 * 1024),
  mb512(512 * 1024 * 1024);

  const MemoryLimit(this.bytes);
  final int bytes;
}

/// One ordered rule group; within a tier block beats direct beats proxy.
/// Matchers use prefixes (`geoip:`, `geosite:`, `domain:`, `full:`,
/// `keyword:`, `regexp:`, `process:`) or bare IP/CIDR/host. `domain:`/`full:`
/// match on label boundaries, so `domain:ru` covers `ru` and every `*.ru`;
/// dots around the zone are stripped (`.ru` ≡ `ru`). `keyword:` is a
/// substring and keeps its dots.
class VpnRoutingTier {
  final List<String> block;
  final List<String> direct;
  final List<String> proxy;

  const VpnRoutingTier({
    this.block = const [],
    this.direct = const [],
    this.proxy = const [],
  });
}

/// Routing for xray/mihomo. Tiers are evaluated in list order, first match
/// wins across the whole sequence; then LAN bypass and the mode catch-all.
/// `process:` rules are the exception wherever the desktop tun2socks bridge
/// owns the per-process split: there they keep the global priority
/// block > direct > proxy regardless of tier order.
class VpnRouting {
  /// '', 'proxy-all', or 'direct-all'.
  final String mode;

  /// Ordered rule groups, first evaluated first.
  final List<VpnRoutingTier> tiers;

  /// RFC1918/CGNAT/loopback → direct.
  final bool localNetworksDirect;

  /// Reject ::/0 and suppress AAAA.
  final bool disableIPv6;

  /// Reject UDP except :53.
  final bool disableUDP;

  const VpnRouting({
    this.mode = '',
    this.tiers = const [],
    this.localNetworksDirect = false,
    this.disableIPv6 = false,
    this.disableUDP = false,
  });

  Map<String, String> toOpts() {
    final opts = <String, String>{};
    List<String> clean(List<String> v) =>
        v.map((e) => e.trim()).where((e) => e.isNotEmpty).toList();
    final cleaned = tiers
        .map(
          (t) => (
            block: clean(t.block),
            direct: clean(t.direct),
            proxy: clean(t.proxy),
          ),
        )
        .where(
          (t) =>
              t.block.isNotEmpty || t.direct.isNotEmpty || t.proxy.isNotEmpty,
        )
        .toList();

    if (mode.isNotEmpty) opts['routingMode'] = mode;
    if (cleaned.isNotEmpty) {
      opts['routingTiers'] = jsonEncode([
        for (final t in cleaned)
          {
            if (t.block.isNotEmpty) 'block': t.block,
            if (t.direct.isNotEmpty) 'direct': t.direct,
            if (t.proxy.isNotEmpty) 'proxy': t.proxy,
          },
      ]);
    }
    if (localNetworksDirect) opts['localNetworksDirect'] = '1';
    if (disableIPv6) opts['disableIPv6'] = '1';
    if (disableUDP) opts['disableUDP'] = '1';
    return opts;
  }
}

/// Balancer strategies for [engine] ('' = engine default).
List<String> balancerStrategiesFor(VpnEngine engine) {
  switch (engine) {
    case VpnEngine.xray:
      return const ['leastping', 'random', 'roundrobin'];
    case VpnEngine.mihomo:
      return const [
        'url-test',
        'fallback',
        'load-balance',
        'load-balance-hash',
      ];
    case VpnEngine.awg:
      return const ['leastping', 'random', 'fallback'];
  }
}

/// xray router domain strategies (whether the router resolves domain-form
/// requests to match IP rules); other engines have no equivalent → empty.
List<String> domainStrategiesFor(VpnEngine engine) {
  switch (engine) {
    case VpnEngine.xray:
      return const ['asis', 'ipifnonmatch', 'ipondemand'];
    case VpnEngine.mihomo:
    case VpnEngine.awg:
      return const [];
  }
}

/// uTLS fingerprints for [engine] (sets differ; awg → empty).
List<String> fingerprintsFor(VpnEngine engine) {
  switch (engine) {
    case VpnEngine.xray:
      return const [
        'chrome',
        'firefox',
        'safari',
        'ios',
        'android',
        'edge',
        '360',
        'qq',
        'random',
        'randomized',
        'randomizednoalpn',
        'unsafe',
      ];
    case VpnEngine.mihomo:
      return const [
        'chrome',
        'firefox',
        'safari',
        'ios',
        'android',
        'edge',
        '360',
        'qq',
        'random',
        'randomized',
        'chrome120',
        'firefox120',
        'safari16',
      ];
    case VpnEngine.awg:
      return const [];
  }
}

enum VpnDnsMode { fakeIp, normal }

/// DNS for xray/mihomo (awg uses the first plain server only, and takes it
/// verbatim — no port suffix there).
/// Schemes: plain / `tls://` / `https://` / `quic://` / `tcp://`; a plain
/// server may carry a port (`10.0.0.1:5353`).
class VpnDns {
  final VpnDnsMode mode;
  final List<String> servers;
  final List<String> fakeIpFilter;

  /// Static name → addresses; keys take xray matcher prefixes verbatim. An
  /// entry with several values keeps only IPs — an alias name is single-valued.
  /// awg ignores.
  final Map<String, List<String>> hosts;

  /// Resolvers for direct-routed names. fake-ip covers every direct dial on
  /// both engines; xray's normal mode falls back to the direct domain rules,
  /// and direct-all inverts the split (README). awg ignores.
  final List<String> directServers;

  const VpnDns({
    this.mode = VpnDnsMode.fakeIp,
    this.servers = const [],
    this.fakeIpFilter = const [],
    this.hosts = const {},
    this.directServers = const [],
  });

  Map<String, dynamic> toJson() => {
    'mode': mode == VpnDnsMode.fakeIp ? 'fake-ip' : 'normal',
    if (servers.isNotEmpty) 'servers': servers,
    if (fakeIpFilter.isNotEmpty) 'fakeIpFilter': fakeIpFilter,
    if (hosts.isNotEmpty) 'hosts': hosts,
    if (directServers.isNotEmpty) 'directServers': directServers,
  };
}

class GlitchVpnCore {
  GlitchVpnCore._();
  static final GlitchVpnCore instance = GlitchVpnCore._();
  static const MethodChannel _ch = MethodChannel('glitch_vpn_core');

  static final _AsyncMutex _transitionMutex = _AsyncMutex();
  static Future<T> _withTransitionLock<T>(Future<T> Function() action) async =>
      _transitionMutex.runExclusive(action);

  Stream<VpnStatusUpdate> get onStatusChanged =>
      VpnStatusChannel.instance.stream;

  ValueListenable<VpnStatusUpdate> get statusListenable =>
      VpnStatusChannel.instance.listenable;

  Stream<VpnStats> get onStatsChanged => VpnStatsChannel.instance.stream;

  Stream<VpnLog> get onLogsChanged => VpnLogsChannel.instance.stream;

  /// Emits while [setConnectionInspector] is on.
  Stream<VpnConnEvent> get onConnEvent => VpnConnChannel.instance.stream;

  /// The connected server (the balancer's pick for multi-link pools);
  /// leastping/url-test can switch it mid-session. The stream stays silent on
  /// session end - pair it with [onStatusChanged], or use the listenable,
  /// which nulls on reset.
  Stream<VpnServerSelection> get onServerSelectionChanged =>
      VpnServerChannel.instance.stream;

  ValueListenable<VpnServerSelection?> get serverSelectionListenable =>
      VpnServerChannel.instance.listenable;

  /// Null until the core reports one.
  VpnServerSelection? get serverSelection => VpnServerChannel.instance.value;

  /// External IPv4/IPv6 fetched through the tunnel; refreshed on link
  /// recovery and on server change. Silent on session end - see
  /// [onServerSelectionChanged].
  Stream<VpnExternalIp> get onExternalIpChanged => VpnIpChannel.instance.stream;

  ValueListenable<VpnExternalIp?> get externalIpListenable =>
      VpnIpChannel.instance.listenable;

  /// Null until the first in-tunnel fetch completes.
  VpnExternalIp? get externalIp => VpnIpChannel.instance.value;

  int _maxLogLines = 500;
  int _maxConnEvents = 100;
  bool _fileLogging = false;
  final List<VpnLog> _logRing = <VpnLog>[];
  final List<VpnConnEvent> _connRing = <VpnConnEvent>[];
  StreamSubscription<VpnLog>? _logRetentionSub;
  StreamSubscription<VpnConnEvent>? _connRetentionSub;
  IOSink? _logSink;
  String? _logFilePath;

  List<VpnLog> get recentLogs => List.unmodifiable(_logRing);

  List<VpnConnEvent> get recentConns => List.unmodifiable(_connRing);

  bool get fileLoggingEnabled => _fileLogging;

  /// Ring caps (<=0 ignored). [toFile] mirrors logs to a temp file, one line
  /// each, stamped with the core's time in UTC.
  Future<void> configureLogging({
    int? maxLogLines,
    int? maxConnEvents,
    bool? toFile,
  }) async {
    if (maxLogLines != null && maxLogLines > 0) {
      _maxLogLines = maxLogLines;
      _trimRing(_logRing, _maxLogLines);
    }
    if (maxConnEvents != null && maxConnEvents > 0) {
      _maxConnEvents = maxConnEvents;
      _trimRing(_connRing, _maxConnEvents);
    }
    if (toFile != null && toFile != _fileLogging) {
      _fileLogging = toFile;
      if (toFile) {
        await _openLogFile();
      } else {
        await _closeLogFile();
      }
    }
  }

  Future<String?> getLogFilePath() async => _logFilePath;

  Future<void> clearLogFile() async {
    _logRing.clear();
    _connRing.clear();
    if (_logFilePath != null) {
      // Reopen truncated so the sink keeps writing.
      final wasOn = _fileLogging;
      await _closeLogFile();
      try {
        await File(_logFilePath!).writeAsString('');
      } catch (_) {}
      if (wasOn) await _openLogFile();
    }
  }

  static void _trimRing(List<Object?> ring, int cap) {
    if (ring.length > cap) {
      ring.removeRange(0, ring.length - cap);
    }
  }

  Future<void> _openLogFile() async {
    try {
      _logFilePath ??=
          '${Directory.systemTemp.path}${Platform.pathSeparator}glitch_vpn_core.log';
      _logSink = File(_logFilePath!).openWrite(mode: FileMode.writeOnlyAppend);
    } catch (_) {
      _logSink = null;
    }
  }

  Future<void> _closeLogFile() async {
    final s = _logSink;
    _logSink = null;
    if (s != null) {
      try {
        await s.flush();
        await s.close();
      } catch (_) {}
    }
  }

  void _startLogRetention() {
    _logRetentionSub ??= onLogsChanged.listen((log) {
      _logRing.add(log);
      _trimRing(_logRing, _maxLogLines);
      final sink = _logSink;
      if (_fileLogging && sink != null) {
        try {
          final source = log.component.isEmpty ? '' : '${log.component}: ';
          sink.writeln(
            '${log.at.toIso8601String()} ${log.level.name} $source${log.message}',
          );
        } catch (_) {}
      }
    });
    _connRetentionSub ??= onConnEvent.listen((c) {
      _connRing.add(c);
      _trimRing(_connRing, _maxConnEvents);
    });
  }

  VpnStatusUpdate get status => VpnStatusChannel.instance.value;

  GlitchVpnCoreConfig _config = const GlitchVpnCoreConfig();

  GlitchVpnCoreConfig get config => _config;

  void configure({
    int? logLevel,
    String? dnsAddress,
    int? tunMtu,
    int? tunUdpTimeoutSeconds,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
  }) {
    _config = _config.copyWith(
      logLevel: logLevel,
      dnsAddress: dnsAddress,
      tunMtu: tunMtu,
      tunUdpTimeoutSeconds: tunUdpTimeoutSeconds,
      splitTunnelingType: splitTunnelingType,
      splitTunnelingApps: splitTunnelingApps,
    );
  }

  static bool _handlerInstalled = false;
  static String? _activeTunnel;
  static bool _ffiReady = false;
  static bool _coreUsesService = false;
  static Future<void> Function()? _onDisconnectPressedHandler;

  static String _activeProxyUser = '';
  static String _activeProxyPass = '';

  /// Active proxy-mode SOCKS creds, or null. Random unless [proxyUser]/[proxyPass] set.
  ({String user, String pass})? get proxyCredentials => _activeProxyUser.isEmpty
      ? null
      : (user: _activeProxyUser, pass: _activeProxyPass);

  (String, String) _resolveProxyCreds(String? user, String? pass) {
    final u = (user != null && user.trim().isNotEmpty)
        ? user.trim()
        : 'glitch-${_randomCred(6)}';
    final p = (pass != null && pass.trim().isNotEmpty)
        ? pass.trim()
        : _randomCred(24);
    _activeProxyUser = u;
    _activeProxyPass = p;
    return (u, p);
  }

  static const _credAlphabet =
      'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789';

  static String _randomCred(int n) {
    final r = Random.secure();
    return String.fromCharCodes(
      List.generate(
        n,
        (_) => _credAlphabet.codeUnitAt(r.nextInt(_credAlphabet.length)),
      ),
    );
  }

  /// Native disconnect request (e.g. notification). Unset → plugin disconnects.
  static void registerDisconnectPressedHandler(
    Future<void> Function()? handler,
  ) {
    _onDisconnectPressedHandler = handler;
  }

  /// Preload native lib off the UI isolate.
  static Future<void> preloadNativeLibrary() async {
    try {
      await GlitchVpnCoreFfi.preloadInBackground();
    } catch (e) {
      debugPrint('GlitchVpnCore: preloadNativeLibrary failed: $e');
    }
  }

  /// Windows MSI service present.
  static Future<bool> isServiceAvailable() => _isWindowsCoreServiceAvailable();

  /// Idempotent; call on every UI restore.
  static Future<void> initialize() async {
    if (!_ffiReady) {
      // Debug: in-process core (not the installed service). Before InitializeController.
      if (kDebugMode && Platform.isWindows) {
        GlitchVpnCoreFfi.instance.setUseServiceIPC(false);
        _coreUsesService = false;
      } else if (Platform.isWindows) {
        _coreUsesService = true;
      }
      // Before InitializeController (reads GLITCH_PPROF_ADDR).
      if (kDebugMode) {
        GlitchVpnCoreFfi.instance.setEnvVar(
          'GLITCH_PPROF_ADDR',
          '127.0.0.1:6060',
        );
      }
      await GlitchVpnCoreFfi.instance.initialize();
      _ffiReady = true;
    }

    if (!_handlerInstalled) {
      _ch.setMethodCallHandler(_onNativeCall);
      _handlerInstalled = true;
    }

    // Re-register after UI restore / process death.
    GlitchVpnCoreFfi.instance.registerStatus(_onCoreEvent);

    instance._startLogRetention();

    try {
      final active = GlitchVpnCoreFfi.instance.activeEngine();
      if (active.isNotEmpty) {
        _activeTunnel = active;
        VpnStatusChannel.instance.emit(VpnStatus.connected);
        GlitchVpnCoreFfi.instance.listenStats(1000);
      } else {
        VpnStatusChannel.instance.emit(VpnStatus.disconnected);
      }
    } catch (_) {}
  }

  static bool isRunning() =>
      GlitchVpnCoreFfi.instance.activeEngine().isNotEmpty;

  static void registerStatus(void Function(int, String) cb) {
    GlitchVpnCoreFfi.instance.registerStatus(cb);
  }

  static Future<String?> getPlatformVersion() =>
      _ch.invokeMethod<String>('getPlatformVersion');

  static Future<bool> _isWindowsCoreServiceAvailable() async {
    if (!Platform.isWindows) return false;
    try {
      final ok = await _ch.invokeMethod<bool>('serviceAvailable');
      return ok ?? false;
    } on PlatformException {
      return false;
    } on MissingPluginException {
      return false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isAnyVpnActive() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _ch.invokeMethod<bool>('isAnyVpnActive');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  /// true = battery-optimized (bad for VPN).
  static Future<bool> isBatteryOptimized() async {
    if (!Platform.isAndroid) return false;
    try {
      final result = await _ch.invokeMethod<bool>('isBatteryOptimized');
      return result ?? true;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestIgnoreBatteryOptimization() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _ch.invokeMethod<bool>(
        'requestIgnoreBatteryOptimization',
      );
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> requestVpnPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      final result = await _ch.invokeMethod<bool>('requestVpnPermission');
      return result ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<bool> isAdmin() async {
    if (!Platform.isWindows) return true;
    final ok = await _ch.invokeMethod<bool>('checkAdmin');
    return ok ?? false;
  }

  /// True when elevation launched a new process (this one will exit).
  static Future<bool> requestAdmin() async {
    if (!Platform.isWindows) return true;
    final launched = await _ch.invokeMethod<bool>('requestAdmin');
    return launched ?? false;
  }

  /// False if UAC was triggered and this process is about to exit.
  static Future<bool> ensureAdmin() async {
    if (!Platform.isWindows) return true;

    // Debug runs in-process: a leftover installed service must not skip UAC.
    if (_coreUsesService && await _isWindowsCoreServiceAvailable()) {
      return true;
    }

    final admin = await isAdmin();
    if (admin) return true;
    await requestAdmin();
    // If requestAdmin launched an elevated process, this one exits shortly.
    return false;
  }

  /// Android 13+ POST_NOTIFICATIONS. false = prompt shown (VPN connects anyway).
  static Future<bool> requestNotificationPermission() async {
    if (!Platform.isAndroid) return true;
    try {
      return await _ch.invokeMethod<bool>('requestNotificationPermission') ??
          true;
    } catch (_) {
      return true;
    }
  }

  static String _extractWgAddress(String config) {
    final lines = config.split('\n');
    var inInterface = false;
    for (final raw in lines) {
      final line = raw.trim();
      if (line.startsWith('[')) {
        inInterface = line.toLowerCase().contains('interface');
        continue;
      }
      if (!inInterface) continue;
      if (line.toLowerCase().startsWith('address')) {
        final idx = line.indexOf('=');
        if (idx == -1) continue;
        var val = line.substring(idx + 1).trim();
        val = val.split(RegExp('[, ;]')).first.trim();
        if (val.isNotEmpty) return val;
      }
    }
    return '10.0.0.2/32';
  }

  static String _extractWgDns(String config) {
    for (final raw in config.split('\n')) {
      final line = raw.trim();
      if (line.toLowerCase().startsWith('dns')) {
        final idx = line.indexOf('=');
        if (idx == -1) continue;
        final val = line.substring(idx + 1).split(RegExp('[, ;]')).first.trim();
        if (val.isNotEmpty) return val;
      }
    }
    return '';
  }

  /// The TUN fd. A refusal leaves the status at error, not connecting, so the
  /// next [connect] is not refused as busy; the platform's code passes through.
  static Future<int> _prepareTunnel(Map<String, Object?> args) async {
    final int? fd;
    try {
      fd = await _ch.invokeMethod<int>('prepareTunnel', args);
    } on PlatformException catch (e) {
      VpnStatusChannel.instance.emit(
        VpnStatus.error,
        reason: 'prepareTunnel error: ${e.code}',
      );
      rethrow;
    } on Object catch (e) {
      VpnStatusChannel.instance.emit(
        VpnStatus.error,
        reason: 'prepareTunnel error: ${e.runtimeType}',
      );
      rethrow;
    }
    if (fd == null || fd == -1) {
      throw _refuse('PREPARE_TUNNEL_FAILED', 'prepareTunnel failed');
    }
    return fd;
  }

  static Future<void> stopTunnel() => _ch.invokeMethod('stopTunnel');
  static Future<void> _stopTunnelSilently() async {
    _activeProxyUser = '';
    _activeProxyPass = '';
    try {
      await stopTunnel();
    } catch (_) {}
  }

  /// Android only. A null argument keeps what the notification shows;
  /// [texts] replaces the words [connect] was given (a change of language).
  /// [countryLine] heads the connected notification, above the traffic
  /// counter the plugin keeps itself.
  Future<void> updateNotification({
    VpnNotificationTexts? texts,
    String? countryLine,
  }) async {
    if (!Platform.isAndroid) return;
    await _ch.invokeMethod('updateNotification', {
      'notification': ?texts?.toMap(),
      'countryLine': ?countryLine,
    });
  }

  // Best-effort: the notification follows the session, it never decides it.
  static Future<void> _showNotificationPhase(String phase) async {
    if (!Platform.isAndroid) return;
    try {
      await _ch.invokeMethod('showNotificationPhase', {'phase': phase});
    } catch (_) {}
  }

  /// Throws [PlatformException] when the start is refused, and every refusal
  /// but `BUSY` also sets [onStatusChanged] to error. A start the core accepts
  /// and that fails afterwards (a bad link, missing geo files, a failed
  /// handshake) does not throw: it arrives on [onStatusChanged] only.
  ///
  /// The exception's message is the status reason, word for word:
  /// - `ENGINE_NOT_IN_BUILD`, `UNSUPPORTED_STRATEGY` ([balancerStrategiesFor]),
  ///   `UNSUPPORTED_DOMAIN_STRATEGY` ([domainStrategiesFor]),
  ///   `RELATIVE_GEO_PATH`, `PROXY_NOT_SUPPORTED` (awg with `proxyPort`):
  ///   refused before anything starts.
  /// - `ELEVATION_REQUIRED`: Windows without admin rights; [ensureAdmin] may
  ///   already be relaunching the app elevated.
  /// - `PREPARE_TUNNEL_FAILED`: Android gave no TUN fd.
  ///
  /// The exception carries its source's own message:
  /// - `BUSY`: a session is connecting or connected and keeps its status.
  /// - Android's code from preparing the tunnel (`DENIED`,
  ///   `NOTIFICATIONS_DENIED`, `TUN_ERROR`, ...); the status reason names it.
  /// - `XRAY_START_FAILED`, `AWG_START_FAILED`, `MIHOMO_START_FAILED`: the
  ///   core refused the start; the status reason is its result code.
  ///
  /// [notification] is shown on Android and ignored elsewhere.
  Future<void> connect({
    required VpnEngine engine,
    required String config,
    required VpnNotificationTexts notification,
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    String balancerStrategy = '',
    VpnRouting? routing,
    VpnDns? dns,
    // Absolute dir with geoip.dat/geosite.dat; xray/mihomo only. Empty falls
    // back to the engine default, which exists on desktop (beside the core
    // binary) but not on Android — geo rules there need this set. Failure
    // modes are in the README.
    String geoAssetsDir = '',
    // xray only: one of [domainStrategiesFor]; empty → engine default (asis).
    // Non-asis leaks lookups to the direct outbound under fake-ip — README.
    String domainStrategy = '',
    int? proxyPort,
    bool proxyAuth = true, // false → open loopback SOCKS (proxy mode only)
    String? proxyUser, // null → random; read back via [proxyCredentials]
    String? proxyPass,
    // Off kills domain routing in normal DNS mode; fake-ip→domain stays on.
    bool sniffing = true,
    String probeUrl = '', // empty → engine default
    int? livenessIntervalSec, // 10..300, default 20
    // xray only: null/0 off; >0 TCP mux N; <0 mux-capable, TCP off. Vision always off.
    int? muxConcurrency,
    int? xudpConcurrency,
    String fingerprint = '', // one of [fingerprintsFor]; empty keeps link's
    // External-IP resolution through the tunnel → [onExternalIpChanged].
    bool resolveExternalIp = true,
    String ipv4EchoUrl = '', // empty → core default (api.ipify.org)
    String ipv6EchoUrl = '', // empty → core default (api6.ipify.org)
  }) async {
    await _withTransitionLock(() async {
      final currentStatus = VpnStatusChannel.instance.value.status;

      if (currentStatus == VpnStatus.disconnecting ||
          currentStatus == VpnStatus.error) {
        debugPrint(
          'GlitchVpnCore.connect: force cleanup from stale status $currentStatus',
        );
        await _stopTunnelSilently();
        _activeTunnel = null;
        VpnStatusChannel.instance.emit(VpnStatus.disconnected);
        // Let listeners react to the forced disconnected state.
        await Future.delayed(const Duration(milliseconds: 100));
      } else if (currentStatus != VpnStatus.disconnected) {
        // No status: the session in progress keeps its own.
        throw PlatformException(
          code: 'BUSY',
          message: 'connect() while ${currentStatus.name}',
        );
      }

      final engines = await engineIds();
      if (engines.isNotEmpty && !engines.contains(engine.name)) {
        throw _refuse(
          'ENGINE_NOT_IN_BUILD',
          'Engine "${engine.name}" is not in this build (available: ${engines.join(', ')})',
        );
      }

      if (balancerStrategy.isNotEmpty &&
          !balancerStrategiesFor(engine).contains(balancerStrategy)) {
        throw _refuse(
          'UNSUPPORTED_STRATEGY',
          'Balancer "$balancerStrategy" not supported by ${engine.name}',
        );
      }

      final effectiveDomainStrategy = domainStrategy.trim();
      if (effectiveDomainStrategy.isNotEmpty &&
          !domainStrategiesFor(engine).contains(effectiveDomainStrategy)) {
        throw _refuse(
          'UNSUPPORTED_DOMAIN_STRATEGY',
          'domainStrategy "$domainStrategy" not supported by ${engine.name}',
        );
      }

      // The engine may run in the service process whose working directory the
      // caller cannot know - a relative dir would silently fall back to the
      // default and evaluate geo rules against the wrong database.
      final effectiveGeoAssetsDir = geoAssetsDir.trim();
      if (effectiveGeoAssetsDir.isNotEmpty &&
          !debugIsAbsolutePath(effectiveGeoAssetsDir)) {
        throw _refuse(
          'RELATIVE_GEO_PATH',
          'geoAssetsDir "$geoAssetsDir" must be an absolute path',
        );
      }

      if (proxyPort != null && engine == VpnEngine.awg) {
        throw _refuse('PROXY_NOT_SUPPORTED', 'awg has no proxy mode (use TUN)');
      }

      _activeProxyUser = '';
      _activeProxyPass = '';

      switch (engine) {
        case VpnEngine.xray:
          await _connectXrayCore(
            config,
            notification: notification,
            dnsAddress: dnsAddress,
            logLevel: logLevel,
            splitTunnelingType: splitTunnelingType,
            splitTunnelingApps: splitTunnelingApps,
            balancerStrategy: balancerStrategy,
            routing: routing,
            dns: dns,
            geoAssetsDir: effectiveGeoAssetsDir,
            domainStrategy: effectiveDomainStrategy,
            proxyPort: proxyPort,
            proxyAuth: proxyAuth,
            proxyUser: proxyUser,
            proxyPass: proxyPass,
            sniffing: sniffing,
            probeUrl: probeUrl,
            livenessIntervalSec: livenessIntervalSec,
            muxConcurrency: muxConcurrency,
            xudpConcurrency: xudpConcurrency,
            fingerprint: fingerprint,
            resolveExternalIp: resolveExternalIp,
            ipv4EchoUrl: ipv4EchoUrl,
            ipv6EchoUrl: ipv6EchoUrl,
          );
          break;
        case VpnEngine.awg:
          await _connectAwgCore(
            config,
            notification: notification,
            dnsAddress: dnsAddress,
            splitTunnelingType: splitTunnelingType,
            splitTunnelingApps: splitTunnelingApps,
            dns: dns,
            balancerStrategy: balancerStrategy,
            probeUrl: probeUrl,
            livenessIntervalSec: livenessIntervalSec,
            resolveExternalIp: resolveExternalIp,
            ipv4EchoUrl: ipv4EchoUrl,
            ipv6EchoUrl: ipv6EchoUrl,
          );
          break;
        case VpnEngine.mihomo:
          await _connectMihomoCore(
            config,
            notification: notification,
            dnsAddress: dnsAddress,
            logLevel: logLevel,
            splitTunnelingType: splitTunnelingType,
            splitTunnelingApps: splitTunnelingApps,
            dns: dns,
            balancerStrategy: balancerStrategy,
            routing: routing,
            geoAssetsDir: effectiveGeoAssetsDir,
            proxyPort: proxyPort,
            proxyAuth: proxyAuth,
            proxyUser: proxyUser,
            proxyPass: proxyPass,
            sniffing: sniffing,
            probeUrl: probeUrl,
            livenessIntervalSec: livenessIntervalSec,
            fingerprint: fingerprint,
            resolveExternalIp: resolveExternalIp,
            ipv4EchoUrl: ipv4EchoUrl,
            ipv6EchoUrl: ipv6EchoUrl,
          );
          break;
      }
    });
  }

  /// Skips [connect]'s checks. Throws `ELEVATION_REQUIRED` on Windows without
  /// admin rights, and otherwise the codes [connect] lists from preparing the
  /// tunnel on.
  Future<void> connectXray(
    String config, {
    required VpnNotificationTexts notification,
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    String balancerStrategy = '',
    VpnRouting? routing,
  }) async {
    await _withTransitionLock(() async {
      await _connectXrayCore(
        config,
        notification: notification,
        dnsAddress: dnsAddress,
        logLevel: logLevel,
        splitTunnelingType: splitTunnelingType,
        splitTunnelingApps: splitTunnelingApps,
        balancerStrategy: balancerStrategy,
        routing: routing,
      );
    });
  }

  static PlatformException _refuse(String code, String reason) {
    VpnStatusChannel.instance.emit(VpnStatus.error, reason: reason);
    return PlatformException(code: code, message: reason);
  }

  // ensureAdmin() returning false may mean a UAC relaunch is under way and
  // this process is about to exit; the caller decides whether to say so.
  static PlatformException _refuseNotElevated() =>
      _refuse('ELEVATION_REQUIRED', 'Admin rights are required');

  // A throw after the connecting status must not leave it there: the next
  // connect() would read it as busy. Only the type goes into the reason, since
  // an FFI error may quote what it was handed.
  static T _withErrorStatus<T>(String step, T Function() call) {
    try {
      return call();
    } on Object catch (e) {
      VpnStatusChannel.instance.emit(
        VpnStatus.error,
        reason: '$step failed: ${e.runtimeType}',
      );
      rethrow;
    }
  }

  // Listeners must not show the previous session's data while a new tunnel
  // is coming up.
  static void _resetSessionChannels() {
    VpnServerChannel.instance.reset();
    VpnIpChannel.instance.reset();
  }

  /// Mirrors Go's `filepath.IsAbs` for the running platform.
  @visibleForTesting
  static bool debugIsAbsolutePath(String p, {bool? windows}) =>
      (windows ?? Platform.isWindows)
      ? RegExp(r'^([A-Za-z]:[\\/]|\\\\)').hasMatch(p)
      : p.startsWith('/');

  static void _applyIpResolveOpts(
    Map<String, String> opts, {
    required bool resolveExternalIp,
    required String ipv4EchoUrl,
    required String ipv6EchoUrl,
  }) {
    if (!resolveExternalIp) opts['resolveExternalIp'] = '0';
    if (ipv4EchoUrl.trim().isNotEmpty) opts['ipv4EchoUrl'] = ipv4EchoUrl.trim();
    if (ipv6EchoUrl.trim().isNotEmpty) opts['ipv6EchoUrl'] = ipv6EchoUrl.trim();
  }

  Future<void> _connectXrayCore(
    String config, {
    required VpnNotificationTexts notification,
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    String balancerStrategy = '',
    VpnRouting? routing,
    VpnDns? dns,
    String geoAssetsDir = '',
    String domainStrategy = '',
    int? proxyPort,
    bool proxyAuth = true,
    String? proxyUser,
    String? proxyPass,
    bool sniffing = true,
    String probeUrl = '',
    int? livenessIntervalSec,
    int? muxConcurrency,
    int? xudpConcurrency,
    String fingerprint = '',
    bool resolveExternalIp = true,
    String ipv4EchoUrl = '',
    String ipv6EchoUrl = '',
  }) async {
    await initialize();
    // Proxy mode exposes a loopback SOCKS - no TUN, so no admin/prepareTunnel.
    final proxyMode = proxyPort != null;
    if (!proxyMode) {
      if (!await ensureAdmin()) throw _refuseNotElevated();
    }

    final effectiveDns = (dnsAddress ?? _config.dnsAddress).trim();
    final effectiveLog = logLevel ?? _config.logLevel;
    final effectiveTunMtu = _config.tunMtu;
    final effectiveTunUdpTimeoutSeconds = _config.tunUdpTimeoutSeconds;
    final effectiveSplitType = splitTunnelingType ?? _config.splitTunnelingType;
    final effectiveSplitApps = splitTunnelingApps ?? _config.splitTunnelingApps;

    VpnStatusChannel.instance.emit(VpnStatus.connecting);
    _resetSessionChannels();

    int fd = -1;
    if (Platform.isAndroid && !proxyMode) {
      fd = await _prepareTunnel({
        'notification': notification.toMap(),
        'dns': effectiveDns,
        'mtu': effectiveTunMtu,
        'splitType': effectiveSplitType.name,
        'splitApps': effectiveSplitApps,
      });
    }
    _withErrorStatus(
      'SetTun2SocksConfig',
      () => GlitchVpnCoreFfi.instance.setTun2SocksConfig(
        mtu: effectiveTunMtu,
        udpTimeoutSeconds: effectiveTunUdpTimeoutSeconds,
      ),
    );

    final opts = <String, String>{...?routing?.toOpts()};
    if (balancerStrategy.isNotEmpty) {
      opts['balancerStrategy'] = balancerStrategy;
    }
    // connect() already trimmed and validated both.
    if (geoAssetsDir.isNotEmpty) opts['geoAssetsDir'] = geoAssetsDir;
    if (domainStrategy.isNotEmpty) opts['domainStrategy'] = domainStrategy;
    if (proxyMode) {
      opts['proxyPort'] = '$proxyPort';
      if (proxyAuth) {
        final (u, p) = _resolveProxyCreds(proxyUser, proxyPass);
        opts['proxyUser'] = u;
        opts['proxyPass'] = p;
      }
    }
    if (!sniffing) opts['sniffing'] = '0';
    if (probeUrl.trim().isNotEmpty) opts['probeUrl'] = probeUrl.trim();
    if (livenessIntervalSec != null) {
      opts['livenessIntervalSec'] = '$livenessIntervalSec';
    }
    if (muxConcurrency != null) opts['muxConcurrency'] = '$muxConcurrency';
    if (xudpConcurrency != null) opts['xudpConcurrency'] = '$xudpConcurrency';
    if (fingerprint.trim().isNotEmpty) opts['fingerprint'] = fingerprint.trim();
    _applyIpResolveOpts(
      opts,
      resolveExternalIp: resolveExternalIp,
      ipv4EchoUrl: ipv4EchoUrl,
      ipv6EchoUrl: ipv6EchoUrl,
    );

    final res = _withErrorStatus(
      'EngineStart',
      () => GlitchVpnCoreFfi.instance.engineStart(
        'xray',
        config: config,
        tunFd: fd,
        dns: effectiveDns,
        logLevel: effectiveLog,
        opts: opts,
        dnsConfig: dns?.toJson(),
      ),
    );
    if (res == 0) {
      _activeTunnel = 'xray';
    } else {
      VpnStatusChannel.instance.emit(
        VpnStatus.error,
        reason: 'EngineStart=$res',
      );
      throw PlatformException(
        code: 'XRAY_START_FAILED',
        message: 'EngineStart(xray)=$res',
      );
    }
  }

  /// Skips [connect]'s checks. Throws `ELEVATION_REQUIRED` on Windows without
  /// admin rights, and otherwise the codes [connect] lists from preparing the
  /// tunnel on.
  Future<void> connectAwg(
    String config, {
    required VpnNotificationTexts notification,
    String? dnsAddress,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
  }) async {
    await _withTransitionLock(() async {
      await _connectAwgCore(
        config,
        notification: notification,
        dnsAddress: dnsAddress,
        splitTunnelingType: splitTunnelingType,
        splitTunnelingApps: splitTunnelingApps,
      );
    });
  }

  Future<void> _connectAwgCore(
    String config, {
    required VpnNotificationTexts notification,
    String? dnsAddress,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    VpnDns? dns,
    String balancerStrategy = '',
    String probeUrl = '',
    int? livenessIntervalSec,
    bool resolveExternalIp = true,
    String ipv4EchoUrl = '',
    String ipv6EchoUrl = '',
  }) async {
    await initialize();
    if (!await ensureAdmin()) throw _refuseNotElevated();

    final effectiveDns = (dnsAddress ?? _config.dnsAddress).trim();
    final effectiveSplitType = splitTunnelingType ?? _config.splitTunnelingType;
    final effectiveSplitApps = splitTunnelingApps ?? _config.splitTunnelingApps;

    // awg is L3 - only a plain resolver applies (no DoH/DoT/fake-ip).
    String awgDns = '';
    for (final s in (dns?.servers ?? const <String>[])) {
      if (!s.contains('://') && s.trim().isNotEmpty) {
        awgDns = s.trim();
        break;
      }
    }
    if (awgDns.isEmpty) awgDns = _extractWgDns(config);
    if (awgDns.isEmpty) awgDns = effectiveDns;

    VpnStatusChannel.instance.emit(VpnStatus.connecting);
    _resetSessionChannels();

    String addr = _extractWgAddress(config);
    int fd = -1;
    if (Platform.isAndroid) {
      fd = await _prepareTunnel({
        'notification': notification.toMap(),
        'addresses': [addr],
        'dns': awgDns,
        'splitType': effectiveSplitType.name,
        'splitApps': effectiveSplitApps,
      });
    }
    final awgOpts = <String, String>{
      if (balancerStrategy.isNotEmpty) 'balancerStrategy': balancerStrategy,
      if (probeUrl.trim().isNotEmpty) 'probeUrl': probeUrl.trim(),
      if (livenessIntervalSec != null)
        'livenessIntervalSec': '$livenessIntervalSec',
    };
    _applyIpResolveOpts(
      awgOpts,
      resolveExternalIp: resolveExternalIp,
      ipv4EchoUrl: ipv4EchoUrl,
      ipv6EchoUrl: ipv6EchoUrl,
    );
    final res = _withErrorStatus(
      'EngineStart',
      () => GlitchVpnCoreFfi.instance.engineStart(
        'awg',
        config: config,
        tunFd: fd,
        dns: awgDns,
        logLevel: _config.logLevel,
        opts: awgOpts,
      ),
    );
    if (res == 0) {
      _activeTunnel = 'awg';
    } else {
      VpnStatusChannel.instance.emit(
        VpnStatus.error,
        reason: 'EngineStart=$res',
      );
      throw PlatformException(
        code: 'AWG_START_FAILED',
        message: 'EngineStart(awg)=$res',
      );
    }
  }

  Future<void> _connectMihomoCore(
    String config, {
    required VpnNotificationTexts notification,
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    VpnDns? dns,
    String balancerStrategy = '',
    VpnRouting? routing,
    String geoAssetsDir = '',
    int? proxyPort,
    bool proxyAuth = true,
    String? proxyUser,
    String? proxyPass,
    bool sniffing = true,
    String probeUrl = '',
    int? livenessIntervalSec,
    String fingerprint = '',
    bool resolveExternalIp = true,
    String ipv4EchoUrl = '',
    String ipv6EchoUrl = '',
  }) async {
    await initialize();
    // Proxy mode exposes a loopback mixed inbound - no TUN, so no admin/prepareTunnel.
    final proxyMode = proxyPort != null;
    if (!proxyMode) {
      if (!await ensureAdmin()) throw _refuseNotElevated();
    }

    final effectiveDns = (dnsAddress ?? _config.dnsAddress).trim();
    final effectiveLog = logLevel ?? _config.logLevel;
    final effectiveSplitType = splitTunnelingType ?? _config.splitTunnelingType;
    final effectiveSplitApps = splitTunnelingApps ?? _config.splitTunnelingApps;

    VpnStatusChannel.instance.emit(VpnStatus.connecting);
    _resetSessionChannels();

    int fd = -1;
    if (Platform.isAndroid && !proxyMode) {
      fd = await _prepareTunnel({
        'notification': notification.toMap(),
        'dns': effectiveDns,
        'mtu': _config.tunMtu,
        'splitType': effectiveSplitType.name,
        'splitApps': effectiveSplitApps,
      });
    }

    final opts = <String, String>{...?routing?.toOpts()};
    if (balancerStrategy.isNotEmpty) {
      opts['balancerStrategy'] = balancerStrategy;
    }
    // connect() already trimmed and validated it.
    if (geoAssetsDir.isNotEmpty) opts['geoAssetsDir'] = geoAssetsDir;
    if (proxyMode) {
      opts['proxyPort'] = '$proxyPort';
      if (proxyAuth) {
        final (u, p) = _resolveProxyCreds(proxyUser, proxyPass);
        opts['proxyUser'] = u;
        opts['proxyPass'] = p;
      }
    }
    if (!sniffing) opts['sniffing'] = '0';
    if (probeUrl.trim().isNotEmpty) opts['probeUrl'] = probeUrl.trim();
    if (livenessIntervalSec != null) {
      opts['livenessIntervalSec'] = '$livenessIntervalSec';
    }
    if (fingerprint.trim().isNotEmpty) opts['fingerprint'] = fingerprint.trim();
    _applyIpResolveOpts(
      opts,
      resolveExternalIp: resolveExternalIp,
      ipv4EchoUrl: ipv4EchoUrl,
      ipv6EchoUrl: ipv6EchoUrl,
    );

    final res = _withErrorStatus(
      'EngineStart',
      () => GlitchVpnCoreFfi.instance.engineStart(
        'mihomo',
        config: config,
        tunFd: fd,
        dns: effectiveDns,
        logLevel: effectiveLog,
        opts: opts,
        dnsConfig: dns?.toJson(),
      ),
    );
    if (res == 0) {
      _activeTunnel = 'mihomo';
    } else {
      VpnStatusChannel.instance.emit(
        VpnStatus.error,
        reason: 'EngineStart=$res',
      );
      throw PlatformException(
        code: 'MIHOMO_START_FAILED',
        message: 'EngineStart(mihomo)=$res',
      );
    }
  }

  Future<void> disconnect() async {
    await _withTransitionLock(() async {
      if (VpnStatusChannel.instance.value.status == VpnStatus.disconnected) {
        return;
      }

      await _showNotificationPhase('disconnecting');
      VpnStatusChannel.instance.emit(VpnStatus.disconnecting);

      // `_activeTunnel` may be empty after UI restore.
      String engine = _activeTunnel ?? '';
      try {
        final active = GlitchVpnCoreFfi.instance.activeEngine();
        if (active.isNotEmpty) engine = active;
      } catch (_) {}

      if (engine.isNotEmpty) {
        GlitchVpnCoreFfi.instance.engineStop(engine);
      } else {
        // No running core: 504 will never arrive to do the cleanup.
        await _stopTunnelSilently();
        _activeTunnel = null;
        _resetSessionChannels();
        VpnStatusChannel.instance.emit(VpnStatus.disconnected);
        return;
      }
    });
  }

  static Future<void> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'onDisconnectPressed':
        VpnStatusChannel.instance.emit(VpnStatus.disconnecting);
        if (_onDisconnectPressedHandler != null) {
          try {
            await _onDisconnectPressedHandler!.call();
          } catch (e) {
            debugPrint(
              'GlitchVpnCore: onDisconnectPressed handler failed: $e. Falling back to direct disconnect.',
            );
            await GlitchVpnCore.instance.disconnect();
          }
        } else {
          await GlitchVpnCore.instance.disconnect();
        }
        break;
      default:
        break;
    }
  }

  static Future<void> _onCoreEvent(int code, Object? msg) async {
    final ev = GlitchVpnCoreFfiEventCode.fromCode(code);
    final curr = VpnStatusChannel.instance.value.status;
    final reason = (msg?.toString().trim().isEmpty ?? true)
        ? null
        : msg.toString();

    switch (ev) {
      case GlitchVpnCoreFfiEventCode.engineConnecting:
        if (curr != VpnStatus.error) {
          VpnStatusChannel.instance.emit(VpnStatus.connecting);
        }
        break;

      case GlitchVpnCoreFfiEventCode.engineConnected:
      case GlitchVpnCoreFfiEventCode.engineAlreadyRunning:
        VpnStatusChannel.instance.emit(VpnStatus.connected);
        await _showNotificationPhase('connected');
        break;

      case GlitchVpnCoreFfiEventCode.engineConflictOtherCore:
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: reason ?? 'core conflict',
        );
        await _stopTunnelSilently();
        _activeTunnel = null;
        _resetSessionChannels();
        break;

      case GlitchVpnCoreFfiEventCode.engineDisconnecting:
        if (curr != VpnStatus.error) {
          VpnStatusChannel.instance.emit(VpnStatus.disconnecting);
        }
        break;

      case GlitchVpnCoreFfiEventCode.engineDisconnected:
        // Keep ERROR status; only tear down the tunnel.
        if (VpnStatusChannel.instance.value.status == VpnStatus.error) {
          await _stopTunnelSilently();
          _activeTunnel = null;
          _resetSessionChannels();
          break;
        }
        await _stopTunnelSilently();
        _activeTunnel = null;
        _resetSessionChannels();
        VpnStatusChannel.instance.emit(VpnStatus.disconnected);
        break;

      case GlitchVpnCoreFfiEventCode.engineStopRejectedNotRunning:
        break;

      case GlitchVpnCoreFfiEventCode.engineError:
        VpnStatusChannel.instance.emit(VpnStatus.error, reason: reason);
        await _stopTunnelSilently();
        _activeTunnel = null;
        _resetSessionChannels();
        break;

      case GlitchVpnCoreFfiEventCode.statsEvent:
        try {
          final stats = jsonDecode(msg as String);
          final rx = (stats is Map) ? stats['rx'] as int? ?? 0 : 0;
          final tx = (stats is Map) ? stats['tx'] as int? ?? 0 : 0;
          final durationMs = (stats is Map)
              ? stats['durationMs'] as int? ?? 0
              : 0;
          final rssBytes = (stats is Map) ? stats['rssBytes'] as int? ?? 0 : 0;
          final goMemBytes = (stats is Map)
              ? stats['goMemBytes'] as int? ?? 0
              : 0;
          final linkUp = (stats is Map) ? stats['linkUp'] as bool? : null;
          final probeMs = (stats is Map) ? stats['probeMs'] as int? ?? -1 : -1;
          VpnStatsChannel.instance.emit(
            rx,
            tx,
            durationMs,
            rssBytes: rssBytes,
            goMemBytes: goMemBytes,
            linkUp: linkUp,
            probeMs: probeMs,
          );
        } catch (_) {}
        break;
      case GlitchVpnCoreFfiEventCode.connEvent:
        final conn = VpnConnEvent.tryParse(msg as String);
        if (conn != null) VpnConnChannel.instance.emit(conn);
        break;
      case GlitchVpnCoreFfiEventCode.serverEvent:
        final sel = VpnServerSelection.tryParse(msg as String);
        if (sel != null) VpnServerChannel.instance.emit(sel);
        break;
      case GlitchVpnCoreFfiEventCode.ipEvent:
        final ip = VpnExternalIp.tryParse(msg as String);
        if (ip != null) VpnIpChannel.instance.emit(ip);
        break;
      case GlitchVpnCoreFfiEventCode.statsError:
      case GlitchVpnCoreFfiEventCode.logEvent:
      case GlitchVpnCoreFfiEventCode.logError:
        final log = VpnLog.tryParse(msg as String);
        if (log != null) VpnLogsChannel.instance.emit(log);
        break;
    }
  }

  /// -1 OFF (default) · 0 errors · 1 info+warn · 2 all.
  static Future<void> setLogsVerbosity(int level) async {
    try {
      GlitchVpnCoreFfi.instance.setStatusVerbosity(level);
    } catch (_) {}
  }

  /// Emit per-connection events on [onConnEvent]. Default off.
  static Future<void> setConnectionInspector(bool enabled) async {
    await initialize();
    GlitchVpnCoreFfi.instance.setConnInspector(enabled);
  }

  /// Soft Go heap cap (not an OOM kill). Persists across connects.
  static Future<void> setMemoryLimit(MemoryLimit limit) async {
    await initialize();
    GlitchVpnCoreFfi.instance.setMemoryLimit(limit.bytes);
  }

  static Future<String> getCapabilitiesJson() async {
    await initialize();
    return GlitchVpnCoreFfi.instance.coreCapabilitiesJson();
  }

  static Set<String>? _engineIdsCache;

  /// Reads the capabilities JSON instead of [getCapabilitiesJson] when set,
  /// so the cache rule below is testable without the native library.
  @visibleForTesting
  static Future<String> Function()? debugCapabilitiesJsonProvider;

  @visibleForTesting
  static void debugResetEngineIdsCache() => _engineIdsCache = null;

  /// `{"engines": [...]}` → the string ids; anything malformed → empty set,
  /// never a throw (the payload crosses the FFI boundary).
  static Set<String> _parseEngineIds(String json) {
    final ids = <String>{};
    try {
      final decoded = jsonDecode(json);
      if (decoded is Map && decoded['engines'] is List) {
        for (final e in decoded['engines'] as List) {
          if (e is String) ids.add(e);
        }
      }
    } catch (_) {}
    return ids;
  }

  /// Engine ids linked in this binary. An empty result (garbled or failed
  /// read) is returned but never cached, so a later call retries instead of
  /// reporting "no engines" for the process lifetime.
  static Future<Set<String>> engineIds() async {
    final cached = _engineIdsCache;
    if (cached != null) return cached;
    var ids = const <String>{};
    try {
      final json =
          await (debugCapabilitiesJsonProvider?.call() ??
              getCapabilitiesJson());
      ids = _parseEngineIds(json);
    } catch (_) {
      // empty; treated as "unknown", callers fall back permissively
    }
    if (ids.isNotEmpty) _engineIdsCache = ids;
    return ids;
  }

  static Future<List<VpnEngine>> availableEngines() async {
    final ids = await engineIds();
    return VpnEngine.values.where((e) => ids.contains(e.name)).toList();
  }

  static String activeEngine() => GlitchVpnCoreFfi.instance.activeEngine();

  /// Answers the ping request instead of the native library when set, so the
  /// result parsing is testable without it.
  @visibleForTesting
  static Future<String> Function(String requestJson)?
  debugMeasurePingsJsonProvider;

  /// Url-test latency per link (through that server). No engine/admin/TUN needed.
  /// A link that fails carries its own [PingResult.error]; a run the core
  /// refuses as a whole throws [PlatformException] `PING_FAILED` with the
  /// core's reason as the message.
  static Future<List<PingResult>> measurePings(
    List<String> links, {
    String? probeUrl,
    int timeoutMs = 5000,
    int concurrency = 8,
  }) async {
    if (links.isEmpty) return const <PingResult>[];
    final request = jsonEncode({
      'links': links,
      if (probeUrl != null && probeUrl.trim().isNotEmpty) 'probeUrl': probeUrl,
      'timeoutMs': timeoutMs,
      'concurrency': concurrency,
    });
    final raw =
        await (debugMeasurePingsJsonProvider?.call(request) ??
            GlitchVpnCoreFfi.measurePings(request));
    Object? decoded;
    try {
      decoded = jsonDecode(raw);
    } catch (_) {}
    if (decoded is List) {
      return decoded
          .whereType<Map>()
          .map(PingResult.fromJson)
          .toList(growable: false);
    }
    final coreError = decoded is Map ? decoded['error']?.toString() : null;
    throw PlatformException(
      code: 'PING_FAILED',
      message: (coreError == null || coreError.isEmpty)
          ? 'unreadable ping results'
          : coreError,
    );
  }

  /// Reads the versions JSON instead of the native library when set, so the
  /// never-throws rule is testable without it.
  @visibleForTesting
  static Future<String> Function()? debugCoreVersionsJsonProvider;

  /// Never throws: a library that does not load reads as no versions at all.
  static Future<CoreVersions> getCoreVersions() async {
    try {
      final json =
          await (debugCoreVersionsJsonProvider?.call() ??
              _readCoreVersionsJson());
      return CoreVersions.tryParse(json) ?? const CoreVersions();
    } catch (_) {
      return const CoreVersions();
    }
  }

  static Future<String> _readCoreVersionsJson() async {
    await initialize();
    return GlitchVpnCoreFfi.instance.getCoreVersionsJson();
  }

  Future<AndroidAppsPage> appsListing(
    void Function(AndroidAppsPage)? callback, {
    int offset = 0,
    int? limit,
    bool includeSystem = false,
    String? query,
  }) async {
    if (!Platform.isAndroid) {
      final empty = AndroidAppsPage(items: const <AndroidAppInfo>[], total: 0);
      if (callback != null) callback(empty);
      return empty;
    }
    final args = <String, Object?>{
      'offset': offset,
      'includeSystem': includeSystem,
    };
    if (limit != null) args['limit'] = limit;
    if (query != null && query.trim().isNotEmpty) args['query'] = query.trim();
    final res = await _ch.invokeMethod('appsListing', args);
    final Map<dynamic, dynamic> map =
        (res as Map<dynamic, dynamic>? ?? const {});
    final List<dynamic> items = (map['items'] as List<dynamic>? ?? const []);
    final int total = (map['total'] as int?) ?? items.length;
    final list = <AndroidAppInfo>[];
    for (final it in items) {
      if (it is Map) {
        final pkg = it['package']?.toString() ?? '';
        final name = it['name']?.toString() ?? pkg;
        if (pkg.isNotEmpty) {
          list.add(AndroidAppInfo(packageName: pkg, appName: name));
        }
      }
    }
    final page = AndroidAppsPage(items: list, total: total);
    if (callback != null) callback(page);
    return page;
  }

  Future<Map<String, Uint8List>> appsIcon(
    List<String> packageNames,
    void Function(Map<String, Uint8List>)? callback,
  ) async {
    if (!Platform.isAndroid) {
      final empty = const <String, Uint8List>{};
      if (callback != null) callback(empty);
      return empty;
    }
    final res = await _ch.invokeMethod('appsIcon', {'packages': packageNames});
    final Map<dynamic, dynamic> map =
        (res as Map<dynamic, dynamic>? ?? const {});
    final out = <String, Uint8List>{};
    map.forEach((k, v) {
      final pkg = k.toString();
      if (v is Uint8List) out[pkg] = v;
    });
    if (callback != null) callback(out);
    return out;
  }

  /// Windows Start Menu apps (empty elsewhere). [pickExecutable] for browse fallback.
  Future<List<InstalledApp>> listInstalledApps() async {
    if (!Platform.isWindows) return const [];
    try {
      final res = await _ch.invokeMethod('listInstalledApps');
      if (res is List) {
        return res
            .whereType<Map>()
            .map((m) {
              return InstalledApp(
                name: m['name']?.toString() ?? '',
                path: m['path']?.toString() ?? '',
                process: m['process']?.toString() ?? '',
              );
            })
            .where((a) => a.process.isNotEmpty)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  /// Windows `.exe` picker → basename for `process:` matcher, or null.
  Future<String?> pickExecutable() async {
    if (!Platform.isWindows) return null;
    try {
      final path = await _ch.invokeMethod<String>('pickExecutable');
      if (path == null || path.trim().isEmpty) return null;
      return path.replaceAll('/', '\\').split('\\').last;
    } catch (_) {
      return null;
    }
  }

  /// Windows folder picker → absolute path, or null (cancelled/other platform).
  /// For [connect]'s `geoAssetsDir`.
  Future<String?> pickDirectory() async {
    if (!Platform.isWindows) return null;
    try {
      final path = await _ch.invokeMethod<String>('pickDirectory');
      if (path == null || path.trim().isEmpty) return null;
      return path.trim();
    } catch (_) {
      return null;
    }
  }

  /// PNG icons by exe path (Windows).
  Future<Map<String, Uint8List>> appIcons(List<String> paths) async {
    if (!Platform.isWindows || paths.isEmpty) return const {};
    try {
      final res = await _ch.invokeMethod('appIcons', {'paths': paths});
      if (res is Map) {
        final out = <String, Uint8List>{};
        res.forEach((k, v) {
          if (v is Uint8List) out['$k'] = v;
        });
        return out;
      }
    } catch (_) {}
    return const {};
  }
}

class InstalledApp {
  final String name;
  final String path;
  final String process; // exe basename - the process: matcher value
  const InstalledApp({
    required this.name,
    required this.path,
    required this.process,
  });
}

/// Headless disconnect when the UI isn't running.
@pragma('vm:entry-point')
void glitchVpnCoreBackgroundDisconnect() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await GlitchVpnCore.initialize();
    await GlitchVpnCore.instance.disconnect();
  } catch (_) {}
}

class AndroidAppInfo {
  final String packageName;
  final String appName;
  const AndroidAppInfo({required this.packageName, required this.appName});
}

class AndroidAppsPage {
  final List<AndroidAppInfo> items;
  final int total;
  const AndroidAppsPage({required this.items, required this.total});
}

class PingResult {
  final int index;
  final String engine; // "xray" | "awg" | "mihomo"; "" = none matched
  final bool alive;
  final int delayMs; // meaningful only when alive
  final String? error;
  const PingResult({
    required this.index,
    required this.engine,
    required this.alive,
    required this.delayMs,
    this.error,
  });

  factory PingResult.fromJson(Map<dynamic, dynamic> json) => PingResult(
    index: (json['index'] as num?)?.toInt() ?? 0,
    engine: json['engine']?.toString() ?? '',
    alive: json['alive'] == true,
    delayMs: (json['delayMs'] as num?)?.toInt() ?? -1,
    error: (json['error']?.toString().isNotEmpty ?? false)
        ? json['error'].toString()
        : null,
  );
}

/// Engine versions of the loaded core. A field is null for an engine not in
/// this build, or one the build did not stamp with a version.
class CoreVersions {
  final String? xrayCore;
  final String? amneziawg;
  final String? mihomo;

  const CoreVersions({this.xrayCore, this.amneziawg, this.mihomo});

  static CoreVersions? tryParse(String json) {
    try {
      final m = jsonDecode(json);
      if (m is! Map) return null;
      // The core reports "unknown" for an engine linked without a version.
      String? version(String key) {
        final v = (m[key] ?? '').toString().trim();
        return (v.isEmpty || v == 'unknown') ? null : v;
      }

      return CoreVersions(
        xrayCore: version('xray_core'),
        amneziawg: version('amneziawg'),
        mihomo: version('mihomo'),
      );
    } catch (_) {
      return null;
    }
  }
}

class _AsyncMutex {
  Future<void>? _current;
  Completer<void>? _completer;

  Future<T> runExclusive<T>(Future<T> Function() action) async {
    while (_current != null) {
      try {
        await _current;
      } catch (_) {}
    }
    _completer = Completer<void>();
    _current = _completer!.future;
    try {
      return await action();
    } finally {
      final c = _completer;
      _completer = null;
      _current = null;
      c?.complete();
    }
  }
}
