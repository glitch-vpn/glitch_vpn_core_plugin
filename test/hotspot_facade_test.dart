import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/glitch_vpn_core_ffi.dart';
import 'package:glitch_vpn_core/vpn_hotspot_channel.dart';
import 'package:glitch_vpn_core/vpn_logs_channel.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';

class _Native implements HotspotNative {
  final calls = <String>[];

  @override
  Future<Map<Object?, Object?>?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add(method);
    return switch (method) {
      'hotspotClients' => {'clients': <Object?>[]},
      'hotspotStatus' => {'state': 'on', 'ours': true},
      _ => {'running': true, 'restarted': false},
    };
  }
}

class _Core implements HotspotCore {
  final sent = <bool>[];

  @override
  Future<int> prepare() async => 0;

  @override
  Future<int> setSharing(String json) async {
    sent.add((jsonDecode(json) as Map)['on'] as bool);
    return 0;
  }
}

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Native native;
  late _Core core;
  late VpnHotspotChannel channel;
  late VpnHotspotChannel original;

  setUp(() async {
    original = VpnHotspotChannel.instance;
    native = _Native();
    core = _Core();
    channel = VpnHotspotChannel.withNative(native, core: core);
    VpnHotspotChannel.debugInstance = channel;
    await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
    await channel.start();
    await _settle();
    expect(core.sent, [true]);
  });

  tearDown(() {
    VpnHotspotChannel.debugInstance = original;
    GlitchVpnCore.debugRegisterStatus = null;
    GlitchVpnCore.debugReclaimStatus = null;
  });

  group('the core event codes', () {
    test('600 and 508 are their own events, not log errors', () {
      expect(
        GlitchVpnCoreFfiEventCode.fromCode(600),
        GlitchVpnCoreFfiEventCode.hotspotSharingEvent,
      );
      expect(
        GlitchVpnCoreFfiEventCode.fromCode(508),
        GlitchVpnCoreFfiEventCode.serviceReattached,
      );
      expect(GlitchVpnCoreFfiEventCode.hotspotSharingEvent.code, 600);
      expect(GlitchVpnCoreFfiEventCode.serviceReattached.code, 508);
    });
  });

  group('the facade routes the core to the hotspot', () {
    test('event 600 reaches the hotspot and is not a log', () async {
      final logs = <VpnLog>[];
      final sub = VpnLogsChannel.instance.stream.listen(logs.add);
      await GlitchVpnCore.debugOnCoreEvent(
        600,
        '{"shared":"tunnel","blocked":false,"error":""}',
      );
      expect(channel.sharing.value!.shared, 'tunnel');
      expect(logs, isEmpty);
      await sub.cancel();
    });

    test('event 600 with an error stops the hotspot', () async {
      await GlitchVpnCore.debugOnCoreEvent(
        600,
        '{"shared":"none","blocked":true,"error":"no adapter"}',
      );
      await _settle();
      await _settle();
      expect(channel.value.state, HotspotState.failed);
      expect(native.calls, contains('hotspotStop'));
    });

    test('an engine connecting sends the state again', () async {
      await GlitchVpnCore.debugOnCoreEvent(500, '[xray] connecting');
      await _settle();
      expect(core.sent, [true, true]);
      expect(VpnStatusChannel.instance.value.status, VpnStatus.connecting);
    });

    test(
      'a reattached service sends the state again, status untouched',
      () async {
        VpnStatusChannel.instance.emit(VpnStatus.disconnected);
        await GlitchVpnCore.debugOnCoreEvent(508, '[service] Reattached');
        await _settle();
        expect(core.sent, [true, true]);
        expect(VpnStatusChannel.instance.value.status, VpnStatus.disconnected);
      },
    );

    test('registering the core events again sends the state again', () async {
      var registered = 0;
      GlitchVpnCore.debugRegisterStatus = (_) => registered++;
      GlitchVpnCore.debugAttachCoreEvents();
      await _settle();
      expect(registered, 1);
      expect(core.sent, [true, true]);
    });

    test('reclaiming the core events sends the state again', () async {
      var reclaimed = 0;
      GlitchVpnCore.debugReclaimStatus = () => reclaimed++;
      await GlitchVpnCore.debugOnNativeCall(const MethodCall('reclaimStatus'));
      await _settle();
      expect(reclaimed, 1);
      expect(core.sent, [true, true]);
    });

    test('with the hotspot off nothing is sent for any of them', () async {
      await channel.stop();
      await _settle();
      final before = core.sent.length;
      await GlitchVpnCore.debugOnCoreEvent(500, '[xray] connecting');
      await GlitchVpnCore.debugOnCoreEvent(508, '[service] Reattached');
      GlitchVpnCore.debugRegisterStatus = (_) {};
      GlitchVpnCore.debugAttachCoreEvents();
      await _settle();
      expect(core.sent, hasLength(before));
    });
  });
}
