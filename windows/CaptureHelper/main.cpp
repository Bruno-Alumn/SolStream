#include "device_management.h"
#include "texture_ring.h"
#include "capture.h"
#include "pipe_transport.h"

#include <algorithm>
#include <array>
#include <atomic>
#include <chrono>
#include <cstdarg>
#include <cstddef>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cwchar>
#include <deque>
#include <mutex>
#include <optional>
#include <span>
#include <string>
#include <thread>

namespace ipc = SolStream::IPC;
namespace cap = SolStream::Capture;

// ── Logging ─────────────────────────────────────────────────────────────────

static void Log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
    va_end(args);
}

// ── Shared state ────────────────────────────────────────────────────────────

/// Sunshine's PID, received via SunshinePID message.
static std::atomic<DWORD> g_sunshinePid{0};

/// Target HWND for capture.
static std::atomic<HWND> g_targetHwnd{0};

/// The texture ring (cross-process access for handle export).
static cap::TextureRing* g_ringPtr{nullptr};

/// Resize state — set by ResizeNotify handler, cleared after ring recreation.
static std::atomic<bool> g_resizePending{false};
static std::atomic<UINT> g_resizeWidth{0};
static std::atomic<UINT> g_resizeHeight{0};

// ── Command queue (pipe thread → main thread) ───────────────────────────────

enum class Cmd { Start, Stop, Quit };

static std::deque<Cmd> g_cmds;
static std::mutex g_cmdMtx;
static std::atomic<bool> g_running{true};

static void Enqueue(Cmd c) {
    std::lock_guard lk(g_cmdMtx);
    g_cmds.push_back(c);
}

static std::optional<Cmd> Dequeue() {
    std::lock_guard lk(g_cmdMtx);
    if (g_cmds.empty()) return {};
    auto c = g_cmds.front();
    g_cmds.pop_front();
    return c;
}

// ── Send all ring slot handles to Sunshine ──────────────────────────────────

/// Export each ring slot's shared handle duplicated into Sunshine's process
/// and send them over the pipe. Returns false if any step fails.
static bool ExportAndSendRingHandles(
    cap::TextureRing& ring,
    ipc::PipeClient& pipe,
    LUID adapterLuid,
    UINT width, UINT height)
{
    DWORD pid = g_sunshinePid.load(std::memory_order_acquire);
    if (pid == 0)
        return false;

    HANDLE targetProcess = OpenProcess(PROCESS_DUP_HANDLE, FALSE, pid);
    if (!targetProcess) {
        Log("OpenProcess(%lu) failed: %lu",
            static_cast<unsigned long>(pid),
            static_cast<unsigned long>(GetLastError()));
        return false;
    }

    std::size_t count = ring.ExportSharedHandleCount();
    bool allOk = true;

    for (std::size_t i = 0; i < count; ++i) {
        HANDLE remoteHandle = ring.ExportSlotHandle(i, targetProcess);
        if (!remoteHandle) {
            Log("ExportSlotHandle(%zu) failed.", i);
            allOk = false;
            break;
        }

        ipc::SharedHandlePayload shp{};
        shp.slotIndex       = static_cast<std::uint32_t>(i);
        shp.handleValue     = reinterpret_cast<std::uint64_t>(remoteHandle);
        shp.textureWidth    = static_cast<std::int32_t>(width);
        shp.textureHeight   = static_cast<std::int32_t>(height);
        shp.adapterLuidLow  = adapterLuid.LowPart;
        shp.adapterLuidHigh = adapterLuid.HighPart;

        auto payload = std::span<const std::byte>(
            reinterpret_cast<const std::byte*>(&shp), sizeof(shp));

        if (!pipe.Send(ipc::MessageType::SharedHandleInfo, payload)) {
            Log("Send SharedHandleInfo for slot %zu failed.", i);
            CloseHandle(remoteHandle);
            allOk = false;
            break;
        }

        Log("Exported ring slot %zu: handle=%p %lux%lu",
            i, static_cast<void*>(remoteHandle),
            static_cast<unsigned long>(width),
            static_cast<unsigned long>(height));
    }

    CloseHandle(targetProcess);
    return allOk;
}

// ── Pipe message handler (runs on pipe thread) ──────────────────────────────

