// follow.h — which new windows go with the application being streamed.
//
// A streamed application opens more than one window: a dialog of its own, a
// second document, a sign-in page that comes up in the browser that is already
// running. The Mac shows one window per stream, so each of those used to open
// somewhere it could not be seen -- on the PC's own monitor, or behind the
// streamed window on the capture display -- and the application sat waiting on
// a question nobody could answer. The host now tells the Mac about them
// (`windowOpened`, see main.cpp's FollowNewWindows), and the Mac decides
// whether to open a window of its own for one.
//
// A window shown or uncloaked while something is streamed FOLLOWS a held
// window -- is said to the Mac as part of it -- when either:
//
//   - its owner chain reaches a held window: Windows' own word that a dialog
//     belongs to an application; or
//   - it takes the foreground within kFollowAfterMacInputMs of a press the Mac
//     sent into a held window: how a page opening in another process's
//     browser is caught, since nothing in Windows ties it to the click.
//
// Never on a process id alone: a browser being streamed is the same process as
// every other browser window the person at the PC has open. Never after input
// at the PC itself, newer than the Mac's: that window is theirs, and it must
// stay on their monitor. Never the host itself or Earshot, which the person
// relies on staying where it is; and, unless they are owned, never the shell
// or a tooltip -- the Windows key the Mac sends opens Start.
//
// Header-only and with nothing to call, so the test program can check it.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>

#include <atomic>
#include <cstdint>
#include <cwctype>
#include <string>

