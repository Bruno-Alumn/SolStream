// capture.h — Windows.Graphics.Capture, per window or per display.
//
// spike/wgc-capture proved the three things this depends on, on an unpackaged
// binary: a capture item can be made from an HWND, the yellow border can be
// turned off, and frames keep arriving while the window is completely covered.
// That last one is why the virtual display driver becomes unnecessary rather
// than merely better handled.
//
// The one behaviour that shapes this interface: WGC is CHANGE-DRIVEN. It
// delivers 241 frames for 240 paints and nothing at all for a still window. A
// consumer that waits for the next frame therefore waits forever whenever the
// picture is worth streaming but not changing, so `Acquire` distinguishes "a new
// frame" from "the same frame again" and always has something to hand back.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <d3d11.h>
#include <winrt/base.h>

#include <cstdint>
#include <memory>

namespace solstream::media {

/// What was captured, and when.
struct Frame {
    ID3D11Texture2D* texture = nullptr;   ///< BGRA, kept alive by `hold`
    UINT width = 0;
    UINT height = 0;
    uint64_t serial = 0;                  ///< increments once per delivered frame
    long long capturedAt = 0;             ///< QueryPerformanceCounter ticks
    bool isNew = false;                   ///< false means this is the retained frame

    /// The frame's own reference to `texture`, so it outlives every use the
    /// caller makes of it. A borrowed pointer was not enough: the capture
    /// thread replaces the retained texture whenever the source changes size,
    /// and the encoder then read freed memory inside a D3D call.
    winrt::com_ptr<ID3D11Texture2D> hold;
};

class Capture {
public:
    Capture();
    ~Capture();

    Capture(const Capture&) = delete;
    Capture& operator=(const Capture&) = delete;

    /// Is WGC present at all? False on Windows versions that predate it.
    static bool Supported();

    /// Capture one window. The window keeps its own size; the caller scales.
    bool StartWindow(HWND window);
    /// Capture one monitor, for the whole-desktop mode the app picker offers.
    bool StartMonitor(HMONITOR monitor);
    void Stop();

    bool Running() const;

    /// The device the captured textures belong to. The encoder must use this
    /// same device, or every frame needs a cross-device copy nobody wants.
    ID3D11Device* Device() const;

    /// Wait up to `timeoutMs` for a frame newer than `sinceSerial`.
    ///
    /// Returns false only when nothing has ever been captured. On timeout it
    /// returns the RETAINED frame with `isNew == false`: a static window has no
    /// next frame, and a caller that needs to repair damage has to be able to
    /// re-encode the last one. That is fix #1 of the six in docs/transport-smt1.md.
    bool Acquire(Frame& out, uint64_t sinceSerial, int timeoutMs);

    /// Frames delivered since Start, for the log line that says whether the
    /// picture is moving.
    uint64_t Delivered() const;

private:
    struct Impl;
    std::unique_ptr<Impl> impl_;
};

}  // namespace solstream::media
