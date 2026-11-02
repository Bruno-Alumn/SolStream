#include "wake.h"

// winsock2 before windows.h, or the two declare the same structures and
// collide; iphlpapi needs both.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>

#include <cstdio>
#include <cstring>
#include <vector>

#include "util.h"

namespace solstream {

std::string FormatMac(const unsigned char* bytes, size_t length) {
    std::string text;
    char part[4];
    for (size_t i = 0; i < length; ++i) {
        std::snprintf(part, sizeof(part), i == 0 ? "%02X" : ":%02X", bytes[i]);
        text += part;
    }
    return text;
}

std::string BroadcastAddress(const std::array<unsigned char, 4>& address, unsigned prefix) {
    if (prefix < 1 || prefix > 30) {
        return {};
    }
    const unsigned long host = (static_cast<unsigned long>(address[0]) << 24)
                             | (static_cast<unsigned long>(address[1]) << 16)
                             | (static_cast<unsigned long>(address[2]) << 8) | address[3];
    const unsigned long mask = 0xFFFFFFFFul << (32 - prefix) & 0xFFFFFFFFul;
    const unsigned long broadcast = (host & mask) | (~mask & 0xFFFFFFFFul);
    return std::to_string((broadcast >> 24) & 0xFF) + "." + std::to_string((broadcast >> 16) & 0xFF)
         + "." + std::to_string((broadcast >> 8) & 0xFF) + "." + std::to_string(broadcast & 0xFF);
}

std::string WakeInfoJson() {
    ULONG size = 16 * 1024;
    std::vector<unsigned char> buffer;
    ULONG result = ERROR_BUFFER_OVERFLOW;
    // The list can grow between asking its size and reading it; a second try
    // with the size it then asks for is the documented answer.
    for (int attempt = 0; attempt < 3 && result == ERROR_BUFFER_OVERFLOW; ++attempt) {
        buffer.resize(size);
        result = GetAdaptersAddresses(
            AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER
                         | GAA_FLAG_INCLUDE_GATEWAYS,
            nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
    }
    if (result != NO_ERROR) {
        return "{\"type\":\"wakeInfo\",\"ok\":false,\"message\":\"could not list adapters\"}";
    }
    std::string list;
    for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()); adapter;
         adapter = adapter->Next) {
        const bool wired_or_wifi = adapter->IfType == IF_TYPE_ETHERNET_CSMACD
                                || adapter->IfType == IF_TYPE_IEEE80211;
        if (!wired_or_wifi || adapter->OperStatus != IfOperStatusUp
            || adapter->PhysicalAddressLength != 6 || !adapter->FirstGatewayAddress) {
            continue;
        }
        std::string broadcast;
        for (auto* unicast = adapter->FirstUnicastAddress; unicast && broadcast.empty();
             unicast = unicast->Next) {
            const sockaddr* address = unicast->Address.lpSockaddr;
            if (address && address->sa_family == AF_INET) {
                std::array<unsigned char, 4> bytes{};
                std::memcpy(bytes.data(), &reinterpret_cast<const sockaddr_in*>(address)->sin_addr,
                            bytes.size());
                broadcast = BroadcastAddress(bytes, unicast->OnLinkPrefixLength);
            }
        }
        if (!list.empty()) {
            list += ",";
        }
        list += "{\"mac\":\"" + FormatMac(adapter->PhysicalAddress, 6) + "\"";
        if (!broadcast.empty()) {
            list += ",\"broadcast\":\"" + broadcast + "\"";
        }
        list += "}";
    }
    return "{\"type\":\"wakeInfo\",\"ok\":true,\"adapters\":[" + list + "]}";
}

}  // namespace solstream
