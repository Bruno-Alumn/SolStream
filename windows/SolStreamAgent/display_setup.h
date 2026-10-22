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
bool ConfigureVirtualDisplay(int width, int height, int scale_percent,
                             std::string& note, std::string& error);

/// The folder the Virtual Display Driver reads vdd_settings.xml from: VDDPATH
/// under HKLM\SOFTWARE\MikeTheTech\VirtualDisplayDriver when set, otherwise
/// C:\VirtualDisplayDriver -- both read out of MttVDD.dll itself. One answer
/// for everything that reads, writes or removes it.
std::wstring VddSettingsFolder();

/// Added to vdd_settings.xml's name for the copy kept of it before SolStream
/// first changes it. Named once, so what uninstall deletes is what this writes.
constexpr wchar_t kVddSettingsBackupSuffix[] = L".solstream-backup";

/// Is this path a junction, symbolic link or other reparse point? Elevated
/// writes and deletes under C:\ refuse those: any user can make folders there.
bool IsReparsePoint(const std::wstring& path);

/// The attached virtual display SolStream streams from, as \\.\DISPLAYn, or
/// empty when there is none. The same choice ConfigureVirtualDisplay makes, so
/// the display that was set up is the display that gets captured.
std::wstring VirtualDisplayDevice();

/// Is Windows composing this display in HDR? `gdi_name` is a device name of the
/// form \\.\DISPLAY1. Answers false for a display that cannot do HDR at all.
bool IsHdrEnabled(const std::wstring& gdi_name);

/// Turn "Use HDR" on or off for one display.
///
/// Needs no elevation, but does need the interactive session. This is the
/// setting that actually decides: clearing HDRPlus in the driver's own settings
/// file stops it ADVERTISING HDR, but Windows remembers the per-display toggle
/// and re-applies it, so the display keeps composing in PQ and only the bit
/// depth changes.
bool SetHdrEnabled(const std::wstring& gdi_name, bool enabled, std::string& error);

}  // namespace solstream
