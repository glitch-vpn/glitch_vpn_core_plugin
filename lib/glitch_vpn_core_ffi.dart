import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:developer' as developer;
import 'package:ffi/ffi.dart' as pkg;
import 'src/bindings_generated.dart';

enum GlitchVpnCoreFfiEventCode {
  engineConnecting(500),
  engineConnected(501),
  engineError(502),
  engineDisconnecting(503),
  engineDisconnected(504),
  engineAlreadyRunning(505),
  engineConflictOtherCore(506),
  engineStopRejectedNotRunning(507),
  statsEvent(300),
  statsError(301),
  serverEvent(302),
  ipEvent(303),
  logEvent(400),
  logError(401),
  connEvent(402);

  const GlitchVpnCoreFfiEventCode(this.code);
  final int code;

  static GlitchVpnCoreFfiEventCode fromCode(int code) {
    switch (code) {
      case 500:
        return GlitchVpnCoreFfiEventCode.engineConnecting;
      case 501:
        return GlitchVpnCoreFfiEventCode.engineConnected;
      case 502:
        return GlitchVpnCoreFfiEventCode.engineError;
      case 503:
        return GlitchVpnCoreFfiEventCode.engineDisconnecting;
      case 504:
        return GlitchVpnCoreFfiEventCode.engineDisconnected;
      case 505:
        return GlitchVpnCoreFfiEventCode.engineAlreadyRunning;
      case 506:
        return GlitchVpnCoreFfiEventCode.engineConflictOtherCore;
      case 507:
        return GlitchVpnCoreFfiEventCode.engineStopRejectedNotRunning;
      case 300:
        return GlitchVpnCoreFfiEventCode.statsEvent;
      case 301:
        return GlitchVpnCoreFfiEventCode.statsError;
      case 302:
        return GlitchVpnCoreFfiEventCode.serverEvent;
      case 303:
        return GlitchVpnCoreFfiEventCode.ipEvent;
      case 400:
        return GlitchVpnCoreFfiEventCode.logEvent;
      case 401:
        return GlitchVpnCoreFfiEventCode.logError;
      case 402:
        return GlitchVpnCoreFfiEventCode.connEvent;
      default:
        return GlitchVpnCoreFfiEventCode.logError;
    }
  }
}

class GlitchVpnCoreFfi {
  static Future<void> preloadInBackground() => Isolate.run(_backgroundOpen);

  @pragma('vm:entry-point')
  static void _backgroundOpen() {
    if (Platform.isWindows) {
      ffi.DynamicLibrary.open('libglitchcore.dll');
    } else if (Platform.isAndroid || Platform.isLinux) {
      ffi.DynamicLibrary.open('libglitchcore.so');
    } else if (Platform.isMacOS) {
      ffi.DynamicLibrary.open('libglitchcore.dylib');
    }
  }

  GlitchVpnCoreFfi._() {
    final lib = _openLib();
    final initDartApi = lib
        .lookupFunction<
          ffi.Int32 Function(ffi.Pointer<ffi.Void>),
          int Function(ffi.Pointer<ffi.Void>)
        >('InitDartApiDL');
    final initRes = initDartApi(ffi.NativeApi.initializeApiDLData);
    if (initRes != 0) {
      throw Exception('InitDartApiDL failed: $initRes');
    }
    _lib = lib;
    _bindings = GlitchCoreBindings(lib);
    _registerStatusPort = _lib
        .lookupFunction<ffi.Void Function(ffi.Int64), void Function(int)>(
          'RegisterStatusPort',
        );
  }

  static final GlitchVpnCoreFfi instance = GlitchVpnCoreFfi._();

  late final GlitchCoreBindings _bindings;
  late final ffi.DynamicLibrary _lib;
  late final void Function(int) _registerStatusPort;

  ReceivePort? _statusPort;

  static ffi.DynamicLibrary _openLib() {
    if (Platform.isWindows) return ffi.DynamicLibrary.open('libglitchcore.dll');
    if (Platform.isAndroid || Platform.isLinux) {
      return ffi.DynamicLibrary.open('libglitchcore.so');
    }
    if (Platform.isMacOS) return ffi.DynamicLibrary.open('libglitchcore.dylib');
    throw UnsupportedError('unsupported');
  }

  Future<void> initialize() async {
    final initCtl = _lib.lookupFunction<ffi.Void Function(), void Function()>(
      'InitializeController',
    );
    initCtl();
  }

  void registerStatus(void Function(int, String) cb) {
    _statusCallback = cb;
    if (_statusPort != null) return;

    final port = ReceivePort();
    _statusPort = port;
    _registerStatusPort(port.sendPort.nativePort);

    port.listen((dynamic msg) {
      if (msg is List && msg.length == 2) {
        final code = msg[0] as int;
        final message = msg[1] as String;
        _statusCallback?.call(code, message);
      }
    });
  }

