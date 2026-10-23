// updater.cpp — see updater.h, and docs/updates.md for the contract.
//
// Three things here are load-bearing and easy to "simplify" away:
//
//  - Redirects are followed by hand. WinHTTP's own policy follows any HTTPS
//    redirect anywhere; the contract allows four GitHub hosts and nothing else,
//    so every hop -- the first one included -- is checked against that list.
//  - The token goes to api.github.com and nowhere else. An asset fetched with
//    it is answered by a redirect to a pre-signed storage URL, which rejects a
//    second credential and has no business seeing the first.
//  - The installer is hashed through a handle that shares read access only, and
//    that handle stays open until the elevated installer has started and taken
//    the same hold on itself. Without write or delete sharing nothing can
//    change, rename or replace the file in between; and it is started by the
//    path that handle resolves to (PinPath), not the one it was opened by, so
//    no junction or link can be re-pointed in between either. The bytes that
//    were checked are the bytes that run elevated -- and the bytes it copies.
//    What loads BESIDE them is CMakeLists.txt's /DEPENDENTLOADFLAG and
//    main.cpp's SetDefaultDllDirectories: the Updates folder is the user's.

// Windows 10, as main.cpp says, so the SDK declares BCryptHash; and std::min
// rather than windows.h's macro.
#ifndef _WIN32_WINNT
#define _WIN32_WINNT 0x0A00
#endif
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include "updater.h"

#include <winhttp.h>
#include <bcrypt.h>
#include <shellapi.h>
#include <objbase.h>

#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <cwchar>
#include <mutex>
#include <thread>

#include "media/log.h"
#include "util.h"

// Newer than some SDKs this is built against; the values are fixed.
#ifndef WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY
#define WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY 4
#endif
#ifndef WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3
#define WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3 0x00002000
#endif
#ifndef STATUS_INVALID_SIGNATURE
#define STATUS_INVALID_SIGNATURE ((NTSTATUS) 0xC000A000L)
#endif

namespace solstream::update {
namespace {

using media::Log;

constexpr unsigned long long kMaxInstallerBytes = 200ull * 1024 * 1024;
/// A release's JSON is tens of kilobytes; most of it is the release notes.
constexpr size_t kMaxReleaseJson = 2 * 1024 * 1024;
constexpr size_t kMaxSumsBytes = 64 * 1024;
constexpr size_t kMaxSignatureBytes = 4 * 1024;
constexpr int kMaxRedirects = 5;

/// docs/updates.md, "redirects only to". Every request's host is checked
/// against this, not only a redirect's.
constexpr const wchar_t* kAllowedHosts[] = {
    L"github.com",
    L"api.github.com",
    L"objects.githubusercontent.com",
    L"release-assets.githubusercontent.com",
};
constexpr wchar_t kApiHost[] = L"api.github.com";

std::string Trim(const std::string& text) {
    const char* space = " \t\r\n";
    const size_t first = text.find_first_not_of(space);
    if (first == std::string::npos) {
        return {};
    }
    const size_t last = text.find_last_not_of(space);
    return text.substr(first, last - first + 1);
}

// ── JSON ─────────────────────────────────────────────────────────────────────
//
// A whole parser rather than a search for "tag_name": the release notes are
// free text inside the same document, and a search can be pointed at a key
// somebody typed into them. Parsing to a tree means a key is only ever a key.

struct Json {
    enum class Kind { Null, Bool, Number, String, Array, Object };
    Kind kind = Kind::Null;
    bool boolean = false;
    std::string text;               ///< a string's value, or a number as written
    std::vector<Json> items;        ///< an array's elements
    std::vector<std::string> keys;  ///< an object's member names...
    std::vector<Json> values;       ///< ...and, at the same index, their values
};

class JsonReader {
  public:
    explicit JsonReader(const std::string& text) : text_(text) {}
    JsonReader(const JsonReader&) = delete;
    JsonReader& operator=(const JsonReader&) = delete;

    bool Document(Json& out) {
        SkipSpace();
        if (!Value(out, 0)) {
            return false;
        }
        SkipSpace();
        return at_ == text_.size();
    }

  private:
    /// Deep enough for anything GitHub sends, shallow enough that a hostile
    /// document of nested brackets cannot exhaust the stack.
    static constexpr int kMaxDepth = 64;

    bool More() const { return at_ < text_.size(); }
    char Peek() const { return text_[at_]; }

    void SkipSpace() {
        while (More() && (Peek() == ' ' || Peek() == '\t' || Peek() == '\n' || Peek() == '\r')) {
            ++at_;
        }
    }

    bool Eat(char c) {
        if (More() && Peek() == c) {
            ++at_;
            return true;
        }
        return false;
    }

    bool Word(const char* word) {
        const size_t length = std::strlen(word);
        if (text_.compare(at_, length, word) != 0) {
            return false;
        }
        at_ += length;
        return true;
    }

    bool Digit() {
        if (More() && Peek() >= '0' && Peek() <= '9') {
            ++at_;
            return true;
        }
        return false;
    }

    bool Value(Json& out, int depth) {
        if (depth > kMaxDepth || !More()) {
            return false;
        }
        switch (Peek()) {
            case '{': return Object(out, depth);
            case '[': return Array(out, depth);
            case '"':
                out.kind = Json::Kind::String;
                return String(out.text);
            case 't':
                out.kind = Json::Kind::Bool;
                out.boolean = true;
                return Word("true");
            case 'f':
                out.kind = Json::Kind::Bool;
                out.boolean = false;
                return Word("false");
            case 'n':
                out.kind = Json::Kind::Null;
                return Word("null");
            default:
                out.kind = Json::Kind::Number;
                return Number(out.text);
        }
    }

    bool Object(Json& out, int depth) {
        ++at_;  // {
        out.kind = Json::Kind::Object;
        SkipSpace();
        if (Eat('}')) {
            return true;
        }
        for (;;) {
            SkipSpace();
            std::string key;
            if (!More() || Peek() != '"' || !String(key)) {
                return false;
            }
            SkipSpace();
            if (!Eat(':')) {
                return false;
            }
            SkipSpace();
            Json value;
            if (!Value(value, depth + 1)) {
                return false;
            }
            out.keys.push_back(std::move(key));
            out.values.push_back(std::move(value));
            SkipSpace();
            if (Eat(',')) {
                continue;
            }
            return Eat('}');
        }
    }

    bool Array(Json& out, int depth) {
        ++at_;  // [
        out.kind = Json::Kind::Array;
        SkipSpace();
        if (Eat(']')) {
            return true;
        }
        for (;;) {
            SkipSpace();
            Json value;
            if (!Value(value, depth + 1)) {
                return false;
            }
            out.items.push_back(std::move(value));
            SkipSpace();
            if (Eat(',')) {
                continue;
            }
            return Eat(']');
        }
    }

    bool Hex4(unsigned& out) {
        if (text_.size() - at_ < 4) {
            return false;
        }
        out = 0;
        for (int i = 0; i < 4; ++i) {
            const char c = text_[at_++];
            out <<= 4;
            if (c >= '0' && c <= '9') { out |= (unsigned) (c - '0'); }
            else if (c >= 'a' && c <= 'f') { out |= (unsigned) (c - 'a' + 10); }
            else if (c >= 'A' && c <= 'F') { out |= (unsigned) (c - 'A' + 10); }
            else { return false; }
        }
        return true;
    }

    static void AppendUtf8(std::string& out, unsigned code) {
        if (code < 0x80) {
            out.push_back((char) code);
        } else if (code < 0x800) {
            out.push_back((char) (0xC0 | (code >> 6)));
            out.push_back((char) (0x80 | (code & 0x3F)));
        } else if (code < 0x10000) {
            out.push_back((char) (0xE0 | (code >> 12)));
            out.push_back((char) (0x80 | ((code >> 6) & 0x3F)));
            out.push_back((char) (0x80 | (code & 0x3F)));
        } else {
            out.push_back((char) (0xF0 | (code >> 18)));
            out.push_back((char) (0x80 | ((code >> 12) & 0x3F)));
            out.push_back((char) (0x80 | ((code >> 6) & 0x3F)));
            out.push_back((char) (0x80 | (code & 0x3F)));
        }
    }

    bool String(std::string& out) {
        ++at_;  // the opening quote
        out.clear();
        while (More()) {
            const unsigned char c = (unsigned char) text_[at_++];
            if (c == '"') {
                return true;
            }
            if (c < 0x20) {
                return false;  // a raw control character is not JSON
            }
            if (c != '\\') {
                out.push_back((char) c);
                continue;
            }
            if (!More()) {
                return false;
            }
            switch (text_[at_++]) {
                case '"': out.push_back('"'); break;
                case '\\': out.push_back('\\'); break;
                case '/': out.push_back('/'); break;
                case 'b': out.push_back('\b'); break;
                case 'f': out.push_back('\f'); break;
                case 'n': out.push_back('\n'); break;
                case 'r': out.push_back('\r'); break;
                case 't': out.push_back('\t'); break;
                case 'u': {
                    unsigned code = 0;
                    if (!Hex4(code)) {
                        return false;
                    }
                    // A surrogate is only half a character. Paired, the two
                    // halves are one code point; alone, it is U+FFFD rather than
                    // a reason to throw the whole release away -- it can only be
                    // in somebody's release notes.
                    if (code >= 0xD800 && code <= 0xDBFF) {
                        const size_t mark = at_;
                        unsigned low = 0;
                        if (Eat('\\') && Eat('u') && Hex4(low) && low >= 0xDC00
                            && low <= 0xDFFF) {
                            code = 0x10000 + ((code - 0xD800) << 10) + (low - 0xDC00);
                        } else {
                            at_ = mark;
                            code = 0xFFFD;
                        }
                    } else if (code >= 0xDC00 && code <= 0xDFFF) {
                        code = 0xFFFD;
                    }
                    AppendUtf8(out, code);
                    break;
                }
                default:
                    return false;
            }
        }
        return false;  // ran out before the closing quote
    }

