#include "util.h"

#include <algorithm>
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

std::wstring LocalDataPath(const wchar_t* file) {
    wchar_t buffer[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH)) {
        return {};
    }
    const std::wstring dir = std::wstring(buffer) + L"\\SolStream";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir + L"\\" + file;
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
    const size_t rest = command[0] == L'"' ? program.size() + 2 : program.size();
    return L"\"" + std::wstring(system_dir) + L"\\" + program + L"\""
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
