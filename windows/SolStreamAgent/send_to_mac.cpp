// send_to_mac.cpp — see send_to_mac.h.

#include "send_to_mac.h"

#include <windows.h>
#include <shlobj.h>

#include <map>
#include <mutex>
#include <vector>

#include "media/log.h"
#include "transfer.h"
#include "util.h"

namespace solstream {

namespace {

struct Offer {
    std::wstring path;
    unsigned long long size = 0;
    ULONGLONG made = 0;
    /// Which file it was, and as it was, when offered: the path is opened
    /// again for every chunk, and one saved over or swapped for another since
    /// would otherwise arrive as a mix of the two and be called whole.
    DWORD volume = 0;
    unsigned long long index = 0;
    FILETIME written{};
};

/// Opened to be read, sharing with whoever else has it open.
HANDLE OpenForSending(const std::wstring& path) {
    return CreateFileW(path.c_str(), GENERIC_READ,
                       FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                       OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
}

/// Why a file that exists can't be read, in words for the person who sent it.
std::string UnreadableReason(DWORD error) {
    switch (error) {
        case ERROR_SHARING_VIOLATION:
        case ERROR_LOCK_VIOLATION:
            return "Another app on the PC has that file locked. Close it there, then send "
                   "the file again.";
        case ERROR_ACCESS_DENIED:
            return "SolStream isn't allowed to read that file on the PC.";
        case ERROR_FILE_NOT_FOUND:
        case ERROR_PATH_NOT_FOUND:
            return "The file was moved or deleted on the PC before it was sent.";
        default:
            return "SolStream couldn't read that file on the PC (error " + std::to_string(error)
                 + ").";
    }
}

std::mutex g_offers_cs;
std::map<uint64_t, Offer> g_offers;  // guarded by g_offers_cs
uint64_t g_next_offer = 1;           // guarded by g_offers_cs

constexpr ULONGLONG kOfferLifetimeMs = 30 * 60 * 1000;
constexpr size_t kMaxOffers = 16;
constexpr wchar_t kVerbKey[] = L"Classes\\*\\shell\\SolStream.SendToMac";

/// Offers past their half hour. Call with g_offers_cs held.
void ForgetExpired(ULONGLONG now) {
    for (auto it = g_offers.begin(); it != g_offers.end();) {
        it = now - it->second.made >= kOfferLifetimeMs ? g_offers.erase(it) : std::next(it);
    }
}

constexpr char kChanged[] =
    "The file changed on the PC while it was being sent. Send it again once it's saved.";

std::string Fail(const std::string& message) {
    return "{\"type\":\"download\",\"ok\":false,\"message\":\"" + JsonEscape(message) + "\"}";
}

bool SetString(HKEY root, const std::wstring& key, const wchar_t* name,
               const std::wstring& value) {
    HKEY handle = nullptr;
    if (RegCreateKeyExW(root, key.c_str(), 0, nullptr, 0, KEY_WRITE | KEY_WOW64_64KEY, nullptr,
                        &handle, nullptr) != ERROR_SUCCESS) {
        return false;
    }
    const bool ok = RegSetValueExW(handle, name, 0, REG_SZ,
                                   reinterpret_cast<const BYTE*>(value.c_str()),
                                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)))
                    == ERROR_SUCCESS;
    RegCloseKey(handle);
    return ok;
}

}  // namespace

std::string FileOfferRefusal(const std::wstring& path, unsigned long long* size_out) {
    WIN32_FILE_ATTRIBUTE_DATA info{};
    if (path.empty() || !GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &info)) {
        return "SolStream couldn't find that file. It may have been moved or renamed.";
    }
    if (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
        return "SolStream sends files, not folders. Zip the folder first, then send that.";
    }
    const unsigned long long size =
        (static_cast<unsigned long long>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    if (size > kMaxUploadBytes) {
        return "That file is too big to send to the Mac (the limit is 8 GB).";
    }
    // Opened once now, so that a file another app keeps locked -- a mailbox, a
    // database -- is turned down here, in words, rather than offered and then
    // failing at its first chunk with nothing to say but "send it again".
    HANDLE file = OpenForSending(path);
    if (file == INVALID_HANDLE_VALUE) {
        return UnreadableReason(GetLastError());
    }
    CloseHandle(file);
    if (size_out) {
        *size_out = size;
    }
    return {};
}

uint64_t AddFileOffer(const std::wstring& path, std::string& error) {
    unsigned long long size = 0;
    error = FileOfferRefusal(path, &size);
    if (!error.empty()) {
        return 0;
    }
    Offer offer{path, size, 0};
    HANDLE file = OpenForSending(path);
    BY_HANDLE_FILE_INFORMATION info{};
    if (file == INVALID_HANDLE_VALUE || !GetFileInformationByHandle(file, &info)) {
        error = UnreadableReason(GetLastError());
        if (file != INVALID_HANDLE_VALUE) CloseHandle(file);
        return 0;
    }
    CloseHandle(file);
    offer.size = (static_cast<unsigned long long>(info.nFileSizeHigh) << 32) | info.nFileSizeLow;
    if (offer.size > kMaxUploadBytes) {
        error = "That file is too big to send to the Mac (the limit is 8 GB).";
        return 0;
    }
    offer.volume = info.dwVolumeSerialNumber;
    offer.index = (static_cast<unsigned long long>(info.nFileIndexHigh) << 32) | info.nFileIndexLow;
    offer.written = info.ftLastWriteTime;
    std::lock_guard<std::mutex> lock(g_offers_cs);
    const ULONGLONG now = GetTickCount64();
    ForgetExpired(now);
    if (g_offers.size() >= kMaxOffers) {
        error = "SolStream is already sending 16 files. Wait for them to arrive, then "
                "send the rest.";
        return 0;
    }
    const uint64_t id = g_next_offer++;
    offer.made = now;
    g_offers[id] = offer;
    return id;
}

