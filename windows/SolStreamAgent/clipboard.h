// clipboard.h — what the clipboard's text needs on its way between the Mac and
// Windows, apart from the JSON it travels in.
//
// Two things. The machines end a line differently, and each side's
// applications expect their own. And an application can mark what it copies
// as not for clipboard tools, which is how a password manager keeps a password
// out of clipboard history -- and has to keep it off the Mac too.
//
// Kept out of main.cpp so the tests can reach it. The transfer itself, and the
// lock around Windows' clipboard, stay there.

#pragma once

#include <windows.h>

#include <optional>
#include <string>

namespace solstream {

/// Text as Windows keeps it on the clipboard: every line ending CRLF.
///
/// A Mac line ends in a bare LF, and a classic multi-line edit control --
/// WinForms' TextBox and most dialogs -- shows a bare LF as no line break at
/// all, so a pasted paragraph arrives as one long line. An LF that already
/// follows a CR is left alone, so converting twice changes nothing.
std::string ToWindowsLineEndings(const std::string& text);

/// Text as the Mac keeps it: CRLF folded to LF, and with it any run of CRs
/// before an LF -- what an edit control's soft line break, or a CRLF converted
/// twice, leaves. So what comes out holds no CRLF, and folding it again changes
/// nothing.
///
/// Left as CRLF, every line pasted into a terminal or a code editor carries a
/// stray CR. A CR not followed by an LF is not a Windows line ending and is
/// left alone.
std::string ToMacLineEndings(const std::string& text);

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
