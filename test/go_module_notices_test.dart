import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glitch_vpn_core/glitch_vpn_core.dart';

void main() {
  test(
    'the core\'s Go module notices ship as the asset the constant names',
    () {
      final path = coreGoModuleNoticesAsset.replaceFirst(
        'packages/glitch_vpn_core/',
        '',
      );
      final notices = File(path);

      expect(notices.existsSync(), isTrue, reason: '$path is missing');
      expect(
        notices.readAsStringSync(),
        startsWith('Go modules linked by the release binaries:'),
      );
      expect(File('pubspec.yaml').readAsLinesSync(), contains('    - $path'));
    },
  );
}