  String _consumeCString(ffi.Pointer<ffi.Char> ptr, String fallback) {
    if (ptr == ffi.nullptr) return fallback;
    try {
      return ptr.cast<pkg.Utf8>().toDartString();
    } finally {
      _bindings.FreeStatusMessage(ptr);
    }
  }

  String getCoreVersionsJson() =>
      _consumeCString(_bindings.GetCoreVersions(), '{}');

  String coreCapabilitiesJson() =>
      _consumeCString(_bindings.CoreCapabilities(), '{"engines":[]}');

  int engineStart(
    String engineId, {
    required String config,
    required int tunFd,
    required String dns,
    required int logLevel,
    Map<String, String> opts = const {},
    Map<String, dynamic>? dnsConfig,
  }) {
    final request = jsonEncode({
      'config': config,
      'tunFd': tunFd,
      'dns': dns,
      'logLevel': logLevel,
      if (opts.isNotEmpty) 'opts': opts,
      'dnsConfig': ?dnsConfig,
    });
    final enginePtr = engineId.toNativeUtf8();
    final requestPtr = request.toNativeUtf8();
    developer.log('EngineStart($engineId)');
    try {
      final res = _bindings.EngineStart(enginePtr.cast(), requestPtr.cast());
      developer.log('EngineStart($engineId) = $res');
      return res;
    } finally {
      pkg.malloc.free(enginePtr);
      pkg.malloc.free(requestPtr);
    }
  }

  int engineStop(String engineId) {
    final enginePtr = engineId.toNativeUtf8();
    try {
      return _bindings.EngineStop(enginePtr.cast());
    } finally {
      pkg.malloc.free(enginePtr);
    }
  }

  bool engineIsRunning(String engineId) {
    final enginePtr = engineId.toNativeUtf8();
    try {
      return _bindings.EngineIsRunning(enginePtr.cast()) == 0;
    } catch (_) {
      return false;
    } finally {
      pkg.malloc.free(enginePtr);
    }
  }

  String activeEngine() {
    try {
      return _consumeCString(_bindings.ActiveEngine(), '');
    } catch (_) {
      return '';
    }
  }

  // Blocks up to the per-link timeout - keep off the UI isolate.
  static Future<String> measurePings(String requestJson) =>
      Isolate.run(() => _measurePingsSync(requestJson));

  @pragma('vm:entry-point')
  static String _measurePingsSync(String requestJson) {
    final lib = _openLib();
    final measure = lib
        .lookupFunction<
          ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>),
          ffi.Pointer<ffi.Char> Function(ffi.Pointer<ffi.Char>)
        >('MeasurePings');
    final free = lib
        .lookupFunction<
          ffi.Void Function(ffi.Pointer<ffi.Char>),
          void Function(ffi.Pointer<ffi.Char>)
        >('FreeStatusMessage');
    final reqPtr = requestJson.toNativeUtf8();
    ffi.Pointer<ffi.Char> resPtr = ffi.nullptr;
    try {
      resPtr = measure(reqPtr.cast());
      if (resPtr == ffi.nullptr) return '[]';
      return resPtr.cast<pkg.Utf8>().toDartString();
    } finally {
      pkg.malloc.free(reqPtr);
      if (resPtr != ffi.nullptr) free(resPtr.cast());
    }
  }

  int listenStats(int intervalMs) {
    try {
      return _bindings.ListenStats(intervalMs);
    } catch (_) {
      return -1;
    }
  }

  void setEnvVar(String key, String value) {
    final keyPtr = key.toNativeUtf8();
    final valuePtr = value.toNativeUtf8();
    _bindings.SetEnvVar(keyPtr.cast(), valuePtr.cast());
    pkg.malloc.free(keyPtr);
    pkg.malloc.free(valuePtr);
  }

  void setTun2SocksConfig({required int mtu, required int udpTimeoutSeconds}) {
    _bindings.SetTun2SocksConfig(mtu, udpTimeoutSeconds);
  }

  void setMemoryLimit(int bytes) {
    try {
      _bindings.SetMemoryLimit(bytes);
    } catch (_) {}
  }

  // Call before [initialize].
  void setUseServiceIPC(bool enabled) {
    try {
      _bindings.SetUseServiceIPC(enabled ? 1 : 0);
    } catch (_) {}
  }

  void setStatusVerbosity(int level) {
    try {
      _bindings.SetStatusVerbosity(level);
    } catch (_) {}
  }

  void setConnInspector(bool enabled) {
    try {
      _bindings.SetConnInspector(enabled ? 1 : 0);
    } catch (_) {}
  }

  int stopStats() {
    try {
      return _bindings.StopStats();
    } catch (_) {
      return -1;
    }
  }

  void dispose() {
    _statusCallback = null;
    _statusPort?.close();
    _statusPort = null;
  }

  static void Function(int, String)? _statusCallback;
}