std::string FileOfferJson(uint64_t id) {
    std::lock_guard<std::mutex> lock(g_offers_cs);
    const auto found = g_offers.find(id);
    if (found == g_offers.end()) {
        return {};
    }
    const std::wstring& path = found->second.path;
    const size_t slash = path.find_last_of(L"\\/");
    const std::string name = ToUtf8(slash == std::wstring::npos ? path : path.substr(slash + 1));
    return "{\"type\":\"fileOffer\",\"id\":" + std::to_string(id) + ",\"name\":\""
         + JsonEscape(name) + "\",\"size\":" + std::to_string(found->second.size) + "}";
}

std::string DownloadJson(long long id, long long offset) {
    Offer offer;
    {
        std::lock_guard<std::mutex> lock(g_offers_cs);
        ForgetExpired(GetTickCount64());
        const auto found = id > 0 ? g_offers.find(static_cast<uint64_t>(id)) : g_offers.end();
        if (found == g_offers.end()) {
            return Fail("The PC no longer has that file on offer. Send it again from the PC.");
        }
        // Every open offer, not only this one: the Mac fetches one file at a
        // time, and a small file sent after a large one waits its turn for as
        // long as the large one takes.
        const ULONGLONG now = GetTickCount64();
        for (auto& open : g_offers) {
            open.second.made = now;
        }
        offer = found->second;
    }
    if (offset < 0 || static_cast<unsigned long long>(offset) > offer.size
        || (offer.size > 0 && static_cast<unsigned long long>(offset) == offer.size)) {
        return Fail("The Mac asked for a part of the file that isn't there. Send it again "
                    "from the PC.");
    }
    // Read where it is now, sharing with whoever has it open -- but only if it
    // is still the file that was offered, as it was then.
    HANDLE file = OpenForSending(offer.path);
    if (file == INVALID_HANDLE_VALUE) {
        return Fail(UnreadableReason(GetLastError()));
    }
    BY_HANDLE_FILE_INFORMATION info{};
    const bool same = GetFileInformationByHandle(file, &info)
        && info.dwVolumeSerialNumber == offer.volume
        && ((static_cast<unsigned long long>(info.nFileIndexHigh) << 32) | info.nFileIndexLow)
               == offer.index
        && ((static_cast<unsigned long long>(info.nFileSizeHigh) << 32) | info.nFileSizeLow)
               == offer.size
        && CompareFileTime(&info.ftLastWriteTime, &offer.written) == 0;
    if (!same) {
        CloseHandle(file);
        return Fail(kChanged);
    }
    const size_t length = static_cast<size_t>(
        (std::min)(static_cast<unsigned long long>(kTransferChunkBytes),
                   offer.size - static_cast<unsigned long long>(offset)));
    std::vector<unsigned char> chunk(length);
    LARGE_INTEGER at{};
    at.QuadPart = offset;
    DWORD read = 0;
    bool ok = SetFilePointerEx(file, at, nullptr, FILE_BEGIN) != FALSE;
    const bool read_ok = ok && (length == 0
        || ReadFile(file, chunk.data(), static_cast<DWORD>(length), &read, nullptr));
    const DWORD error = read_ok ? 0 : GetLastError();
    CloseHandle(file);
    if (!read_ok) {
        // A region another app holds locked fails here, not at the open.
        return Fail(ok ? UnreadableReason(error) : kChanged);
    }
    if (read != length) {
        return Fail(kChanged);
    }
    if (static_cast<unsigned long long>(offset) + length == offer.size) {
        std::lock_guard<std::mutex> lock(g_offers_cs);
        g_offers.erase(static_cast<uint64_t>(id));
    }
    return "{\"type\":\"download\",\"ok\":true,\"id\":" + std::to_string(id)
         + ",\"total\":" + std::to_string(offer.size) + ",\"offset\":" + std::to_string(offset)
         + ",\"data\":\"" + Base64Encode(chunk.data(), chunk.size()) + "\"}";
}

void ForgetFileOffer(uint64_t id) {
    std::lock_guard<std::mutex> lock(g_offers_cs);
    g_offers.erase(id);
}

void RegisterSendToMac(const std::wstring& exe) {
    const std::wstring key = std::wstring(L"SOFTWARE\\") + kVerbKey;
    bool ok = SetString(HKEY_LOCAL_MACHINE, key, nullptr, L"Send to Mac");
    ok = SetString(HKEY_LOCAL_MACHINE, key, L"Icon", exe + L",0") && ok;
    ok = SetString(HKEY_LOCAL_MACHINE, key + L"\\command", nullptr,
                   L"\"" + exe + L"\" --send-to-mac \"%1\"") && ok;
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
    media::Log(ok ? "[install] added Send to Mac to the right-click menu for files"
                  : "[install] could not add Send to Mac to the right-click menu");
}

void RemoveSendToMac() {
    HKEY software = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, L"SOFTWARE", 0, KEY_ALL_ACCESS | KEY_WOW64_64KEY,
                      &software) == ERROR_SUCCESS) {
        RegDeleteTreeW(software, kVerbKey);
        RegCloseKey(software);
    }
    SHChangeNotify(SHCNE_ASSOCCHANGED, SHCNF_IDLIST, nullptr, nullptr);
}

}  // namespace solstream