    /// -?(0|[1-9][0-9]*)(\.[0-9]+)?([eE][+-]?[0-9]+)?, kept as written.
    bool Number(std::string& out) {
        const size_t start = at_;
        Eat('-');
        if (!Eat('0')) {
            if (!Digit()) {
                return false;
            }
            while (Digit()) {}
        }
        if (Eat('.')) {
            if (!Digit()) {
                return false;
            }
            while (Digit()) {}
        }
        if (Eat('e') || Eat('E')) {
            if (!Eat('+')) {
                Eat('-');
            }
            if (!Digit()) {
                return false;
            }
            while (Digit()) {}
        }
        out.assign(text_, start, at_ - start);
        return true;
    }

    const std::string& text_;
    size_t at_ = 0;
};

/// The member called `key`. False when the object names it twice: a document
/// that says two things about the same field is not one to act on, and quietly
/// taking either would be choosing which one to believe.
bool Member(const Json& object, const char* key, const Json*& out) {
    out = nullptr;
    for (size_t i = 0; i < object.keys.size(); ++i) {
        if (object.keys[i] == key) {
            if (out != nullptr) {
                return false;
            }
            out = &object.values[i];
        }
    }
    return true;
}

bool StringMember(const Json& object, const char* key, bool required, std::string& out,
                  std::string& error) {
    const Json* field = nullptr;
    if (!Member(object, key, field)) {
        error = std::string("\"") + key + "\" appears twice";
        return false;
    }
    if (field == nullptr || field->kind == Json::Kind::Null) {
        if (required) {
            error = std::string("no \"") + key + "\"";
            return false;
        }
        out.clear();
        return true;
    }
    if (field->kind != Json::Kind::String) {
        error = std::string("\"") + key + "\" is not a string";
        return false;
    }
    out = field->text;
    return true;
}

bool BoolMember(const Json& object, const char* key, bool& out, std::string& error) {
    const Json* field = nullptr;
    if (!Member(object, key, field)) {
        error = std::string("\"") + key + "\" appears twice";
        return false;
    }
    if (field == nullptr) {
        out = false;
        return true;
    }
    if (field->kind != Json::Kind::Bool) {
        error = std::string("\"") + key + "\" is not true or false";
        return false;
    }
    out = field->boolean;
    return true;
}

// ── Hashing ──────────────────────────────────────────────────────────────────

bool Sha256(const unsigned char* data, size_t size, unsigned char digest[32]) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, 0))) {
        return false;
    }
    const bool ok = BCRYPT_SUCCESS(BCryptHash(algorithm, nullptr, 0,
                                              const_cast<unsigned char*>(data),
                                              (ULONG) size, digest, 32));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok;
}

/// SHA-256 of everything `file` holds, read through that handle from the start.
bool HashFile(HANDLE file, std::string& hex, std::string& error) {
    LARGE_INTEGER start{};
    if (!SetFilePointerEx(file, start, nullptr, FILE_BEGIN)) {
        error = "could not rewind the download";
        return false;
    }
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    BCRYPT_HASH_HANDLE hash = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, 0))) {
        error = "SHA-256 is unavailable";
        return false;
    }
    bool ok = BCRYPT_SUCCESS(BCryptCreateHash(algorithm, &hash, nullptr, 0, nullptr, 0, 0));
    std::vector<unsigned char> buffer(256 * 1024);
    while (ok) {
        DWORD read = 0;
        if (!ReadFile(file, buffer.data(), (DWORD) buffer.size(), &read, nullptr)) {
            error = "could not read the download back (error "
                  + std::to_string(GetLastError()) + ")";
            ok = false;
            break;
        }
        if (read == 0) {
            break;
        }
        ok = BCRYPT_SUCCESS(BCryptHashData(hash, buffer.data(), read, 0));
    }
    unsigned char digest[32] = {0};
    if (ok) {
        ok = BCRYPT_SUCCESS(BCryptFinishHash(hash, digest, sizeof(digest), 0));
    }
    if (hash) {
        BCryptDestroyHash(hash);
    }
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (!ok) {
        if (error.empty()) {
            error = "could not hash the download";
        }
        return false;
    }
    hex = ToHex(digest, sizeof(digest));
    return true;
}

// ── HTTP ─────────────────────────────────────────────────────────────────────

/// A WinHTTP handle that closes itself.
class Internet {
  public:
    explicit Internet(HINTERNET handle = nullptr) : handle_(handle) {}
    ~Internet() {
        if (handle_) {
            WinHttpCloseHandle(handle_);
        }
    }
    Internet(Internet&& other) noexcept : handle_(other.handle_) { other.handle_ = nullptr; }
    Internet(const Internet&) = delete;
    Internet& operator=(const Internet&) = delete;
    Internet& operator=(Internet&&) = delete;

    HINTERNET get() const { return handle_; }
    explicit operator bool() const { return handle_ != nullptr; }

  private:
    HINTERNET handle_;
};

/// SOLSTREAM_GITHUB_TOKEN, for one check, and wiped when it is done with.
///
/// Read from the environment and nowhere else -- never stored, never logged,
/// never shown (docs/updates.md). The most any log line says is whether there
/// was one. Characters a token cannot contain are refused rather than sent,
/// because whatever is here is pasted into a request header.
class Token {
  public:
    Token() {
        const DWORD needed = GetEnvironmentVariableW(L"SOLSTREAM_GITHUB_TOKEN", nullptr, 0);
        if (needed <= 1) {
            return;
        }
        if (needed > 4096) {
            Log("[update] SOLSTREAM_GITHUB_TOKEN is too long to be a token; ignoring it");
            return;
        }
        value_.assign(needed, L'\0');
        const DWORD got = GetEnvironmentVariableW(L"SOLSTREAM_GITHUB_TOKEN", value_.data(),
                                                  needed);
        if (got == 0 || got >= needed) {
            Wipe();
            return;
        }
        value_.resize(got);
        for (const wchar_t c : value_) {
            if (c < 0x21 || c > 0x7E) {
                Log("[update] SOLSTREAM_GITHUB_TOKEN holds characters no token has; "
                    "ignoring it");
                Wipe();
                return;
            }
        }
    }
    ~Token() { Wipe(); }
    Token(const Token&) = delete;
    Token& operator=(const Token&) = delete;

    bool present() const { return !value_.empty(); }

    /// The header line, written into `out`. The caller wipes it after use.
    void Header(std::wstring& out) const {
        out.clear();
        out.reserve(32 + value_.size());
        out += L"Authorization: Bearer ";
        out += value_;
        out += L"\r\n";
    }

  private:
    void Wipe() {
        if (!value_.empty()) {
            SecureZeroMemory(value_.data(), value_.size() * sizeof(wchar_t));
        }
        value_.clear();
    }

    std::wstring value_;
};

void WipeText(std::wstring& text) {
    if (!text.empty()) {
        SecureZeroMemory(text.data(), text.size() * sizeof(wchar_t));
    }
    text.clear();
}

std::string WinHttpProblem(const char* what, DWORD code) {
    // The handful anyone will actually see, in words; the rest by number.
    const char* meaning = nullptr;
    switch (code) {
        case ERROR_WINHTTP_NAME_NOT_RESOLVED: meaning = "the name did not resolve"; break;
        case ERROR_WINHTTP_CANNOT_CONNECT: meaning = "could not connect"; break;
        case ERROR_WINHTTP_TIMEOUT: meaning = "timed out"; break;
        case ERROR_WINHTTP_SECURE_FAILURE: meaning = "the TLS certificate was refused"; break;
        case ERROR_WINHTTP_CONNECTION_ERROR: meaning = "the connection dropped"; break;
        default: break;
    }
    return std::string(what) + ": " + (meaning ? meaning : "WinHTTP error")
         + " (" + std::to_string(code) + ")";
}

Internet OpenSession(std::string& error) {
    // The compiled version, not a pretended one: this names the program that
    // is actually making the request.
    const std::wstring agent =
        L"SolStream/" + ToWide(SOLSTREAM_VERSION_STRING) + L" (Windows)";
    // The system's proxy settings, PAC files included. AUTOMATIC_PROXY is
    // Windows 8.1 and later; DEFAULT_PROXY is the fallback before that.
    HINTERNET session = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_AUTOMATIC_PROXY,
                                    WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    if (!session) {
        session = WinHttpOpen(agent.c_str(), WINHTTP_ACCESS_TYPE_DEFAULT_PROXY,
                              WINHTTP_NO_PROXY_NAME, WINHTTP_NO_PROXY_BYPASS, 0);
    }
    if (!session) {
        error = WinHttpProblem("WinHttpOpen", GetLastError());
        return Internet();
    }
    // Resolve, connect, send, receive. Generous on receive: a 200 MB installer
    // over a slow link is many reads, and this bounds each one, not the total.
    WinHttpSetTimeouts(session, 15000, 15000, 30000, 60000);
    // TLS 1.2 and 1.3 only. A Windows that does not know 1.3 refuses the pair,
    // and 1.2 alone is still all GitHub needs.
    DWORD protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2 | WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_3;
    if (!WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols,
                          sizeof(protocols))) {
        protocols = WINHTTP_FLAG_SECURE_PROTOCOL_TLS1_2;
        WinHttpSetOption(session, WINHTTP_OPTION_SECURE_PROTOCOLS, &protocols,
                         sizeof(protocols));
    }
    // A default for every request. Best effort here: Get() sets it again on each
    // request and refuses to send one that does not take it, which is the
    // setting that counts.
    DWORD never = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
    WinHttpSetOption(session, WINHTTP_OPTION_REDIRECT_POLICY, &never, sizeof(never));
    return Internet(session);
}

