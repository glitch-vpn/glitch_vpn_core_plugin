import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'glitch_vpn_core_platform_interface.dart';

class MethodChannelGlitchVpnCore extends GlitchVpnCorePlatform {
  @visibleForTesting
  final methodChannel = const MethodChannel('glitch_vpn_core');

  @override
  Future<String?> getPlatformVersion() async {
    final version = await methodChannel.invokeMethod<String>(
      'getPlatformVersion',
    );
    return version;
  }
}
