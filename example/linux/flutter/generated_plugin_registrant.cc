//
//  Generated file. Do not edit.
//

// clang-format off

#include "generated_plugin_registrant.h"

#include <glitch_vpn_core/glitch_vpn_core_plugin.h>

void fl_register_plugins(FlPluginRegistry* registry) {
  g_autoptr(FlPluginRegistrar) glitch_vpn_core_registrar =
      fl_plugin_registry_get_registrar_for_plugin(registry, "GlitchVpnCorePlugin");
  glitch_vpn_core_plugin_register_with_registrar(glitch_vpn_core_registrar);
}
