#include <Windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstdarg>

#include "clipboard_listener.h"
#include "ws_server.h"
#include "udp_input.h"
#include "clipboard_input_protocol.h"
#include "../CaptureHelper/pipe_transport.h"

namespace clip = solstream::clipboard;
namespace ipc  = SolStream::IPC;

// ── Logging ─────────────────────────────────────────────────────────────────

static void Log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
    va_end(args);
}

// ── Global state ────────────────────────────────────────────────────────────

static clip::ClipboardListener g_clipListener;
static clip::ClipboardServer   g_clipServer;
static clip::InputReceiver     g_inputReceiver;
static ipc::PipeClient         g_inputPipe;

// ── Forward declarations ────────────────────────────────────────────────────

static bool ConnectToInputInjector();
static void ForwardInputPacket(const clip::InputPacket& packet);

// ══════════════════════════════════════════════════════════════════════════════
// Windows message pump thread
// ══════════════════════════════════════════════════════════════════════════════

/// Runs the message pump for the hidden clipboard listener window.
/// This must be on the thread that created the window.
static DWORD WINAPI MessagePumpThread(LPVOID) {
    MSG msg{};
    while (GetMessageW(&msg, nullptr, 0, 0)) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }
    return 0;
}

// ══════════════════════════════════════════════════════════════════════════════
// InputInjector pipe connection
// ══════════════════════════════════════════════════════════════════════════════

static bool ConnectToInputInjector() {
    Log("Connecting to InputInjector pipe...");

    try {
        g_inputPipe.Connect(kInputInjectorPipe,
                            nullptr,  // no message callback needed (we send only)
                            std::chrono::milliseconds(10000));
        Log("Connected to InputInjector pipe.");
        return true;
    } catch (ipc::PipeException const& e) {
        Log("Pipe connection failed: %s", e.what());
        return false;
    }
}

static void ForwardInputPacket(const clip::InputPacket& packet) {
    if (!g_inputPipe.IsConnected())
        return;

    auto payload = std::span<const std::byte>(
        reinterpret_cast<const std::byte*>(&packet), sizeof(packet));

    g_inputPipe.Send(static_cast<ipc::MessageType>(0xFF), payload);
    // MessageType 0xFF is used as a raw-input transport marker.
    // InputInjector identifies input packets by the payload size == sizeof(InputPacket).
}

// ══════════════════════════════════════════════════════════════════════════════
// Main
// ══════════════════════════════════════════════════════════════════════════════

int main() try {
    Log("SolStream ClipboardMonitor v0.1 starting...");

    // ── Clipboard Listener ──────────────────────────────────────────────
    Log("Initialising clipboard listener...");
    if (!g_clipListener.Initialize()) {
        Log("Failed to create clipboard listener window.");
        return 1;
    }

    // Wire clipboard changes → WS broadcast.
    g_clipListener.SetCallback(
        [](const clip::ClipboardSnapshot& snapshot) {
            Log("Clipboard changed: %zu formats (seq=%llu)",
                snapshot.formats.size(),
                static_cast<unsigned long long>(snapshot.sequence));
            g_clipServer.BroadcastClipboard(snapshot);
        });

    // Start the message pump thread for the hidden window.
    HANDLE pumpThread = CreateThread(nullptr, 0, MessagePumpThread,
                                     nullptr, 0, nullptr);
    if (!pumpThread) {
        Log("Failed to create message pump thread.");
        return 1;
    }

    // ── WS Server ───────────────────────────────────────────────────────
    Log("Starting clipboard WS server on port %u...",
        static_cast<unsigned>(kClipboardWSPort));
    if (!g_clipServer.Start()) {
        Log("Failed to start clipboard WS server.");
        return 1;
    }

    // Wire received clipboard data (from macOS) → local clipboard.
    g_clipServer.SetReceiveCallback(
        [](const clip::ClipboardSnapshot& snapshot) {
            Log("Received clipboard from remote: %zu formats (seq=%llu)",
                snapshot.formats.size(),
                static_cast<unsigned long long>(snapshot.sequence));
            // Apply to local clipboard.
            if (!OpenClipboard(nullptr))
                return;
            EmptyClipboard();

            for (const auto& fmt : snapshot.formats) {
                if (!fmt.data.empty() && fmt.data.size() <= clip::kMaxBytesPerFormat) {
                    HGLOBAL hGlob = GlobalAlloc(GMEM_MOVEABLE, fmt.data.size());
                    if (hGlob) {
                        void* locked = GlobalLock(hGlob);
                        if (locked) {
                            std::memcpy(locked, fmt.data.data(), fmt.data.size());
                            GlobalUnlock(hGlob);
                            SetClipboardData(fmt.formatId, hGlob);
                        } else {
                            GlobalFree(hGlob);
                        }
                    }
                }
            }

            CloseClipboard();
        });

    // ── Input Pipe (to InputInjector) ──────────────────────────────────
    // Retry connection in a loop (InputInjector may start later).
    for (int attempt = 0; attempt < 30 && !g_inputPipe.IsConnected(); ++attempt) {
        if (ConnectToInputInjector())
            break;
        Sleep(1000);
    }

    if (!g_inputPipe.IsConnected()) {
        Log("Warning: Could not connect to InputInjector. Input forwarding disabled.");
    }

    // ── UDP Input Receiver ──────────────────────────────────────────────
    Log("Starting UDP input receiver on port %u...",
        static_cast<unsigned>(kInputUDPPort));
    g_inputReceiver.SetPacketCallback(
        [](const clip::InputPacket& packet) {
            ForwardInputPacket(packet);
        });
    if (!g_inputReceiver.Start()) {
        Log("Failed to start UDP input receiver.");
        return 1;
    }

    Log("ClipboardMonitor ready. Clipboard WS on %u, UDP input on %u.",
        static_cast<unsigned>(kClipboardWSPort),
        static_cast<unsigned>(kInputUDPPort));

    // ── Main wait ───────────────────────────────────────────────────────
    // The message pump thread handles clipboard. Main thread just waits.
    WaitForSingleObject(pumpThread, INFINITE);

    // ── Shutdown ────────────────────────────────────────────────────────
    Log("Shutting down...");
    g_inputReceiver.Stop();
    g_inputPipe.Disconnect();
    g_clipServer.Stop();
    g_clipListener.Shutdown();
    CloseHandle(pumpThread);

    Log("ClipboardMonitor exited.");
    return 0;

} catch (std::exception const& e) {
    Log("Fatal: %s", e.what());
    return 1;
}
