import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';

const _supported = '{"engines":["xray","mihomo"],"features":["linkRelay"]}';
const _oldCore = '{"engines":["xray","mihomo"],"features":["routeTargets"]}';
const _link = 'ss://chacha20-ietf-poly1305:pw@192.0.2.1:8388#relay';
const _answer =
    '{"id":"a1b2","port":50123,"user":"u1","pass":"p1","engine":"xray"}';

void main() {
  tearDown(() {
    GlitchVpnCore.debugCapabilitiesJsonProvider = null;
    GlitchVpnCore.debugResetCapabilitiesCache();
    GlitchVpnCore.debugOpenLinkRelayJsonProvider = null;
    GlitchVpnCore.debugCloseLinkRelayProvider = null;
  });

  group('LinkRelay.tryParse', () {
    test('reads the id, the port, the login and the engine', () {
      final relay = LinkRelay.tryParse(_answer)!;
      expect(relay.id, 'a1b2');
      expect(relay.port, 50123);
      expect(relay.user, 'u1');
      expect(relay.password, 'p1');
      expect(relay.engine, 'xray');
      expect(relay.address, 'socks5://u1:p1@127.0.0.1:50123');
    });

    test('leaves the engine empty when the core names none', () {
      final relay = LinkRelay.tryParse(
        '{"id":"a","port":1,"user":"u","pass":"p"}',
      )!;
      expect(relay.engine, '');
    });

    test('returns null for an answer it cannot use', () {
      for (final garbage in [
        'not json',
        '[]',
        '"text"',
        '{"error":"too many relays open"}',
        '{"id":"a","port":0,"user":"u","pass":"p"}',
        '{"id":"a","port":1,"user":"","pass":"p"}',
        '{"id":"a","port":1,"user":"u"}',
        '{"port":1,"user":"u","pass":"p"}',
      ]) {
        expect(LinkRelay.tryParse(garbage), isNull, reason: garbage);
      }
    });

    test('leaves the login out of toString', () {
      final text = LinkRelay.tryParse(_answer).toString();
      expect(text, contains('127.0.0.1:50123'));
      expect(text, isNot(contains('u1')));
      expect(text, isNot(contains('p1')));
    });
  });

  group('GlitchVpnCore.openLinkRelay', () {
    setUp(
      () =>
          GlitchVpnCore.debugCapabilitiesJsonProvider = () async => _supported,
    );

    test('sends the link, and the options that were given', () async {
      late Map<String, dynamic> sent;
      GlitchVpnCore.debugOpenLinkRelayJsonProvider = (request) async {
        sent = jsonDecode(request) as Map<String, dynamic>;
        return _answer;
      };

      final relay = await GlitchVpnCore.openLinkRelay(
        _link,
        engine: VpnEngine.mihomo,
        timeoutMs: 4000,
        idleSec: 30,
      );

      expect(relay.port, 50123);
      expect(sent, {
        'link': _link,
        'engine': 'mihomo',
        'timeoutMs': 4000,
        'idleSec': 30,
      });
    });

    test('leaves out the options it was not given', () async {
      late Map<String, dynamic> sent;
      GlitchVpnCore.debugOpenLinkRelayJsonProvider = (request) async {
        sent = jsonDecode(request) as Map<String, dynamic>;
        return _answer;
      };

      await GlitchVpnCore.openLinkRelay(_link);

      expect(sent, {'link': _link});
    });

    test('throws LINK_RELAY_FAILED with the core reason', () async {
      GlitchVpnCore.debugOpenLinkRelayJsonProvider = (_) async =>
          '{"error":"too many relays open"}';

      await expectLater(
        GlitchVpnCore.openLinkRelay(_link),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'LINK_RELAY_FAILED')
              .having((e) => e.message, 'message', 'too many relays open'),
        ),
      );
    });

    test('throws LINK_RELAY_FAILED for an unreadable answer', () async {
      GlitchVpnCore.debugOpenLinkRelayJsonProvider = (_) async => 'garbage';

      await expectLater(
        GlitchVpnCore.openLinkRelay(_link),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'LINK_RELAY_FAILED')
              .having((e) => e.message, 'message', 'unreadable relay answer'),
        ),
      );
    });

    test(
      'closes a relay the core opened but whose answer it cannot use',
      () async {
        final closed = <String>[];
        GlitchVpnCore.debugCloseLinkRelayProvider = (id) async =>
            closed.add(id);
        GlitchVpnCore.debugOpenLinkRelayJsonProvider = (_) async =>
            '{"id":"a1b2","port":50123,"user":"u1","engine":"xray"}';

        await expectLater(
          GlitchVpnCore.openLinkRelay(_link),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'LINK_RELAY_FAILED',
            ),
          ),
        );
        expect(closed, ['a1b2']);
      },
    );

    test(
      'is refused before the core is asked when the core has none',
      () async {
        GlitchVpnCore.debugCapabilitiesJsonProvider = () async => _oldCore;
        GlitchVpnCore.debugResetCapabilitiesCache();
        var asked = false;
        GlitchVpnCore.debugOpenLinkRelayJsonProvider = (_) async {
          asked = true;
          return _answer;
        };

        await expectLater(
          GlitchVpnCore.openLinkRelay(_link),
          throwsA(
            isA<PlatformException>().having(
              (e) => e.code,
              'code',
              'LINK_RELAY_NOT_IN_BUILD',
            ),
          ),
        );
        expect(asked, isFalse);
      },
    );
  });

  group('GlitchVpnCore.closeLinkRelay', () {
    setUp(
      () =>
          GlitchVpnCore.debugCapabilitiesJsonProvider = () async => _supported,
    );

    test('hands the id to the core, from the relay too', () async {
      final closed = <String>[];
      GlitchVpnCore.debugCloseLinkRelayProvider = (id) async => closed.add(id);

      await LinkRelay.tryParse(_answer)!.close();
      await GlitchVpnCore.closeLinkRelay('other');

      expect(closed, ['a1b2', 'other']);
    });

    test('ignores an empty id and a core without relays', () async {
      final closed = <String>[];
      GlitchVpnCore.debugCloseLinkRelayProvider = (id) async => closed.add(id);

      await GlitchVpnCore.closeLinkRelay('');
      GlitchVpnCore.debugCapabilitiesJsonProvider = () async => _oldCore;
      GlitchVpnCore.debugResetCapabilitiesCache();
      await GlitchVpnCore.closeLinkRelay('a1b2');

      expect(closed, isEmpty);
    });
  });
}
