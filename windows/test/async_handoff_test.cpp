#include <gtest/gtest.h>

#include <atomic>
#include <memory>
#include <string>
#include <thread>
#include <vector>

#include "async_handoff.h"

namespace glitch_vpn_core {
namespace {

using flutter::EncodableValue;

TEST(AsyncHandoff, HandsOverWhatWasDeliveredOnce) {
  AsyncHandoff handoff;
  EXPECT_TRUE(handoff.Deliver(1, EncodableValue("one")));
  EXPECT_TRUE(handoff.Deliver(2, EncodableValue("two")));

  auto ready = handoff.TakeDone();
  ASSERT_EQ(ready.size(), 2u);
  EXPECT_EQ(std::get<std::string>(ready.at(1)), "one");
  EXPECT_EQ(std::get<std::string>(ready.at(2)), "two");
  EXPECT_TRUE(handoff.TakeDone().empty());
}

TEST(AsyncHandoff, DropsWhatArrivesAfterClosing) {
  AsyncHandoff handoff;
  handoff.Close();

  EXPECT_FALSE(handoff.Deliver(1, EncodableValue("late")));
  EXPECT_TRUE(handoff.TakeDone().empty());
}

TEST(AsyncHandoff, ClosingDropsWhatWasNotTaken) {
  AsyncHandoff handoff;
  ASSERT_TRUE(handoff.Deliver(1, EncodableValue("waiting")));

  handoff.Close();

  EXPECT_TRUE(handoff.TakeDone().empty());
}

TEST(AsyncHandoff, AWorkerOutlivesItsOwner) {
  auto owner = std::make_shared<AsyncHandoff>();
  std::shared_ptr<AsyncHandoff> workers_copy = owner;
  owner->Close();
  owner.reset();

  std::thread worker([handoff = std::move(workers_copy)] {
    EXPECT_FALSE(handoff->Deliver(1, EncodableValue("late")));
  });
  worker.join();
}

TEST(AsyncHandoff, NothingLandsOnceClosingReturns) {
  AsyncHandoff handoff;
  std::atomic<bool> closed{false};
  std::atomic<bool> landed_after_close{false};
  std::vector<std::thread> workers;
  for (uint64_t worker = 0; worker < 8; ++worker) {
    workers.emplace_back([&, worker] {
      for (uint64_t i = 0; i < 2000; ++i) {
        const bool was_closed = closed.load();
        if (handoff.Deliver(worker * 10000 + i, EncodableValue(1)) &&
            was_closed) {
          landed_after_close = true;
        }
      }
    });
  }
  std::this_thread::yield();
  handoff.Close();
  closed = true;
  for (auto& worker : workers) worker.join();

  EXPECT_FALSE(landed_after_close);
  EXPECT_TRUE(handoff.TakeDone().empty());
  EXPECT_FALSE(handoff.Deliver(0, EncodableValue(1)));
}

}  // namespace
}  // namespace glitch_vpn_core
