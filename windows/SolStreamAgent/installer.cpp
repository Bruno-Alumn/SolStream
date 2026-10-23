#include "installer.h"

#include <windows.h>
#include <shlobj.h>
#include <shellapi.h>
#include <objbase.h>
#include <sddl.h>
#include <aclapi.h>
#include <bcrypt.h>
#include <oleauto.h>
#include <taskschd.h>
#include <wtsapi32.h>

#include <cstdio>
#include <string>
#include <vector>

#include "driver_install.h"
#include "host_window.h"
#include "ports.h"
#include "util.h"

namespace solstream {
namespace {

constexpr wchar_t kTaskName[] = L"SolStream Host";
constexpr wchar_t kUninstallKey[] =
    L"SOFTWARE\\Microsoft\\Windows\\CurrentVersion\\Uninstall\\SolStream";
constexpr wchar_t kShortcutName[] = L"SolStream.lnk";

/// The two things the elevated half cannot work out for itself, so the
/// unelevated half tells it: who is at the keyboard, and what to call the file it
/// leaves its answer in. Both are appended on the way to the UAC prompt --
/// --invoking-user by OptionArguments, --result-token by RelaunchElevated -- and
/// read back off the elevated process's own command line.
constexpr wchar_t kInvokingUserSwitch[] = L"--invoking-user";
constexpr wchar_t kResultTokenSwitch[] = L"--result-token";

/// Who may do what in C:\ProgramData\SolStream. SYSTEM and Administrators own the
/// place; ordinary users get read, write and delete, which is all a transient
/// result file and a log are worth. Why it has to be written out rather than
/// inherited is in SharedDirectory.
constexpr wchar_t kSharedDacl[] =
    L"D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FRFWSD;;;BU)";

/// The value following `name` on THIS process's own command line, or empty.
///
/// Its own command line rather than the argv the program was started with: the
/// two places that need these values -- the name of the result file, and the
/// account the logon task belongs to -- sit at the bottom of call chains that
/// were never handed argv, and threading it down to them would mean changing
/// every signature in between and the header they are declared in.
std::wstring SwitchValue(const wchar_t* name) {
    int count = 0;
    wchar_t** args = CommandLineToArgvW(GetCommandLineW(), &count);
    if (args == nullptr) {
        return {};
    }
    std::wstring value;
    for (int i = 1; i + 1 < count; ++i) {
        if (std::wstring(args[i]) == name) {
            value = args[i + 1];
            break;
        }
    }
    LocalFree(args);
    return value;
}

/// This process's own user, as a SID string.
///
/// A SID rather than a name because a name means nothing without the domain it
/// belongs to, and guessing that domain is exactly the mistake this file used to
/// make -- it pasted the computer name in front of whatever GetUserNameW said.
std::wstring CurrentUserSid() {
    HANDLE token = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &token)) {
        return {};
    }
    DWORD size = 0;
    GetTokenInformation(token, TokenUser, nullptr, 0, &size);
    std::wstring out;
    if (size != 0) {
        std::vector<unsigned char> buffer(size);
        wchar_t* text = nullptr;
        if (GetTokenInformation(token, TokenUser, buffer.data(), size, &size)
            && ConvertSidToStringSidW(((TOKEN_USER*) buffer.data())->User.Sid, &text)
            && text != nullptr) {
            out = text;
            LocalFree(text);
        }
    }
    CloseHandle(token);
    return out;
}

/// Below, beside the log's path: SessionUserSid writes to it too.
void InstallLog(const std::string& line);

/// Whoever is signed in to the session this process runs in, as a SID string,
/// or empty when nobody is.
///
/// The person at this desktop, which is not always the account this process
/// runs as. "Run as administrator" with somebody else's name and password
/// typed in elevates to that administrator, inside the session of the person
/// who typed them, and Windows still knows that session as theirs. Only a user
/// account counts: whatever else a session might name -- a service account, a
/// group -- is nobody to start SolStream for.
std::wstring SessionUserSid() {
    std::wstring account;
    wchar_t* user = nullptr;
    wchar_t* domain = nullptr;
    DWORD bytes = 0;
    if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION,
                                    WTSUserName, &user, &bytes)
        && user != nullptr && user[0] != L'\0') {
        if (WTSQuerySessionInformationW(WTS_CURRENT_SERVER_HANDLE, WTS_CURRENT_SESSION,
                                        WTSDomainName, &domain, &bytes)
            && domain != nullptr && domain[0] != L'\0') {
            account = std::wstring(domain) + L"\\";
        }
        account += user;
    }
    if (user != nullptr) {
        WTSFreeMemory(user);
    }
    if (domain != nullptr) {
        WTSFreeMemory(domain);
    }
    if (account.empty()) {
        return {};
    }
    BYTE sid[SECURITY_MAX_SID_SIZE] = {0};
    DWORD sid_size = sizeof(sid);
    wchar_t found_domain[256] = {0};
    DWORD found_domain_size = 256;
    SID_NAME_USE kind = SidTypeUnknown;
    // Said in the log when it fails, because the task then goes to the account
    // this runs as, and the log is the one place that can say why: an Entra ID
    // or domain account whose name Windows can't look up from here, say.
    if (!LookupAccountNameW(nullptr, account.c_str(), sid, &sid_size, found_domain,
                            &found_domain_size, &kind)) {
        const DWORD code = GetLastError();
        InstallLog("could not look up " + ToUtf8(account)
                   + ", who is signed in to this session (error " + std::to_string(code)
                   + ")");
        return {};
    }
    if (kind != SidTypeUser) {
        InstallLog(ToUtf8(account) + ", signed in to this session, is not a user account");
        return {};
    }
    std::wstring out;
    wchar_t* text = nullptr;
    if (ConvertSidToStringSidW(sid, &text) && text != nullptr) {
        out = text;
        LocalFree(text);
    }
    return out;
}

std::wstring TempDirectory() {
    wchar_t temp[MAX_PATH] = {0};
    if (GetTempPathW(MAX_PATH, temp) == 0) {
        return L"C:\\Windows\\Temp\\";
    }
    return temp;
}

/// Is this SID one of the two accounts allowed to own C:\ProgramData\SolStream?
///
/// Ownership rather than permissions is the test that matters. An owner can
/// rewrite a DACL whenever it likes, so a directory owned by an ordinary user is
/// one that user controls no matter how sensible its permissions look at the
/// moment we read them.
bool SidIsAdminOrSystem(PSID sid) {
    if (sid == nullptr || !IsValidSid(sid)) {
        return false;
    }
    const WELL_KNOWN_SID_TYPE allowed[] = {WinBuiltinAdministratorsSid,
                                           WinLocalSystemSid};
    for (WELL_KNOWN_SID_TYPE type : allowed) {
        BYTE known[SECURITY_MAX_SID_SIZE] = {0};
        DWORD size = sizeof(known);
        if (CreateWellKnownSid(type, nullptr, known, &size) && EqualSid(sid, known)) {
            return true;
        }
    }
    return false;
}

