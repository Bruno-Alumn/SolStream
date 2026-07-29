// send.cpp — step 5: SMT/1's video packetizer, measured without an encoder.
//
// Frames are SYNTHETIC and deterministic: byte i of frame n is
// (n * 31 + i * 17) & 0xFF. The receiver regenerates the same bytes and compares,
// so reassembly is checked against an independent computation rather than
// against a hash this side chose -- a hash both ends compute the same wrong way
// agrees with itself.
//
// No encoder, for the same reason step 3 had no handshake and step 4 had no
// media: one new variable at a time. What is being measured here is
// fragmentation, byte-offset reassembly, frame closure and the packet rate the
// transport sustains -- none of which need a real picture to be wrong.
//
// Sizes are realistic rather than arbitrary. A 1080p60 stream at 20 Mbps is
// about 40 KB a frame with an IDR five to ten times that, which is the shape
// that makes the difference between a frame fitting in a few datagrams and
// needing a couple of hundred.

#include <winsock2.h>
#include <ws2tcpip.h>

#include "../smt-ping/smt.h"

#include <cstdio>
#include <cstdlib>

#pragma comment(lib, "ws2_32.lib")

namespace {

// 1500 MTU - 28 (IPv4 + UDP) - 24 (SMT header + tag) - 16 (video header).
constexpr int kPayload = 1432;
constexpr int kVideoHeader = 16;

enum : unsigned char {
    kTypeVideo = 0x10,
    kFlagFrameStart = 0x01,
    kFlagFrameEnd = 0x04,
    kFlagIdr = 0x08,
};

smt::Bytes FromHex(const char* hex) {
    smt::Bytes out;
    for (size_t i = 0; hex[i] && hex[i + 1]; i += 2) {
        auto nibble = [](char c) -> int {
            if (c >= '0' && c <= '9') { return c - '0'; }
            if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
            return c >= 'A' && c <= 'F' ? c - 'A' + 10 : 0;
        };
        out.push_back((unsigned char) ((nibble(hex[i]) << 4) | nibble(hex[i + 1])));
    }
    return out;
}

/// Deterministic from the frame number alone, so the receiver can regenerate it.
void FillFrame(smt::Bytes& frame, uint32_t frameId, size_t bytes) {
    frame.resize(bytes);
    for (size_t i = 0; i < bytes; ++i) {
        frame[i] = (unsigned char) ((frameId * 31u + (uint32_t) i * 17u) & 0xFF);
    }
}

}  // namespace

