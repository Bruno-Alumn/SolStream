#include "sunshine_host.h"

#include <winsock2.h>
#include <ws2tcpip.h>
#include <windows.h>
#include <bcrypt.h>
#include <shlwapi.h>

#include <cstdio>
#include <fstream>
#include <mutex>
#include <string>

#include "ports.h"

namespace solstream {

bool StartSunshine(unsigned short base_port, const std::wstring& output_name);

namespace {

std::mutex g_mutex;
HANDLE g_process = nullptr;
HANDLE g_job = nullptr;
SunshineState g_state = SunshineState::kStopped;
std::string g_status = "not started";
std::string g_user;
std::string g_password;
/// Set when StartSunshine stopped only to come back with the right display.
bool g_restart_for_device_id = false;
/// Whether Sunshine is MEANT to be running. Separate from whether it is,
/// deliberately: the watchdog's first version keyed off the observed state and
/// so raced the status poll, which calls GetSunshineState once a second and
/// reaps the dead process itself. Whoever noticed first won — the poll set the
/// state to kFailed, the watchdog then saw "not running" instead of "was
/// running and stopped", and did nothing. It restarted correctly exactly once,
/// by luck, and looked fixed.
bool g_wanted = false;
/// What StartSunshine was last asked for, so the watchdog can ask again.
unsigned short g_base_port = 0;
std::wstring g_output_name;
HANDLE g_watchdog_thread = nullptr;
volatile LONG g_watchdog_stop = 0;
int g_restarts = 0;
ULONGLONG g_last_restart_tick = 0;

/// How many times to bring Sunshine back before concluding that it is not
/// coming back. Five in a row is a broken machine, not a hiccup, and restarting
/// forever would hide that behind a stream that never quite works.
constexpr int kMaxRestarts = 5;
/// A quiet spell this long means whatever went wrong was a one-off, so the
/// count starts again. Without this a machine that loses Sunshine once a week
/// would eventually stop trying.
constexpr ULONGLONG kHealthyMillis = 10 * 60 * 1000;

void SetStatus(SunshineState state, const std::string& text) {
    g_state = state;
    g_status = text;
}

std::wstring ExecutableDir() {
    wchar_t path[MAX_PATH] = {};
    if (!GetModuleFileNameW(nullptr, path, MAX_PATH)) {
        return {};
    }
    std::wstring full(path);
    const size_t slash = full.find_last_of(L'\\');
    return slash == std::wstring::npos ? std::wstring{} : full.substr(0, slash);
}

bool FileExists(const std::wstring& path) {
    const DWORD attributes = GetFileAttributesW(path.c_str());
    return attributes != INVALID_FILE_ATTRIBUTES
        && !(attributes & FILE_ATTRIBUTE_DIRECTORY);
}

/// Hex from the system CSPRNG. Used for the web UI password, which is never
/// shown to anyone: it exists so Sunshine's own API will talk to us, and a
/// value the user might be tempted to reuse would be worse than one they never
/// see.
std::string RandomHex(size_t bytes) {
    std::string out;
    unsigned char buffer[64] = {};
    if (bytes > sizeof(buffer)) {
        bytes = sizeof(buffer);
    }
    if (!BCRYPT_SUCCESS(BCryptGenRandom(nullptr, buffer, (ULONG) bytes,
                                        BCRYPT_USE_SYSTEM_PREFERRED_RNG))) {
        return {};
    }
    static const char* kHex = "0123456789abcdef";
    for (size_t i = 0; i < bytes; ++i) {
        out.push_back(kHex[buffer[i] >> 4]);
        out.push_back(kHex[buffer[i] & 0x0F]);
    }
    return out;
}

std::string Narrow(const std::wstring& text) {
    if (text.empty()) {
        return {};
    }
    const int size = WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(),
                                         nullptr, 0, nullptr, nullptr);
    std::string out(static_cast<size_t>(size), '\0');
    WideCharToMultiByte(CP_UTF8, 0, text.data(), (int) text.size(),
                        out.data(), size, nullptr, nullptr);
    return out;
}

/// Is something already answering on this Sunshine's HTTP port?
///
/// Worth asking before spawning one. A Sunshine installed as a Windows service
/// is started by its own service wrapper, and that copy will not run as an
/// ordinary process — so on a machine that already has one configured for these
/// ports, adopting it is both correct and the only thing that works.
bool SomethingListensOn(unsigned short port) {
    WSADATA wsa{};
    static bool started = false;
    if (!started) {
        WSAStartup(MAKEWORD(2, 2), &wsa);
        started = true;
    }
    SOCKET probe = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
    if (probe == INVALID_SOCKET) {
        return false;
    }
    sockaddr_in address{};
    address.sin_family = AF_INET;
    address.sin_port = htons(port);
    address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    // Non-blocking would be tidier; a loopback connect either succeeds or is
    // refused immediately, so a blocking one costs nothing measurable.
    const bool answered = connect(probe, (sockaddr*) &address, sizeof(address)) == 0;
    closesocket(probe);
    return answered;
}

/// Where the generated web credentials are kept between runs.
///
/// They have to survive a restart. Sunshine stores only a salted hash of its
/// password, so a SolStream that forgot the plaintext could never talk to its
/// own Sunshine again — and the symptom would not be an error, it would be
/// pairing quietly falling back to asking the user for a PIN it was supposed to
/// handle for them.
///
/// DPAPI, so the file is readable only by this Windows user account. It is a
/// password to a service listening on this machine; another account on the same
/// machine should not be able to lift it off disk.
std::wstring CredentialsPath(const std::wstring& config_dir) {
    return config_dir + L"\\web.cred";
}

bool SaveCredentials(const std::wstring& config_dir,
                     const std::string& user, const std::string& password) {
    std::string plain = user;
    plain.push_back('\n');
    plain += password;

    DATA_BLOB in{(DWORD) plain.size(), (BYTE*) plain.data()};
    DATA_BLOB out{};
    if (!CryptProtectData(&in, L"SolStream Sunshine web credentials", nullptr, nullptr,
                          nullptr, CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;
    }
    HANDLE file = CreateFileW(CredentialsPath(config_dir).c_str(), GENERIC_WRITE, 0,
                              nullptr, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    bool ok = false;
    if (file != INVALID_HANDLE_VALUE) {
        DWORD written = 0;
        ok = WriteFile(file, out.pbData, out.cbData, &written, nullptr)
             && written == out.cbData;
        CloseHandle(file);
    }
    LocalFree(out.pbData);
    return ok;
}

bool LoadCredentials(const std::wstring& config_dir,
                     std::string& user, std::string& password) {
    HANDLE file = CreateFileW(CredentialsPath(config_dir).c_str(), GENERIC_READ,
                              FILE_SHARE_READ, nullptr, OPEN_EXISTING,
                              FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    std::string encrypted;
    char chunk[1024];
    DWORD read = 0;
    while (ReadFile(file, chunk, sizeof(chunk), &read, nullptr) && read > 0) {
        encrypted.append(chunk, read);
    }
    CloseHandle(file);
    if (encrypted.empty()) {
        return false;
    }

    DATA_BLOB in{(DWORD) encrypted.size(), (BYTE*) encrypted.data()};
    DATA_BLOB out{};
    if (!CryptUnprotectData(&in, nullptr, nullptr, nullptr, nullptr,
                            CRYPTPROTECT_UI_FORBIDDEN, &out)) {
        return false;
    }
    const std::string plain((const char*) out.pbData, out.cbData);
    SecureZeroMemory(out.pbData, out.cbData);
    LocalFree(out.pbData);

    const size_t split = plain.find('\n');
    if (split == std::string::npos) {
        return false;
    }
    user = plain.substr(0, split);
    password = plain.substr(split + 1);
    return !user.empty() && !password.empty();
}

/// Read a whole file, or an empty string.
std::string ReadWholeFile(const std::wstring& path) {
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ,
                              FILE_SHARE_READ | FILE_SHARE_WRITE, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return {};
    }
    std::string out;
    char chunk[16384];
    DWORD read = 0;
    while (ReadFile(file, chunk, sizeof(chunk), &read, nullptr) && read > 0) {
        out.append(chunk, read);
    }
    CloseHandle(file);
    return out;
}

/// Undo JSON's backslash doubling, so "\\\\.\\DISPLAY5" reads as \\.\DISPLAY5.
std::string JsonUnescape(const std::string& text) {
    std::string out;
    for (size_t i = 0; i < text.size(); ++i) {
        if (text[i] == '\\' && i + 1 < text.size()) {
            ++i;
        }
        out.push_back(text[i]);
    }
    return out;
}

std::string ValueAfter(const std::string& text, size_t from, const char* key) {
    const size_t at = text.find(key, from);
    if (at == std::string::npos) {
        return {};
    }
    const size_t open = text.find('"', at + strlen(key));
    if (open == std::string::npos) {
        return {};
    }
    size_t close = open + 1;
    while (close < text.size() && !(text[close] == '"' && text[close - 1] != '\\')) {
        ++close;
    }
    return close < text.size() ? text.substr(open + 1, close - open - 1) : std::string{};
}

/// Sunshine's own id for a display, taken from its own log.
///
/// `output_name` is not the `\\.\DISPLAYn` name it looks like it should be.
/// Sunshine runs the setting through libdisplaydevice first (map_output_name ->
/// getDisplayName), which expects a device id — a GUID — and returns EMPTY for
/// anything else. Empty then means "no filter", so a GDI name does not select
/// the wrong display, it selects *no* display and Sunshine captures the first
/// output it finds: the primary monitor. That is the user's real desktop, which
/// is the one thing streaming a virtual display exists to avoid.
///
/// Sunshine logs the whole device table on every start ("Currently available
/// display devices"), ids included, so this reads the answer from the program
/// that has to agree with it rather than trying to recompute a UUIDv5 whose
/// inputs are not documented.
std::string DeviceIdForDisplay(const std::wstring& config_dir,
                               const std::string& display_name) {
    const std::string log = ReadWholeFile(config_dir + L"\\sunshine.log");
    if (log.empty() || display_name.empty()) {
        return {};
    }
    // The last enumeration, not the first: the log survives restarts.
    const size_t table = log.rfind("Currently available display devices");
    if (table == std::string::npos) {
        return {};
    }

    size_t at = table;
    for (;;) {
        const size_t entry = log.find("\"device_id\"", at);
        if (entry == std::string::npos) {
            return {};
        }
        const std::string id = ValueAfter(log, entry, "\"device_id\"");
        const std::string name = JsonUnescape(ValueAfter(log, entry, "\"display_name\""));
        if (!id.empty() && name == display_name) {
            return id;
        }
        at = entry + 1;
    }
}

}  // namespace

std::wstring SunshineConfigDir() {
    wchar_t buffer[MAX_PATH] = {};
    if (!GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH)) {
        return {};
    }
    std::wstring dir = std::wstring(buffer) + L"\\SolStream";
    CreateDirectoryW(dir.c_str(), nullptr);
    dir += L"\\sunshine";
    CreateDirectoryW(dir.c_str(), nullptr);
    return dir;
}

SunshineLocation FindSunshine() {
    SunshineLocation found;

    // Beside our own executable — how a packaged SolStream ships.
    const std::wstring here = ExecutableDir();
    if (!here.empty()) {
        for (const wchar_t* relative : {L"\\sunshine\\sunshine.exe", L"\\sunshine.exe"}) {
            const std::wstring candidate = here + relative;
            if (FileExists(candidate)) {
                found.executable = candidate;
                found.bundled = true;
                return found;
            }
        }
    }

    // Otherwise fall back to an install the user already has. Not the preferred
    // answer — its version is whatever they happen to have — but far better
    // than refusing to run on a machine that plainly can stream.
    for (const wchar_t* absolute : {L"C:\\Program Files\\Sunshine\\sunshine.exe",
                                    L"C:\\Program Files (x86)\\Sunshine\\sunshine.exe"}) {
        if (FileExists(absolute)) {
            found.executable = absolute;
            found.bundled = false;
            return found;
        }
    }
    return found;
}

bool SupervisedCredentials(std::string& user, std::string& password) {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_user.empty() || g_password.empty()) {
        return false;
    }
    user = g_user;
    password = g_password;
    return true;
}

