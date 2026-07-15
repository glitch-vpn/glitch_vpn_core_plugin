import 'package:plugin_platform_interface/plugin_platform_interface.dart';

import 'glitch_vpn_core_method_channel.dart';

abstract class GlitchVpnCorePlatform extends PlatformInterface {
  GlitchVpnCorePlatform() : super(token: _token);

  static final Object _token = Object();

  static GlitchVpnCorePlatform _instance = MethodChannelGlitchVpnCore();

  static GlitchVpnCorePlatform get instance => _instance;

  static set instance(GlitchVpnCorePlatform instance) {
    PlatformInterface.verifyToken(instance, _token);
    _instance = instance;
  }

  Future<String?> getPlatformVersion() {
    throw UnimplementedError('platformVersion() has not been implemented.');
  }
}