static void OnPipeMessage(ipc::MessageType type,
                           std::span<const std::byte> payload,
                           std::uint32_t)
{
    switch (type) {
    case ipc::MessageType::StartStream:
        Enqueue(Cmd::Start);
        break;
    case ipc::MessageType::StopStream:
        Enqueue(Cmd::Stop);
        break;
    case ipc::MessageType::Quit:
        Enqueue(Cmd::Quit);
        break;

    case ipc::MessageType::SunshinePID: {
        if (payload.size() >= sizeof(DWORD)) {
            DWORD pid = 0;
            std::memcpy(&pid, payload.data(), sizeof(pid));
            if (pid != 0) {
                g_sunshinePid.store(pid, std::memory_order_release);
                Log("Received Sunshine PID: %lu", static_cast<unsigned long>(pid));
            }
        }
        break;
    }

    case ipc::MessageType::HandleAck: {
        // Sunshine acknowledged our shared handles — reset slot CPU states
        // so the ring's producer can start claiming Free slots.
        if (g_ringPtr)
            g_ringPtr->ResetSlotStates();
        Log("HandleAck received — ring slot states reset.");
        break;
    }

    case ipc::MessageType::ResizeNotify:
        // Encoder drained — capture thread should recreate ring at new size.
        // The new dimensions were stored in g_resizeWidth/Height when
        // FrameSizeChanged was sent.
        Log("ResizeNotify received — ring recreation queued.");
        g_resizePending.store(true, std::memory_order_release);
        break;

    default:
        break;
    }
}

// ── Texture ring guard (RAII for Begin/EndProduce) ─────────────────────────

struct RingGuard {
    cap::TextureRing& ring;
    cap::TextureRing::ProduceResult res;
    explicit RingGuard(cap::TextureRing& r) : ring(r) {
        res = ring.BeginProduce();
    }
    ~RingGuard() {
        if (res.result == cap::RingResult::Success) {
            auto endRes = ring.EndProduce();
            if (endRes == cap::RingResult::DeviceRemoved)
                Log("EndProduce: device removed.");
        }
    }
    [[nodiscard]] ID3D11Texture2D* Texture() const { return res.texture; }
    [[nodiscard]] bool Valid() const { return res.result == cap::RingResult::Success; }
};

// ── Main ────────────────────────────────────────────────────────────────────

