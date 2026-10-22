// tailscale.h — whether this PC can be reached away from home.
//
// SolStream finds a PC by broadcast on the local network, which stops at the
// router. Tailscale is what the setup recommends for everywhere else: it puts
// both machines on one private network, its peers are already authenticated
// to each other, and the host already prefers its addresses (main.cpp). These
// two answers are all the window needs to say "it's on, here is the address"
// or "install it on both".

#pragma once

#include <string>

namespace solstream {

/// This PC's Tailscale address (100.64.0.0/10 on an adapter that is up), or
/// empty when Tailscale is not connected.
std::wstring TailscaleAddress();

/// Whether the Tailscale client is installed, connected or not.
bool TailscaleInstalled();

/// Where to get it.
constexpr wchar_t kTailscaleDownloadUrl[] = L"https://tailscale.com/download/windows";

}  // namespace solstream
