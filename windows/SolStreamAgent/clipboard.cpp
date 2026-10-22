#include "clipboard.h"

#include <cstring>
#include <initializer_list>

namespace solstream {

namespace {

/// Registered once: the same name always answers the same format for the life
/// of the session, and registering is a trip to the atom table.
struct MarkerFormats {
    UINT exclude = RegisterClipboardFormatW(L"ExcludeClipboardContentFromMonitorProcessing");
    UINT ignore = RegisterClipboardFormatW(L"Clipboard Viewer Ignore");
    UINT history = RegisterClipboardFormatW(L"CanIncludeInClipboardHistory");
    UINT cloud = RegisterClipboardFormatW(L"CanUploadToCloudClipboard");
};

const MarkerFormats& Formats() {
    static const MarkerFormats formats;
    return formats;
}

}  // namespace

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
    for (const char c : text) {
        // The CRs at the end of what is out so far are the ones right before
        // this LF.
        if (c == '\n') {
            while (!out.empty() && out.back() == '\r') {
                out.pop_back();
            }
        }
        out.push_back(c);
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
    const MarkerFormats& formats = Formats();
    ClipboardMarkers markers;
    markers.exclude_from_monitors =
        formats.exclude != 0 && IsClipboardFormatAvailable(formats.exclude);
    markers.viewer_ignore = formats.ignore != 0 && IsClipboardFormatAvailable(formats.ignore);
    if (formats.history != 0 && IsClipboardFormatAvailable(formats.history)) {
        markers.history = ClipboardDword(GetClipboardData(formats.history));
    }
    if (formats.cloud != 0 && IsClipboardFormatAvailable(formats.cloud)) {
        markers.cloud = ClipboardDword(GetClipboardData(formats.cloud));
    }
    return markers;
}

HGLOBAL ClipboardDwordData(DWORD value) {
    HGLOBAL data = GlobalAlloc(GMEM_MOVEABLE, sizeof(value));
    if (!data) {
        return nullptr;
    }
    void* bytes = GlobalLock(data);
    if (!bytes) {
        GlobalFree(data);
        return nullptr;
    }
    std::memcpy(bytes, &value, sizeof(value));
    GlobalUnlock(data);
    return data;
}

void MarkClipboardPrivate() {
    const MarkerFormats& formats = Formats();
    // 0 refuses history and the cloud. The first format says what it says by
    // being there at all, so its 0 is only there to be some data.
    for (const UINT format : {formats.exclude, formats.history, formats.cloud}) {
        if (format == 0) {
            continue;
        }
        HGLOBAL data = ClipboardDwordData(0);
        if (data && !SetClipboardData(format, data)) {
            // Ownership only transfers on success; on failure it is still ours.
            GlobalFree(data);
        }
    }
}

}  // namespace solstream
