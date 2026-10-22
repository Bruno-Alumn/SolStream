#include "tailscale.h"

// winsock2 before windows.h, or windows.h pulls in the old winsock and the two
// collide; iphlpapi needs both.
#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <iphlpapi.h>
#include <shlobj.h>

#include <vector>

namespace solstream {

std::wstring TailscaleAddress() {
    ULONG size = 16 * 1024;
    std::vector<unsigned char> buffer;
    ULONG result = ERROR_BUFFER_OVERFLOW;
    // The list can grow between asking its size and reading it; a second try
    // with the size it then asks for is the documented answer.
    for (int attempt = 0; attempt < 3 && result == ERROR_BUFFER_OVERFLOW; ++attempt) {
        buffer.resize(size);
        result = GetAdaptersAddresses(
            AF_INET, GAA_FLAG_SKIP_ANYCAST | GAA_FLAG_SKIP_MULTICAST | GAA_FLAG_SKIP_DNS_SERVER,
            nullptr, reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()), &size);
    }
    if (result != NO_ERROR) {
        return {};
    }
    for (auto* adapter = reinterpret_cast<IP_ADAPTER_ADDRESSES*>(buffer.data()); adapter;
         adapter = adapter->Next) {
        if (adapter->OperStatus != IfOperStatusUp) {
            continue;
        }
        for (auto* unicast = adapter->FirstUnicastAddress; unicast; unicast = unicast->Next) {
            const auto* in = reinterpret_cast<const sockaddr_in*>(unicast->Address.lpSockaddr);
            if (!in || in->sin_family != AF_INET) {
                continue;
            }
            const unsigned long bits = ntohl(in->sin_addr.s_addr);
            // 100.64.0.0/10, the shared address space Tailscale hands out.
            if ((bits & 0xFFC00000UL) != 0x64400000UL) {
                continue;
            }
            wchar_t text[INET_ADDRSTRLEN] = {0};
            if (InetNtopW(AF_INET, &in->sin_addr, text, INET_ADDRSTRLEN)) {
                return text;
            }
        }
    }
    return {};
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
