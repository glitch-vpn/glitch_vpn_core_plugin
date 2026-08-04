import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/vpn_ip_channel.dart';
import 'package:glitch_vpn_core/vpn_server_channel.dart';

void main() {
  group('VpnServerSelection.tryParse', () {
    test('full balancer payload', () {
      final sel = VpnServerSelection.tryParse(
        '{"engine":"xray","strategy":"leastping","total":2,'
        '"selected":{"index":1,"name":"Ams #2","host":"nl.example.com","port":443,"protocol":"vless"},'
        '"servers":['
        '{"index":0,"name":"Fra","host":"de.example.com","port":443,"protocol":"vless"},'
        '{"index":1,"name":"Ams #2","host":"nl.example.com","port":443,"protocol":"vless"}]}',
      );
      expect(sel, isNotNull);
      expect(sel!.engine, 'xray');
      expect(sel.strategy, 'leastping');
      expect(sel.total, 2);
      expect(sel.servers, hasLength(2));
      expect(sel.selected?.index, 1);
      expect(sel.selected?.host, 'nl.example.com');
      expect(sel.selected?.port, 443);
      expect(sel.selected?.displayName, 'Ams #2');
    });

    test('per-connection strategy has no selected', () {
      final sel = VpnServerSelection.tryParse(
        '{"engine":"xray","strategy":"random","total":2,'
        '"servers":[{"index":0,"host":"a.example.com"},{"index":1,"host":"b.example.com"}]}',
      );
      expect(sel, isNotNull);
      expect(sel!.selected, isNull);
      expect(sel.servers[0].name, isEmpty);
      expect(sel.servers[0].displayName, 'a.example.com');
    });

    test('single server payload', () {
      final sel = VpnServerSelection.tryParse(
        '{"engine":"awg","total":1,'
        '"selected":{"index":0,"host":"wg.example.com","port":51820,"protocol":"awg"},'
        '"servers":[{"index":0,"host":"wg.example.com","port":51820,"protocol":"awg"}]}',
      );
      expect(sel, isNotNull);
      expect(sel!.strategy, isEmpty);
      expect(sel.selected?.protocol, 'awg');
    });

    test('garbage returns null', () {
      expect(VpnServerSelection.tryParse('not json'), isNull);
      expect(VpnServerSelection.tryParse('[1,2,3]'), isNull);
    });
  });

  group('VpnExternalIp.tryParse', () {
    test('both families', () {
      final ip = VpnExternalIp.tryParse(
        '{"ipv4":"203.0.113.7","ipv6":"2001:db8::1"}',
      );
      expect(ip, isNotNull);
      expect(ip!.ipv4, '203.0.113.7');
      expect(ip.ipv6, '2001:db8::1');
      expect(ip.hasAny, isTrue);
      expect(ip.unsupported, isFalse);
    });

    test('v6 disabled', () {
      final ip = VpnExternalIp.tryParse(
        '{"ipv4":"203.0.113.7","ipv6Error":"disabled"}',
      );
      expect(ip!.ipv4, '203.0.113.7');
      expect(ip.ipv6, isNull);
      expect(ip.ipv6Error, 'disabled');
    });

    test('unsupported platform', () {
      final ip = VpnExternalIp.tryParse(
        '{"ipv4Error":"unsupported","ipv6Error":"unsupported"}',
      );
      expect(ip!.hasAny, isFalse);
      expect(ip.unsupported, isTrue);
    });

    test('garbage returns null', () {
      expect(VpnExternalIp.tryParse('nope'), isNull);
    });
  });

  group('channels', () {
    test('server channel caches and resets', () {
      final ch = VpnServerChannel.instance;
      final sel = VpnServerSelection.tryParse(
        '{"engine":"xray","total":1,"servers":[{"index":0,"host":"a"}]}',
      )!;
      ch.emit(sel);
      expect(ch.value, same(sel));
      expect(ch.listenable.value, same(sel));
      ch.reset();
      expect(ch.value, isNull);
      expect(ch.listenable.value, isNull);
    });

    test('ip channel caches and resets', () {
      final ch = VpnIpChannel.instance;
      final ip = VpnExternalIp.tryParse('{"ipv4":"203.0.113.7"}')!;
      ch.emit(ip);
      expect(ch.value, same(ip));
      expect(ch.listenable.value, same(ip));
      ch.reset();
      expect(ch.value, isNull);
      expect(ch.listenable.value, isNull);
    });
  });
}
