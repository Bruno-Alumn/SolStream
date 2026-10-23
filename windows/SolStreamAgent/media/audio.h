// audio.h — WASAPI loopback capture, sent as 16-bit PCM or as Opus.
//
// PCM is what every Mac before Opus expects, and what a Mac that names no
// codec gets: 48 kHz stereo S16, 1.5 Mbit/s, in 5 ms packets -- 960 bytes, one
// datagram, never fragmented, and small enough that losing one is inaudible
// rather than a gap.
//
// OPUS WHEN THE MAC ASKS FOR IT BY NAME, which is the only codec that is worth
// its bytes here. libopus is compiled in from third_party/opus -- the one
// third-party component, BSD-licensed -- because Windows ships no Opus encoder
// and the AAC one it does ship is the wrong tool: 96 to 192 kbit/s only, and
// 1024-sample frames with lookahead behind them, which is some 50 ms against
// Opus's 2.5 ms plus one packet. Restricted low delay keeps Opus to CELT, so
// what that costs is fixed: 10 ms packets play 7.5 ms later than PCM's 5 ms
// ones. The Mac decodes it with AudioToolbox and needs nothing.
//
// FROM THE WHOLE PC, or from the streamed apps alone when the Mac asks: the
// sound of the processes whose windows it is streaming, through Windows'
// process loopback, so a notification or a song playing elsewhere on the PC
// stays there. A Mac that predates the choice gets the whole PC, as before.
//
//   off  w  field
//    0   1  type = 0x20
//    1   1  flags
//    2   1  channels
//    3   1  format: 1 = signed 16-bit little-endian, interleaved
//                   2 = one Opus packet (RFC 6716), 48 kHz
//    4   4  sequence, big-endian
//    8   4  timestamp in microseconds since the session started
//   12   4  sample rate
//   16   N  samples, or the Opus packet

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <functional>
#include <vector>

namespace solstream::media {

/// Whether this Windows can capture the streamed apps' sound alone: build
/// 20348 or later. Below that, a request for it gets the whole PC's.
bool AppSoundSupported();

/// What the sound is sent as. The defaults are PCM's, for a Mac that asked
/// for nothing.
struct AudioEncoding {
    enum class Codec { Pcm, Opus };
    Codec codec = Codec::Pcm;
    unsigned bitrate = 128000;   ///< Opus's target, bit/s
    unsigned frameMs = 5;        ///< the sound in one packet
};

class AudioCapture {
public:
    /// Called with one packet: interleaved S16 samples, or one Opus packet,
    /// as `format` says.
    using Sink = std::function<void(const unsigned char* data, size_t length,
                                    uint32_t seq, uint32_t timestampUs,
                                    uint32_t sampleRate, uint16_t channels,
                                    unsigned char format)>;

    /// The processes whose sound is wanted, asked again four times a second
    /// because the streamed windows change during a session. Null means the
    /// whole PC's sound.
    using Processes = std::function<std::vector<unsigned long>()>;

    /// Runs until `keepGoing` returns false or Stop is called. Blocking: this
    /// is the body of the audio thread.
    void Run(const AudioEncoding& encoding, const Processes& processes, Sink sink,
             std::function<bool()> keepGoing);
    void Stop();

    uint64_t Packets() const { return packets_.load(); }
    uint64_t Silent() const { return silent_.load(); }
    /// How many apps' sound is being captured, or -1 for the whole PC's.
    int AppSources() const { return appSources_.load(); }

private:
    std::atomic<bool> stop_{false};
    std::atomic<int> appSources_{-1};
    std::atomic<uint64_t> packets_{0};
    /// Atomic for the same reason as `packets_`, which it sits next to in the
    /// same log line: the audio thread counts silent buffers while the sender
    /// thread reads the count out for its five-second report.
    std::atomic<uint64_t> silent_{0};
};

}  // namespace solstream::media
