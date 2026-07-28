// sunshine_host.h — SolStream owning its own Sunshine, instead of asking the
// user to install and configure one.
//
// ── On the licence ───────────────────────────────────────────────────────────
//
// Sunshine is GPL-3.0. None of its code is compiled into this program and
// nothing here links against it: SolStream ships Sunshine's own unmodified
// binary alongside its own and runs it as a child process, communicating over
// the network protocol any Moonlight client would use. That is aggregation, not
// derivation — the arrangement Moonlight clients have always had with it — and
// it keeps SolStream's own licence its own. Distributing the binary still
// carries the GPL's obligations: ship Sunshine's licence text and offer its
// source. `--sunshine-source` prints where that is.
//
// Compiling Sunshine *into* this executable would be the other reading of "built
// in", and it would make the whole of SolStream GPL-3.0. That is a decision
// about the product, not about the code, so this takes the reversible option.
//
// ── What the user gets ───────────────────────────────────────────────────────
//
// A Sunshine the user never sees, never configures and never has to keep in step
// with SolStream:
//
//   * its own configuration directory, so an existing Sunshine install is left
//     untouched — its config, its paired clients, its apps;
//   * its own ports (ports.h), so both can run at once;
//   * web UI credentials generated here and never shown, which is what lets the
//     agent approve pairing PINs on the user's behalf. That was previously a
//     manual --set-sunshine-credentials step, and before that a browser, a
//     certificate warning, and a PIN page.
//   * the capture display pinned to the virtual one, so the stream never shows
//     the user's real desktop.

#pragma once

#include <string>

namespace solstream {

/// How the supervised Sunshine is doing.
enum class SunshineState {
    kStopped,      ///< Not running, and not meant to be.
    kStarting,     ///< Spawned; its web API has not answered yet.
    kRunning,      ///< Answering on its own ports.
    kFailed,       ///< Could not be started — `SunshineStatusText` says why.
    kNotBundled,   ///< No sunshine.exe found to run.
};

/// Where the supervisor found (or failed to find) Sunshine.
struct SunshineLocation {
    std::wstring executable;   ///< Empty when nothing was found.
    bool bundled = false;      ///< True when it came from beside our own .exe.
};

/// Look for Sunshine beside this executable first, then where the official
/// installer puts it.
///
/// Beside-us first on purpose: the bundled copy is the one whose version this
/// program was tested against, and a machine with both should not silently get
/// the other one.
SunshineLocation FindSunshine();

/// Write SolStream's own Sunshine configuration and start it.
///
/// Idempotent: if a supervised Sunshine is already running this does nothing.
/// `output_name` is the display device to capture, e.g. `\\.\DISPLAY5` — pass
/// the virtual display so the stream can never show the real desktop.
bool StartSunshine(unsigned short base_port, const std::wstring& output_name);

/// Stop the supervised Sunshine, if this program started one.
///
/// A Sunshine the user installed themselves is never touched: this only knows
/// about the process it spawned.
void StopSunshine();

/// True when the last StartSunshine stopped only so it could come back pinned
/// to the right display. Clears when read; the caller should simply call
/// StartSunshine again.
bool RestartedForDisplay();

SunshineState GetSunshineState();
std::string SunshineStatusText();

/// The web UI credentials this program generated, for its own API calls. Empty
/// until `StartSunshine` has run once.
bool SupervisedCredentials(std::string& user, std::string& password);

/// Where SolStream keeps its Sunshine's configuration — separate from any the
/// user installed.
std::wstring SunshineConfigDir();

}  // namespace solstream
