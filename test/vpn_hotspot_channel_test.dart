import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/vpn_hotspot_channel.dart';

/// Every call, native or core, in the order it happened.
final _order = <String>[];

class _FakeNative implements HotspotNative {
  final calls = <String>[];
  final answers = <String, Map<Object?, Object?>?>{};
  Map<String, Object?>? lastStartArguments;

  /// Holds a call's answer until completed, to look at the world meanwhile.
  final holds = <String, Completer<void>>{};

  @override
  Future<Map<Object?, Object?>?> invoke(
    String method, [
    Map<String, Object?>? arguments,
  ]) async {
    calls.add(method);
    _order.add('native:$method');
    if (method == 'hotspotStart') lastStartArguments = arguments;
    await holds[method]?.future;
    return answers[method];
  }
}

class _FakeCore implements HotspotCore {
  int prepareCode = 0;
  Object? prepareThrows;
  final setCodes = <int>[]; // answers in turn; empty means 0

  /// Holds the first SetHotspotSharing answer until completed.
  Completer<void>? holdFirstSet;
  final sent = <HotspotSharingWanted>[];
  int prepareCalls = 0;

  @override
  Future<int> prepare() async {
    _order.add('core:prepare');
    prepareCalls++;
    if (prepareThrows != null) throw prepareThrows!;
    return prepareCode;
  }

  @override
  Future<int> setSharing(String json) async {
    _order.add('core:set');
    final m = jsonDecode(json) as Map;
    sent.add(
      HotspotSharingWanted(
        on: m['on'] as bool,
        blockWhileTunnelDown: m['blockWhileTunnelDown'] as bool,
        blockedClients: (m['blockedClients'] as List).cast<String>(),
      ),
    );
    final hold = holdFirstSet;
    if (hold != null) {
      holdFirstSet = null;
      await hold.future;
    }
    return setCodes.isEmpty ? 0 : setCodes.removeAt(0);
  }
}

Map<Object?, Object?> _clientsAnswer(List<Map<String, String>> clients) => {
  'clients': clients,
};

const _ok = {'ok': true};

const _tv = {
  'mac': '00-11-22-33-44-55',
  'ipv4': '192.168.137.33',
  'name': 'tv',
};

