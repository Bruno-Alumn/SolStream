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
// every other browser window the person at the PC has open. The second rule
// only on a PC nobody has pressed anything at for kPcIdleForMacOpenMs (see
// PcInputRulesOut): a window someone there may have opened is theirs, and it
// must stay on their monitor.
// What is left is a window another program raises on its own, on an idle PC,
// just after the Mac's click; the Mac decides what to do with it. Never the
// host itself or Earshot, which the person
// relies on staying where it is; and, unless they are owned, never the shell
// or a tooltip -- the Windows key the Mac sends opens Start.
//
// Header-only and with nothing to call, so the test program can check it.

#pragma once

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif

#include <windows.h>
#include <xinput.h>

#include <atomic>
#include <cstdint>
#include <cwctype>
#include <string>

namespace solstream {

/// How long after a press the Mac sent a window taking the foreground still
/// counts as opened by it. A browser asked to open a page by another process
/// can take a second or two to show it.
constexpr uint64_t kFollowAfterMacInputMs = 2500;

/// How long the PC's own mouse and keyboard must have been still for a window
/// to count as opened by the Mac: rule (b) is for a PC nobody is using. A
/// program started at the PC can take seconds to show its window, long after
/// the Mac's next click.
constexpr uint64_t kPcIdleForMacOpenMs = 10000;

/// How far before the Mac's press a window may be seen shown and still be
/// opened by it: the press is stamped once SendInput returns, and the
/// application may have answered on another core by then.
constexpr uint64_t kShownBeforePressSlackMs = 100;

/// When the Mac's latest press went in -- a button or key going down, or
/// text -- in GetTickCount64 time, 0 for never. Written by the media session's
/// receive thread (media/input.cpp), read by the window watcher.
inline std::atomic<uint64_t> g_mac_press_at{0};
/// The window in front when that press went in -- the one a key goes to, and
/// the one a click lands on once the Mac has focused it.
inline std::atomic<uintptr_t> g_mac_press_foreground{0};

/// What every event the host sends for the Mac carries in dwExtraInfo, so the
/// PC's own input can be told from it: "SOLS". Raw Input hands it back in
/// RAWMOUSE::ulExtraInformation and RAWKEYBOARD::ExtraInformation, 32 bits
/// wide. The fence's re-sent click is the PC user's own and goes without it.
constexpr ULONG kMacInputSignature = 0x534F4C53;

/// When someone at the PC last pressed something -- a mouse button, the
/// wheel, a key, a game controller -- 0 for not since the host started. Any
/// press not marked as the Mac's counts: a touchpad, a pen, touch, the
/// on-screen keyboard and Steam Input all arrive without a device, so "has a
/// device" would call a PC in use idle. Written by main.cpp's PC-input
/// thread, read by the window watcher.
inline std::atomic<uint64_t> g_pc_input_at{0};
/// When that thread began hearing the PC's input, 0 while it is not: a quiet
/// PC means something only once it has been listened to for a while.
inline std::atomic<uint64_t> g_pc_watching_since{0};

/// Note that the Mac pressed something. Cheap: the receive thread calls it.
inline void NoteMacPress() {
    g_mac_press_foreground.store(reinterpret_cast<uintptr_t>(GetForegroundWindow()));
    g_mac_press_at.store(GetTickCount64());
}

/// Whether a raw mouse event presses something: a button going down, or the
/// wheel. Plain movement cannot open a window, and a 1-8 kHz mouse sends a
/// great deal of it.
inline bool MousePresses(USHORT button_flags) {
    constexpr USHORT kPresses = RI_MOUSE_LEFT_BUTTON_DOWN | RI_MOUSE_RIGHT_BUTTON_DOWN
                              | RI_MOUSE_MIDDLE_BUTTON_DOWN | RI_MOUSE_BUTTON_4_DOWN
                              | RI_MOUSE_BUTTON_5_DOWN | RI_MOUSE_WHEEL | RI_MOUSE_HWHEEL;
    return (button_flags & kPresses) != 0;
}

/// Whether a Raw Input event is a press by someone at the PC: a mouse press
/// or a key going down, not marked as the Mac's.
inline bool IsPcPress(const RAWINPUT& raw) {
    if (raw.header.dwType == RIM_TYPEMOUSE) {
        return raw.data.mouse.ulExtraInformation != kMacInputSignature
            && MousePresses(raw.data.mouse.usButtonFlags);
    }
    if (raw.header.dwType == RIM_TYPEKEYBOARD) {
        return raw.data.keyboard.ExtraInformation != kMacInputSignature
            && (raw.data.keyboard.Flags & RI_KEY_BREAK) == 0;
    }
    return false;
}

/// What the PC-input thread knows of one game controller slot.
struct PadSlot {
    bool known = false;
    DWORD packet = 0;
    WORD buttons = 0;
};

/// Whether a controller lies still: no button down, triggers and sticks inside
/// XInput's own dead zones. A resting stick drifts, and every drift is a new
/// packet.
inline bool PadAtRest(const XINPUT_GAMEPAD& pad) {
    const auto inside = [](SHORT value, SHORT zone) { return value >= -zone && value <= zone; };
    return pad.wButtons == 0 && pad.bLeftTrigger <= XINPUT_GAMEPAD_TRIGGER_THRESHOLD
        && pad.bRightTrigger <= XINPUT_GAMEPAD_TRIGGER_THRESHOLD
        && inside(pad.sThumbLX, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE)
        && inside(pad.sThumbLY, XINPUT_GAMEPAD_LEFT_THUMB_DEADZONE)
        && inside(pad.sThumbRX, XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE)
        && inside(pad.sThumbRY, XINPUT_GAMEPAD_RIGHT_THUMB_DEADZONE);
}

/// Note a controller's state, and say whether someone used it since the last
/// look: its packet number moved, and it is not merely drifting at rest -- a
/// button changed, or something is held or pushed. A controller first seen,
/// or seen again after going away, says nothing until it changes.
inline bool PadUsed(PadSlot& slot, bool connected, const XINPUT_STATE& state) {
    if (!connected) {
        slot = PadSlot{};
        return false;
    }
    const bool used = slot.known && state.dwPacketNumber != slot.packet
                   && (state.Gamepad.wButtons != slot.buttons || !PadAtRest(state.Gamepad));
    slot.known = true;
    slot.packet = state.dwPacketNumber;
    slot.buttons = state.Gamepad.wButtons;
    return used;
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

/// A transient pop-up, by class: a menu (`#32768`), a combo box's drop-down
/// list, a tooltip, or a pop-up a XAML or DirectUI application hosts in a
/// window of its own -- a flyout, a context menu, a tooltip. They come and go
/// with the pointer and live in menu mode, and the Mac must never give one the
/// keyboard: focusing it ends the menu.
inline bool IsPopupClass(const std::wstring& cls) {
    return cls == L"#32768" || cls == L"ComboLBox" || cls == L"DropDown"
        || cls == L"SysDragImage" || cls == L"Xaml_WindowedPopupClass"
        || cls == L"Microsoft.UI.Content.PopupWindowSiteBridge"
        || cls == L"DirectUIHWND_Popup" || cls == L"NetUIToolWindow"
        || cls == L"Net UI Tool Window" || IsTooltipClass(cls);
}

/// Whether a window that follows is a pop-up rather than a window to work
/// in: a pop-up class, or WS_EX_TOOLWINDOW -- a palette, a floating strip, and
/// what many toolkits draw their menus and tooltips in. Said to the Mac as
/// `"popup": true`, so that it never takes the keyboard for one.
inline bool IsPopupWindow(const std::wstring& cls, LONG_PTR ex_style) {
    return (ex_style & WS_EX_TOOLWINDOW) != 0 || IsPopupClass(cls);
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
    /// Mac's latest press went in (0 for never), when someone at the PC last
    /// pressed something, as of now (g_pc_input_at; 0 for never), and since
    /// when the PC's input has been heard (g_pc_watching_since; 0 while it is
    /// not).
    uint64_t now = 0;
    uint64_t shown_at = 0;
    uint64_t mac_press_at = 0;
    uint64_t pc_input_at = 0;
    uint64_t watching_since = 0;
};

/// Whether the PC's own input rules out a window the Mac's press might have
/// opened: rule (b) is for a PC nobody is using. Read with the PC's input as
/// it is now, every time the watcher looks.
///
/// Ruled out when someone pressed something at the PC in the last
/// kPcIdleForMacOpenMs -- before the Mac's press or after it, since a program
/// started at the PC shows its window seconds later, after the Mac's next
/// click as easily as before it -- and whenever the PC's input has not been
/// heard for that long: a quiet PC nobody has listened to says nothing.
///
/// Never for an owned window. The fence keeps the PC user's pointer off the
/// held windows, so they cannot well open a dialog one of them owns, and
/// turning the dialog away would leave the Mac's own Save As where nobody can
/// see it.
inline bool PcInputRulesOut(const FollowFacts& f) {
    if (f.owner_reaches_held) {
        return false;
    }
    if (f.watching_since == 0 || f.now < f.watching_since + kPcIdleForMacOpenMs) {
        return true;
    }
    return f.pc_input_at != 0 && f.now <= f.pc_input_at + kPcIdleForMacOpenMs;
}

/// Whether a newly shown window follows a held one, and why.
inline FollowReason DecideFollow(const FollowFacts& f) {
    if (!f.top_level || f.held || f.own_process || f.earshot) {
        return FollowReason::None;
    }
    // Windows' own word that it belongs to the application: a credential
    // prompt or a sign-in from a broker process, a palette, a menu that
    // reaches past its window.
    if (f.owner_reaches_held) {
        return FollowReason::Owned;
    }
    if (f.shell || f.tooltip || PcInputRulesOut(f)) {
        return FollowReason::None;
    }
    // A window already showing before the press was not opened by it.
    if (f.foreground && f.press_was_on_held && !f.tool_window && f.mac_press_at != 0
        && f.shown_at + kShownBeforePressSlackMs >= f.mac_press_at
        && f.now >= f.mac_press_at && f.now - f.mac_press_at <= kFollowAfterMacInputMs) {
        return FollowReason::OpenedByMac;
    }
    return FollowReason::None;
}

/// Whether nothing more can make this window follow, for this sighting: one
/// that might yet take the foreground is worth another look until its time
/// runs out, but one the PC's own input has ruled out is dropped then, however
/// still the PC goes. Shown again later, it is looked at afresh.
inline bool NeverFollows(const FollowFacts& f) {
    return f.held || f.own_process || f.earshot || PcInputRulesOut(f)
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
