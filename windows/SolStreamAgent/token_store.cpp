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

DATA_BLOB Blob(const std::string& bytes) {
    DATA_BLOB blob{};
    blob.cbData = static_cast<DWORD>(bytes.size());
    blob.pbData = reinterpret_cast<BYTE*>(const_cast<char*>(bytes.data()));
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
void Shred(const std::wstring& path, size_t length) {
    WriteWholeFile(path, std::string(length + 8, '0'));
    DeleteFileW(path.c_str());
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
    DATA_BLOB entropy = Blob(std::string(kEntropy));
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
    DATA_BLOB entropy = Blob(std::string(kEntropy));
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
    if (ReadSmallFile(protected_path, 4096, blob) && !blob.empty()) {
        if (UnprotectToken(blob, token) && IsTokenText(token)) {
            // A plain copy beside it is one an older host made since; it is
            // not the token this PC pairs with, and must not sit there readable.
            std::string stale;
            if (ReadSmallFile(plain_path, 127, stale)) {
                Shred(plain_path, stale.size());
            }
            return token;
        }
        // Another account's, or damaged: not this host's to read. Kept aside
        // rather than overwritten, in case it is the account that is wrong.
        media::Log("[token] could not read the saved pairing token; keeping it as "
                   "agent.token.dpapi.unreadable and making a new one");
        MoveFileExW(protected_path.c_str(), (protected_path + L".unreadable").c_str(),
                    MOVEFILE_REPLACE_EXISTING);
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