/// Put an existing C:\ProgramData\SolStream beyond the reach of the account that
/// happens to have made it, or say that it cannot be done.
///
/// The awkward part is that BOTH halves of an install go through here, and the
/// unelevated one usually gets there first: the setup window prints the log path
/// on its failure screen and writes lines like "could not elevate" long before
/// any administrator is involved, so on a clean machine this folder is normally
/// created by, and therefore owned by, an ordinary user. Refusing anything not
/// already owned by Administrators would refuse the ordinary case. So the
/// elevated half REPAIRS instead: it takes ownership and rewrites the DACL, and
/// only gives up if it cannot. From then on both halves find it owned by
/// Administrators and leave it alone.
///
/// The unelevated half does not get a veto on ownership. It cannot repair
/// anything, and if it disagreed with the elevated half about which directory is
/// in use the two of them would go back to leaving the result file and the log in
/// different places -- which is the bug this whole directory exists to fix. It
/// writes there with its own privileges and nobody else's, so an odd owner costs
/// it nothing. A junction is refused for both, because following one lands
/// somewhere neither half meant to write.
///
/// One handle, opened once with FILE_FLAG_OPEN_REPARSE_POINT so a junction is
/// examined rather than followed, and every test and every change made through
/// that handle. Testing a path and then acting on the same path is two lookups
/// with a gap in between, and the gap is the thing being defended against.
///
/// Nothing in here logs. InstallLog asks for this directory, so a line written
/// from inside this call would come straight back round for another.
bool SecureExistingShared(const std::wstring& directory) {
    // Whether this process is expected to be able to put the folder right, which
    // is not the same question as whether the open below happens to succeed: an
    // elevated process denied WRITE_DAC by a hostile ACL must refuse, not carry
    // on as though it were the unelevated half.
    const bool elevated = IsElevated();
    const DWORD share = FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE;
    const DWORD flags = FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT;
    HANDLE handle = CreateFileW(
        directory.c_str(),
        READ_CONTROL | FILE_READ_ATTRIBUTES | WRITE_DAC | WRITE_OWNER, share,
        nullptr, OPEN_EXISTING, flags, nullptr);
    const bool repairing = handle != INVALID_HANDLE_VALUE;
    if (!repairing) {
        if (elevated) {
            return false;
        }
        handle = CreateFileW(directory.c_str(), READ_CONTROL | FILE_READ_ATTRIBUTES,
                             share, nullptr, OPEN_EXISTING, flags, nullptr);
        if (handle == INVALID_HANDLE_VALUE) {
            return false;
        }
    }

    bool ok = false;
    BY_HANDLE_FILE_INFORMATION info{};
    if (GetFileInformationByHandle(handle, &info)
        && (info.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0
        && (info.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) == 0) {
        PSECURITY_DESCRIPTOR descriptor = nullptr;
        PSID owner = nullptr;
        if (GetSecurityInfo(handle, SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION,
                            &owner, nullptr, nullptr, nullptr, &descriptor)
            == ERROR_SUCCESS) {
            ok = SidIsAdminOrSystem(owner);
            LocalFree(descriptor);
        }
        if (!ok && elevated) {
            // Setting the owner to the Administrators group needs no privilege
            // beyond WRITE_OWNER on the handle: an elevated token carries that
            // group marked as its default owner, which is why everything else an
            // administrator creates ends up owned by it too.
            BYTE admins[SECURITY_MAX_SID_SIZE] = {0};
            DWORD size = sizeof(admins);
            ok = CreateWellKnownSid(WinBuiltinAdministratorsSid, nullptr, admins,
                                    &size)
                 && SetSecurityInfo(handle, SE_FILE_OBJECT,
                                    OWNER_SECURITY_INFORMATION, admins, nullptr,
                                    nullptr, nullptr) == ERROR_SUCCESS;
        } else if (!ok) {
            ok = true;  // unelevated, as above
        }
    }

    if (ok && repairing) {
        // Protected, so that whatever the previous owner set is replaced rather
        // than merged with. In practice only the elevated half gets this far:
        // the ACL being written deliberately withholds WRITE_DAC and WRITE_OWNER
        // from ordinary users, so their open above asked for more than they have
        // and dropped back to the read-only one. Best effort even so — the owner
        // has already been settled by this point, and an owner is the thing that
        // decides who may rewrite an ACL tomorrow.
        PSECURITY_DESCRIPTOR wanted = nullptr;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
                kSharedDacl, SDDL_REVISION_1, &wanted, nullptr)) {
            BOOL present = FALSE;
            BOOL defaulted = FALSE;
            PACL dacl = nullptr;
            if (GetSecurityDescriptorDacl(wanted, &present, &dacl, &defaulted)
                && present) {
                SetSecurityInfo(handle, SE_FILE_OBJECT,
                                DACL_SECURITY_INFORMATION
                                    | PROTECTED_DACL_SECURITY_INFORMATION,
                                nullptr, nullptr, dacl, nullptr);
            }
            LocalFree(wanted);
        }
    }
    CloseHandle(handle);
    return ok;
}

/// Where the two halves of an install leave things for each other. Ends in a
/// backslash, like TempDirectory does.
///
/// The result file and the log used to live under GetTempPathW, and %TEMP% is
/// per-account. UAC is allowed to elevate to a DIFFERENT account -- that is what
/// happens whenever a standard user types an administrator's name and password
/// at the prompt rather than clicking Yes -- and when it does, the elevated half
/// wrote its answer into the administrator's %TEMP% while the window waiting for
/// it looked in the user's own, found nothing, and told somebody whose install
/// had just succeeded "The install did not run." The log had the same split: the
/// setup screen prints the path of the user's copy, which is the one that does
/// NOT contain the lines explaining what went wrong.
///
/// ProgramData is the machine-wide equivalent and is the same path for every
/// account. The DACL has to be spelled out because the one this folder inherits
/// gives ordinary users read and execute only: the waiting window could then
/// read the administrator's result file but not delete it, so the next run would
/// pick up the last run's answer, and the unelevated half of an uninstall could
/// not append to the log at all.
///
/// The DACL used to be applied only on the call that CREATED the folder, and a
/// folder that already existed was taken exactly as it was found. That is the
/// wrong way round. ProgramData's own permissions let any user create a
/// subdirectory in it, and nothing reserves this name until SolStream is first
/// installed, so a standard user could make C:\ProgramData\SolStream first -- as
/// its owner, with whatever ACL they liked, or as a junction pointing somewhere
/// else entirely -- and then simply wait: the elevated half would write its
/// result file and its log through a directory that user controlled.
/// SecureExistingShared is the answer, and it runs on every path that did not
/// just create the folder outright.
std::wstring SharedDirectory() {
    wchar_t root[MAX_PATH] = {0};
    if (GetEnvironmentVariableW(L"ProgramData", root, MAX_PATH) == 0) {
        wcscpy_s(root, MAX_PATH, L"C:\\ProgramData");
    }
    const std::wstring directory = std::wstring(root) + L"\\SolStream";
    SECURITY_ATTRIBUTES attributes{};
    attributes.nLength = sizeof(attributes);
    PSECURITY_DESCRIPTOR descriptor = nullptr;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(
            kSharedDacl, SDDL_REVISION_1, &descriptor, nullptr)) {
        attributes.lpSecurityDescriptor = descriptor;
    }
    const BOOL made = CreateDirectoryW(directory.c_str(),
                                       descriptor != nullptr ? &attributes : nullptr);
    const DWORD made_error = GetLastError();
    if (descriptor != nullptr) {
        LocalFree(descriptor);
    }
    if (!made && made_error != ERROR_ALREADY_EXISTS) {
        // Nowhere machine-wide to write. %TEMP% at least exists, and a log only
        // one of the two accounts can see beats no log.
        return TempDirectory();
    }
    if (!made && !SecureExistingShared(directory)) {
        // It is there and it is not ours. %TEMP% for the same reason as above,
        // and this time also because it is the one directory nobody else can
        // have got to first.
        return TempDirectory();
    }
    return directory + L"\\";
}

