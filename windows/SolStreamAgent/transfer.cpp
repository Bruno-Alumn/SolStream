#include "transfer.h"

#include <objbase.h>
#include <shlobj.h>
#include <wincodec.h>
#include <wincrypt.h>

#include <algorithm>
#include <cstring>
#include <cwctype>
#include <mutex>

#include "media/log.h"
#include "util.h"

namespace solstream {

using media::Log;

namespace {

// The Imaging Component's class, interface and format ids, spelled out here:
// mingw's import libraries do not carry them, and these never change.
const GUID kWicFactoryClass = {0xcacaf262, 0x9370, 0x4615,
                               {0xa1, 0x3b, 0x9f, 0x55, 0x39, 0xda, 0x4c, 0x0a}};
const GUID kWicFactoryInterface = {0xec5ec8a9, 0xc395, 0x4314,
                                   {0x9c, 0x77, 0x54, 0xd7, 0xa9, 0x35, 0xff, 0x70}};
const GUID kPngContainer = {0x1b7cfaf4, 0x713f, 0x473c,
                            {0xbb, 0xcd, 0x61, 0x37, 0x42, 0x5f, 0xae, 0xaf}};
const GUID kBgra32 = {0x6fddc324, 0x4e03, 0x4bfe,
                      {0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x0f}};

/// The clipboard, opened with retries: another program may hold it a moment.
/// The same as clipboard.cpp's, which keeps its own private.
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
    ClipboardLock(const ClipboardLock&) = delete;
    ClipboardLock& operator=(const ClipboardLock&) = delete;
    bool held() const { return held_; }

private:
    bool held_ = false;
};

/// COM for the Imaging Component, for the length of one conversion: the
/// client thread's apartment belongs to the media path's WinRT calls.
class ComScope {
public:
    ComScope() : result_(CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE)) {}
    ~ComScope() {
        if (SUCCEEDED(result_)) {
            CoUninitialize();
        }
    }
    ComScope(const ComScope&) = delete;
    ComScope& operator=(const ComScope&) = delete;

private:
    HRESULT result_;
};

/// Releases a COM pointer when it goes.
template <typename T>
class Ref {
public:
    Ref() = default;
    ~Ref() {
        if (pointer_) {
            pointer_->Release();
        }
    }
    Ref(const Ref&) = delete;
    Ref& operator=(const Ref&) = delete;
    T* operator->() const { return pointer_; }
    T* get() const { return pointer_; }
    T** out() { return &pointer_; }
    void** out_void() { return reinterpret_cast<void**>(&pointer_); }
    explicit operator bool() const { return pointer_ != nullptr; }

private:
    T* pointer_ = nullptr;
};

UINT PngFormat() {
    static const UINT format = RegisterClipboardFormatW(L"PNG");
    return format;
}

UINT DropEffectFormat() {
    static const UINT format = RegisterClipboardFormatW(L"Preferred DropEffect");
    return format;
}

std::string Error(const char* type, const std::string& message) {
    return std::string("{\"type\":\"") + type + "\",\"ok\":false,\"message\":\""
         + JsonEscape(message) + "\"}";
}

/// A picture in any format the Imaging Component reads, decoded and checked.
bool Decode(IWICImagingFactory* factory, const std::vector<unsigned char>& bytes,
            Ref<IWICStream>& stream, Ref<IWICBitmapFrameDecode>& frame) {
    Ref<IWICBitmapDecoder> decoder;
    if (bytes.empty() || bytes.size() > 0xFFFFFFFFu
        || FAILED(factory->CreateStream(stream.out()))
        || FAILED(stream->InitializeFromMemory(const_cast<BYTE*>(bytes.data()),
                                               static_cast<DWORD>(bytes.size())))
        || FAILED(factory->CreateDecoderFromStream(stream.get(), nullptr,
                                                   WICDecodeMetadataCacheOnDemand,
                                                   decoder.out()))
        || FAILED(decoder->GetFrame(0, frame.out()))) {
        return false;
    }
    UINT width = 0, height = 0;
    return SUCCEEDED(frame->GetSize(&width, &height)) && width > 0 && height > 0
        && width <= kMaxClipboardImageSide && height <= kMaxClipboardImageSide
        && static_cast<unsigned long long>(width) * height <= kMaxClipboardImagePixels;
}

