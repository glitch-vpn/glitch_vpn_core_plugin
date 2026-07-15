import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';
import 'package:glitch_vpn_core/vpn_conn_channel.dart';

void main() {
  test('VpnRouting.toOpts flattens matcher lists', () {
    final opts = const VpnRouting(
      mode: 'direct-all',
      proxy: ['geosite:youtube', ' domain:x.com '],
      direct: ['geoip:ru'],
      block: [''],
      localNetworksDirect: true,
      disableIPv6: true,
      disableUDP: true,
    ).toOpts();
    expect(opts['routingMode'], 'direct-all');
    expect(opts['proxyRules'], 'geosite:youtube,domain:x.com');
    expect(opts['directRules'], 'geoip:ru');
    expect(opts.containsKey('blockRules'), isFalse);
    expect(opts['localNetworksDirect'], '1');
    expect(opts['disableIPv6'], '1');
    expect(opts['disableUDP'], '1');
  });

  test('VpnDns.toJson maps mode and omits empty lists', () {
    expect(const VpnDns().toJson(), {'mode': 'fake-ip'});
    expect(
      const VpnDns(
        mode: VpnDnsMode.normal,
        servers: ['1.1.1.1'],
        fakeIpFilter: ['*.lan'],
      ).toJson(),
      {
        'mode': 'normal',
        'servers': ['1.1.1.1'],
        'fakeIpFilter': ['*.lan'],
      },
    );
  });

  test('balancer strategies and fingerprints are gated per engine', () {
    expect(balancerStrategiesFor(VpnEngine.awg), contains('leastping'));
    expect(balancerStrategiesFor(VpnEngine.mihomo), contains('url-test'));
    expect(fingerprintsFor(VpnEngine.awg), isEmpty);
    expect(fingerprintsFor(VpnEngine.xray), contains('chrome'));
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