/// Installing writes a log, because installing is the one thing that happens on
/// a machine nobody is watching, before there is any window to report into, and
/// under an elevated relaunch whose console vanishes the moment it returns. A
/// failure with no message and no file is a support conversation that cannot
/// start; this is the file to ask for.
void InstallLog(const std::string& line) {
    const std::wstring path = InstallLogPath();
    // Shared for writing as well as reading: there is one log for the whole
    // machine now, and the setup window and the elevated half it launched are
    // both appending to it. Without this the second one to arrive is refused and
    // its line -- which is the one saying what went wrong -- is simply lost.
    HANDLE file = CreateFileW(path.c_str(), FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE,
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

/// Add/Remove Programs shows a size, and an entry with no size looks like a
/// broken one. Kilobytes, which is the unit that registry value is in.
DWORD TreeSizeKb(const std::wstring& path) {
    unsigned long long bytes = 0;
    WIN32_FIND_DATAW found{};
    HANDLE search = FindFirstFileW((path + L"\\*").c_str(), &found);
    if (search == INVALID_HANDLE_VALUE) {
        return 0;
    }
    do {
        const std::wstring name = found.cFileName;
        if (name == L"." || name == L"..") {
            continue;
        }
        if (found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) {
            bytes += (unsigned long long) TreeSizeKb(path + L"\\" + name) * 1024ull;
        } else {
            bytes += ((unsigned long long) found.nFileSizeHigh << 32) | found.nFileSizeLow;
        }
    } while (FindNextFileW(search, &found));
    FindClose(search);
    return (DWORD) (bytes / 1024ull);
}


/// Ask each host running out of the install directory, on this desktop, to
/// quit the way its tray's Quit does, and give it a moment to.
///
/// Stopped by force, a host never reached WM_DESTROY: its notification icon
/// stayed by the clock, dead and still saying whatever it last said, beside
/// the icon of the copy that replaced it; and a window being streamed when
/// somebody reinstalled or uninstalled kept the locked style, the topmost bit
/// and the virtual-display placement the stream gave it. Asked, it puts all of
/// that back on its way out. StopInstalled still stops by force whatever is
/// left, so a host that will not answer -- hung, or a copy from before this
/// request existed, which answers 0 -- costs at most a few seconds' wait.
///
/// Found by window class and then held to the same rule as StopInstalled: its
/// program must be under the install directory. Setup's window has a class of
/// its own, and a host somebody runs from anywhere else is not ours to end.
void AskInstalledHostsToQuit(const std::wstring& destination) {
    std::vector<HWND> windows;
    for (HWND window = FindWindowExW(nullptr, nullptr, kHostWindowClass, nullptr);
         window != nullptr;
         window = FindWindowExW(nullptr, window, kHostWindowClass, nullptr)) {
        windows.push_back(window);
    }
    if (windows.empty()) {
        return;
    }
    const UINT quit = RegisterWindowMessageW(kQuitHostMessage);
    const std::wstring inside = FoldCase(destination + L"\\");
    for (HWND window : windows) {
        DWORD pid = 0;
        GetWindowThreadProcessId(window, &pid);
        if (pid == 0 || pid == GetCurrentProcessId()) {
            continue;
        }
        HANDLE process =
            OpenProcess(SYNCHRONIZE | PROCESS_QUERY_LIMITED_INFORMATION, FALSE, pid);
        if (process == nullptr) {
            continue;
        }
        wchar_t image[MAX_PATH * 2] = {0};
        DWORD size = MAX_PATH * 2;
        const bool ours = QueryFullProcessImageNameW(process, 0, image, &size)
                          && FoldCase(image).rfind(inside, 0) == 0;
        DWORD_PTR answer = 0;
        if (ours && quit != 0
            && SendMessageTimeoutW(window, quit, 0, 0, SMTO_ABORTIFHUNG | SMTO_BLOCK, 2000,
                                   &answer)
            && answer == kHostQuitting) {
            // Long enough to stop a stream and give its windows back, which
            // takes well under a second. A host still here after that is
            // stopped by force like anything else.
            InstallLog(WaitForSingleObject(process, 5000) == WAIT_OBJECT_0
                           ? "the running host quit when asked"
                           : "the running host was asked to quit and had not after 5 "
                             "seconds");
        }
        CloseHandle(process);
    }
}

/// Stop by force whatever is still running out of the install directory.
void ForceStopInstalled(const std::wstring& destination) {
    // By WHERE a process is running from, never by what it is called.
    //
    // The point of this is to release locks on files about to be overwritten,
    // and only a process running out of the install directory holds one. Killing
    // by image name instead was wrong twice over. It killed the installer itself
    // — the installer IS SolStream.exe — which stopped the install dead after
    // "installing from ... to ...", with nothing copied and an exit code that
    // only meant "killed". Adding a PID filter fixed that and introduced the
    // second one: the setup window and the elevated half it launches are the
    // same file with different PIDs, so the install killed the window that was
    // waiting to tell the user how it went. The user saw setup vanish.
    //
    // A path test has neither problem, and it also catches any helper that
    // belongs to this install without touching a program somebody else set up
    // themselves — which is none of our business and would be a rude surprise.
    const std::wstring mine = std::to_wstring(GetCurrentProcessId());
    const DWORD code =
        RunHidden(L"powershell.exe -NoProfile -Command \""
                  L"Get-CimInstance Win32_Process | Where-Object { "
                  L"$_.ProcessId -ne " + mine + L" -and $_.ExecutablePath -and "
                  L"$_.ExecutablePath.StartsWith('" + destination + L"\\', "
                  L"[System.StringComparison]::OrdinalIgnoreCase) } | ForEach-Object { "
                  L"Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }\"");
    if (code != 0) {
        // Whatever was running is still running, so the copy that follows is
        // about to fail on a locked file and say only that it could not copy.
        // This is the line that explains which of the two things went wrong.
        InstallLog("could not look for a running copy in the install directory "
                   "(powershell " + RunOutcome(code) + ")");
    }
    Sleep(1500);
}

/// Stop anything already running out of the install directory, or the copy
/// fails on a locked executable and leaves a half-installed folder.
void StopInstalled(const std::wstring& destination) {
    // Asked to quit first, and only what is still here after that is stopped
    // by force: see AskInstalledHostsToQuit.
    AskInstalledHostsToQuit(destination);
    ForceStopInstalled(destination);
}

void DeleteRule(const std::wstring& name) {
    RunHidden(L"netsh.exe advfirewall firewall delete rule name=\"" + name + L"\"");
}

/// Delete every firewall rule this project has ever created, by the program it
/// points at rather than by name.
///
/// Removing them by name needs the uninstaller to know every name any past build
/// used, and it did not: it deleted "SolStream - agent" and a handful of
/// Sunshine-era ones, while the build that wrote it had already renamed the
/// second rule to "SolStream - media" and added others. So an uninstall left
/// inbound UDP open for an executable that no longer existed -- exactly what the
/// name list was there to prevent, quietly failing at it. Matching on the
/// program path cannot go stale the same way: whatever the rule is called, if it
/// points into the install directory it goes.
void DeleteRulesForProgram(const std::wstring& directory) {
    // Windows also creates its own allow rules, named after the executable, when
    // a program first listens and someone clicks Allow. Those are ours to remove
    // too -- nobody else will, and they outlive the file they name.
    //
    // Three minutes rather than RunHidden's one. One query over every program
    // filter is quick, but PowerShell loading the firewall module is not, and
    // a sweep stopped part-way leaves exactly the rules it exists to remove.
    const DWORD code = RunHidden(FirewallSweepCommand(directory), 180000);
    if (code != 0) {
        // The sweep is the only thing that finds rules this build does not know
        // the names of, so if it did not run, inbound ports are left open for an
        // executable that is about to be deleted. The uninstall carries on --
        // there is nothing better to do -- but it does not get to be silent.
        InstallLog("could not sweep the firewall rules pointing into the install "
                   "directory (powershell " + RunOutcome(code)
                   + "); any rule left behind can be removed in Windows Defender "
                     "Firewall");
    }
}

bool AddRule(const std::wstring& name, const std::wstring& program,
             const std::wstring& protocol, const std::wstring& ports) {
    DeleteRule(name);
    return RunHidden(FirewallRuleCommand(name, program, protocol, ports)) == 0;
}

// ── Shortcuts ────────────────────────────────────────────────────────────────

/// A .lnk, written the only way Windows writes one.
///
/// The all-users folders rather than the installing account's, because the
/// install itself is machine-wide: it lives in Program Files and opens firewall
/// rules for everyone. A shortcut visible only to whoever happened to approve
/// the UAC prompt would be the one part of it that was not.
bool CreateShortcut(const std::wstring& link_path, const std::wstring& target,
                    const std::wstring& description) {
    IShellLinkW* link = nullptr;
    if (FAILED(CoCreateInstance(CLSID_ShellLink, nullptr, CLSCTX_INPROC_SERVER,
                                IID_IShellLinkW, (void**) &link))
        || link == nullptr) {
        return false;
    }
    link->SetPath(target.c_str());
    link->SetWorkingDirectory(DirectoryOf(target).c_str());
    link->SetDescription(description.c_str());
    link->SetIconLocation(target.c_str(), 0);

    IPersistFile* persist = nullptr;
    bool ok = false;
    if (SUCCEEDED(link->QueryInterface(IID_IPersistFile, (void**) &persist))
        && persist != nullptr) {
        ok = SUCCEEDED(persist->Save(link_path.c_str(), TRUE));
        persist->Release();
    }
    link->Release();
    return ok;
}

/// CSIDL rather than KNOWNFOLDERID for the same reason InstallDirectory reads an
/// environment variable: the FOLDERID GUIDs live in an import library the mingw
/// cross-build does not link, and this program is cross-compiled from a Mac.
std::wstring SystemFolder(int csidl) {
    wchar_t path[MAX_PATH] = {0};
    if (FAILED(SHGetFolderPathW(nullptr, csidl, nullptr, SHGFP_TYPE_CURRENT, path))) {
        return {};
    }
    return path;
}

std::wstring StartMenuShortcutPath() {
    const std::wstring folder = SystemFolder(CSIDL_COMMON_PROGRAMS);
    return folder.empty() ? std::wstring() : folder + L"\\" + kShortcutName;
}

std::wstring DesktopShortcutPath() {
    const std::wstring folder = SystemFolder(CSIDL_COMMON_DESKTOPDIRECTORY);
    return folder.empty() ? std::wstring() : folder + L"\\" + kShortcutName;
}

/// Delete a shortcut, and say so when it will not go.
///
/// Not finding one is the ordinary case: it was never written, or somebody
/// removed it themselves. A refusal is not ordinary, and it leaves a shortcut
/// pointing at an executable that is no longer there -- which is the sort of
/// thing reported as "it did not uninstall properly", with nothing to go on.
void RemoveShortcutFile(const std::wstring& path) {
    if (DeleteFileW(path.c_str())) {
        return;
    }
    const DWORD code = GetLastError();
    if (code == ERROR_FILE_NOT_FOUND || code == ERROR_PATH_NOT_FOUND) {
        return;
    }
    InstallLog("could not remove " + ToUtf8(path) + " (error "
               + std::to_string((int) code) + ")");
}

void WriteShortcuts(const std::wstring& destination, const InstallOptions& options) {
    const std::wstring exe = InstalledExe(destination);
    const std::wstring description = L"Stream one Windows application to your Mac";

    // COM has to be up for IShellLink, and this process may not have initialised
    // it: the install runs on its own in an elevated relaunch with no message
    // loop and nothing else that needs it.
    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    const bool started_com = SUCCEEDED(com);

    const std::wstring start_menu = StartMenuShortcutPath();
    if (start_menu.empty()) {
        // Windows would not name the all-users Start Menu, so there is nothing to
        // write and nothing to remove. This used to fall through both branches
        // without a word, which meant a ticked box and no shortcut and no reason.
        InstallLog("could not find the all-users start menu folder");
    } else if (options.start_menu_shortcut) {
        InstallLog(CreateShortcut(start_menu, exe, description)
                       ? "start menu shortcut written"
                       : "could not write the start menu shortcut");
    } else {
        // Not asked for this time. Removing any earlier one keeps the ticks on
        // the setup screen honest across a reinstall.
        RemoveShortcutFile(start_menu);
    }

    const std::wstring desktop = DesktopShortcutPath();
    if (desktop.empty()) {
        InstallLog("could not find the all-users desktop folder");
    } else if (options.desktop_shortcut) {
        InstallLog(CreateShortcut(desktop, exe, description)
                       ? "desktop shortcut written"
                       : "could not write the desktop shortcut");
    } else {
        RemoveShortcutFile(desktop);
    }

    if (started_com) {
        CoUninitialize();
    }
}

void RemoveShortcuts() {
    const std::wstring start_menu = StartMenuShortcutPath();
    if (!start_menu.empty()) {
        RemoveShortcutFile(start_menu);
    }
    const std::wstring desktop = DesktopShortcutPath();
    if (!desktop.empty()) {
        RemoveShortcutFile(desktop);
    }
}

// ── Add/Remove Programs ──────────────────────────────────────────────────────

void SetRegString(HKEY key, const wchar_t* name, const std::wstring& value) {
    RegSetValueExW(key, name, 0, REG_SZ, (const BYTE*) value.c_str(),
                   (DWORD) ((value.size() + 1) * sizeof(wchar_t)));
}

void SetRegDword(HKEY key, const wchar_t* name, DWORD value) {
    RegSetValueExW(key, name, 0, REG_DWORD, (const BYTE*) &value, sizeof(value));
}

/// The entry in Settings > Apps, which is where somebody looks to remove a
/// program and the only place they will think to look. Without it SolStream is
/// a folder in Program Files that nothing offers to take away.
void RegisterUninstallEntry(const std::wstring& destination) {
    HKEY key = nullptr;
    const LSTATUS opened = RegCreateKeyExW(HKEY_LOCAL_MACHINE, kUninstallKey, 0,
                                           nullptr, 0, KEY_WRITE, nullptr, &key,
                                           nullptr);
    if (opened != ERROR_SUCCESS) {
        // With the code: this is the difference between "no rights" and "the
        // hive would not take it", and the log is all anybody has to tell them
        // apart afterwards.
        InstallLog("could not register in Add/Remove Programs (error "
                   + std::to_string((int) opened) + ")");
        return;
    }
    const std::wstring exe = InstalledExe(destination);
    SetRegString(key, L"DisplayName", L"SolStream");
    SetRegString(key, L"DisplayVersion", kVersion);
    SetRegString(key, L"Publisher", L"SolStream");
    SetRegString(key, L"InstallLocation", destination);
    SetRegString(key, L"DisplayIcon", exe);
    SetRegString(key, L"UninstallString", L"\"" + exe + L"\" --uninstall");
    SetRegString(key, L"QuietUninstallString", L"\"" + exe + L"\" --uninstall --quiet");
    // Nothing to modify or repair: reinstalling is running setup again, which is
    // one file and takes ten seconds. Offering buttons that do nothing is worse
    // than not offering them.
    SetRegDword(key, L"NoModify", 1);
    SetRegDword(key, L"NoRepair", 1);
    SetRegDword(key, L"EstimatedSize", TreeSizeKb(destination));
    RegCloseKey(key);
    InstallLog("registered in Add/Remove Programs");
}

void RemoveUninstallEntry() {
    const LSTATUS status =
        RegDeleteKeyExW(HKEY_LOCAL_MACHINE, kUninstallKey, KEY_WOW64_64KEY, 0);
    // ERROR_FILE_NOT_FOUND means there was no entry, which is the answer we
    // wanted. Anything else leaves SolStream listed in Settings > Apps with
    // nothing behind it, and an Uninstall button that will never work again.
    if (status != ERROR_SUCCESS && status != ERROR_FILE_NOT_FOUND) {
        InstallLog("could not remove the Add/Remove Programs entry (error "
                   + std::to_string((int) status) + ")");
    }
}

/// Text safe to put between XML tags. The account comes from LookupAccountSidW
/// and the path from the environment, and an `&` in either -- legal in a
/// Windows user name -- made the whole definition malformed.
std::wstring XmlEscape(const std::wstring& text) {
    std::wstring out;
    out.reserve(text.size());
    for (const wchar_t c : text) {
        switch (c) {
            case L'&':  out += L"&amp;"; break;
            case L'<':  out += L"&lt;"; break;
            case L'>':  out += L"&gt;"; break;
            case L'"':  out += L"&quot;"; break;
            case L'\'': out += L"&apos;"; break;
            default:    out.push_back(c);
        }
    }
    return out;
}

}  // namespace

/// Who the logon task belongs to: whoever is sitting at this PC.
///
/// This was GetUserNameW, under a comment saying it picked the console user. It
/// did not, and the case where the two differ is the ordinary one on a managed
/// machine. UAC is allowed to elevate to a DIFFERENT account — that is what
/// happens whenever a standard user, who cannot elevate at all on their own, has
/// somebody type an administrator's name and password at the prompt for them —
/// and from inside the elevated half GetUserNameW then answers with that
/// administrator. So the task that starts SolStream at logon was registered
/// against the wrong person: it would start when the administrator logged on,
/// into a session with no Mac waiting for it, and never for the user who asked.
///
/// The unelevated half cannot get this wrong, because it IS the person at the
/// keyboard, so it puts its own SID on the command line it elevates with (see
/// OptionArguments) and RegisterLogonTask reads it back. A SID rather than a
/// name because a name is ambiguous without the domain it came from.
/// ConvertStringSidToSidW also refuses anything that is not a SID, which is
/// worth having when the result is pasted into XML.
///
/// Two spellings of that one account, best first. DOMAIN\name as Windows
/// itself names it, which is the form every install so far has registered
/// with; then the SID as it is, which Task Scheduler takes too and which needs
/// nobody to answer for the name -- the lookup can fail for a domain account
/// whose domain controller is out of reach. Whenever the lookup failed, or no
/// SID was passed, this used to paste the computer's name in front of what
/// GetUserNameW said, which for a domain or Entra ID account names an account
/// that does not exist, or a local one that happens to share the name.
std::vector<std::wstring> LogonTaskAccounts(const std::wstring& sid_text) {
    PSID sid = nullptr;
    if (sid_text.empty() || !ConvertStringSidToSidW(sid_text.c_str(), &sid)) {
        return {};
    }
    std::vector<std::wstring> accounts;
    wchar_t name[256] = {0};
    DWORD name_size = 256;
    wchar_t domain[256] = {0};
    DWORD domain_size = 256;
    SID_NAME_USE kind = SidTypeUnknown;
    if (LookupAccountSidW(nullptr, sid, name, &name_size, domain, &domain_size, &kind)
        && name[0] != L'\0') {
        accounts.push_back(domain[0] != L'\0' ? std::wstring(domain) + L"\\" + name
                                              : std::wstring(name));
    }
    // Written back out by Windows rather than passed through, so what goes into
    // the XML is a SID in Windows' own spelling and nothing else.
    wchar_t* text = nullptr;
    if (ConvertSidToStringSidW(sid, &text) && text != nullptr) {
        accounts.push_back(text);
        LocalFree(text);
    }
    LocalFree(sid);
    return accounts;
}

/// One rule, naming both the program and the ports it may use.
///
/// Naming the program is what stops Windows asking the user whether to allow it
/// — that prompt is raised per-executable, and on this project it once landed on
/// a display with no monitor and blocked every click for days. Naming the ports
/// as well is what keeps the rule honest: a program rule on its own opens every
/// port that executable ever binds, and an agent that later opens a socket for
/// something else should not inherit a hole it was never granted.
///
/// Every profile, the Domain one included. Without it a PC on its company's
/// network -- where Windows uses the Domain profile -- met its default Block,
/// and because a rule naming SolStream.exe existed, Windows did not ask either:
/// the Mac's knock and connection went unanswered with nothing on the PC saying
/// why. The program and the ports are what keep the rule narrow, not the
/// profile.
std::wstring FirewallRuleCommand(const std::wstring& name, const std::wstring& program,
                                 const std::wstring& protocol, const std::wstring& ports) {
    return L"netsh.exe advfirewall firewall add rule"
           L" name=\"" + name + L"\""
           L" dir=in action=allow"
           L" program=\"" + program + L"\""
           L" protocol=" + protocol +
           L" localport=" + ports +
           L" profile=any"
           L" description=\"SolStream remote application streaming\"";
}

/// Every firewall rule whose program is in `directory`, found and removed in
/// one pass.
///
/// The program filters are read once, all together, and only the rules behind
/// the few that match are looked up. This used to go the other way: every rule
/// on the PC -- several hundred on a stock Windows 11 -- then each one's
/// program filter, one query apiece, which was slow enough to run into
/// RunHidden's time limit and be stopped part-way.
///
/// Inside the folder, by a prefix that ends in a backslash: a bare prefix also
/// matched a neighbour such as "C:\Program Files\SolStreamOld", whose rules
/// are not ours. Compared without wildcards, as StopInstalled compares paths,
/// so nothing in a folder's name is read as a pattern.
std::wstring FirewallSweepCommand(const std::wstring& directory) {
    return L"powershell.exe -NoProfile -WindowStyle Hidden -Command \""
           L"$dir = '" + directory + L"\\'; "
           L"Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue | "
           L"Where-Object { $_.Program -and $_.Program.StartsWith($dir, "
           L"[System.StringComparison]::OrdinalIgnoreCase) } | "
           L"Get-NetFirewallRule -ErrorAction SilentlyContinue | "
           L"Remove-NetFirewallRule -ErrorAction SilentlyContinue\"";
}

std::wstring LogonTaskXml(const std::wstring& account, const std::wstring& destination,
                          bool at_logon) {
    const std::wstring user = XmlEscape(account);
    const std::wstring directory = XmlEscape(destination);
    return
        L"<?xml version=\"1.0\" encoding=\"UTF-16\"?>\r\n"
        L"<Task version=\"1.2\" xmlns=\"http://schemas.microsoft.com/windows/2004/02/mit/task\">\r\n"
        L"  <RegistrationInfo><Description>Starts SolStream so this PC can serve a Mac.</Description></RegistrationInfo>\r\n"
        // At THIS account's logon. A logon trigger naming nobody fires for
        // every account on the PC, so on a shared one each logon started the
        // host again in the background session of whoever installed it --
        // undoing their Quit, holding the port, and serving a desktop nobody
        // was at.
        + (at_logon
              ? L"  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>" + user
                    + L"</UserId></LogonTrigger></Triggers>\r\n"
              : std::wstring(L"  <Triggers />\r\n")) +
        L"  <Principals><Principal id=\"Author\">\r\n"
        // The account is declared here, beside InteractiveToken, so no password
        // is ever wanted for it.
        L"    <UserId>" + user + L"</UserId>\r\n"
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
        // Normal, as if it had been opened from the Start menu. Left out, a task
        // runs at Task Scheduler's default of 7, which is below normal: capture,
        // the encoder and the audio all lost the CPU to whatever else was busy
        // -- a game on the PC, say -- and every application the Mac opened
        // inherited the same class from the host that started it.
        L"    <Priority>4</Priority>\r\n"
        L"  </Settings>\r\n"
        L"  <Actions Context=\"Author\">\r\n"
        L"    <Exec>\r\n"
        L"      <Command>" + InstalledExe(directory) + L"</Command>\r\n"
        // --listen-all because an installed host that only answers on loopback is
        // one no Mac can reach. The socket still requires the pairing token off
        // loopback; the window shows that token. That is the lock, not the address.
        L"      <Arguments>--listen-all --background</Arguments>\r\n"
        L"      <WorkingDirectory>" + directory + L"</WorkingDirectory>\r\n"
        L"    </Exec>\r\n"
        L"  </Actions>\r\n"
        L"</Task>\r\n";
}

/// One account, spelled the ways LogonTaskAccounts gives, so a refusal of the
/// first spelling -- a domain account whose controller is out of reach -- is
/// not the end of it. The first one's failure is the one reported when none is
/// taken: it is the form that has always worked, so its failure is the one
/// worth reading.
int RegisterUnderAccounts(
    const std::vector<std::wstring>& accounts,
    const std::function<bool(const std::wstring& account, std::string& failure)>& attempt,
    std::string& error) {
    std::string first;
    for (size_t i = 0; i < accounts.size(); ++i) {
        std::string failure;
        if (attempt(accounts[i], failure)) {
            return static_cast<int>(i);
        }
        if (i == 0) {
            first = failure;
        }
    }
    error = first;
    return -1;
}

TaskAccountFrom ChooseLogonTaskAccounts(const std::function<std::wstring()>& passed,
                                        const std::function<std::wstring()>& session,
                                        const std::function<std::wstring()>& process,
                                        std::vector<std::wstring>& accounts) {
    accounts = LogonTaskAccounts(passed());
    if (!accounts.empty()) {
        return TaskAccountFrom::Passed;
    }
    accounts = LogonTaskAccounts(session());
    if (!accounts.empty()) {
        return TaskAccountFrom::Session;
    }
    accounts = LogonTaskAccounts(process());
    return accounts.empty() ? TaskAccountFrom::Nobody : TaskAccountFrom::Process;
}

namespace {

/// The Task Scheduler's class and interface ids, spelled out here rather than
/// taken from taskschd.lib, which the mingw cross-build does not link.
const CLSID kClsidTaskScheduler = {0x0f87369f, 0xa4e5, 0x4cfc,
                                   {0xbd, 0x3e, 0x73, 0xe6, 0x15, 0x45, 0x72, 0xdd}};
const IID kIidTaskService = {0x2faba4c7, 0x4da9, 0x4013,
                             {0x96, 0x97, 0x20, 0xcc, 0x3f, 0xd4, 0x0f, 0x85}};

/// Register the logon task from an XML definition, handed to the Task
/// Scheduler in memory.
///
/// XML rather than schtasks' own switches, because /tr splits the command on
/// spaces and "C:\Program Files\..." does not survive it. In memory rather than
/// through `schtasks /xml <file>`, because this runs elevated and the file used
/// to sit in %TEMP% -- writable by every unelevated process of the same user,
/// any of which could rewrite RunLevel or Command between the write and the
/// read and come away with an elevated task that runs at every logon.
bool RegisterTaskDefinition(const std::wstring& xml, std::string& error) {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ITaskService* service = nullptr;
    ITaskFolder* root = nullptr;
    IRegisteredTask* task = nullptr;
    VARIANT none;
    VariantInit(&none);
    BSTR root_path = SysAllocString(L"\\");
    BSTR name = SysAllocString(kTaskName);
    BSTR text = SysAllocStringLen(xml.data(), (UINT) xml.size());

    const char* step = "start the Task Scheduler";
    HRESULT hr = (root_path && name && text) ? S_OK : E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(kClsidTaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
                              kIidTaskService, (void**) &service);
    }
    if (SUCCEEDED(hr)) {
        step = "connect to the Task Scheduler";
        hr = service->Connect(none, none, none, none);
    }
    if (SUCCEEDED(hr)) {
        step = "open the Task Scheduler's root folder";
        hr = service->GetFolder(root_path, &root);
    }
    if (SUCCEEDED(hr)) {
        step = "register the logon task";
        hr = root->RegisterTask(name, text, TASK_CREATE_OR_UPDATE, none, none,
                                TASK_LOGON_INTERACTIVE_TOKEN, none, &task);
    }

    if (task) { task->Release(); }
    if (root) { root->Release(); }
    if (service) { service->Release(); }
    SysFreeString(text);
    SysFreeString(name);
    SysFreeString(root_path);
    if (SUCCEEDED(com)) {
        CoUninitialize();
    }
    if (FAILED(hr)) {
        char code[16];
        std::snprintf(code, sizeof(code), "0x%08lX", (unsigned long) hr);
        error = std::string("Could not ") + step + " (" + code + ").";
        return false;
    }
    return true;
}

/// Register the task that starts the installed host. With `at_logon` it runs at
/// every logon; without, it has no trigger at all and only runs when asked to --
/// which is still how an install or an update starts the new copy, so turning
/// "start when I log in" off no longer means an update leaves nothing running.
bool RegisterLogonTask(const std::wstring& destination, std::string& error,
                       bool at_logon = true) {
    // Whoever asked for the install, not whoever approved it: an administrator
    // setting this up for somebody else must not register a task that runs as
    // themselves. How the difference is worked out is in LogonTaskAccounts.
    //
    // With no SID passed -- SolStream.exe --install typed at an elevated
    // prompt, or a setup window started with "Run as administrator", where
    // there is no unelevated half to have asked -- the person is whoever is
    // signed in to this session. Not the account this runs as: elevated with
    // another administrator's name and password, that is the administrator,
    // and the task went to them, to start at a logon that was never going to
    // come. That account is left for when the session names nobody, as in
    // session 0 with nobody signed in, and its own token says exactly which
    // account it is.
    std::vector<std::wstring> accounts;
    const TaskAccountFrom from = ChooseLogonTaskAccounts(
        [] { return SwitchValue(kInvokingUserSwitch); }, SessionUserSid, CurrentUserSid,
        accounts);
    if (from == TaskAccountFrom::Nobody) {
        error = "Could not tell which account to start SolStream for.";
        return false;
    }
    // Each spelling in turn: see RegisterUnderAccounts.
    const int taken = RegisterUnderAccounts(
        accounts,
        [&destination, at_logon](const std::wstring& account, std::string& failure) {
            if (RegisterTaskDefinition(LogonTaskXml(account, destination, at_logon),
                                       failure)) {
                return true;
            }
            InstallLog("could not register the task for " + ToUtf8(account) + ": "
                       + failure);
            return false;
        },
        error);
    // Which account, and why that one, every time: a task that went to the
    // wrong person is a SolStream that never starts at their logon, and
    // nothing else on the PC says so.
    if (taken >= 0) {
        const char* why = from == TaskAccountFrom::Passed
            ? "the account that asked for the install"
            : from == TaskAccountFrom::Session
            ? "signed in to this session, as no account was passed"
            : "the account this install runs as, as no account was passed and nobody "
              "signed in to this session could be looked up";
        InstallLog("registered the task for " + ToUtf8(accounts[static_cast<size_t>(taken)])
                   + " (" + why + ")");
    }
    return taken >= 0;
}

/// The name of this run's result file, chosen by the process that is going to
/// read it. Empty when there is not one.
///
/// The file was called solstream-install-result.txt, always, in a directory every
/// account can write to — and it has to be writable by everybody, because the
/// unelevated half deletes the file after reading it. A name that is the same on
/// every machine and every run is a name anybody logged in can occupy before the
/// elevated half gets there, and what the setup window then reads back is a file
/// somebody else made, or a hard link aimed at a file the elevated half had no
/// intention of writing to. Locking the directory down does not fix that on its
/// own; taking the shared name away does.
///
/// The reader is always the process that raised the UAC prompt, so the name is
/// generated in RelaunchElevated and remembered in this variable. The elevated
/// half — and the temporary copy an uninstall steps out to, which is two
/// processes further on — find it on their own command line instead.
std::wstring g_result_token;

std::wstring ResultToken() {
    if (!g_result_token.empty()) {
        return g_result_token;
    }
    const std::wstring passed = SwitchValue(kResultTokenSwitch);
    // Only what this program puts there: thirty-two hex characters. This string
    // becomes part of a path, and anything else on that switch arrived from
    // somewhere with no business naming a file in ProgramData.
    if (passed.size() != 32
        || passed.find_first_not_of(L"0123456789abcdef") != std::wstring::npos) {
        return {};
    }
    return passed;
}

std::wstring ResultPath() {
    // Shared, not per-account: see SharedDirectory. The whole point of this file
    // is that it is written by one process and read by another, and those two
    // are not always the same user.
    const std::wstring token = ResultToken();
    // No token means nobody is waiting for this: SolStream.exe --install or
    // --uninstall --quiet run from an elevated console, where the answer is the
    // process's own exit code and this file is only ever written. It still has to
    // be written somewhere, and one fixed name that overwrites itself is tidier
    // there than a new file per run that nothing ever deletes.
    return SharedDirectory() + L"solstream-install-result"
         + (token.empty() ? std::wstring() : L"-" + token) + L".txt";
}

/// A new per-run name, and the leftovers of any run that never had its answer
/// read swept up on the way past.
///
/// The fixed name overwrote itself; per-run names do not, and the one path that
/// asks for an install and then exits without reading the result — SolStream.exe
/// --install typed at an unelevated prompt — would otherwise leave one small file
/// in ProgramData every time. Swept by the unelevated half as it starts a run,
/// which is the account the DACL grants delete rights to.
std::wstring NewResultToken() {
    const std::wstring shared = SharedDirectory();
    WIN32_FIND_DATAW found{};
    HANDLE search =
        FindFirstFileW((shared + L"solstream-install-result-*.txt").c_str(), &found);
    if (search != INVALID_HANDLE_VALUE) {
        do {
            if ((found.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0) {
                DeleteFileW((shared + found.cFileName).c_str());
            }
        } while (FindNextFileW(search, &found));
        FindClose(search);
    }

    unsigned char bytes[16] = {0};
    if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, bytes, sizeof(bytes),
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
        // Nothing unguessable to be had, so the fixed name it is — see
        // ResultPath. Better a predictable postbox than no postbox and a setup
        // window told the install never ran.
        return {};
    }
    static const wchar_t* hex = L"0123456789abcdef";
    std::wstring out;
    out.reserve(sizeof(bytes) * 2);
    for (unsigned char byte : bytes) {
        out.push_back(hex[byte >> 4]);
        out.push_back(hex[byte & 0x0F]);
    }
    return out;
}

}  // namespace

