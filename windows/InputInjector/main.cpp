#include <Windows.h>
#include <wtsapi32.h>
#include <cstdio>
#include <cstdlib>
#include <cstdarg>
#include <cstring>
#include <array>
#include <atomic>
#include <thread>

#include "../ClipboardMonitor/clipboard_input_protocol.h"
#include "input_injector.h"
#include "pipe_client_validator.h"
#include "key_state_tracker.h"

#pragma comment(lib, "wtsapi32.lib")

namespace input = solstream::input;

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

static input::InputInjector       g_injector;
static input::PipeClientValidator g_validator;
static std::atomic<bool>          g_running{true};

// ── WTS session notification window ─────────────────────────────────────────

static const wchar_t kSessionWndClass[] = L"SolStreamInputSessionWindow";
static HWND g_sessionHwnd{};

static LRESULT CALLBACK SessionWndProc(HWND hwnd, UINT msg,
                                        WPARAM wParam, LPARAM lParam)
{
    if (msg == WM_WTSSESSION_CHANGE) {
        DWORD event = LOWORD(wParam);
        switch (event) {
        case WTS_SESSION_LOCK:
        case WTS_SESSION_LOGOFF:
            Log("Session lock/logoff — releasing all keys.");
            g_injector.ReleaseAllKeys();
            break;
        case WTS_SESSION_UNLOCK:
        case WTS_SESSION_LOGON:
            Log("Session unlock/logon — re-enabling input.");
            break;
        }
        return 0;
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

static bool CreateSessionWindow() {
    WNDCLASSEXW wc{};
    wc.cbSize        = sizeof(wc);
    wc.lpfnWndProc   = SessionWndProc;
    wc.hInstance     = GetModuleHandleW(nullptr);
    wc.lpszClassName = kSessionWndClass;
    RegisterClassExW(&wc);

    g_sessionHwnd = CreateWindowExW(0, kSessionWndClass,
                                     L"SolStream Input Session",
                                     WS_OVERLAPPEDWINDOW,
                                     0, 0, 0, 0,
                                     HWND_MESSAGE,  // Message-only
                                     nullptr, GetModuleHandleW(nullptr), nullptr);

    if (!g_sessionHwnd)
        return false;

    WTSRegisterSessionNotification(g_sessionHwnd,
                                    NOTIFY_FOR_THIS_SESSION);
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// Named pipe server
// ══════════════════════════════════════════════════════════════════════════════

static bool RunPipeServer(HANDLE stopEvent) {
    // Create the named pipe with explicit security - restrict to local access only.
    // Build a DACL that allows only the current user (not Everyone).
    SECURITY_ATTRIBUTES sa{};
    SECURITY_DESCRIPTOR sd{};
    PACL pAcl = nullptr;

    // Get current user SID.
    HANDLE hToken = nullptr;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken)) {
        DWORD tokenLen = 0;
        GetTokenInformation(hToken, TokenUser, nullptr, 0, &tokenLen);
        std::vector<uint8_t> tokenBuf(tokenLen);
        if (GetTokenInformation(hToken, TokenUser, tokenBuf.data(), tokenLen, &tokenLen)) {
            auto* tu = reinterpret_cast<TOKEN_USER*>(tokenBuf.data());
            // Build ACL with one ACE for current user (GENERIC_ALL access).
            DWORD aclSize = sizeof(ACL) + sizeof(ACCESS_ALLOWED_ACE) +
                           GetLengthSid(tu->User.Sid) - sizeof(DWORD);
            pAcl = static_cast<PACL>(HeapAlloc(GetProcessHeap(), HEAP_ZERO_MEMORY, aclSize));
            if (pAcl && InitializeAcl(pAcl, aclSize, ACL_REVISION) &&
                AddAccessAllowedAce(pAcl, ACL_REVISION, GENERIC_ALL, tu->User.Sid)) {
                if (InitializeSecurityDescriptor(&sd, SECURITY_DESCRIPTOR_REVISION) &&
                    SetSecurityDescriptorDacl(&sd, TRUE, pAcl, FALSE)) {
                    sa.nLength = sizeof(SECURITY_ATTRIBUTES);
                    sa.lpSecurityDescriptor = &sd;
                    sa.bInheritHandle = FALSE;
                }
            }
        }
        CloseHandle(hToken);
    }

    if (sa.lpSecurityDescriptor == nullptr) {
        // Fallback: use default security (less secure, log warning).
        Log("Warning: Failed to create user-restricted DACL, using default security.");
    }

    // Create the named pipe with PIPE_REJECT_REMOTE_CLIENTS and explicit security.
    HANDLE hPipe = CreateNamedPipeW(
        kInputInjectorPipe,
        PIPE_ACCESS_DUPLEX | FILE_FLAG_OVERLAPPED,
        PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT | PIPE_REJECT_REMOTE_CLIENTS,
        1,                          // Max instances
        kInputPipeBufferSize,       // Out buffer
        kInputPipeBufferSize,       // In buffer
        0,                          // Default timeout
        &sa);                      // Security attributes with explicit DACL

    if (!hPipe || hPipe == INVALID_HANDLE_VALUE) {
        Log("CreateNamedPipeW failed: %lu", GetLastError());
        return false;
    }

    Log("Pipe created. Waiting for ClipboardMonitor connection...");

    while (g_running.load(std::memory_order_acquire)) {
        // Wait for connection (overlapped so stopEvent works).
        OVERLAPPED ov{};
        ov.hEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
        if (!ov.hEvent) break;

        BOOL connected = ConnectNamedPipe(hPipe, &ov);
        DWORD err = connected ? ERROR_SUCCESS : GetLastError();

        if (err == ERROR_IO_PENDING) {
            HANDLE waitHandles[2] = {ov.hEvent, stopEvent};
            DWORD waitResult = WaitForMultipleObjects(2, waitHandles,
                                                       FALSE, INFINITE);
            if (waitResult == WAIT_OBJECT_0 + 1) {
                // Stop requested.
                CancelIoEx(hPipe, &ov);
                DWORD unused = 0;
                GetOverlappedResult(hPipe, &ov, &unused, FALSE);
                CloseHandle(ov.hEvent);
                break;
            }
            DWORD unused = 0;
            if (!GetOverlappedResult(hPipe, &ov, &unused, FALSE)) {
                CloseHandle(ov.hEvent);
                continue;
            }
        } else if (err == ERROR_PIPE_CONNECTED) {
            // Already connected.
        } else {
            CloseHandle(ov.hEvent);
            continue;
        }
        CloseHandle(ov.hEvent);

        Log("Client connected. Validating...");

        // Validate the client.
        if (!g_validator.Validate(hPipe)) {
            Log("Client validation failed — disconnecting.");
            DisconnectNamedPipe(hPipe);
            continue;
        }

        Log("Client validated (PID=%lu). Entering input receive loop.",
            static_cast<unsigned long>(g_validator.GetClientPID()));

        // Read loop.
        while (g_running.load(std::memory_order_acquire)) {
            std::array<uint8_t, kInputPipeMaxMsgSize> buf{};
            DWORD bytesRead = 0;

            BOOL ok = ReadFile(hPipe, buf.data(),
                                static_cast<DWORD>(buf.size()),
                                &bytesRead, nullptr);

            if (!ok) {
                DWORD err2 = GetLastError();
                if (err2 == ERROR_BROKEN_PIPE || err2 == ERROR_PIPE_NOT_CONNECTED)
                    break;
                continue;
            }

            // Check if this is an InputPacket (payload size matches).
            if (bytesRead == sizeof(solstream::clipboard::InputPacket)) {
                solstream::clipboard::InputPacket packet{};
                std::memcpy(&packet, buf.data(), sizeof(packet));
                g_injector.ProcessPacket(packet);
            }
            // Other message types are silently ignored.
        }

        Log("Client disconnected. Releasing keys.");
        g_injector.ReleaseAllKeys();
        g_validator.ReleaseProcess();
        DisconnectNamedPipe(hPipe);
    }

    CloseHandle(hPipe);
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// Main
// ══════════════════════════════════════════════════════════════════════════════

int main() try {
    Log("SolStream InputInjector v0.1 starting...");

    // This process runs as High Integrity Admin in the interactive session.
    // Verify that we have the necessary privileges.
    HANDLE hToken = nullptr;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken)) {
        DWORD elevation = 0;
        DWORD size = 0;
        if (GetTokenInformation(hToken, TokenElevation,
                                &elevation, sizeof(elevation), &size)) {
            Log("Running at %s integrity.",
                elevation ? "HIGH (Admin)" : "MEDIUM (user)");
        }
        CloseHandle(hToken);
    }

    // Create session notification window.
    if (!CreateSessionWindow()) {
        Log("Failed to create session notification window.");
        return 1;
    }

    // Create stop event for pipe cancellation.
    HANDLE stopEvent = CreateEventW(nullptr, TRUE, FALSE, nullptr);
    if (!stopEvent) {
        Log("Failed to create stop event.");
        return 1;
    }

    // Run the pipe server.
    RunPipeServer(stopEvent);

    // Cleanup.
    if (g_sessionHwnd) {
        WTSUnRegisterSessionNotification(g_sessionHwnd);
        DestroyWindow(g_sessionHwnd);
    }
    CloseHandle(stopEvent);
    g_injector.ReleaseAllKeys();
    g_validator.ReleaseProcess();

    Log("InputInjector exited.");
    return 0;

} catch (std::exception const& e) {
    Log("Fatal: %s", e.what());
    return 1;
}