namespace solstream {

/// How long after a press the Mac sent a window taking the foreground still
/// counts as opened by it. A browser asked to open a page by another process
/// can take a second or two to show it.
constexpr uint64_t kFollowAfterMacInputMs = 2500;

/// How far past the Mac's latest input the PC's last-input time may be and
/// still be the Mac's own: the two are read from different clocks' ticks.
constexpr uint64_t kLocalInputSlackMs = 150;

/// When the Mac's input last went into the PC, in GetTickCount64 time: any
/// event at all, and the latest press -- a button or key going down, or text.
/// Written by the media session's receive thread (media/input.cpp) and read by
/// the window watcher. 0 for never.
inline std::atomic<uint64_t> g_mac_input_at{0};
inline std::atomic<uint64_t> g_mac_press_at{0};
/// The window in front when that press went in -- the one a key goes to, and
/// the one a click lands on once the Mac has focused it.
inline std::atomic<uintptr_t> g_mac_press_foreground{0};

/// Note that the Mac's input went in, and whether it was a press. Cheap: the
/// receive thread calls it for every event.
inline void NoteMacInput(bool press) {
    const uint64_t now = GetTickCount64();
    g_mac_input_at.store(now);
    if (press) {
        g_mac_press_foreground.store(reinterpret_cast<uintptr_t>(GetForegroundWindow()));
        g_mac_press_at.store(now);
    }
}

/// When input at the PC itself last arrived, given its last-input time and the
/// Mac's: the last-input time when it is clearly later than anything the Mac
/// sent, and otherwise 0, for "nothing seen that was not the Mac's".
inline uint64_t LocalInputAt(uint64_t last_input, uint64_t mac_input_at) {
    if (last_input == 0) {
        return 0;
    }
    if (mac_input_at != 0 && last_input <= mac_input_at + kLocalInputSlackMs) {
        return 0;
    }
    return last_input;
}

/// Whether `path` -- a full image path or a file name -- contains `needle`,
/// in lower case, ignoring case.
inline bool ImageContains(const std::wstring& path, const wchar_t* needle) {
    std::wstring lower;
    lower.reserve(path.size());
    for (const wchar_t c : path) {
        lower.push_back(static_cast<wchar_t>(std::towlower(c)));
    }
    return lower.find(needle) != std::wstring::npos;
}

/// Earshot's windows are never followed, whatever opened them.
inline bool IsEarshotImage(const std::wstring& path) {
    return ImageContains(path, L"earshot");
}

/// The file-name part of an image path, lower case.
inline std::wstring ImageFileName(const std::wstring& path) {
    const size_t slash = path.find_last_of(L"\\/");
    std::wstring name = slash == std::wstring::npos ? path : path.substr(slash + 1);
    for (wchar_t& c : name) {
        c = static_cast<wchar_t>(std::towlower(c));
    }
    return name;
}

/// The Windows shell's own surfaces, which a key the Mac sends brings up --
/// the Windows key opens Start, Alt+Tab the switcher -- and which belong to
/// nobody's application. By the process that draws them.
inline bool IsShellImage(const std::wstring& path) {
    const std::wstring name = ImageFileName(path);
    return name == L"startmenuexperiencehost.exe" || name == L"searchhost.exe"
        || name == L"searchapp.exe" || name == L"shellexperiencehost.exe"
        || name == L"shellhost.exe" || name == L"lockapp.exe"
        || name == L"textinputhost.exe";
}

/// The same, by window class: the taskbars and the desktop, the task switcher,
/// the notification area's overflow, menus and tooltips.
inline bool IsShellClass(const std::wstring& cls) {
    return cls == L"Shell_TrayWnd" || cls == L"Shell_SecondaryTrayWnd" || cls == L"Progman"
        || cls == L"WorkerW" || cls == L"MultitaskingViewFrame" || cls == L"TaskSwitcherWnd"
        || cls == L"XamlExplorerHostIslandWindow" || cls == L"ForegroundStaging"
        || cls == L"NotifyIconOverflowWindow" || cls == L"TopLevelWindowForOverflowXamlIsland"
        || cls == L"Shell_InputSwitchTopLevelWindow" || cls == L"Windows.UI.Core.CoreWindow";
}

/// A tooltip, by class: the common controls' own, and the ones WPF and the
/// .NET forms draw.
inline bool IsTooltipClass(const std::wstring& cls) {
    return cls == L"tooltips_class32" || ImageContains(cls, L"tooltip");
}

/// Why a window follows a held one, if it does.
enum class FollowReason {
    None,
    /// Its owner chain reaches a held window.
    Owned,
    /// It took the foreground just after the Mac's press into a held window.
    OpenedByMac,
};

/// Everything the decision needs, gathered by the watcher.
struct FollowFacts {
    /// Its own top-level window, visible and not cloaked.
    bool top_level = false;
    /// It is itself held already: nothing to say.
    bool held = false;
    /// It belongs to the host.
    bool own_process = false;
    /// The taskbar, the desktop, Start, the task switcher (IsShellClass,
    /// IsShellImage).
    bool shell = false;
    /// A tooltip (IsTooltipClass).
    bool tooltip = false;
    /// WS_EX_TOOLWINDOW: a palette or a floating strip.
    bool tool_window = false;
    /// Earshot's (IsEarshotImage).
    bool earshot = false;
    /// Its owner chain reaches a held window.
    bool owner_reaches_held = false;
    /// It holds the foreground now.
    bool foreground = false;
    /// The Mac's latest press went to a held window, or to one of its own.
    bool press_was_on_held = false;
    /// GetTickCount64 now, when the window was first seen shown, when the
    /// Mac's latest press went in (0 for never), and when input at the PC
    /// itself last did as of the window's first sighting (LocalInputAt; 0 for
    /// none).
    uint64_t now = 0;
    uint64_t shown_at = 0;
    uint64_t mac_press_at = 0;
    uint64_t local_input_at = 0;
};

/// Whether a newly shown window follows a held one, and why.
inline FollowReason DecideFollow(const FollowFacts& f) {
    if (!f.top_level || f.held || f.own_process || f.earshot) {
        return FollowReason::None;
    }
    // Input at the PC itself since the Mac's last press, in the moments before
    // this window was shown: the window is the PC user's. Measured from when
    // it was shown, not from now, so the answer does not change as the
    // watcher looks again -- and `local_input_at` is what was known when it
    // was first seen, so input after it was shown takes nothing away.
    if (f.local_input_at != 0 && f.local_input_at >= f.mac_press_at
        && f.local_input_at <= f.shown_at + kLocalInputSlackMs
        && (f.shown_at > f.local_input_at ? f.shown_at - f.local_input_at : 0)
               <= kFollowAfterMacInputMs) {
        return FollowReason::None;
    }
    // Windows' own word that it belongs to the application: a credential
    // prompt or a sign-in from a broker process, a palette, a menu that
    // reaches past its window.
    if (f.owner_reaches_held) {
        return FollowReason::Owned;
    }
    if (f.shell || f.tooltip) {
        return FollowReason::None;
    }
    // A window already showing before the press was not opened by it.
    if (f.foreground && f.press_was_on_held && !f.tool_window && f.mac_press_at != 0
        && f.shown_at + kLocalInputSlackMs >= f.mac_press_at
        && f.now >= f.mac_press_at && f.now - f.mac_press_at <= kFollowAfterMacInputMs) {
        return FollowReason::OpenedByMac;
    }
    return FollowReason::None;
}

/// Whether nothing more can make this window follow: a window that might yet
/// take the foreground is worth another look until its time runs out.
inline bool NeverFollows(const FollowFacts& f) {
    return f.held || f.own_process || f.earshot
        || (!f.owner_reaches_held && (f.shell || f.tooltip));
}

/// Whether `inner` lies wholly inside `outer`: an owned pop-up -- a menu, a
/// tooltip -- that is already in its parent's picture, and so needs no window
/// of its own on the Mac.
inline bool WhollyInside(const RECT& inner, const RECT& outer) {
    return inner.left >= outer.left && inner.top >= outer.top && inner.right <= outer.right
        && inner.bottom <= outer.bottom;
}

}  // namespace solstream
