// updater_tests.cpp — the Windows updater's own tests (docs/updates.md).
//
//     SolStreamUpdaterTests <path to tests/update-vector>
//
// Includes updater.cpp rather than linking it: the parsers, the host allow-list,
// the download's hold and the anti-rollback check live in its anonymous
// namespace, deliberately, and this is the one place that needs to reach them.
//
// No network, and nothing outside a temporary folder: %LOCALAPPDATA% is pointed
// at one before anything runs, so the real Updates folder is never touched. The
// one exception is a volatile registry key of its own under HKCU, for the
// virtual display's settings records, deleted again at the end. The fetching
// itself (Get, the redirects, the token's scoping) needs a server and is not
// covered here.
//
// It also carries the tests of a few pieces outside the updater that need no
// hardware: how commands are started, the install options, what uninstall
// takes of the virtual display's settings, when its device is waiting for a
// restart, which adapter is Tailscale's, the clipboard's privacy
// markers and line endings, when the sound capture opens its device
// again, when the encoder spends a frame id, when a Mac may take
// back the session it left behind, and how a key the Mac sends by
// position is pressed here.

#include "updater.cpp"

#include <sddl.h>
#include <shellapi.h>
#include <winioctl.h>
#include <cfgmgr32.h>

#include <cctype>
#include <cstdio>

#include "clipboard.h"
#include "driver_install.h"
#include "media/audio_reopen.h"
#include "media/feed_ledger.h"
#include "media/overflow_gate.h"
#include "session_takeover.h"
#include "media/keys.h"
#include "tailscale.h"
#include "vdd.h"

namespace {

using namespace solstream;
using namespace solstream::update;

int g_checks = 0;
int g_failures = 0;
std::string g_log;

#define CHECK(condition)                                                    \
    do {                                                                    \
        ++g_checks;                                                         \
        if (!(condition)) {                                                 \
            ++g_failures;                                                   \
            std::printf("FAIL %s:%d: %s\n", __FILE__, __LINE__, #condition); \
        }                                                                   \
    } while (0)

bool UnderWine() {
    const HMODULE ntdll = GetModuleHandleW(L"ntdll.dll");
    return ntdll && GetProcAddress(ntdll, "wine_get_version") != nullptr;
}

std::string ReadVector(const std::wstring& dir, const wchar_t* name) {
    std::string text;
    if (!ReadSmallFile((dir + L"\\" + name).c_str(), 64 * 1024, text)) {
        std::printf("FAIL: could not read %s from the test vector\n", ToUtf8(name).c_str());
        ++g_failures;
    }
    return text;
}

bool WriteAll(const std::wstring& path, const std::string& bytes) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD written = 0;
    const bool ok = WriteFile(file, bytes.data(), (DWORD) bytes.size(), &written, nullptr)
                    && written == bytes.size();
    CloseHandle(file);
    return ok;
}

bool Exists(const std::wstring& path) {
    return GetFileAttributesW(path.c_str()) != INVALID_FILE_ATTRIBUTES;
}

/// Both handles open the same file: same volume, same file index.
bool SameFile(HANDLE a, HANDLE b) {
    BY_HANDLE_FILE_INFORMATION x{};
    BY_HANDLE_FILE_INFORMATION y{};
    return GetFileInformationByHandle(a, &x) && GetFileInformationByHandle(b, &y)
           && x.dwVolumeSerialNumber == y.dwVolumeSerialNumber
           && x.nFileIndexHigh == y.nFileIndexHigh && x.nFileIndexLow == y.nFileIndexLow;
}

void RemoveTree(const std::wstring& path) {
    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW((path + L"\\*").c_str(), &found);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            const std::wstring name = found.cFileName;
            if (name == L"." || name == L"..") {
                continue;
            }
            const std::wstring child = path + L"\\" + name;
            const bool junction = (found.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0;
            if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0) {
                // A junction is removed as itself, never followed into.
                if (junction) {
                    RemoveDirectoryW(child.c_str());
                } else {
                    RemoveTree(child);
                }
            } else {
                DeleteFileW(child.c_str());
            }
        } while (FindNextFileW(search, &found));
        FindClose(search);
    }
    RemoveDirectoryW(path.c_str());
}

/// `link`, a new empty folder, made a junction to `target` -- what something
/// running as the same user can do to %LOCALAPPDATA%\SolStream\Updates.
bool MakeJunction(const std::wstring& link, const std::wstring& target) {
    if (!CreateDirectoryW(link.c_str(), nullptr)) {
        return false;
    }
    HANDLE folder = CreateFileW(link.c_str(), GENERIC_WRITE, 0, nullptr, OPEN_EXISTING,
                                FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
                                nullptr);
    if (folder == INVALID_HANDLE_VALUE) {
        return false;
    }
    // REPARSE_DATA_BUFFER's mount-point form, which user-mode headers leave
    // out: tag, length, reserved, then the two names' offsets and lengths.
    const std::wstring substitute = L"\\??\\" + target;
    const WORD substitute_bytes = (WORD) (substitute.size() * sizeof(wchar_t));
    const WORD print_bytes = (WORD) (target.size() * sizeof(wchar_t));
    const WORD names = (WORD) (substitute_bytes + sizeof(wchar_t) + print_bytes
                               + sizeof(wchar_t));
    std::vector<unsigned char> buffer(16 + names, 0);
    auto put16 = [&buffer](size_t at, WORD value) { std::memcpy(&buffer[at], &value, 2); };
    const DWORD tag = IO_REPARSE_TAG_MOUNT_POINT;
    std::memcpy(&buffer[0], &tag, 4);
    put16(4, (WORD) (8 + names));
    put16(8, 0);
    put16(10, substitute_bytes);
    put16(12, (WORD) (substitute_bytes + sizeof(wchar_t)));
    put16(14, print_bytes);
    std::memcpy(&buffer[16], substitute.c_str(), substitute_bytes);
    std::memcpy(&buffer[16 + substitute_bytes + sizeof(wchar_t)], target.c_str(), print_bytes);
    DWORD returned = 0;
    const bool ok = DeviceIoControl(folder, FSCTL_SET_REPARSE_POINT, buffer.data(),
                                    (DWORD) buffer.size(), nullptr, 0, &returned, nullptr)
                    != FALSE;
    CloseHandle(folder);
    if (!ok) {
        RemoveDirectoryW(link.c_str());
    }
    return ok;
}

// ── Pieces ───────────────────────────────────────────────────────────────────

void TestVersions() {
    Version v;
    CHECK(ParseVersion("1.0.0", v) && v.parts[0] == 1 && v.parts[1] == 0 && v.parts[2] == 0);
    CHECK(ParseVersion("v10.20.30", v) && v.parts[0] == 10 && v.parts[2] == 30);
    CHECK(ParseVersion("0.0.0", v));
    CHECK(ParseVersion("999999999.0.1", v));
    CHECK(!ParseVersion("1000000000.0.1", v));
    CHECK(!ParseVersion("", v));
    CHECK(!ParseVersion("v", v));
    CHECK(!ParseVersion("1.0", v));
    CHECK(!ParseVersion("1.0.0.0", v));
    CHECK(!ParseVersion("1.0.0-beta", v));
    CHECK(!ParseVersion("01.0.0", v));
    CHECK(!ParseVersion("1..0", v));
    CHECK(!ParseVersion(" 1.0.0", v));
    CHECK(!ParseVersion("V1.0.0", v));
    CHECK(!ParseVersion("vv1.0.0", v));
    Version a;
    Version b;
    CHECK(ParseVersion("1.0.10", a) && ParseVersion("1.0.9", b));
    CHECK(CompareVersions(a, b) > 0);  // numbers, not text
    CHECK(ParseVersion("2.0.0", a) && ParseVersion("1.99.99", b));
    CHECK(CompareVersions(a, b) > 0);
    CHECK(CompareVersions(b, a) < 0);
    CHECK(CompareVersions(a, a) == 0);
    CHECK(VersionText(a) == "2.0.0");
    // What this build compares against has to be a version at all.
    CHECK(ParseVersion(SOLSTREAM_VERSION_STRING, v));
}

void TestBase64() {
    std::vector<unsigned char> out;
    CHECK(DecodeBase64("TWFu", out) && out.size() == 3 && out[0] == 'M');
    CHECK(DecodeBase64("TWE=", out) && out.size() == 2);
    CHECK(DecodeBase64("TQ==", out) && out.size() == 1 && out[0] == 'M');
    CHECK(!DecodeBase64("TQ=", out));
    CHECK(!DecodeBase64("T===", out));
    CHECK(!DecodeBase64("TQ=A", out));
    CHECK(!DecodeBase64("TQ==TWFu", out));
    CHECK(!DecodeBase64("TW-u", out));
    CHECK(!DecodeBase64("", out));
    CHECK(!DecodeBase64("TWFu\n", out));
}

void TestSignature(const std::wstring& dir) {
    const std::string sums = ReadVector(dir, L"SHA256SUMS");
    const std::string signature = ReadVector(dir, L"SHA256SUMS.sig");
    const std::string key = ReadVector(dir, L"test-key.pub.b64");
    CHECK(sums.size() == 183);
    std::string error;
    CHECK(VerifySumsSignature(sums, signature, key, error));
    // Under the production key it must not verify.
    CHECK(!VerifySumsSignature(sums, signature, kPublicKey, error));
    // Nor with any one bit of any byte changed.
    int refused = 0;
    for (size_t i = 0; i < sums.size(); ++i) {
        std::string tampered = sums;
        tampered[i] = (char) (tampered[i] ^ 1);
        if (!VerifySumsSignature(tampered, signature, key, error)) {
            ++refused;
        }
    }
    CHECK(refused == (int) sums.size());
    CHECK(!VerifySumsSignature(sums + "x", signature, key, error));
    CHECK(!VerifySumsSignature(sums.substr(0, sums.size() - 1), signature, key, error));
    CHECK(!VerifySumsSignature(sums, "AAAA", key, error));
    CHECK(!VerifySumsSignature(sums, "", key, error));
    CHECK(!VerifySumsSignature(sums, "!!!!", key, error));
    CHECK(!VerifySumsSignature(sums, std::string(86, 'A') + "==", key, error));
    // A key that is not a point on the curve.
    CHECK(!VerifySumsSignature(sums, signature, "BA" + std::string(85, 'A') + "=", error));
    // Whitespace around the key, as a file holding it has.
    CHECK(VerifySumsSignature(sums, signature, "  " + Trim(key) + "\r\n", error));
}

void TestVouch(const std::wstring& dir) {
    const std::string sums = ReadVector(dir, L"SHA256SUMS");
    const std::string signature = ReadVector(dir, L"SHA256SUMS.sig");
    const std::string key = ReadVector(dir, L"test-key.pub.b64");
    std::string sha256;
    std::string error;
    CHECK(VouchFor(sums, signature, key, "SolStreamSetup-9.9.9.exe", sha256, error)
          == Vouched::Yes);
    CHECK(sha256 == "a0b1c2d3e4f5061728394a5b6c7d8e9fa0b1c2d3e4f5061728394a5b6c7d8e9f");
    // The anti-rollback check: 9.9.9's genuine, signed sums served under a
    // newer tag do not vouch for that tag's installer.
    CHECK(VouchFor(sums, signature, key, "SolStreamSetup-10.0.0.exe", sha256, error)
          == Vouched::NotListed);
    CHECK(sha256.empty());
    // The Mac's asset is listed, and is not the Windows installer.
    CHECK(VouchFor(sums, signature, key, "SolStreamSetup-9.9.9.exe.zip", sha256, error)
          == Vouched::NotListed);
    std::string tampered = sums;
    tampered[0] = tampered[0] == '3' ? '4' : '3';
    CHECK(VouchFor(tampered, signature, key, "SolStreamSetup-9.9.9.exe", sha256, error)
          == Vouched::NotSigned);
    CHECK(VouchFor(sums, signature, kPublicKey, "SolStreamSetup-9.9.9.exe", sha256, error)
          == Vouched::NotSigned);
}

void TestSums(const std::wstring& dir) {
    std::vector<std::pair<std::string, std::string>> entries;
    std::string error;
    CHECK(ParseSums(ReadVector(dir, L"SHA256SUMS"), entries, error));
    CHECK(entries.size() == 2 && entries[1].first == "SolStreamSetup-9.9.9.exe");
    const std::string hex(64, 'a');
    CHECK(ParseSums(hex + "  A.exe\n", entries, error));
    CHECK(!ParseSums(hex + "  A.exe", entries, error));                     // no newline
    CHECK(!ParseSums(hex + "  A.exe\r\n", entries, error));                 // CRLF
    CHECK(!ParseSums(std::string(64, 'A') + "  A.exe\n", entries, error));  // uppercase
    CHECK(!ParseSums(hex + " *A.exe\n", entries, error));                   // binary marker
    CHECK(!ParseSums(hex + "  \n", entries, error));                        // no name
    CHECK(!ParseSums(hex + "  a/b.exe\n", entries, error));                 // a path
    CHECK(!ParseSums(hex + "  ..\\b.exe\n", entries, error));               // a path
    CHECK(!ParseSums(hex + "  A.exe\n" + hex + "  A.exe\n", entries, error));
    CHECK(!ParseSums("\n", entries, error));
    CHECK(!ParseSums("", entries, error));
    CHECK(!ParseSums(hex.substr(1) + "  A.exe\n", entries, error));
}

