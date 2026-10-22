// tailscale.h — whether this PC can be reached away from home.
//
// SolStream finds a PC by broadcast on the local network, which stops at the
// router. Tailscale is what the setup recommends for everywhere else: it puts
// both machines on one private network, its peers are already authenticated
// to each other, and the host already prefers its addresses (main.cpp). These
// two answers are all the window needs to say "it's on, here is the address"
// or "install it on both".

#pragma once

#include <array>
#include <string>
#include <vector>

namespace solstream {

/// This PC's Tailscale address (100.64.0.0/10 on Tailscale's adapter, while it
/// is up), or empty when Tailscale is not connected.
std::wstring TailscaleAddress();

/// One network adapter, as much of it as telling Tailscale's apart takes.
struct NetworkAdapter {
    std::wstring friendly_name;
    std::wstring description;
    bool up = false;
    std::vector<std::array<unsigned char, 4>> ipv4;   ///< in network order
    std::vector<std::array<unsigned char, 16>> ipv6;
};

/// TailscaleAddress's choice, over adapters already read: the first
/// 100.64.0.0/10 address on an adapter that is up and is Tailscale's
/// (IsTailscaleAdapter, asked of that adapter's own addresses), as text; or
/// empty. Exposed for its tests.
std::wstring PickTailscaleAddress(const std::vector<NetworkAdapter>& adapters);

/// Whether an adapter is Tailscale's: named for it -- its tunnel is "Tailscale",
/// described as "Tailscale Tunnel" -- or carrying an address of Tailscale's own
/// IPv6 prefix (IsTailscaleIpv6). A 100.64.0.0/10 address alone does not say
/// so: other VPNs and carrier-grade NAT use that range too. Exposed for its
/// tests.
bool IsTailscaleAdapter(const std::wstring& friendly_name, const std::wstring& description,
                        bool has_tailscale_ipv6);

/// Is this IPv6 address (16 bytes) in fd7a:115c:a1e0::/48, the prefix only
/// Tailscale assigns? Exposed for its tests.
bool IsTailscaleIpv6(const unsigned char* address);

/// Whether the Tailscale client is installed, connected or not.
bool TailscaleInstalled();

/// Where to get it.
constexpr wchar_t kTailscaleDownloadUrl[] = L"https://tailscale.com/download/windows";

}  // namespace solstream
