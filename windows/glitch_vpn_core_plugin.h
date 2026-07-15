#ifndef FLUTTER_PLUGIN_GLITCH_VPN_CORE_PLUGIN_H_
#define FLUTTER_PLUGIN_GLITCH_VPN_CORE_PLUGIN_H_

#include <flutter/method_channel.h>
#include <flutter/plugin_registrar_windows.h>

#include <cstdint>
#include <functional>
#include <map>
#include <memory>
#include <mutex>

// Forward-declare HWND to keep <windows.h> out of this header.
struct HWND__;

namespace glitch_vpn_core {

class GlitchVpnCorePlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit GlitchVpnCorePlugin(flutter::PluginRegistrarWindows* registrar);
  ~GlitchVpnCorePlugin() override;

  GlitchVpnCorePlugin(const GlitchVpnCorePlugin&) = delete;
  GlitchVpnCorePlugin& operator=(const GlitchVpnCorePlugin&) = delete;

  void HandleMethodCall(
      const flutter::MethodCall<flutter::EncodableValue>& method_call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);

 private:
  using Result =
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>>;

  // RunAsync runs work() on a background std::thread and delivers its result on
  // the platform thread (via a window message). The MethodResult is never
  // touched off the platform thread - required, as it is not thread-safe.
  void RunAsync(Result result, std::function<flutter::EncodableValue()> work);

  // DrainCompleted delivers all finished background results; runs on the
  // platform thread from the top-level window proc.
  void DrainCompleted();

  flutter::PluginRegistrarWindows* registrar_ = nullptr;
  HWND__* message_window_ = nullptr;  // top-level window we PostMessage back to
  int proc_delegate_id_ = -1;
  uint64_t next_id_ = 0;
  std::map<uint64_t, Result> pending_;  // platform-thread only

  std::mutex done_mutex_;  // guards done_ (worker → platform hand-off)
  std::map<uint64_t, flutter::EncodableValue> done_;
};

}  // namespace glitch_vpn_core

#endif  // FLUTTER_PLUGIN_GLITCH_VPN_CORE_PLUGIN_H_
