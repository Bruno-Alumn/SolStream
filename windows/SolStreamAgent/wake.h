// wake.h — what a Mac needs to wake this PC from sleep.
//
// Wake-on-LAN is a "magic packet" broadcast on the local network, carrying the
// hardware address of the adapter that is to wake the PC. The Mac can only
// send one if it already knows that address, so it asks for it while the PC is
// awake (`wakeInfo`) and keeps it. Only adapters that can carry one: wired and
// Wi-Fi, up, with a gateway -- the network the Mac reaches the PC on at home.
// Tailscale's and other virtual adapters cannot wake anything.

#pragma once

#include <array>
#include <string>

namespace solstream {

/// The reply to `{"cmd":"wakeInfo"}`: {"adapters":[{"mac","broadcast"}]}.
std::string WakeInfoJson();

/// "AA:BB:CC:DD:EE:FF".
std::string FormatMac(const unsigned char* bytes, size_t length);

/// The broadcast address of the network `address` is on, given its prefix
/// length, as text: 192.168.1.20/24 is 192.168.1.255. Empty for a prefix
/// outside 1..30, where there is no broadcast worth sending to.
std::string BroadcastAddress(const std::array<unsigned char, 4>& address, unsigned prefix);

}  // namespace solstream