void TestRelease() {
    ReleaseInfo info;
    std::string error;
    const std::string good = R"({
  "url": "https://api.github.com/repos/Bruno-Alumn/SolStream/releases/1",
  "tag_name": "v1.2.3",
  "draft": false,
  "prerelease": false,
  "body": "Fixes \"tag_name\": \"v99.0.0\", and {\"tag_name\":\"v98.0.0\"} é 😀 \ud800 lone",
  "author": {"login": "x", "tag_name": "v97.0.0", "id": 1.5e3},
  "assets": [
    {"url": "https://api.github.com/repos/Bruno-Alumn/SolStream/releases/assets/10",
     "name": "SolStreamSetup-1.2.3.exe", "size": 612345,
     "browser_download_url": "https:\/\/github.com\/Bruno-Alumn\/SolStream\/releases\/download\/v1.2.3\/SolStreamSetup-1.2.3.exe",
     "uploader": {"tag_name": "nope", "size": 1}},
    {"url": "https://api.github.com/repos/Bruno-Alumn/SolStream/releases/assets/11",
     "name": "SHA256SUMS", "size": 183,
     "browser_download_url": "https://github.com/Bruno-Alumn/SolStream/releases/download/v1.2.3/SHA256SUMS"}
  ],
  "nested": [[[[]]]], "nul": null, "neg": -0.5E-3
})";
    CHECK(ParseRelease(good, info, error));
    CHECK(info.tag == "v1.2.3" && !info.draft && !info.prerelease);
    CHECK(info.assets.size() == 2);
    if (info.assets.size() == 2) {
        CHECK(info.assets[0].name == "SolStreamSetup-1.2.3.exe");
        CHECK(info.assets[0].size == 612345);
        CHECK(info.assets[0].download_url
              == "https://github.com/Bruno-Alumn/SolStream/releases/download/v1.2.3/"
                 "SolStreamSetup-1.2.3.exe");
        CHECK(info.assets[0].api_url
              == "https://api.github.com/repos/Bruno-Alumn/SolStream/releases/assets/10");
        CHECK(info.assets[1].size == 183);
    }
    // A key inside a string is only text. These literals stay outside CHECK:
    // MSVC cannot stringize a raw string that holds backslashes (C2017).
    const std::string quoted_key = R"({"body":"\"tag_name\":\"v9.9.9\"","tag_name":"v1.0.0"})";
    const std::string only_quoted_key = R"({"body":"\"tag_name\":\"v9.9.9\""})";
    CHECK(ParseRelease(quoted_key, info, error) && info.tag == "v1.0.0");
    CHECK(!ParseRelease(only_quoted_key, info, error));
    // A field named twice is not chosen between.
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","tag_name":"v9.0.0"})", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","draft":false,"draft":true})", info, error));
    CHECK(!ParseRelease(R"({"tag_name":1})", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","draft":"false"})", info, error));
    CHECK(ParseRelease(R"({"tag_name":"v1.0.0","draft":true})", info, error) && info.draft);
    CHECK(ParseRelease(R"({"tag_name":"v1.0.0","prerelease":true})", info, error)
          && info.prerelease);
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","assets":{}})", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","assets":[{"name":"a","size":-1}]})", info,
                        error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","assets":[{"name":"a","size":1.0}]})", info,
                        error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","assets":[{"name":"a","size":"1"}]})", info,
                        error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","assets":[{"name":"a"}]})", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","assets":[{"size":1}]})", info, error));
    // Not JSON.
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0")", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0"} x)", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0",})", info, error));
    CHECK(!ParseRelease(R"({'tag_name':"v1.0.0"})", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","x":01})", info, error));
    CHECK(!ParseRelease(R"({"tag_name":"v1.0.0","x":tru})", info, error));
    const std::string bad_escape = R"({"tag_name":"v1.0.0","x":"\q"})";
    CHECK(!ParseRelease(bad_escape, info, error));
    CHECK(!ParseRelease(std::string("{\"tag_name\":\"v1\n.0.0\"}"), info, error));
    CHECK(!ParseRelease(R"(["tag_name","v1.0.0"])", info, error));
    CHECK(!ParseRelease("", info, error));
    // Deep enough for anything real; a hostile depth is refused, not recursed.
    std::string deep = "{\"tag_name\":\"v1.0.0\",\"x\":";
    deep += std::string(64, '[') + std::string(64, ']') + "}";
    CHECK(ParseRelease(deep, info, error));
    std::string deeper = "{\"tag_name\":\"v1.0.0\",\"x\":";
    deeper += std::string(100000, '[') + std::string(100000, ']') + "}";
    CHECK(!ParseRelease(deeper, info, error));
    Json root;
    const std::string lone_surrogate = R"({"s":"é😀\ud800x"})";
    CHECK(JsonReader(lone_surrogate).Document(root));
    CHECK(root.values.size() == 1
          && root.values[0].text == "\xC3\xA9\xF0\x9F\x98\x80\xEF\xBF\xBDx");
}

void TestResolve() {
    Target target;
    std::string error;
    CHECK(Resolve(L"https://api.github.com/repos/a/b/releases/latest", target, error)
          && target.host == L"api.github.com" && target.path == L"/repos/a/b/releases/latest");
    CHECK(Resolve(L"https://GitHub.com/x?y=1&z", target, error) && target.path == L"/x?y=1&z");
    CHECK(Resolve(L"https://release-assets.githubusercontent.com/a?sig=1", target, error));
    CHECK(Resolve(L"https://objects.githubusercontent.com/", target, error));
    CHECK(Resolve(L"https://github.com:443/x", target, error));
    CHECK(!Resolve(L"http://github.com/x", target, error));
    CHECK(!Resolve(L"https://github.com:8443/x", target, error));
    CHECK(!Resolve(L"https://evil.example/x", target, error));
    CHECK(!Resolve(L"https://github.com.evil.example/x", target, error));
    CHECK(!Resolve(L"https://evilgithub.com/x", target, error));
    CHECK(!Resolve(L"https://user:pw@github.com/x", target, error));
    CHECK(!Resolve(L"https://raw.githubusercontent.com/x", target, error));
    CHECK(!Resolve(L"ftp://github.com/x", target, error));
    CHECK(!Resolve(L"github.com/x", target, error));
}

void TestCommandLine(const std::wstring& dir, const std::wstring& scratch) {
    std::wstring sums = dir + L"\\SHA256SUMS";
    std::wstring signature = dir + L"\\SHA256SUMS.sig";
    std::wstring key = ToWide(Trim(ReadVector(dir, L"test-key.pub.b64")));
    std::wstring key_file = dir + L"\\test-key.pub.b64";
    {
        wchar_t* argv[] = {sums.data(), signature.data(), key.data()};
        CHECK(VerifySignatureCommand(3, argv) == 0);
    }
    {
        wchar_t* argv[] = {sums.data(), signature.data(), key_file.data()};
        CHECK(VerifySignatureCommand(3, argv) == 0);
    }
    {
        // The compiled-in production key.
        wchar_t* argv[] = {sums.data(), signature.data()};
        CHECK(VerifySignatureCommand(2, argv) == 1);
    }
    {
        // What CI does: one byte of a copy changed.
        std::string bytes = ReadVector(dir, L"SHA256SUMS");
        bytes[0] = (char) (bytes[0] ^ 1);
        std::wstring tampered = scratch + L"\\SHA256SUMS";
        CHECK(WriteAll(tampered, bytes));
        wchar_t* argv[] = {tampered.data(), signature.data(), key.data()};
        CHECK(VerifySignatureCommand(3, argv) == 1);
    }
    {
        std::wstring missing = scratch + L"\\no-such-file";
        wchar_t* argv[] = {missing.data(), signature.data(), key.data()};
        CHECK(VerifySignatureCommand(3, argv) == 1);
    }
    {
        wchar_t* argv[] = {sums.data()};
        CHECK(VerifySignatureCommand(1, argv) == 2);
    }
}

/// Never sideways or down, whatever the pretend version says: the guard is
/// against the version this copy was built as, and it stops before anything is
/// downloaded or run.
void TestNoDowngrade() {
    SetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", L"0.0.1");
    for (const char* version : {SOLSTREAM_VERSION_STRING, "0.0.2", "0.9.9"}) {
        Release release;
        release.version = version;
        InstallOptions options;
        std::string error;
        bool stepped = false;
        const bool ran = InstallUpdate(release, nullptr, options,
                                       [&](const std::wstring&) { stepped = true; },
                                       [] { return true; }, nullptr, error);
        CHECK(!ran);
        CHECK(!stepped);
        CHECK(error == "This copy of SolStream is already up to date.");
    }
    SetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", nullptr);
}

/// Every elevated command runs its System32 program, whatever paths its
/// arguments carry: a ':' in an argument used to skip the rewrite, so the
/// setup's tar and netsh were searched for beside the setup in Downloads.
void TestQualifyCommand() {
    wchar_t dir[MAX_PATH] = {0};
    GetSystemDirectoryW(dir, MAX_PATH);
    const std::wstring sys = L"\"" + std::wstring(dir) + L"\\";
    const std::wstring tar = L"tar.exe -xf \"C:\\ProgramData\\x\\d.zip\" -C \"C:\\ProgramData\\x\"";
    CHECK(QualifySystemCommand(tar)
          == sys + L"tar.exe\" -xf \"C:\\ProgramData\\x\\d.zip\" -C \"C:\\ProgramData\\x\"");
    const std::wstring netsh = L"netsh.exe advfirewall firewall add rule program=\"C:\\Program Files\\S.exe\"";
    CHECK(QualifySystemCommand(netsh).rfind(sys + L"netsh.exe\" advfirewall", 0) == 0);
    CHECK(QualifySystemCommand(L"schtasks.exe /run") == sys + L"schtasks.exe\" /run");
    CHECK(QualifySystemCommand(L"\"pnputil.exe\" /enum-drivers") == sys + L"pnputil.exe\" /enum-drivers");
    CHECK(QualifySystemCommand(L"whoami") == sys + L"whoami.exe\"");
    // Windows PowerShell is under System32, not in it; named as plain
    // System32\powershell.exe it never started, and the installer's stop and
    // firewall sweep silently did nothing.
    CHECK(QualifySystemCommand(L"powershell.exe -NoProfile -Command \"Stop-Process C:\\x\"")
          == sys + L"WindowsPowerShell\\v1.0\\powershell.exe\" -NoProfile -Command \"Stop-Process C:\\x\"");
    CHECK(QualifySystemCommand(L"PowerShell.EXE -c x").rfind(sys + L"WindowsPowerShell\\v1.0\\PowerShell.EXE\"", 0) == 0);
    // Given by path, it is left alone.
    const std::wstring quoted = L"\"C:\\Program Files\\SolStream\\SolStream.exe\" --x";
    CHECK(QualifySystemCommand(quoted) == quoted);
    CHECK(QualifySystemCommand(L"C:\\Tools\\a.exe b") == L"C:\\Tools\\a.exe b");
    CHECK(QualifySystemCommand(L"sub\\a.exe b") == L"sub\\a.exe b");
    CHECK(CommandProgram(quoted) == L"C:\\Program Files\\SolStream\\SolStream.exe");
    CHECK(CommandProgram(tar) == L"tar.exe");
}

/// Everything the host writes into a JSON line reaches the Mac as UTF-8, or it
/// costs the connection: the Mac refuses a whole line over one bad byte.
void TestJsonEscape() {
    const std::string fffd = "\xEF\xBF\xBD";
    // Text from the wide APIs passes through untouched, whatever its script.
    const std::string french = ToUtf8(L"Sécurité Windows — Paramètres");
    CHECK(JsonEscape(french) == french);
    const std::string japanese = ToUtf8(L"Windows セキュリティ");
    CHECK(JsonEscape(japanese) == japanese);
    const std::string emoji = ToUtf8(L"JÜRGEN-PC \U0001F600");
    CHECK(JsonEscape(emoji) == emoji);
    // What the escaping was always for.
    CHECK(JsonEscape("say \"hi\"\\\n\r\t") == "say \\\"hi\\\"\\\\\\n\\r\\t");
    CHECK(JsonEscape(std::string("a\x01" "b", 3)) == "a\\u0001b");
    CHECK(JsonEscape("") == "");
    // The same title read with the ANSI call on a Western PC: é is a lone 0xE9
    // in code page 1252, and an em dash is 0x97.
    CHECK(JsonEscape("S" "\xE9" "curit" "\xE9" " " "\x97" " x")
          == "S" + fffd + "curit" + fffd + " " + fffd + " x");
    // Code page 932: "セ" is 0x83 0x5A, which is no UTF-8 at all; the
    // trailing byte is plain ASCII and survives.
    CHECK(JsonEscape("\x83" "Z") == fffd + "Z");
    // One replacement per broken sequence, not per byte: an unfinished
    // three-byte sequence before ASCII, and one cut off at the end.
    CHECK(JsonEscape("\xE2\x82" "A") == fffd + "A");
    CHECK(JsonEscape("A" "\xE2\x82") == "A" + fffd);
    CHECK(JsonEscape("\xE2(" "\xA1") == fffd + "(" + fffd);
    // Forms a strict parser refuses: a stray continuation byte, an overlong
    // '/', an encoded surrogate, and a code point past U+10FFFF.
    CHECK(JsonEscape("\x80") == fffd);
    CHECK(JsonEscape("\xC0\xAF") == fffd + fffd);
    CHECK(JsonEscape("\xED\xA0\x80") == fffd + fffd + fffd);
    CHECK(JsonEscape("\xF4\x90\x80\x80") == fffd + fffd + fffd + fffd);
    // The edges of what is allowed stay allowed.
    CHECK(JsonEscape("\xF4\x8F\xBF\xBF") == "\xF4\x8F\xBF\xBF");
    CHECK(JsonEscape("\xEF\xBF\xBD") == fffd);
}

