#include "clipboard.h"

#include <cstring>

namespace solstream {

// Both work on UTF-8 bytes. CR and LF are ASCII, and no byte of a multi-byte
// UTF-8 sequence falls in the ASCII range, so neither can be found inside a
// character or cut one in half.

std::string ToWindowsLineEndings(const std::string& text) {
    std::string out;
    out.reserve(text.size() + text.size() / 16);
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '\n' && (i == 0 || text[i - 1] != '\r')) {
            out.push_back('\r');
        }
        out.push_back(text[i]);
    }
    return out;
}

std::string ToMacLineEndings(const std::string& text) {
    std::string out;
    out.reserve(text.size());
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '\r' && i + 1 < text.size() && text[i + 1] == '\n') {
            continue;
        }
        out.push_back(text[i]);
    }
    return out;
}

bool ClipboardIsPrivate(const ClipboardMarkers& markers) {
    return markers.exclude_from_monitors || markers.viewer_ignore
           || markers.history == DWORD{0} || markers.cloud == DWORD{0};
}

std::optional<DWORD> ClipboardDword(HANDLE data) {
    if (!data || GlobalSize(data) < sizeof(DWORD)) {
        return std::nullopt;
    }
    const void* bytes = GlobalLock(data);
    if (!bytes) {
        return std::nullopt;
    }
    DWORD value = 0;
    std::memcpy(&value, bytes, sizeof(value));
    GlobalUnlock(data);
    return value;
}

ClipboardMarkers ReadClipboardMarkers() {
    // Registered once: the same name always answers the same format for the
    // life of the session, and registering is a trip to the atom table.
    static const UINT exclude =
        RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
    static const UINT ignore = RegisterClipboardFormatW(L"Clipboard Viewer Ignore");
    static const UINT history = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
    static const UINT cloud = RegisterClipboardFormatW(L"CanUploadToCloudClipboard");

    ClipboardMarkers markers;
    markers.exclude_from_monitors = exclude != 0 && IsClipboardFormatAvailable(exclude);
    markers.viewer_ignore = ignore != 0 && IsClipboardFormatAvailable(ignore);
    if (history != 0 && IsClipboardFormatAvailable(history)) {
        markers.history = ClipboardDword(GetClipboardData(history));
    }
    if (cloud != 0 && IsClipboardFormatAvailable(cloud)) {
        markers.cloud = ClipboardDword(GetClipboardData(cloud));
    }
    return markers;
}

}  // namespace solstream
