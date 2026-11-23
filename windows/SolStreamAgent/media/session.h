// session.h — one SMT/1 media session: socket, threads, and everything on the
// wire between `media open` and `media stop`.
//
// The agent channel (TCP 47630) agrees the keys and chooses the source. From
// there this owns the whole media path: capture, encode, packetize, pace, send,
// and the return direction carrying input and feedback.
//
// There is exactly one session at a time. Two Macs streaming the same window is
// not a feature anybody asked for, and pretending to support it would mean an
// encoder, a capture and a pacer per client for no reason.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include "audio.h"
#include "video_codec.h"

#include <cstdint>
#include <memory>
#include <string>
#include <vector>

namespace solstream::media {

/// The lowest rate SetFrameRateCap goes to. Under it, a still picture's
/// 250 ms refresh would come more often than a moving one's pictures.
constexpr unsigned kMinFrameRateCap = 5;

struct MediaConfig {
    HWND window = nullptr;
    HMONITOR monitor = nullptr;
    /// The display's device name, kept beside its handle and looked up again
    /// each pass; set by the session from `monitor`.
    std::wstring monitorDevice;
    UINT width = 0;          ///< encode size; 0 means "whatever the source is"
    UINT height = 0;
    UINT fps = 60;
    UINT bitrate = 20000000;
    /// What the Mac decodes, most wanted first. H.264 alone -- the default,
    /// and all an older Mac gets -- is what every Mac decodes.
    std::vector<VideoCodec> videoCodecs{VideoCodec::H264};
    unsigned short port = 47999;
    /// The PC's own IPv4 address the Mac reached the agent on, in network
    /// order, or 0 for every address. Bound to so replies leave from the
    /// address the Mac sends to; see Start.
    uint32_t bindAddress = 0;
    bool audio = true;
    /// PCM unless the Mac asked for Opus by name; see audio.h.
    AudioEncoding audioEncoding;
    /// The streamed apps' processes, when the Mac asked to hear only them.
    /// Null -- the default, and all an older Mac gets -- is the whole PC.
    AudioCapture::Processes audioProcesses;
};

class MediaSession {
public:
    static MediaSession& Instance();

    /// `okm` is the 108 bytes both ends derived. Returns false with `error` set.
    bool Start(const unsigned char* okm, const MediaConfig& config, std::string* error);
    void Stop();
    bool Running() const;

    /// Point the capture at something else without renegotiating keys.
    bool Retarget(HWND window, HMONITOR monitor);

    /// At most `fps` pictures a second, or with 0 the rate the session was
    /// opened at again: the Mac shows none of them while every stream window
    /// is hidden or minimised. Raised to kMinFrameRateCap. The encoder is not
    /// reopened, and the picture after the cap is lifted is a keyframe.
    /// False with no session running. A new session starts with no cap.
    bool SetFrameRateCap(unsigned fps);

    /// The codec this session sends, for the `media open` reply. Settled by
    /// the time Start returns: see the fallback in RunCapture.
    VideoCodec Codec() const;

    /// What the agent reports back on the channel, and what the log line says.
    std::string StatsJson() const;

private:
    MediaSession();
    ~MediaSession();
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace solstream::media
