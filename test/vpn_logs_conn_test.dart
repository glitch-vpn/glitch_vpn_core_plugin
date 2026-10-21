import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/src/core_time.dart';
import 'package:glitch_vpn_core/vpn_conn_channel.dart';
import 'package:glitch_vpn_core/vpn_logs_channel.dart';

void main() {
  group('coreTime', () {
    test('reads a stamp with an offset as UTC', () {
      final at = coreTime('2026-10-21T12:00:00+02:00');
      expect(at.isUtc, isTrue);
      expect(at, DateTime.utc(2026, 10, 21, 10));
    });

    test('falls back to the arrival time in UTC', () {
      for (final ts in <Object?>[
        null,
        1792576800,
        '2026-10-21T10:00:00',
        'garbage',
      ]) {
        final before = DateTime.now().toUtc();
        final at = coreTime(ts);
        expect(at.isUtc, isTrue, reason: '$ts');
        expect(at.isBefore(before), isFalse, reason: '$ts');
      }
    });
  });

  group('VpnLog.tryParse', () {
    test('carries the core time, level and component', () {
      final log = VpnLog.tryParse(
        '{"ts":"2026-10-21T10:00:00.123456789Z","level":"warn",'
        '"component":"Xray/Inbound","message":"slow handshake"}',
      )!;
      expect(log.at, DateTime.utc(2026, 10, 21, 10, 0, 0, 123, 456));
      expect(log.level, VpnLogLevel.warn);
      expect(log.component, 'Xray/Inbound');
      expect(log.message, 'slow handshake');
    });

    test('a line without ts, level or component still parses', () {
      final before = DateTime.now().toUtc();
      final log = VpnLog.tryParse('{"message":"started"}')!;
      expect(log.level, VpnLogLevel.info);
      expect(log.component, isEmpty);
      expect(log.at.isUtc, isTrue);
      expect(log.at.isBefore(before), isFalse);
    });

    test('garbage and a line with no message are null', () {
      expect(VpnLog.tryParse('not json'), isNull);
      expect(VpnLog.tryParse('[1]'), isNull);
      expect(VpnLog.tryParse('{"level":"info","message":""}'), isNull);
    });

    test('levels map from every engine spelling', () {
      expect(VpnLogLevel.fromCore('trace'), VpnLogLevel.trace);
      expect(VpnLogLevel.fromCore('debug'), VpnLogLevel.debug);
      expect(VpnLogLevel.fromCore('info'), VpnLogLevel.info);
      expect(VpnLogLevel.fromCore('warning'), VpnLogLevel.warn);
      expect(VpnLogLevel.fromCore('ERROR'), VpnLogLevel.error);
      expect(VpnLogLevel.fromCore('panic'), VpnLogLevel.fatal);
      expect(VpnLogLevel.fromCore('silent'), VpnLogLevel.info);
    });
  });

  group('VpnLogsChannel', () {
    test('passes identical lines through', () {
      final received = <VpnLog>[];
      final sub = VpnLogsChannel.instance.stream.listen(received.add);
      addTearDown(sub.cancel);
      final line = VpnLog.tryParse(
        '{"ts":"2026-10-21T10:00:00Z","level":"info","message":"tick"}',
      )!;
      VpnLogsChannel.instance.emit(line);
      VpnLogsChannel.instance.emit(line);
      expect(received, hasLength(2));
      expect(VpnLogsChannel.instance.value, same(line));
      expect(VpnLogsChannel.instance.listenable.value, same(line));
    });
  });

  group('VpnConnEvent', () {
    test('carries the core time', () {
      final event = VpnConnEvent.tryParse(
        '{"ts":"2026-10-21T10:00:01.5Z","engine":"xray","host":"x.com"}',
      )!;
      expect(event.at, DateTime.utc(2026, 10, 21, 10, 0, 1, 500));
    });
  });
}
