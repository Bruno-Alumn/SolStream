#include "util.h"

#include <bcrypt.h>

#include <algorithm>
#include <cstdio>
#include <cwctype>

namespace solstream {

std::string ToUtf8(const std::wstring& text) {
    if (text.empty()) {
        return {};
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(),
                                           nullptr, 0, nullptr, nullptr);
    if (needed <= 0) {
        return {};
    }
    std::string out(static_cast<size_t>(needed), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(),
                        out.data(), needed, nullptr, nullptr);
    return out;
}

std::wstring ToWide(const std::string& text) {
    if (text.empty()) {
        return {};
    }
    const int needed = MultiByteToWideChar(CP_UTF8, 0, text.data(), (int) text.size(),
                                           nullptr, 0);
    if (needed <= 0) {
        return {};
    }
    std::wstring out(static_cast<size_t>(needed), L'\0');
    MultiByteToWideChar(CP_UTF8, 0, text.data(), (int) text.size(), out.data(), needed);
    return out;
}

namespace {

/// How many bytes of the UTF-8 sequence starting at `at` are well formed:
/// the whole sequence's length when it is complete and valid, otherwise the
/// length of its longest valid start (at least 1), which is what one U+FFFD
/// stands for. The ranges are RFC 3629's, so overlong forms, surrogates and
/// anything past U+10FFFF are refused rather than passed on.
size_t Utf8Sequence(const std::string& text, size_t at, bool& valid) {
    const auto byte = [&](size_t i) { return static_cast<unsigned char>(text[i]); };
    const unsigned char lead = byte(at);
    size_t length = 0;
    unsigned char low = 0x80;
    unsigned char high = 0xBF;
    if (lead >= 0xC2 && lead <= 0xDF) {
        length = 2;
    } else if (lead >= 0xE0 && lead <= 0xEF) {
        length = 3;
        if (lead == 0xE0) { low = 0xA0; }
        if (lead == 0xED) { high = 0x9F; }
    } else if (lead >= 0xF0 && lead <= 0xF4) {
        length = 4;
        if (lead == 0xF0) { low = 0x90; }
        if (lead == 0xF4) { high = 0x8F; }
    } else {
        valid = false;
        return 1;
    }
    size_t taken = 1;
    for (; taken < length && at + taken < text.size(); ++taken) {
        const unsigned char next = byte(at + taken);
        // Only the second byte has a narrowed range; the rest are any
        // continuation byte.
        const bool fits = taken == 1 ? (next >= low && next <= high)
                                     : (next >= 0x80 && next <= 0xBF);
        if (!fits) {
            break;
        }
    }
    valid = taken == length;
    return taken;
}

}  // namespace

std::string JsonEscape(const std::string& text) {
    std::string out;
    out.reserve(text.size() + 8);
    size_t i = 0;
    while (i < text.size()) {
        const unsigned char ch = static_cast<unsigned char>(text[i]);
        if (ch >= 0x80) {
            // Text from an ANSI ("A") Windows call is in the PC's code page, not
            // UTF-8, and one such byte in a line makes the Mac refuse the whole
            // line. A replacement character is the honest stand-in: the text
            // still arrives, and the connection survives it.
            bool valid = false;
            const size_t length = Utf8Sequence(text, i, valid);
            if (valid) {
                out.append(text, i, length);
            } else {
                out += "\xEF\xBF\xBD";
            }
            i += length;
            continue;
        }
        switch (ch) {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (ch < 0x20) {
                    char buffer[8];
                    std::snprintf(buffer, sizeof(buffer), "\\u%04x", ch);
                    out += buffer;
                } else {
                    out += static_cast<char>(ch);
                }
        }
        ++i;
    }
    return out;
}

std::wstring FoldCase(std::wstring text) {
    std::transform(text.begin(), text.end(), text.begin(),
                   [](wchar_t c) { return (wchar_t) std::towlower(c); });
    return text;
}

std::string ToHex(const unsigned char* bytes, size_t count) {
    static const char kDigits[] = "0123456789abcdef";
    std::string out;
    out.reserve(count * 2);
    for (size_t i = 0; i < count; ++i) {
        out.push_back(kDigits[bytes[i] >> 4]);
        out.push_back(kDigits[bytes[i] & 0x0F]);
    }
    return out;
}

std::string ToHex(const std::vector<unsigned char>& bytes) {
    return ToHex(bytes.data(), bytes.size());
}

std::vector<unsigned char> FromHex(const std::string& hex) {
    if (hex.size() % 2 != 0) {
        return {};
    }
    auto nibble = [](char c) -> int {
        if (c >= '0' && c <= '9') { return c - '0'; }
        if (c >= 'a' && c <= 'f') { return c - 'a' + 10; }
        if (c >= 'A' && c <= 'F') { return c - 'A' + 10; }
        return -1;
    };
    std::vector<unsigned char> out;
    out.reserve(hex.size() / 2);
    for (size_t i = 0; i < hex.size(); i += 2) {
        const int high = nibble(hex[i]);
        const int low = nibble(hex[i + 1]);
        if (high < 0 || low < 0) {
            return {};
        }
        out.push_back((unsigned char) ((high << 4) | low));
    }
    return out;
}

std::vector<unsigned char> HmacSha256(const std::vector<unsigned char>& key,
                                      const std::vector<unsigned char>& data) {
    BCRYPT_ALG_HANDLE algorithm = nullptr;
    if (!BCRYPT_SUCCESS(BCryptOpenAlgorithmProvider(&algorithm, BCRYPT_SHA256_ALGORITHM,
                                                    nullptr, BCRYPT_ALG_HANDLE_HMAC_FLAG))) {
        return {};
    }
    std::vector<unsigned char> out(32);
    const bool ok = BCRYPT_SUCCESS(BCryptHash(algorithm, (PUCHAR) key.data(),
                                              (ULONG) key.size(), (PUCHAR) data.data(),
                                              (ULONG) data.size(), out.data(), 32));
    BCryptCloseAlgorithmProvider(algorithm, 0);
    return ok ? out : std::vector<unsigned char>{};
}

bool ProofMatchesHmac(const std::vector<unsigned char>& key,
                      const std::vector<unsigned char>& message,
                      const std::vector<unsigned char>& proof) {
    if (proof.size() != 32) {
        return false;
    }
    const std::vector<unsigned char> expected = HmacSha256(key, message);
    if (expected.size() != 32) {
        return false;
    }
    unsigned char difference = 0;
    for (size_t i = 0; i < 32; ++i) {
        difference |= (unsigned char) (expected[i] ^ proof[i]);
    }
    return difference == 0;
}

std::wstring LocalDataPath(const wchar_t* file) {
    wchar_t buffer[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH)) {
        return {};
    }
    const std::wstring dir = std::wstring(buffer) + L"\\SolStream";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\" + file;
}

