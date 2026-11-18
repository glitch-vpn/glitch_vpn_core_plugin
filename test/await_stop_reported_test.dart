import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';

void main() {
  final status = VpnStatusChannel.instance;

  tearDown(() => status.emit(VpnStatus.disconnected));

  test('returns at once when no stop is in progress', () async {
    status.emit(VpnStatus.disconnected);

    await GlitchVpnCore.awaitStopReported(limit: Duration.zero);
  });

  test('holds until the core reports the stop', () async {
    status.emit(VpnStatus.disconnecting);
    var returned = false;
    final waiting = GlitchVpnCore.awaitStopReported().then(
      (_) => returned = true,
    );

    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(returned, isFalse);

    status.emit(VpnStatus.disconnected);
    await waiting;
    expect(returned, isTrue);
  });

  test('gives up after the limit when no report comes', () async {
    status.emit(VpnStatus.disconnecting);

    await GlitchVpnCore.awaitStopReported(
      limit: const Duration(milliseconds: 20),
    );

    expect(status.value.status, VpnStatus.disconnecting);
  });
}