std::wstring InstallLogPath() {
    return SharedDirectory() + L"solstream-install.log";
}

std::wstring OptionArguments(const InstallOptions& options) {
    // Named for what they turn OFF, so the arguments a person might type by hand
    // do the expected thing when they are absent.
    std::wstring out;
    if (!options.desktop_shortcut) { out += L" --no-desktop-shortcut"; }
    if (!options.start_menu_shortcut) { out += L" --no-start-menu"; }
    if (!options.start_at_logon) { out += L" --no-logon"; }
    // The exception: this one is named for what it turns ON, because absent has
    // to mean "download nothing" for anybody typing --install by hand.
    if (options.display_driver) { out += L" --with-display-driver"; }
    // Who is asking. This is only ever built on the way to the UAC prompt, by
    // the half that has not been elevated, so the account this process runs as
    // is the person at the keyboard — which is exactly what the elevated half
    // can no longer work out for itself once somebody else's administrator
    // credentials have been typed at that prompt. See LogonTaskAccounts.
    const std::wstring sid = CurrentUserSid();
    if (!sid.empty()) {
        out += L" " + std::wstring(kInvokingUserSwitch) + L" " + sid;
    }
    return out;
}

InstallOptions OptionsFromArguments(int argc, wchar_t** argv) {
    InstallOptions options;
    for (int i = 1; i < argc; ++i) {
        const std::wstring arg = argv[i];
        if (arg == L"--no-desktop-shortcut") { options.desktop_shortcut = false; }
        else if (arg == L"--no-start-menu") { options.start_menu_shortcut = false; }
        else if (arg == L"--no-logon") { options.start_at_logon = false; }
        else if (arg == L"--with-display-driver") { options.display_driver = true; }
    }
    return options;
}