bool CreateFactory(Ref<IWICImagingFactory>& factory) {
    return SUCCEEDED(CoCreateInstance(kWicFactoryClass, nullptr, CLSCTX_INPROC_SERVER,
                                      kWicFactoryInterface, factory.out_void()));
}

/// `bytes` -- a BMP, a PNG, anything the Imaging Component reads -- as PNG.
bool EncodePng(const std::vector<unsigned char>& bytes, std::vector<unsigned char>& png) {
    ComScope com;
    Ref<IWICImagingFactory> factory;
    Ref<IWICStream> source;
    Ref<IWICBitmapFrameDecode> frame;
    if (!CreateFactory(factory) || !Decode(factory.get(), bytes, source, frame)) {
        return false;
    }
    Ref<IStream> memory;
    if (FAILED(CreateStreamOnHGlobal(nullptr, TRUE, memory.out()))) {
        return false;
    }
    Ref<IWICBitmapEncoder> encoder;
    Ref<IWICBitmapFrameEncode> target;
    Ref<IPropertyBag2> options;
    if (FAILED(factory->CreateEncoder(kPngContainer, nullptr, encoder.out()))
        || FAILED(encoder->Initialize(memory.get(), WICBitmapEncoderNoCache))
        || FAILED(encoder->CreateNewFrame(target.out(), options.out()))
        || FAILED(target->Initialize(options.get()))
        || FAILED(target->WriteSource(frame.get(), nullptr))
        || FAILED(target->Commit()) || FAILED(encoder->Commit())) {
        return false;
    }
    STATSTG stat{};
    HGLOBAL global = nullptr;
    if (FAILED(memory->Stat(&stat, STATFLAG_NONAME))
        || FAILED(GetHGlobalFromStream(memory.get(), &global)) || !global) {
        return false;
    }
    const size_t size = static_cast<size_t>(stat.cbSize.QuadPart);
    const void* data = GlobalLock(global);
    if (!data) {
        return false;
    }
    png.assign(static_cast<const unsigned char*>(data),
               static_cast<const unsigned char*>(data) + size);
    GlobalUnlock(global);
    return !png.empty();
}

/// A PNG as a 32-bit DIB, bottom-up as CF_DIB is, laid over white: CF_DIB's
/// alpha is ignored by most readers, and a transparent pixel left as it is
/// would paste black.
bool PngToDib(const std::vector<unsigned char>& png, std::vector<unsigned char>& dib) {
    ComScope com;
    Ref<IWICImagingFactory> factory;
    Ref<IWICStream> source;
    Ref<IWICBitmapFrameDecode> frame;
    Ref<IWICFormatConverter> converter;
    UINT width = 0, height = 0;
    if (!CreateFactory(factory) || !Decode(factory.get(), png, source, frame)
        || FAILED(factory->CreateFormatConverter(converter.out()))
        || FAILED(converter->Initialize(frame.get(), kBgra32, WICBitmapDitherTypeNone, nullptr,
                                        0.0, WICBitmapPaletteTypeCustom))
        || FAILED(converter->GetSize(&width, &height))) {
        return false;
    }
    const size_t stride = static_cast<size_t>(width) * 4;
    std::vector<unsigned char> pixels(stride * height);
    if (FAILED(converter->CopyPixels(nullptr, static_cast<UINT>(stride),
                                     static_cast<UINT>(pixels.size()), pixels.data()))) {
        return false;
    }
    BITMAPINFOHEADER header{};
    header.biSize = sizeof(header);
    header.biWidth = static_cast<LONG>(width);
    header.biHeight = static_cast<LONG>(height);  // bottom-up
    header.biPlanes = 1;
    header.biBitCount = 32;
    header.biCompression = BI_RGB;
    header.biSizeImage = static_cast<DWORD>(pixels.size());
    dib.resize(sizeof(header) + pixels.size());
    std::memcpy(dib.data(), &header, sizeof(header));
    unsigned char* out = dib.data() + sizeof(header);
    for (UINT row = 0; row < height; ++row) {
        const unsigned char* in = pixels.data() + static_cast<size_t>(height - 1 - row) * stride;
        unsigned char* line = out + static_cast<size_t>(row) * stride;
        for (UINT x = 0; x < width; ++x) {
            const unsigned alpha = in[x * 4 + 3];
            for (int channel = 0; channel < 3; ++channel) {
                line[x * 4 + channel] = static_cast<unsigned char>(
                    (in[x * 4 + channel] * alpha + 255 * (255 - alpha)) / 255);
            }
            line[x * 4 + 3] = 255;
        }
    }
    return true;
}

