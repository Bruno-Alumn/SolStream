// audio.h — WASAPI loopback capture, as 16-bit PCM.
//
// NO CODEC, DELIBERATELY. 48 kHz stereo S16 is 1.5 Mbit/s next to video's 20,
// and every codec that would shrink it is either a new dependency (Opus) or
// costs more latency than the bytes are worth (the in-box AAC encoder frames at
// 21 ms and buffers ahead of that). SolStream streams on a LAN to a Mac; the
// bandwidth is there and the milliseconds are not.
//
// Packets are 5 ms, which is 960 bytes of stereo S16 -- one datagram, never
// fragmented, and small enough that losing one is inaudible rather than a gap.
//
//   off  w  field
//    0   1  type = 0x20
//    1   1  flags
//    2   1  channels
//    3   1  format: 1 = signed 16-bit little-endian, interleaved
//    4   4  sequence, big-endian
//    8   4  timestamp in microseconds since the session started
//   12   4  sample rate
//   16   N  samples

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>

namespace solstream::media {

class AudioCapture {
public:
    /// Called with one packet's worth of interleaved S16 samples.
    using Sink = std::function<void(const unsigned char* pcm, size_t length,
                                    uint32_t seq, uint32_t timestampUs,
                                    uint32_t sampleRate, uint16_t channels)>;

    /// Runs until `keepGoing` returns false or Stop is called. Blocking: this
    /// is the body of the audio thread.
    void Run(Sink sink, std::function<bool()> keepGoing);
    void Stop();

    uint64_t Packets() const { return packets_.load(); }
    uint64_t Silent() const { return silent_.load(); }
    bool Started() const { return started_.load(); }

private:
    std::atomic<bool> stop_{false};
    std::atomic<bool> started_{false};
    std::atomic<uint64_t> packets_{0};
    /// Atomic for the same reason as `packets_`, which it sits next to in the
    /// same log line: the audio thread counts silent buffers while the sender
    /// thread reads the count out for its five-second report.
    std::atomic<uint64_t> silent_{0};
};

}  // namespace solstream::media
