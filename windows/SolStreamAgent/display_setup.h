// display_setup.h — making the virtual display fit to stream.
//
// Installing the driver is not the same as having a display worth capturing.
// Straight out of the box the Virtual Display Driver offers a short list of
// modes that has nothing to do with any Mac, advertises HDR, and attaches at
// whatever DPI Windows guesses. All three have to be corrected before the first
// frame is any good, and until now all three lived in a PowerShell script
// (windows/VirtualDisplay/setup-virtual-display.ps1) that the application never
// ran — so pressing "Install driver" gave you a driver and none of the setup.
//
// The HDR one is not cosmetic. SolStream is SDR Rec.709 from capture to screen
// and the Mac client does no PQ tone mapping, so a display composing in
// ST.2084 / Rec.2020 arrives with white still white and black still black —
// both are endpoints of either curve — and every mid-tone between them crushed
// to near-black. It reads as "the window's chrome draws and its content is a
// black rectangle", it is worst in terminals and browsers, and a pure
// black-on-white application looks perfect throughout, which is what made it so
// easy to misread as a capture bug for days.

#pragma once

#include <windows.h>

#include <functional>
#include <string>

namespace solstream {

/// The canvas SolStream sets up by default: 1800x1169 points at 2x, which is
/// within NVENC's 4096 limit on both axes and large enough for any current
/// Mac's window. The full ladder is seeded alongside it, so a Mac of a different
/// size later needs only a mode switch and never a device restart.
constexpr int kDefaultCanvasWidth = 3600;
constexpr int kDefaultCanvasHeight = 2338;

/// 200% matches a 2x Retina Mac exactly: Windows draws its UI at 2x, the Mac
/// shows those pixels at 2x, and a Windows control ends up the same physical
/// size as a native one. At 100% every glyph arrives half the size it should be.
constexpr int kDefaultScalePercent = 200;

/// Teach the driver the mode ladder, turn its HDR off, cycle it so it re-reads
/// its settings, attach it, set its scaling, and turn "Use HDR" off on the
/// display itself.
///
/// Needs administrator rights (it writes the driver's settings file and restarts
/// the device) and the interactive session (display configuration is
/// session-bound; run in session 0 it lands on a phantom 1024x768 desktop and
/// silently does nothing).
///
/// Returns false only when there is no usable virtual display at the end of it.
/// The parts that are improvements rather than requirements — scaling, the HDR
/// toggle — report into `note` instead of failing the whole thing.
///
/// Run by Set up and the command-line setups only, never at the host's start:
/// each step it takes can be a display reconfiguration, and the host starts at
/// every logon and again after every crash.
///
/// `may_reattach`, when given, is asked before the one step that attaches a
/// display already attached at another size; false leaves it at its size. The
/// host's Set up says no while a Mac is connected: that is the topology
/// changing under a running capture, or under a full-screen game.
///
/// `settings_refused`, when given, is set when the driver's settings file
/// needed changing and writing it was refused -- no administrator rights.
/// Everything else may still have worked, so the call can return true with it
/// set; a caller that can ask for the rights should.
bool ConfigureVirtualDisplay(int width, int height, int scale_percent,
                             std::string& note, std::string& error,
                             const std::function<bool()>& may_reattach = {},
                             bool* settings_refused = nullptr);

/// What the host does with the virtual display when it starts: says, into
/// `note`, whether SolStream's is attached and at what size, rate and scaling,
/// and turns "Use HDR" off on it if it is on. Nothing else -- it does not
/// attach, resize, move or rescale it, or touch the driver's settings.
void CheckVirtualDisplay(std::string& note);

/// The scaling SolStream's attached virtual display is at, as a percentage,
/// when the window should offer Set up for it: not kDefaultScalePercent, and
/// at a size where Windows would let it be (OffScale). 0 otherwise, and when it
/// is not attached or its scaling cannot be read. Read only.
int VirtualDisplayOffScale();

/// Put `gdi_name` back at kDefaultScalePercent after its size changed, when
/// Windows lets it be at the new size. Windows keeps scaling relative to what
/// it recommends for a size, so a mode switch alone can leave a 200% display
/// at 150%. True when it is at kDefaultScalePercent afterwards. What was done,
/// or why it could not be, goes into `note`; a size that stops short of it is
/// left without a word.
bool RestoreVirtualDisplayScale(const std::wstring& gdi_name, std::string& note);

/// The folder the Virtual Display Driver reads vdd_settings.xml from: VDDPATH
/// under HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver when set, otherwise
/// C:\VirtualDisplayDriver -- both read out of MttVDD.dll itself. One answer
/// for everything that reads, writes or removes it.
std::wstring VddSettingsFolder();

/// A string value from `root`\`key`, in the 64-bit view of the registry, or
/// empty when it is not there, is not a string, or is longer than MAX_PATH.
std::wstring ReadRegString(HKEY root, const wchar_t* key, const wchar_t* name);

/// Added to vdd_settings.xml's name for the copy kept of it before SolStream
/// first changes it. Named once, so what uninstall deletes is what this writes.
constexpr wchar_t kVddSettingsBackupSuffix[] = L".solstream-backup";

/// Added to vdd_settings.xml's name for the new version written beside it and
/// then moved over it. Left behind only by a process killed in between, and
/// removed with the folder.
constexpr wchar_t kVddSettingsWriteSuffix[] = L".new";

/// Is this path a junction, symbolic link or other reparse point? Elevated
/// writes and deletes under C:\ refuse those: any user can make folders there.
bool IsReparsePoint(const std::wstring& path);

/// Whether a file or folder that exists is one an elevated process must not
/// write through: a link, or one owned by anybody but Administrators, SYSTEM
/// or the account this process runs as -- another user can replace theirs
/// with a link once a check by path is done. False for a path that is not
/// there yet.
bool IsUnsafeForElevatedWrite(const std::wstring& path);

/// The attached virtual display SolStream streams from, as \\.\DISPLAYn, or
/// empty when there is none. The same choice ConfigureVirtualDisplay makes, so
/// the display that was set up is the display that gets captured -- but only
/// when it is SolStream's own driver (IsSolStreamDisplayDriver). With ours
/// absent, the best adapter can be a phone-as-monitor or remote-desktop
/// product's display, which SolStream neither sizes nor controls; capturing it
/// or resizing it is not the host's to do, so that is empty too.
std::wstring VirtualDisplayDevice();

}  // namespace solstream