/// The bytes a clipboard format holds. The caller has the clipboard open.
std::vector<unsigned char> FormatBytes(UINT format) {
    std::vector<unsigned char> bytes;
    HANDLE handle = GetClipboardData(format);
    if (!handle) {
        return bytes;
    }
    const size_t size = GlobalSize(handle);
    const void* data = GlobalLock(handle);
    if (data && size > 0) {
        bytes.assign(static_cast<const unsigned char*>(data),
                     static_cast<const unsigned char*>(data) + size);
    }
    if (data) {
        GlobalUnlock(handle);
    }
    return bytes;
}

HGLOBAL GlobalCopy(const void* data, size_t size) {
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
    if (!memory) {
        return nullptr;
    }
    void* target = GlobalLock(memory);
    if (!target) {
        GlobalFree(memory);
        return nullptr;
    }
    std::memcpy(target, data, size);
    GlobalUnlock(memory);
    return memory;
}

/// Hands `size` bytes to the clipboard as `format`. The caller owns the open
/// clipboard, having emptied it.
bool Put(UINT format, const void* data, size_t size) {
    HGLOBAL memory = GlobalCopy(data, size);
    if (!memory) {
        return false;
    }
    if (!SetClipboardData(format, memory)) {
        // Ownership only transfers on success; on failure it is still ours.
        GlobalFree(memory);
        return false;
    }
    return true;
}

std::mutex g_transfer_mutex;

/// The clipboard's picture as PNG, made once per sequence number.
struct OutgoingImage {
    DWORD sequence = 0;
    bool made = false;
    std::vector<unsigned char> png;
};
OutgoingImage g_outgoing;

/// A PNG from the Mac, chunk by chunk.
std::vector<unsigned char> g_incoming;
long long g_incoming_total = 0;  ///< the total its first chunk said

/// A file from the Mac, chunk by chunk.
struct Upload {
    HANDLE file = INVALID_HANDLE_VALUE;
    std::wstring path;
    unsigned long long total = 0;
    unsigned long long written = 0;
};
Upload g_upload;

/// Whether Windows deletes the file when its handle closes. Set on an upload
/// from its first byte and cleared after its last, so a host that stops
/// mid-way -- killed, crashed, the user signing out or shutting down -- leaves
/// no half file behind under the whole one's name, which DropUpload alone could
/// not see to. Not a power cut: the mark lives in memory until the handle closes.
bool DeleteWhenClosed(HANDLE file, bool remove) {
    FILE_DISPOSITION_INFO disposition{};
    disposition.DeleteFile = remove ? TRUE : FALSE;
    return SetFileInformationByHandle(file, FileDispositionInfo, &disposition,
                                      sizeof(disposition)) != FALSE;
}

/// An upload that never finished goes, rather than leaving half a file
/// in Downloads looking like a whole one. The caller holds the mutex.
void DropUpload() {
    if (g_upload.file != INVALID_HANDLE_VALUE) {
        CloseHandle(g_upload.file);
        DeleteFileW(g_upload.path.c_str());
        Log("[transfer] dropped an unfinished upload");
    }
    g_upload = Upload{};
}

std::wstring Lower(std::wstring text) {
    for (wchar_t& c : text) {
        c = static_cast<wchar_t>(std::towlower(c));
    }
    return text;
}

}  // namespace

