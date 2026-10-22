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
// restart, and which adapter is Tailscale's.

#include "updater.cpp"

#include <shellapi.h>
#include <winioctl.h>
#include <cfgmgr32.h>

#include <cstdio>

#include "driver_install.h"
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
    CHECK(at_logon.find(L"<LogonTrigger>") != std::wstring::npos);
    CHECK(on_demand.find(L"<LogonTrigger>") == std::wstring::npos);
    CHECK(on_demand.find(L"<Triggers />") != std::wstring::npos);
    // An & is legal in a Windows user name, and unescaped it made the whole
    // definition malformed.
    CHECK(LogonTaskXml(L"PC\\R&D", L"C:\\x", false).find(L"<UserId>PC\\R&amp;D</UserId>")
          != std::wstring::npos);
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
    TestFirewallRule();
    TestQualifyCommand();
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

    RemoveTree(scratch);
    std::printf("%d checks, %d failures\n", g_checks, g_failures);
    return g_failures == 0 ? 0 : 1;
}