/// The display driver is the one install option named for what it turns ON:
/// absent must mean "download nothing", for anybody typing --install by hand.
void TestInstallOptions() {
    auto round_trip = [](const InstallOptions& options) {
        const std::wstring line = L"SolStream.exe --install" + OptionArguments(options);
        int argc = 0;
        wchar_t** argv = CommandLineToArgvW(line.c_str(), &argc);
        InstallOptions parsed = OptionsFromArguments(argc, argv);
        LocalFree(argv);
        return parsed;
    };
    InstallOptions plain;
    CHECK(!plain.display_driver);
    CHECK(OptionArguments(plain).find(L"--with-display-driver") == std::wstring::npos);
    CHECK(!round_trip(plain).display_driver);

    InstallOptions chosen;
    chosen.display_driver = true;
    chosen.start_at_logon = false;
    const InstallOptions parsed = round_trip(chosen);
    CHECK(parsed.display_driver);
    CHECK(!parsed.start_at_logon);
    CHECK(parsed.desktop_shortcut);
}

/// The task that starts the installed host. Task Scheduler cannot be asked
/// here, so these read the definition it would be handed.
void TestLogonTask() {
    const std::wstring at_logon = LogonTaskXml(L"PC\\me", L"C:\\Program Files\\SolStream", true);
    const std::wstring on_demand = LogonTaskXml(L"PC\\me", L"C:\\Program Files\\SolStream", false);
    // Normal priority, inside <Settings>. Left out, Task Scheduler's default
    // of 7 ran the host below normal, and every application the Mac opened
    // inherited it.
    for (const std::wstring& xml : {at_logon, on_demand}) {
        const size_t settings = xml.find(L"<Settings>");
        const size_t priority = xml.find(L"<Priority>4</Priority>");
        CHECK(settings != std::wstring::npos);
        CHECK(priority != std::wstring::npos);
        CHECK(priority > settings && priority < xml.find(L"</Settings>"));
        CHECK(xml.find(L"<Command>C:\\Program Files\\SolStream\\SolStream.exe</Command>")
              != std::wstring::npos);
        CHECK(xml.find(L"<RunLevel>LeastPrivilege</RunLevel>") != std::wstring::npos);
        CHECK(xml.find(L"<LogonType>InteractiveToken</LogonType>") != std::wstring::npos);
    }
    // At this account's logon only: a trigger naming nobody fires for every
    // account on the PC, and restarted the host in the installer's session
    // whenever somebody else logged on.
    CHECK(at_logon.find(L"<LogonTrigger><Enabled>true</Enabled><UserId>PC\\me</UserId>"
                        L"</LogonTrigger>")
          != std::wstring::npos);
    CHECK(at_logon.find(L"<Principal id=\"Author\">\r\n    <UserId>PC\\me</UserId>")
          != std::wstring::npos);
    CHECK(LogonTaskXml(L"S-1-5-21-1-2-3-1001", L"C:\\x", true)
              .find(L"<UserId>S-1-5-21-1-2-3-1001</UserId></LogonTrigger>")
          != std::wstring::npos);
    CHECK(LogonTaskXml(L"PC\\R&D", L"C:\\x", true)
              .find(L"<UserId>PC\\R&amp;D</UserId></LogonTrigger>")
          != std::wstring::npos);
    CHECK(on_demand.find(L"<LogonTrigger>") == std::wstring::npos);
    CHECK(on_demand.find(L"<Triggers />") != std::wstring::npos);
    // An & is legal in a Windows user name, and unescaped it made the whole
    // definition malformed.
    CHECK(LogonTaskXml(L"PC\\R&D", L"C:\\x", false).find(L"<UserId>PC\\R&amp;D</UserId>")
          != std::wstring::npos);
}

/// Who the logon task is registered for: the account a SID names, spelled as
/// Windows names it and then as the SID. Never a guess -- the computer's name
/// pasted in front of a user name named nobody on a domain PC.
void TestLogonTaskAccounts() {
    CHECK(LogonTaskAccounts(L"").empty());
    CHECK(LogonTaskAccounts(L"PC\\me").empty());
    CHECK(LogonTaskAccounts(L"S-1-5-18 & <x>").empty());

    const std::vector<std::wstring> system = LogonTaskAccounts(L"S-1-5-18");
    CHECK(!system.empty() && system.back() == L"S-1-5-18");
    for (const std::wstring& account : system) {
        CHECK(!account.empty());
    }
    if (system.size() == 2) {
        CHECK(system.front().rfind(L"S-1-", 0) != 0);
    }

    // This process's own account, which is the candidate when no SID was
    // passed: whatever Windows calls it, the SID itself is always offered.
    HANDLE token = nullptr;
    std::wstring own;
    if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        alignas(TOKEN_USER) unsigned char buffer[256] = {0};
        DWORD size = sizeof(buffer);
        wchar_t* text = nullptr;
        if (GetTokenInformation(token, TokenUser, buffer, size, &size)
            && ConvertSidToStringSidW(((TOKEN_USER*) buffer)->User.Sid, &text)) {
            own = text;
            LocalFree(text);
        }
        CloseHandle(token);
    }
    CHECK(!own.empty());
    const std::vector<std::wstring> mine = LogonTaskAccounts(own);
    CHECK(!mine.empty() && mine.back() == own);
}

/// The two rules the installer writes. Every profile: on a PC at its
/// company's office Windows uses the Domain profile, and a rule for only
/// Private and Public left the Mac unanswered there.
void TestFirewallRule() {
    const std::wstring rule = FirewallRuleCommand(
        L"SolStream - agent", L"C:\\Program Files\\SolStream\\SolStream.exe", L"TCP", L"47630");
    CHECK(rule.rfind(L"netsh.exe advfirewall firewall add rule", 0) == 0);
    CHECK(rule.find(L" profile=any ") != std::wstring::npos);
    CHECK(rule.find(L"private,public") == std::wstring::npos);
    // Still narrow: the one program, the one protocol, the named ports.
    CHECK(rule.find(L" program=\"C:\\Program Files\\SolStream\\SolStream.exe\" ")
          != std::wstring::npos);
    CHECK(rule.find(L" dir=in action=allow ") != std::wstring::npos);
    CHECK(rule.find(L" protocol=TCP localport=47630 ") != std::wstring::npos);
}

/// The uninstall's sweep of rules pointing into the install folder: one query
/// over the program filters rather than one per rule on the PC, and only
/// inside the folder, not beside it.
void TestFirewallSweep() {
    const std::wstring sweep = FirewallSweepCommand(L"C:\\Program Files\\SolStream");
    CHECK(sweep.rfind(L"powershell.exe -NoProfile ", 0) == 0);
    // The prefix ends in a backslash, so "SolStreamOld" beside it is not
    // matched.
    CHECK(sweep.find(L"$dir = 'C:\\Program Files\\SolStream\\';") != std::wstring::npos);
    // Filters first, all at once, then only the rules behind the matches.
    const size_t filters = sweep.find(L"Get-NetFirewallApplicationFilter");
    const size_t rules = sweep.find(L"Get-NetFirewallRule");
    const size_t remove = sweep.find(L"Remove-NetFirewallRule");
    CHECK(filters != std::wstring::npos && rules != std::wstring::npos
          && remove != std::wstring::npos);
    CHECK(filters < rules && rules < remove);
    CHECK(sweep.find(L"ForEach-Object") == std::wstring::npos);
    // No wildcard match: a folder name is not a pattern.
    CHECK(sweep.find(L"-like") == std::wstring::npos);
    CHECK(sweep.find(L"OrdinalIgnoreCase") != std::wstring::npos);
    // One quoted -Command, closed at the very end.
    CHECK(sweep.back() == L'"');
    CHECK(std::count(sweep.begin(), sweep.end(), L'"') == 2);
}

/// Each spelling of the task's account in turn until Task Scheduler takes one:
/// a domain account whose controller is out of reach cannot be named, and the
/// task still has to register, under the SID.
void TestRegisterUnderAccounts() {
    const std::vector<std::wstring> accounts = {L"PC\\me", L"S-1-5-21-1-2-3-1001"};
    std::vector<std::wstring> tried;
    std::string error;

    // The name refused: the SID is tried next, and taken.
    auto name_refused = [&tried](const std::wstring& account, std::string& failure) {
        tried.push_back(account);
        if (account == L"PC\\me") {
            failure = "Could not register the task (0x80070534).";
            return false;
        }
        return true;
    };
    CHECK(RegisterUnderAccounts(accounts, name_refused, error) == 1);
    CHECK(tried == accounts);

    // Both refused: what is reported is the name's failure, the form that has
    // always worked, not the SID's.
    tried.clear();
    auto both_refused = [&tried](const std::wstring& account, std::string& failure) {
        tried.push_back(account);
        failure = account == L"PC\\me" ? "the name was refused" : "the SID was refused";
        return false;
    };
    CHECK(RegisterUnderAccounts(accounts, both_refused, error) == -1);
    CHECK(tried == accounts);
    CHECK(error == "the name was refused");

    // The name taken: nothing else is tried.
    tried.clear();
    error.clear();
    auto name_taken = [&tried](const std::wstring& account, std::string&) {
        tried.push_back(account);
        return true;
    };
    CHECK(RegisterUnderAccounts(accounts, name_taken, error) == 0);
    CHECK(tried.size() == 1);
    CHECK(error.empty());
}

/// The end of an install starts the host through its task even when the task
/// would not register: on an update the one an earlier install registered
/// names the same path, and skipping it left the PC with no SolStream until
/// the next logon.
void TestHostTaskStart() {
    const std::vector<std::string> both = {"register", "run"};
    std::vector<std::string> steps;
    auto refused = [&steps](std::string& failure) {
        steps.push_back("register");
        failure = "Could not register the task (0x80070005).";
        return false;
    };
    auto started = [&steps] {
        steps.push_back("run");
        return 0ul;
    };
    const HostTaskResult unregistered = RegisterAndRunHostTask(refused, started);
    CHECK(steps == both);
    CHECK(!unregistered.registered);
    CHECK(unregistered.register_error == "Could not register the task (0x80070005).");
    CHECK(unregistered.started == 0);

    // Registered, and the run's answer carried back as it came, so a failed
    // start can be warned about.
    steps.clear();
    auto registered = [&steps](std::string&) {
        steps.push_back("register");
        return true;
    };
    auto not_started = [&steps] {
        steps.push_back("run");
        return 1ul;
    };
    const HostTaskResult result = RegisterAndRunHostTask(registered, not_started);
    CHECK(steps == both);
    CHECK(result.registered);
    CHECK(result.register_error.empty());
    CHECK(result.started == 1);
}

/// An update or an uninstall asks the running host to quit before anything is
/// stopped by force: only quitting takes its tray icon away and gives back the
/// windows it was streaming.
void TestStopInstalled() {
    std::vector<std::wstring> steps;
    StopInstalled(
        L"C:\\Program Files\\SolStream",
        [&steps](const std::wstring& directory) { steps.push_back(L"ask " + directory); },
        [&steps](const std::wstring& directory) { steps.push_back(L"force " + directory); });
    const std::vector<std::wstring> expected = {L"ask C:\\Program Files\\SolStream",
                                                L"force C:\\Program Files\\SolStream"};
    CHECK(steps == expected);
}

void TestEnvironment() {
    SetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", L"0.9.0");
    CHECK(CurrentVersion() == "0.9.0");
    SetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", L"v2.3.4");
    CHECK(CurrentVersion() == "2.3.4");
    SetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", L"banana");
    CHECK(CurrentVersion() == SOLSTREAM_VERSION_STRING);
    SetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", nullptr);
    CHECK(CurrentVersion() == SOLSTREAM_VERSION_STRING);

    // Not a real token: the shape of one, to see it is carried and wiped.
    SetEnvironmentVariableW(L"SOLSTREAM_GITHUB_TOKEN", L"ghp_TESTONLYnotarealtoken0");
    {
        Token token;
        CHECK(token.present());
        std::wstring header;
        token.Header(header);
        CHECK(header == L"Authorization: Bearer ghp_TESTONLYnotarealtoken0\r\n");
        WipeText(header);
        CHECK(header.empty());
    }
    // Anything that would add a header line of its own is refused.
    SetEnvironmentVariableW(L"SOLSTREAM_GITHUB_TOKEN", L"ghp_TESTONLY\r\nX-Evil: 1");
    {
        Token token;
        CHECK(!token.present());
    }
    SetEnvironmentVariableW(L"SOLSTREAM_GITHUB_TOKEN", L"");
    {
        Token token;
        CHECK(!token.present());
    }
    SetEnvironmentVariableW(L"SOLSTREAM_GITHUB_TOKEN", nullptr);
    CHECK(g_log.find("TESTONLY") == std::string::npos);
}

// ── The download ─────────────────────────────────────────────────────────────

/// A release whose "installer" is `bytes`, already in Updates, so
/// PrepareInstaller reuses it and never reaches for the network: neither URL is
/// set, and with no token that fails before anything is sent.
Release LocalRelease(const std::string& bytes) {
    unsigned char digest[32] = {0};
    Sha256((const unsigned char*) bytes.data(), bytes.size(), digest);
    Release release;
    release.version = "9.9.9";
    release.installer.name = "SolStreamSetup-9.9.9.exe";
    release.installer.size = bytes.size();
    release.sha256 = ToHex(digest, sizeof(digest));
    return release;
}