/// A DIB as a BMP file, which the Imaging Component reads: the DIB with the
/// file header in front, saying where its pixels start.
std::vector<unsigned char> DibAsBmp(const unsigned char* dib, size_t size) {
    std::vector<unsigned char> bmp;
    if (size < sizeof(BITMAPINFOHEADER)) {
        return bmp;
    }
    BITMAPINFOHEADER header{};
    std::memcpy(&header, dib, sizeof(header));
    if (header.biSize < sizeof(BITMAPINFOHEADER) || header.biSize > size) {
        return bmp;
    }
    // What sits between the header and the pixels. Masks, after a plain
    // header only -- a V4 or V5 header carries them inside itself. Then a
    // colour table: as many entries as biClrUsed says, at any depth, since an
    // encoder may write an optional one even for 24 or 32 bits; otherwise a
    // full one for 8 bits or fewer, and none for JPEG or PNG inside (a bit
    // count of 0). Counted only by biBitCount, a table nobody needed shifted
    // every pixel and the picture came out garbled.
    size_t extra = 0;
    if (header.biSize == sizeof(BITMAPINFOHEADER)) {
        if (header.biCompression == BI_BITFIELDS) {
            extra = 12;
        } else if (header.biCompression == 6 /* BI_ALPHABITFIELDS */) {
            extra = 16;
        }
    }
    if (header.biClrUsed != 0) {
        extra += static_cast<size_t>(header.biClrUsed) * 4;
    } else if (header.biBitCount > 0 && header.biBitCount <= 8) {
        extra += (size_t{1} << header.biBitCount) * 4;
    }
    // Pixels that would start past the end are not a picture.
    if (extra > size || header.biSize + extra > size) {
        return bmp;
    }
    BITMAPFILEHEADER file{};
    file.bfType = 0x4D42;  // "BM"
    file.bfSize = static_cast<DWORD>(sizeof(file) + size);
    file.bfOffBits = static_cast<DWORD>(sizeof(file) + header.biSize + extra);
    bmp.resize(sizeof(file) + size);
    std::memcpy(bmp.data(), &file, sizeof(file));
    std::memcpy(bmp.data() + sizeof(file), dib, size);
    return bmp;
}

void AbandonUpload() {
    std::lock_guard<std::mutex> guard(g_transfer_mutex);
    DropUpload();
}

void AbandonTransfers() {
    std::lock_guard<std::mutex> guard(g_transfer_mutex);
    DropUpload();
    // And a picture on its way in: up to 32 MB otherwise held for the rest of
    // the host's life after the Mac that was sending it left.
    std::vector<unsigned char>().swap(g_incoming);
    g_incoming_total = 0;
}

std::string Base64Encode(const unsigned char* bytes, size_t size) {
    if (size == 0) {
        return {};
    }
    DWORD needed = 0;
    if (!CryptBinaryToStringA(bytes, static_cast<DWORD>(size),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, nullptr, &needed)) {
        return {};
    }
    std::string out(needed, '\0');
    if (!CryptBinaryToStringA(bytes, static_cast<DWORD>(size),
                              CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF, out.data(), &needed)) {
        return {};
    }
    out.resize(std::strlen(out.c_str()));
    return out;
}

bool Base64Decode(const std::string& text, std::vector<unsigned char>& out) {
    out.clear();
    if (text.empty()) {
        return true;
    }
    DWORD size = 0;
    if (!CryptStringToBinaryA(text.c_str(), static_cast<DWORD>(text.size()), CRYPT_STRING_BASE64,
                              nullptr, &size, nullptr, nullptr)) {
        return false;
    }
    out.resize(size);
    if (!CryptStringToBinaryA(text.c_str(), static_cast<DWORD>(text.size()), CRYPT_STRING_BASE64,
                              out.data(), &size, nullptr, nullptr)) {
        out.clear();
        return false;
    }
    out.resize(size);
    return true;
}

bool ClipboardHoldsImage() {
    return IsClipboardFormatAvailable(PngFormat()) || IsClipboardFormatAvailable(CF_DIBV5)
        || IsClipboardFormatAvailable(CF_DIB) || IsClipboardFormatAvailable(CF_BITMAP);
}