struct Target {
    std::wstring host;
    INTERNET_PORT port = INTERNET_DEFAULT_HTTPS_PORT;
    std::wstring path;  ///< path and query, as sent
};

bool HostAllowed(const std::wstring& host) {
    const std::wstring folded = FoldCase(host);
    for (const wchar_t* allowed : kAllowedHosts) {
        if (folded == allowed) {
            return true;
        }
    }
    return false;
}

/// Where a URL points, if it is somewhere this updater may go: HTTPS, port 443,
/// no credentials in the URL, and one of the four hosts.
bool Resolve(const std::wstring& url, Target& out, std::string& error) {
    URL_COMPONENTS parts{};
    parts.dwStructSize = sizeof(parts);
    // Non-zero lengths with null pointers: point into `url` rather than copy.
    parts.dwSchemeLength = (DWORD) -1;
    parts.dwHostNameLength = (DWORD) -1;
    parts.dwUserNameLength = (DWORD) -1;
    parts.dwPasswordLength = (DWORD) -1;
    parts.dwUrlPathLength = (DWORD) -1;
    parts.dwExtraInfoLength = (DWORD) -1;
    if (!WinHttpCrackUrl(url.c_str(), (DWORD) url.size(), 0, &parts)) {
        error = "not a URL";
        return false;
    }
    if (parts.nScheme != INTERNET_SCHEME_HTTPS) {
        error = "not HTTPS";
        return false;
    }
    if (parts.dwUserNameLength != 0 || parts.dwPasswordLength != 0) {
        error = "a URL with credentials in it";
        return false;
    }
    out.host.clear();
    if (parts.lpszHostName && parts.dwHostNameLength) {
        out.host.assign(parts.lpszHostName, parts.dwHostNameLength);
    }
    if (!HostAllowed(out.host)) {
        // The host only: a redirect's query string is a pre-signed credential.
        error = "a host outside GitHub (" + ToUtf8(out.host) + ")";
        return false;
    }
    if (parts.nPort != INTERNET_DEFAULT_HTTPS_PORT) {
        error = "a port other than 443";
        return false;
    }
    out.port = parts.nPort;
    out.path.clear();
    if (parts.lpszUrlPath && parts.dwUrlPathLength) {
        out.path.assign(parts.lpszUrlPath, parts.dwUrlPathLength);
    }
    if (parts.lpszExtraInfo && parts.dwExtraInfoLength) {
        out.path.append(parts.lpszExtraInfo, parts.dwExtraInfoLength);
    }
    if (out.path.empty()) {
        out.path = L"/";
    }
    return true;
}

std::wstring QueryText(HINTERNET request, DWORD what) {
    DWORD bytes = 0;
    WinHttpQueryHeaders(request, what, WINHTTP_HEADER_NAME_BY_INDEX, WINHTTP_NO_OUTPUT_BUFFER,
                        &bytes, WINHTTP_NO_HEADER_INDEX);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes == 0 || bytes > 64 * 1024) {
        return {};
    }
    std::wstring text(bytes / sizeof(wchar_t), L'\0');
    if (!WinHttpQueryHeaders(request, what, WINHTTP_HEADER_NAME_BY_INDEX, text.data(), &bytes,
                             WINHTTP_NO_HEADER_INDEX)) {
        return {};
    }
    text.resize(bytes / sizeof(wchar_t));
    return text;
}

/// True when the response on `request` came from `target`'s host: WinHTTP's own
/// record of the URL it ended up at, checked like any URL this updater fetches.
bool AnsweredBy(HINTERNET request, const Target& target, std::string& error) {
    DWORD bytes = 0;
    WinHttpQueryOption(request, WINHTTP_OPTION_URL, nullptr, &bytes);
    if (GetLastError() != ERROR_INSUFFICIENT_BUFFER || bytes == 0 || bytes > 64 * 1024) {
        error = WinHttpProblem("read back the request's URL", GetLastError());
        return false;
    }
    std::wstring url(bytes / sizeof(wchar_t), L'\0');
    if (!WinHttpQueryOption(request, WINHTTP_OPTION_URL, url.data(), &bytes)) {
        error = WinHttpProblem("read back the request's URL", GetLastError());
        return false;
    }
    url.resize(wcsnlen(url.c_str(), url.size()));
    Target answered;
    std::string why;
    if (!Resolve(url, answered, why)) {
        error = "an answer from " + why;
        return false;
    }
    if (FoldCase(answered.host) != FoldCase(target.host)) {
        error = "asked " + ToUtf8(target.host) + " and was answered by "
              + ToUtf8(answered.host);
        return false;
    }
    return true;
}

enum class Accept { Api, Binary, Any };

using Sink = std::function<bool(const char* data, size_t size)>;

/// GET `url`, following redirects by hand within the allowed hosts, and hand a
/// 200's body to `sink`, refusing more than `cap` bytes. Any other status is
/// returned in `status` with the body unread -- the caller decides what a 404
/// means. False means no usable answer at all, with `error` for the log.
bool Get(HINTERNET session, const std::string& url_text, Accept accept, const Token& token,
         unsigned long long cap, const Sink& sink, DWORD& status, std::string& error) {
    std::wstring url = ToWide(url_text);
    status = 0;
    for (int hop = 0; hop <= kMaxRedirects; ++hop) {
        Target target;
        if (!Resolve(url, target, error)) {
            error = (hop == 0 ? "refused to fetch " : "refused a redirect to ") + error;
            return false;
        }
        Internet connection(WinHttpConnect(session, target.host.c_str(), target.port, 0));
        if (!connection) {
            error = WinHttpProblem("connect", GetLastError());
            return false;
        }
        Internet request(WinHttpOpenRequest(connection.get(), L"GET", target.path.c_str(),
                                            nullptr, WINHTTP_NO_REFERER,
                                            WINHTTP_DEFAULT_ACCEPT_TYPES, WINHTTP_FLAG_SECURE));
        if (!request) {
            error = WinHttpProblem("open request", GetLastError());
            return false;
        }
        // Refused rather than sent when it does not take. WinHTTP's default
        // follows any HTTPS redirect by itself, to any host, carrying the
        // headers added below -- the token among them -- while this loop goes on
        // believing it is talking to target.host.
        DWORD never = WINHTTP_OPTION_REDIRECT_POLICY_NEVER;
        if (!WinHttpSetOption(request.get(), WINHTTP_OPTION_REDIRECT_POLICY, &never,
                              sizeof(never))) {
            error = WinHttpProblem("turn off automatic redirects", GetLastError());
            return false;
        }

        const bool api = FoldCase(target.host) == kApiHost;
        std::wstring headers;
        if (api) {
            headers = accept == Accept::Binary ? L"Accept: application/octet-stream\r\n"
                                               : L"Accept: application/vnd.github+json\r\n";
            headers += L"X-GitHub-Api-Version: 2022-11-28\r\n";
        }
        std::wstring authorization;
        if (api && token.present()) {
            token.Header(authorization);
        }
        bool added = true;
        constexpr DWORD kAdd = WINHTTP_ADDREQ_FLAG_ADD | WINHTTP_ADDREQ_FLAG_REPLACE;
        if (!headers.empty()) {
            added = WinHttpAddRequestHeaders(request.get(), headers.c_str(), (DWORD) -1L,
                                             kAdd) != FALSE;
        }
        if (added && !authorization.empty()) {
            added = WinHttpAddRequestHeaders(request.get(), authorization.c_str(),
                                             (DWORD) -1L, kAdd) != FALSE;
        }
        WipeText(authorization);
        if (!added) {
            error = WinHttpProblem("add headers", GetLastError());
            return false;
        }
        if (!WinHttpSendRequest(request.get(), WINHTTP_NO_ADDITIONAL_HEADERS, 0,
                                WINHTTP_NO_REQUEST_DATA, 0, 0, 0)
            || !WinHttpReceiveResponse(request.get(), nullptr)) {
            error = WinHttpProblem(ToUtf8(target.host).c_str(), GetLastError());
            return false;
        }
        // And checked: the answer must have come from the host this hop asked.
        // Should a redirect ever be followed behind this loop's back, what it
        // fetched is refused instead of trusted.
        if (!AnsweredBy(request.get(), target, error)) {
            return false;
        }
        DWORD code = 0;
        DWORD size = sizeof(code);
        if (!WinHttpQueryHeaders(request.get(),
                                 WINHTTP_QUERY_STATUS_CODE | WINHTTP_QUERY_FLAG_NUMBER,
                                 WINHTTP_HEADER_NAME_BY_INDEX, &code, &size,
                                 WINHTTP_NO_HEADER_INDEX)) {
            error = WinHttpProblem("status", GetLastError());
            return false;
        }
        status = code;

        if (code == 301 || code == 302 || code == 303 || code == 307 || code == 308) {
            std::wstring location = QueryText(request.get(), WINHTTP_QUERY_LOCATION);
            if (location.empty()) {
                error = "a redirect from " + ToUtf8(target.host) + " with no Location";
                return false;
            }
            // Relative forms, resolved against where this hop was. Anything
            // else must be absolute, and Resolve checks it like any other URL.
            if (location.rfind(L"//", 0) == 0) {
                location = L"https:" + location;
            } else if (location[0] == L'/') {
                location = L"https://" + target.host + location;
            }
            url = location;
            continue;
        }
        if (code != 200) {
            return true;
        }

        // Refused before reading when the server says up front it is too big.
        const std::wstring length = QueryText(request.get(), WINHTTP_QUERY_CONTENT_LENGTH);
        if (!length.empty() && std::wcstoull(length.c_str(), nullptr, 10) > cap) {
            error = "the response is larger than " + std::to_string(cap) + " bytes";
            return false;
        }
        unsigned long long total = 0;
        std::vector<char> buffer(64 * 1024);
        for (;;) {
            DWORD read = 0;
            if (!WinHttpReadData(request.get(), buffer.data(), (DWORD) buffer.size(), &read)) {
                error = WinHttpProblem("read", GetLastError());
                return false;
            }
            if (read == 0) {
                return true;
            }
            total += read;
            if (total > cap) {
                error = "the response is larger than " + std::to_string(cap) + " bytes";
                return false;
            }
            if (!sink(buffer.data(), read)) {
                error = "could not keep what was downloaded";
                return false;
            }
        }
    }
    error = "more than " + std::to_string(kMaxRedirects) + " redirects";
    return false;
}