bool RestartedForDisplay() {
    std::lock_guard<std::mutex> lock(g_mutex);
    const bool value = g_restart_for_device_id;
    g_restart_for_device_id = false;
    return value;
}

SunshineState GetSunshineState() {
    std::lock_guard<std::mutex> lock(g_mutex);
    // A process that exited on its own — a port already taken, a missing
    // encoder — must not keep reading as running.
    if (g_state == SunshineState::kRunning || g_state == SunshineState::kStarting) {
        if (g_process && WaitForSingleObject(g_process, 0) == WAIT_OBJECT_0) {
            DWORD code = 0;
            GetExitCodeProcess(g_process, &code);
            char buffer[96];
            std::snprintf(buffer, sizeof(buffer), "Sunshine exited (code %lu)", code);
            SetStatus(SunshineState::kFailed, buffer);
        }
    }
    return g_state;
}

std::string SunshineStatusText() {
    std::lock_guard<std::mutex> lock(g_mutex);
    return g_status;
}

namespace {

std::string g_capture_device_id;

/// The id that pins the capture display, remembered between runs.
std::wstring DeviceIdCachePath(const std::wstring& config_dir) {
    return config_dir + L"\\display-id.txt";
}

}  // namespace

/// Bring Sunshine back if it stops.
///
/// The supervisor used to start it and then only ever *notice* that it had
/// gone: GetSunshineState would report kFailed and nothing acted on it, so a
/// Sunshine that crashed took the PC's ability to stream with it until somebody
/// restarted SolStream by hand. Measured — killing it mid-stream left the Mac
/// showing "Lost the stream" and the host with nothing listening, permanently.
DWORD WINAPI SunshineWatchdog(LPVOID) {
    while (InterlockedCompareExchange(&g_watchdog_stop, 0, 0) == 0) {
        Sleep(2000);

        unsigned short port = 0;
        bool wanted = false;
        {
            std::lock_guard<std::mutex> lock(g_mutex);
            wanted = g_wanted;
            port = MapPort(g_base_port, SunshinePort::kHttp);
            if (g_process && WaitForSingleObject(g_process, 0) == WAIT_OBJECT_0) {
                CloseHandle(g_process);
                g_process = nullptr;
            }
        }
        if (!wanted) {
            continue;
        }

        // The question is not "did our handle exit" but "can this host stream" —
        // which is answered by whether anything is listening. That covers the
        // process dying whoever noticed it first, and it leaves an adopted
        // Sunshine alone: something is listening, so there is nothing to do.
        if (SomethingListensOn(port)) {
            continue;
        }

        {
            std::lock_guard<std::mutex> lock(g_mutex);
            const ULONGLONG now = GetTickCount64();
            if (g_last_restart_tick != 0 && now - g_last_restart_tick > kHealthyMillis) {
                g_restarts = 0;
            }
            g_last_restart_tick = now;
        }

        if (g_restarts >= kMaxRestarts) {
            std::lock_guard<std::mutex> lock(g_mutex);
            SetStatus(SunshineState::kFailed,
                      "Sunshine keeps stopping; giving up until SolStream restarts");
            continue;
        }
        ++g_restarts;
        // StartSunshine takes the lock itself, so it must not be held here.
        StartSunshine(g_base_port, g_output_name);
    }
    return 0;
}