std::string ClipboardImageGetJson(long long seq, long long offset) {
    std::lock_guard<std::mutex> guard(g_transfer_mutex);
    const DWORD current = GetClipboardSequenceNumber();
    if (seq < 0 || static_cast<DWORD>(seq) != current) {
        return Error("clipboardImage", "the clipboard has changed");
    }
    if (!g_outgoing.made || g_outgoing.sequence != current) {
        g_outgoing = OutgoingImage{};
        g_outgoing.sequence = current;
        g_outgoing.made = true;
        std::vector<unsigned char> source;
        {
            ClipboardLock lock;
            if (!lock.held()) {
                g_outgoing.made = false;
                return Error("clipboardImage", "clipboard busy");
            }
            // PNG where the application left one: it keeps transparency,
            // which a DIB mostly does not. Otherwise the DIB, as a BMP file.
            source = FormatBytes(PngFormat());
            if (source.empty()) {
                // CF_DIB before CF_DIBV5. A V5 that Windows made from a
                // 32-bit DIB of GDI's, alpha all zero, can carry an alpha mask
                // the decoder honours, and the picture comes out invisible.
                std::vector<unsigned char> dib = FormatBytes(CF_DIB);
                if (dib.empty()) {
                    dib = FormatBytes(CF_DIBV5);
                }
                source = DibAsBmp(dib.data(), dib.size());
            }
        }
        if (source.empty() || !EncodePng(source, g_outgoing.png)) {
            g_outgoing.png.clear();
            Log("[transfer] the clipboard's picture could not be read");
        } else if (g_outgoing.png.size() > kMaxClipboardImageBytes) {
            Log("[transfer] the clipboard's picture is %zu bytes as PNG; not sending it",
                g_outgoing.png.size());
            g_outgoing.png.clear();
        }
    }
    if (g_outgoing.png.empty()) {
        return Error("clipboardImage", "no picture to send");
    }
    const size_t total = g_outgoing.png.size();
    if (offset < 0 || static_cast<unsigned long long>(offset) >= total) {
        return Error("clipboardImage", "offset out of range");
    }
    const size_t start = static_cast<size_t>(offset);
    const size_t length = (std::min)(kTransferChunkBytes, total - start);
    return "{\"type\":\"clipboardImage\",\"ok\":true,\"seq\":" + std::to_string(current)
         + ",\"total\":" + std::to_string(total) + ",\"offset\":" + std::to_string(start)
         + ",\"data\":\"" + Base64Encode(g_outgoing.png.data() + start, length) + "\"}";
}

std::string ClipboardImageSetJson(long long offset, long long total, const std::string& base64) {
    std::lock_guard<std::mutex> guard(g_transfer_mutex);
    if (total <= 0 || static_cast<unsigned long long>(total) > kMaxClipboardImageBytes) {
        return Error("clipboardImage", "too large");
    }
    if (offset == 0) {
        g_incoming.clear();
        g_incoming_total = total;
    }
    std::vector<unsigned char> chunk;
    // The same total throughout: a smaller one part way would finish early
    // with the front of a picture.
    if (total != g_incoming_total
        || static_cast<unsigned long long>(offset) != g_incoming.size()
        || !Base64Decode(base64, chunk) || chunk.size() > kTransferChunkBytes
        || g_incoming.size() + chunk.size() > static_cast<size_t>(total)) {
        g_incoming.clear();
        return Error("clipboardImage", "out of order");
    }
    g_incoming.insert(g_incoming.end(), chunk.begin(), chunk.end());
    if (g_incoming.size() < static_cast<size_t>(total)) {
        return "{\"type\":\"clipboardImage\",\"ok\":true,\"received\":"
             + std::to_string(g_incoming.size()) + "}";
    }

    std::vector<unsigned char> png;
    png.swap(g_incoming);
    std::vector<unsigned char> dib;
    if (!PngToDib(png, dib)) {
        return Error("clipboardImage", "not a picture this PC can read");
    }
    ClipboardLock lock;
    if (!lock.held()) {
        return Error("clipboardImage", "clipboard busy");
    }
    EmptyClipboard();
    // Both: PNG for what reads it and keeps transparency, the DIB for
    // everything else. Windows makes CF_BITMAP and CF_DIBV5 from the DIB.
    const bool asPng = Put(PngFormat(), png.data(), png.size());
    const bool asDib = Put(CF_DIB, dib.data(), dib.size());
    if (!asPng && !asDib) {
        return Error("clipboardImage", "clipboard rejected it");
    }
    return "{\"type\":\"clipboardImage\",\"ok\":true,\"done\":true,\"seq\":"
         + std::to_string(GetClipboardSequenceNumber()) + "}";
}

