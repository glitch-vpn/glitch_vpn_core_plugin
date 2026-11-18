#ifndef FLUTTER_PLUGIN_GLITCH_VPN_CORE_ASYNC_HANDOFF_H_
#define FLUTTER_PLUGIN_GLITCH_VPN_CORE_ASYNC_HANDOFF_H_

#include <flutter/encodable_value.h>

#include <cstdint>
#include <map>
#include <mutex>
#include <utility>

namespace glitch_vpn_core {

// Where background workers leave their results for the platform thread. The
// plugin and every worker hold it by shared_ptr, so a worker that finishes
// after the plugin is gone finds it closed and drops its result.
class AsyncHandoff {
 public:
  // False once closed: the result is dropped and nobody is to be woken.
  bool Deliver(uint64_t id, flutter::EncodableValue value) {
    std::lock_guard<std::mutex> lock(mutex_);
    if (closed_) return false;
    done_.emplace(id, std::move(value));
    return true;
  }

  std::map<uint64_t, flutter::EncodableValue> TakeDone() {
    std::lock_guard<std::mutex> lock(mutex_);
    std::map<uint64_t, flutter::EncodableValue> ready;
    ready.swap(done_);
    return ready;
  }

  void Close() {
    std::lock_guard<std::mutex> lock(mutex_);
    closed_ = true;
    done_.clear();
  }

 private:
  std::mutex mutex_;
  std::map<uint64_t, flutter::EncodableValue> done_;
  bool closed_ = false;
};

}  // namespace glitch_vpn_core

#endif  // FLUTTER_PLUGIN_GLITCH_VPN_CORE_ASYNC_HANDOFF_H_
