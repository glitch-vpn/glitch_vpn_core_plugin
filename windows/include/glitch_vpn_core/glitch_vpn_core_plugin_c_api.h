#ifndef FLUTTER_PLUGIN_GLITCH_VPN_CORE_PLUGIN_C_API_H_
#define FLUTTER_PLUGIN_GLITCH_VPN_CORE_PLUGIN_C_API_H_

#include <flutter/plugin_registrar_windows.h>

#ifdef GLITCH_VPN_CORE_PLUGIN_IMPL
#define FLUTTER_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FLUTTER_PLUGIN_EXPORT __declspec(dllimport)
#endif

#ifdef __cplusplus
extern "C" {
#endif

FLUTTER_PLUGIN_EXPORT void GlitchVpnCorePluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // FLUTTER_PLUGIN_GLITCH_VPN_CORE_PLUGIN_C_API_H_
