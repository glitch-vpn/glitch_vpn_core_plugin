#include <gtest/gtest.h>

#include <memory>
#include <string>
#include <thread>

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

}  // namespace
}  // namespace glitch_vpn_core
