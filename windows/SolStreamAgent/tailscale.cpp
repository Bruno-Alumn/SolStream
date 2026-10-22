#include "tailscale.h"

// winsock2 before windows.h, or windows.h pulls in the old winsock and the two
// collide; iphlpapi needs both.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <shlobj.h>

#include <cstring>
#include <vector>

#include "util.h"

namespace solstream {

bool IsTailscaleIpv6(const unsigned char* address) {
    // fd7a:115c:a1e0::/48.
    static const unsigned char prefix[6] = {0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0};
    for (int i = 0; i < 6; ++i) {
        if (address[i] != prefix[i]) {
            return false;
        }
    }
    return true;
}

bool IsTailscaleAdapter(const std::wstring& friendly_name, const std::wstring& description,
                        bool has_tailscale_ipv6) {
    return has_tailscale_ipv6
        || FoldCase(friendly_name).find(L"tailscale") != std::wstring::npos
        || FoldCase(description).find(L"tailscale") != std::wstring::npos;
}

std::wstring PickTailscaleAddress(const std::vector<NetworkAdapter>& adapters) {
    for (const NetworkAdapter& adapter : adapters) {
        if (!adapter.up) {
            continue;
        }
        // Only this adapter's own addresses say whether it is Tailscale's: an
        // address of Tailscale's on one adapter vouches for nothing on another.
        bool tailscale_ipv6 = false;
        for (const auto& address : adapter.ipv6) {
            tailscale_ipv6 = tailscale_ipv6 || IsTailscaleIpv6(address.data());
        }
        // 100.64.0.0/10 is not Tailscale's alone: Cloudflare WARP, NetBird and
        // carrier-grade NAT hand out addresses in it too, and calling one of
        // those Tailscale told somebody they could reach this PC from away
        // when they could not. So the adapter has to be Tailscale's as well.
        if (!IsTailscaleAdapter(adapter.friendly_name, adapter.description, tailscale_ipv6)) {
            continue;
        }
        for (const auto& address : adapter.ipv4) {
            // 100.64.0.0/10, the shared address space Tailscale hands out.
            if (address[0] == 100 && (address[1] & 0xC0) == 0x40) {
                return std::to_wstring(address[0]) + L"." + std::to_wstring(address[1]) + L"."
                     + std::to_wstring(address[2]) + L"." + std::to_wstring(address[3]);
            }
        }
    }
    return {};
}

std::wstring TailscaleAddress() {
    ULONG size = 16 * 1024;
    std::vector<unsigned char> buffer;
    ULONG result = ERROR_BUFFER_OVERFLOW;
    // The list can grow between asking its size and reading it; a second try
    // with the size it then asks for is the documented answer. Both families:
    // the IPv6 addresses are part of telling Tailscale's adapter apart.
    for (int attempt = 0; attempt < 3 && result == ERROR_BUFFER_OVERFLOW; ++attempt) {
        buffer.resize(size);
        result = GetAdaptersAddresses(
            AF_UNSPEC, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
            nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
    }
    if (result != NO_ERROR) {
        return {};
    }
    std::vector<NetworkAdapter> adapters;
    for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()); adapter;
         adapter = adapter->Next) {
        NetworkAdapter facts;
        facts.friendly_name = adapter->FriendlyName ? adapter->FriendlyName : L"";
        facts.description = adapter->Description ? adapter->Description : L"";
        facts.up = adapter->OperStatus == IfOperStatusUp;
        for (auto* unicast = adapter->FirstUnicastAddress; unicast; unicast = unicast->Next) {
            const sockaddr* address = unicast->Address.lpSockaddr;
            if (!address) {
                continue;
            }
            if (address->sa_family == AF_INET) {
                const auto* in = reinterpret_cast<const sockaddr_in*>(address);
                std::array<unsigned char, 4> bytes{};
                std::memcpy(bytes.data(), &in->sin_addr, bytes.size());
                facts.ipv4.push_back(bytes);
            } else if (address->sa_family == AF_INET6) {
                const auto* in6 = reinterpret_cast<const sockaddr_in6*>(address);
                std::array<unsigned char, 16> bytes{};
                std::memcpy(bytes.data(), in6->sin6_addr.s6_addr, bytes.size());
                facts.ipv6.push_back(bytes);
            }
        }
        adapters.push_back(std::move(facts));
    }
    return PickTailscaleAddress(adapters);
}

bool TailscaleInstalled() {
    if (!TailscaleAddress().empty()) {
        return true;
    }
    wchar_t program_files[MAX_PATH] = {0};
    if (FAILED(SHGetFolderPathW(nullptr, CSIDL_PROGRAM_FILES, nullptr, SHGFP_TYPE_CURRENT,
                                program_files))) {
        return false;
    }
    const std::wstring client = std::wstring(program_files) + L"\\Tailscale\\tailscale-ipn.exe";
    return GetFileAttributesW(client.c_str()) != INVALID_FILE_ATTRIBUTES;
}

}  // namespace solstream