/// Between the install's answer and the display's, on a line of its own. Not
/// a character either answer can contain: both are sentences.
constexpr char kDisplaySeparator[] = "\n--display--\n";

void WriteInstallResult(bool ok, const std::string& error, const std::string& display) {
    const std::wstring path = ResultPath();
    // Delete first, then CREATE_NEW rather than CREATE_ALWAYS: what is written
    // here has to land in a file this process made, not in whatever happens to
    // be sitting at that path. CREATE_ALWAYS would happily truncate and write
    // through somebody else's file — or through a hard link they had aimed
    // somewhere else — and this process is the elevated one. With a per-run name
    // there should be nothing there at all; this is what makes that true rather
    // than likely.
    DeleteFileW(path.c_str());
    HANDLE file = CreateFileW(path.c_str(), GENERIC_WRITE, 0, nullptr, CREATE_NEW,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        const DWORD code = GetLastError();
        // The window on the other side of this file is about to say "The install
        // did not run", which will be untrue. Nothing here can stop that, but the
        // log can at least say the install did run and the postbox was locked.
        InstallLog("could not write " + ToUtf8(path) + " (error "
                   + std::to_string((int) code)
                   + "), so the waiting window will report no result");
        return;
    }
    // "OK" alone is a clean install. "OK " with something after it is an install
    // that stands, with a warning attached -- a firewall rule netsh refused, or a
    // logon task that would not register. Failures keep the ERR form.
    std::string text = ok ? (error.empty() ? "OK" : "OK " + error)
                          : ("ERR " + error);
    if (!display.empty()) {
        text += kDisplaySeparator + display;
    }
    DWORD written = 0;
    WriteFile(file, text.data(), (DWORD) text.size(), &written, nullptr);
    CloseHandle(file);
}

