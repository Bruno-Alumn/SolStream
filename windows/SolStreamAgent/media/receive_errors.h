// receive_errors.h — what the media socket's receive loop does when recvfrom
// fails.
//
// The loop used to sleep 5 ms after every failure other than its own timeout,
// so that an error that persists cannot spin it, and wrote a line to the log
// for the first failure after each datagram that arrived. Two failures are
// about one datagram, though, not the socket. WSAEMSGSIZE is a datagram larger
// than the buffer, which anyone who can reach the port can send: a couple of
// hundred a second, interleaved with the Mac's own, kept the thread asleep --
// input, feedback and pings late, then lost once the receive buffer filled --
// and rolled the log over within seconds. WSAECONNRESET is Windows passing on
// an ICMP port-unreachable for something this socket sent earlier, which the
// socket now asks not to be told (SIO_UDP_CONNRESET), and which in any case
// says nothing about what arrives next. Both are now passed over at once. A
// failure that is about the socket still slows the loop, and is said at most
// every ten seconds, with how many went unsaid.
//
// Header-only and with no sockets in it, so the test program can check it.

#pragma once

#include <cstdint>

namespace solstream::media {

/// Winsock's numbers, which session.cpp checks against its headers.
constexpr int kWsaMessageTooBig = 10040;   // WSAEMSGSIZE
constexpr int kWsaConnectionReset = 10054; // WSAECONNRESET
constexpr int kWsaTimedOut = 10060;        // WSAETIMEDOUT

enum class ReceiveFailure {
    /// Nothing wrong: the receive timeout, or an empty datagram. Go round.
    None,
    /// One datagram too big to read. Count it as rejected and go round.
    Oversized,
    /// One ICMP report about something sent earlier. Go round.
    Reset,
    /// About the socket, and may well happen again at once. Slow down.
    Persistent,
};

/// What `error`, from WSAGetLastError after recvfrom failed, or 0 when it
/// returned nothing, calls for.
constexpr ReceiveFailure ClassifyReceiveFailure(int error) {
    return error == 0 || error == kWsaTimedOut ? ReceiveFailure::None
         : error == kWsaMessageTooBig          ? ReceiveFailure::Oversized
         : error == kWsaConnectionReset        ? ReceiveFailure::Reset
                                               : ReceiveFailure::Persistent;
}

/// When a failure that keeps happening earns a line in the log: the first
/// time, then at most once every `kQuietMs`. Not thread-safe; the receive
/// thread is its only user.
class ComplaintLimiter {
public:
    static constexpr uint64_t kQuietMs = 10000;

    /// Whether to say this one, at `nowMs` on a clock that does not go
    /// backwards. When it is, `unsaid` is how many were not since the last.
    bool Allow(uint64_t nowMs, uint64_t& unsaid) {
        if (said_ && nowMs - lastMs_ < kQuietMs) {
            ++unsaid_;
            return false;
        }
        said_ = true;
        lastMs_ = nowMs;
        unsaid = unsaid_;
        unsaid_ = 0;
        return true;
    }

private:
    bool said_ = false;
    uint64_t lastMs_ = 0;
    uint64_t unsaid_ = 0;
};

}  // namespace solstream::media