/// Lets queued core calls (each runs in its own isolate for real) finish.
Future<void> _settleQueue() => Future<void>.delayed(Duration.zero);

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

    test('carries the reason when unsupported, as a code', () {
      for (final entry in {
        'noAdapter': HotspotUnsupportedReason.noAdapter,
        'cannotHost': HotspotUnsupportedReason.cannotHost,
        'noConnection': HotspotUnsupportedReason.noConnection,
        'something else': HotspotUnsupportedReason.unknown,
      }.entries) {
        final c = HotspotCapability.parse({
          'supported': false,
          'reason': entry.key,
        });
        expect(c.supported, isFalse);
        expect(c.unsupportedReason, entry.value);
        expect(c.bands, isEmpty);
      }
    });

    test('a missing answer is unavailable on this platform', () {
      final c = HotspotCapability.parse(null);
      expect(c.supported, isFalse);
      expect(c.unsupportedReason, HotspotUnsupportedReason.platform);
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
    late _FakeCore core;
    late VpnHotspotChannel channel;
    late List<HotspotState> states;

    setUp(() async {
      _order.clear();
      native = _FakeNative()
        ..answers['hotspotStart'] = _ok
        ..answers['hotspotStop'] = _ok
        ..answers['hotspotStatus'] = {'state': 'on', 'ours': true}
        ..answers['hotspotClients'] = _clientsAnswer([]);
      core = _FakeCore();
      channel = VpnHotspotChannel.withNative(native, core: core);
      states = [];
      channel.stream.listen((u) => states.add(u.state));
      await channel.configure(
        ssid: 'test-net',
        passphrase: 'made-up-pass',
        band: HotspotBand.ghz2_4,
      );
    });

    test('start goes starting, on and sends the configuration', () async {
      await channel.start();
      expect(states, [HotspotState.starting, HotspotState.on]);
      expect(native.lastStartArguments, {
        'ssid': 'test-net',
        'passphrase': 'made-up-pass',
        'band': '2.4',
      });
    });

    test(
      'the core repairs first, then WinRT starts, then the core is told',
      () async {
        await channel.start();
        await _settleQueue();
        expect(_order.where((c) => !c.contains('hotspotClients')), [
          'core:prepare',
          'native:hotspotStart',
          'core:set',
        ]);
        expect(core.sent.single.on, isTrue);
      },
    );

    test('nothing reaches SetHotspotSharing before WinRT reports on', () async {
      native.holds['hotspotStart'] = Completer<void>();
      final started = channel.start();
      await _settleQueue();
      await _settleQueue();
      expect(channel.value.state, HotspotState.starting);
      expect(core.sent, isEmpty);
      // Block calls while starting record the wish and send nothing.
      channel.blockClient('00:11:22:33:44:55');
      channel.setBlockWhileTunnelDown(false);
      await _settleQueue();
      expect(core.sent, isEmpty);
      native.holds['hotspotStart']!.complete();
      await started;
      await _settleQueue();
      expect(core.sent, hasLength(1));
      expect(core.sent.single.blockWhileTunnelDown, isFalse);
    });

    test(
      'a failed start sends nothing, and a stop then has nothing to undo',
      () async {
        native.answers['hotspotStart'] = {'reason': 'wifiOff'};
        await channel.start();
        await _settleQueue();
        expect(core.sent, isEmpty);
        await channel.stop();
        await _settleQueue();
        expect(core.sent, isEmpty);
      },
    );

    test(
      'a device already joined and blocked is in the first state sent',
      () async {
        native.answers['hotspotClients'] = _clientsAnswer([_tv]);
        channel.blockClient('00:11:22:33:44:55');
        await channel.start();
        await _settleQueue();
        expect(core.sent.single.blockedClients, ['00:11:22:33:44:55']);
      },
    );

    test('PrepareHotspot codes map to failure reasons', () async {
      const expected = {
        1: HotspotFailureReason.coreUnreachable,
        3: HotspotFailureReason.unsupported,
        5: HotspotFailureReason.sharingNeedsElevation,
        6: HotspotFailureReason.sharingRepairFailed,
        9: HotspotFailureReason.unknown,
      };
      for (final entry in expected.entries) {
        core.prepareCode = entry.key;
        native.calls.clear();
        await channel.start();
        expect(
          channel.value.state,
          HotspotState.failed,
          reason: '${entry.key}',
        );
        expect(channel.value.failure!.reason, entry.value);
        expect(native.calls, isNot(contains('hotspotStart')));
      }
      expect(core.sent, isEmpty);
    });

    test('a core that throws is unreachable', () async {
      core.prepareThrows = StateError('no library');
      await channel.start();
      expect(
        channel.value.failure!.reason,
        HotspotFailureReason.coreUnreachable,
      );
    });

    test('code 4, a hotspot runs, goes on to the WinRT start', () async {
      core.prepareCode = 4;
      await channel.start();
      expect(channel.value.state, HotspotState.on);
      expect(native.calls, contains('hotspotStart'));
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

    test(
      'stop goes off, clears the clients and tells the core on false',
      () async {
        native.answers['hotspotClients'] = _clientsAnswer([_tv]);
        await channel.start();
        expect(channel.clients.value, hasLength(1));
        await channel.stop();
        await _settleQueue();
        expect(channel.value.state, HotspotState.off);
        expect(channel.clients.value, isEmpty);
        expect(core.sent.map((w) => w.on), [true, false]);
      },
    );

    test('a stop Windows refused leaves the hotspot on for the core', () async {
      await channel.start();
      native.answers['hotspotStop'] = {
        'reason': 'operationInProgress',
        'running': true,
      };
      await channel.stop();
      await _settleQueue();
      expect(channel.value.state, HotspotState.failed);
      expect(core.sent.map((w) => w.on), [true]);
      native.answers['hotspotStop'] = _ok;
      await channel.stop();
      await _settleQueue();
      expect(core.sent.map((w) => w.on), [true, false]);
    });

    test('a stop with no answer about the hotspot leaves it on', () async {
      await channel.start();
      native.answers['hotspotStop'] = {'reason': 'noConnection'};
      await channel.stop();
      await _settleQueue();
      expect(channel.value.failure!.reason, HotspotFailureReason.noConnection);
      expect(core.sent.map((w) => w.on), [true]);
    });

    test('a stop that turned it off but could not restore is off', () async {
      native.answers['hotspotClients'] = _clientsAnswer([_tv]);
      await channel.start();
      native.answers['hotspotStop'] = {
        'reason': 'configureFailed',
        'running': false,
      };
      await channel.stop();
      await _settleQueue();
      expect(channel.value.state, HotspotState.failed);
      expect(
        channel.value.failure!.reason,
        HotspotFailureReason.configureFailed,
      );
      expect(channel.clients.value, isEmpty);
      expect(core.sent.map((w) => w.on), [true, false]);
    });

    test('a restart inside one call never tells the core off', () async {
      native.answers['hotspotClients'] = _clientsAnswer([_tv]);
      await channel.start();
      native.answers['hotspotStart'] = {'running': true, 'restarted': true};
      await channel.configure(
        ssid: 'other',
        passphrase: 'made-up-pass',
        band: HotspotBand.auto,
      );
      expect(native.calls.where((c) => c == 'hotspotStart'), hasLength(2));
      expect(native.lastStartArguments!['ssid'], 'other');
      expect(channel.value.state, HotspotState.on);
      await _settleQueue();
      // The whole state, on, goes again; the core keeps blocking meanwhile.
      expect(core.sent.map((w) => w.on), [true, true]);
    });

    test('a Save that changes nothing changes nothing', () async {
      await channel.start();
      native.calls.clear();
      core.prepareCalls = 0;
      await channel.configure(
        ssid: 'test-net',
        passphrase: 'made-up-pass',
        band: HotspotBand.ghz2_4,
      );
      await _settleQueue();
      expect(native.calls, isEmpty);
      expect(core.prepareCalls, 0);
      expect(core.sent.map((w) => w.on), [true]);
      expect(channel.value.state, HotspotState.on);
    });

    test(
      'a start that keeps a running hotspot never tells the core off',
      () async {
        native.answers['hotspotStart'] = {'running': true, 'restarted': false};
        await channel.start();
        await channel.start();
        await _settleQueue();
        expect(core.sent.map((w) => w.on), [true]);
      },
    );

    test('a reconfigure Windows refuses before stopping stays on', () async {
      await channel.start();
      native.answers['hotspotStart'] = {
        'reason': 'operationInProgress',
        'running': true,
      };
      await channel.configure(
        ssid: 'other',
        passphrase: 'made-up-pass',
        band: HotspotBand.auto,
      );
      await _settleQueue();
      expect(channel.value.state, HotspotState.failed);
      expect(core.sent.map((w) => w.on), [true]);
    });

    test('a reconfigure the core refuses to prepare stays on', () async {
      await channel.start();
      core.prepareCode = 1;
      await channel.configure(
        ssid: 'other',
        passphrase: 'made-up-pass',
        band: HotspotBand.auto,
      );
      await _settleQueue();
      expect(
        channel.value.failure!.reason,
        HotspotFailureReason.coreUnreachable,
      );
      expect(core.sent.map((w) => w.on), [true]);
    });

    test('a reconfigure that stopped it and then failed is off', () async {
      await channel.start();
      native.answers['hotspotStart'] = {
        'reason': 'configureFailed',
        'running': false,
      };
      await channel.configure(
        ssid: 'other',
        passphrase: 'made-up-pass',
        band: HotspotBand.auto,
      );
      await _settleQueue();
      expect(channel.value.state, HotspotState.failed);
      expect(core.sent.map((w) => w.on), [true, false]);
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

    test(
      'reconcile adopts a hotspot of ours and ignores a foreign one',
      () async {
        native.answers['hotspotStatus'] = {'state': 'on', 'ours': false};
        await channel.reconcile();
        expect(channel.value.state, HotspotState.off);
        await _settleQueue();
        expect(core.sent, isEmpty);
        native.answers['hotspotStatus'] = {'state': 'on', 'ours': true};
        await channel.reconcile();
        await _settleQueue();
        expect(channel.value.state, HotspotState.on);
        expect(core.sent.single.on, isTrue);
        expect(core.prepareCalls, 0);
      },
    );

    test('a hotspot Windows turned off ends as off with on false', () async {
      await channel.start();
      native.answers['hotspotStatus'] = {'state': 'off', 'ours': true};
      await channel.pollOnce();
      await _settleQueue();
      expect(channel.value.state, HotspotState.off);
      expect(native.calls, contains('hotspotStop'));
      expect(core.sent.map((w) => w.on), [true, false]);
    });

    test('a poll in transition leaves the state alone', () async {
      await channel.start();
      native.answers['hotspotStatus'] = {'state': 'transition'};
      await channel.pollOnce();
      expect(channel.value.state, HotspotState.on);
    });
  });

  group('what WinRT says is what the core hears', () {
    late _FakeNative native;
    late _FakeCore core;
    late VpnHotspotChannel channel;

    setUp(() async {
      _order.clear();
      native = _FakeNative()
        ..answers['hotspotStart'] = _ok
        ..answers['hotspotStop'] = _ok
        ..answers['hotspotStatus'] = {'state': 'on', 'ours': true}
        ..answers['hotspotClients'] = _clientsAnswer([]);
      core = _FakeCore();
      channel = VpnHotspotChannel.withNative(native, core: core);
    });

    test('reconcile then configure on the launch never sends off', () async {
      await channel.reconcile();
      await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
      native.answers['hotspotStart'] = {'running': true, 'restarted': false};
      await channel.start();
      await _settleQueue();
      expect(core.sent.map((w) => w.on), [true]);
    });

    test('a status that could not be read keeps the state', () async {
      await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
      await channel.start();
      native.answers['hotspotStatus'] = {'state': 'unknown', 'ours': true};
      await channel.pollOnce();
      native.answers['hotspotStatus'] = null;
      await channel.pollOnce();
      expect(channel.value.state, HotspotState.on);
      expect(native.calls, isNot(contains('hotspotStop')));
    });

    test(
      'reconcile with settings left saved and no hotspot puts them back',
      () async {
        native.answers['hotspotStatus'] = {'state': 'off', 'ours': true};
        await channel.reconcile();
        expect(native.calls, contains('hotspotStop'));
        expect(channel.value.state, HotspotState.off);
        await _settleQueue();
        expect(core.sent, isEmpty);
      },
    );

    test('reconcile with nothing of ours does nothing', () async {
      native.answers['hotspotStatus'] = {'state': 'off', 'ours': false};
      await channel.reconcile();
      expect(native.calls, ['hotspotStatus']);
    });

    test(
      'a core that never takes on true loses the hotspot after three polls',
      () async {
        core.setCodes.addAll([1, 1, 1, 1, 1, 1, 1, 1]);
        await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
        await channel.start();
        await _settleQueue();
        for (var i = 0; i < VpnHotspotChannel.untakenPollLimit - 1; i++) {
          await channel.pollOnce();
          await _settleQueue();
          expect(channel.value.state, HotspotState.on, reason: 'poll $i');
        }
        await channel.pollOnce();
        await _settleQueue();
        expect(channel.value.state, HotspotState.failed);
        expect(
          channel.value.failure!.reason,
          HotspotFailureReason.coreUnreachable,
        );
        expect(native.calls, contains('hotspotStop'));
      },
    );

    test(
      'a stop whose outcome is unknown on a channel never started sends nothing',
      () async {
        for (final reason in ['noConnection', 'stopFailed']) {
          native.answers['hotspotStop'] = {'reason': reason};
          await channel.stop();
          await _settleQueue();
          expect(channel.value.state, HotspotState.failed, reason: reason);
        }
        expect(core.sent, isEmpty);
      },
    );

    test(
      'reconcile with settings saved whose stop is unknown sends nothing',
      () async {
        native.answers['hotspotStatus'] = {'state': 'off', 'ours': true};
        native.answers['hotspotStop'] = {'reason': 'stopFailed'};
        await channel.reconcile();
        await _settleQueue();
        expect(core.sent, isEmpty);
      },
    );

    test(
      'a stop whose outcome is unknown leaves a running hotspot on',
      () async {
        await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
        await channel.start();
        native.answers['hotspotStop'] = {'reason': 'stopFailed'};
        await channel.stop();
        await _settleQueue();
        expect(core.sent.map((w) => w.on), [true]);
      },
    );

    test(
      'an ack that arrives after the hotspot went off is not the next one',
      () async {
        final held = Completer<void>();
        core.holdFirstSet = held;
        await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
        await channel.start();
        await _settleQueue();
        native.answers['hotspotStatus'] = {'state': 'off', 'ours': true};
        await channel.pollOnce();
        expect(channel.value.state, HotspotState.off);
        held.complete();
        for (var i = 0; i < 4; i++) {
          await _settleQueue();
        }
        expect(core.sent.map((w) => w.on), [true, false]);
        // The hotspot comes up again and the core never takes on true.
        core.setCodes.addAll([1, 1, 1, 1, 1, 1, 1, 1]);
        native.answers['hotspotStatus'] = {'state': 'on', 'ours': true};
        await channel.start();
        await _settleQueue();
        for (var i = 0; i < VpnHotspotChannel.untakenPollLimit; i++) {
          await channel.pollOnce();
          await _settleQueue();
        }
        expect(channel.value.state, HotspotState.failed);
        expect(
          channel.value.failure!.reason,
          HotspotFailureReason.coreUnreachable,
        );
      },
    );

    test('a core that takes on true late keeps the hotspot', () async {
      core.setCodes.addAll([1, 1]);
      await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
      await channel.start();
      await _settleQueue();
      await channel.pollOnce();
      await _settleQueue();
      await channel.pollOnce();
      await _settleQueue();
      await channel.pollOnce();
      await _settleQueue();
      expect(channel.value.state, HotspotState.on);
    });

    test(
      'a failure with the same reason and another detail is published',
      () async {
        await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
        final details = <String>[];
        channel.stream.listen((u) {
          if (u.failure != null) details.add(u.failure!.detail);
        });
        native.answers['hotspotStart'] = {
          'reason': 'startFailed',
          'detail': 'a',
        };
        await channel.start();
        native.answers['hotspotStart'] = {
          'reason': 'startFailed',
          'detail': 'b',
        };
        await channel.start();
        expect(details, ['a', 'b']);
      },
    );
  });

  group('the core, after the hotspot is on', () {
    late _FakeNative native;
    late _FakeCore core;
    late VpnHotspotChannel channel;

    setUp(() async {
      _order.clear();
      native = _FakeNative()
        ..answers['hotspotStart'] = _ok
        ..answers['hotspotStop'] = _ok
        ..answers['hotspotStatus'] = {'state': 'on', 'ours': true}
        ..answers['hotspotClients'] = _clientsAnswer([
          _tv,
          {'mac': 'AA-BB-CC-DD-EE-FF', 'ipv4': '192.168.137.40'},
        ]);
      core = _FakeCore();
      channel = VpnHotspotChannel.withNative(native, core: core);
      await channel.configure(ssid: 'test-net', passphrase: 'made-up-pass');
      await channel.start();
      await _settleQueue();
    });

    test('start sends on with the block default', () {
      expect(core.sent.first.on, isTrue);
      expect(core.sent.first.blockWhileTunnelDown, isTrue);
      expect(core.sent.first.blockedClients, isEmpty);
    });

    test('blocking lists the device as blocked and sends its MAC', () async {
      channel.blockClient('00:11:22:33:44:55');
      await _settleQueue();
      expect(
        channel.clients.value.firstWhere((c) => c.name == 'tv').blocked,
        isTrue,
      );
      expect(core.sent.last.blockedClients, ['00:11:22:33:44:55']);
      expect(
        core.sent.last.toJson(),
        '{"on":true,"blockWhileTunnelDown":true,'
        '"blockedClients":["00:11:22:33:44:55"]}',
      );
    });

    test('a blocked device that left stays listed and blocked', () async {
      channel.blockClient('00:11:22:33:44:55');
      await _settleQueue();
      native.answers['hotspotClients'] = _clientsAnswer([]);
      await channel.refreshClients();
      await _settleQueue();
      final listed = channel.clients.value.single;
      expect(listed.mac, '00:11:22:33:44:55');
      expect(listed.name, 'tv');
      expect(listed.ipv4, '192.168.137.33');
      expect(listed.blocked, isTrue);
      expect(core.sent.last.blockedClients, ['00:11:22:33:44:55']);
    });

    test('a blocked device Windows does not list is still sent', () async {
      channel.blockClient('11:22:33:44:55:66');
      await _settleQueue();
      expect(channel.clients.value.last.mac, '11:22:33:44:55:66');
      expect(channel.clients.value.last.blocked, isTrue);
      expect(core.sent.last.blockedClients, ['11:22:33:44:55:66']);
    });

    test('a blocked device that came back under another address is '
        'still sent by its MAC', () async {
      channel.blockClient('00:11:22:33:44:55');
      native.answers['hotspotClients'] = _clientsAnswer([
        {'mac': '00-11-22-33-44-55', 'ipv4': '192.168.137.77'},
      ]);
      await channel.refreshClients();
      await _settleQueue();
      expect(core.sent.last.blockedClients, ['00:11:22:33:44:55']);
    });

    test('a client read that failed keeps the list and the state', () async {
      final before = channel.clients.value;
      expect(before, isNotEmpty);
      final sent = core.sent.length;
      native.answers['hotspotClients'] = {
        'reason': 'unknown',
        'detail': 'read failed',
      };
      await channel.refreshClients();
      await channel.pollOnce();
      await _settleQueue();
      expect(channel.clients.value, before);
      expect(core.sent, hasLength(sent));
    });

    test('unblocking and the block switch send once per change', () async {
      channel.blockClient('00:11:22:33:44:55');
      await _settleQueue();
      final before = core.sent.length;
      channel.blockClient('00:11:22:33:44:55');
      await _settleQueue();
      expect(core.sent, hasLength(before));
      channel.unblockClient('00:11:22:33:44:55');
      await _settleQueue();
      expect(core.sent.last.blockedClients, isEmpty);
      channel.setBlockWhileTunnelDown(false);
      await _settleQueue();
      expect(core.sent.last.blockWhileTunnelDown, isFalse);
      expect(channel.wantedSharing, core.sent.last);
    });

    test('at most eight blocked clients are sent', () async {
      native.answers['hotspotClients'] = _clientsAnswer([
        for (var i = 0; i < 10; i++)
          {'mac': '00-00-00-00-00-0$i', 'ipv4': '192.168.137.${40 + i}'},
      ]);
      await channel.refreshClients();
      for (var i = 0; i < 10; i++) {
        channel.blockClient('00:00:00:00:00:0$i');
      }
      await _settleQueue();
      expect(core.sent.last.blockedClients, hasLength(8));
    });

    test('the state is sent again after the core comes back', () async {
      final before = core.sent.length;
      channel.coreReattached();
      await _settleQueue();
      expect(core.sent, hasLength(before + 1));
      expect(core.sent.last, core.sent[before - 1]);
    });

    test(
      'an engine connecting sends the state again, before it connects',
      () async {
        // A core that lost its state (a service that crashed and came back)
        // gets the whole state again at the connecting event.
        final before = core.sent.length;
        channel.coreSessionStarting();
        await _settleQueue();
        expect(core.sent, hasLength(before + 1));
        expect(core.sent.last.on, isTrue);
      },
    );

    test(
      'an engine connecting while the hotspot is off sends nothing',
      () async {
        await channel.stop();
        await _settleQueue();
        final before = core.sent.length;
        channel.coreSessionStarting();
        await _settleQueue();
        expect(core.sent, hasLength(before));
      },
    );

    test(
      'a core that comes back while the hotspot is off hears nothing',
      () async {
        await channel.stop();
        await _settleQueue();
        final before = core.sent.length;
        channel.coreReattached();
        await _settleQueue();
        expect(core.sent, hasLength(before));
      },
    );

    test(
      'a core that did not answer is asked again at the next poll',
      () async {
        core.setCodes.add(1);
        channel.setBlockWhileTunnelDown(false);
        await _settleQueue();
        expect(core.sent, hasLength(2));
        await channel.pollOnce();
        await _settleQueue();
        expect(core.sent, hasLength(3));
        expect(core.sent[2], core.sent[1]);
        await channel.pollOnce();
        await _settleQueue();
        expect(core.sent, hasLength(3));
      },
    );

    test(
      'an on false the core did not take is asked again with the hotspot off',
      () async {
        core.setCodes.add(1);
        await channel.stop();
        await _settleQueue();
        expect(core.sent.map((w) => w.on), [true, false]);
        expect(channel.value.state, HotspotState.off);
        await channel.pollOnce();
        await _settleQueue();
        expect(core.sent.map((w) => w.on), [true, false, false]);
        await channel.pollOnce();
        await _settleQueue();
        expect(core.sent, hasLength(3));
      },
    );

    test('a core that took the state is not asked again', () async {
      for (var i = 0; i < 5; i++) {
        await channel.pollOnce();
        await _settleQueue();
      }
      expect(core.sent, hasLength(1));
      expect(channel.value.state, HotspotState.on);
    });

    test('a refused request stops the hotspot and reports it failed', () async {
      core.setCodes.add(2);
      channel.setBlockWhileTunnelDown(false);
      await _settleQueue();
      await _settleQueue();
      expect(channel.value.state, HotspotState.failed);
      expect(channel.value.failure!.reason, HotspotFailureReason.sharingFailed);
      expect(native.calls, contains('hotspotStop'));
      await _settleQueue();
      expect(core.sent.last.on, isFalse);
    });

    test('event 600 is kept for the app', () {
      channel.handleCoreEvent(
        '{"shared":"tunnel","blocked":false,"error":"","restartOn":""}',
      );
      expect(channel.sharing.value!.shared, 'tunnel');
      expect(channel.sharing.value!.blocked, isFalse);
    });

    test(
      'event 600 none with an error stops the hotspot and fails it',
      () async {
        channel.handleCoreEvent(
          '{"shared":"none","blocked":true,"error":"no hotspot adapter",'
          '"restartOn":""}',
        );
        await _settleQueue();
        await _settleQueue();
        expect(channel.value.state, HotspotState.failed);
        expect(
          channel.value.failure!.reason,
          HotspotFailureReason.sharingFailed,
        );
        expect(channel.value.failure!.detail, 'no hotspot adapter');
        expect(native.calls, contains('hotspotStop'));
        expect(channel.sharing.value, isNull);
        await _settleQueue();
        expect(core.sent.last.on, isFalse);
      },
    );

    test('event 600 none without an error is quiet', () async {
      channel.handleCoreEvent('{"shared":"none","blocked":true,"error":""}');
      await _settleQueue();
      expect(channel.value.state, HotspotState.on);
    });

    test('event 600 asking for a restart is not acted on', () async {
      channel.handleCoreEvent(
        '{"shared":"none","blocked":true,"error":"","restartOn":"tunnel"}',
      );
      await _settleQueue();
      await _settleQueue();
      expect(channel.value.state, HotspotState.on);
      expect(native.calls.where((c) => c == 'hotspotStart'), hasLength(1));
    });

    test(
      'event 600 is dropped when malformed or while the hotspot is off',
      () async {
        channel.handleCoreEvent('not json');
        channel.handleCoreEvent('[]');
        expect(channel.sharing.value, isNull);
        await channel.stop();
        channel.handleCoreEvent('{"shared":"tunnel","blocked":false}');
        expect(channel.sharing.value, isNull);
      },
    );
  });

  group('HotspotSharingEvent.tryParse', () {
    test('is lenient with missing and unknown fields', () {
      final e = HotspotSharingEvent.tryParse('{"extra":1,"restartOn":"x"}')!;
      expect(e.shared, 'none');
      expect(e.blocked, isFalse);
      expect(e.error, isEmpty);
    });

    test('garbage is null', () {
      expect(HotspotSharingEvent.tryParse('{'), isNull);
      expect(HotspotSharingEvent.tryParse('3'), isNull);
    });
  });
}