bool ReadInstallResult(std::string& error, std::string* display) {
    const std::wstring path = ResultPath();
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        // No file at all means the elevated half never got far enough to write
        // one — most often because the UAC prompt was dismissed.
        error = "The install did not run.";
        return false;
    }
    char buffer[8192] = {0};
    DWORD read = 0;
    ReadFile(file, buffer, sizeof(buffer) - 1, &read, nullptr);
    CloseHandle(file);
    DeleteFileW(path.c_str());
    std::string text(buffer, read);
    const size_t split = text.find(kDisplaySeparator);
    if (split != std::string::npos) {
        if (display) {
            *display = text.substr(split + sizeof(kDisplaySeparator) - 1);
        }
        text.resize(split);
    }
    if (text.rfind("OK", 0) == 0) {
        // Anything after the OK is a warning from an install that otherwise
        // worked, so it comes back in `error` with a true return. Callers that
        // only look at the return value are unaffected: on a clean install this
        // is empty.
        error = text.size() > 3 ? text.substr(3) : std::string();
        return true;
    }
    error = text.size() > 4 ? text.substr(4) : "The install failed.";
    return false;
}

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

bool RelaunchElevated(const std::wstring& arguments, std::string& error, bool may_prompt) {
    const std::wstring exe = ExePath();
    // The name of the postbox is settled here, in the process that is going to
    // read it, rather than agreed in advance by both halves — see ResultToken.
    // Here because this is the one place every elevated relaunch passes through,
    // installs and uninstalls alike, and the callers pass their arguments in as
    // fixed strings that have no room for it.
    std::wstring parameters = arguments;
    g_result_token = NewResultToken();
    if (!g_result_token.empty()) {
        parameters += L" " + std::wstring(kResultTokenSwitch) + L" " + g_result_token;
    }
    SHELLEXECUTEINFOW execute{};
    execute.cbSize = sizeof(execute);
    execute.fMask = SEE_MASK_NOCLOSEPROCESS;
    execute.lpVerb = L"runas";
    execute.lpFile = exe.c_str();
    execute.lpParameters = parameters.c_str();
    // Hidden, because the elevated half has no window worth showing -- except
    // when it may raise a prompt of Windows' own. The show state a process is
    // started with is applied to the first window it shows, and installing the
    // display driver can make that Windows' "install this device software?"
    // question: started hidden, the one thing the install is waiting on could
    // come up hidden too, with the setup screen waiting on it for ever. Shown,
    // a Windows older than 24H2 flashes the console this program then
    // releases; a lost prompt is the worse of the two.
    execute.nShow = may_prompt ? SW_SHOWNORMAL : SW_HIDE;
    if (!ShellExecuteExW(&execute)) {
        // Not "to install": this is the same call the uninstaller makes, and it
        // told somebody removing SolStream that it needed rights to install.
        // Neither half of the sentence has to name the operation -- the window
        // that raised the prompt is already saying which one it is.
        error = GetLastError() == ERROR_CANCELLED
                    ? "Windows' permission prompt was dismissed, so nothing was "
                      "changed."
                    : "Could not restart SolStream with administrator rights.";
        // An uninstall started from Add/Remove Programs has no console and, with
        // --quiet, no window either, so this is the only place the reason exists.
        InstallLog("could not elevate: " + error);
        return false;
    }
    if (execute.hProcess) {
        // And allowed to come to the front: the prompt belongs to a process
        // that has no foreground of its own to give it, while this one -- the
        // window the person is looking at -- does.
        AllowSetForegroundWindow(GetProcessId(execute.hProcess));
        WaitForSingleObject(execute.hProcess, INFINITE);
        CloseHandle(execute.hProcess);
    }
    return true;
}