bool GetText(HINTERNET session, const std::string& url, Accept accept, const Token& token,
             size_t cap, std::string& body, DWORD& status, std::string& error) {
    body.clear();
    return Get(session, url, accept, token, cap,
               [&body](const char* data, size_t size) {
                   body.append(data, size);
                   return true;
               },
               status, error);
}

/// An asset, the way the contract says to fetch one: through the API with a
/// token, because browser_download_url does not take one; directly without.
bool GetAsset(HINTERNET session, const Asset& asset, const Token& token,
              unsigned long long cap, const Sink& sink, std::string& error) {
    const bool via_api = token.present();
    const std::string& url = via_api ? asset.api_url : asset.download_url;
    if (url.empty()) {
        error = asset.name + " has no " + (via_api ? "API url" : "download url");
        return false;
    }
    DWORD status = 0;
    if (!Get(session, url, via_api ? Accept::Binary : Accept::Any, token, cap, sink, status,
             error)) {
        error = asset.name + ": " + error;
        return false;
    }
    if (status != 200) {
        error = asset.name + ": HTTP " + std::to_string(status);
        return false;
    }
    return true;
}

bool GetAssetText(HINTERNET session, const Asset& asset, const Token& token, size_t cap,
                  std::string& body, std::string& error) {
    body.clear();
    return GetAsset(session, asset, token, cap,
                    [&body](const char* data, size_t size) {
                        body.append(data, size);
                        return true;
                    },
                    error);
}

const Asset* FindAsset(const std::vector<Asset>& assets, const std::string& name) {
    for (const Asset& asset : assets) {
        if (asset.name == name) {
            return &asset;
        }
    }
    return nullptr;
}

// ── The download ─────────────────────────────────────────────────────────────

/// %LOCALAPPDATA%\SolStream\Updates, made when `create` is set. Per user, which
/// is the account that will be asked to approve what runs from it.
std::wstring UpdatesDirectory(bool create) {
    const std::wstring directory = LocalDataPath(L"Updates");
    if (directory.empty()) {
        return {};
    }
    if (create && !CreateDirectoryW(directory.c_str(), nullptr)
        && GetLastError() != ERROR_ALREADY_EXISTS) {
        return {};
    }
    return directory;
}

/// In Updates, and never cleaned away with the downloads: it is how the copy
/// that starts after an install learns what became of it. See TakeInstallNote.
constexpr wchar_t kInstallNoteName[] = L"install-started";

std::wstring InstallNotePath() {
    const std::wstring directory = UpdatesDirectory(false);
    return directory.empty() ? std::wstring() : directory + L"\\" + kInstallNoteName;
}

/// While an Install press is downloading and checking the installer. The
/// scheduler's thread cleans up after each check, and between the download's
/// .partial being closed and renamed -- or between the rename and the hold --
/// that would delete a file the install is about to use. So it skips its
/// clean-up then; the next check does it.
std::atomic<bool> g_preparing{false};

/// From just before the elevation prompt until the installer exits (or fails to
/// start). The prompt can stay up for minutes, and a Mac that connected in that
/// time would have its stream ended by the installer stopping this host.
std::atomic<bool> g_install_starting{false};

/// Everything in Updates except `keep` and the install note: installers that
/// have already been installed, and anything an interrupted download left. Best
/// effort -- a file still in use is simply tried again after the next check.
void CleanDownloads(const std::wstring& keep) {
    const std::wstring directory = UpdatesDirectory(false);
    if (directory.empty()) {
        return;
    }
    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW((directory + L"\\*").c_str(), &found);
    if (search == INVALID_HANDLE_VALUE) {
        return;
    }
    const std::wstring kept = FoldCase(keep);
    do {
        if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
            continue;
        }
        const std::wstring name = FoldCase(found.cFileName);
        if ((!kept.empty() && name == kept) || name == kInstallNoteName) {
            continue;
        }
        if (DeleteFileW((directory + L"\\" + found.cFileName).c_str())) {
            Log("[update] removed an old download, %s", ToUtf8(found.cFileName).c_str());
        }
    } while (FindNextFileW(search, &found));
    FindClose(search);
}

/// Read access, and read SHARING only. No write sharing, so nothing can change
/// the bytes; no delete sharing, so nothing can rename the file or put another
/// in its place. CreateProcess asks for read and execute, which this allows.
HANDLE OpenHeld(const std::wstring& path) {
    return CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                       FILE_ATTRIBUTE_NORMAL | FILE_FLAG_SEQUENTIAL_SCAN, nullptr);
}

bool Matches(HANDLE file, const Release& release, std::string& detail) {
    LARGE_INTEGER size{};
    if (!GetFileSizeEx(file, &size)
        || (unsigned long long) size.QuadPart != release.installer.size) {
        detail = "it is not the " + std::to_string(release.installer.size)
               + " bytes the release lists";
        return false;
    }
    std::string hex;
    if (!HashFile(file, hex, detail)) {
        return false;
    }
    if (hex != release.sha256) {
        detail = "its SHA-256 is " + hex + ", and SHA256SUMS says " + release.sha256;
        return false;
    }
    return true;
}

/// The path `held` is really open at, for the installer to be started by.
///
/// The hold pins a FILE, and a path is only the route there: a junction put in
/// place of the Updates folder, or a link at the installer's own name, sends the
/// download somewhere else, and a route can be re-pointed after the hash while
/// the file it led to stays held. Asked of the handle, the path has no link or
/// junction left in it. Each folder on it has a held file below it, so Windows
/// will not rename or remove it, and it is not empty, so it cannot be turned
/// into a junction -- the path stays tied to the bytes that were hashed, for the
/// elevated start, for that process's own hold on itself and for its copy into
/// Program Files.
///
/// A network share is refused outright: it can serve different bytes to the
/// second open than it did to the first, and nothing here can hold it still.
bool PinPath(HANDLE held, std::wstring& path, std::string& detail) {
    const DWORD flags = FILE_NAME_NORMALIZED | VOLUME_NAME_DOS;
    const DWORD needed = GetFinalPathNameByHandleW(held, nullptr, 0, flags);
    if (needed == 0) {
        detail = "Windows would not say where the download is (error "
               + std::to_string(GetLastError()) + ")";
        return false;
    }
    std::wstring resolved(needed, L'\0');
    const DWORD length = GetFinalPathNameByHandleW(held, resolved.data(), needed, flags);
    if (length == 0 || length >= needed) {
        detail = "Windows would not say where the download is (error "
               + std::to_string(GetLastError()) + ")";
        return false;
    }
    resolved.resize(length);
    if (resolved.rfind(L"\\\\?\\UNC\\", 0) == 0) {
        detail = "the download is on a network share";
        return false;
    }
    if (resolved.rfind(L"\\\\?\\", 0) == 0) {
        resolved.erase(0, 4);
    }
    // A drive letter and an absolute path, and short enough for the installer:
    // it finds itself through GetModuleFileNameW into a MAX_PATH buffer, and a
    // name cut short there is a copy of the wrong file, or of none.
    if (resolved.size() < 3 || resolved[1] != L':' || resolved[2] != L'\\'
        || resolved.size() >= MAX_PATH) {
        detail = "the download's path is not one the installer can start from ("
               + ToUtf8(resolved) + ")";
        return false;
    }
    path = resolved;
    return true;
}

/// PinPath for PrepareInstaller: on failure the hold is let go of and `error`
/// is for the window.
bool Pin(HANDLE& held, std::wstring& path, std::string& error) {
    std::string detail;
    if (PinPath(held, path, detail)) {
        return true;
    }
    CloseHandle(held);
    held = INVALID_HANDLE_VALUE;
    Log("[update] not using the download: %s", detail.c_str());
    error = "SolStream couldn't check where the update was saved, so it wasn't installed.";
    return false;
}

