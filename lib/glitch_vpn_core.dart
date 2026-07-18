import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:glitch_vpn_core/geo_manager.dart';
import 'package:glitch_vpn_core/glitch_vpn_core_ffi.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';
import 'package:glitch_vpn_core/vpn_stats_channel.dart';
import 'package:glitch_vpn_core/vpn_logs_channel.dart';
import 'package:glitch_vpn_core/vpn_conn_channel.dart';

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
  final String? disconnectNotificationTitle;
  final String? disconnectNotificationSubtitle;

  /// Empty URL keeps the last downloaded copy. See [GeoManager].
  static const String defaultGeoVersion = '202607050337';
  static const String defaultGeoipUrl =
      'https://github.com/v2fly/geoip/releases/download/202607050337/geoip.dat';
  static const String defaultGeositeUrl =
      'https://github.com/v2fly/domain-list-community/releases/download/20260711103457/dlc.dat';
  final String geoipUrl;
  final String geositeUrl;
  final Duration geoUpdateInterval;

  const GlitchVpnCoreConfig({
    this.logLevel = 0,
    this.dnsAddress = '1.1.1.1',
    this.tunMtu = defaultTunMtu,
    this.tunUdpTimeoutSeconds = defaultTunUdpTimeoutSeconds,
    this.splitTunnelingType = SplitTunnelingType.blacklist,
    this.splitTunnelingApps = const <String>[],
    this.disconnectNotificationTitle,
    this.disconnectNotificationSubtitle,
    this.geoipUrl = defaultGeoipUrl,
    this.geositeUrl = defaultGeositeUrl,
    this.geoUpdateInterval = const Duration(days: 7),
  });

  GlitchVpnCoreConfig copyWith({
    int? logLevel,
    String? dnsAddress,
    int? tunMtu,
    int? tunUdpTimeoutSeconds,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    String? disconnectNotificationTitle,
    String? disconnectNotificationSubtitle,
    String? geoipUrl,
    String? geositeUrl,
    Duration? geoUpdateInterval,
  }) => GlitchVpnCoreConfig(
    logLevel: logLevel ?? this.logLevel,
    dnsAddress: dnsAddress ?? this.dnsAddress,
    tunMtu: tunMtu ?? this.tunMtu,
    tunUdpTimeoutSeconds: tunUdpTimeoutSeconds ?? this.tunUdpTimeoutSeconds,
    splitTunnelingType: splitTunnelingType ?? this.splitTunnelingType,
    splitTunnelingApps: splitTunnelingApps ?? this.splitTunnelingApps,
    disconnectNotificationTitle:
        disconnectNotificationTitle ?? this.disconnectNotificationTitle,
    disconnectNotificationSubtitle:
        disconnectNotificationSubtitle ?? this.disconnectNotificationSubtitle,
    geoipUrl: geoipUrl ?? this.geoipUrl,
    geositeUrl: geositeUrl ?? this.geositeUrl,
    geoUpdateInterval: geoUpdateInterval ?? this.geoUpdateInterval,
  );
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

/// Routing for xray/mihomo. Matchers use prefixes (`geoip:`, `geosite:`,
/// `domain:`, `full:`, `keyword:`, `regexp:`, `process:`) or bare IP/CIDR/host.
/// Priority: block → direct → proxy → local → mode catch-all.
class VpnRouting {
  /// '', 'proxy-all', or 'direct-all'.
  final String mode;

  final List<String> proxy;
  final List<String> direct;
  final List<String> block;

  /// RFC1918/CGNAT/loopback → direct.
  final bool localNetworksDirect;

  /// Reject ::/0 and suppress AAAA.
  final bool disableIPv6;

  /// Reject UDP except :53.
  final bool disableUDP;

  const VpnRouting({
    this.mode = '',
    this.proxy = const [],
    this.direct = const [],
    this.block = const [],
    this.localNetworksDirect = false,
    this.disableIPv6 = false,
    this.disableUDP = false,
  });