bool RelaunchFromTemp(const std::wstring& arguments, std::string& error) {
    InstallLog("stepping out to a temporary copy to uninstall from");
    const std::wstring copy = TempDirectory() + L"SolStreamUninstall.exe";
    // Best effort: a copy left behind by an earlier attempt is still running or
    // still locked often enough that overwriting has to be allowed to fail
    // without taking the uninstall with it.
    DeleteFileW(copy.c_str());
    if (!CopyFileW(ExePath().c_str(), copy.c_str(), FALSE)) {
        const DWORD code = GetLastError();
        error = "Could not make a temporary copy to uninstall from.";
        // The line above says the uninstall stepped out. Without this one the log
        // stops there and says nothing about why it never came back.
        InstallLog(error + " (error " + std::to_string((int) code) + ")");
        return false;
    }
    // The temporary copy is the process that actually does the uninstall, so it
    // is the one that writes the result — and the window waiting for that result
    // is two processes back, looking for a name it chose. Carry the name across.
    // Without it the copy writes to the fixed name, the window finds nothing
    // where it is looking, and a completed uninstall is reported as one that
    // never ran.
    std::wstring parameters = arguments;
    const std::wstring token = ResultToken();
    if (!token.empty()) {
        parameters += L" " + std::wstring(kResultTokenSwitch) + L" " + token;
    }
    SHELLEXECUTEINFOW execute{};
    execute.cbSize = sizeof(execute);
    execute.fMask = SEE_MASK_NOCLOSEPROCESS;
    execute.lpVerb = L"open";
    execute.lpFile = copy.c_str();
    execute.lpParameters = parameters.c_str();
    execute.nShow = SW_SHOWNORMAL;
    if (!ShellExecuteExW(&execute)) {
        error = "Could not start the uninstaller.";
        InstallLog(error);
        return false;
    }
    if (execute.hProcess) {
        CloseHandle(execute.hProcess);
    }
    InstallLog("temporary copy started");
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

std::wstring InstalledExe(const std::wstring& directory) {
    return directory + L"\\SolStream.exe";
}

InstallOptions InstalledOptions() {
    // Where Windows will not name a folder the answer is "keep it": guessing
    // wrong that way costs a shortcut, and the other way it costs the
    // installer deleting one.
    auto present = [](const std::wstring& link) {
        return link.empty() || GetFileAttributesW(link.c_str()) != INVALID_FILE_ATTRIBUTES;
    };
    InstallOptions options;
    options.desktop_shortcut = present(DesktopShortcutPath());
    options.start_menu_shortcut = present(StartMenuShortcutPath());
    // As the person left it: an update used to turn "start when I log in"
    // back on every time.
    options.start_at_logon = StartsAtLogon();
    return options;
}

bool RunningInstalled() {
    std::wstring here = DirectoryOf(ExePath());
    std::wstring there = InstallDirectory();
    return FoldCase(here) == FoldCase(there);
}

/// Whether the installed task starts SolStream at logon. True when it cannot
/// tell -- no task, no access to read it -- because that is the setup screen's
/// default, and an update guessing "off" would turn a person's logon start off.
bool StartsAtLogon() {
    const HRESULT com = CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);
    ITaskService* service = nullptr;
    ITaskFolder* root = nullptr;
    IRegisteredTask* task = nullptr;
    ITaskDefinition* definition = nullptr;
    ITriggerCollection* triggers = nullptr;
    VARIANT none;
    VariantInit(&none);
    BSTR root_path = SysAllocString(L"\\");
    BSTR name = SysAllocString(kTaskName);
    LONG count = -1;
    HRESULT hr = (root_path && name) ? S_OK : E_OUTOFMEMORY;
    if (SUCCEEDED(hr)) {
        hr = CoCreateInstance(kClsidTaskScheduler, nullptr, CLSCTX_INPROC_SERVER,
                              kIidTaskService, (void**) &service);
    }
    if (SUCCEEDED(hr)) { hr = service->Connect(none, none, none, none); }
    if (SUCCEEDED(hr)) { hr = service->GetFolder(root_path, &root); }
    if (SUCCEEDED(hr)) { hr = root->GetTask(name, &task); }
    if (SUCCEEDED(hr)) { hr = task->get_Definition(&definition); }
    if (SUCCEEDED(hr)) { hr = definition->get_Triggers(&triggers); }
    if (SUCCEEDED(hr)) { hr = triggers->get_Count(&count); }
    if (triggers) { triggers->Release(); }
    if (definition) { definition->Release(); }
    if (task) { task->Release(); }
    if (root) { root->Release(); }
    if (service) { service->Release(); }
    SysFreeString(name);
    SysFreeString(root_path);
    if (SUCCEEDED(com)) { CoUninitialize(); }
    return FAILED(hr) || count != 0;
}

HostTaskResult RegisterAndRunHostTask(
    const std::function<bool(std::string& error)>& register_task,
    const std::function<unsigned long()>& run_task) {
    HostTaskResult result;
    result.registered = register_task(result.register_error);
    // Run whether or not that registration went through. On an update the task
    // an earlier install registered is still there and names this same path, so
    // it starts the copy just put in place; skipping it, as a failed
    // registration used to, left the PC with no SolStream at all -- the old one
    // already stopped -- until the next logon.
    result.started = run_task();
    return result;
}