/// Get the installer onto disk and checked, and leave it HELD: on success
/// `held` is the open handle the hash was taken through, `path` is where that
/// handle really points (PinPath), and the caller closes it only once nothing
/// more depends on those bytes.
bool PrepareInstaller(const Release& release,
                      const std::function<void(const std::wstring&)>& step, HANDLE& held,
                      std::wstring& path, std::string& error) {
    held = INVALID_HANDLE_VALUE;
    g_preparing = true;
    struct Prepared {
        ~Prepared() { g_preparing = false; }
    } prepared;
    const std::wstring directory = UpdatesDirectory(true);
    if (directory.empty()) {
        Log("[update] could not create %%LOCALAPPDATA%%\\SolStream\\Updates");
        error = "SolStream couldn't make a folder to download the update into.";
        return false;
    }
    const std::wstring name = ToWide(release.installer.name);
    CleanDownloads(name);
    path = directory + L"\\" + name;

    // Downloaded already, by an attempt whose permission prompt was dismissed
    // or that a Mac connecting interrupted? Then it only needs checking again.
    held = OpenHeld(path);
    if (held != INVALID_HANDLE_VALUE) {
        step(L"Checking the download.");
        std::string detail;
        if (Matches(held, release, detail)) {
            Log("[update] %s was already downloaded and still matches SHA256SUMS",
                release.installer.name.c_str());
            return Pin(held, path, error);
        }
        CloseHandle(held);
        held = INVALID_HANDLE_VALUE;
        DeleteFileW(path.c_str());
    }

    step(L"Downloading the update.");
    // Under a second name until it is whole, so an interrupted download is never
    // mistaken for one that finished.
    const std::wstring partial = path + L".partial";
    HANDLE out = CreateFileW(partial.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                             FILE_ATTRIBUTE_NORMAL, nullptr);
    if (out == INVALID_HANDLE_VALUE) {
        Log("[update] could not create the download (error %lu)", GetLastError());
        error = "SolStream couldn't save the update on this PC.";
        return false;
    }
    std::string detail;
    unsigned long long written = 0;
    bool ok = false;
    {
        Token token;
        Internet session = OpenSession(detail);
        if (session) {
            ok = GetAsset(session.get(), release.installer, token, release.installer.size,
                          [out, &written](const char* data, size_t size) {
                              DWORD put = 0;
                              if (!WriteFile(out, data, (DWORD) size, &put, nullptr)
                                  || put != size) {
                                  return false;
                              }
                              written += put;
                              return true;
                          },
                          detail);
        }
    }
    CloseHandle(out);
    if (ok && written != release.installer.size) {
        ok = false;
        detail = "got " + std::to_string(written) + " of "
               + std::to_string(release.installer.size) + " bytes";
    }
    if (!ok) {
        DeleteFileW(partial.c_str());
        Log("[update] download failed: %s", detail.c_str());
        error = "SolStream couldn't download the update. Check this PC's internet "
                "connection and try again.";
        return false;
    }
    if (!MoveFileExW(partial.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        Log("[update] could not rename the finished download (error %lu)", GetLastError());
        DeleteFileW(partial.c_str());
        error = "SolStream couldn't save the update on this PC.";
        return false;
    }

    step(L"Checking the download.");
    held = OpenHeld(path);
    if (held == INVALID_HANDLE_VALUE) {
        Log("[update] could not open the download to check it (error %lu)", GetLastError());
        error = "Something else on this PC is using the update's file, so it wasn't "
                "installed.";
        return false;
    }
    if (!Matches(held, release, detail)) {
        CloseHandle(held);
        held = INVALID_HANDLE_VALUE;
        DeleteFileW(path.c_str());
        Log("[update] %s does not match SHA256SUMS, discarded: %s",
            release.installer.name.c_str(), detail.c_str());
        error = "The download didn't match the checksum SolStream signed, so it wasn't "
                "installed.";
        return false;
    }
    Log("[update] %s downloaded; its SHA-256 matches the signed SHA256SUMS",
        release.installer.name.c_str());
    return Pin(held, path, error);
}

bool ReadSmallFile(const wchar_t* path, size_t cap, std::string& out) {
    HANDLE file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    LARGE_INTEGER size{};
    bool ok = GetFileSizeEx(file, &size) && size.QuadPart >= 0
              && (unsigned long long) size.QuadPart <= cap;
    if (ok) {
        out.assign((size_t) size.QuadPart, '\0');
        DWORD read = 0;
        ok = out.empty()
             || (ReadFile(file, out.data(), (DWORD) out.size(), &read, nullptr)
                 && read == out.size());
    }
    CloseHandle(file);
    return ok;
}

/// Written just before the installer starts: the version it installs. The
/// installer stops this copy and starts the new one hidden, from the logon
/// task, so this is the only thing that tells the new one somebody pressed
/// Install a moment ago and is waiting to see SolStream come back.
void WriteInstallNote(const std::string& version) {
    const std::wstring path = InstallNotePath();
    if (path.empty()) {
        return;
    }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }
    const std::string line = version + "\n";
    DWORD written = 0;
    WriteFile(file, line.data(), (DWORD) line.size(), &written, nullptr);
    CloseHandle(file);
}

/// This copy is still running, so the installer did not get as far as
/// replacing it: nobody else is going to read the note.
void DeleteInstallNote() {
    const std::wstring path = InstallNotePath();
    if (!path.empty()) {
        DeleteFileW(path.c_str());
    }
}

enum class Vouched { Yes, NotSigned, Unreadable, NotListed };

/// The checksum a signed SHA256SUMS gives for `installer_name`, into `sha256`.
///
/// The name carries the version, and the signed sums carry the name. That is
/// what stops an older release's genuine, signed sums being served under a
/// newer tag to walk a PC backwards: they list an older installer, never this
/// one. `error` is for the log.
Vouched VouchFor(const std::string& sums, const std::string& signature,
                 const std::string& public_key_b64, const std::string& installer_name,
                 std::string& sha256, std::string& error) {
    sha256.clear();
    if (!VerifySumsSignature(sums, signature, public_key_b64, error)) {
        return Vouched::NotSigned;
    }
    std::vector<std::pair<std::string, std::string>> entries;
    if (!ParseSums(sums, entries, error)) {
        return Vouched::Unreadable;
    }
    for (const auto& entry : entries) {
        if (entry.first == installer_name) {
            sha256 = entry.second;
            return Vouched::Yes;
        }
    }
    error = "SHA256SUMS has no line for " + installer_name;
    return Vouched::NotListed;
}

// ── Schedule state ───────────────────────────────────────────────────────────

std::mutex g_schedule_mutex;
std::condition_variable g_schedule_wake;
bool g_scheduler_started = false;
bool g_asked = false;

CheckResult CheckFailed(CheckResult result, const std::string& for_person,
                        const std::string& for_log) {
    Log("[update] check failed: %s", for_log.c_str());
    result.outcome = Outcome::Failed;
    result.error = for_person;
    return result;
}

void Schedule(SchedulerHooks hooks) {
    // The wall clock, in naps of at most five minutes, rather than one long
    // wait: a wait on a steady clock does not count time the PC spent asleep,
    // so a PC that sleeps every night would put its daily check off for days.
    using Clock = std::chrono::system_clock;
    Clock::time_point due = Clock::now() + std::chrono::seconds(60);
    bool said_streaming = false;
    for (;;) {
        bool asked = false;
        {
            std::unique_lock<std::mutex> lock(g_schedule_mutex);
            for (;;) {
                if (g_asked) {
                    break;
                }
                const Clock::time_point now = Clock::now();
                if (now >= due) {
                    break;
                }
                // A clock set backwards would otherwise postpone the check by
                // however far it went.
                if (due - now > std::chrono::hours(24)) {
                    due = now + std::chrono::hours(24);
                }
                const Clock::duration nap =
                    std::min<Clock::duration>(due - now, std::chrono::minutes(5));
                g_schedule_wake.wait_for(lock, nap);
            }
            asked = g_asked;
            g_asked = false;
        }
        // Never in the middle of a stream -- unless somebody asked, and then
        // only the check: installing still waits for the Mac to go.
        if (!asked && hooks.streaming_clients && hooks.streaming_clients() > 0) {
            if (!said_streaming) {
                Log("[update] a Mac is streaming; the scheduled check waits until it "
                    "disconnects");
                said_streaming = true;
            }
            due = Clock::now() + std::chrono::minutes(5);
            continue;
        }
        said_streaming = false;

        const CheckResult result = CheckForUpdate();
        // Asked while this one was running: this one is the answer. That is
        // what keeps it to one check in flight.
        bool asked_meanwhile = false;
        {
            std::lock_guard<std::mutex> lock(g_schedule_mutex);
            asked_meanwhile = g_asked;
            g_asked = false;
        }
        // A failure keeps what is there: it may be the update a moment ago's
        // check found, half-way to being installed.
        // Nor while an Install press is preparing its download (g_preparing).
        if (g_preparing) {
            // Left for the next check.
        } else if (result.outcome == Outcome::Found) {
            CleanDownloads(ToWide(result.release.installer.name));
        } else if (result.outcome != Outcome::Failed) {
            CleanDownloads(std::wstring());
        }
        if (hooks.finished) {
            hooks.finished(result, asked || asked_meanwhile);
        }
        // Sooner after a failure -- the PC was probably offline -- but never
        // anywhere near the API's 60 an hour.
        due = Clock::now() + (result.outcome == Outcome::Failed ? std::chrono::hours(1)
                                                                : std::chrono::hours(24));
    }
}

}  // namespace

// ── Versions ─────────────────────────────────────────────────────────────────