  Map<String, String> toOpts() {
    final opts = <String, String>{};
    void put(String k, List<String> v) {
      final cleaned = v.map((e) => e.trim()).where((e) => e.isNotEmpty);
      if (cleaned.isNotEmpty) opts[k] = cleaned.join(',');
    }

    if (mode.isNotEmpty) opts['routingMode'] = mode;
    put('proxyRules', proxy);
    put('directRules', direct);
    put('blockRules', block);
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
      return const ['url-test', 'fallback', 'load-balance', 'load-balance-hash'];
    case VpnEngine.awg:
      return const ['leastping', 'random', 'fallback'];
  }
}

/// uTLS fingerprints for [engine] (sets differ; awg → empty).
List<String> fingerprintsFor(VpnEngine engine) {
  switch (engine) {
    case VpnEngine.xray:
      return const [
        'chrome', 'firefox', 'safari', 'ios', 'android', 'edge',
        '360', 'qq', 'random', 'randomized', 'randomizednoalpn', 'unsafe',
      ];
    case VpnEngine.mihomo:
      return const [
        'chrome', 'firefox', 'safari', 'ios', 'android', 'edge', '360', 'qq',
        'random', 'randomized', 'chrome120', 'firefox120', 'safari16',
      ];
    case VpnEngine.awg:
      return const [];
  }
}

enum VpnDnsMode { fakeIp, normal }

/// DNS for xray/mihomo (awg uses the first plain server only).
/// Schemes: plain / `tls://` / `https://` / `quic://` / `tcp://`.
class VpnDns {
  final VpnDnsMode mode;
  final List<String> servers;
  final List<String> fakeIpFilter;

  const VpnDns({
    this.mode = VpnDnsMode.fakeIp,
    this.servers = const [],
    this.fakeIpFilter = const [],
  });