void TestDownload() {
    const std::wstring updates = UpdatesDirectory(true);
    CHECK(!updates.empty());
    const std::string bytes = "MZ not really an installer, but bytes with a known hash";
    const Release release = LocalRelease(bytes);
    const std::wstring installer = updates + L"\\SolStreamSetup-9.9.9.exe";
    CHECK(WriteAll(installer, bytes));
    // What an earlier update and an interrupted download leave, and the note
    // an install leaves for the copy after it.
    CHECK(WriteAll(updates + L"\\SolStreamSetup-0.0.1.exe", "old"));
    CHECK(WriteAll(updates + L"\\junk.partial", "half"));
    WriteInstallNote("9.9.9");

    auto step = [](const std::wstring&) {};
    HANDLE held = INVALID_HANDLE_VALUE;
    std::wstring path;
    std::string error;
    CHECK(PrepareInstaller(release, step, held, path, error));
    CHECK(held != INVALID_HANDLE_VALUE);
    if (held == INVALID_HANDLE_VALUE) {
        std::printf("  PrepareInstaller: %s\n", error.c_str());
        return;
    }
    CHECK(!Exists(updates + L"\\SolStreamSetup-0.0.1.exe"));
    CHECK(!Exists(updates + L"\\junk.partial"));
    CHECK(Exists(InstallNotePath()));

    // The path it starts from is where the hold is, spelled out in full.
    CHECK(path.rfind(L"\\\\?\\", 0) != 0);
    CHECK(path.size() > 3 && path[1] == L':' && path[2] == L'\\');
    CHECK(FoldCase(path).size() >= 24
          && FoldCase(path).compare(path.size() - 24, 24, L"solstreamsetup-9.9.9.exe") == 0);
    HANDLE again = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                               OPEN_EXISTING, 0, nullptr);
    CHECK(again != INVALID_HANDLE_VALUE && SameFile(held, again));
    if (again != INVALID_HANDLE_VALUE) {
        CloseHandle(again);
    }

    // While held: no writer, no rename, no delete -- but a reader the way
    // CreateProcess opens an image, the installer's own hold on itself, and
    // its copy into Program Files by path all still work.
    HANDLE writer = CreateFileW(path.c_str(), GENERIC_WRITE,
                                FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                                OPEN_EXISTING, 0, nullptr);
    CHECK(writer == INVALID_HANDLE_VALUE);
    if (writer != INVALID_HANDLE_VALUE) {
        CloseHandle(writer);
    }
    CHECK(!MoveFileW(path.c_str(), (path + L".moved").c_str()));
    CHECK(!DeleteFileW(path.c_str()));
    HANDLE image = CreateFileW(path.c_str(), GENERIC_READ | FILE_EXECUTE,
                               FILE_SHARE_READ | FILE_SHARE_DELETE, nullptr, OPEN_EXISTING, 0,
                               nullptr);
    CHECK(image != INVALID_HANDLE_VALUE);
    HANDLE self = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    CHECK(self != INVALID_HANDLE_VALUE);
    CHECK(CopyFileW(path.c_str(), (updates + L"\\copied.bin").c_str(), FALSE));
    DeleteFileW((updates + L"\\copied.bin").c_str());
    if (self != INVALID_HANDLE_VALUE) {
        CloseHandle(self);
    }
    if (image != INVALID_HANDLE_VALUE) {
        CloseHandle(image);
    }
    // Nor can the folder it is in be moved out from under the path. Wine keeps
    // POSIX rules for folders, so this one is Windows' word only.
    if (!UnderWine()) {
        CHECK(!MoveFileW(updates.c_str(), (updates + L"-moved").c_str()));
    }
    CloseHandle(held);

    // A file that no longer matches the signed checksum is thrown away, and
    // with nowhere to download from, nothing takes its place.
    Release wrong = release;
    wrong.sha256[0] = wrong.sha256[0] == 'a' ? 'b' : 'a';
    CHECK(!PrepareInstaller(wrong, step, held, path, error));
    CHECK(held == INVALID_HANDLE_VALUE);
    CHECK(!Exists(installer));
    CHECK(!Exists(installer + L".partial"));

    // Nor is one of the wrong size, hash unread.
    CHECK(WriteAll(installer, bytes + "x"));
    CHECK(!PrepareInstaller(release, step, held, path, error));
    CHECK(!Exists(installer));

    DeleteFileW(InstallNotePath().c_str());
}

/// The download's folder swapped for a junction to somewhere else: the
/// installer is held where the junction led, and started from THERE, by a path
/// with no junction left in it to re-point.
void TestJunction(const std::wstring& scratch) {
    const std::wstring updates = UpdatesDirectory(false);
    const std::wstring elsewhere = scratch + L"\\elsewhere";
    CHECK(CreateDirectoryW(elsewhere.c_str(), nullptr));
    RemoveTree(updates);
    if (!MakeJunction(updates, elsewhere)) {
        std::printf("  (junction test skipped: could not make a junction here)\n");
        return;
    }
    const std::string bytes = "the genuine installer";
    const Release release = LocalRelease(bytes);
    CHECK(WriteAll(updates + L"\\SolStreamSetup-9.9.9.exe", bytes));
    HANDLE held = INVALID_HANDLE_VALUE;
    std::wstring path;
    std::string error;
    CHECK(PrepareInstaller(release, [](const std::wstring&) {}, held, path, error));
    if (held != INVALID_HANDLE_VALUE) {
        const std::wstring folded = FoldCase(path);
        CHECK(folded.find(L"\\elsewhere\\solstreamsetup-9.9.9.exe") != std::wstring::npos);
        CHECK(folded.find(L"\\updates\\") == std::wstring::npos);
        CloseHandle(held);
    }
    RemoveDirectoryW(updates.c_str());
}

// ── The note an install leaves ───────────────────────────────────────────────

void TestInstallNote() {
    Version running;
    CHECK(ParseVersion(SOLSTREAM_VERSION_STRING, running));
    Version newer = running;
    ++newer.parts[2];

    CHECK(TakeInstallNote().kind == InstallNote::Kind::None);

    WriteInstallNote(SOLSTREAM_VERSION_STRING);
    InstallNote note = TakeInstallNote();
    CHECK(note.kind == InstallNote::Kind::Installed);
    CHECK(note.version == SOLSTREAM_VERSION_STRING);
    CHECK(note.recent);
    // Said once.
    CHECK(!Exists(InstallNotePath()));
    CHECK(TakeInstallNote().kind == InstallNote::Kind::None);

    WriteInstallNote(VersionText(newer));
    note = TakeInstallNote();
    CHECK(note.kind == InstallNote::Kind::NotInstalled);
    CHECK(note.version == VersionText(newer));

    // Older than this copy: something newer was installed since, some other
    // way, and an old note is not news.
    if (running.parts[0] + running.parts[1] + running.parts[2] > 0) {
        WriteInstallNote("0.0.0");
        CHECK(TakeInstallNote().kind == InstallNote::Kind::None);
    }

    WriteInstallNote("not a version");
    CHECK(TakeInstallNote().kind == InstallNote::Kind::None);
    CHECK(!Exists(InstallNotePath()));

    // Written an hour ago: still said, but nobody is waiting at the screen.
    WriteInstallNote(SOLSTREAM_VERSION_STRING);
    HANDLE file = CreateFileW(InstallNotePath().c_str(), FILE_WRITE_ATTRIBUTES, 0, nullptr,
                              OPEN_EXISTING, 0, nullptr);
    CHECK(file != INVALID_HANDLE_VALUE);
    if (file != INVALID_HANDLE_VALUE) {
        FILETIME now{};
        GetSystemTimeAsFileTime(&now);
        ULARGE_INTEGER then{};
        then.LowPart = now.dwLowDateTime;
        then.HighPart = now.dwHighDateTime;
        then.QuadPart -= 60ull * 60ull * 10000000ull;
        FILETIME old{};
        old.dwLowDateTime = then.LowPart;
        old.dwHighDateTime = then.HighPart;
        CHECK(SetFileTime(file, nullptr, nullptr, &old));
        CloseHandle(file);
    }
    note = TakeInstallNote();
    CHECK(note.kind == InstallNote::Kind::Installed);
    CHECK(!note.recent);
}

// ── The virtual display's settings, at uninstall ─────────────────────────────

/// A settings folder SolStream made goes with the files it and the driver keep
/// there -- the backup of the settings among them, which once kept the folder
/// on the PC for good while its record was let go. One that holds anything
/// else stays, and says so, so its record can stay too.
void TestDriverSettingsFolder(const std::wstring& scratch) {
    const std::wstring folder = scratch + L"\\VirtualDisplayDriver";
    auto make = [&folder](std::initializer_list<const wchar_t*> files) {
        CHECK(CreateDirectoryW(folder.c_str(), nullptr));
        for (const wchar_t* file : files) {
            CHECK(WriteAll(folder + L"\\" + file, "x"));
        }
    };

    make({L"vdd_settings.xml", L"vdd_settings.xml.solstream-backup", L"option.txt",
          L"adapter.txt"});
    CHECK(RemoveDriverSettingsFolder(folder));
    CHECK(!Exists(folder));
    // Already gone is gone.
    CHECK(RemoveDriverSettingsFolder(folder));

    make({L"vdd_settings.xml", L"somebody-else.txt"});
    CHECK(!RemoveDriverSettingsFolder(folder));
    CHECK(Exists(folder + L"\\somebody-else.txt"));
    CHECK(!Exists(folder + L"\\vdd_settings.xml"));
    RemoveTree(folder);
}

/// In a folder that is somebody else's, the settings file SolStream wrote and
/// its backup go, and nothing else does -- whatever the record names.
void TestDriverSettingsFile(const std::wstring& scratch) {
    const std::wstring folder = scratch + L"\\TheirSettings";
    CHECK(CreateDirectoryW(folder.c_str(), nullptr));
    for (const wchar_t* file : {L"vdd_settings.xml", L"vdd_settings.xml.solstream-backup",
                                L"theirs.xml"}) {
        CHECK(WriteAll(folder + L"\\" + file, "x"));
    }
    CHECK(RemoveDriverSettingsFile(folder + L"\\vdd_settings.xml"));
    CHECK(!Exists(folder + L"\\vdd_settings.xml"));
    CHECK(RemoveDriverSettingsFile(folder + L"\\VDD_Settings.xml.SolStream-Backup"));
    CHECK(!Exists(folder + L"\\vdd_settings.xml.solstream-backup"));
    // Already gone is gone.
    CHECK(RemoveDriverSettingsFile(folder + L"\\vdd_settings.xml"));
    CHECK(!RemoveDriverSettingsFile(folder + L"\\theirs.xml"));
    CHECK(Exists(folder + L"\\theirs.xml"));
    CHECK(Exists(folder));
    RemoveTree(folder);
}

/// Never through a link: these run elevated, and anybody can make the folder
/// at C:\ first.
void TestDriverSettingsJunction(const std::wstring& scratch) {
    const std::wstring folder = scratch + L"\\LinkedSettings";
    const std::wstring elsewhere = scratch + L"\\settings-elsewhere";
    CHECK(CreateDirectoryW(elsewhere.c_str(), nullptr));
    CHECK(WriteAll(elsewhere + L"\\vdd_settings.xml", "x"));
    if (!MakeJunction(folder, elsewhere)) {
        std::printf("  (settings junction test skipped: could not make a junction here)\n");
        RemoveTree(elsewhere);
        return;
    }
    CHECK(!RemoveDriverSettingsFolder(folder));
    CHECK(!RemoveDriverSettingsFile(folder + L"\\vdd_settings.xml"));
    CHECK(Exists(elsewhere + L"\\vdd_settings.xml"));
    RemoveDirectoryW(folder.c_str());
    RemoveTree(elsewhere);
}

