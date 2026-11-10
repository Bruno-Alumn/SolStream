// window_keys.h -- which button a key presses in the setup, uninstall and
// host windows when no control has the focus.
//
// The window draws its own buttons, so it gets none of a dialog's keys for
// free: Escape did nothing on setup's Cancel or Close, Enter did nothing on a
// screen that had just opened -- the focus starts on nothing -- and the token
// could be copied only by tabbing to Copy. Apart from host_window.cpp so it
// can be tested.

#pragma once

#include "host_window.h"

namespace solstream {

/// Where setup has got to. Setup, uninstall and the display-driver button all
/// have the same shape — choose, work, then say what happened — so they share
/// one state machine rather than each inventing their own.
enum class Phase { Choosing, Working, Done, Failed };

/// What a key asks for; the window presses the button of that name, and only
/// one on show.
enum class KeyPress { None, CopyToken, Install, Cancel, OpenApp, Close, Retry };

enum class Key { Enter, Escape, CtrlC };

/// The button `key` presses in `mode` at `phase`, with nothing focused.
///
/// Enter presses the screen's primary button, except Remove and trying a
/// removal again: taking SolStream off a PC is asked for by pressing it, not
/// by a key that may have been meant for another window. Escape is Cancel while choosing and Close once it has
/// finished, and nothing while working, when closing is refused anyway. The
/// host window keeps its own Escape (put away to the tray), and Ctrl+C copies
/// the token there.
inline KeyPress KeyTarget(WindowMode mode, Phase phase, Key key) {
    if (mode == WindowMode::Host) {
        return key == Key::CtrlC ? KeyPress::CopyToken : KeyPress::None;
    }
    switch (key) {
        case Key::CtrlC:
            return KeyPress::None;
        case Key::Escape:
            switch (phase) {
                case Phase::Choosing: return KeyPress::Cancel;
                case Phase::Working: return KeyPress::None;
                case Phase::Done:
                case Phase::Failed: return KeyPress::Close;
            }
            return KeyPress::None;
        case Key::Enter:
            switch (phase) {
                case Phase::Choosing:
                    return mode == WindowMode::Setup ? KeyPress::Install : KeyPress::None;
                case Phase::Working: return KeyPress::None;
                case Phase::Done:
                    return mode == WindowMode::Setup ? KeyPress::OpenApp : KeyPress::Close;
                // Trying a removal again is asked for on purpose, as Remove is.
                case Phase::Failed:
                    return mode == WindowMode::Setup ? KeyPress::Retry : KeyPress::None;
            }
            return KeyPress::None;
    }
    return KeyPress::None;
}

}  // namespace solstream
