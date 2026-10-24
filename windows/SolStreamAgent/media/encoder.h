// encoder.h — the hardware H.264 encoder, fed a GPU texture.
//
// spike/mf-encode answered the two questions this depends on. The encoder
// exposes LTR, which the recovery design needs. And fed from SYSTEM MEMORY its
// floor was 5.34 ms against a 3-8 ms budget, with a 3 MB CPU-to-GPU upload
// inside every sample -- which is why this class takes an ID3D11Texture2D and
// never a pointer to bytes. The upload is not optimised here; it does not
// happen.
//
// Two setup steps are load-bearing and both must precede type negotiation:
//
//   MF_TRANSFORM_ASYNC_UNLOCK  -- a hardware MFT starts locked and refuses input
//       types with MF_E_TRANSFORM_ASYNC_LOCKED. SetOutputType succeeds anyway,
//       so it presents as the input type being wrong.
//   MFT_MESSAGE_SET_D3D_MANAGER -- without it the MFT accepts every call in the
//       setup sequence and then never emits an event, which presents as a hang.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <d3d11.h>

#include <cstdint>
#include <functional>
#include <memory>

namespace solstream::media {

/// One coded picture, ready to packetize.
struct CodedPicture {
    const unsigned char* data = nullptr;
    size_t length = 0;
    uint32_t frameId = 0;
    bool isIdr = false;
    long long capturedAt = 0;   ///< QPC ticks, carried from the capture
};

class Encoder {
public:
    Encoder();
    ~Encoder();

    Encoder(const Encoder&) = delete;
    Encoder& operator=(const Encoder&) = delete;

    /// `device` must be the same D3D11 device the capture textures live on.
    bool Open(ID3D11Device* device, UINT width, UINT height, UINT fps, UINT bitrateBps);
    void Close();

    UINT Width() const;
    UINT Height() const;

    /// Called on an MF work-queue thread, with the picture's bytes valid only
    /// for the duration of the call.
    using PictureSink = std::function<void(const CodedPicture&)>;
    void OnPicture(PictureSink sink);

    /// Convert `bgra` to NV12 on the GPU and hand it to the encoder.
    ///
    /// LATEST WINS. If the encoder has not asked for input yet, the frame
    /// replaces whatever was waiting: a streaming host that queues frames is
    /// choosing to show old ones, and the point of the whole path is the
    /// opposite of that.
    bool Submit(ID3D11Texture2D* bgra, UINT srcWidth, UINT srcHeight,
                long long capturedAt, bool forceIdr);

    /// The first id this encoder gives a picture, so that a session's ids run
    /// on from one capture pass to the next. Before `Open`. See feed_ledger.h.
    void StartFrameIdsAt(uint32_t next);
    /// The id the next picture would have carried: where the next encoder of
    /// the session starts. After `Close`.
    uint32_t NextFrameId() const;

    void RequestIdr();
    /// A keyframe has been asked for and not yet produced.
    bool IdrPending() const;

    /// Diagnostics. `extraSamples` counts output samples that arrived for a
    /// picture already emitted -- if it is not zero, one encoder output is not
    /// one picture and the packetizer's assumption is wrong.
    uint64_t Submitted() const;
    uint64_t Pictures() const;
    uint64_t Dropped() const;
    uint64_t ExtraSamples() const;

    /// Public only because the Media Foundation event callback is a separate
    /// COM object and has to reach the state it is servicing. Nothing outside
    /// this file names it.
    struct Impl;

private:
    std::unique_ptr<Impl> impl_;
};

}  // namespace solstream::media
