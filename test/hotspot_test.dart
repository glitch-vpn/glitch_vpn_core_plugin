import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('HotspotCredentials.fromMap', () {
    test('parses full map', () {
      final c = HotspotCredentials.fromMap(const {
        'ssid': 'GlitchVPN Wifi',
        'password': 'abc12345',
        'tunneled': true,
      });
      expect(c.ssid, 'GlitchVPN Wifi');
      expect(c.password, 'abc12345');
      expect(c.isOpen, isFalse);
      expect(c.tunneled, isTrue);
    });

    test('empty password means open network', () {
      final c = HotspotCredentials.fromMap(const {'ssid': 'x', 'password': ''});
      expect(c.password, isNull);
      expect(c.isOpen, isTrue);
      expect(c.tunneled, isFalse);
    });
  });

  group('startHotspot argument validation', () {
    test('rejects a short WPA2 passphrase', () {
      expect(
        () => GlitchVpnCore.instance.startHotspot(password: 'short'),
        throwsArgumentError,
      );
    });

    test('rejects a passphrase longer than 63 chars', () {
      expect(
        () => GlitchVpnCore.instance.startHotspot(password: 'a' * 64),
        throwsArgumentError,
      );
    });

    test('rejects an SSID longer than 32 bytes', () {
      expect(
        () => GlitchVpnCore.instance.startHotspot(ssid: 'a' * 33),
        throwsArgumentError,
      );
      // Multibyte UTF-8: 17 Cyrillic chars = 34 bytes.
      expect(
        () => GlitchVpnCore.instance.startHotspot(ssid: 'ц' * 17),
        throwsArgumentError,
      );
    });

    test('rejects password combined with open', () {
      expect(
        () => GlitchVpnCore.instance.startHotspot(
          open: true,
          password: 'abc12345',
        ),
        throwsArgumentError,
      );
    });
  });

  group('non-Windows platforms', () {
    test('startHotspot throws UnsupportedError', () {
      expect(
        () => GlitchVpnCore.instance.startHotspot(),
        throwsUnsupportedError,
      );
      expect(
        () => GlitchVpnCore.instance.stopHotspot(),
        throwsUnsupportedError,
      );
    });

    test('getHotspotCredentials is null, isHotspotSupported is false',
        () async {
      expect(await GlitchVpnCore.instance.getHotspotCredentials(), isNull);
      expect(await GlitchVpnCore.instance.isHotspotSupported(), isFalse);
    });
  }, skip: Platform.isWindows);

  group('method channel round-trip', () {
    const channel = MethodChannel('glitch_vpn_core');
    final calls = <MethodCall>[];
    Object? nativeResult;

    setUp(() {
      calls.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return nativeResult;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('startHotspot defaults SSID and generates a random password',
        () async {
      nativeResult = <Object?, Object?>{
        'ssid': GlitchVpnCore.defaultHotspotSsid,
        'password': 'native-echo1',
        'open': false,
        'tunneled': true,
      };
      final creds = await GlitchVpnCore.instance.startHotspot();

      expect(calls, hasLength(1));
      expect(calls.single.method, 'startHotspot');
      final args = calls.single.arguments as Map;
      expect(args['ssid'], GlitchVpnCore.defaultHotspotSsid);
      final sent = args['password'] as String;
      expect(sent.length, 12);
      expect(RegExp(r'^[A-Za-z0-9]+$').hasMatch(sent), isTrue);
      expect(args['open'], isFalse);

      expect(creds.ssid, GlitchVpnCore.defaultHotspotSsid);
      expect(creds.password, 'native-echo1');
      expect(creds.tunneled, isTrue);
      expect(GlitchVpnCore.instance.hotspotCredentials, same(creds));
    });

    test('startHotspot rethrows native errors as PlatformException', () async {
      nativeResult = <Object?, Object?>{
        'errorCode': 'HOTSPOT_NOT_SUPPORTED',
        'errorMessage': 'No Wi-Fi adapter',
      };
      expect(
        () => GlitchVpnCore.instance.startHotspot(),
        throwsA(
          isA<PlatformException>()
              .having((e) => e.code, 'code', 'HOTSPOT_NOT_SUPPORTED')
              .having((e) => e.message, 'message', 'No Wi-Fi adapter'),
        ),
      );
    });

    test('getHotspotCredentials maps active config and clears on inactive',
        () async {
      nativeResult = <Object?, Object?>{
        'active': true,
        'ssid': 'MySpot',
        'password': 'secret123',
        'tunneled': false,
      };
      final creds = await GlitchVpnCore.instance.getHotspotCredentials();
      expect(creds, isNotNull);
      expect(creds!.ssid, 'MySpot');
      expect(creds.password, 'secret123');
      expect(creds.tunneled, isFalse);

      nativeResult = <Object?, Object?>{'active': false};
      expect(await GlitchVpnCore.instance.getHotspotCredentials(), isNull);
    });

    test('stopHotspot clears cached credentials', () async {
      nativeResult = <Object?, Object?>{
        'ssid': 'x',
        'password': 'abc12345',
        'open': false,
        'tunneled': false,
      };
      await GlitchVpnCore.instance.startHotspot();
      expect(GlitchVpnCore.instance.hotspotCredentials, isNotNull);

      nativeResult = true;
      await GlitchVpnCore.instance.stopHotspot();
      expect(GlitchVpnCore.instance.hotspotCredentials, isNull);
      expect(calls.last.method, 'stopHotspot');
    });
  }, skip: !Platform.isWindows);
}
