// quit_app.cpp — see quit_app.h.

#include "quit_app.h"

#include "media/log.h"
#include "util.h"

namespace solstream {

namespace {

/// The taskbar, the desktop and the windows behind its wallpaper.
bool IsShellWindow(const std::wstring& class_name) {
    const std::wstring folded = FoldCase(class_name);
    return folded == L"shell_traywnd" || folded == L"shell_secondarytraywnd"
        || folded == L"progman" || folded == L"workerw";
}

bool IsExplorer(const std::wstring& image_name) {
    return FoldCase(image_name) == L"explorer.exe";
}

bool IsFrameHost(const std::wstring& image_name) {
    return FoldCase(image_name) == L"applicationframehost.exe";
}

/// The executable's file name for a process, or empty.
std::wstring ImageName(DWORD pid) {
    std::wstring image;
    if (HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
        wchar_t path[MAX_PATH] = {0};
        DWORD length = MAX_PATH;
        if (QueryFullProcessImageNameW(process, 0, path, &length)) {
            const std::wstring full(path, length);
            const size_t slash = full.find_last_of(L"\\/");
            image = slash == std::wstring::npos ? full : full.substr(slash + 1);
        }
        CloseHandle(process);
    }
    return image;
}

/// A Store app's own process: the one owning a child window inside the
/// frame ApplicationFrameHost draws, as SoundOwner finds it. Zero when no
/// child belongs to another process.
DWORD StoreAppInside(HWND frame, DWORD frame_pid) {
    struct Search {
        DWORD frame;
        DWORD app;
    } search{frame_pid, 0};
    EnumChildWindows(frame, [](HWND child, LPARAM param) -> BOOL {
        auto* found = reinterpret_cast<Search*>(param);
        DWORD pid = 0;
        GetWindowThreadProcessId(child, &pid);
        if (pid != 0 && pid != found->frame) {
            found->app = pid;
            return FALSE;
        }
        return TRUE;
    }, reinterpret_cast<LPARAM>(&search));
    return search.app;
}

}  // namespace

std::vector<HWND> WindowsToClose(const std::vector<QuitCandidate>& windows, HWND streamed,
                                 const std::wstring& image_name) {
    std::vector<HWND> close;
    for (const QuitCandidate& candidate : windows) {
        if (IsShellWindow(candidate.class_name)) {
            continue;
        }
        const bool shared = IsExplorer(image_name) || IsFrameHost(image_name);
        if (shared ? candidate.window == streamed
                                   : (candidate.visible && !candidate.owned)) {
            close.push_back(candidate.window);
        }
    }
    return close;
}

std::string ForceQuitRefusal(DWORD pid, DWORD own_pid, DWORD session, DWORD own_session,
                             bool critical, const std::wstring& image_name) {
    if (pid == 0 || pid == own_pid) {
        return "That window belongs to SolStream itself.";
    }
    if (session != own_session) {
        return "That app belongs to another user signed in to this PC.";
    }
    if (critical) {
        return "That is part of Windows, and ending it would stop the PC.";
    }
    if (IsExplorer(image_name)) {
        return "File Explorer is also the PC's taskbar and desktop, so it can't be "
               "force quit. Quit it instead, which closes only this window.";
    }
    if (IsFrameHost(image_name)) {
        return "SolStream couldn't tell which Store app is in that window, so it "
               "wasn't ended. Quit it instead, or end it on the PC.";
    }
    return {};
}

std::string QuitAppJson(HWND streamed, bool force) {
    auto refused = [](const std::string& reason) {
        return "{\"type\":\"quit\",\"ok\":false,\"reason\":\"" + JsonEscape(reason) + "\"}";
    };
    DWORD pid = 0;
    GetWindowThreadProcessId(streamed, &pid);
    if (pid == 0) {
        return refused("The app's window has already closed on the PC.");
    }
    std::wstring image = ImageName(pid);

    if (!force) {
        if (pid == GetCurrentProcessId()) {
            return refused("That window belongs to SolStream itself.");
        }
        struct Walk {
            DWORD pid;
            std::vector<QuitCandidate> windows;
        } walk{pid, {}};
        EnumWindows(
            [](HWND window, LPARAM context) -> BOOL {
                auto* walk = reinterpret_cast<Walk*>(context);
                DWORD owner = 0;
                GetWindowThreadProcessId(window, &owner);
                if (owner != walk->pid) {
                    return TRUE;
                }
                QuitCandidate candidate;
                candidate.window = window;
                wchar_t name[256] = {0};
                GetClassNameW(window, name, 256);
                candidate.class_name = name;
                // A tool window -- a palette, a floating toolbar -- goes with
                // the app's main window rather than being closed on its own.
                candidate.visible = IsWindowVisible(window) != FALSE
                    && (GetWindowLongPtrW(window, GWL_EXSTYLE) & WS_EX_TOOLWINDOW) == 0;
                candidate.owned = GetWindow(window, GW_OWNER) != nullptr;
                walk->windows.push_back(candidate);
                return TRUE;
            },
            reinterpret_cast<LPARAM>(&walk));
        const std::vector<HWND> close = WindowsToClose(walk.windows, streamed, image);
        // SC_CLOSE rather than WM_CLOSE: what the close box sends, so an app
        // that asks to save first still asks.
        int posted = 0;
        DWORD denied = 0;
        for (HWND window : close) {
            if (PostMessageW(window, WM_SYSCOMMAND, SC_CLOSE, 0)) {
                ++posted;
            } else if (GetLastError() == ERROR_ACCESS_DENIED) {
                ++denied;
            }
        }
        if (posted == 0) {
            // A hung app takes the message and never acts on it, so a refusal
            // is never that: Windows keeps the host, which isn't elevated, from
            // reaching an app that is.
            return refused(denied > 0
                ? "The app runs as administrator, so SolStream can't close it. Quit it on the PC."
                : "The app's window has already closed on the PC.");
        }
        return "{\"type\":\"quit\",\"ok\":true,\"windows\":" + std::to_string(posted) + "}";
    }

    // A Store app's frame is ApplicationFrameHost's, which draws every Store
    // app: the process to end is the app inside it. Not found, the frame host
    // stays the one named, and ForceQuitRefusal turns it down.
    if (IsFrameHost(image)) {
        if (const DWORD app = StoreAppInside(streamed, pid)) {
            pid = app;
            image = ImageName(pid);
        }
    }
    DWORD session = 0, own_session = 0;
    ProcessIdToSessionId(pid, &session);
    ProcessIdToSessionId(GetCurrentProcessId(), &own_session);
    HANDLE process = OpenProcess(PROCESS_TERMINATE | PROCESS_QUERY_LIMITED_INFORMATION,
                                 FALSE, pid);
    BOOL critical = FALSE;
    if (process) {
        IsProcessCritical(process, &critical);
    }
    const std::string refusal = ForceQuitRefusal(pid, GetCurrentProcessId(), session,
                                                 own_session, critical != FALSE, image);
    if (!refusal.empty()) {
        if (process) CloseHandle(process);
        return refused(refusal);
    }
    if (!process) {
        // Most often an app running as administrator, which the host -- not
        // elevated -- is not allowed to end.
        return refused("SolStream isn't allowed to end that app, most likely "
                       "because it runs as administrator. End it on the PC.");
    }
    const bool ended = TerminateProcess(process, 1) != FALSE;
    const DWORD code = ended ? 0 : GetLastError();
    CloseHandle(process);
    if (!ended) {
        return refused("Windows refused to end the app (error " + std::to_string(code) + ").");
    }
    media::Log("[quit] force quit pid %lu (%s)", (unsigned long) pid, ToUtf8(image).c_str());
    return "{\"type\":\"quit\",\"ok\":true,\"forced\":true}";
}

}  // namespace solstream
