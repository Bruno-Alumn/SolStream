#include "installer.h"

#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>

#include <cstdio>
#include <string>
#include <vector>

#include "ports.h"

namespace solstream {
namespace {

constexpr wchar_t kTaskName[] = L"SolStream Host";

/// Installing writes a log, because installing is the one thing that happens on
/// a machine nobody is watching, before there is any window to report into, and
/// under an elevated relaunch whose console vanishes the moment it returns. A
/// failure with no message and no file is a support conversation that cannot
/// start; this is the file to ask for.
void InstallLog(const std::string& line) {
    wchar_t temp[MAX_PATH] = {0};
    if (GetTempPathW(MAX_PATH, temp) == 0) {
        return;
    }
    const std::wstring path = std::wstring(temp) + L"solstream-install.log";
    HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA, FILE_SHARE_READ,
                              nullptr, OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }
    SYSTEMTIME now{};
    GetLocalTime(&now);
    char stamp[32] = {0};
    std::snprintf(stamp, sizeof(stamp), "%02d:%02d:%02d  ", now.wHour, now.wMinute,
                  now.wSecond);
    const std::string text = std::string(stamp) + line + "\r\n";
    DWORD written = 0;
    WriteFile(file, text.data(), (DWORD) text.size(), &written, nullptr);
    CloseHandle(file);
    // Still to stderr, for anyone running it from a console on purpose.
    std::fprintf(stderr, "%s\n", line.c_str());
}

std::wstring ExePath() {
    wchar_t buffer[MAX_PATH] = {0};
    GetModuleFileNameW(nullptr, buffer, MAX_PATH);
    return buffer;
}

std::wstring DirectoryOf(const std::wstring& path) {
    const size_t slash = path.find_last_of(L'\\');
    return slash == std::wstring::npos ? std::wstring() : path.substr(0, slash);
}

std::string Narrow(const std::wstring& text) {
    if (text.empty()) {
        return {};
    }
    const int needed = WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(),
                                           nullptr, 0, nullptr, nullptr);
    std::string out((size_t) needed, '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(), out.data(),
                        needed, nullptr, nullptr);
    return out;
}

/// Run a command and wait, returning its exit code. Used for netsh and
/// schtasks, which are Windows' own tools rather than anything we ship.
DWORD RunHidden(const std::wstring& command) {
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION process{};
    std::wstring mutable_command = command;
    if (!CreateProcessW(nullptr, mutable_command.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW, nullptr, nullptr, &startup, &process)) {
        return 0xFFFFFFFF;
    }
    WaitForSingleObject(process.hProcess, 120000);
    DWORD code = 0xFFFFFFFF;
    GetExitCodeProcess(process.hProcess, &code);
    CloseHandle(process.hThread);
    CloseHandle(process.hProcess);
    return code;
}

bool CopyTree(const std::wstring& from, const std::wstring& to, std::string& error) {
    if (!CreateDirectoryW(to.c_str(), nullptr)
        && GetLastError() != ERROR_ALREADY_EXISTS) {
        error = "Could not create " + Narrow(to);
        return false;
    }
    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW((from + L"\\*").c_str(), &found);
    if (search == INVALID_HANDLE_VALUE) {
        error = "Could not read " + Narrow(from);
        return false;
    }
    bool ok = true;
    do {
        const std::wstring name = found.cFileName;
        if (name == L"." || name == L"..") {
            continue;
        }
        const std::wstring source = from + L"\\" + name;
        const std::wstring target = to + L"\\" + name;
        if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            if (!CopyTree(source, target, error)) {
                ok = false;
                break;
            }
        } else if (!CopyFileW(source.c_str(), target.c_str(), FALSE)) {
            error = "Could not copy " + Narrow(name) + " (error "
                  + std::to_string(GetLastError()) + ")";
            ok = false;
            break;
        }
    } while (FindNextFileW(search, &found));
    FindClose(search);
    return ok;
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
            if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
                RemoveTree(child);
            } else {
                SetFileAttributesW(child.c_str(), FILE_ATTRIBUTE_NORMAL);
                DeleteFileW(child.c_str());
            }
        } while (FindNextFileW(search, &found));
        FindClose(search);
    }
    RemoveDirectoryW(path.c_str());
}