/// Uninstall lets a settings record go only with what it names. A folder that
/// still holds somebody's file is left, and so is its record, or nothing would
/// say again that the folder was SolStream's; the same for a settings file
/// that couldn't be deleted, and for a record naming anything but the
/// settings. The records are in a key of this test's own under HKCU, named at
/// the call, so SolStream's real ones in HKLM are never read.
void TestDriverSettingsRecords(const std::wstring& scratch) {
    const std::wstring key =
        L"Software\\SolStreamUpdaterTests-" + std::to_wstring(GetCurrentProcessId());
    HKEY records = nullptr;
    // Volatile, so it goes at logoff even if this stops before deleting it.
    if (RegCreateKeyExW(HKEY_CURRENT_USER, key.c_str(), 0, nullptr, REG_OPTION_VOLATILE,
                        KEY_SET_VALUE | KEY_QUERY_VALUE, nullptr, &records, nullptr)
        != ERROR_SUCCESS) {
        std::printf("FAIL: could not make a registry key for the settings records\n");
        ++g_failures;
        return;
    }
    auto record = [records](const wchar_t* name, const std::wstring& value) {
        CHECK(RegSetValueExW(records, name, 0, REG_SZ, (const BYTE*) value.c_str(),
                             (DWORD) ((value.size() + 1) * sizeof(wchar_t)))
              == ERROR_SUCCESS);
    };
    auto recorded = [records](const wchar_t* name) {
        return RegQueryValueExW(records, name, nullptr, nullptr, nullptr, nullptr)
            == ERROR_SUCCESS;
    };
    std::string note;
    auto take_back = [&key, &note] {
        note.clear();
        RemoveRecordedDriverSettings(HKEY_CURRENT_USER, key.c_str(), note);
    };

    // A folder SolStream made, where somebody has since put a file the
    // driver reads.
    const std::wstring folder = scratch + L"\\RecordedSettings";
    CHECK(CreateDirectoryW(folder.c_str(), nullptr));
    CHECK(WriteAll(folder + L"\\vdd_settings.xml", "x"));
    CHECK(WriteAll(folder + L"\\user_edid.bin", "x"));
    record(L"DisplayDriverSettingsFolder", folder);
    take_back();
    CHECK(Exists(folder + L"\\user_edid.bin"));
    CHECK(recorded(L"DisplayDriverSettingsFolder"));
    CHECK(note.find("Left the display driver's settings folder") != std::string::npos);
    // With theirs gone, the folder goes, and its record with it.
    CHECK(DeleteFileW((folder + L"\\user_edid.bin").c_str()));
    take_back();
    CHECK(!Exists(folder));
    CHECK(!recorded(L"DisplayDriverSettingsFolder"));
    CHECK(note.empty());

    // The settings file written into somebody else's folder, held open so it
    // can't be deleted, beside a record that names their own file.
    const std::wstring theirs = scratch + L"\\TheirRecordedSettings";
    CHECK(CreateDirectoryW(theirs.c_str(), nullptr));
    const std::wstring settings = theirs + L"\\vdd_settings.xml";
    CHECK(WriteAll(settings, "x"));
    CHECK(WriteAll(theirs + L"\\theirs.xml", "x"));
    record(L"DisplayDriverSettingsFile", settings);
    record(L"DisplayDriverSettingsBackup", theirs + L"\\theirs.xml");
    HANDLE held = CreateFileW(settings.c_str(), GENERIC_READ, 0, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    CHECK(held != INVALID_HANDLE_VALUE);
    take_back();
    CHECK(Exists(settings));
    CHECK(recorded(L"DisplayDriverSettingsFile"));
    CloseHandle(held);
    take_back();
    CHECK(!Exists(settings));
    CHECK(!recorded(L"DisplayDriverSettingsFile"));
    // Not the settings: kept, and its record with it, however often asked.
    CHECK(Exists(theirs + L"\\theirs.xml"));
    CHECK(recorded(L"DisplayDriverSettingsBackup"));
    CHECK(note.find("theirs.xml") != std::string::npos);

    RegCloseKey(records);
    RegDeleteKeyW(HKEY_CURRENT_USER, key.c_str());
    RemoveTree(theirs);
}

/// A device Windows starts at the next restart is an install it has not
/// finished, not a driver somebody switched off -- which is what the window
/// once called SolStream's own new device, sending somebody to Device Manager
/// for an Enable that isn't there.
void TestWaitsForRestart() {
    CHECK(WaitsForRestart(DN_HAS_PROBLEM, CM_PROB_NEED_RESTART));
    CHECK(WaitsForRestart(0, CM_PROB_NEED_RESTART));
    // Failed to start, and Windows says a restart is what it needs.
    CHECK(WaitsForRestart(DN_HAS_PROBLEM | DN_NEED_RESTART, CM_PROB_FAILED_START));
    // Running: there is a display now, whatever the restart would change.
    CHECK(!WaitsForRestart(DN_STARTED, 0));
    CHECK(!WaitsForRestart(DN_STARTED | DN_NEED_RESTART, 0));
    // Switched off, before a restart and after it.
    CHECK(!WaitsForRestart(DN_HAS_PROBLEM, CM_PROB_DISABLED));
    CHECK(!WaitsForRestart(DN_HAS_PROBLEM | DN_NEED_RESTART, CM_PROB_DISABLED));
    // Failing, with nothing said about a restart.
    CHECK(!WaitsForRestart(DN_HAS_PROBLEM, CM_PROB_FAILED_START));
}

// ── Tailscale ────────────────────────────────────────────────────────────────

/// 100.64.0.0/10 is where Tailscale's addresses are, but other VPNs hand out
/// addresses there too; only Tailscale's own adapter counts.
void TestTailscaleAdapter() {
    CHECK(IsTailscaleAdapter(L"Tailscale", L"Tailscale Tunnel", false));
    // Renamed, but still described as itself.
    CHECK(IsTailscaleAdapter(L"Ethernet 4", L"Tailscale Tunnel", false));
    // Named nothing like it, but carrying one of its addresses.
    CHECK(IsTailscaleAdapter(L"vpn", L"Wintun Userspace Tunnel", true));
    CHECK(!IsTailscaleAdapter(L"CloudflareWARP", L"Cloudflare WARP Interface Tunnel", false));
    CHECK(!IsTailscaleAdapter(L"wt0", L"WireGuard Tunnel", false));
    CHECK(!IsTailscaleAdapter(L"Ethernet", L"Realtek PCIe GbE Family Controller", false));

    unsigned char address[16] = {0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0, 0xab, 0x12,
                                 0, 0, 0, 0, 0, 0, 0, 1};
    CHECK(IsTailscaleIpv6(address));
    // The next /48 along.
    address[5] = 0xe1;
    CHECK(!IsTailscaleIpv6(address));
    // Any other unique-local address.
    const unsigned char other[16] = {0xfd, 0x12, 0x34, 0x56, 0x78, 0x9a, 0, 0,
                                     0, 0, 0, 0, 0, 0, 0, 1};
    CHECK(!IsTailscaleIpv6(other));
}

/// The choice among adapters, which the checks above don't reach: a WARP or
/// NetBird address listed first, or an address of Tailscale's on some other
/// adapter, must never be taken for Tailscale's.
void TestPickTailscaleAddress() {
    using Ipv4 = std::array<unsigned char, 4>;
    using Ipv6 = std::array<unsigned char, 16>;
    const Ipv6 tailscale_v6{0xfd, 0x7a, 0x11, 0x5c, 0xa1, 0xe0, 0xab, 0x12,
                            0, 0, 0, 0, 0x4f, 0x01, 0x22, 0x07};
    const Ipv6 link_local{0xfe, 0x80, 0, 0, 0, 0, 0, 0, 0x5d, 0x1c, 0x22, 0xa7, 0, 0, 0, 0x12};
    const Ipv6 warp_v6{0x26, 0x06, 0x47, 0x00, 0x01, 0x10, 0x8a, 0x36,
                       0, 0, 0, 0, 0, 0, 0, 0x02};

    // What each one looks like on a PC: Tailscale's tunnel, Cloudflare WARP
    // (which hands out 100.96.0.0/12 now), NetBird's WireGuard tunnel, and an
    // ordinary network card.
    const NetworkAdapter tailscale{L"Tailscale", L"Tailscale Tunnel", true,
                                   {Ipv4{100, 101, 102, 103}}, {tailscale_v6, link_local}};
    const NetworkAdapter warp{L"CloudflareWARP", L"Cloudflare WARP Interface Tunnel", true,
                              {Ipv4{100, 96, 0, 2}}, {warp_v6, link_local}};
    const NetworkAdapter netbird{L"wt0", L"WireGuard Tunnel", true, {Ipv4{100, 92, 14, 7}},
                                 {link_local}};
    const NetworkAdapter ethernet{L"Ethernet", L"Realtek PCIe GbE Family Controller", true,
                                  {Ipv4{192, 168, 1, 20}}, {link_local}};

    // Tailscale's own, past the others listed ahead of it.
    CHECK(PickTailscaleAddress({ethernet, warp, netbird, tailscale}) == L"100.101.102.103");
    CHECK(PickTailscaleAddress({tailscale, warp}) == L"100.101.102.103");
    // Without it, no address is Tailscale's, whatever range it is in.
    CHECK(PickTailscaleAddress({ethernet, warp}).empty());
    CHECK(PickTailscaleAddress({netbird}).empty());
    CHECK(PickTailscaleAddress({warp, netbird, ethernet}).empty());
    CHECK(PickTailscaleAddress({}).empty());

    // Tailscale's IPv6 prefix on one adapter says nothing about another's
    // 100.x, before it in the list or after.
    const NetworkAdapter v6_only{L"vpn", L"Wintun Userspace Tunnel", true, {}, {tailscale_v6}};
    CHECK(PickTailscaleAddress({v6_only, warp}).empty());
    CHECK(PickTailscaleAddress({warp, v6_only}).empty());
    // On the adapter itself it does: Tailscale's tunnel under another name.
    const NetworkAdapter renamed{L"vpn", L"Wintun Userspace Tunnel", true,
                                 {Ipv4{100, 70, 1, 2}}, {tailscale_v6}};
    CHECK(PickTailscaleAddress({warp, renamed}) == L"100.70.1.2");

    // Down is not connected.
    NetworkAdapter down = tailscale;
    down.up = false;
    CHECK(PickTailscaleAddress({down}).empty());
    CHECK(PickTailscaleAddress({down, warp}).empty());

    // Tailscale's adapter, but only with an address outside the range -- one
    // Windows gave it while it comes up -- and then with one inside it.
    NetworkAdapter starting{L"Tailscale", L"Tailscale Tunnel", true,
                            {Ipv4{169, 254, 83, 107}}, {}};
    CHECK(PickTailscaleAddress({starting}).empty());
    starting.ipv4.push_back(Ipv4{100, 64, 0, 1});
    CHECK(PickTailscaleAddress({starting}) == L"100.64.0.1");

    // The /10's edges.
    for (const Ipv4& outside :
         {Ipv4{100, 63, 255, 255}, Ipv4{100, 128, 0, 0}, Ipv4{101, 64, 0, 1}}) {
        CHECK(PickTailscaleAddress(
                  {NetworkAdapter{L"Tailscale", L"Tailscale Tunnel", true, {outside}, {}}})
                  .empty());
    }
    CHECK(PickTailscaleAddress({NetworkAdapter{L"Tailscale", L"Tailscale Tunnel", true,
                                               {Ipv4{100, 127, 255, 254}}, {}}})
          == L"100.127.255.254");
}

// ── The clipboard ────────────────────────────────────────────────────────────
//
// Here because this is the one C++ test program. Nothing below touches the real
// clipboard: under Wine on a Mac, that is the Mac's own.

/// Global memory holding `size` bytes copied from `bytes`, the way an
/// application hands a format's data to SetClipboardData.
HGLOBAL GlobalBytes(const void* bytes, size_t size) {
    HGLOBAL memory = GlobalAlloc(GMEM_MOVEABLE, size);
    if (memory && size > 0) {
        if (void* target = GlobalLock(memory)) {
            std::memcpy(target, bytes, size);
            GlobalUnlock(memory);
        }
    }
    return memory;
}

void TestClipboardLineEndings() {
    // A Mac's lines become Windows' lines.
    CHECK(ToWindowsLineEndings("one\ntwo\n") == "one\r\ntwo\r\n");
    CHECK(ToWindowsLineEndings("\n") == "\r\n");
    CHECK(ToWindowsLineEndings("\n\n") == "\r\n\r\n");
    // What is already Windows' is left alone, so a Mac that converts and a
    // host that converts again agree with either one doing it alone.
    CHECK(ToWindowsLineEndings("one\r\ntwo") == "one\r\ntwo");
    CHECK(ToWindowsLineEndings(ToWindowsLineEndings("a\nb\r\nc")) == "a\r\nb\r\nc");
    // A CR on its own is not a line ending either side converts.
    CHECK(ToWindowsLineEndings("a\rb") == "a\rb");

    // Windows' lines become a Mac's.
    CHECK(ToMacLineEndings("one\r\ntwo\r\n") == "one\ntwo\n");
    CHECK(ToMacLineEndings("one\ntwo") == "one\ntwo");
    CHECK(ToMacLineEndings("a\rb") == "a\rb");
    CHECK(ToMacLineEndings("ends in a CR\r") == "ends in a CR\r");
    CHECK(ToMacLineEndings("a\r\rb") == "a\r\rb");
    // A run of CRs before an LF -- an edit control's soft line break, or a
    // CRLF converted twice -- is one line ending, and folds to one LF. So
    // nothing folded holds a CRLF, and folding it again changes nothing: an
    // old Mac, which does not fold, and a new one get the same text.
    CHECK(ToMacLineEndings("\r\r\n") == "\n");
    CHECK(ToMacLineEndings("a\r\r\nb\r\r\r\nc") == "a\nb\nc");
    for (const std::string text : {"a\r\r\nb", "\r\r\r\n", "a\r\n\r\nb\r", "\r\ra\r\r",
                                   "one\r\ntwo\n\rthree"}) {
        const std::string once = ToMacLineEndings(text);
        CHECK(ToMacLineEndings(once) == once);
        CHECK(once.find("\r\n") == std::string::npos);
    }

    // There and back again is the Mac's text as it was.
    const std::string mac = "first line\nsecond, with a tab\there\n\nafter a blank line";
    CHECK(ToMacLineEndings(ToWindowsLineEndings(mac)) == mac);

    // Characters beyond ASCII pass through untouched.
    const std::string accented = "caf\xC3\xA9\n\xE6\xBC\xA2\xE5\xAD\x97\n\xF0\x9F\x87\xAA\xF0\x9F\x87\xB8";
    CHECK(ToWindowsLineEndings(accented)
          == "caf\xC3\xA9\r\n\xE6\xBC\xA2\xE5\xAD\x97\r\n\xF0\x9F\x87\xAA\xF0\x9F\x87\xB8");
    CHECK(ToMacLineEndings(ToWindowsLineEndings(accented)) == accented);

    CHECK(ToWindowsLineEndings("").empty());
    CHECK(ToMacLineEndings("").empty());
}

ClipboardMarkers Markers(bool exclude_from_monitors, bool viewer_ignore,
                         std::optional<DWORD> history, std::optional<DWORD> cloud) {
    ClipboardMarkers markers;
    markers.exclude_from_monitors = exclude_from_monitors;
    markers.viewer_ignore = viewer_ignore;
    markers.history = history;
    markers.cloud = cloud;
    return markers;
}

void TestClipboardMarkers() {
    constexpr std::optional<DWORD> absent;
    constexpr DWORD refuse = 0;
    constexpr DWORD allow = 1;

    // An ordinary copy, marked with nothing, crosses to the Mac.
    CHECK(!ClipboardIsPrivate(ClipboardMarkers{}));

    // Either of the two presence formats keeps it here on its own.
    CHECK(ClipboardIsPrivate(Markers(true, false, absent, absent)));
    CHECK(ClipboardIsPrivate(Markers(false, true, absent, absent)));

    // The two DWORD formats keep it here only when they hold 0. 1 is an
    // application saying, explicitly, that history and the cloud are welcome.
    CHECK(ClipboardIsPrivate(Markers(false, false, refuse, absent)));
    CHECK(ClipboardIsPrivate(Markers(false, false, absent, refuse)));
    CHECK(!ClipboardIsPrivate(Markers(false, false, allow, allow)));
    // Out of history but allowed to the cloud is still not for the Mac: the
    // history refusal is what a password manager sets.
    CHECK(ClipboardIsPrivate(Markers(false, false, refuse, allow)));

    // What KeePass puts beside every password it copies.
    CHECK(ClipboardIsPrivate(Markers(true, true, refuse, refuse)));
    // What the host puts beside the pairing token (MarkClipboardPrivate).
    CHECK(ClipboardIsPrivate(Markers(true, false, refuse, refuse)));

    // Reading the DWORD out of a format's data.
    const DWORD zero = 0;
    const DWORD one = 1;
    HGLOBAL data = GlobalBytes(&zero, sizeof(zero));
    CHECK(ClipboardDword(data) == DWORD{0});
    GlobalFree(data);
    data = GlobalBytes(&one, sizeof(one));
    CHECK(ClipboardDword(data) == DWORD{1});
    GlobalFree(data);
    // Only the first four bytes are the value.
    const unsigned char longer[8] = {1, 0, 0, 0, 0xFF, 0xFF, 0xFF, 0xFF};
    data = GlobalBytes(longer, sizeof(longer));
    CHECK(ClipboardDword(data) == DWORD{1});
    GlobalFree(data);
    // Nothing to read is no answer, not a 0 -- which would read as a refusal.
    CHECK(!ClipboardDword(nullptr).has_value());
    data = GlobalAlloc(GMEM_MOVEABLE, 0);
    CHECK(!ClipboardDword(data).has_value());
    GlobalFree(data);

    // What the host hands the clipboard beside the pairing token reads back
    // as the refusal it means: a DWORD, holding 0.
    data = ClipboardDwordData(0);
    CHECK(data != nullptr);
    CHECK(GlobalSize(data) >= sizeof(DWORD));
    CHECK(ClipboardDword(data) == DWORD{0});
    GlobalFree(data);
    data = ClipboardDwordData(1);
    CHECK(ClipboardDword(data) == DWORD{1});
    GlobalFree(data);
}

// ── The sound capture opening its device again ───────────────────────────────

// Here because this is the one C++ test program; audio.cpp itself builds only
// with MSVC. See media/audio_reopen.h.

void TestSoundReadTrouble() {
    using media::kPersistentFailureMs;
    using media::ReadTrouble;

    // A device that has gone, or an audio service that has stopped, is given
    // up on at the first failed read: waiting brings neither back.
    ReadTrouble gone;
    CHECK(gone.GiveUp(AUDCLNT_E_DEVICE_INVALIDATED, 1000));
    CHECK(gone.GiveUp(AUDCLNT_E_SERVICE_NOT_RUNNING, 1000));

    // Any other failure only once it has gone on that long.
    ReadTrouble other;
    CHECK(!other.GiveUp(E_FAIL, 1000));
    CHECK(!other.GiveUp(E_FAIL, 1000 + kPersistentFailureMs - 1));
    CHECK(other.GiveUp(E_FAIL, 1000 + kPersistentFailureMs));
    // Giving up ends the run, so the capture opened next starts afresh.
    CHECK(!other.GiveUp(E_FAIL, 2000));

    // A read that works in between ends the run too.
    ReadTrouble interrupted;
    CHECK(!interrupted.GiveUp(E_FAIL, 0));
    interrupted.Worked();
    CHECK(!interrupted.GiveUp(E_FAIL, kPersistentFailureMs + 10));
    CHECK(!interrupted.GiveUp(E_FAIL, 2 * kPersistentFailureMs + 9));
    CHECK(interrupted.GiveUp(E_FAIL, 2 * kPersistentFailureMs + 10));

    // A device going in the middle of other failures is still given up on at once.
    ReadTrouble mixed;
    CHECK(!mixed.GiveUp(E_FAIL, 0));
    CHECK(mixed.GiveUp(AUDCLNT_E_DEVICE_INVALIDATED, 1));
}

void TestSoundReopener() {
    using media::kReopenRetryMs;
    using media::kRepeatQuietMs;
    using media::kSteadyMs;
    using media::Reopener;
    const HRESULT gone = AUDCLNT_E_DEVICE_INVALIDATED;
    const HRESULT noDevice = HRESULT_FROM_WIN32(ERROR_NOT_FOUND);

    // Opened at once the first time, and then never more than twice a
    // second, counting an open that worked as well as one that did not.
    Reopener timing;
    CHECK(timing.Due(0));
    CHECK(timing.OpenFailed(noDevice, 0));
    CHECK(!timing.Due(kReopenRetryMs - 1));
    CHECK(timing.Due(kReopenRetryMs));
    CHECK(timing.Opened(kReopenRetryMs));
    CHECK(!timing.Due(2 * kReopenRetryMs - 1));
    CHECK(timing.Due(2 * kReopenRetryMs));

    // An open that timed out -- an app's activation left unanswered by a
    // wedged audio service -- is not started again for much longer, and an
    // open that fails or works the ordinary way afterwards goes back to the
    // half second.
    const HRESULT timedOut = HRESULT_FROM_WIN32(ERROR_TIMEOUT);
    Reopener wedged;
    CHECK(wedged.Due(0));
    CHECK(wedged.OpenFailed(timedOut, 2000));
    CHECK(!wedged.Due(2000 + kReopenRetryMs));
    CHECK(!wedged.Due(2000 + media::kTimedOutRetryMs - 1));
    CHECK(wedged.Due(2000 + media::kTimedOutRetryMs));
    CHECK(!wedged.OpenFailed(timedOut, 2000 + media::kTimedOutRetryMs));
    CHECK(!wedged.Due(2000 + 2 * media::kTimedOutRetryMs - 1));
    const uint64_t later = 2000 + 2 * media::kTimedOutRetryMs;
    CHECK(wedged.OpenFailed(noDevice, later));
    CHECK(wedged.Due(later + kReopenRetryMs));
    CHECK(wedged.OpenFailed(timedOut, later + kReopenRetryMs));
    CHECK(wedged.Opened(later + kReopenRetryMs + media::kTimedOutRetryMs));
    CHECK(wedged.Due(later + 2 * kReopenRetryMs + media::kTimedOutRetryMs));

    // The first open is said, as the line that gives the device's format.
    // So is losing a device that had been working, and opening the next one.
    Reopener change;
    CHECK(change.Opened(0));
    CHECK(change.Lost(gone, 60000));
    CHECK(change.Due(60000));
    CHECK(change.Opened(60000));
    // A second change soon after, once the new device has worked a while, is
    // said again: it is new trouble, not a repeat.
    CHECK(change.Lost(gone, 60000 + kSteadyMs));
    CHECK(change.Opened(60000 + kSteadyMs));
    // Another device becoming the default is said the same way.
    CHECK(change.Lost(S_OK, 60000 + 2 * kSteadyMs));
    CHECK(change.Opened(60000 + 2 * kSteadyMs));

    // A device that opens and fails at once, over and over, is said once a
    // minute rather than twice a second. In 130 rounds, 65 seconds, that is
    // the first opening again, then the loss a minute on and the opening
    // after it.
    Reopener flapping;
    CHECK(flapping.Opened(0));
    CHECK(flapping.Lost(gone, 10));
    int lines = 0;
    uint64_t at = 0;
    for (int round = 1; round <= 130; ++round) {
        at = (uint64_t) round * kReopenRetryMs;
        CHECK(flapping.Due(at));
        if (flapping.Opened(at)) { ++lines; }
        if (flapping.Lost(gone, at + 10)) { ++lines; }
    }
    CHECK(lines == 3);
    // A different error is said whenever it comes.
    CHECK(flapping.Due(at + kReopenRetryMs));
    CHECK(flapping.OpenFailed(noDevice, at + kReopenRetryMs));

    // A PC whose one sound device is a monitor that has been switched off: the
    // loss is said, then the first failed open, then a repeat once a minute,
    // and the open that finally works.
    Reopener off;
    CHECK(off.Opened(0));
    CHECK(off.Lost(gone, 10000));
    lines = 0;
    int tries = 0;
    for (uint64_t now = 10000; now < 10000 + 3 * kRepeatQuietMs; now += kReopenRetryMs) {
        if (!off.Due(now)) { continue; }
        ++tries;
        if (off.OpenFailed(noDevice, now)) { ++lines; }
    }
    CHECK(tries == (int) (3 * kRepeatQuietMs / kReopenRetryMs));
    CHECK(lines == 3);
    CHECK(off.Opened(10000 + 3 * kRepeatQuietMs));
    // Nothing more to say until the next trouble.
    CHECK(!off.Opened(10000 + 3 * kRepeatQuietMs + kReopenRetryMs));
}

void TestSoundDefaultDevice() {
    using media::DefaultDeviceMoved;
    const std::wstring speakers = L"{0.0.0.00000000}.{speakers}";
    const std::wstring headset = L"{0.0.0.00000000}.{headset}";
    CHECK(!DefaultDeviceMoved(speakers, speakers));
    CHECK(DefaultDeviceMoved(speakers, headset));
    // No default device at all, or no answer, is not a move: the open
    // device's own reads say whether it has gone.
    CHECK(!DefaultDeviceMoved(speakers, L""));
    // Nor is anything, when the open device's id was never known.
    CHECK(!DefaultDeviceMoved(L"", headset));
}

// ── The encoder's frame ids ──────────────────────────────────────────────────

/// The Mac reads a jump in frame ids as a picture lost whole and freezes for a
/// keyframe, so an id may only be spent on a frame the encoder took, and a
/// keyframe request a refused feed was carrying must not be lost with it.
void TestFeedLedger() {
    media::FeedLedger ledger;
    CHECK(ledger.NextFrameId() == 1);
    CHECK(!ledger.IdrPending());

    // Accepted: the id is spent.
    CHECK(!ledger.TakeIdr(false));
    ledger.Accepted();
    CHECK(ledger.NextFrameId() == 2);

    // Refused: the next feed carries the same id, so the ids the Mac sees stay
    // consecutive.
    CHECK(!ledger.TakeIdr(false));
    ledger.Refused(false);
    CHECK(ledger.NextFrameId() == 2);
    CHECK(!ledger.IdrPending());
    ledger.Accepted();
    CHECK(ledger.NextFrameId() == 3);

    // A requested keyframe is taken by one feed only...
    ledger.RequestIdr();
    CHECK(ledger.IdrPending());
    CHECK(ledger.TakeIdr(false));
    CHECK(!ledger.IdrPending());
    // ...and handed back when that feed is refused, so the next one is it.
    ledger.Refused(true);
    CHECK(ledger.IdrPending());
    CHECK(ledger.NextFrameId() == 3);
    CHECK(ledger.TakeIdr(false));
    ledger.Accepted();
    CHECK(!ledger.IdrPending());
    CHECK(ledger.NextFrameId() == 4);

    // A keyframe the caller forces is one too, and owed again if refused.
    CHECK(ledger.TakeIdr(true));
    ledger.Refused(true);
    CHECK(ledger.TakeIdr(false));
    ledger.Accepted();

    // Accepted, a keyframe is not owed again.
    ledger.RequestIdr();
    CHECK(ledger.TakeIdr(false));
    ledger.Accepted();
    CHECK(!ledger.IdrPending());
    CHECK(!ledger.TakeIdr(false));
}

void TestOverflowGate() {
    using Gate = media::OverflowGate;
    {
        // Pictures go straight through while the queue has room.
        Gate gate;
        Gate::Decision d = gate.Picture(false, false, 0.0);
        CHECK(d.send && !d.clear && !d.askIdr);
        d = gate.Picture(true, false, 16.0);
        CHECK(d.send && !d.clear && !d.askIdr);
        CHECK(!gate.Waiting());
    }
    {
        // A P-frame finds the queue full: the backlog goes, so does the P-frame,
        // and a keyframe is asked for once.
        Gate gate;
        Gate::Decision d = gate.Picture(false, true, 100.0);
        CHECK(d.clear && !d.send && d.askIdr);
        CHECK(gate.Waiting());
        // Every P-frame until the keyframe is dropped, and nothing more asked,
        // with the queue full or not.
        d = gate.Picture(false, false, 116.0);
        CHECK(!d.send && !d.clear && !d.askIdr);
        d = gate.Picture(false, true, 132.0);
        CHECK(!d.send && !d.clear && !d.askIdr);
        // The keyframe goes, and ends the wait.
        d = gate.Picture(true, false, 148.0);
        CHECK(d.send && !d.clear && !d.askIdr);
        CHECK(!gate.Waiting());
        d = gate.Picture(false, false, 164.0);
        CHECK(d.send && !d.askIdr);
    }
    {
        // A keyframe that finds the queue full goes, over the backlog, and
        // asks for nothing: asking made a second keyframe straight after it.
        Gate gate;
        Gate::Decision d = gate.Picture(true, true, 0.0);
        CHECK(d.clear && d.send && !d.askIdr);
        CHECK(!gate.Waiting());
    }
    {
        // An encoder that ignores the request: the wait gives up, the picture
        // is sent, and the keyframe is asked for again.
        Gate gate;
        gate.Picture(false, true, 1000.0);
        Gate::Decision d = gate.Picture(false, false, 1000.0 + Gate::kGiveUpMs);
        CHECK(!d.send && !d.askIdr);
        d = gate.Picture(false, false, 1001.0 + Gate::kGiveUpMs);
        CHECK(d.send && !d.clear && d.askIdr);
        CHECK(!gate.Waiting());
        // A full queue at that moment is an overflow again, and the wait
        // starts over.
        Gate again;
        again.Picture(false, true, 0.0);
        d = again.Picture(false, true, 1.0 + Gate::kGiveUpMs);
        CHECK(d.clear && !d.send && d.askIdr);
        CHECK(again.Waiting());
    }
}

/// The takeover proof, against the same frozen vector the Mac's tests check
/// (AgentReconnectTests.swift): if either end changes what it HMACs, one of
/// the two fails here rather than every takeover failing on a real PC.
void TestTakeoverProof() {
    const std::string token = "00112233445566778899aabbccddeeff";
    const std::string challenge =
        "000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f";
    const std::string cnonce =
        "202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f";
    const std::string id = "0123456789abcdef0123456789abcdef";
    const std::string proof =
        "2e9724ecddb956360f9455f33d31d1157c2a3d13aac41a4c8085879862b2bc38";

    CHECK(ToHex(TakeoverHmac(FromHex(token),
                             TakeoverProofMessage(FromHex(challenge), FromHex(cnonce), id)))
          == proof);
    CHECK(TakeoverProofMatches(token, challenge, cnonce, id, proof));
    // Upper-case hex is the same bytes.
    std::string shouted = proof;
    std::transform(shouted.begin(), shouted.end(), shouted.begin(),
                   [](char c) { return (char) std::toupper((unsigned char) c); });
    CHECK(TakeoverProofMatches(token, challenge, cnonce, id, shouted));

    // The id is inside the proof: the same proof under another id is no proof.
    CHECK(!TakeoverProofMatches(token, challenge, cnonce, "fedcba9876543210fedcba9876543210",
                                proof));
    // Nor is the auth v2 proof over the same challenge and nonce, which a
    // listener on the wire would have seen.
    CHECK(!TakeoverProofMatches(
        token, challenge, cnonce, id,
        "8088d61292cfe919910042d796548189e271424c40025e35719b0e6369c3eacc"));
    // Another token, challenge or nonce.
    CHECK(!TakeoverProofMatches("ffeeddccbbaa99887766554433221100", challenge, cnonce, id, proof));
    CHECK(!TakeoverProofMatches(token, cnonce, challenge, id, proof));
    std::string flipped = proof;
    flipped[0] = flipped[0] == '2' ? '3' : '2';
    CHECK(!TakeoverProofMatches(token, challenge, cnonce, id, flipped));

    // Malformed in every way the wire can deliver.
    CHECK(!TakeoverProofMatches("", challenge, cnonce, id, proof));
    CHECK(!TakeoverProofMatches(token, challenge.substr(2), cnonce, id, proof));
    CHECK(!TakeoverProofMatches(token, challenge, cnonce + "00", id, proof));
    CHECK(!TakeoverProofMatches(token, challenge, cnonce, id, proof.substr(0, 62)));
    CHECK(!TakeoverProofMatches(token, challenge, cnonce, id, ""));
    CHECK(!TakeoverProofMatches(token, challenge, cnonce, "", proof));
    CHECK(!TakeoverProofMatches(token, "zz" + challenge.substr(2), cnonce, id, proof));
}

void TestClientId() {
    CHECK(IsClientId("0123456789abcdef0123456789abcdef"));
    CHECK(IsClientId("00000000000000000000000000000000"));
    CHECK(!IsClientId(""));
    CHECK(!IsClientId("0123456789abcdef0123456789abcde"));
    CHECK(!IsClientId("0123456789abcdef0123456789abcdef0"));
    // Lowercase only: the Mac never sends anything else, and one spelling is
    // what lets the host compare two ids as strings.
    CHECK(!IsClientId("0123456789ABCDEF0123456789ABCDEF"));
    CHECK(!IsClientId("0123456789abcdef0123456789abcdeg"));
    CHECK(!IsClientId("0123456789abcdef\"123456789abcdef"));
}

/// Who may take a session over. Above all: never a Mac other than the one
/// that holds it, and never the session of a Mac that did not say who it was.
void TestDecideTakeover() {
    const std::string mine = "0123456789abcdef0123456789abcdef";
    const std::string theirs = "fedcba9876543210fedcba9876543210";
    const unsigned long long quiet = kTakeoverSilenceMs;
    const unsigned long long live = kTakeoverSilenceMs - 1;

    // The same Mac, and its session has missed a heartbeat: it may have it.
    CHECK(DecideTakeover(true, mine, true, mine, quiet) == TakeoverVerdict::Take);
    CHECK(DecideTakeover(true, mine, true, mine, 10 * 60 * 1000) == TakeoverVerdict::Take);
    // The same Mac, but the session was heard from recently: not yet.
    CHECK(DecideTakeover(true, mine, true, mine, live) == TakeoverVerdict::NotYet);
    CHECK(DecideTakeover(true, mine, true, mine, 0) == TakeoverVerdict::NotYet);

    // Another Mac, however long the session has been quiet.
    CHECK(DecideTakeover(true, theirs, true, mine, quiet) == TakeoverVerdict::Another);
    CHECK(DecideTakeover(true, theirs, true, mine, 10 * 60 * 1000) == TakeoverVerdict::Another);
    CHECK(DecideTakeover(true, theirs, true, mine, 0) == TakeoverVerdict::Another);
    // A session whose Mac gave no id -- every Mac built before this -- is
    // nobody's to take, even with an id that is empty too.
    CHECK(DecideTakeover(true, mine, true, "", quiet) == TakeoverVerdict::Another);
    CHECK(DecideTakeover(true, "", true, "", quiet) == TakeoverVerdict::Another);
    // A knock with a malformed id cannot be anybody's holder.
    CHECK(DecideTakeover(true, "MINE", true, "MINE", quiet) == TakeoverVerdict::Another);

    // Without the token, nothing -- and nothing said about whose session it is.
    CHECK(DecideTakeover(false, mine, true, mine, quiet) == TakeoverVerdict::Refused);
    CHECK(DecideTakeover(false, theirs, true, mine, quiet) == TakeoverVerdict::Refused);
    CHECK(DecideTakeover(false, mine, false, "", quiet) == TakeoverVerdict::Refused);

    // The session ended while the request was on its way: a Mac with the token
    // may have the free slot, as it would have on its next knock.
    CHECK(DecideTakeover(true, mine, false, "", 0) == TakeoverVerdict::Take);
    CHECK(DecideTakeover(true, theirs, false, "", 0) == TakeoverVerdict::Take);
}

/// When the session's Mac counts as heard from, through a long command that
/// stops the serving thread reading. Times in ms; the session authenticated at
/// 1000, and a launch runs from 2000 to 62000.
void TestHolderHearing() {
    const unsigned long long ping = 24;

    // A live Mac pings every ten seconds and the pings pile up unread. Each
    // knock that finds more waiting than the last hears it; the session is
    // never silent for kTakeoverSilenceMs.
    {
        HolderHearing h = HeardFresh(1000);
        h.heard_at = 2000;  // the launch request, read as it arrived
        CHECK(HearingSilentMs(h, 0, 9000) == 7000);
        CHECK(HearingSilentMs(h, ping, 13000) == 0);       // first ping, first look
        CHECK(HearingSilentMs(h, ping, 20000) == 7000);
        CHECK(HearingSilentMs(h, 2 * ping, 23000) == 0);   // the next one
        CHECK(HearingSilentMs(h, 2 * ping, 32000) == 9000);
        CHECK(HearingSilentMs(h, 3 * ping, 33000) == 0);
        CHECK(HearingSilentMs(h, 3 * ping, 42000) < kTakeoverSilenceMs);
    }

    // The Mac's network goes at 13000, after one ping. Knocks from its new
    // address find that ping waiting and nothing more: it is taken over 15
    // seconds after the first of them, well inside the Mac's 45, though the
    // launch runs on for another 40.
    {
        HolderHearing h = HeardFresh(1000);
        h.heard_at = 2000;
        CHECK(HearingSilentMs(h, ping, 16000) == 0);
        CHECK(HearingSilentMs(h, ping, 25000) == 9000);
        CHECK(HearingSilentMs(h, ping, 30999) < kTakeoverSilenceMs);
        CHECK(HearingSilentMs(h, ping, 31000) >= kTakeoverSilenceMs);
        CHECK(HearingSilentMs(h, ping, 40000) >= kTakeoverSilenceMs);
    }

    // The same, but the launch returns at 62000 before the Mac knocks again.
    // The serving thread reads the old ping then: it was waiting when the
    // thread came out, so it is said to have been sent by 2000, when the
    // launch began. The silence is not started again by reading it.
    {
        HolderHearing h = HeardFresh(1000);
        h.heard_at = 2000;
        CHECK(HearingSilentMs(h, ping, 16000) == 0);
        HearingRead(h, 2000, 0);
        CHECK(HearingSilentMs(h, 0, 63000) == 47000);
        CHECK(HearingSilentMs(h, 0, 63000) >= kTakeoverSilenceMs);
    }

    // Read with nothing having been looked at during the launch: still the
    // launch's start, so the silence counts from there.
    {
        HolderHearing h = HeardFresh(1000);
        h.heard_at = 2000;
        HearingRead(h, 2000, 0);
        CHECK(HearingSilentMs(h, 0, 62500) == 60500);
    }

    // What arrives while the thread is waiting is heard when it is read.
    {
        HolderHearing h = HeardFresh(1000);
        HearingRead(h, 70000, 0);
        CHECK(HearingSilentMs(h, 0, 75000) == 5000);
        // And an older stamp never moves it back.
        HearingRead(h, 2000, 0);
        CHECK(HearingSilentMs(h, 0, 75000) == 5000);
    }

    // A read resets the baseline: the next command piling up the same number
    // of bytes again is the Mac heard from, not nothing new.
    {
        HolderHearing h = HeardFresh(1000);
        CHECK(HearingSilentMs(h, ping, 5000) == 0);
        HearingRead(h, 5000, 0);
        CHECK(HearingSilentMs(h, ping, 30000) == 0);
        // And what a read left behind is not growth either.
        HearingRead(h, 30000, ping);
        CHECK(HearingSilentMs(h, ping, 50000) == 20000);
    }

    // A clock that has not moved past the stamp is no silence at all.
    {
        HolderHearing h = HeardFresh(9000);
        CHECK(HearingSilentMs(h, 0, 8000) == 0);
    }
}

/// A key the Mac sends by position goes in as that scan code, so this PC's own
/// layout decides what it types -- except the few where the Mac's meaning has
/// no PC key to carry it.
void TestScanKeys() {
    using media::BuildScanKeyInput;
    INPUT in{};

    // An ordinary key: the scan code alone, no virtual key, so the layout
    // here decides. The key marked Z on a German keyboard is 0x15 -- what a
    // US keyboard calls Y -- and must arrive as 0x15, not as VK_Y.
    CHECK(BuildScanKeyInput(0x0015, true, &in));
    CHECK(in.type == INPUT_KEYBOARD);
    CHECK(in.ki.wVk == 0);
    CHECK(in.ki.wScan == 0x15);
    CHECK(in.ki.dwFlags == KEYEVENTF_SCANCODE);

    CHECK(BuildScanKeyInput(0x0015, false, &in));
    CHECK(in.ki.dwFlags == (KEYEVENTF_SCANCODE | KEYEVENTF_KEYUP));

    // The ISO keyboard's extra key and the one left of 1.
    CHECK(BuildScanKeyInput(0x0056, true, &in) && in.ki.wScan == 0x56 && in.ki.wVk == 0);
    CHECK(BuildScanKeyInput(0x0029, true, &in) && in.ki.wScan == 0x29 && in.ki.wVk == 0);

    // 0xE0 in the high byte is an extended key: the arrows, the right-hand
    // Control and Alt, the keypad's Enter and slash, Insert and Menu.
    CHECK(BuildScanKeyInput(0xE04B, true, &in));
    CHECK(in.ki.wScan == 0x4B && in.ki.wVk == 0);
    CHECK(in.ki.dwFlags == (KEYEVENTF_SCANCODE | KEYEVENTF_EXTENDEDKEY));
    CHECK(BuildScanKeyInput(0xE038, false, &in));
    CHECK(in.ki.dwFlags == (KEYEVENTF_SCANCODE | KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP));
    CHECK(BuildScanKeyInput(0xE01C, true, &in) && in.ki.wScan == 0x1C
          && (in.ki.dwFlags & KEYEVENTF_EXTENDEDKEY));

    // Control goes in by virtual key, so it is Control on every layout: on
    // Korean's 101-key Type 1 the right one's place is Hanja. The scan code
    // is still given, and the right one is still extended.
    CHECK(BuildScanKeyInput(0x001D, true, &in));
    CHECK(in.ki.wVk == VK_LCONTROL && in.ki.wScan == 0x1D && in.ki.dwFlags == 0);
    CHECK(BuildScanKeyInput(0xE01D, true, &in));
    CHECK(in.ki.wVk == VK_RCONTROL && in.ki.wScan == 0x1D
          && in.ki.dwFlags == KEYEVENTF_EXTENDEDKEY);
    CHECK(BuildScanKeyInput(0xE01D, false, &in));
    CHECK(in.ki.wVk == VK_RCONTROL
          && in.ki.dwFlags == (KEYEVENTF_EXTENDEDKEY | KEYEVENTF_KEYUP));
    CHECK(BuildScanKeyInput(0x001D, false, &in) && in.ki.wVk == VK_LCONTROL
          && in.ki.dwFlags == KEYEVENTF_KEYUP);

    // The keypad's digits and point go in by virtual key, so this PC's Num
    // Lock cannot turn them into Home, End and the arrows. The scan code is
    // still given, as the PC's own keyboard would report it.
    const struct { uint16_t scan; WORD vk; } keypad[] = {
        {0x52, VK_NUMPAD0}, {0x4F, VK_NUMPAD1}, {0x50, VK_NUMPAD2}, {0x51, VK_NUMPAD3},
        {0x4B, VK_NUMPAD4}, {0x4C, VK_NUMPAD5}, {0x4D, VK_NUMPAD6}, {0x47, VK_NUMPAD7},
        {0x48, VK_NUMPAD8}, {0x49, VK_NUMPAD9}, {0x53, VK_DECIMAL},
    };
    for (const auto& key : keypad) {
        CHECK(BuildScanKeyInput(key.scan, true, &in));
        CHECK(in.ki.wVk == key.vk && in.ki.wScan == key.scan && in.ki.dwFlags == 0);
        CHECK(BuildScanKeyInput(key.scan, false, &in) && in.ki.dwFlags == KEYEVENTF_KEYUP);
    }
    // Only without the prefix: E0 47 is Home, which stays a scan code.
    CHECK(BuildScanKeyInput(0xE047, true, &in) && in.ki.wVk == 0
          && in.ki.dwFlags == (KEYEVENTF_SCANCODE | KEYEVENTF_EXTENDEDKEY));
    // The keypad's operators mean the same with Num Lock on or off.
    CHECK(BuildScanKeyInput(0x004E, true, &in) && in.ki.wVk == 0
          && in.ki.dwFlags == KEYEVENTF_SCANCODE);

    // The keypad's '=' has no PC key, so it goes in as the character.
    CHECK(BuildScanKeyInput(0x0059, true, &in));
    CHECK(in.ki.wVk == 0 && in.ki.wScan == L'=' && in.ki.dwFlags == KEYEVENTF_UNICODE);
    CHECK(BuildScanKeyInput(0x0059, false, &in)
          && in.ki.dwFlags == (KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));
    // And so does the JIS keypad's comma, whose place only a Brazilian
    // layout gives a character.
    CHECK(BuildScanKeyInput(0x007E, true, &in));
    CHECK(in.ki.wVk == 0 && in.ki.wScan == L',' && in.ki.dwFlags == KEYEVENTF_UNICODE);
    CHECK(BuildScanKeyInput(0x007E, false, &in)
          && in.ki.dwFlags == (KEYEVENTF_UNICODE | KEYEVENTF_KEYUP));

    // Kana and Eisu switch the IME on and off.
    CHECK(BuildScanKeyInput(0x00F2, true, &in) && in.ki.wVk == 0x16 && in.ki.dwFlags == 0);
    CHECK(BuildScanKeyInput(0x00F1, false, &in) && in.ki.wVk == 0x1A
          && in.ki.dwFlags == KEYEVENTF_KEYUP);

    // Nothing that names no key.
    CHECK(!BuildScanKeyInput(0x0000, true, &in));
    CHECK(!BuildScanKeyInput(0xE000, true, &in));
    CHECK(!BuildScanKeyInput(0xE11D, true, &in));   // E1 is Pause's, which no Mac has
    CHECK(!BuildScanKeyInput(0x1234, true, &in));
    CHECK(!BuildScanKeyInput(0x0095, true, &in));   // a break code
    CHECK(!BuildScanKeyInput(0xE0F2, true, &in));
}

/// The Mac's Caps Lock state, carried on every key, is matched by pressing
/// Caps Lock here only when the PC's differs -- and what the PC's is comes from
/// Windows, except just after a press from here, which Windows may not have
/// caught up with.
void TestCapsLock() {
    using namespace media;
    CapsLockBelief belief;
    // Nothing known: Windows is asked.
    CHECK(CapsLockNeedsReading(belief, 5000));

    CapsLockNoted(belief, false, 5000);
    CHECK(belief.known && !belief.on);
    // Trusted for a second, so a press made from here is not read back as
    // the old state and pressed a second time.
    CHECK(!CapsLockNeedsReading(belief, 5000));
    CHECK(!CapsLockNeedsReading(belief, 5000 + kCapsLockTrustMs - 1));
    // Then asked again, so Caps Lock changed at the PC itself is noticed.
    CHECK(CapsLockNeedsReading(belief, 5000 + kCapsLockTrustMs));
    CHECK(CapsLockNeedsReading(belief, 5000 + 60000));
    // A clock that went backwards proves nothing.
    CHECK(CapsLockNeedsReading(belief, 4999));

    // A press from here is what the PC now is.
    CapsLockNoted(belief, true, 9000);
    CHECK(belief.on && !CapsLockNeedsReading(belief, 9500));

    // A fresh session knows nothing.
    belief = CapsLockBelief{};
    CHECK(!belief.known && CapsLockNeedsReading(belief, 0));

    // Whether to press. Windows is asked when the belief needs it, and what
    // it says decides.
    int asked = 0;
    const auto says = [&asked](std::optional<bool> answer) {
        return [&asked, answer]() { ++asked; return answer; };
    };
    CHECK(CapsLockPressNeeded(belief, says(false), true, 20000));
    CHECK(asked == 1 && belief.known && !belief.on);
    belief = CapsLockBelief{};
    CHECK(!CapsLockPressNeeded(belief, says(true), true, 20000));
    CHECK(belief.known && belief.on);

    // Windows cannot be asked and nothing is known: nothing pressed, and
    // still nothing known, so the next key asks again.
    belief = CapsLockBelief{};
    asked = 0;
    CHECK(!CapsLockPressNeeded(belief, says(std::nullopt), true, 20000));
    CHECK(!CapsLockPressNeeded(belief, says(std::nullopt), false, 20000));
    CHECK(asked == 2 && !belief.known);

    // A belief past its second is not acted on when Windows cannot be asked:
    // nothing pressed, and it is forgotten rather than trusted.
    CapsLockNoted(belief, false, 30000);
    CHECK(!CapsLockPressNeeded(belief, says(std::nullopt), true, 30000 + kCapsLockTrustMs));
    CHECK(!belief.known);

    // Within its second, the belief decides and Windows is not asked: just
    // after a press from here, it may not have caught up.
    CapsLockNoted(belief, true, 40000);
    asked = 0;
    CHECK(!CapsLockPressNeeded(belief, says(false), true, 40500));
    CHECK(CapsLockPressNeeded(belief, says(std::nullopt), false, 40500));
    CHECK(asked == 0 && belief.known && belief.on);

    // The press itself: Caps Lock down and up by virtual key, so a Japanese
    // layout's 英数 at that place is not what it presses.
    INPUT toggle[2];
    BuildCapsLockToggle(toggle);
    CHECK(toggle[0].type == INPUT_KEYBOARD && toggle[1].type == INPUT_KEYBOARD);
    CHECK(toggle[0].ki.wVk == VK_CAPITAL && toggle[1].ki.wVk == VK_CAPITAL);
    CHECK(toggle[0].ki.dwFlags == 0);
    CHECK(toggle[1].ki.dwFlags == KEYEVENTF_KEYUP);
    CHECK(!(toggle[0].ki.dwFlags & KEYEVENTF_SCANCODE));

    // Caps Lock's scan code is what the Mac reports its changes with, and the
    // state is the modifiers byte's 0x10, clear of shift, control, alt and
    // the Windows key. Constants, so checked as this compiles: a CHECK of
    // one is a warning under MSVC's /W4.
    static_assert(kScanCapsLock == 0x3A);
    static_assert((kModifierCapsLock & 0x0F) == 0);
}

/// A key's events are applied in the order they were made, whatever order
/// their datagrams arrive in: an old release that turns up after a newer press
/// of the same key is passed over, or it lets go of a key the hand is on.
void TestHoldOrder() {
    using namespace media;
    const unsigned char wDown[] = {0x00, 0x11, 1, 0};
    const unsigned char wUp[] = {0x00, 0x11, 0, 0};
    const unsigned char leftUp[] = {1, 0};
    const unsigned char move[] = {0, 3, 0, 1};

    // A key by scan code, the same by virtual key, and a button are three.
    const uint32_t w = HoldTarget(8, wDown, sizeof(wDown));
    CHECK(w != 0 && w == HoldTarget(8, wUp, sizeof(wUp)));
    CHECK(HoldTarget(6, wDown, sizeof(wDown)) != w);
    CHECK(HoldTarget(3, leftUp, sizeof(leftUp)) != 0);
    CHECK(HoldTarget(3, leftUp, sizeof(leftUp)) != HoldTarget(3, wDown, 2));
    // Nothing held by a move, a scroll or text, nor by an event too short.
    CHECK(HoldTarget(2, move, sizeof(move)) == 0);
    CHECK(HoldTarget(4, move, 2) == 0);
    CHECK(HoldTarget(7, wDown, sizeof(wDown)) == 0);
    CHECK(HoldTarget(8, wDown, 2) == 0);
    CHECK(HoldTarget(3, leftUp, 1) == 0);

    // The case it is for: W-up (2), carried ahead of the newest, then W
    // pressed again (22) and applied first; the older datagram lands last.
    HoldOrder order;
    CHECK(HoldEventIsNewest(order, w, 22));
    CHECK(!HoldEventIsNewest(order, w, 2));
    // And the key's own next event still goes.
    CHECK(HoldEventIsNewest(order, w, 30));
    // Other keys and buttons are not held back by it.
    const uint32_t left = HoldTarget(3, leftUp, sizeof(leftUp));
    CHECK(HoldEventIsNewest(order, left, 5));
    // Nor is anything that holds nothing.
    CHECK(HoldEventIsNewest(order, 0, 1));
    CHECK(order.count == 2);

    // Bounded: full, the key not seen for longest makes way. The fillers
    // are of no kind, so none of them is W.
    order = HoldOrder{};
    for (int i = 0; i < kHoldOrderSlots; ++i) {
        HoldEventIsNewest(order, 0x1000000u + (uint32_t) i, 100u + (uint32_t) i);
    }
    CHECK(order.count == kHoldOrderSlots);
    CHECK(HoldEventIsNewest(order, w, 5000));
    CHECK(order.count == kHoldOrderSlots);
    CHECK(!HoldEventIsNewest(order, w, 4999));
    CHECK(!HoldEventIsNewest(order, 0x1000001u, 100));  // still kept
    // The one that made way is a stranger again.
    CHECK(HoldEventIsNewest(order, 0x1000000u, 1));
}

}  // namespace