bool ParseVersion(const std::string& text, Version& out) {
    size_t at = (!text.empty() && text[0] == 'v') ? 1 : 0;
    Version parsed;
    for (int part = 0; part < 3; ++part) {
        if (part > 0) {
            if (at >= text.size() || text[at] != '.') {
                return false;
            }
            ++at;
        }
        const size_t start = at;
        unsigned long value = 0;
        while (at < text.size() && text[at] >= '0' && text[at] <= '9') {
            if (at - start == 9) {
                return false;  // nine digits is plenty, and ten could overflow
            }
            value = value * 10 + (unsigned long) (text[at] - '0');
            ++at;
        }
        const size_t digits = at - start;
        if (digits == 0 || (digits > 1 && text[start] == '0')) {
            return false;
        }
        parsed.parts[part] = value;
    }
    if (at != text.size()) {
        return false;
    }
    out = parsed;
    return true;
}

int CompareVersions(const Version& a, const Version& b) {
    for (int part = 0; part < 3; ++part) {
        if (a.parts[part] != b.parts[part]) {
            return a.parts[part] < b.parts[part] ? -1 : 1;
        }
    }
    return 0;
}

std::string VersionText(const Version& version) {
    char text[40];
    std::snprintf(text, sizeof(text), "%lu.%lu.%lu", version.parts[0], version.parts[1],
                  version.parts[2]);
    return text;
}

std::string CurrentVersion() {
    wchar_t pretend[64] = {0};
    const DWORD length = GetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", pretend, 64);
    if (length > 0 && length < 64) {
        Version version;
        if (ParseVersion(ToUtf8(pretend), version)) {
            return VersionText(version);
        }
        Log("[update] SOLSTREAM_PRETEND_VERSION is not X.Y.Z; ignoring it");
    }
    return SOLSTREAM_VERSION_STRING;
}

// ── Parsing ──────────────────────────────────────────────────────────────────

bool ParseRelease(const std::string& json, ReleaseInfo& out, std::string& error) {
    Json root;
    if (!JsonReader(json).Document(root) || root.kind != Json::Kind::Object) {
        error = "the release is not a JSON object";
        return false;
    }
    ReleaseInfo info;
    if (!StringMember(root, "tag_name", true, info.tag, error)
        || !BoolMember(root, "draft", info.draft, error)
        || !BoolMember(root, "prerelease", info.prerelease, error)) {
        return false;
    }
    const Json* assets = nullptr;
    if (!Member(root, "assets", assets)) {
        error = "\"assets\" appears twice";
        return false;
    }
    if (assets != nullptr) {
        if (assets->kind != Json::Kind::Array) {
            error = "\"assets\" is not a list";
            return false;
        }
        for (const Json& item : assets->items) {
            if (item.kind != Json::Kind::Object) {
                error = "an asset is not an object";
                return false;
            }
            Asset asset;
            if (!StringMember(item, "name", true, asset.name, error)
                || !StringMember(item, "url", false, asset.api_url, error)
                || !StringMember(item, "browser_download_url", false, asset.download_url,
                                 error)) {
                return false;
            }
            const Json* size = nullptr;
            if (!Member(item, "size", size)) {
                error = "an asset's \"size\" appears twice";
                return false;
            }
            // A whole number of bytes: digits only, and few enough of them that
            // it cannot overflow. Anything else is not a size.
            if (size == nullptr || size->kind != Json::Kind::Number || size->text.empty()
                || size->text.size() > 15
                || size->text.find_first_not_of("0123456789") != std::string::npos) {
                error = "asset " + asset.name + " has no usable size";
                return false;
            }
            asset.size = std::strtoull(size->text.c_str(), nullptr, 10);
            info.assets.push_back(std::move(asset));
        }
    }
    out = std::move(info);
    return true;
}

bool ParseSums(const std::string& sums, std::vector<std::pair<std::string, std::string>>& out,
               std::string& error) {
    out.clear();
    if (sums.empty() || sums.back() != '\n') {
        error = "SHA256SUMS does not end in a newline";
        return false;
    }
    size_t at = 0;
    int number = 0;
    while (at < sums.size()) {
        ++number;
        const size_t end = sums.find('\n', at);
        const std::string line = sums.substr(at, end - at);
        at = end + 1;
        const std::string where = "SHA256SUMS line " + std::to_string(number);
        if (line.size() < 64 + 2 + 1) {
            error = where + " is too short";
            return false;
        }
        for (size_t i = 0; i < 64; ++i) {
            const char c = line[i];
            if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) {
                error = where + " does not start with 64 lowercase hex digits";
                return false;
            }
        }
        if (line[64] != ' ' || line[65] != ' ') {
            error = where + " does not separate the hash from the name with two spaces";
            return false;
        }
        const std::string name = line.substr(66);
        // A file name, not a path, and nothing invisible -- a CR from a CRLF
        // file included, which would otherwise ride along on the end of it.
        for (const char c : name) {
            if ((unsigned char) c < 0x20 || c == 0x7F || c == '/' || c == '\\') {
                error = where + " does not name a plain file";
                return false;
            }
        }
        for (const auto& entry : out) {
            if (entry.first == name) {
                error = "SHA256SUMS lists " + name + " twice";
                return false;
            }
        }
        out.emplace_back(name, line.substr(0, 64));
    }
    return true;
}

bool DecodeBase64(const std::string& text, std::vector<unsigned char>& out) {
    out.clear();
    if (text.empty() || text.size() % 4 != 0) {
        return false;
    }
    auto value = [](char c) -> int {
        if (c >= 'A' && c <= 'Z') { return c - 'A'; }
        if (c >= 'a' && c <= 'z') { return c - 'a' + 26; }
        if (c >= '0' && c <= '9') { return c - '0' + 52; }
        if (c == '+') { return 62; }
        if (c == '/') { return 63; }
        return -1;
    };
    out.reserve(text.size() / 4 * 3);
    for (size_t i = 0; i < text.size(); i += 4) {
        const bool last = i + 4 == text.size();
        unsigned bits = 0;
        int padding = 0;
        for (size_t j = 0; j < 4; ++j) {
            const char c = text[i + j];
            int sextet = 0;
            if (c == '=') {
                // Only in the last group's last two places.
                if (!last || j < 2) {
                    return false;
                }
                ++padding;
            } else {
                if (padding > 0) {
                    return false;  // data after padding
                }
                sextet = value(c);
                if (sextet < 0) {
                    return false;
                }
            }
            bits = (bits << 6) | (unsigned) sextet;
        }
        out.push_back((unsigned char) (bits >> 16));
        if (padding < 2) {
            out.push_back((unsigned char) (bits >> 8));
        }
        if (padding < 1) {
            out.push_back((unsigned char) bits);
        }
    }
    return true;
}

bool VerifySumsSignature(const std::string& sums, const std::string& signature_file,
                         const std::string& public_key_b64, std::string& error) {
    std::vector<unsigned char> point;
    if (!DecodeBase64(Trim(public_key_b64), point) || point.size() != 65 || point[0] != 0x04) {
        error = "the public key is not base64 of an uncompressed P-256 point";
        return false;
    }
    std::vector<unsigned char> signature;
    if (!DecodeBase64(Trim(signature_file), signature) || signature.size() != 64) {
        error = "the signature is not base64 of a 64-byte r||s";
        return false;
    }
    unsigned char digest[32] = {0};
    if (!Sha256((const unsigned char*) sums.data(), sums.size(), digest)) {
        error = "SHA-256 is unavailable";
        return false;
    }

    // BCRYPT_ECCPUBLIC_BLOB is a small header and then X || Y: the X9.63
    // point without its leading 0x04.
    BCRYPT_ECCKEY_BLOB header{};
    header.dwMagic = BCRYPT_ECDSA_PUBLIC_P256_MAGIC;
    header.cbKey = 32;
    std::vector<unsigned char> blob(sizeof(header) + 64);
    std::memcpy(blob.data(), &header, sizeof(header));
    std::memcpy(blob.data() + sizeof(header), point.data() + 1, 64);

    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_ECDSA_P256_ALGORITHM,
                                                    nullptr, 0))) {
        error = "ECDSA P-256 is unavailable";
        return false;
    }
    BCRYPT_KEY_HANDLE key = nullptr;
    NTSTATUS status = BCryptImportKeyPair(algorithm, nullptr, BCRYPT_ECCPUBLIC_BLOB, &key,
                                          blob.data(), (ULONG) blob.size(), 0);
    if (!BCRYPT_SUCCESS(status)) {
        BCryptCloseAlgorithmProvider(algorithm, 0);
        error = "the public key is not a point on P-256";
        return false;
    }
    // CNG takes ECDSA signatures as raw r || s, which is why the release
    // carries them that way rather than DER.
    status = BCryptVerifySignature(key, nullptr, digest, sizeof(digest), signature.data(),
                                   (ULONG) signature.size(), 0);
    BCryptDestroyKey(key);
    BCryptCloseAlgorithmProvider(algorithm, 0);
    if (status == 0) {
        return true;
    }
    if (status == STATUS_INVALID_SIGNATURE) {
        error = "the signature does not match";
    } else {
        char code[16];
        std::snprintf(code, sizeof(code), "0x%08lX", (unsigned long) status);
        error = std::string("verification failed (") + code + ")";
    }
    return false;
}

// ── Checking ─────────────────────────────────────────────────────────────────

