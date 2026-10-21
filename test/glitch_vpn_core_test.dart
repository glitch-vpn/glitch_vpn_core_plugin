import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_conn_channel.dart';

void main() {
  group('VpnRouting.toOpts', () {
    test('a single tier goes out as a one-element routingTiers', () {
      final opts = const VpnRouting(
        mode: 'direct-all',
        tiers: [
          VpnRoutingTier(
            proxy: ['geosite:youtube', ' domain:x.com '],
            direct: ['geoip:ru'],
            block: [''],
          ),
        ],
        localNetworksDirect: true,
        disableIPv6: true,
        disableUDP: true,
      ).toOpts();
      expect(opts.keys, {
        'routingMode',
        'routingTiers',
        'localNetworksDirect',
        'disableIPv6',
        'disableUDP',
      });
      expect(opts['routingMode'], 'direct-all');
      expect(jsonDecode(opts['routingTiers']!), [
        {
          'direct': ['geoip:ru'],
          'proxy': ['geosite:youtube', 'domain:x.com'],
        },
      ]);
      expect(opts['localNetworksDirect'], '1');
      expect(opts['disableIPv6'], '1');
      expect(opts['disableUDP'], '1');
    });

    test('a matcher holding a comma stays one matcher', () {
      final opts = const VpnRouting(
        tiers: [
          VpnRoutingTier(block: [r'regexp:^ad[0-9]{2,5}\.example$']),
        ],
      ).toOpts();
      expect(jsonDecode(opts['routingTiers']!), [
        {
          'block': [r'regexp:^ad[0-9]{2,5}\.example$'],
        },
      ]);
    });

    test('two tiers emit routingTiers JSON', () {
      final opts = const VpnRouting(
        tiers: [
          VpnRoutingTier(proxy: [' domain:vk.ru ']),
          VpnRoutingTier(direct: ['domain:ru'], block: ['geosite:ads']),
        ],
      ).toOpts();
      expect(jsonDecode(opts['routingTiers']!), [
        {
          'proxy': ['domain:vk.ru'],
        },
        {
          'block': ['geosite:ads'],
          'direct': ['domain:ru'],
        },
      ]);
    });

    test('empty tiers are dropped', () {
      final opts = const VpnRouting(
        tiers: [
          VpnRoutingTier(direct: ['geoip:ru']),
          VpnRoutingTier(block: [' ', '']),
        ],
      ).toOpts();
      expect(opts.keys, {'routingTiers'});
      expect(jsonDecode(opts['routingTiers']!), [
        {
          'direct': ['geoip:ru'],
        },
      ]);

      // All empty → no rule keys, flags still emitted.
      final empty = const VpnRouting(
        tiers: [VpnRoutingTier()],
        localNetworksDirect: true,
      ).toOpts();
      expect(empty, {'localNetworksDirect': '1'});

      expect(const VpnRouting().toOpts(), isEmpty);
    });
  });

  test('VpnDns.toJson maps mode and omits empty collections', () {
    expect(const VpnDns().toJson(), {'mode': 'fake-ip'});
    expect(
      const VpnDns(
        mode: VpnDnsMode.normal,
        servers: ['1.1.1.1'],
        fakeIpFilter: ['*.lan'],
        hosts: {
          'dns.google': ['8.8.8.8', '8.8.4.4'],
          'domain:corp.local': ['10.0.0.53'],
        },
        directServers: ['77.88.8.8'],
      ).toJson(),
      {
        'mode': 'normal',
        'servers': ['1.1.1.1'],
        'fakeIpFilter': ['*.lan'],
        'hosts': {
          'dns.google': ['8.8.8.8', '8.8.4.4'],
          'domain:corp.local': ['10.0.0.53'],
        },
        'directServers': ['77.88.8.8'],
      },
    );
  });

  test('balancer strategies and fingerprints are gated per engine', () {
    expect(balancerStrategiesFor(VpnEngine.awg), contains('leastping'));
    expect(balancerStrategiesFor(VpnEngine.mihomo), contains('url-test'));
    expect(fingerprintsFor(VpnEngine.awg), isEmpty);
    expect(fingerprintsFor(VpnEngine.xray), contains('chrome'));
  });

  test('domain strategies are xray-only', () {
    expect(domainStrategiesFor(VpnEngine.xray), [
      'asis',
      'ipifnonmatch',
      'ipondemand',
    ]);
    expect(domainStrategiesFor(VpnEngine.mihomo), isEmpty);
    expect(domainStrategiesFor(VpnEngine.awg), isEmpty);
  });

  test('geoAssetsDir absolute-path check follows the target platform', () {
    // Matches Go's filepath.IsAbs, which the core applies: a POSIX root is not
    // absolute on Windows and a drive letter is not absolute elsewhere. Both
    // tables run on every host, so neither branch depends on where the suite
    // happens to be executed.
    const winOk = [r'C:\geo', 'C:/geo', r'\\host\share\geo'];
    const winBad = ['geo', r'..\geo', 'geo/dat', r'C:geo', '/opt/geo', ''];
    const posixOk = ['/opt/geo', '/opt/geo/'];
    const posixBad = ['geo', '../geo', r'C:\geo', ''];
    for (final p in winOk) {
      expect(
        GlitchVpnCore.debugIsAbsolutePath(p, windows: true),
        isTrue,
        reason: p,
      );
    }
    for (final p in winBad) {
      expect(
        GlitchVpnCore.debugIsAbsolutePath(p, windows: true),
        isFalse,
        reason: p,
      );
    }
    for (final p in posixOk) {
      expect(
        GlitchVpnCore.debugIsAbsolutePath(p, windows: false),
        isTrue,
        reason: p,
      );
    }
    for (final p in posixBad) {
      expect(
        GlitchVpnCore.debugIsAbsolutePath(p, windows: false),
        isFalse,
        reason: p,
      );
    }
  });

  test('engineIds parses payloads and tolerates garbage', () async {
    addTearDown(() {
      GlitchVpnCore.debugCapabilitiesJsonProvider = null;
      GlitchVpnCore.debugResetEngineIdsCache();
    });
    Future<Set<String>> read(String json) async {
      GlitchVpnCore.debugResetEngineIdsCache();
      GlitchVpnCore.debugCapabilitiesJsonProvider = () async => json;
      return GlitchVpnCore.engineIds();
    }

    expect(await read('{"engines":["xray","awg","mihomo"]}'), {
      'xray',
      'awg',
      'mihomo',
    });
    expect(await read('{"engines":[]}'), isEmpty);
    expect(await read('not json'), isEmpty);
    expect(await read('[1,2,3]'), isEmpty);
    expect(await read('{"engines":[1,"xray"]}'), {'xray'});
  });

  test('engineIds never caches an empty result', () async {
    var calls = 0;
    addTearDown(() {
      GlitchVpnCore.debugCapabilitiesJsonProvider = null;
      GlitchVpnCore.debugResetEngineIdsCache();
    });
    GlitchVpnCore.debugResetEngineIdsCache();

    GlitchVpnCore.debugCapabilitiesJsonProvider = () async {
      calls++;
      throw StateError('transient native failure');
    };
    expect(await GlitchVpnCore.engineIds(), isEmpty);
    expect(calls, 1);

    // The failure was not cached: the next call retries and gets the real set.
    GlitchVpnCore.debugCapabilitiesJsonProvider = () async {
      calls++;
      return '{"engines":["xray","awg"]}';
    };
    expect(await GlitchVpnCore.engineIds(), {'xray', 'awg'});
    expect(calls, 2);

    // The non-empty set is cached: no further reads.
    expect(await GlitchVpnCore.engineIds(), {'xray', 'awg'});
    expect(calls, 2);
  });

  group('CoreVersions', () {
    test('reads every engine the core reports', () {
      final v = CoreVersions.tryParse(
        '{"xray_core":"25.3.6","amneziawg":"0.2.12","mihomo":"1.19.2"}',
      )!;
      expect(v.xrayCore, '25.3.6');
      expect(v.amneziawg, '0.2.12');
      expect(v.mihomo, '1.19.2');
    });

    test('an engine absent or reported unknown is null', () {
      final v = CoreVersions.tryParse(
        '{"xray_core":"unknown","amneziawg":" "}',
      )!;
      expect(v.xrayCore, isNull);
      expect(v.amneziawg, isNull);
      expect(v.mihomo, isNull);
    });

    test('garbage is null', () {
      expect(CoreVersions.tryParse('not json'), isNull);
      expect(CoreVersions.tryParse('[1,2]'), isNull);
    });

    test('getCoreVersions never throws', () async {
      addTearDown(() => GlitchVpnCore.debugCoreVersionsJsonProvider = null);
      GlitchVpnCore.debugCoreVersionsJsonProvider = () async =>
          throw ArgumentError('library did not load');
      final failed = await GlitchVpnCore.getCoreVersions();
      expect(failed.xrayCore, isNull);
      expect(failed.amneziawg, isNull);
      expect(failed.mihomo, isNull);

      GlitchVpnCore.debugCoreVersionsJsonProvider = () async => 'not json';
      expect((await GlitchVpnCore.getCoreVersions()).mihomo, isNull);

      GlitchVpnCore.debugCoreVersionsJsonProvider = () async =>
          '{"mihomo":"1.19.2"}';
      expect((await GlitchVpnCore.getCoreVersions()).mihomo, '1.19.2');
    });
  });

  test('PingResult.fromJson tolerates missing fields', () {
    final r = PingResult.fromJson(const {
      'index': 3,
      'alive': true,
      'delayMs': 42,
    });
    expect(r.index, 3);
    expect(r.engine, '');
    expect(r.alive, isTrue);
    expect(r.delayMs, 42);
    expect(r.error, isNull);
  });

  test('VpnConnEvent.tryParse returns null on malformed input', () {
    expect(VpnConnEvent.tryParse('not json'), isNull);
    final e = VpnConnEvent.tryParse(
      '{"engine":"mihomo","host":"x.com","outbound":"proxy","status":"accepted"}',
    );
    expect(e, isNotNull);
    expect(e!.host, 'x.com');
    expect(e.blocked, isFalse);
    final blocked = VpnConnEvent.tryParse(
      '{"engine":"xray","host":"ads.example","outbound":"block","status":"rejected"}',
    );
    expect(blocked!.blocked, isTrue);
  });
}