std::wstring UploadFolder() {
    // The environment rather than SHGetKnownFolderPath, whose folder ids the
    // mingw cross-build does not link (see InstallDirectory). A Downloads
    // moved elsewhere is not followed; the profile's own is always there.
    wchar_t profile[MAX_PATH] = {0};
    if (GetEnvironmentVariableW(L"USERPROFILE", profile, MAX_PATH) == 0) {
        return {};
    }
    const std::wstring downloads = std::wstring(profile) + L"\\Downloads";
    const std::wstring folder = downloads + L"\\SolStream";
    CreateDirectoryW(downloads.c_str(), nullptr);
    CreateDirectoryW(folder.c_str(), nullptr);
    return folder;
}

std::wstring SafeFileName(const std::wstring& name) {
    // The last component only: a name, never a path.
    std::wstring base = name;
    const size_t slash = base.find_last_of(L"\\/");
    if (slash != std::wstring::npos) {
        base = base.substr(slash + 1);
    }
    std::wstring cleaned;
    for (wchar_t c : base) {
        if (c < 32 || std::wcschr(L"<>:\"/\\|?*", c)) {
            cleaned += L'_';
        } else {
            cleaned += c;
        }
    }
    // Windows drops trailing dots and spaces, and a leading dot hides it.
    while (!cleaned.empty() && (cleaned.back() == L'.' || cleaned.back() == L' ')) {
        cleaned.pop_back();
    }
    while (!cleaned.empty() && (cleaned.front() == L'.' || cleaned.front() == L' ')) {
        cleaned.erase(cleaned.begin());
    }
    if (cleaned.empty()) {
        cleaned = L"file";
    }
    // CON, NUL, COM1 and the rest are devices whatever extension follows,
    // and with spaces before it: "nul .txt" is NUL. COM and LPT take any digit
    // and the superscripts one to three.
    std::wstring stem = Lower(cleaned.substr(0, cleaned.find(L'.')));
    while (!stem.empty() && stem.back() == L' ') {
        stem.pop_back();
    }
    static const wchar_t* devices[] = {L"con", L"prn", L"aux", L"nul", L"conin$", L"conout$"};
    bool device = std::any_of(std::begin(devices), std::end(devices),
                              [&](const wchar_t* d) { return stem == d; });
    if (stem.size() == 4 && (stem.rfind(L"com", 0) == 0 || stem.rfind(L"lpt", 0) == 0)
        && ((stem[3] >= L'0' && stem[3] <= L'9') || stem[3] == L'\u00B9' || stem[3] == L'\u00B2'
            || stem[3] == L'\u00B3')) {
        device = true;
    }
    if (device) {
        cleaned = L"_" + cleaned;
    }
    // Long names are cut ahead of their extension, which says what opens it.
    constexpr size_t kMaxName = 120;
    if (cleaned.size() > kMaxName) {
        const size_t dot = cleaned.find_last_of(L'.');
        std::wstring extension = dot != std::wstring::npos && cleaned.size() - dot <= 16
            ? cleaned.substr(dot) : L"";
        size_t keep = kMaxName - extension.size();
        // Not through the middle of an emoji: half of one is a name NTFS takes
        // but the path sent back to the Mac cannot carry, and the file could
        // then not be put on the PC's clipboard.
        if (keep > 0 && cleaned[keep - 1] >= 0xD800 && cleaned[keep - 1] <= 0xDBFF) {
            --keep;
        }
        std::wstring kept = cleaned.substr(0, keep);
        // With nothing after it, a cut that lands on a space or a dot leaves
        // a name Windows strips -- and the path sent back to the Mac, to put
        // on the clipboard, would name a file that is not there.
        if (extension.empty()) {
            while (!kept.empty() && (kept.back() == L'.' || kept.back() == L' ')) {
                kept.pop_back();
            }
            if (kept.empty()) {
                kept = L"file";
            }
        }
        cleaned = kept + extension;
    }
    return cleaned;
}

std::wstring UniqueFilePath(const std::wstring& folder, const std::wstring& name,
                            const std::function<bool(const std::wstring&)>& exists) {
    const std::wstring first = folder + L"\\" + name;
    if (!exists(first)) {
        return first;
    }
    const size_t dot = name.find_last_of(L'.');
    const bool hasExtension = dot != std::wstring::npos && dot > 0;
    const std::wstring stem = hasExtension ? name.substr(0, dot) : name;
    const std::wstring extension = hasExtension ? name.substr(dot) : L"";
    for (int copy = 2; copy < 1000; ++copy) {
        const std::wstring candidate =
            folder + L"\\" + stem + L" (" + std::to_wstring(copy) + L")" + extension;
        if (!exists(candidate)) {
            return candidate;
        }
    }
    return {};
}

