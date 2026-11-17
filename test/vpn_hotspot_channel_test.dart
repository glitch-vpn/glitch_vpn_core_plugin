import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/vpn_hotspot_channel.dart';

class _FakeNative implements HotspotNative {
  final calls = <String>[];
  final answers = <String, Map<Object?, Object?>?>{};
  Map<String, Object?>? lastStartArguments;

  @override
  Future<Map<Object?, Object?>?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add(method);
    if (method == 'hotspotStart') lastStartArguments = arguments;
    return answers[method];
  }
}

Map<Object?, Object?> _clientsAnswer(List<Map<String, String>> clients) => {
  'clients': clients,
};

const _ok = {'ok': true};

void main() {
  group('HotspotClient', () {
    test('normalizes a MAC from any separator', () {
      expect(
        HotspotClient.normalizeMac('aa-bb-cc-dd-ee-ff'),
        'AA:BB:CC:DD:EE:FF',
      );
      expect(HotspotClient.normalizeMac('001122334455'), '00:11:22:33:44:55');
      expect(HotspotClient.normalizeMac('00:11:22'), isNull);
    });

    test('tryParse drops an entry without a MAC and empty fields', () {
      expect(HotspotClient.tryParse({'name': 'x'}), isNull);
      expect(HotspotClient.tryParse('junk'), isNull);
      final c = HotspotClient.tryParse({
        'name': '',
        'mac': '00-11-22-33-44-55',
        'ipv4': '192.168.137.33',
      })!;
      expect(c.name, isNull);
      expect(c.mac, '00:11:22:33:44:55');
      expect(c.ipv4, '192.168.137.33');
      expect(c.blocked, isFalse);
    });
  });

  group('HotspotCapability.parse', () {
    test('lists known bands and skips unknown ones', () {
      final c = HotspotCapability.parse({
        'supported': true,
        'bands': ['auto', '2.4', '6'],
      });
      expect(c.supported, isTrue);
      expect(c.bands, [HotspotBand.auto, HotspotBand.ghz2_4]);
    });

    test('carries the reason when unsupported', () {
      final c = HotspotCapability.parse({
        'supported': false,
        'reason': 'disabled by group policy',
      });
      expect(c.supported, isFalse);
      expect(c.unsupportedReason, 'disabled by group policy');
      expect(c.bands, isEmpty);
    });

    test('a missing answer is unavailable', () {
      expect(HotspotCapability.parse(null).supported, isFalse);
    });
  });

  group('validation', () {
    test('SSID is counted in UTF-8 bytes', () {
      expect(VpnHotspotChannel.isValidSsid('a' * 32), isTrue);
      expect(VpnHotspotChannel.isValidSsid('a' * 33), isFalse);
      expect(VpnHotspotChannel.isValidSsid('ц' * 16), isTrue);
      expect(VpnHotspotChannel.isValidSsid('ц' * 17), isFalse);
      expect(VpnHotspotChannel.isValidSsid(''), isFalse);
    });

    test('passphrase is 8 to 63 printable ASCII', () {
      expect(VpnHotspotChannel.isValidPassphrase('1234567'), isFalse);
      expect(VpnHotspotChannel.isValidPassphrase('12345678'), isTrue);
      expect(VpnHotspotChannel.isValidPassphrase('a' * 63), isTrue);
      expect(VpnHotspotChannel.isValidPassphrase('a' * 64), isFalse);
      expect(VpnHotspotChannel.isValidPassphrase('п' * 8), isFalse);
    });

    test('configure throws without echoing the passphrase', () {
      final channel = VpnHotspotChannel.withNative(_FakeNative());
      expect(
        () => channel.configure(ssid: 'x', passphrase: 'short'),
        throwsA(
          isA<ArgumentError>().having(
            (e) => e.toString(),
            'message',
            isNot(contains('short')),
          ),
        ),
      );
      expect(
        () => channel.configure(ssid: '', passphrase: 'longenough'),
        throwsArgumentError,
      );
    });

    test('start before configure is a state error', () {
      final channel = VpnHotspotChannel.withNative(_FakeNative());
      expect(channel.start, throwsStateError);
    });
  });

  group('state machine', () {
    late _FakeNative native;
    late VpnHotspotChannel channel;
    late List<HotspotState> states;

    setUp(() async {
      native = _FakeNative()
        ..answers['hotspotStart'] = _ok
        ..answers['hotspotStop'] = _ok
        ..answers['hotspotClients'] = _clientsAnswer([]);
      channel = VpnHotspotChannel.withNative(native);
      states = [];
      channel.stream.listen((u) => states.add(u.state));
      await channel.configure(
        ssid: 'test-net',
        passphrase: 'made-up-pass',
        band: HotspotBand.ghz2_4,
      );
    });

    test('start goes off, starting, on and sends the configuration', () async {
      await channel.start();
      expect(states, [HotspotState.starting, HotspotState.on]);
      expect(native.lastStartArguments, {
        'ssid': 'test-net',
        'passphrase': 'made-up-pass',
        'band': '2.4',
      });
    });

    test('a native failure is failed with its reason', () async {
      native.answers['hotspotStart'] = {
        'reason': 'wifiOff',
        'detail': 'Wi-Fi is turned off',
      };
      await channel.start();
      expect(channel.value.state, HotspotState.failed);
      expect(channel.value.failure!.reason, HotspotFailureReason.wifiOff);
      expect(channel.value.failure!.detail, 'Wi-Fi is turned off');
      native.answers['hotspotStart'] = _ok;
      await channel.start();
      expect(channel.value.state, HotspotState.on);
      expect(channel.value.failure, isNull);
    });

    test('an unknown reason code is unknown', () async {
      native.answers['hotspotStart'] = {'reason': 'weird'};
      await channel.start();
      expect(channel.value.failure!.reason, HotspotFailureReason.unknown);
    });

    test('a platform without the call is unsupported', () async {
      native.answers['hotspotStart'] = null;
      await channel.start();
      expect(channel.value.state, HotspotState.failed);
      expect(channel.value.failure!.reason, HotspotFailureReason.unsupported);
    });

    test('stop goes off and clears the clients', () async {
      native.answers['hotspotClients'] = _clientsAnswer([
        {'mac': '00-11-22-33-44-55', 'ipv4': '192.168.137.33'},
      ]);
      await channel.start();
      await channel.refreshClients();
      expect(channel.clients.value, hasLength(1));
      await channel.stop();
      expect(channel.value.state, HotspotState.off);
      expect(channel.clients.value, isEmpty);
    });

    test('a failed stop is failed, not off', () async {
      await channel.start();
      native.answers['hotspotStop'] = {'reason': 'operationInProgress'};
      await channel.stop();
      expect(channel.value.state, HotspotState.failed);
    });

    test('configure while on restarts with the new configuration', () async {
      await channel.start();
      await channel.configure(
        ssid: 'other',
        passphrase: 'made-up-pass',
        band: HotspotBand.auto,
      );
      expect(native.calls.where((c) => c == 'hotspotStart'), hasLength(2));
      expect(native.lastStartArguments!['ssid'], 'other');
      expect(channel.value.state, HotspotState.on);
    });

    test('calls queue behind a transition in flight', () async {
      final first = channel.start();
      final second = channel.stop();
      await Future.wait([first, second]);
      expect(
        native.calls.indexOf('hotspotStart'),
        lessThan(native.calls.indexOf('hotspotStop')),
      );
      expect(channel.value.state, HotspotState.off);
    });

    test('restartOn names the connection', () async {
      native.answers['hotspotRestartOn'] = _ok;
      await channel.start();
      await channel.restartOn(HotspotConnection.tunnel);
      expect(native.calls, contains('hotspotRestartOn'));
      expect(channel.value.state, HotspotState.on);
    });

    test(
      'reconcile adopts a hotspot of ours and ignores a foreign one',
      () async {
        native.answers['hotspotStatus'] = {'state': 'on', 'ours': false};
        await channel.reconcile();
        expect(channel.value.state, HotspotState.off);
        native.answers['hotspotStatus'] = {'state': 'on', 'ours': true};
        await channel.reconcile();
        expect(channel.value.state, HotspotState.on);
      },
    );
  });

  group('clients and the wanted sharing state', () {
    late _FakeNative native;
    late VpnHotspotChannel channel;
    late List<HotspotSharingWanted> pushed;

    setUp(() async {
      native = _FakeNative()
        ..answers['hotspotStart'] = _ok
        ..answers['hotspotClients'] = _clientsAnswer([
          {'mac': '00-11-22-33-44-55', 'ipv4': '192.168.137.33', 'name': 'tv'},
          {'mac': 'AA-BB-CC-DD-EE-FF', 'ipv4': '192.168.137.40'},
        ]);
      channel = VpnHotspotChannel.withNative(native);
      pushed = [];
      channel.sharingSink = pushed.add;
      await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
      await channel.start();
      await channel.refreshClients();
    });

    test('start pushes on with the block default', () {
      expect(pushed.first.on, isTrue);
      expect(pushed.first.blockWhileTunnelDown, isTrue);
      expect(pushed.first.blockedClients, isEmpty);
    });

    test('blocking lists the device as blocked and pushes its address', () {
      channel.blockClient('00:11:22:33:44:55');
      expect(
        channel.clients.value.firstWhere((c) => c.name == 'tv').blocked,
        isTrue,
      );
      expect(pushed.last.blockedClients, ['192.168.137.33']);
      expect(
        pushed.last.toJson(),
        '{"on":true,"blockWhileTunnelDown":true,'
        '"blockedClients":["192.168.137.33"]}',
      );
    });

    test(
      'a blocked device that left stays listed, without an address',
      () async {
        channel.blockClient('00:11:22:33:44:55');
        native.answers['hotspotClients'] = _clientsAnswer([]);
        await channel.refreshClients();
        final listed = channel.clients.value.single;
        expect(listed.mac, '00:11:22:33:44:55');
        expect(listed.blocked, isTrue);
        expect(pushed.last.blockedClients, isEmpty);
      },
    );

    test('unblocking and the block switch push once per change', () {
      channel.blockClient('00:11:22:33:44:55');
      final before = pushed.length;
      channel.blockClient('00:11:22:33:44:55');
      expect(pushed, hasLength(before));
      channel.unblockClient('00:11:22:33:44:55');
      expect(pushed.last.blockedClients, isEmpty);
      channel.setBlockWhileTunnelDown(false);
      expect(pushed.last.blockWhileTunnelDown, isFalse);
      expect(channel.wantedSharing, pushed.last);
    });

    test('stop pushes on false', () async {
      native.answers['hotspotStop'] = _ok;
      await channel.stop();
      expect(pushed.last.on, isFalse);
    });
  });
}