CheckResult CheckForUpdate() {
    CheckResult result;
    result.current = CurrentVersion();
    Version current;
    if (!ParseVersion(result.current, current)) {
        return CheckFailed(result, "This copy of SolStream doesn't know its own version.",
                      "the compiled-in version " + result.current + " is not X.Y.Z");
    }
    const bool pretending = result.current != SOLSTREAM_VERSION_STRING;
    Token token;
    Log("[update] checking %s for a version newer than %s%s%s", kRepository,
        result.current.c_str(), pretending ? " (SOLSTREAM_PRETEND_VERSION)" : "",
        token.present() ? ", with a token" : "");

    std::string error;
    Internet session = OpenSession(error);
    if (!session) {
        return CheckFailed(result, "SolStream couldn't reach GitHub. It will try again later.",
                      error);
    }
    const std::string url =
        std::string("https://api.github.com/repos/") + kRepository + "/releases/latest";
    std::string body;
    DWORD status = 0;
    if (!GetText(session.get(), url, Accept::Api, token, kMaxReleaseJson, body, status,
                 error)) {
        return CheckFailed(result, "SolStream couldn't reach GitHub. It will try again later.",
                      error);
    }
    if (status == 404) {
        // Not an error: it is what a private repository says to anybody
        // without access, and what any repository says before its first
        // release. Nothing to show; ask again tomorrow.
        Log("[update] nothing published that this copy can see (HTTP 404)%s",
            token.present() ? "" : "; a private repository answers this without "
                                   "SOLSTREAM_GITHUB_TOKEN");
        result.outcome = Outcome::NothingVisible;
        return result;
    }
    if (status == 401) {
        return CheckFailed(result, "GitHub didn't accept SOLSTREAM_GITHUB_TOKEN.", "HTTP 401");
    }
    if (status == 403 || status == 429) {
        return CheckFailed(result,
                      "GitHub is limiting requests from this network. SolStream will try "
                      "again later.",
                      "HTTP " + std::to_string(status));
    }
    if (status != 200) {
        return CheckFailed(result,
                      "GitHub answered with an error (HTTP " + std::to_string(status)
                          + "). SolStream will try again later.",
                      "HTTP " + std::to_string(status));
    }

    ReleaseInfo info;
    if (!ParseRelease(body, info, error)) {
        return CheckFailed(result, "GitHub's answer didn't make sense, so it was ignored.", error);
    }
    if (info.draft || info.prerelease) {
        Log("[update] the latest release is a %s; ignoring it",
            info.draft ? "draft" : "prerelease");
        result.outcome = Outcome::NothingVisible;
        return result;
    }
    Version latest;
    if (!ParseVersion(info.tag, latest)) {
        return CheckFailed(result,
                      "The newest release isn't numbered the way SolStream expects, so it "
                      "was ignored.",
                      "tag \"" + info.tag.substr(0, 64) + "\" is not vX.Y.Z");
    }
    result.latest = VersionText(latest);
    if (CompareVersions(latest, current) <= 0) {
        Log("[update] up to date: the latest release is %s", result.latest.c_str());
        result.outcome = Outcome::UpToDate;
        return result;
    }
    // SOLSTREAM_PRETEND_VERSION left set in somebody's environment must not
    // turn into a downgrade: never offer a release older than what was built.
    // Nor the version it already is: the install refuses anything not
    // strictly newer than the build, so offering it would only end in an error.
    if (pretending) {
        Version built;
        if (!ParseVersion(SOLSTREAM_VERSION_STRING, built) || CompareVersions(latest, built) <= 0) {
            Log("[update] up to date: %s is not newer than this build (%s), whatever "
                "SOLSTREAM_PRETEND_VERSION says", result.latest.c_str(),
                SOLSTREAM_VERSION_STRING);
            result.outcome = Outcome::UpToDate;
            return result;
        }
    }

    // Named for the tag's version, and only trusted once the signed sums name
    // it too (VouchFor): no older release's sums can stand in for these.
    const std::string installer_name = "SolStreamSetup-" + result.latest + ".exe";
    const Asset* installer = FindAsset(info.assets, installer_name);
    const Asset* sums_asset = FindAsset(info.assets, "SHA256SUMS");
    const Asset* signature_asset = FindAsset(info.assets, "SHA256SUMS.sig");
    if (!installer || !sums_asset || !signature_asset) {
        return CheckFailed(result,
                      "SolStream " + result.latest
                          + " was published without its Windows installer or its "
                            "checksums, so it was ignored.",
                      "release " + result.latest + " lacks "
                          + (!installer ? installer_name
                                        : (!sums_asset ? "SHA256SUMS" : "SHA256SUMS.sig")));
    }
    std::string sums;
    std::string signature;
    if (!GetAssetText(session.get(), *sums_asset, token, kMaxSumsBytes, sums, error)
        || !GetAssetText(session.get(), *signature_asset, token, kMaxSignatureBytes,
                         signature, error)) {
        return CheckFailed(result,
                      "SolStream couldn't download the update's checksums. It will try "
                      "again later.",
                      error);
    }
    std::string sha256;
    switch (VouchFor(sums, signature, kPublicKey, installer_name, sha256, error)) {
        case Vouched::Yes:
            break;
        case Vouched::NotSigned:
            return CheckFailed(result,
                          "SolStream " + result.latest
                              + "'s checksums aren't signed by SolStream, so it was ignored.",
                          "SHA256SUMS signature: " + error);
        case Vouched::Unreadable:
            return CheckFailed(result,
                          "SolStream " + result.latest
                              + "'s checksums couldn't be read, so it was ignored.",
                          error);
        case Vouched::NotListed:
            return CheckFailed(result,
                          "SolStream " + result.latest
                              + "'s checksums don't include its Windows installer, so it was "
                                "ignored.",
                          error);
    }
    if (installer->size == 0 || installer->size > kMaxInstallerBytes) {
        return CheckFailed(result,
                      "SolStream " + result.latest
                          + "'s installer isn't a size SolStream will download.",
                      installer_name + " is " + std::to_string(installer->size) + " bytes");
    }

    result.release.version = result.latest;
    result.release.installer = *installer;
    result.release.sha256 = sha256;
    result.outcome = Outcome::Found;
    Log("[update] %s is available (%s, %llu bytes); the SHA256SUMS signature is valid",
        result.latest.c_str(), installer_name.c_str(), installer->size);
    return result;
}

// ── Installing ───────────────────────────────────────────────────────────────

bool InstallStarting() {
    return g_install_starting;
}

bool InstallUpdate(const Release& release, HWND owner, const InstallOptions& options,
                   const std::function<void(const std::wstring&)>& step,
                   const std::function<bool()>& may_install,
                   const std::function<void(DWORD)>& installer_exited, std::string& error) {
    // Never sideways or down -- against the version this copy was BUILT as,
    // not the one it reports: SOLSTREAM_PRETEND_VERSION makes the check find
    // older releases, and without this an override set for testing would run
    // an older installer elevated. The Mac refuses the same way at install.
    {
        Version wanted, running;
        if (!ParseVersion(release.version, wanted)
            || !ParseVersion(SOLSTREAM_VERSION_STRING, running)
            || CompareVersions(wanted, running) <= 0) {
            Log("[update] not installing %s over %s: not newer than this copy",
                release.version.c_str(), SOLSTREAM_VERSION_STRING);
            error = "This copy of SolStream is already up to date.";
            return false;
        }
    }
    HANDLE held = INVALID_HANDLE_VALUE;
    std::wstring path;
    if (!PrepareInstaller(release, step, held, path, error)) {
        return false;
    }
    // Closed to new Macs first, then asked: a Mac that proves its token after
    // this line is refused at the door instead (main.cpp's accept loop).
    g_install_starting = true;
    if (may_install && !may_install()) {
        g_install_starting = false;
        CloseHandle(held);
        Log("[update] a Mac connected while the update was downloading; not installing");
        error = "Your Mac connected while the update downloaded, so it wasn't installed. "
                "Install it once your Mac has disconnected.";
        return false;
    }

    step(L"Waiting for you to allow this in the Windows prompt…");
    // Elevated by this call rather than by the installer relaunching itself.
    // A relaunch would start the file a SECOND time, by path, after this
    // process had let go of it -- reopening exactly the gap the held handle
    // closes. Who is at the keyboard travels in OptionArguments, as it does
    // from the setup window.
    const std::wstring arguments = L"--install" + OptionArguments(options);
    wchar_t system[MAX_PATH] = {0};
    GetSystemDirectoryW(system, MAX_PATH);
    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE);
    SHELLEXECUTEINFOW execute{};
    execute.cbSize = sizeof(execute);
    // NO_UI: a failure is explained by the window, not by a second, shell-drawn
    // dialog on top of it.
    execute.fMask = SEE_MASK_NOCLOSEPROCESS | SEE_MASK_NOASYNC | SEE_MASK_FLAG_NO_UI;
    // The window that asked, so the prompt comes up in front of it rather than
    // flashing in the taskbar.
    execute.hwnd = owner;
    execute.lpVerb = L"runas";
    execute.lpFile = path.c_str();
    execute.lpParameters = arguments.c_str();
    // Not the download folder: nothing should be found relative to it.
    execute.lpDirectory = system[0] ? system : nullptr;
    // The install path never shows a window of its own.
    execute.nShow = SW_HIDE;
    // Before the start, not after: once the installer is running it can stop
    // this process at any moment.
    WriteInstallNote(release.version);
    const BOOL started = ShellExecuteExW(&execute);
    const DWORD code = started ? 0 : GetLastError();
    if (SUCCEEDED(com)) {
        CoUninitialize();
    }
    if (started && may_install && !may_install()) {
        // Connected before the door closed and authenticated during the
        // prompt. The installer is already running, so this only explains the
        // stream it is about to end.
        Log("[update] a Mac connected during the permission prompt; the installer will "
            "end its stream");
    }
    if (started) {
        // Not let go yet. The installer is running the bytes that were hashed,
        // but it copies itself into Program Files BY PATH, so the file has to
        // stay put until it has taken its own hold on itself (main.cpp's
        // --install does that first thing). The installer stops this process
        // before it copies, which is what normally releases this handle.
        //
        // So the installer finishing while this thread is still here to see it
        // means it did NOT replace this copy -- it stopped before the copy, or
        // the copy failed -- and whoever pressed Install is still looking at a
        // window saying it is under way. That is what `installer_exited` is
        // told, with the installer's exit code.
        HANDLE process = execute.hProcess;
        if (!process) {
            // Started, but with nothing to wait on. Then the hold is kept for
            // the life of this process -- which the installer ends -- rather
            // than let go of before the installer has taken its own.
            Log("[update] the installer started without a process handle; keeping the "
                "download held until this copy stops");
            g_install_starting = false;
            Log("[update] the installer for %s has started", release.version.c_str());
            return true;
        }
        std::thread([held, process, installer_exited] {
            DWORD exit_code = 0;
            const bool exited = WaitForSingleObject(process, INFINITE) == WAIT_OBJECT_0
                                && GetExitCodeProcess(process, &exit_code);
            CloseHandle(process);
            CloseHandle(held);
            g_install_starting = false;
            if (exited) {
                DeleteInstallNote();
                Log("[update] the installer finished (exit code %lu) and this copy is still "
                    "running, so it was not replaced", exit_code);
                if (installer_exited) {
                    installer_exited(exit_code);
                }
            }
        }).detach();
    } else {
        g_install_starting = false;
        DeleteInstallNote();
        CloseHandle(held);
        Log("[update] the installer did not start (error %lu)", code);
        error = code == ERROR_CANCELLED
                    ? "Windows' permission prompt was dismissed, so nothing was changed."
                    : "Windows wouldn't start the installer (error " + std::to_string(code)
                          + ").";
        return false;
    }
    Log("[update] the installer for %s has started; it stops this copy and starts the "
        "new one", release.version.c_str());
    return true;
}