bool IsDirectlyInside(const std::wstring& path, const std::wstring& folder) {
    // A NUL ends the path for every API that checks it, and separates the
    // entries of CF_HDROP: "a.txt\0C:secret" would pass as a.txt and paste as
    // two files.
    if (folder.empty() || path.size() <= folder.size() + 1
        || path.find(L'\0') != std::wstring::npos) {
        return false;
    }
    if (Lower(path.substr(0, folder.size())) != Lower(folder) || path[folder.size()] != L'\\') {
        return false;
    }
    const std::wstring rest = path.substr(folder.size() + 1);
    return rest.find_first_of(L"\\/") == std::wstring::npos && rest != L"." && rest != L"..";
}

std::vector<unsigned char> DropFilesData(const std::vector<std::wstring>& paths) {
    std::vector<unsigned char> data(sizeof(DROPFILES));
    DROPFILES header{};
    header.pFiles = sizeof(DROPFILES);
    header.fWide = TRUE;
    std::memcpy(data.data(), &header, sizeof(header));
    for (const std::wstring& path : paths) {
        const auto* bytes = reinterpret_cast<const unsigned char*>(path.c_str());
        data.insert(data.end(), bytes, bytes + (path.size() + 1) * sizeof(wchar_t));
    }
    data.insert(data.end(), sizeof(wchar_t), 0);
    return data;
}

/// An upload turned down for a reason the person who dropped it should read:
/// `reason`, as `quit` says its own, beside the usual `message`.
std::string Refused(const std::string& reason) {
    return "{\"type\":\"upload\",\"ok\":false,\"message\":\"" + JsonEscape(reason)
         + "\",\"reason\":\"" + JsonEscape(reason) + "\"}";
}

std::string UploadRefusal(unsigned long long total, unsigned long long free_bytes) {
    if (total > kMaxUploadBytes) {
        return "That file is too big to send to the PC (the limit is 8 GB).";
    }
    if (free_bytes < kKeepFreeBytes || total > free_bytes - kKeepFreeBytes) {
        return "There isn't enough room on the PC for that file. Free up some space "
               "on its drive and try again.";
    }
    return {};
}

