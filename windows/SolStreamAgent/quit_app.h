// quit_app.h — quitting a streamed application from the Mac.
//
// Closing a Mac window only stops streaming it: the application keeps running
// on the PC. Quit asks it to close, as clicking its close box would, and Force
// Quit ends a hung one. These are the decisions about which windows and which
// process, kept apart from the Win32 calls so they can be tested.

#pragma once

#include <windows.h>

#include <string>
#include <vector>

namespace solstream {

/// One top-level window of the application being quit.
struct QuitCandidate {
    HWND window = nullptr;
    std::wstring class_name;
    bool visible = false;
    bool owned = false;  ///< has an owner: a dialog or palette, closed with it
};

/// The windows Quit closes: every visible top-level window of the process
/// that nothing owns, so an application with several windows quits rather
/// than losing one. Only `streamed` when the process is shared: Explorer's is
/// also the taskbar and the desktop -- closing those would end the shell or
/// bring up "Shut down Windows" -- and ApplicationFrameHost draws the frame of
/// every Store app at once. The shell's own windows are never closed, whatever
/// process they turn up in.
std::vector<HWND> WindowsToClose(const std::vector<QuitCandidate>& windows, HWND streamed,
                                 const std::wstring& image_name);

/// Why a process may not be force-quit, or empty when it may. Refused: this
/// host itself, a process in another session, Windows' critical processes,
/// Explorer, which is the shell, and ApplicationFrameHost, which is every
/// Store app's frame -- reached only when the app inside it could not be
/// found.
std::string ForceQuitRefusal(DWORD pid, DWORD own_pid, DWORD session, DWORD own_session,
                             bool critical, const std::wstring& image_name);

/// Do it: post a close to WindowsToClose, or with `force` terminate the
/// process after ForceQuitRefusal. The reply to the Mac's `quit` command.
std::string QuitAppJson(HWND streamed, bool force);

}  // namespace solstream