int wmain(int argc, wchar_t** argv) {
    if (argc != 2) {
        std::fputs("usage: SolStreamUpdaterTests <path to tests/update-vector>\n", stderr);
        return 2;
    }
    media::SetLogger([](const char* line) {
        g_log += line;
        g_log += "\n";
    });
    // Whatever the machine running this has set, these tests decide.
    SetEnvironmentVariableW(L"SOLSTREAM_PRETEND_VERSION", nullptr);
    SetEnvironmentVariableW(L"SOLSTREAM_GITHUB_TOKEN", nullptr);

    // A %LOCALAPPDATA% of its own, so the real Updates folder is never touched.
    wchar_t temp[MAX_PATH] = {0};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring scratch = std::wstring(temp) + L"SolStreamUpdaterTests-"
                               + std::to_wstring(GetCurrentProcessId());
    RemoveTree(scratch);
    if (!CreateDirectoryW(scratch.c_str(), nullptr)
        || !CreateDirectoryW((scratch + L"\\LocalAppData").c_str(), nullptr)) {
        std::fputs("could not make a scratch folder\n", stderr);
        return 2;
    }
    SetEnvironmentVariableW(L"LOCALAPPDATA", (scratch + L"\\LocalAppData").c_str());

    std::wstring vector = argv[1];
    std::replace(vector.begin(), vector.end(), L'/', L'\\');

    TestVersions();
    TestBase64();
    TestSignature(vector);
    TestVouch(vector);
    TestSums(vector);
    TestRelease();
    TestResolve();
    TestCommandLine(vector, scratch);
    TestEnvironment();
    TestInstallOptions();
    TestLogonTask();
    TestLogonTaskAccounts();
    TestFirewallRule();
    TestFirewallSweep();
    TestRegisterUnderAccounts();
    TestHostTaskStart();
    TestStopInstalled();
    TestQualifyCommand();
    TestJsonEscape();
    TestNoDowngrade();
    TestDownload();
    TestInstallNote();
    TestJunction(scratch);
    TestDriverSettingsFolder(scratch);
    TestDriverSettingsFile(scratch);
    TestDriverSettingsJunction(scratch);
    TestDriverSettingsRecords(scratch);
    TestWaitsForRestart();
    TestTailscaleAdapter();
    TestPickTailscaleAddress();
    TestClipboardLineEndings();
    TestClipboardMarkers();
    TestSoundReadTrouble();
    TestSoundReopener();
    TestSoundDefaultDevice();
    TestFeedLedger();
    TestOverflowGate();
    TestTakeoverProof();
    TestClientId();
    TestDecideTakeover();
    TestHolderHearing();
    TestScanKeys();
    TestCapsLock();
    TestHoldOrder();

    RemoveTree(scratch);
    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
