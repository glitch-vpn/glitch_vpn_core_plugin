#include <winsock2.h>
#include <Windows.h>

#include <gtest/gtest.h>

#include <string>

#include "hotspot_internal.h"

namespace glitch_vpn_core::hotspot::detail {
namespace {

AdapterInfo Adapter(const std::wstring& name, const std::wstring& description,
                    uint32_t type, bool up = true) {
  AdapterInfo info;
  info.name = name;
  info.description = description;
  info.type = type;
  info.up = up;
  return info;
}

constexpr uint32_t kWifi = 71;
constexpr uint32_t kEthernet = 6;

TEST(HotspotIsPhysical, WifiAndEthernetThatAreUpCount) {
  EXPECT_TRUE(IsPhysical(Adapter(L"Wi-Fi", L"Intel(R) Wi-Fi 6 AX201", kWifi)));
  EXPECT_TRUE(IsPhysical(
      Adapter(L"Ethernet", L"Realtek PCIe GbE Family Controller", kEthernet)));
}

TEST(HotspotIsPhysical, AnAdapterThatIsDownDoesNot) {
  EXPECT_FALSE(IsPhysical(Adapter(L"Wi-Fi", L"Intel(R) Wi-Fi 6", kWifi, false)));
}

TEST(HotspotIsPhysical, TheTunnelDoesNotWhateverItsSuffix) {
  EXPECT_FALSE(IsPhysical(Adapter(L"GlitchVPN", L"Glitch VPN Tunnel", kEthernet)));
  EXPECT_FALSE(IsPhysical(Adapter(L"GlitchVPN 2", L"Intel", kEthernet)));
  EXPECT_TRUE(IsTunnel(Adapter(L"GlitchVPN 2", L"", 0)));
  EXPECT_FALSE(IsTunnel(Adapter(L"Wi-Fi", L"", 0)));
}

TEST(HotspotIsPhysical, SoftwareAdaptersDoNot) {
  for (const wchar_t* description :
       {L"Hyper-V Virtual Ethernet Adapter", L"VMware Virtual Ethernet",
        L"Microsoft Wi-Fi Direct Virtual Adapter #2", L"Wintun Userspace Tunnel",
        L"TAP-Windows Adapter V9", L"WireGuard Tunnel",
        L"Acme VPN Adapter"}) {
    EXPECT_FALSE(IsPhysical(Adapter(L"x", description, kEthernet)))
        << "a software adapter counted as physical";
  }
}

TEST(HotspotIsPhysical, OtherTypesDoNot) {
  EXPECT_FALSE(IsPhysical(Adapter(L"Loop", L"Software Loopback", 24)));
  EXPECT_FALSE(IsPhysical(Adapter(L"PPP", L"Dial-up", 23)));
}

TEST(HotspotCredentials, SsidIsOneToThirtyTwoBytes) {
  EXPECT_FALSE(IsValidSsid(""));
  EXPECT_TRUE(IsValidSsid("a"));
  EXPECT_TRUE(IsValidSsid(std::string(32, 'a')));
  EXPECT_FALSE(IsValidSsid(std::string(33, 'a')));
  // 16 two-byte characters are 32 bytes; 17 are 34.
  std::string sixteen;
  for (int i = 0; i < 16; ++i) sixteen += "\xD1\x86";
  EXPECT_TRUE(IsValidSsid(sixteen));
  EXPECT_FALSE(IsValidSsid(sixteen + "\xD1\x86"));
}

TEST(HotspotCredentials, PassphraseIsEightToSixtyThreePrintableAscii) {
  EXPECT_FALSE(IsValidPassphrase("1234567"));
  EXPECT_TRUE(IsValidPassphrase("12345678"));
  EXPECT_TRUE(IsValidPassphrase(std::string(63, 'a')));
  EXPECT_FALSE(IsValidPassphrase(std::string(64, 'a')));
  EXPECT_TRUE(IsValidPassphrase("with spaces ~!"));
  EXPECT_FALSE(IsValidPassphrase("tab\there12"));
  EXPECT_FALSE(IsValidPassphrase("caf\xC3\xA9 password"));
}

TEST(HotspotSavedState, RoundTrips) {
  SavedState state;
  state.ssid = "made-up-net";
  state.passphrase = "made-up-pass";
  state.band = 2;
  state.timeout_was_enabled = true;
  const auto decoded = DecodeSavedState(EncodeSavedState(state));
  ASSERT_TRUE(decoded.has_value());
  EXPECT_EQ(decoded->ssid, state.ssid);
  EXPECT_EQ(decoded->passphrase, state.passphrase);
  EXPECT_EQ(decoded->band, 2);
  EXPECT_TRUE(decoded->timeout_was_enabled);
}

TEST(HotspotSavedState, KeepsBytesThatAreNotText) {
  SavedState state;
  state.ssid = std::string("a\0b", 3);
  state.passphrase = "";
  const auto decoded = DecodeSavedState(EncodeSavedState(state));
  ASSERT_TRUE(decoded.has_value());
  EXPECT_EQ(decoded->ssid, state.ssid);
  EXPECT_FALSE(decoded->timeout_was_enabled);
}

TEST(HotspotSavedState, TruncatedOrOversizedInputIsRejected) {
  SavedState state;
  state.ssid = "net";
  state.passphrase = "made-up-pass";
  const std::string encoded = EncodeSavedState(state);
  for (size_t cut = 0; cut < encoded.size(); ++cut) {
    EXPECT_FALSE(DecodeSavedState(encoded.substr(0, cut)).has_value()) << cut;
  }
  EXPECT_FALSE(DecodeSavedState(encoded + "x").has_value());
  // A length that runs past the end.
  std::string lying = encoded;
  lying[0] = '\x7f';
  EXPECT_FALSE(DecodeSavedState(lying).has_value());
}

}  // namespace
}  // namespace glitch_vpn_core::hotspot::detail