int main(int argc, char** argv) {
    const unsigned short port = argc > 1 ? (unsigned short) std::atoi(argv[1]) : 47631;
    const int frameCount = argc > 2 ? std::atoi(argv[2]) : 300;
    const int fps = argc > 3 ? std::atoi(argv[3]) : 60;

    WSADATA wsa{};
    WSAStartup(MAKEWORD(2, 2), &wsa);
    SOCKET sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP);
    int sndbuf = 1 << 21;
    setsockopt(sock, SOL_SOCKET, SO_SNDBUF, (const char*) &sndbuf, sizeof(sndbuf));

    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_addr.s_addr = INADDR_ANY;
    address.sin_port = htons(port);
    if (bind(sock, (sockaddr*) &address, sizeof(address)) == SOCKET_ERROR) {
        std::printf("bind %u failed: %d\n", port, WSAGetLastError());
        return 1;
    }

    smt::Direction inbound, outbound;
    inbound.key = FromHex("4aa5aaf36c0cb3dacd26251c0c0e84b96c6910d1d87bcd803f0df616e7dd3b87");
    inbound.fixed = FromHex("593154045ebd");
    outbound.key = FromHex("8c83fc537b9b19d56753962eacc673097a76510c95b60f41fdb5056a5062aaea");
    outbound.fixed = FromHex("4a20dd1ecfc0");
    const unsigned char sessTag = 0x62;

    // Wait for the receiver to say where it is. The Mac speaks first because it
    // is the one behind whatever NAT there might be, and because a host that
    // starts sending video at an address nobody confirmed is a reflector.
    smt::ReplayWindow window;
    unsigned char buffer[2048];
    sockaddr_in peer{};
    int peerLen = sizeof(peer);
    std::printf("smt-video waiting on UDP %u\n", port);
    std::fflush(stdout);
    for (;;) {
        const int n = recvfrom(sock, (char*) buffer, sizeof(buffer), 0,
                               (sockaddr*) &peer, &peerLen);
        if (n <= 0) { continue; }
        smt::Bytes plaintext;
        uint64_t counter = 0;
        if (smt::Open(inbound, window, buffer, (size_t) n, plaintext, counter)) {
            break;
        }
    }

    char who[64] = {};
    inet_ntop(AF_INET, &peer.sin_addr, who, sizeof(who));
    std::printf("receiver at %s:%u -- sending %d frames at %d fps\n",
                who, ntohs(peer.sin_port), frameCount, fps);
    std::fflush(stdout);

    // 1 ms timer resolution. Windows' default is 15.6 ms, so Sleep(16) between
    // frames is really ~31 ms and a "60 fps" sender actually runs at 24. The
    // first run of this spike reported 719 pkt/s where the arithmetic says 1820,
    // and that gap was the timer, not the network.
    timeBeginPeriod(1);

    LARGE_INTEGER frequency{}, started{};
    QueryPerformanceFrequency(&frequency);
    QueryPerformanceCounter(&started);

    // Spin to an absolute deadline. Sub-millisecond pacing cannot be done with
    // Sleep at any timer resolution, and pacing is the whole point of the change
    // below.
    auto waitUntil = [&frequency](long long deadline) {
        LARGE_INTEGER now{};
        for (;;) {
            QueryPerformanceCounter(&now);
            if (now.QuadPart >= deadline) { return; }
            const long long remainingUs =
                (deadline - now.QuadPart) * 1000000 / frequency.QuadPart;
            if (remainingUs > 2000) { Sleep(1); }
        }
    };
    const long long ticksPerFrame = frequency.QuadPart / (fps > 0 ? fps : 60);

    unsigned long long datagrams = 0, bytes = 0;
    smt::Bytes frame;
    for (int f = 1; f <= frameCount; ++f) {
        // Every 60th frame is an IDR at 6x, which is the ratio that decides
        // whether a keyframe fits inside one frame period on a slow path.
        const bool idr = (f % 60) == 1;
        const size_t size = idr ? 240000 : 40000;
        FillFrame(frame, (uint32_t) f, size);

        LARGE_INTEGER now{};
        QueryPerformanceCounter(&now);
        const uint32_t captureUs =
            (uint32_t) ((now.QuadPart - started.QuadPart) * 1000000 / frequency.QuadPart);

        // PACE WITHIN THE FRAME. Sending a frame's fragments back to back and
        // then sleeping is what loses keyframes: a 240 KB IDR is 168 datagrams,
        // and blasting them takes about 2 ms, which is 950 Mbit/s instantaneous
        // however modest the average is. Measured, not theorised -- with no
        // pacing, frames 1, 61, 121, 181 and 241 arrived incomplete on every run
        // and every P-frame arrived perfectly. Spreading each frame across its
        // own period costs nothing in latency, because the last fragment leaves
        // at the same moment either way.
        LARGE_INTEGER frameStart{};
        QueryPerformanceCounter(&frameStart);
        const size_t fragments = (size + kPayload - 1) / kPayload;
        size_t fragment = 0;

        for (size_t offset = 0; offset < size; offset += kPayload) {
            const size_t chunk = size - offset < kPayload ? size - offset : kPayload;
            smt::Bytes payload;
            payload.reserve(kVideoHeader + chunk);
            payload.push_back(kTypeVideo);
            unsigned char flags = 0;
            if (offset == 0) { flags |= kFlagFrameStart; }
            if (offset + chunk >= size) { flags |= kFlagFrameEnd; }
            if (idr) { flags |= kFlagIdr; }
            payload.push_back(flags);
            payload.push_back(0xF0);            // ltr: unmarked, previous ref
            payload.push_back(0);               // sliceId
            smt::AppendBE(payload, (uint64_t) f, 4);
            smt::AppendBE(payload, (uint64_t) offset, 3);
            payload.push_back(0);               // psGen
            smt::AppendBE(payload, captureUs, 4);
            payload.insert(payload.end(), frame.begin() + offset,
                           frame.begin() + offset + chunk);

            waitUntil(frameStart.QuadPart
                      + (long long) ((double) fragment / (double) fragments
                                     * (double) ticksPerFrame));
            ++fragment;

            const smt::Bytes datagram = smt::Seal(outbound, sessTag, payload);
            sendto(sock, (const char*) datagram.data(), (int) datagram.size(), 0,
                   (sockaddr*) &peer, peerLen);
            ++datagrams;
            bytes += datagram.size();
        }
        waitUntil(frameStart.QuadPart + ticksPerFrame);
    }
    timeEndPeriod(1);

    LARGE_INTEGER ended{};
    QueryPerformanceCounter(&ended);
    const double seconds = (double) (ended.QuadPart - started.QuadPart) / (double) frequency.QuadPart;
    std::printf("sent %llu datagrams, %llu bytes in %.2fs = %.1f Mbit/s, %.0f pkt/s\n",
                datagrams, bytes, seconds, (double) bytes * 8.0 / seconds / 1e6,
                (double) datagrams / seconds);
    return 0;
}
