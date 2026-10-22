#include "clipboard.h"

#include <cstring>

namespace solstream {

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
