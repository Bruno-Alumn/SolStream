#include "clipboard.h"

#include <cstring>
#include <initializer_list>

#include "util.h"

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

/// The clipboard is a shared, contended resource: another process can hold it
/// open, and OpenClipboard fails rather than waiting.
class ClipboardLock {
public:
    ClipboardLock() {
        for (int attempt = 0; attempt < 10 && !held_; ++attempt) {
            held_ = OpenClipboard(nullptr) != FALSE;
            if (!held_) {
                Sleep(20);
            }
        }
    }
    ~ClipboardLock() {
        if (held_) {
            CloseClipboard();
        }
    }
    bool held() const { return held_; }

    ClipboardLock(const ClipboardLock&) = delete;
    ClipboardLock& operator=(const ClipboardLock&) = delete;

private:
    bool held_ = false;
};

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

DWORD ClipboardSequence() {
    return GetClipboardSequenceNumber();
}

std::string ClipboardGetJson() {
    ClipboardLock lock;
    if (!lock.held()) {
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"clipboard busy\"}";
    }
    // A password manager marks what it copies as not for clipboard tools, and
    // this sync is one. On the Mac a password would go on into clipboard
    // history and across to the user's other Apple devices, and nothing would
    // clear it when the password manager clears this clipboard. Said as no
    // text, which every Mac already leaves alone, with "private" for one that
    // wants to say why.
    if (ClipboardIsPrivate(ReadClipboardMarkers())) {
        return "{\"type\":\"clipboard\",\"ok\":true,\"private\":true,\"text\":\"\",\"seq\":"
             + std::to_string(ClipboardSequence()) + "}";
    }
    HANDLE handle = GetClipboardData(CF_UNICODETEXT);
    if (!handle) {
        // Not an error: the clipboard may hold an image, or nothing.
        return "{\"type\":\"clipboard\",\"ok\":true,\"text\":\"\",\"seq\":"
             + std::to_string(ClipboardSequence()) + "}";
    }
    auto* wide = static_cast<const wchar_t*>(GlobalLock(handle));
    if (!wide) {
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"could not lock\"}";
    }
    // In the Mac's line endings, so every Mac gets them whatever its version.
    // Before the size check, which then counts what is actually sent.
    std::string text = ToMacLineEndings(ToUtf8(wide));
    GlobalUnlock(handle);

    // A clipboard can hold a whole document; this channel is for text people
    // copy, not for bulk transfer.
    bool truncated = false;
    if (text.size() > kMaxClipboardBytes) {
        // Cut between codepoints, not at a byte offset. resize() alone can slice
        // a multi-byte character in half, and the Mac rejects the whole line as
        // malformed JSON — losing the reply, not just the tail of the text.
        size_t cut = kMaxClipboardBytes;
        while (cut > 0 && (static_cast<unsigned char>(text[cut]) & 0xC0) == 0x80) {
            --cut;
        }
        text.resize(cut);
        truncated = true;
    }
    return "{\"type\":\"clipboard\",\"ok\":true,\"seq\":" + std::to_string(ClipboardSequence())
         + ",\"truncated\":" + (truncated ? "true" : "false")
         + ",\"text\":\"" + JsonEscape(text) + "\"}";
}

std::string ClipboardSetJson(const std::string& text) {
    // Windows' line endings whatever the Mac sent: one from before it learned
    // to convert sends bare LF. No echo follows from changing the text: the
    // Mac adopts the sequence number this write produces, so it never reads
    // the converted copy back as a change of its own. Not cut to
    // kMaxClipboardBytes: a Mac cuts its text to that before adding the CRs,
    // so a full one arrives up to twice as long.
    const std::wstring wide = ToWide(ToWindowsLineEndings(text));
    const size_t bytes = (wide.size() + 1) * sizeof(wchar_t);
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (!memory) {
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"out of memory\"}";
    }
    if (void* target = GlobalLock(memory)) {
        std::memcpy(target, wide.c_str(), bytes);
        GlobalUnlock(memory);
    } else {
        GlobalFree(memory);
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"could not lock\"}";
    }

    ClipboardLock lock;
    if (!lock.held()) {
        GlobalFree(memory);
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"clipboard busy\"}";
    }
    EmptyClipboard();
    if (!SetClipboardData(CF_UNICODETEXT, memory)) {
        // Ownership only transfers on success; on failure it is still ours.
        GlobalFree(memory);
        return "{\"type\":\"clipboard\",\"ok\":false,\"message\":\"clipboard rejected it\"}";
    }
    return "{\"type\":\"clipboard\",\"ok\":true,\"seq\":"
         + std::to_string(ClipboardSequence()) + "}";
}

std::string ClipboardUnchangedJson() {
    return "{\"type\":\"clipboard\",\"ok\":true,\"unchanged\":true,\"seq\":"
         + std::to_string(ClipboardSequence()) + "}";
}

}  // namespace solstream
