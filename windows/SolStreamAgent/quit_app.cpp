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

std::wstring FileName(const std::wstring& path) {
    const size_t slash = path.find_last_of(L"\\/");
    return slash == std::wstring::npos ? path : path.substr(slash + 1);
}

}  // namespace

std::vector<HWND> WindowsToClose(const std::vector<QuitCandidate>& windows, HWND streamed,
                                 const std::wstring& image_name) {
    std::vector<HWND> close;
    for (const QuitCandidate& candidate : windows) {
        if (IsShellWindow(candidate.class_name)) {
            continue;
        }
        if (IsExplorer(image_name) ? candidate.window == streamed
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
    return {};
}

std::string QuitAppJson(HWND streamed, bool force) {
    DWORD pid = 0;
    GetWindowThreadProcessId(streamed, &pid);
    std::wstring image;
    if (HANDLE process = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid)) {
        wchar_t path[MAX_PATH] = {0};
        DWORD length = MAX_PATH;
        if (QueryFullProcessImageNameW(process, 0, path, &length)) {
            image = FileName(std::wstring(path, length));
        }
        CloseHandle(process);
    }
    auto refused = [](const std::string& reason) {
        return "{\"type\":\"quit\",\"ok\":false,\"reason\":\"" + JsonEscape(reason) + "\"}";
    };

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
                candidate.visible = IsWindowVisible(window) != FALSE;
                candidate.owned = GetWindow(window, GW_OWNER) != nullptr;
                walk->windows.push_back(candidate);
                return TRUE;
            },
            reinterpret_cast<LPARAM>(&walk));
        const std::vector<HWND> close = WindowsToClose(walk.windows, streamed, image);
        // SC_CLOSE rather than WM_CLOSE: what the close box sends, so an app
        // that asks to save first still asks.
        int posted = 0;
        for (HWND window : close) {
            if (PostMessageW(window, WM_SYSCOMMAND, SC_CLOSE, 0)) {
                ++posted;
            }
        }
        if (posted == 0) {
            return refused("The app didn't take the request to close. It may be "
                           "busy; try Force Quit.");
        }
        return "{\"type\":\"quit\",\"ok\":true,\"windows\":" + std::to_string(posted) + "}";
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
