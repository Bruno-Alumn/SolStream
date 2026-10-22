// clipboard.h — what the clipboard's text needs on its way between the Mac and
// Windows, apart from the JSON it travels in.
//
// An application can mark what it copies as not for clipboard tools, which is
// how a password manager keeps a password out of clipboard history -- and has
// to keep it off the Mac too.
//
// Kept out of main.cpp so the tests can reach it. The transfer itself, and the
// lock around Windows' clipboard, stay there.

#pragma once

#include <windows.h>

#include <optional>

namespace solstream {

/// The formats Windows defines for an application to say "clipboard tools,
/// leave this alone". Password managers set them on everything they copy.
struct ClipboardMarkers {
    /// "ExcludeClipboardContentFromMonitorProcessing": present at all means
    /// it is not to be read by anything watching the clipboard.
    bool exclude_from_monitors = false;
    /// "Clipboard Viewer Ignore": the older convention clipboard managers
    /// honour, meaning the same.
    bool viewer_ignore = false;
    /// "CanIncludeInClipboardHistory" and "CanUploadToCloudClipboard": a
    /// DWORD, 0 to refuse and 1 to allow. Absent says nothing either way.
    std::optional<DWORD> history;
    std::optional<DWORD> cloud;
};

/// Whether the markers keep the clipboard on this PC.
///
/// The Mac is another device, so an application refusing the cloud clipboard
/// -- which carries a copy to the user's other PCs -- is refusing the Mac as
/// well.
bool ClipboardIsPrivate(const ClipboardMarkers& markers);

/// The DWORD held in a clipboard format's data, or nothing when the handle is
/// null or holds fewer than four bytes.
std::optional<DWORD> ClipboardDword(HANDLE data);

/// Read the markers off the clipboard. The caller must have it open.
ClipboardMarkers ReadClipboardMarkers();

}  // namespace solstream
