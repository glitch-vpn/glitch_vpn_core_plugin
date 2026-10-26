import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_status_channel.dart';

const _texts = VpnNotificationTexts(
  title: 'title',
  channel: 'channel',
  connecting: 'connecting',
  connected: 'connected',
  disconnecting: 'disconnecting',
  disconnectAction: 'disconnect',
  byteUnits: VpnByteUnits(
    bytes: 'b',
    kilobytes: 'kb',
    megabytes: 'mb',
    gigabytes: 'gb',
    terabytes: 'tb',
  ),
);

void main() {
  setUp(() {
    GlitchVpnCore.debugResetEngineIdsCache();
    GlitchVpnCore.debugCapabilitiesJsonProvider = () async =>
        '{"engines":["xray","awg"]}';
  });

  tearDown(() {
    GlitchVpnCore.debugAwgPickJsonProvider = null;
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
        (core) => core.connect(
          engine: VpnEngine.xray,
          config: 'x',
          notification: _texts,
        ),
      );
      expect(e.code, 'BUSY');
      expect(VpnStatusChannel.instance.value.status, VpnStatus.connecting);
    });

    test('ENGINE_NOT_IN_BUILD for an engine the build lacks', () async {
      final e = await refusalOf(
        (core) => core.connect(
          engine: VpnEngine.mihomo,
          config: 'x',
          notification: _texts,
        ),
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
          notification: _texts,
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
          notification: _texts,
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
          notification: _texts,
          geoAssetsDir: 'geo',
        ),
      );
      expect(e.code, 'RELATIVE_GEO_PATH');
    });

    test('PROXY_NOT_SUPPORTED for awg in proxy mode', () async {
      final e = await refusalOf(
        (core) => core.connect(
          engine: VpnEngine.awg,
          config: 'x',
          notification: _texts,
          proxyPort: 10808,
        ),
      );
      expect(e.code, 'PROXY_NOT_SUPPORTED');
    });

    test(
      'AWG_PICK_FAILED when the core picks no link, with its reason',
      () async {
        String? request;
        GlitchVpnCore.debugAwgPickJsonProvider = (r) async {
          request = r;
          return '{"error":"chosen awg link has no Interface address"}';
        };
        final e = await refusalOf(
          (core) => GlitchVpnCore.debugPickAwgLink('awg://AAAA\nawg://BBBB', {
            'balancerStrategy': 'random',
          }),
        );
        expect(e.code, 'AWG_PICK_FAILED');
        expect(e.message, 'chosen awg link has no Interface address');
        expect(request, contains('"balancerStrategy":"random"'));
        expect(request, contains(r'awg://AAAA\nawg://BBBB'));
      },
    );

    test('AWG_PICK_FAILED for an unreadable answer', () async {
      GlitchVpnCore.debugAwgPickJsonProvider = (_) async => 'garbage';
      final e = await refusalOf(
        (core) => GlitchVpnCore.debugPickAwgLink('awg://AAAA', const {}),
      );
      expect(e.code, 'AWG_PICK_FAILED');
    });

    test('AWG_PICK_FAILED when the call itself throws', () async {
      GlitchVpnCore.debugAwgPickJsonProvider = (_) async =>
          throw ArgumentError('no AwgPick symbol');
      final e = await refusalOf(
        (core) => GlitchVpnCore.debugPickAwgLink('awg://AAAA', const {}),
      );
      expect(e.code, 'AWG_PICK_FAILED');
    });

    test(
      'a pick answer comes back as the chosen link and its addresses',
      () async {
        GlitchVpnCore.debugAwgPickJsonProvider = (_) async =>
            '{"index":1,"addresses":["10.2.0.2/32"],"peersCarryV6":false}';
        final pick = await GlitchVpnCore.debugPickAwgLink(
          'awg://a\nawg://b',
          const {},
        );
        expect(pick.index, 1);
        expect(pick.addresses, ['10.2.0.2/32']);
      },
    );
  });
}
