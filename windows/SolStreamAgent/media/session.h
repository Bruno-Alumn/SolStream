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

#include <cstdint>
#include <memory>
#include <string>

namespace solstream::media {

struct MediaConfig {
    HWND window = nullptr;
    HMONITOR monitor = nullptr;
    UINT width = 0;          ///< encode size; 0 means "whatever the source is"
    UINT height = 0;
    UINT fps = 60;
    UINT bitrate = 20000000;
    unsigned short port = 47999;
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

    /// What the agent reports back on the channel, and what the log line says.
    std::string StatsJson() const;

private:
    MediaSession();
    ~MediaSession();
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace solstream::media
