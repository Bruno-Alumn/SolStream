#include <Windows.h>
#include <cstdio>
#include <cstdlib>
#include <cstdarg>
#include <string>
#include <thread>

#include "cleanup.h"
#include "http_server.h"
#include "path_validator.h"
#include "../ClipboardMonitor/clipboard_input_protocol.h"

namespace ft = solstream::filetransfer;

// ── Logging ─────────────────────────────────────────────────────────────────

static void Log(const char* fmt, ...) {
    va_list args;
    va_start(args, fmt);
    std::vfprintf(stderr, fmt, args);
    std::fputc('\n', stderr);
    std::fflush(stderr);
    va_end(args);
}

// ══════════════════════════════════════════════════════════════════════════════
// Main
// ══════════════════════════════════════════════════════════════════════════════

int main() try {
    Log("SolStream FileTransferService v0.1 starting...");

    // Initialize COM (for OleSetClipboard in IDataObject).
    HRESULT hr = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    if (FAILED(hr)) {
        Log("CoInitializeEx failed: 0x%08X", (unsigned)hr);
        return 1;
    }

    // Ensure the transfer root exists.
    Log("Transfer root: %ls", ft::TransferRoot().c_str());

    // Create the cleanup engine.
    ft::CleanupEngine cleanup;

    // Create the HTTP server.
    ft::FileTransferServer server(cleanup);

    // Set auth token from environment (optional).
    const char* envToken = std::getenv("SOLSTREAM_AUTH_TOKEN");
    if (envToken && envToken[0]) {
        server.SetAuthToken(envToken);
        Log("Auth token configured.");
    } else {
        Log("No auth token set — running in dev mode (no auth).");
    }

    // Wire upload callback: log completed uploads.
    server.SetUploadCallback(
        [](const std::wstring& session, const std::wstring& name,
           const std::wstring& path, uint64_t size)
        {
            Log("Upload complete: session=%ls file=%ls size=%llu path=%ls",
                session.c_str(), name.c_str(),
                (unsigned long long)size, path.c_str());
        });

    // Start server.
    if (!server.Start(47992)) {
        Log("Failed to start HTTP server on port 47992.");
        return 1;
    }

    Log("FileTransferService ready on port 47992.");

    // Periodic orphan sweep (every 5 minutes).
    std::atomic<bool> running{true};
    std::thread sweepThread([&] {
        while (running.load(std::memory_order_acquire)) {
            std::this_thread::sleep_for(
                std::chrono::seconds(ft::CleanupEngine::kSweepIntervalSec));
            cleanup.SweepOrphans();
            Log("Orphan sweep completed.");
        }
    });

    // Wait for shutdown signal (console event or Ctrl+C).
    // For now, just wait indefinitely.
    HANDLE hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (hEvent) {
        WaitForSingleObject(hEvent, INFINITE);
        CloseHandle(hEvent);
    }

    // Shutdown.
    Log("Shutting down...");
    running.store(false, std::memory_order_release);
    server.Stop();
    sweepThread.join();
    CoUninitialize();

    Log("FileTransferService exited.");
    return 0;

} catch (std::exception const& e) {
    Log("Fatal: %s", e.what());
    return 1;
}
