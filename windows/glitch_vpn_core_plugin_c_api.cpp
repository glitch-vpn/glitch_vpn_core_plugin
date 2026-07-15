#define GLITCH_VPN_CORE_PLUGIN_IMPL
#include "include/glitch_vpn_core/glitch_vpn_core_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "glitch_vpn_core_plugin.h"

void GlitchVpnCorePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  glitch_vpn_core::GlitchVpnCorePlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
