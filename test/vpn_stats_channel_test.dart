import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_stats_channel.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final channel = VpnStatsChannel.instance;
  late List<VpnStats> heard;

  setUp(() {
    channel.reset();
    heard = [];
    final sub = channel.stream.listen(heard.add);
    addTearDown(sub.cancel);
  });

  group('reset', () {
    test('clears every figure and emits the cleared stats', () {
      channel.emit(1000, 2000, 29000, linkUp: true, probeMs: 40);
      heard.clear();

      channel.reset();

      expect(channel.value.durationMs, 0);
      expect(channel.value.downloadBytes, 0);
      expect(channel.value.linkUp, isNull);
      expect(channel.listenable.value.durationMs, 0);
      expect(heard.single.durationMs, 0);
    });

    test('of a channel already at zero emits nothing', () {
      channel.reset();

      expect(heard, isEmpty);
    });

    test('says so when only the link state differs from zero', () {
      channel.emit(0, 0, 0, linkUp: false);
      heard.clear();

      channel.reset();

      expect(channel.value.linkUp, isNull);
      expect(heard, hasLength(1));
    });

    test('says so when only the probe time differs from zero', () {
      channel.emit(0, 0, 0, probeMs: 80);
      heard.clear();

      channel.reset();

      expect(channel.value.probeMs, -1);
      expect(heard, hasLength(1));
    });
  });

  group('a session ending', () {
    for (final (name, code) in [
      ('the engine stopping', 504),
      ('an engine error', 502),
      ('another core owning the engine', 506),
    ]) {
      test('through $name clears the last tick once', () async {
        VpnStatusChannel.instance.emit(VpnStatus.connected);
        await GlitchVpnCore.debugOnCoreEvent(
          300,
          '{"rx":5,"tx":6,"durationMs":29000}',
        );
        expect(channel.value.durationMs, 29000);
        heard.clear();

        await GlitchVpnCore.debugOnCoreEvent(code, '[xray] ended');

        expect(channel.value.durationMs, 0);
        expect(heard, hasLength(1));
        expect(heard.single.durationMs, 0);
      });
    }
  });
}
