// pong.cpp — the Windows half of step 3: bind UDP, open, echo, seal.
//
// No media, no encoder, no handshake. The question this answers is what SMT/1's
// packet layer costs and what the path between the Mac and this PC actually
// looks like, and those are the first real numbers this project will have: every
// latency figure so far has been arithmetic, and the one measurement that did
// exist (spike/wgc-capture) was honest about being inflated by its own
// instrument.
//
//   cmake -S spike/smt-ping -B build/smt-ping && cmake --build build/smt-ping --config Release
//   build\smt-ping\Release\smt-pong.exe [port]

// WINSOCK2 BEFORE ANYTHING THAT PULLS IN windows.h, including smt.h. Left to
// itself windows.h includes winsock 1.1, and ws2tcpip.h then fails on a hundred
// undeclared identifiers that have nothing to do with the real problem
// (IP_MSFILTER, SourceCount, ...). main.cpp carries the same note.
#include <winsock2.h>
#include <ws2tcpip.h>

#include "smt.h"

#include <cstdio>
#include <cstdlib>

#pragma comment(lib, "ws2_32.lib")

namespace {

smt::Bytes FromHex(const char* hex) {
    smt::Bytes out;
    for (size_t i = 0; hex[i] && hex[i + 1]; i += 2) {
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') { return c - '0'; }
            if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
            if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
            return 0;
        };
        out.push_back((unsigned char) ((nibble(hex[i]) << 4) | nibble(hex[i + 1])));
    }
    return out;
}

}  // namespace

int main(int argc, char** argv) {
    const unsigned short port = argc > 1 ? (unsigned short) std::atoi(argv[1]) : 47631;

    WSADATA wsa{};
    if (WSAStartup(MAKEWORD(2, 2), &wsa) != 0) {
        std::printf("WSAStartup failed\n");
        return 1;
    }

    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    if (sock == INVALID_SOCKET) {
        std::printf("socket failed: %d\n", WSAGetLastError());
        return 1;
    }
    // A receive buffer big enough that a burst does not become loss the kernel
    // never tells us about. The default is small enough to matter at video rates
    // and the failure looks exactly like network loss.
    int rcvbuf = 1 << 20;
    setsockopt(sock, SOL_SOCKET, SO_RCVBUF, (const char*) &rcvbuf, sizeof(rcvbuf));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    if (bind(sock, (sockaddr*) &address, sizeof(address)) == SOCKET_ERROR) {
        std::printf("bind %u failed: %d\n", port, WSAGetLastError());
        return 1;
    }

    // The frozen vector's keys. Step 4 replaces this with the real handshake;
    // the packet layer does not care where a key came from, which is the whole
    // reason it can be measured before the handshake exists.
    smt::Direction inbound;   // client -> host
    inbound.key = FromHex("4aa5aaf36c0cb3dacd26251c0c0e84b96c6910d1d87bcd803f0df616e7dd3b87");
    inbound.fixed = FromHex("593154045ebd");
    smt::Direction outbound;  // host -> client
    outbound.key = FromHex("8c83fc537b9b19d56753962eacc673097a76510c95b60f41fdb5056a5062aaea");
    outbound.fixed = FromHex("4a20dd1ecfc0");
    const unsigned char sessTag = 0x62;   // low byte of the vector's session id

    smt::ReplayWindow window;
    std::printf("smt-pong listening on UDP %u\n", port);
    std::fflush(stdout);

    unsigned long long accepted = 0, rejected = 0;
    unsigned char buffer[2048];
    for (;;) {
        sockaddr_in from{};
        int fromLen = sizeof(from);
        const int n = recvfrom(sock, (char*) buffer, sizeof(buffer), 0,
                               (sockaddr*) &from, &fromLen);
        if (n <= 0) {
            continue;
        }

        smt::Bytes plaintext;
        uint64_t counter = 0;
        if (!smt::Open(inbound, window, buffer, (size_t) n, plaintext, counter)) {
            // Silently, and counted. A datagram that does not authenticate is
            // not an error to report to anybody: on an open port most of them
            // are the internet, and answering is how a UDP service becomes a
            // reflector.
            ++rejected;
            continue;
        }
        ++accepted;

        if (plaintext.empty() || plaintext[0] != smt::kTypePing) {
            continue;
        }
        // Echo the client's timestamp back untouched. Only the Mac's clock is
        // ever consulted, so the two machines never have to agree about time.
        smt::Bytes reply;
        reply.push_back(smt::kTypePong);
        reply.insert(reply.end(), plaintext.begin() + 1, plaintext.end());

        const smt::Bytes datagram = smt::Seal(outbound, sessTag, reply);
        if (!datagram.empty()) {
            sendto(sock, (const char*) datagram.data(), (int) datagram.size(), 0,
                   (sockaddr*) &from, fromLen);
        }
        if (accepted % 200 == 0) {
            std::printf("  accepted %llu, rejected %llu\n", accepted, rejected);
            std::fflush(stdout);
        }
    }
}