/// Write the embedded Sunshine archive out and unpack it into `destination`.
///
/// Only reached when the executable is travelling alone — a development tree has
/// a real sunshine\ folder beside it and that is copied normally. Returns false
/// with `error` untouched when there is no embedded archive, which is not a
/// failure, just the other arrangement.
bool ExtractBundledSunshine(const std::wstring& destination, std::string& error) {
    HRSRC found = FindResourceW(nullptr, L"SUNSHINE_ARCHIVE", RT_RCDATA);
    if (!found) {
        return false;
    }
    HGLOBAL loaded = LoadResource(nullptr, found);
    const void* bytes = loaded ? LockResource(loaded) : nullptr;
    const DWORD size = SizeofResource(nullptr, found);
    if (!bytes || size == 0) {
        return false;
    }

    wchar_t temp[MAX_PATH] = {0};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring archive = std::wstring(temp) + L"solstream-sunshine.zip";
    HANDLE file = CreateFileW(archive.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        error = "Could not write the bundled Sunshine archive to a temporary file.";
        return false;
    }
    DWORD written = 0;
    const bool wrote = WriteFile(file, bytes, size, &written, nullptr) && written == size;
    CloseHandle(file);
    if (!wrote) {
        DeleteFileW(archive.c_str());
        error = "Could not write the bundled Sunshine archive (out of disk?).";
        return false;
    }

    SHCreateDirectoryExW(nullptr, destination.c_str(), nullptr);
    // tar.exe has been in Windows since 10 1803 and reads zip through
    // libarchive, so unpacking needs nothing shipped and no PowerShell.
    const DWORD code = RunHidden(L"tar.exe -x -f \"" + archive + L"\" -C \""
                                 + destination + L"\"");
    DeleteFileW(archive.c_str());
    if (code != 0) {
        error = "Could not unpack the bundled Sunshine (tar returned "
              + std::to_string((int) code) + ").";
        return false;
    }
    InstallLog("unpacked the bundled Sunshine");
    return true;
}

/// Stop anything already running out of the install directory, or the copy
/// fails on a locked executable and leaves a half-installed folder.
void StopInstalled(const std::wstring& destination) {
    // Every process of that name EXCEPT this one. The installer is itself
    // SolStream.exe, so an unfiltered taskkill terminates the install halfway
    // through — which is exactly what it did: the log stopped after "installing
    // from ... to ...", with nothing copied and an exit code that only meant
    // "killed".
    const std::wstring mine = std::to_wstring(GetCurrentProcessId());
    RunHidden(L"taskkill.exe /F /IM SolStream.exe /FI \"PID ne " + mine + L"\"");
    RunHidden(L"taskkill.exe /F /IM SolStreamAgent.exe /FI \"PID ne " + mine + L"\"");
    // Only the Sunshine that belongs to this install. A Sunshine the user set up
    // themselves is none of our business and killing it would be a rude surprise.
    const std::wstring ours = destination + L"\\sunshine\\sunshine.exe";
    RunHidden(L"powershell.exe -NoProfile -Command \"Get-Process sunshine "
              L"-ErrorAction SilentlyContinue | Where-Object { $_.Path -eq '"
              + ours + L"' } | Stop-Process -Force\"");
    Sleep(1500);
}

void DeleteRule(const std::wstring& name) {
    RunHidden(L"netsh.exe advfirewall firewall delete rule name=\"" + name + L"\"");
}