std::string UploadJson(const std::string& name, long long offset, long long total,
                       const std::string& base64) {
    std::lock_guard<std::mutex> guard(g_transfer_mutex);
    if (total < 0) {
        return Error("upload", "bad size");
    }
    if (offset == 0) {
        DropUpload();
        const std::wstring folder = UploadFolder();
        // Before anything is written: a file a paired Mac says is huge, or a
        // run of them, would otherwise go on filling the disk until it was full.
        ULARGE_INTEGER free_bytes{};
        if (!folder.empty()
            && GetDiskFreeSpaceExW(folder.c_str(), &free_bytes, nullptr, nullptr)) {
            const std::string refusal =
                UploadRefusal(static_cast<unsigned long long>(total), free_bytes.QuadPart);
            if (!refusal.empty()) {
                Log("[transfer] refused a %lld-byte file: %s", total, refusal.c_str());
                return Refused(refusal);
            }
        } else if (static_cast<unsigned long long>(total) > kMaxUploadBytes) {
            return Refused(UploadRefusal(static_cast<unsigned long long>(total), ~0ull));
        }
        const std::wstring path = UniqueFilePath(folder, SafeFileName(ToWide(name)),
            [](const std::wstring& candidate) {
                // Taken unless plainly absent: a name still being deleted --
                // the last upload's, held a moment by a scanner -- answers
                // access denied, and CREATE_NEW on it would fail.
                if (GetFileAttributesW(candidate.c_str()) != INVALID_FILE_ATTRIBUTES) {
                    return true;
                }
                const DWORD error = GetLastError();
                return error != ERROR_FILE_NOT_FOUND && error != ERROR_PATH_NOT_FOUND;
            });
        if (folder.empty()) {
            return Refused("The PC has no Downloads folder SolStream can write to.");
        }
        if (path.empty()) {
            return Refused("Downloads\\SolStream on the PC already has too many files with "
                           "this name. Move some out of it, then send it again.");
        }
        HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE | DELETE, 0, nullptr, CREATE_NEW,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
        if (file == INVALID_HANDLE_VALUE) {
            return Error("upload", "could not create the file");
        }
        // Best effort: where it cannot be set, DropUpload still covers every
        // ending but the host's own.
        if (!DeleteWhenClosed(file, true)) {
            Log("[transfer] could not mark the upload to go if the host stops: %lu",
                GetLastError());
        }
        g_upload.file = file;
        g_upload.path = path;
        g_upload.total = static_cast<unsigned long long>(total);
        Log("[transfer] receiving %s, %lld bytes", ToUtf8(path).c_str(), total);
    }
    std::vector<unsigned char> chunk;
    if (g_upload.file == INVALID_HANDLE_VALUE
        || static_cast<unsigned long long>(offset) != g_upload.written
        || static_cast<unsigned long long>(total) != g_upload.total
        || !Base64Decode(base64, chunk) || chunk.size() > kTransferChunkBytes
        || g_upload.written + chunk.size() > g_upload.total) {
        DropUpload();
        return Error("upload", "out of order");
    }
    DWORD wrote = 0;
    if (!chunk.empty()
        && (!WriteFile(g_upload.file, chunk.data(), static_cast<DWORD>(chunk.size()), &wrote,
                       nullptr)
            || wrote != chunk.size())) {
        DropUpload();
        return Error("upload", "could not write the file -- is the disk full?");
    }
    g_upload.written += chunk.size();
    if (g_upload.written < g_upload.total) {
        return "{\"type\":\"upload\",\"ok\":true,\"received\":"
             + std::to_string(g_upload.written) + "}";
    }
    // Kept now it is whole. If that cannot be said, closing would delete it,
    // so it is reported rather than claimed.
    if (!DeleteWhenClosed(g_upload.file, false)) {
        Log("[transfer] could not keep the finished upload: %lu", GetLastError());
        DropUpload();
        return Error("upload", "could not finish the file on the PC");
    }
    CloseHandle(g_upload.file);
    const std::string path = ToUtf8(g_upload.path);
    g_upload = Upload{};
    Log("[transfer] received %s", path.c_str());
    return "{\"type\":\"upload\",\"ok\":true,\"done\":true,\"path\":\"" + JsonEscape(path) + "\"}";
}

std::string ClipboardFilesJson(const std::string& paths) {
    const std::wstring folder = UploadFolder();
    std::vector<std::wstring> files;
    size_t start = 0;
    while (start <= paths.size()) {
        const size_t end = paths.find('\n', start);
        const std::string one = paths.substr(start, end == std::string::npos ? std::string::npos
                                                                             : end - start);
        if (!one.empty()) {
            const std::wstring wide = ToWide(one);
            // Only what an upload put there: the Mac must not be able to put
            // any file on this PC on the clipboard, to be pasted somewhere.
            if (!IsDirectlyInside(wide, folder)
                || GetFileAttributesW(wide.c_str()) == INVALID_FILE_ATTRIBUTES) {
                return Error("clipboardFiles", "not a file SolStream received");
            }
            files.push_back(wide);
        }
        if (end == std::string::npos) {
            break;
        }
        start = end + 1;
    }
    if (files.empty()) {
        return Error("clipboardFiles", "no files");
    }
    const std::vector<unsigned char> drop = DropFilesData(files);
    const DWORD copy = DROPEFFECT_COPY;
    ClipboardLock lock;
    if (!lock.held()) {
        return Error("clipboardFiles", "clipboard busy");
    }
    EmptyClipboard();
    if (!Put(CF_HDROP, drop.data(), drop.size())) {
        return Error("clipboardFiles", "clipboard rejected it");
    }
    // Copy, not move: a paste in Explorer leaves the received file where it is.
    Put(DropEffectFormat(), &copy, sizeof(copy));
    return "{\"type\":\"clipboardFiles\",\"ok\":true,\"seq\":"
         + std::to_string(GetClipboardSequenceNumber()) + "}";
}

}  // namespace solstream