bool InstallSelf(const InstallOptions& options, std::string& error) {
    InstallLog("install requested");
    if (!IsElevated()) {
        error = "Installing needs administrator rights.";
        // The caller shows this, but the log is what somebody reads afterwards
        // and "install requested" followed by nothing at all is the dead end
        // this file exists to avoid.
        InstallLog("refused: " + error);
        return false;
    }
    const std::wstring source = DirectoryOf(ExePath());
    const std::wstring destination = InstallDirectory();
    if (RunningInstalled()) {
        error = "SolStream is already installed here.";
        InstallLog("refused: " + error);
        return false;
    }
    // ONE FILE. There used to be two shapes to handle: a downloaded executable
    // carrying 65 MB of Sunshine inside it as a resource, and a development
    // tree with a sunshine\ folder beside it -- and an error message for the
    // case where neither was true, because without Sunshine there was nothing
    // to stream with. SolStream streams with itself now.
    InstallLog("installing from " + ToUtf8(source) + " to " + ToUtf8(destination));
    StopInstalled(destination);

    if (!CreateDirectoryW(destination.c_str(), nullptr)
        && GetLastError() != ERROR_ALREADY_EXISTS) {
        error = "Could not create " + ToUtf8(destination);
        InstallLog("copy failed: " + error);
        return false;
    }
    // The executable, not its directory. Copying the DIRECTORY -- which this
    // once did -- puts everything else in the user's Downloads folder into
    // Program Files with it.
    //
    // Beside the old one first, then swapped in with one rename. Copying
    // straight over SolStream.exe left nothing runnable when the copy failed
    // part-way -- the file still locked by a host slow to exit, an antivirus
    // scan, a full disk -- and on a self-update the host had already been
    // stopped, so the PC had no SolStream until somebody logged in again.
    // Now a failure leaves the old copy whole and starts it again.
    const std::wstring installed = InstalledExe(destination);
    const std::wstring incoming = installed + L".new";
    bool replaced = false;
    DWORD failure = 0;
    if (CopyFileW(ExePath().c_str(), incoming.c_str(), FALSE)) {
        for (int attempt = 0; attempt < 10 && !replaced; ++attempt) {
            if (attempt > 0) { Sleep(500); }
            replaced = MoveFileExW(incoming.c_str(), installed.c_str(),
                                   MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH) != FALSE;
            if (!replaced) { failure = GetLastError(); }
        }
    } else {
        failure = GetLastError();
    }
    if (!replaced) {
        DeleteFileW(incoming.c_str());
        error = "Could not copy SolStream into " + ToUtf8(destination)
              + " (error " + std::to_string(failure) + ")";
        InstallLog("copy failed: " + error);
        if (GetFileAttributesW(installed.c_str()) != INVALID_FILE_ATTRIBUTES) {
            // The old copy is intact: bring it back rather than leave the PC
            // with no host. A first install has no old copy and no task.
            const DWORD restarted =
                RunHidden(L"schtasks.exe /run /tn \"" + std::wstring(kTaskName) + L"\"");
            InstallLog(restarted == 0 ? "restarted the copy that was already installed"
                                      : "could not restart the installed copy "
                                            + RunOutcome(restarted));
        }
        return false;
    }
    InstallLog("copied");

    // What went wrong without going wrong enough to undo the install. An install
    // that is missing a firewall rule or a logon task is one somebody can finish
    // by hand or by running setup again; a half-copied Program Files is not, so
    // only the steps above this line return false. Anything collected here comes
    // back through `error` with a true return, which is how it reaches the setup
    // window: the elevated half has no other way to say "it worked, but".
    //
    // One clause per thing that did not happen, with no preamble on any of them:
    // several can fire at once, and the sentence they go into is written below.
    std::string warning;

    // Two rules, both for one executable. There used to be six, covering three
    // TCP and three UDP Sunshine ports derived from a base -- and a directory
    // that had to be created by hand because Sunshine exited 0 before its
    // logging was up if it could not write there.
    const std::wstring exe = InstalledExe(destination);
    // Both answers, and both looked at. These two calls used to have their
    // results thrown away and "firewall rules written" logged either way, so a
    // netsh that refused produced an install nothing could connect to and not
    // one word anywhere saying why -- not in the window, not in the log.
    const bool agent_rule =
        AddRule(L"SolStream - agent", exe, L"TCP", std::to_wstring(kDefaultPort));
    const bool media_rule =
        AddRule(L"SolStream - media", exe, L"UDP",
                std::to_wstring(kDefaultMediaPort) + L","
                + std::to_wstring(kDiscoveryPort));
    if (agent_rule && media_rule) {
        InstallLog("firewall rules written");
    } else {
        const std::string which =
            agent_rule ? "the rule for its media and discovery ports"
                       : (media_rule ? "the rule for its agent port"
                                     : "either of its rules");
        InstallLog("firewall: netsh would not add " + which);
        warning = "Windows Firewall would not accept " + which
                + ", so your Mac may not be able to reach this PC.";
    }

    WriteShortcuts(destination, options);
    RegisterUninstallEntry(destination);

    auto also = [&warning](const std::string& clause) {
        if (!warning.empty()) {
            warning += " ";
        }
        warning += clause;
    };

    // Asked not to start at logon, the task is still registered, with no
    // trigger, because it is what starts the copy just installed -- an update
    // must not end with nothing running -- and the tick on the setup screen
    // stays true: nothing starts at the next logon.
    //
    // A failure here used to return false out of an install that had already
    // copied the executable, opened the ports, written the shortcuts and
    // registered itself in Add/Remove Programs -- so the user was told the
    // install had failed when the only missing piece was the part that starts
    // SolStream for them, which they can do from the shortcut. It is a warning
    // for the same reason the firewall one is: what is left is a working
    // install, and saying otherwise invites somebody to "fix" it by installing
    // again over the top.
    const HostTaskResult task = RegisterAndRunHostTask(
        [&destination, &options](std::string& task_error) {
            const bool registered =
                RegisterLogonTask(destination, task_error, options.start_at_logon);
            if (registered) {
                InstallLog(options.start_at_logon ? "logon task registered"
                                                  : "on-demand task registered (not at logon)");
            } else {
                // Task Scheduler's own words, with its code in them, go to the
                // log. The window gets the consequence, below, which is the
                // part the person reading it can do anything about.
                InstallLog("task failed: " + task_error);
            }
            return registered;
        },
        [] { return RunHidden(L"schtasks.exe /run /tn \"" + std::wstring(kTaskName) + L"\""); });
    if (!task.registered && options.start_at_logon) {
        also("Windows would not register its logon task, so it will not start by"
             " itself when you log in.");
    }
    if (task.started == 0) {
        InstallLog(task.registered
                       ? "started"
                       : "started through the task an earlier install registered");
    } else {
        // A warning, not just a line: without one, setup's summary says
        // "SolStream is running" over a PC where nothing is.
        InstallLog("could not start it now: schtasks " + RunOutcome(task.started));
        // Named when it follows another clause, which has a subject of its own.
        also(warning.empty() ? "Windows would not start it just now."
                             : "Windows would not start SolStream just now either.");
    }
    if (!warning.empty()) {
        // The install did happen, and that has to be the first thing said --
        // once, at the front, so a message carrying several clauses does not say
        // it twice and does not read like a failure.
        warning = "SolStream is installed, but " + warning
                + " You can still open it from the Start menu, and running setup"
                  " again usually puts this right.";
    }
    // Empty unless something above filled it. `error` on a true return is a
    // warning, never a failure.
    error = warning;
    return true;
}

bool UninstallSelf(std::string& error, std::string& left) {
    left.clear();
    InstallLog("uninstall requested");
    if (!IsElevated()) {
        error = "Removing SolStream needs administrator rights.";
        InstallLog("refused: " + error);
        return false;
    }
    const std::wstring destination = InstallDirectory();
    // Stopped before the task is ended, and asked first, as an update stops
    // it: Task Scheduler ending the host is not the host quitting, and only
    // quitting takes its icon away and gives the streamed windows back. Once
    // it has, /end has nothing left to end.
    StopInstalled(destination);
    InstallLog("stopped what was running from the install directory");
    RunHidden(L"schtasks.exe /end /tn \"" + std::wstring(kTaskName) + L"\"");
    RunHidden(L"schtasks.exe /delete /tn \"" + std::wstring(kTaskName) + L"\" /f");
    // /delete answers non-zero both for "there was no such task", which is the
    // answer this wanted, and for "it is there and it would not go", which is a
    // Windows that goes on trying to start a deleted SolStream.exe at every
    // logon. Asking whether the task is still there is what tells the two apart,
    // and this line used to claim the removal either way.
    const DWORD queried =
        RunHidden(L"schtasks.exe /query /tn \"" + std::wstring(kTaskName) + L"\"");
    if (queried == 0) {
        InstallLog("the logon task is still registered — remove \"SolStream Host\""
                   " in Task Scheduler");
    } else if (queried == kRunTimedOut || queried == kRunFailed) {
        // A query that never answered is not a "no". Non-zero happens to be what
        // both look like, which is how "logon task removed" would be claimed on
        // the strength of nothing having come back at all.
        InstallLog("could not tell whether the logon task is still registered "
                   "(schtasks " + RunOutcome(queried) + ") — check \"SolStream "
                   "Host\" in Task Scheduler");
    } else {
        InstallLog("logon task removed");
    }
    // The virtual display, and only if SolStream put it here: one somebody
    // installed for themselves is theirs. After the host has quit, so nothing
    // of SolStream's is holding it -- something that is makes Windows put the
    // removal off to the restart. And here, not beside the calls, so every
    // way into an uninstall does it: the window's own, already elevated,
    // called only this and left the display on the PC.
    std::string driver_note;
    const bool display_gone = RemoveInstalledDriver(driver_note);
    for (size_t start = 0; start < driver_note.size();) {
        size_t end = driver_note.find('\n', start);
        if (end == std::string::npos) {
            end = driver_note.size();
        }
        if (end > start) {
            InstallLog(driver_note.substr(start, end - start));
        }
        start = end + 1;
    }
    // The window promised to remove the display, so what stays is said there
    // too, not only here.
    if (!display_gone) {
        left = driver_note;
        while (!left.empty() && left.back() == '\n') {
            left.pop_back();
        }
    }
    // By program first, which catches every rule whatever it is called --
    // including the ones Windows writes itself when someone clicks Allow.
    DeleteRulesForProgram(destination);
    // Then by name, for the Sunshine-era rules that point at an executable this
    // build no longer installs and so cannot be found by path.
    DeleteRule(L"SolStream - agent");
    DeleteRule(L"SolStream - media");
    DeleteRule(L"SolStream - Stream Media");
    DeleteRule(L"SolStream - Agent (program)");
    DeleteRule(L"SolStream - Sunshine TCP");
    DeleteRule(L"SolStream - Sunshine UDP");
    DeleteRule(L"SolStream - Sunshine HTTP");
    DeleteRule(L"SolStream - Sunshine HTTPS");
    DeleteRule(L"SolStream - Sunshine RTSP");
    DeleteRule(L"SolStream - Sunshine Web UI");
    DeleteRule(L"SolStream (SolStream.exe, TCP)");
    DeleteRule(L"SolStream (SolStream.exe, UDP)");
    DeleteRule(L"SolStream (sunshine.exe, TCP)");
    DeleteRule(L"SolStream (sunshine.exe, UDP)");
    // Asked for, not necessarily done: netsh answers non-zero for a rule that was
    // never there, so the names above cannot tell "gone" from "was never here"
    // and this line must not claim more than it knows. The sweep by program path
    // is the one that matters, and it says so itself when it fails.
    InstallLog("asked Windows Firewall to remove every rule this install writes");
    RemoveShortcuts();
    RemoveUninstallEntry();
    InstallLog("shortcuts and the Add/Remove Programs entry removed");
    RemoveTree(destination);
    if (GetFileAttributesW(destination.c_str()) != INVALID_FILE_ATTRIBUTES) {
        error = "Removed what it could, but " + ToUtf8(destination)
              + " is still there — something in it was in use.";
        InstallLog("uninstall incomplete: " + error);
        return false;
    }
    InstallLog("uninstalled");
    return true;
}

}  // namespace solstream