int main() try {
    Log("SolStream CaptureHelper v0.2 starting...");

    winrt::init_apartment(winrt::apartment_type::multi_threaded);

    // ── D3D11 device ────────────────────────────────────────────────────
    Log("Creating D3D11 device...");
    cap::DeviceManager deviceMgr;
    deviceMgr.CreateDevice();

    LUID adapterLuid = deviceMgr.GetAdapterLUID();
    Log("Adapter: %08X-%08X",
        static_cast<unsigned>(adapterLuid.HighPart),
        static_cast<unsigned>(adapterLuid.LowPart));

    // ── Texture ring with SHARED_KEYEDMUTEX ─────────────────────────────
    Log("Creating texture ring (1920x1080, shared keyed-mutex)...");
    cap::TextureRing ring;
    g_ringPtr = &ring;  // for OnPipeMessage

    auto createTex = [](std::size_t, ID3D11Device* dev) {
        D3D11_TEXTURE2D_DESC d{};
        d.Width = 1920; d.Height = 1080;
        d.MipLevels = 1; d.ArraySize = 1;
        d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
        d.SampleDesc.Count = 1;
        d.Usage = D3D11_USAGE_DEFAULT;
        d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
        d.MiscFlags = D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
        Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
        winrt::check_hresult(dev->CreateTexture2D(&d, nullptr, &tex));
        return tex;
    };
    ring.Initialize(deviceMgr.GetD3D11Device(), createTex);

    // ── Pipe ────────────────────────────────────────────────────────────
    Log("Connecting to pipe...");
    ipc::PipeClient pipe;
    pipe.Connect(ipc::kPipeName, OnPipeMessage);

    // Pipe read loop on its own thread.
    std::atomic<bool> pipeDone{false};
    std::thread pipeThread([&] {
        winrt::init_apartment(winrt::apartment_type::multi_threaded);
        try {
            pipe.RunReadLoop();
        } catch (std::exception const& e) {
            Log("Pipe thread error: %s", e.what());
        } catch (...) {
            Log("Pipe thread unknown error.");
        }
        pipeDone.store(true, std::memory_order_release);
    });

    // Send adapter info.
    {
        auto desc = deviceMgr.GetAdapterDesc();
        std::array<std::byte, 8 + 128> payload{};
        std::memcpy(payload.data(), &desc.AdapterLuid, sizeof(LUID));
        auto nameLen = wcsnlen(desc.Description, 128) * sizeof(wchar_t);
        std::memcpy(payload.data() + sizeof(LUID), desc.Description,
                    (std::min)(std::size_t{128}, nameLen));
        pipe.Send(ipc::MessageType::AdapterInfo, payload);
    }
    pipe.Send(ipc::MessageType::Heartbeat);

    // Wait for Sunshine PID with period wake-up for g_running check.
    {
        constexpr int kMaxPidWaitMs = 10000;
        constexpr int kPidPollMs = 100;
        int waited = 0;
        while (g_sunshinePid.load(std::memory_order_acquire) == 0 &&
               g_running.load(std::memory_order_acquire) &&
               waited < kMaxPidWaitMs)
        {
            std::this_thread::sleep_for(std::chrono::milliseconds(kPidPollMs));
            waited += kPidPollMs;
        }
        if (g_sunshinePid.load(std::memory_order_acquire) != 0) {
            // Export actual ring handles to Sunshine.
            bool ok = ExportAndSendRingHandles(
                ring, pipe, adapterLuid, 1920, 1080);
            if (!ok)
                Log("Initial handle export failed — capture will not work.");
        } else {
            Log("Timed out waiting for Sunshine PID.");
        }
    }

    // ── Capture state (main-thread only) ────────────────────────────────
    cap::WindowCapture capture;
    bool capturing = false;

    Log("Ready. Awaiting commands...");

    // ── Main loop ───────────────────────────────────────────────────────
    int lastSentWidth = 0, lastSentHeight = 0;

    while (g_running.load(std::memory_order_acquire) && !pipeDone.load()) {
        // Process pending commands.
        while (auto cmd = Dequeue()) {
            switch (*cmd) {
            case Cmd::Start: {
                if (capturing)
                    break;
                HWND targetHwnd = g_targetHwnd.load(std::memory_order_acquire);
                if (!targetHwnd)
                    targetHwnd = GetDesktopWindow();
                try {
                    capture.StartCapture(targetHwnd,
                                          deviceMgr.GetD3D11Device());
                    capturing = true;
                    Log("Capture started (hwnd=%p).",
                        static_cast<void*>(targetHwnd));
                    pipe.Send(ipc::MessageType::StreamStarted);

                    // Export handles at the actual capture size.
                    RECT clientRect{};
                    if (GetClientRect(targetHwnd, &clientRect)) {
                        auto w = static_cast<UINT>(
                            clientRect.right - clientRect.left);
                        auto h = static_cast<UINT>(
                            clientRect.bottom - clientRect.top);
                        if (w > 0 && h > 0)
                            ExportAndSendRingHandles(ring, pipe, adapterLuid, w, h);
                    }
                } catch (std::exception const& e) {
                    Log("StartCapture failed: %s", e.what());
                    capturing = false;
                }
                break;
            }
            case Cmd::Stop:
                if (capturing) {
                    capture.StopCapture();
                    capturing = false;
                    pipe.Send(ipc::MessageType::StreamStopped);
                    Log("Capture stopped.");
                }
                break;
            case Cmd::Quit:
                g_running.store(false, std::memory_order_release);
                break;
            }
        }

        // Check device health.
        if (deviceMgr.CheckDeviceRemoval() != S_OK) {
            Log("Device lost. Exiting.");
            break;
        }

        // Capture → ring → pipe.
        if (capturing) {
            auto frame = capture.TryGetNextFrame();
            if (frame.texture) {
                // Check for size change BEFORE writing into ring.
                D3D11_TEXTURE2D_DESC frameDesc{};
                frame.texture->GetDesc(&frameDesc);
                UINT currentWidth  = frameDesc.Width;
                UINT currentHeight = frameDesc.Height;

                // If dimensions changed, detect it before copying into
                // the fixed-size ring (which would fail CopyResource).
                if (static_cast<int>(currentWidth)  != lastSentWidth ||
                    static_cast<int>(currentHeight) != lastSentHeight) {
                    Log("Frame size changed: %ux%u (notify encoder, skip this frame)",
                        currentWidth, currentHeight);
                    lastSentWidth  = static_cast<int>(currentWidth);
                    lastSentHeight = static_cast<int>(currentHeight);

                    // Store new size for ResizeNotify handler.
                    g_resizeWidth.store(currentWidth, std::memory_order_relaxed);
                    g_resizeHeight.store(currentHeight, std::memory_order_relaxed);

                    std::array<std::byte, 8> sizePayload{};
                    std::memcpy(sizePayload.data(), &currentWidth, sizeof(currentWidth));
                    std::memcpy(sizePayload.data() + sizeof(currentWidth),
                                &currentHeight, sizeof(currentHeight));
                    pipe.Send(ipc::MessageType::FrameSizeChanged, sizePayload);
                    // Skip this frame — ring is still old size.
                    continue;
                }

                ID3D11DeviceContext* ctx = deviceMgr.GetImmediateContext();
                bool delivered = false;
                {
                    RingGuard rg(ring);
                    if (rg.Valid()) {
                        ctx->CopyResource(rg.Texture(), frame.texture.Get());
                        ctx->Flush();
                        delivered = true;
                    }
                } // EndProduce issued here, before FrameReady signal

                if (delivered)
                    pipe.Send(ipc::MessageType::FrameReady);
            }
        }

        // ── Ring recreation (triggered by ResizeNotify) ─────────────────
        if (g_resizePending.exchange(false, std::memory_order_acq_rel)) {
            UINT newW = g_resizeWidth.load(std::memory_order_relaxed);
            UINT newH = g_resizeHeight.load(std::memory_order_relaxed);
            if (newW > 0 && newH > 0 && newW <= 16384 && newH <= 16384) {
                Log("Recreating ring at %ux%u...", newW, newH);

                // Briefly stop capture while recreating.
                bool wasCapturing = capturing;
                if (wasCapturing) {
                    capture.StopCapture();
                    capturing = false;
                }

                ring.Reset();
                auto createResizeTex = [newW, newH](
                    std::size_t, ID3D11Device* dev) {
                    D3D11_TEXTURE2D_DESC d{};
                    d.Width = newW; d.Height = newH;
                    d.MipLevels = 1; d.ArraySize = 1;
                    d.Format = DXGI_FORMAT_B8G8R8A8_UNORM;
                    d.SampleDesc.Count = 1;
                    d.Usage = D3D11_USAGE_DEFAULT;
                    d.BindFlags = D3D11_BIND_RENDER_TARGET | D3D11_BIND_SHADER_RESOURCE;
                    d.MiscFlags = D3D11_RESOURCE_MISC_SHARED_KEYEDMUTEX;
                    Microsoft::WRL::ComPtr<ID3D11Texture2D> tex;
                    winrt::check_hresult(dev->CreateTexture2D(&d, nullptr, &tex));
                    return tex;
                };
                ring.Initialize(deviceMgr.GetD3D11Device(), createResizeTex);

                // Export new handles.
                bool ok = ExportAndSendRingHandles(
                    ring, pipe, adapterLuid, newW, newH);
                if (!ok) {
                    Log("Handle export after resize failed.");
                }

                // Resume capture if it was running.
                if (wasCapturing) {
                    HWND targetHwnd = g_targetHwnd.load(std::memory_order_acquire);
                    if (!targetHwnd)
                        targetHwnd = GetDesktopWindow();
                    try {
                        capture.StartCapture(targetHwnd,
                                              deviceMgr.GetD3D11Device());
                        capturing = true;
                        Log("Capture resumed after resize.");
                    } catch (std::exception const& e) {
                        Log("Capture resume failed after resize: %s", e.what());
                    }
                }
            }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(16));

        // Periodic heartbeat.
        static auto lastHeartbeat = std::chrono::steady_clock::now();
        auto now = std::chrono::steady_clock::now();
        if (now - lastHeartbeat > std::chrono::seconds(5)) {
            pipe.Send(ipc::MessageType::Heartbeat);
            lastHeartbeat = now;
        }
    }

    // ── Shutdown (ordered: capture → pipe → ring) ───────────────────────
    Log("Shutting down...");
    g_running.store(false, std::memory_order_release);
    g_ringPtr = nullptr;

    if (capturing)
        capture.StopCapture();

    pipe.Send(ipc::MessageType::CaptureStopped);
    pipe.Disconnect();
    if (pipeThread.joinable())
        pipeThread.join();

    ring.Reset();

    Log("CaptureHelper exited.");
    return 0;

} catch (winrt::hresult_error const& e) {
    Log("Fatal WinRT: 0x%08X", static_cast<unsigned>(e.code().value));
    return 1;
} catch (std::exception const& e) {
    Log("Fatal: %s", e.what());
    return 1;
}
