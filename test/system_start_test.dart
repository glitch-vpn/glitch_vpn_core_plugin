import 'dart:ui';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';

const _channel = MethodChannel('glitch_vpn_core');

final _handledStarts = <VpnSystemStart>[];
bool _engineUp = false;

@pragma('vm:entry-point')
Future<void> _recordingHandler(VpnSystemStart start) async {
  _handledStarts.add(start);
}

@pragma('vm:entry-point')
Future<void> _throwingHandler(VpnSystemStart start) async {
  throw StateError('handler failed');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late List<String> calls;
  late Map<Object?, Object?>? systemStart;

  setUp(() {
    calls = [];
    systemStart = null;
    _handledStarts.clear();
    _engineUp = false;
    GlitchVpnCore.debugSystemStartInitialize = () async {
      calls.add('initialize');
    };
    GlitchVpnCore.debugSystemStartEngineRunning = () => _engineUp;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          if (call.method == 'systemStart') return systemStart;
          return null;
        });
  });

  tearDown(() {
    GlitchVpnCore.debugSystemStartInitialize = null;
    GlitchVpnCore.debugSystemStartEngineRunning = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, null);
  });

  int handleOf(Future<void> Function(VpnSystemStart) handler) =>
      PluginUtilities.getCallbackHandle(handler)!.toRawHandle();

  test('declines a start that has no registered handler', () async {
    await GlitchVpnCore.debugRunSystemStart();

    expect(calls, ['systemStart', 'declineSystemStart']);
  });

  test('declines when the handler leaves no engine running', () async {
    systemStart = {'handle': handleOf(_recordingHandler), 'reason': 'restart'};

    await GlitchVpnCore.debugRunSystemStart();

    expect(_handledStarts, [VpnSystemStart.restart]);
    expect(calls, ['systemStart', 'initialize', 'declineSystemStart']);
  });

  test('keeps the service when the handler brought an engine up', () async {
    systemStart = {'handle': handleOf(_recordingHandler), 'reason': 'alwaysOn'};
    GlitchVpnCore.debugSystemStartInitialize = () async {
      calls.add('initialize');
      _engineUp = true;
    };

    await GlitchVpnCore.debugRunSystemStart();

    expect(_handledStarts, [VpnSystemStart.alwaysOn]);
    expect(calls, ['systemStart', 'initialize']);
  });

  test('a throwing handler is contained and the start declined', () async {
    systemStart = {'handle': handleOf(_throwingHandler), 'reason': 'restart'};

    await GlitchVpnCore.debugRunSystemStart();

    expect(calls, ['systemStart', 'initialize', 'declineSystemStart']);
  });

  test('declines when the native side cannot answer', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_channel, (call) async {
          calls.add(call.method);
          if (call.method == 'systemStart') throw PlatformException(code: 'x');
          return null;
        });

    await GlitchVpnCore.debugRunSystemStart();

    expect(calls, ['systemStart', 'declineSystemStart']);
  });
}
