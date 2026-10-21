import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';

void main() {
  setUp(() {
    GlitchVpnCore.debugResetEngineIdsCache();
    GlitchVpnCore.debugCapabilitiesJsonProvider = () async =>
        '{"engines":["xray","awg"]}';
  });

  tearDown(() {
    GlitchVpnCore.debugCapabilitiesJsonProvider = null;
    GlitchVpnCore.debugResetEngineIdsCache();
    VpnStatusChannel.instance.emit(VpnStatus.disconnected);
  });

  Future<PlatformException> refusalOf(
    Future<void> Function(GlitchVpnCore core) call,
  ) async {
    try {
      await call(GlitchVpnCore.instance);
    } on PlatformException catch (e) {
      return e;
    }
    fail('connect() returned without refusing');
  }

  group('connect refuses with a code', () {
    test('BUSY while a session is in progress, keeping its status', () async {
      VpnStatusChannel.instance.emit(VpnStatus.connecting);
      final e = await refusalOf(
        (core) => core.connect(engine: VpnEngine.xray, config: 'x'),
      );
      expect(e.code, 'BUSY');
      expect(VpnStatusChannel.instance.value.status, VpnStatus.connecting);
    });

    test('ENGINE_NOT_IN_BUILD for an engine the build lacks', () async {
      final e = await refusalOf(
        (core) => core.connect(engine: VpnEngine.mihomo, config: 'x'),
      );
      expect(e.code, 'ENGINE_NOT_IN_BUILD');
      expect(VpnStatusChannel.instance.value.status, VpnStatus.error);
      expect(VpnStatusChannel.instance.value.reason, e.message);
    });

    test('UNSUPPORTED_STRATEGY for another engine\'s balancer', () async {
      final e = await refusalOf(
        (core) => core.connect(
          engine: VpnEngine.xray,
          config: 'x',
          balancerStrategy: 'url-test',
        ),
      );
      expect(e.code, 'UNSUPPORTED_STRATEGY');
    });

    test('UNSUPPORTED_DOMAIN_STRATEGY outside xray', () async {
      final e = await refusalOf(
        (core) => core.connect(
          engine: VpnEngine.awg,
          config: 'x',
          domainStrategy: 'ipifnonmatch',
        ),
      );
      expect(e.code, 'UNSUPPORTED_DOMAIN_STRATEGY');
    });

    test('RELATIVE_GEO_PATH for a relative geo assets dir', () async {
      final e = await refusalOf(
        (core) => core.connect(
          engine: VpnEngine.xray,
          config: 'x',
          geoAssetsDir: 'geo',
        ),
      );
      expect(e.code, 'RELATIVE_GEO_PATH');
    });

    test('PROXY_NOT_SUPPORTED for awg in proxy mode', () async {
      final e = await refusalOf(
        (core) =>
            core.connect(engine: VpnEngine.awg, config: 'x', proxyPort: 10808),
      );
      expect(e.code, 'PROXY_NOT_SUPPORTED');
    });
  });
}