bool ReadSmallFile(const std::wstring& path, size_t limit, std::string& out) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    std::string text(limit, '\0');
    DWORD read = 0;
    const bool ok = ReadFile(file, text.data(), (DWORD) text.size(), &read, nullptr) != FALSE;
    CloseHandle(file);
    if (!ok) {
        return false;
    }
    text.resize(read);
    out = std::move(text);
    return true;
}

bool WriteWholeFile(const std::wstring& path, const std::string& bytes) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    DWORD written = 0;
    const bool ok = WriteFile(file, bytes.data(), (DWORD) bytes.size(), &written, nullptr)
                    && written == bytes.size();
    CloseHandle(file);
    return ok;
}

/// The program a command line starts: its first word, unquoted.
std::wstring CommandProgram(const std::wstring& command) {
    if (command.empty()) {
        return {};
    }
    if (command[0] == L'"') {
        const size_t close = command.find(L'"', 1);
        return command.substr(1, close == std::wstring::npos ? std::wstring::npos : close - 1);
    }
    return command.substr(0, command.find(L' '));
}

std::wstring QualifySystemCommand(const std::wstring& command) {
    // Judged by the program alone. This used to pass anything with a ':' in
    // it straight through, which is every command with a path in its
    // ARGUMENTS -- tar unpacking into C:\ProgramData, netsh naming
    // C:\Program Files -- so those ran unqualified, elevated, and Windows
    // looked for them beside the setup program first.
    const std::wstring program = CommandProgram(command);
    if (program.empty() || program.find_first_of(L"\\/:") != std::wstring::npos) {
        return command;
    }
    wchar_t system_dir[MAX_PATH] = {0};
    if (GetSystemDirectoryW(system_dir, MAX_PATH) == 0) {
        return command;
    }
    // Named outright, CreateProcess adds no ".exe" and searches nowhere, so
    // the name has to be the file's: the extension spelled out, and Windows
    // PowerShell found where it lives, under System32 rather than in it.
    std::wstring name = program;
    if (name.find(L'.') == std::wstring::npos) {
        name += L".exe";
    }
    std::wstring folder = system_dir;
    if (lstrcmpiW(name.c_str(), L"powershell.exe") == 0) {
        folder += L"\\WindowsPowerShell\\v1.0";
    }
    const size_t rest = command[0] == L'"' ? program.size() + 2 : program.size();
    return L"\"" + folder + L"\\" + name + L"\""
         + command.substr((std::min)(rest, command.size()));
}

DWORD RunHidden(const std::wstring& command, DWORD timeout_ms) {
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION process{};
    std::wstring mutable_command = QualifySystemCommand(command);
    // And named outright, so nothing about the search order can matter: with
    // lpApplicationName set, CreateProcess runs exactly that file.
    const std::wstring program = CommandProgram(mutable_command);
    const bool absolute = program.size() > 2 && program[1] == L':';
    if (!CreateProcessW(absolute ? program.c_str() : nullptr, mutable_command.data(), nullptr,
                        nullptr, FALSE, CREATE_NO_WINDOW, nullptr, nullptr, &startup,
                        &process)) {
        return kRunFailed;
    }
    DWORD code = kRunFailed;
    if (WaitForSingleObject(process.hProcess, timeout_ms) == WAIT_OBJECT_0) {
        GetExitCodeProcess(process.hProcess, &code);
    } else {
        // Hidden, windowless and with nobody waiting on it once this returns, a
        // child left running would go on changing the machine behind a screen
        // that has already reported. Each of these commands hands its change to
        // a service, so killing the client end cannot leave one half done.
        TerminateProcess(process.hProcess, 1);
        code = kRunTimedOut;
    }
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return code;
}

std::string RunOutcome(DWORD code) {
    if (code == kRunTimedOut) {
        return "was still running at its time limit and was stopped";
    }
    if (code == kRunFailed) {
        return "would not start";
    }
    return "returned " + std::to_string((int) code);
}

}  // namespace solstream