bool StartSunshine(unsigned short base_port, const std::wstring& output_name) {
    {
        std::lock_guard<std::mutex> lock(g_mutex);
        g_base_port = base_port;
        g_output_name = output_name;
        g_wanted = true;
        if (!g_watchdog_thread) {
            InterlockedExchange(&g_watchdog_stop, 0);
            g_watchdog_thread = CreateThread(nullptr, 0, SunshineWatchdog,
                                             nullptr, 0, nullptr);
        }
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_process && WaitForSingleObject(g_process, 0) == WAIT_TIMEOUT) {
        return true;  // already supervising one
    }

    // Adopt one that is already there before starting another. Two Sunshines on
    // one base port is not a degraded arrangement, it is a broken one: the
    // second fails to bind and the first goes on serving, so which one a client
    // reaches stops being knowable.
    if (SomethingListensOn(
            MapPort(base_port, SunshinePort::kHttp))) {
        // Adopting is not just "leave it alone": without the credentials for
        // whatever is listening, this program cannot approve a pairing PIN, and
        // the user is asked to type a code for a reason they cannot see. If it
        // is our own Sunshine from a previous run, the credentials are on disk.
        if (g_user.empty()) {
            LoadCredentials(SunshineConfigDir(), g_user, g_password);
        }
        char buffer[192];
        std::snprintf(buffer, sizeof(buffer),
                      "Using the Sunshine already listening on port %u (%s)",
                      (unsigned) MapPort(base_port, SunshinePort::kHttp),
                      g_user.empty() ? "credentials unknown - pairing needs a PIN"
                                     : "pairing handled here");
        SetStatus(SunshineState::kRunning, buffer);
        return true;
    }

    const SunshineLocation location = FindSunshine();
    if (location.executable.empty()) {
        SetStatus(SunshineState::kNotBundled,
                  "No sunshine.exe found beside SolStream or in Program Files");
        return false;
    }

    // Sunshine looks for assets/ (its shaders) relative to where it is
    // running, so it has to be started from its own directory. Starting it from
    // ours failed at "Couldn't compile ...convert_yuv420...hlsl [0x80070003]"
    // and then "Platform failed to initialize" — a path error reported as a
    // shader error, two layers from its cause.
    std::wstring install_dir = location.executable;
    const size_t slash = install_dir.find_last_of(L'\\');
    install_dir = slash == std::wstring::npos ? std::wstring{} : install_dir.substr(0, slash);

    const std::wstring config_dir = SunshineConfigDir();
    if (config_dir.empty()) {
        SetStatus(SunshineState::kFailed, "No LOCALAPPDATA to put the configuration in");
        return false;
    }

    if (g_capture_device_id.empty()) {
        const std::string cached = ReadWholeFile(DeviceIdCachePath(config_dir));
        const size_t split = cached.find('=');
        if (split != std::string::npos
            && cached.substr(0, split) == Narrow(output_name)) {
            g_capture_device_id = cached.substr(split + 1);
        }
    }

    // Reuse the credentials from last time if there are any; Sunshine keeps
    // only a hash of the password, so a fresh one every start would mean
    // rewriting its store on every start too.
    if (g_user.empty()) {
        LoadCredentials(config_dir, g_user, g_password);
    }
    if (g_user.empty()) {
        g_user = "solstream";
        g_password = RandomHex(24);
        if (g_password.empty()) {
            SetStatus(SunshineState::kFailed, "Could not generate web credentials");
            return false;
        }
        SaveCredentials(config_dir, g_user, g_password);
    }

    // Written every start, not just the first: the ports and the capture display
    // are decided by this program, and a stale file would quietly send the
    // stream somewhere else.
    const std::wstring config_path = config_dir + L"\\sunshine.conf";
    {
        std::ofstream config(config_path.c_str());
        if (!config) {
            SetStatus(SunshineState::kFailed, "Could not write sunshine.conf");
            return false;
        }
        config << "# Written by SolStream. Edits here are overwritten on every start.\n"
               << "# This is SolStream's own Sunshine; an install you set up yourself\n"
               << "# keeps its own configuration and its own ports.\n\n"
               << "port = " << base_port << "\n"
               << "origin_web_ui_allowed = lan\n"
               // The capture display is pinned so the stream cannot show the
               // real desktop even for a frame.
               // The device id when it is known, because that is what
               // Sunshine actually resolves. The GDI name is written only
               // before the first enumeration has been read, and is corrected
               // immediately afterwards.
               << "output_name = "
               << (g_capture_device_id.empty() ? Narrow(output_name)
                                               : g_capture_device_id) << "\n"
               // Desktop Duplication, named rather than left to Sunshine's own
               // probing so the capture path is the same on every machine.
               //
               // Not the cause of the "window draws its chrome, its content is a
               // black rectangle" bug, though it looks like a capture fault and
               // was tried as one: that was the virtual display advertising HDR,
               // so the whole pipeline carried ST.2084 / Rec.2020 while the Mac
               // decoded plain Rec.709 gamma. setup-virtual-display.ps1 turns HDR
               // off; switching this to `wgc` changed nothing either way.
               << "capture = ddx\n"
               << "min_log_level = info\n"
               << "log_path = " << Narrow(config_dir) << "\\sunshine.log\n"
               << "credentials_file = " << Narrow(config_dir) << "\\credentials.json\n"
               << "file_state = " << Narrow(config_dir) << "\\state.json\n"
               << "file_apps = " << Narrow(config_dir) << "\\apps.json\n"
               // The TLS identity, and the reason a second Sunshine died where
               // the first did not. Left unset, these default to the install
               // directory -- C:\\Program Files\\Sunshine\\config -- which the
               // service can write to as SYSTEM and an ordinary user cannot.
               // nvhttp starts on a std::jthread, so the failure to create them
               // came out as std::terminate: exit code 0xC0000409, no message,
               // and a log that simply stops.
               << "cert = " << Narrow(config_dir) << "\\cert.pem\n"
               << "pkey = " << Narrow(config_dir) << "\\pkey.pem\n"
               // Nothing about SolStream's Sunshine is meant to be user-visible,
               // and a second tray icon for a thing the user did not start is
               // the opposite of that.
               << "system_tray = disabled\n";
    }

    // Sunshine needs an apps file; without one it has nothing to launch and the
    // client's /launch fails. Only "Desktop" is needed — SolStream crops a
    // window out of the desktop capture rather than launching per-app streams.
    const std::wstring apps_path = config_dir + L"\\apps.json";
    if (!FileExists(apps_path)) {
        std::ofstream apps(apps_path.c_str());
        apps << "{\"env\":{},\"apps\":[{\"name\":\"Desktop\",\"image-path\":\"\"}]}\n";
    }

    // The credentials go in through Sunshine's own --creds, which hashes and
    // stores them the way its web UI would. Run to completion first, so the
    // service that follows already trusts them.
    {
        // The config file comes FIRST and --creds after it. Sunshine's parser
        // stops at the first --option and hands everything past it to the
        // command (config.cpp: parse), and `creds` writes to whichever
        // credentials_file the config that was loaded names. Without the config
        // in front, this wrote to the default location — i.e. to the Sunshine
        // the user installed, not to ours.
        std::wstring creds = L"\"" + location.executable + L"\" \"" + config_path
                           + L"\" --creds "
                           + std::wstring(g_user.begin(), g_user.end()) + L" "
                           + std::wstring(g_password.begin(), g_password.end());
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        startup.dwFlags = STARTF_USESHOWWINDOW;
        startup.wShowWindow = SW_HIDE;
        PROCESS_INFORMATION info{};
        std::wstring command = creds;
        if (CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                           CREATE_NO_WINDOW, nullptr,
                           install_dir.empty() ? nullptr : install_dir.c_str(),
                           &startup, &info)) {
            WaitForSingleObject(info.hProcess, 10000);
            CloseHandle(info.hThread);
            CloseHandle(info.hProcess);
        }
    }

    // A job object with kill-on-close, so a SolStream that crashes does not
    // leave an orphaned Sunshine holding the capture display and the ports —
    // which the next start would then fail against, for no visible reason.
    if (!g_job) {
        g_job = CreateJobObjectW(nullptr, nullptr);
        if (g_job) {
            JOBOBJECT_EXTENDED_LIMIT_INFORMATION limits{};
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(g_job, JobObjectExtendedLimitInformation,
                                    &limits, sizeof(limits));
        }
    }

    std::wstring command = L"\"" + location.executable + L"\" \"" + config_path + L"\"";
    STARTUPINFOW startup{};
    startup.cb = sizeof(startup);
    startup.dwFlags = STARTF_USESHOWWINDOW;
    startup.wShowWindow = SW_HIDE;
    PROCESS_INFORMATION info{};
    if (!CreateProcessW(nullptr, command.data(), nullptr, nullptr, FALSE,
                        CREATE_NO_WINDOW | CREATE_SUSPENDED, nullptr,
                        install_dir.empty() ? nullptr : install_dir.c_str(),
                        &startup, &info)) {
        char buffer[128];
        std::snprintf(buffer, sizeof(buffer), "Could not start Sunshine (error %lu)",
                      GetLastError());
        SetStatus(SunshineState::kFailed, buffer);
        return false;
    }
    if (g_job) {
        AssignProcessToJobObject(g_job, info.hProcess);
    }
    ResumeThread(info.hThread);
    CloseHandle(info.hThread);
    g_process = info.hProcess;

    // Running means answering, not merely existing.
    //
    // A process that has not exited yet is not a host that can serve a stream,
    // and the difference is not academic: a Sunshine installed as a Windows
    // service is launched by sunshinesvc.exe, and that build quits shortly after
    // start-up when run as an ordinary process — late enough to survive any
    // "did it exit immediately" check, early enough that nothing ever listens.
    // Waiting for the port is the only claim worth making.
    const unsigned short http_port = MapPort(base_port, SunshinePort::kHttp);
    for (int attempt = 0; attempt < 30; ++attempt) {
        if (SomethingListensOn(http_port)) {
            // Now that it has enumerated the displays, take its own id for the
            // one we want and, if we were guessing before, say it properly and
            // start again. Once per machine: the answer is cached beside the
            // configuration.
            if (g_capture_device_id.empty()) {
                const std::string id = DeviceIdForDisplay(config_dir, Narrow(output_name));
                if (!id.empty()) {
                    g_capture_device_id = id;
                    const std::string cache = Narrow(output_name) + "=" + id;
                    HANDLE file = CreateFileW(DeviceIdCachePath(config_dir).c_str(),
                                              GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                              FILE_ATTRIBUTE_NORMAL, nullptr);
                    if (file != INVALID_HANDLE_VALUE) {
                        DWORD written = 0;
                        WriteFile(file, cache.data(), (DWORD) cache.size(), &written, nullptr);
                        CloseHandle(file);
                    }
                    SetStatus(SunshineState::kStarting,
                              "Restarting Sunshine on the virtual display");
                    // Unlock-free restart: the caller holds g_mutex, so tear
                    // this one down inline and go round again.
                    TerminateProcess(g_process, 0);
                    WaitForSingleObject(g_process, 5000);
                    CloseHandle(g_process);
                    g_process = nullptr;
                    g_restart_for_device_id = true;
                    return false;
                }
            }
            char buffer[224];
            std::snprintf(buffer, sizeof(buffer),
                          "Sunshine running on base port %u (%s copy, capturing %s)",
                          (unsigned) base_port, location.bundled ? "bundled" : "installed",
                          g_capture_device_id.empty() ? "the default display"
                                                      : "the chosen display");
            SetStatus(SunshineState::kRunning, buffer);
            return true;
        }
        if (WaitForSingleObject(g_process, 500) == WAIT_OBJECT_0) {
            DWORD code = 0;
            GetExitCodeProcess(g_process, &code);
            CloseHandle(g_process);
            g_process = nullptr;
            char buffer[320];
            std::snprintf(buffer, sizeof(buffer),
                          "Sunshine quit without listening (0x%08lX). A Sunshine installed "
                          "as a Windows service only runs through that service - SolStream "
                          "needs its own copy bundled beside it.", code);
            SetStatus(SunshineState::kFailed, buffer);
            return false;
        }
    }

    char buffer[224];
    std::snprintf(buffer, sizeof(buffer),
                  "Sunshine started but nothing is listening on port %u after 15s",
                  (unsigned) http_port);
    SetStatus(SunshineState::kFailed, buffer);
    return false;
}

void StopSunshine() {
    // Before taking the lock: the watchdog can be inside StartSunshine, which
    // takes it, and stopping is meant to mean stopped rather than restarted.
    InterlockedExchange(&g_watchdog_stop, 1);
    if (g_watchdog_thread) {
        WaitForSingleObject(g_watchdog_thread, 6000);
        CloseHandle(g_watchdog_thread);
        g_watchdog_thread = nullptr;
    }
    std::lock_guard<std::mutex> lock(g_mutex);
    g_wanted = false;
    if (g_process) {
        TerminateProcess(g_process, 0);
        WaitForSingleObject(g_process, 5000);
        CloseHandle(g_process);
        g_process = nullptr;
    }
    if (g_job) {
        CloseHandle(g_job);
        g_job = nullptr;
    }
    SetStatus(SunshineState::kStopped, "stopped");
}

}  // namespace solstream