InstallNote TakeInstallNote() {
    InstallNote note;
    const std::wstring path = InstallNotePath();
    if (path.empty()) {
        return note;
    }
    WIN32_FILE_ATTRIBUTE_DATA attributes{};
    if (!GetFileAttributesExW(path.c_str(), GetFileExInfoStandard, &attributes)) {
        return note;
    }
    std::string text;
    const bool read = ReadSmallFile(path.c_str(), 64, text);
    // Once: the next start has nothing to report.
    DeleteFileW(path.c_str());
    Version version;
    if (!read || !ParseVersion(Trim(text), version)) {
        return note;
    }
    // Against the compiled version, never a pretended one: this is about which
    // file is actually running.
    Version running;
    if (!ParseVersion(SOLSTREAM_VERSION_STRING, running)) {
        return note;
    }
    const int compared = CompareVersions(version, running);
    if (compared < 0) {
        // Something newer has been installed since, some other way. Whatever
        // that install was for, it is not news any more.
        return note;
    }
    note.version = VersionText(version);
    note.kind = compared == 0 ? InstallNote::Kind::Installed : InstallNote::Kind::NotInstalled;
    // Fresh means somebody pressed Install minutes ago and is waiting for the
    // answer. An older note is news for whenever the window is next opened, not
    // a reason to put it in front of somebody logging in days later.
    FILETIME now_time{};
    GetSystemTimeAsFileTime(&now_time);
    ULARGE_INTEGER now{};
    now.LowPart = now_time.dwLowDateTime;
    now.HighPart = now_time.dwHighDateTime;
    ULARGE_INTEGER written{};
    written.LowPart = attributes.ftLastWriteTime.dwLowDateTime;
    written.HighPart = attributes.ftLastWriteTime.dwHighDateTime;
    constexpr unsigned long long kTicksPerMinute = 60ull * 10000000ull;
    note.recent = written.QuadPart <= now.QuadPart + kTicksPerMinute
                  && now.QuadPart - std::min(now.QuadPart, written.QuadPart)
                         <= 10 * kTicksPerMinute;
    Log("[update] the last install started was for %s; this copy is %s", note.version.c_str(),
        SOLSTREAM_VERSION_STRING);
    return note;
}

// ── Command line ─────────────────────────────────────────────────────────────

int VerifySignatureCommand(int argc, wchar_t** argv) {
    if (argc < 2 || argc > 3) {
        std::fputs("usage: SolStream.exe --verify-update-signature <SHA256SUMS> "
                   "<SHA256SUMS.sig> [<public key base64, or a file holding it>]\n",
                   stderr);
        return 2;
    }
    std::string sums;
    std::string signature;
    if (!ReadSmallFile(argv[0], kMaxSumsBytes, sums)) {
        std::printf("BAD SIGNATURE: could not read %s\n", ToUtf8(argv[0]).c_str());
        return 1;
    }
    if (!ReadSmallFile(argv[1], kMaxSignatureBytes, signature)) {
        std::printf("BAD SIGNATURE: could not read %s\n", ToUtf8(argv[1]).c_str());
        return 1;
    }
    std::string key = kPublicKey;
    if (argc == 3) {
        key = ToUtf8(argv[2]);
        // A file holding the key works too, so a caller without a shell to read
        // test-key.pub.b64 can name it instead.
        const DWORD attributes = GetFileAttributesW(argv[2]);
        std::string from_file;
        if (attributes != INVALID_FILE_ATTRIBUTES
            && (attributes & FILE_ATTRIBUTE_DIRECTORY) == 0
            && ReadSmallFile(argv[2], 4096, from_file)) {
            key = from_file;
        }
    }
    std::string error;
    if (VerifySumsSignature(sums, signature, key, error)) {
        std::puts("signature OK");
        return 0;
    }
    std::printf("BAD SIGNATURE: %s\n", error.c_str());
    return 1;
}

int CheckCommand(bool download) {
    const CheckResult result = CheckForUpdate();
    switch (result.outcome) {
        case Outcome::UpToDate:
            std::printf("Up to date: this is %s, and the latest release is %s.\n",
                        result.current.c_str(), result.latest.c_str());
            return 0;
        case Outcome::NothingVisible:
            std::printf("Nothing published that this copy can see. GitHub answers that "
                        "for a private repository without SOLSTREAM_GITHUB_TOKEN, and "
                        "for one with no releases.\n");
            return 0;
        case Outcome::Failed:
            std::printf("The check failed: %s\n", result.error.c_str());
            return 1;
        case Outcome::Found:
            break;
    }
    std::printf("Update available: %s (this is %s). %s, %llu bytes, SHA-256 %s. The "
                "SHA256SUMS signature is valid.\n",
                result.release.version.c_str(), result.current.c_str(),
                result.release.installer.name.c_str(), result.release.installer.size,
                result.release.sha256.c_str());
    if (!download) {
        return 0;
    }
    HANDLE held = INVALID_HANDLE_VALUE;
    std::wstring path;
    std::string error;
    if (!PrepareInstaller(result.release,
                          [](const std::wstring& text) {
                              std::printf("%s\n", ToUtf8(text).c_str());
                          },
                          held, path, error)) {
        std::printf("The download failed: %s\n", error.c_str());
        return 1;
    }
    CloseHandle(held);
    std::printf("Downloaded and verified, and not run: %s\n", ToUtf8(path).c_str());
    return 0;
}

// ── Pinned downloads ─────────────────────────────────────────────────────────

bool FetchPinned(const std::string& url, const std::string& sha256_hex,
                 unsigned long long cap, std::vector<char>& body, std::string& error) {
    body.clear();
    Internet session = OpenSession(error);
    if (!session) {
        return false;
    }
    // Get only ever sends a token to api.github.com, and these URLs are never
    // that host, so the person's token cannot travel with this request.
    const Token no_token;
    DWORD status = 0;
    if (!Get(session.get(), url, Accept::Any, no_token, cap,
             [&body](const char* data, size_t size) {
                 body.insert(body.end(), data, data + size);
                 return true;
             },
             status, error)) {
        return false;
    }
    if (status != 200) {
        error = "GitHub answered HTTP " + std::to_string(status);
        return false;
    }
    unsigned char digest[32] = {0};
    if (!Sha256(reinterpret_cast<const unsigned char*>(body.data()), body.size(), digest)) {
        error = "could not hash what was downloaded";
        return false;
    }
    const std::string got = ToHex(digest, sizeof(digest));
    if (got != sha256_hex) {
        // Not trusted, so not kept: nothing downstream may see these bytes.
        body.clear();
        error = "what was downloaded is not the file SolStream expects (SHA-256 "
              + got + ")";
        return false;
    }
    return true;
}

// ── Schedule ─────────────────────────────────────────────────────────────────

void StartScheduler(const SchedulerHooks& hooks) {
    {
        std::lock_guard<std::mutex> lock(g_schedule_mutex);
        if (g_scheduler_started) {
            return;
        }
        g_scheduler_started = true;
    }
    Log("[update] first check in a minute, then every 24 hours");
    std::thread([hooks] { Schedule(hooks); }).detach();
}

bool CheckNow() {
    {
        std::lock_guard<std::mutex> lock(g_schedule_mutex);
        if (!g_scheduler_started) {
            return false;
        }
        g_asked = true;
    }
    g_schedule_wake.notify_one();
    return true;
}

}  // namespace solstream::update