/// One rule, naming both the program and the ports it may use.
///
/// Naming the program is what stops Windows asking the user whether to allow it
/// — that prompt is raised per-executable, and on this project it once landed on
/// a display with no monitor and blocked every click for days. Naming the ports
/// as well is what keeps the rule honest: a program rule on its own opens every
/// port that executable ever binds, and for Sunshine that includes its web
/// configuration UI, which has no business being reachable from the network.
bool AddRule(const std::wstring& name, const std::wstring& program,
             const std::wstring& protocol, const std::wstring& ports) {
    DeleteRule(name);
    const std::wstring command =
        L"netsh.exe advfirewall firewall add rule"
        L" name=\"" + name + L"\""
        L" dir=in action=allow"
        L" program=\"" + program + L"\""
        L" protocol=" + protocol +
        L" localport=" + ports +
        L" profile=private,public"
        L" description=\"SolStream remote application streaming\"";
    return RunHidden(command) == 0;
}

std::wstring PortList(std::initializer_list<int> offsets) {
    std::wstring out;
    for (int offset : offsets) {
        if (!out.empty()) {
            out += L",";
        }
        out += std::to_wstring(kDefaultSunshineBase + offset);
    }
    return out;
}

/// The task is registered from XML rather than from schtasks' own switches.
///
/// schtasks /tr takes the whole command as one string and splits it on spaces,
/// so "C:\Program Files\SolStream\SolStream.exe" was stored as
/// Command="C:\Program" with the rest as arguments, and the task failed with
/// ERROR_FILE_NOT_FOUND. Quoting does not survive the trip. XML has somewhere
/// to put the arguments, so the question never arises.
bool RegisterLogonTask(const std::wstring& destination, std::string& error) {
    wchar_t temp[MAX_PATH] = {0};
    GetTempPathW(MAX_PATH, temp);
    const std::wstring xml_path = std::wstring(temp) + L"solstream-task.xml";

    // Whoever is at the console, not whoever ran the installer: an administrator
    // setting this up for somebody else must not register a task that runs as
    // themselves.
    wchar_t user[256] = {0};
    DWORD user_size = 256;
    GetUserNameW(user, &user_size);
    wchar_t machine[256] = {0};
    DWORD machine_size = 256;
    GetComputerNameW(machine, &machine_size);
    const std::wstring account = std::wstring(machine) + L"\\" + user;

    const std::wstring xml =
        L"<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n"
        L"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n"
        L"  <RegistrationInfo><Description>Starts SolStream so this PC can serve a Mac.</Description></RegistrationInfo>\r\n"
        L"  <Triggers><LogonTrigger><Enabled>true</Enabled></LogonTrigger></Triggers>\r\n"
        L"  <Principals><Principal id=\"Author\">\r\n"
        // The account belongs here rather than on schtasks' /ru switch. With /ru
        // and no /rp, schtasks asks for a password on a console nobody is
        // watching and simply never returns — it sat there for the full two
        // minute timeout and reported 259, STILL_ACTIVE. Declared in the XML
        // alongside InteractiveToken, no password is wanted at all.
        L"    <UserId>" + account + L"</UserId>\r\n"
        // Interactive and least-privilege. A process in session 0 sees a phantom
        // 1024x768 desktop and no windows at all, so it could neither show its
        // own window nor find the application the Mac asked to stream.
        L"    <LogonType>InteractiveToken</LogonType>\r\n"
        L"    <RunLevel>LeastPrivilege</RunLevel>\r\n"
        L"  </Principal></Principals>\r\n"
        L"  <Settings>\r\n"
        L"    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>\r\n"
        L"    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>\r\n"
        L"    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>\r\n"
        L"    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>\r\n"
        L"    <Enabled>true</Enabled>\r\n"
        L"  </Settings>\r\n"
        L"  <Actions Context=\"Author\">\r\n"
        L"    <Exec>\r\n"
        L"      <Command>" + destination + L"\\SolStream.exe</Command>\r\n"
        // --listen-all because an installed host that only answers on loopback is
        // one no Mac can reach. The socket still requires the pairing token off
        // loopback; the window shows that token. That is the lock, not the address.
        L"      <Arguments>--listen-all</Arguments>\r\n"
        L"      <WorkingDirectory>" + destination + L"</WorkingDirectory>\r\n"
        L"    </Exec>\r\n"
        L"  </Actions>\r\n"
        L"</Task>\r\n";

    HANDLE file = CreateFileW(xml_path.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        error = "Could not write the scheduled task definition.";
        return false;
    }
    const unsigned char bom[2] = {0xFF, 0xFE};  // UTF-16 LE, which schtasks wants
    DWORD written = 0;
    WriteFile(file, bom, 2, &written, nullptr);
    WriteFile(file, xml.data(), (DWORD) (xml.size() * sizeof(wchar_t)), &written, nullptr);
    CloseHandle(file);

    const std::wstring command = L"schtasks.exe /create /tn \"" + std::wstring(kTaskName)
                               + L"\" /xml \"" + xml_path + L"\" /f";
    const DWORD code = RunHidden(command);
    DeleteFileW(xml_path.c_str());
    if (code != 0) {
        error = "Could not register the logon task (schtasks returned "
              + std::to_string((int) code) + ").";
        return false;
    }
    return true;
}

}  // namespace