  Map<String, dynamic> toJson() => {
    'mode': mode == VpnDnsMode.fakeIp ? 'fake-ip' : 'normal',
    if (servers.isNotEmpty) 'servers': servers,
    if (fakeIpFilter.isNotEmpty) 'fakeIpFilter': fakeIpFilter,
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

  /// Ring caps (<=0 ignored). [toFile] mirrors logs to a temp file.
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
          sink.writeln('${log.at.toIso8601String()} ${log.message}');
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
    String? disconnectNotificationTitle,
    String? disconnectNotificationSubtitle,
    String? geoipUrl,
    String? geositeUrl,
    Duration? geoUpdateInterval,
  }) {
    _config = _config.copyWith(
      logLevel: logLevel,
      dnsAddress: dnsAddress,
      tunMtu: tunMtu,
      tunUdpTimeoutSeconds: tunUdpTimeoutSeconds,
      splitTunnelingType: splitTunnelingType,
      splitTunnelingApps: splitTunnelingApps,
      disconnectNotificationTitle: disconnectNotificationTitle,
      disconnectNotificationSubtitle: disconnectNotificationSubtitle,
      geoipUrl: geoipUrl,
      geositeUrl: geositeUrl,
      geoUpdateInterval: geoUpdateInterval,
    );
    if (disconnectNotificationTitle != null ||
        disconnectNotificationSubtitle != null) {
      final title =
          disconnectNotificationTitle ?? _config.disconnectNotificationTitle;
      final subtitle =
          disconnectNotificationSubtitle ??
          _config.disconnectNotificationSubtitle;
      if (title != null && subtitle != null) {
        _saveDisconnectNotificationTexts(title, subtitle);
      }
    }
  }

  static bool _handlerInstalled = false;
  static String? _activeTunnel;
  static bool _ffiReady = false;
  static bool _coreUsesService = false;
  static Future<void> Function()? _onDisconnectPressedHandler;

  static String _activeProxyUser = '';
  static String _activeProxyPass = '';

  /// Active proxy-mode SOCKS creds, or null. Random unless [proxyUser]/[proxyPass] set.
  ({String user, String pass})? get proxyCredentials =>
      _activeProxyUser.isEmpty
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
        GlitchVpnCoreFfi.instance.setEnvVar('GLITCH_PPROF_ADDR', '127.0.0.1:6060');
      }
      await GlitchVpnCoreFfi.instance.initialize();
      _ffiReady = true;
    }

    if (!_handlerInstalled) {
      _ch.setMethodCallHandler(_onNativeCall);
      _handlerInstalled = true;
    }

    await _ensureGeoAssets();

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
        final val = line
            .substring(idx + 1)
            .split(RegExp('[, ;]'))
            .first
            .trim();
        if (val.isNotEmpty) return val;
      }
    }
    return '';
  }

  /// Force-redownload geo (ignores freshness). Takes effect on next connect.
  static Future<void> refreshGeoAssets() => _ensureGeoAssets(force: true);

  static Future<void> _ensureGeoAssets({bool force = false}) async {
    try {
      final dir = await GeoManager.instance.provision(
        geoipUrl: instance._config.geoipUrl,
        geositeUrl: instance._config.geositeUrl,
        maxAge: instance._config.geoUpdateInterval,
        force: force,
      );
      GlitchVpnCoreFfi.instance.setEnvVar('xray.location.asset', dir);
    } catch (e) {
      debugPrint('geo assets: $e');
    }
  }

  /// Newer geo release available? (GitHub URLs only.) Install via [configure] + [refreshGeoAssets].
  static Future<Map<String, GeoUpdateInfo?>> checkGeoUpdate() async {
    return {
      'geoip': await GeoManager.instance.checkUpdate(instance._config.geoipUrl),
      'geosite': await GeoManager.instance.checkUpdate(
        instance._config.geositeUrl,
      ),
    };
  }

  static Future<int?> _prepareTunnelInternal(Map<String, Object?> args) =>
      _ch.invokeMethod<int>('prepareTunnel', args);

  static Future<void> stopTunnel() => _ch.invokeMethod('stopTunnel');
  static Future<void> _stopTunnelSilently() async {
    _activeProxyUser = '';
    _activeProxyPass = '';
    try {
      await stopTunnel();
    } catch (_) {
    }
  }

  Future<void> updateNotification({
    required String title,
    required String subtitle,
    String? countryLine,
    String? statsLine,
    String? disconnectActionText,
    bool? showDisconnectAction,
  }) async {
    if (!Platform.isAndroid) return;
    await _ch.invokeMethod('updateNotification', {
      'title': title,
      'subtitle': subtitle,
      'countryLine': ?countryLine,
      'statsLine': ?statsLine,
      'disconnectActionText': ?disconnectActionText,
      'notifShowDisconnect': ?showDisconnectAction,
    });
  }

  static Future<void> _saveDisconnectNotificationTexts(
    String title,
    String subtitle,
  ) async {
    try {
      await _ch.invokeMethod('setDisconnectNotificationTexts', {
        'title': title,
        'subtitle': subtitle,
      });
    } catch (_) {}
  }

  Future<void> connect({
    required VpnEngine engine,
    required String config,
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    String bypassCountries = '',
    String balancerStrategy = '',
    VpnRouting? routing,
    VpnDns? dns,
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
        return;
      }

      final engines = await engineIds();
      if (engines.isNotEmpty && !engines.contains(engine.name)) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason:
              'Engine "${engine.name}" is not in this build (available: ${engines.join(', ')})',
        );
        return;
      }

      if (balancerStrategy.isNotEmpty &&
          !balancerStrategiesFor(engine).contains(balancerStrategy)) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason:
              'Balancer "$balancerStrategy" not supported by ${engine.name}',
        );
        return;
      }

      if (proxyPort != null && engine == VpnEngine.awg) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: 'awg has no proxy mode (use TUN)',
        );
        return;
      }

      _activeProxyUser = '';
      _activeProxyPass = '';

      switch (engine) {
        case VpnEngine.xray:
          await _connectXrayCore(
            config,
            dnsAddress: dnsAddress,
            logLevel: logLevel,
            splitTunnelingType: splitTunnelingType,
            splitTunnelingApps: splitTunnelingApps,
            bypassCountries: bypassCountries,
            balancerStrategy: balancerStrategy,
            routing: routing,
            dns: dns,
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
          );
          break;
        case VpnEngine.awg:
          await _connectAwgCore(
            config,
            dnsAddress: dnsAddress,
            splitTunnelingType: splitTunnelingType,
            splitTunnelingApps: splitTunnelingApps,
            dns: dns,
            probeUrl: probeUrl,
            livenessIntervalSec: livenessIntervalSec,
          );
          break;
        case VpnEngine.mihomo:
          await _connectMihomoCore(
            config,
            dnsAddress: dnsAddress,
            logLevel: logLevel,
            splitTunnelingType: splitTunnelingType,
            splitTunnelingApps: splitTunnelingApps,
            dns: dns,
            balancerStrategy: balancerStrategy,
            routing: routing,
            proxyPort: proxyPort,
            proxyAuth: proxyAuth,
            proxyUser: proxyUser,
            proxyPass: proxyPass,
            sniffing: sniffing,
            probeUrl: probeUrl,
            livenessIntervalSec: livenessIntervalSec,
            fingerprint: fingerprint,
          );
          break;
      }
    });
  }

  Future<void> connectXray(
    String config, {
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    String bypassCountries = '',
    String balancerStrategy = '',
    VpnRouting? routing,
  }) async {
    await _withTransitionLock(() async {
      await _connectXrayCore(
        config,
        dnsAddress: dnsAddress,
        logLevel: logLevel,
        splitTunnelingType: splitTunnelingType,
        splitTunnelingApps: splitTunnelingApps,
        bypassCountries: bypassCountries,
        balancerStrategy: balancerStrategy,
        routing: routing,
      );
    });
  }

  Future<void> _connectXrayCore(
    String config, {
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    String bypassCountries = '',
    String balancerStrategy = '',
    VpnRouting? routing,
    VpnDns? dns,
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
  }) async {
    await initialize();
    // Proxy mode exposes a loopback SOCKS - no TUN, so no admin/prepareTunnel.
    final proxyMode = proxyPort != null;
    if (!proxyMode) {
      final elevated = await ensureAdmin();
      if (!elevated) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: 'Admin rights are required',
        );
        return;
      }
    }

    final effectiveDns = (dnsAddress ?? _config.dnsAddress).trim();
    final effectiveLog = logLevel ?? _config.logLevel;
    final effectiveTunMtu = _config.tunMtu;
    final effectiveTunUdpTimeoutSeconds = _config.tunUdpTimeoutSeconds;
    final effectiveSplitType = splitTunnelingType ?? _config.splitTunnelingType;
    final effectiveSplitApps = splitTunnelingApps ?? _config.splitTunnelingApps;

    VpnStatusChannel.instance.emit(VpnStatus.connecting);

    int fd = -1;
    if (Platform.isAndroid && !proxyMode) {
      fd =
          await _prepareTunnelInternal({
            'dns': effectiveDns,
            'mtu': effectiveTunMtu,
            'splitType': effectiveSplitType.name,
            'splitApps': effectiveSplitApps,
          }) ??
          -1;
      if (fd == -1) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: 'prepareTunnel failed',
        );
        throw PlatformException(code: 'PREPARE_TUNNEL_FAILED');
      }
    }
    GlitchVpnCoreFfi.instance.setTun2SocksConfig(
      mtu: effectiveTunMtu,
      udpTimeoutSeconds: effectiveTunUdpTimeoutSeconds,
    );

    final opts = <String, String>{...?routing?.toOpts()};
    if (balancerStrategy.isNotEmpty) opts['balancerStrategy'] = balancerStrategy;
    // Legacy alias: bypassCountries → direct geoip:<cc>, unless routing already
    // supplied a direct list.
    if (bypassCountries.isNotEmpty && !opts.containsKey('directRules')) {
      opts['bypassCountries'] = bypassCountries;
    }
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

    final res = GlitchVpnCoreFfi.instance.engineStart(
      'xray',
      config: config,
      tunFd: fd,
      dns: effectiveDns,
      logLevel: effectiveLog,
      opts: opts,
      dnsConfig: dns?.toJson(),
    );
    if (res == 0) {
      _activeTunnel = 'xray';
    } else {
      VpnStatusChannel.instance.emit(VpnStatus.error, reason: 'EngineStart=$res');
      throw PlatformException(
        code: 'XRAY_START_FAILED',
        message: 'EngineStart(xray)=$res',
      );
    }
  }

  Future<void> connectAwg(
    String config, {
    String? dnsAddress,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
  }) async {
    await _withTransitionLock(() async {
      await _connectAwgCore(
        config,
        dnsAddress: dnsAddress,
        splitTunnelingType: splitTunnelingType,
        splitTunnelingApps: splitTunnelingApps,
      );
    });
  }

  Future<void> _connectAwgCore(
    String config, {
    String? dnsAddress,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    VpnDns? dns,
    String probeUrl = '',
    int? livenessIntervalSec,
  }) async {
    await initialize();
    final elevated = await ensureAdmin();
    if (!elevated) {
      VpnStatusChannel.instance.emit(
        VpnStatus.error,
        reason: 'Admin rights are required',
      );
      return;
    }

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

    String addr = _extractWgAddress(config);
    int fd = -1;
    if (Platform.isAndroid) {
      try {
        fd =
            await _prepareTunnelInternal({
              'addresses': [addr],
              'dns': awgDns,
              'splitType': effectiveSplitType.name,
              'splitApps': effectiveSplitApps,
            }) ??
            -1;
      } on PlatformException catch (e) {
        if (e.code == 'NEEDS_PERMISSION') {
          VpnStatusChannel.instance.emit(
            VpnStatus.error,
            reason: 'NEEDS_PERMISSION',
          );
          throw PlatformException(code: 'NEEDS_PERMISSION');
        }
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: 'prepareTunnel error: ${e.code}',
        );
        rethrow;
      }
      if (fd == -1) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: 'prepareTunnel failed',
        );
        throw PlatformException(code: 'PREPARE_TUNNEL_FAILED');
      }
    }
    final res = GlitchVpnCoreFfi.instance.engineStart(
      'awg',
      config: config,
      tunFd: fd,
      dns: awgDns,
      logLevel: _config.logLevel,
      opts: {
        if (probeUrl.trim().isNotEmpty) 'probeUrl': probeUrl.trim(),
        if (livenessIntervalSec != null)
          'livenessIntervalSec': '$livenessIntervalSec',
      },
    );
    if (res == 0) {
      _activeTunnel = 'awg';
    } else {
      VpnStatusChannel.instance.emit(VpnStatus.error, reason: 'EngineStart=$res');
      throw PlatformException(
        code: 'AWG_START_FAILED',
        message: 'EngineStart(awg)=$res',
      );
    }
  }

  Future<void> _connectMihomoCore(
    String config, {
    String? dnsAddress,
    int? logLevel,
    SplitTunnelingType? splitTunnelingType,
    List<String>? splitTunnelingApps,
    VpnDns? dns,
    String balancerStrategy = '',
    VpnRouting? routing,
    int? proxyPort,
    bool proxyAuth = true,
    String? proxyUser,
    String? proxyPass,
    bool sniffing = true,
    String probeUrl = '',
    int? livenessIntervalSec,
    String fingerprint = '',
  }) async {
    await initialize();
    // Proxy mode exposes a loopback mixed inbound - no TUN, so no admin/prepareTunnel.
    final proxyMode = proxyPort != null;
    if (!proxyMode) {
      final elevated = await ensureAdmin();
      if (!elevated) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: 'Admin rights are required',
        );
        return;
      }
    }

    final effectiveDns = (dnsAddress ?? _config.dnsAddress).trim();
    final effectiveLog = logLevel ?? _config.logLevel;
    final effectiveSplitType = splitTunnelingType ?? _config.splitTunnelingType;
    final effectiveSplitApps = splitTunnelingApps ?? _config.splitTunnelingApps;

    VpnStatusChannel.instance.emit(VpnStatus.connecting);

    int fd = -1;
    if (Platform.isAndroid && !proxyMode) {
      fd =
          await _prepareTunnelInternal({
            'dns': effectiveDns,
            'mtu': _config.tunMtu,
            'splitType': effectiveSplitType.name,
            'splitApps': effectiveSplitApps,
          }) ??
          -1;
      if (fd == -1) {
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: 'prepareTunnel failed',
        );
        throw PlatformException(code: 'PREPARE_TUNNEL_FAILED');
      }
    }

    final opts = <String, String>{...?routing?.toOpts()};
    if (balancerStrategy.isNotEmpty) opts['balancerStrategy'] = balancerStrategy;
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

    final res = GlitchVpnCoreFfi.instance.engineStart(
      'mihomo',
      config: config,
      tunFd: fd,
      dns: effectiveDns,
      logLevel: effectiveLog,
      opts: opts,
      dnsConfig: dns?.toJson(),
    );
    if (res == 0) {
      _activeTunnel = 'mihomo';
    } else {
      VpnStatusChannel.instance.emit(VpnStatus.error, reason: 'EngineStart=$res');
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

      if (Platform.isAndroid) {
        final t = _config.disconnectNotificationTitle ?? 'Disconnecting';
        final s = _config.disconnectNotificationSubtitle ?? '';

        try {
          await updateNotification(
            title: t,
            subtitle: s,
            showDisconnectAction: false,
          );
        } catch (_) {}
      }
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
        // Clear Android notification when no core is running.
        await _stopTunnelSilently();
        _activeTunnel = null;
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
        break;

      case GlitchVpnCoreFfiEventCode.engineConflictOtherCore:
        VpnStatusChannel.instance.emit(
          VpnStatus.error,
          reason: reason ?? 'core conflict',
        );
        await _stopTunnelSilently();
        _activeTunnel = null;
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
          break;
        }
        await _stopTunnelSilently();
        _activeTunnel = null;
        VpnStatusChannel.instance.emit(VpnStatus.disconnected);
        break;

      case GlitchVpnCoreFfiEventCode.engineStopRejectedNotRunning:
        break;

      case GlitchVpnCoreFfiEventCode.engineError:
        VpnStatusChannel.instance.emit(VpnStatus.error, reason: reason);
        await _stopTunnelSilently();
        _activeTunnel = null;
        break;

      case GlitchVpnCoreFfiEventCode.statsEvent:
        try {
          final stats = jsonDecode(msg as String);
          final rx = (stats is Map) ? stats['rx'] as int? ?? 0 : 0;
          final tx = (stats is Map) ? stats['tx'] as int? ?? 0 : 0;
          final durationMs = (stats is Map)
              ? stats['durationMs'] as int? ?? 0
              : 0;
          final rssBytes = (stats is Map)
              ? stats['rssBytes'] as int? ?? 0
              : 0;
          final goMemBytes = (stats is Map)
              ? stats['goMemBytes'] as int? ?? 0
              : 0;
          final linkUp = (stats is Map) ? stats['linkUp'] as bool? : null;
          final probeMs = (stats is Map)
              ? stats['probeMs'] as int? ?? -1
              : -1;
          VpnStatsChannel.instance.emit(
            rx,
            tx,
            durationMs,
            rssBytes: rssBytes,
            goMemBytes: goMemBytes,
            linkUp: linkUp,
            probeMs: probeMs,
          );
        } catch (_) {
        }
        break;
      case GlitchVpnCoreFfiEventCode.connEvent:
        final conn = VpnConnEvent.tryParse(msg as String);
        if (conn != null) VpnConnChannel.instance.emit(conn);
        break;
      case GlitchVpnCoreFfiEventCode.statsError:
      case GlitchVpnCoreFfiEventCode.logEvent:
      case GlitchVpnCoreFfiEventCode.logError:
        VpnLogsChannel.instance.emit(msg as String);
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

  /// Engine ids linked in this binary (cached).
  static Future<Set<String>> engineIds() async {
    if (_engineIdsCache != null) return _engineIdsCache!;
    final ids = <String>{};
    try {
      final decoded = jsonDecode(await getCapabilitiesJson());
      if (decoded is Map && decoded['engines'] is List) {
        for (final e in decoded['engines'] as List) {
          if (e is String) ids.add(e);
        }
      }
    } catch (_) {
      // leave empty; treated as "unknown", callers fall back permissively
    }
    _engineIdsCache = ids;
    return ids;
  }

  static Future<List<VpnEngine>> availableEngines() async {
    final ids = await engineIds();
    return VpnEngine.values.where((e) => ids.contains(e.name)).toList();
  }

  static String activeEngine() => GlitchVpnCoreFfi.instance.activeEngine();

  /// Url-test latency per link (through that server). No engine/admin/TUN needed.
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
    final raw = await GlitchVpnCoreFfi.measurePings(request);
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map>()
            .map(PingResult.fromJson)
            .toList(growable: false);
      }
    } catch (_) {}
    return const <PingResult>[];
  }

  static Future<CoreVersions> getCoreVersions() async {
    await initialize();
    try {
      final raw = GlitchVpnCoreFfi.instance.getCoreVersionsJson();
      final decoded = jsonDecode(raw);
      if (decoded is Map) {
        final xray = decoded['xray_core']?.toString() ?? 'unknown';
        final awg = decoded['amneziawg']?.toString() ?? 'unknown';
        return CoreVersions(xrayCore: xray, amneziawg: awg);
      }
    } catch (_) {}
    return const CoreVersions(xrayCore: 'unknown', amneziawg: 'unknown');
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
        return res.whereType<Map>().map((m) {
          return InstalledApp(
            name: m['name']?.toString() ?? '',
            path: m['path']?.toString() ?? '',
            process: m['process']?.toString() ?? '',
          );
        }).where((a) => a.process.isNotEmpty).toList();
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

  // === Windows Mobile Hotspot (shares the VPN tunnel with Wi-Fi clients) ===

  /// Default hotspot network name.
  static const String defaultHotspotSsid = 'GlitchVPN Wifi';

  HotspotCredentials? _hotspotCredentials;

  /// Credentials from the last successful [startHotspot], or null.
  HotspotCredentials? get hotspotCredentials => _hotspotCredentials;

  /// Native hotspot errors arrive as {errorCode, errorMessage} maps.
  static void _throwIfHotspotError(Map<dynamic, dynamic> map) {
    final code = map['errorCode']?.toString();
    if (code != null && code.isNotEmpty) {
      throw PlatformException(
        code: code,
        message: map['errorMessage']?.toString(),
      );
    }
  }

  /// Starts the Windows Mobile Hotspot sharing the VPN tunnel connection.
  ///
  /// [ssid] defaults to [defaultHotspotSsid]. [password] is random when
  /// omitted. The effective credentials are returned and stay readable via
  /// [hotspotCredentials] / [getHotspotCredentials].
  ///
  /// [open] requests a passwordless network. Windows does not support open
  /// hotspots, so on Windows this throws `HOTSPOT_OPEN_NOT_SUPPORTED`.
  ///
  /// [HotspotCredentials.tunneled] is true when the hotspot shares the VPN
  /// adapter itself (client traffic is guaranteed to egress through the
  /// tunnel) - connect the VPN before starting the hotspot for that.
  ///
  /// Throws [PlatformException] when the hotspot cannot be started:
  /// `HOTSPOT_NOT_SUPPORTED` (no SoftAP-capable Wi-Fi adapter, disabled by
  /// policy/edition, ...), `HOTSPOT_NO_CONNECTION` (nothing to share),
  /// `HOTSPOT_OPEN_NOT_SUPPORTED`, `HOTSPOT_START_FAILED`.
  Future<HotspotCredentials> startHotspot({
    String? ssid,
    String? password,
    bool open = false,
  }) async {
    final name = (ssid == null || ssid.trim().isEmpty)
        ? defaultHotspotSsid
        : ssid.trim();
    if (utf8.encode(name).length > 32) {
      throw ArgumentError.value(ssid, 'ssid', 'must be at most 32 bytes');
    }
    var pass = '';
    if (open) {
      if (password != null && password.isNotEmpty) {
        throw ArgumentError('password must not be set when open is true');
      }
    } else {
      pass = (password == null || password.isEmpty)
          ? _randomCred(12)
          : password;
      if (pass.length < 8 || pass.length > 63) {
        throw ArgumentError.value(
          password,
          'password',
          'WPA2 passphrase must be 8-63 characters',
        );
      }
    }
    if (!Platform.isWindows) {
      throw UnsupportedError('Hotspot is only supported on Windows');
    }
    final res = await _ch.invokeMethod('startHotspot', {
      'ssid': name,
      'password': pass,
      'open': open,
    });
    final map = (res as Map<dynamic, dynamic>? ?? const {});
    _throwIfHotspotError(map);
    final creds = HotspotCredentials.fromMap(map);
    _hotspotCredentials = creds;
    return creds;
  }

  /// Stops the Mobile Hotspot. No-op when it isn't running.
  ///
  /// Throws [PlatformException] `HOTSPOT_STOP_FAILED` on failure.
  Future<void> stopHotspot() async {
    if (!Platform.isWindows) {
      throw UnsupportedError('Hotspot is only supported on Windows');
    }
    final res = await _ch.invokeMethod('stopHotspot');
    if (res is Map) _throwIfHotspotError(res);
    _hotspotCredentials = null;
  }

  /// Hotspot name/password as currently configured in Windows, or null when
  /// the hotspot is not active.
  Future<HotspotCredentials?> getHotspotCredentials() async {
    if (!Platform.isWindows) return null;
    final res = await _ch.invokeMethod('getHotspotConfig');
    final map = (res as Map<dynamic, dynamic>? ?? const {});
    _throwIfHotspotError(map);
    if (map['active'] != true) return null;
    return HotspotCredentials.fromMap(map);
  }

  /// Whether this machine can run a Mobile Hotspot at all.
  Future<bool> isHotspotSupported() async {
    if (!Platform.isWindows) return false;
    try {
      return await _ch.invokeMethod<bool>('isHotspotSupported') ?? false;
    } catch (_) {
      return false;
    }
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

/// Wi-Fi hotspot credentials handed to the consumer.
class HotspotCredentials {
  final String ssid;

  /// Null only for an open (passwordless) network.
  final String? password;

  /// True when the hotspot shares the VPN tunnel adapter itself, so client
  /// traffic is guaranteed to egress through the tunnel.
  final bool tunneled;

  const HotspotCredentials({
    required this.ssid,
    this.password,
    this.tunneled = false,
  });

  bool get isOpen => password == null;

  factory HotspotCredentials.fromMap(Map<dynamic, dynamic> map) {
    final pass = map['password']?.toString() ?? '';
    return HotspotCredentials(
      ssid: map['ssid']?.toString() ?? '',
      password: pass.isEmpty ? null : pass,
      tunneled: map['tunneled'] == true,
    );
  }
}

/// Headless disconnect when the UI isn't running.
@pragma('vm:entry-point')
void glitchVpnCoreBackgroundDisconnect() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await GlitchVpnCore.initialize();
    await GlitchVpnCore.instance.disconnect();
  } catch (_) {
  }
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

class CoreVersions {
  final String xrayCore;
  final String amneziawg;
  const CoreVersions({required this.xrayCore, required this.amneziawg});
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
