// token_store.cpp — see token_store.h.

#include "token_store.h"

#include <windows.h>
#include <dpapi.h>

#include "media/log.h"
#include "util.h"

namespace solstream {

namespace {

constexpr wchar_t kPlainName[] = L"agent.token";
constexpr wchar_t kProtectedName[] = L"agent.token.dpapi";

/// Not a secret: it keeps another program calling CryptUnprotectData as this
/// user from reading the blob without knowing it is SolStream's.
constexpr char kEntropy[] = "SolStream pairing token v1";

/// A view of `bytes`, which must outlive it: DPAPI reads through the
/// pointer. Never a temporary -- Blob(std::string(...)) handed it freed
/// memory, different entropy every call, and nothing sealed could be opened.
DATA_BLOB Blob(const std::string& bytes) {
    DATA_BLOB blob{};
    blob.cbData = static_cast<DWORD>(bytes.size());
    blob.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(bytes.data()));
    return blob;
}

DATA_BLOB EntropyBlob() {
    DATA_BLOB blob{};
    blob.cbData = static_cast<DWORD>(sizeof(kEntropy) - 1);
    blob.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(kEntropy));
    return blob;
}

std::string Trimmed(std::string text) {
    while (!text.empty()
           && (text.back() == '\n' || text.back() == '\r' || text.back() == ' ')) {
        text.pop_back();
    }
    return text;
}

/// Written beside it and moved over it, so a crash never leaves half a blob
/// -- which would cost every pairing this PC has.
bool WriteAtomically(const std::wstring& path, const std::string& bytes) {
    const std::wstring temporary = path + L".new";
    if (!WriteWholeFile(temporary, bytes)) {
        DeleteFileW(temporary.c_str());
        return false;
    }
    if (!MoveFileExW(temporary.c_str(), path.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH)) {
        DeleteFileW(temporary.c_str());
        return false;
    }
    return true;
}

/// The plain file gone, its bytes overwritten first: a deleted file's
/// clusters keep what was in them until something else is written there.
/// Overwritten with line ends, which every version trims to nothing: left
/// behind by a delete that failed, it reads as no token at all -- never as one
/// anybody could guess.
void Shred(const std::wstring& path, size_t length) {
    WriteWholeFile(path, std::string(length + 8, '\n'));
    if (!DeleteFileW(path.c_str())) {
        media::Log("[token] could not delete the old plain token file (error %lu); "
                   "its contents were overwritten", GetLastError());
    }
}

bool Exists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

}  // namespace

bool IsTokenText(const std::string& text) {
    if (text.size() < 16 || text.size() > 127) {
        return false;
    }
    for (const char c : text) {
        if (c <= ' ' || c > '~') {
            return false;
        }
    }
    return true;
}

bool ProtectToken(const std::string& token, std::string& blob) {
    DATA_BLOB in = Blob(token);
    DATA_BLOB entropy = EntropyBlob();
    DATA_BLOB out{};
    if (!CryptProtectData(&in, L"SolStream pairing token", &entropy, nullptr, nullptr,
                          CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;
    }
    blob.assign(reinterpret_cast<const char*>(out.pbData), out.cbData);
    LocalFree(out.pbData);
    return true;
}

bool UnprotectToken(const std::string& blob, std::string& token) {
    DATA_BLOB in = Blob(blob);
    DATA_BLOB entropy = EntropyBlob();
    DATA_BLOB out{};
    if (!CryptUnprotectData(&in, nullptr, &entropy, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;
    }
    token.assign(reinterpret_cast<const char*>(out.pbData), out.cbData);
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);
    return true;
}

std::string LoadOrCreateToken(const std::wstring& folder) {
    if (folder.empty()) {
        return {};
    }
    const std::wstring protected_path = folder + L"\\" + kProtectedName;
    const std::wstring plain_path = folder + L"\\" + kPlainName;

    std::string blob, token;
    // There but not readable this moment -- a virus scanner holding it -- is
    // not the same as not there: answered as that, a new token would replace
    // it and every paired Mac would have to pair again. Waited on, and then
    // refused, which keeps the host from starting rather than losing them.
    bool read = ReadSmallFile(protected_path, 4096, blob);
    for (int attempt = 0; !read && Exists(protected_path) && attempt < 10; ++attempt) {
        Sleep(200);
        read = ReadSmallFile(protected_path, 4096, blob);
    }
    if (!read && Exists(protected_path)) {
        media::Log("[token] agent.token.dpapi is there but can't be read (error %lu); "
                   "not replacing it", GetLastError());
        return {};
    }
    if (read && !blob.empty()) {
        if (UnprotectToken(blob, token) && IsTokenText(token)) {
            // A plain copy beside it is one an older host made since; it is
            // not the token this PC pairs with, and must not sit there readable.
            std::string stale;
            if (ReadSmallFile(plain_path, 127, stale)) {
                media::Log("[token] removed a plain token file an older SolStream left; "
                           "the encrypted token is the one this PC pairs with");
                Shred(plain_path, stale.size());
            }
            return token;
        }
        // Another account's, damaged, or -- after an administrator reset this
        // account's password -- no longer openable. Not this host's to read,
        // and kept aside under a name of its own rather than overwritten, in
        // case it is the account that is wrong.
        const DWORD why = GetLastError();
        const std::wstring aside = protected_path + L".unreadable-"
                                 + std::to_wstring(GetTickCount64());
        media::Log("[token] could not decrypt the saved pairing token (error %lu); kept it "
                   "aside and made a new one -- paired Macs will ask for the new token", why);
        MoveFileExW(protected_path.c_str(), aside.c_str(), 0);
    }

    // A plain token from before: moved in, so this PC's pairings carry over.
    std::string plain;
    const bool had_plain = ReadSmallFile(plain_path, 127, plain);
    token = Trimmed(plain);
    const bool migrating = had_plain && IsTokenText(token);
    if (!migrating) {
        token = RandomHex(16);
        if (token.empty()) {
            return {};
        }
    }
    if (ProtectToken(token, blob) && WriteAtomically(protected_path, blob)) {
        if (had_plain) {
            Shred(plain_path, plain.size());
        }
        media::Log(migrating ? "[token] the pairing token is now encrypted for this account"
                             : "[token] made a new pairing token, encrypted for this account");
        return token;
    }
    // DPAPI or the disk refused: still a token the person can pair with,
    // kept as it always was.
    media::Log("[token] could not encrypt the pairing token; keeping it as a plain file");
    if (!migrating) {
        WriteWholeFile(plain_path, token);
    }
    return token;
}

}  // namespace solstream