bool IsElevated() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return false;
    }
    TOKEN_ELEVATION elevation{};
    DWORD size = sizeof(elevation);
    const bool ok = GetTokenInformation(token, TokenElevation, &elevation,
                                        sizeof(elevation), &size) != 0;
    CloseHandle(token);
    return ok && elevation.TokenIsElevated != 0;
}

bool RelaunchElevated(const std::wstring& arguments, std::string& error) {
    const std::wstring exe = ExePath();
    SHELLEXECUTEINFOW execute{};
    execute.cbSize = sizeof(execute);
    execute.fMask = SEE_MASK_NOCLOSEPROCESS;
    execute.lpVerb = L"runas";
    execute.lpFile = exe.c_str();
    execute.lpParameters = arguments.c_str();
    execute.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&execute)) {
        error = GetLastError() == ERROR_CANCELLED
                    ? "SolStream needs administrator rights to install, and the "
                      "prompt was dismissed."
                    : "Could not restart SolStream with administrator rights.";
        return false;
    }
    if (execute.hProcess) {
        WaitForSingleObject(execute.hProcess, INFINITE);
        CloseHandle(execute.hProcess);
    }
    return true;
}

std::wstring InstallDirectory() {
    // The environment variable rather than SHGetKnownFolderPath: the KNOWNFOLDERID
    // GUIDs live in a separate import library that the mingw cross-build does not
    // link, and this is the same answer on a 64-bit process either way.
    wchar_t root[MAX_PATH] = {0};
    if (GetEnvironmentVariableW(L"ProgramW6432", root, MAX_PATH) == 0
        && GetEnvironmentVariableW(L"ProgramFiles", root, MAX_PATH) == 0) {
        wcscpy_s(root, MAX_PATH, L"C:\\Program Files");
    }
    return std::wstring(root) + L"\\SolStream";
}

bool RunningInstalled() {
    std::wstring here = DirectoryOf(ExePath());
    std::wstring there = InstallDirectory();
    for (wchar_t& c : here) { c = (wchar_t) towlower(c); }
    for (wchar_t& c : there) { c = (wchar_t) towlower(c); }
    return here == there;
}

bool InstallSelf(std::string& error) {
    InstallLog("install requested");
    if (!IsElevated()) {
        error = "Installing needs administrator rights.";
        return false;
    }
    const std::wstring source = DirectoryOf(ExePath());
    const std::wstring destination = InstallDirectory();
    if (RunningInstalled()) {
        error = "SolStream is already installed here.";
        return false;
    }
    // Two shapes are legitimate. A single downloaded executable carries Sunshine
    // inside it; a development tree has the folder sitting beside it. Anything
    // else cannot stream and should say so now rather than after copying.
    const bool beside = GetFileAttributesW((source + L"\\sunshine\\sunshine.exe").c_str())
                        != INVALID_FILE_ATTRIBUTES;
    const bool embedded = FindResourceW(nullptr, L"SUNSHINE_ARCHIVE", RT_RCDATA) != nullptr;
    if (!beside && !embedded) {
        error = "This copy of SolStream has no Sunshine with it — neither bundled "
                "inside the executable nor in a sunshine\\ folder beside it — so it "
                "cannot stream.";
        return false;
    }

    InstallLog("installing from " + Narrow(source) + " to " + Narrow(destination));
    StopInstalled(destination);
    if (!CopyTree(source, destination, error)) {
        InstallLog("copy failed: " + error);
        return false;
    }
    InstallLog("copied");
    if (!beside) {
        // Nothing was copied but the executable itself; Sunshine is inside it.
        if (!ExtractBundledSunshine(destination, error)) {
            InstallLog("unpack failed: " + error);
            return false;
        }
    }

    // Sunshine creates this at startup whatever its configuration says, and under
    // Program Files an ordinary user cannot -- it exits 0 before its logging is
    // up, leaving an empty log and a host that says "Sunshine keeps stopping"
    // with no reason. Made here, where there are rights to make it.
    const std::wstring config = destination + L"\\sunshine\\config";
    SHCreateDirectoryExW(nullptr, config.c_str(), nullptr);

    const std::wstring exe = destination + L"\\SolStream.exe";
    const std::wstring sunshine = destination + L"\\sunshine\\sunshine.exe";
    AddRule(L"SolStream - agent", exe, L"TCP", std::to_wstring(kDefaultAgentPort));
    AddRule(L"SolStream - Sunshine TCP", sunshine, L"TCP",
            PortList({(int) SunshinePort::kHttps, (int) SunshinePort::kHttp,
                      (int) SunshinePort::kRtsp}));
    AddRule(L"SolStream - Sunshine UDP", sunshine, L"UDP",
            PortList({(int) SunshinePort::kVideo, (int) SunshinePort::kControl,
                      (int) SunshinePort::kAudio}));

    InstallLog("firewall rules written");
    if (!RegisterLogonTask(destination, error)) {
        InstallLog("task failed: " + error);
        return false;
    }
    InstallLog("logon task registered");
    RunHidden(L"schtasks.exe /run /tn \"" + std::wstring(kTaskName) + L"\"");
    return true;
}

bool UninstallSelf(std::string& error) {
    InstallLog("uninstall requested");
    if (!IsElevated()) {
        error = "Removing SolStream needs administrator rights.";
        return false;
    }
    const std::wstring destination = InstallDirectory();
    RunHidden(L"schtasks.exe /end /tn \"" + std::wstring(kTaskName) + L"\"");
    RunHidden(L"schtasks.exe /delete /tn \"" + std::wstring(kTaskName) + L"\" /f");
    StopInstalled(destination);
    DeleteRule(L"SolStream - agent");
    DeleteRule(L"SolStream - Sunshine TCP");
    DeleteRule(L"SolStream - Sunshine UDP");
    // Older installs named their rules differently; leaving those behind would
    // quietly keep ports open for an executable that no longer exists.
    DeleteRule(L"SolStream (SolStream.exe, TCP)");
    DeleteRule(L"SolStream (SolStream.exe, UDP)");
    DeleteRule(L"SolStream (sunshine.exe, TCP)");
    DeleteRule(L"SolStream (sunshine.exe, UDP)");
    RemoveTree(destination);
    if (GetFileAttributesW(destination.c_str()) != INVALID_FILE_ATTRIBUTES) {
        error = "Removed what it could, but " + Narrow(destination)
              + " is still there — something in it was in use.";
        return false;
    }
    return true;
}

}  // namespace solstream
