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
namespace {

std::mutex g_mutex;
HANDLE g_process = nullptr;
HANDLE g_job = nullptr;
SunshineState g_state = SunshineState::kStopped;
std::string g_status = "not started";
std::string g_user;
std::string g_password;

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

bool StartSunshine(unsigned short base_port, const std::wstring& output_name) {
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
        char buffer[128];
        std::snprintf(buffer, sizeof(buffer),
                      "Using the Sunshine already listening on port %u",
                      (unsigned) MapPort(base_port, SunshinePort::kHttp));
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

    if (g_user.empty()) {
        g_user = "solstream";
        g_password = RandomHex(24);
        if (g_password.empty()) {
            SetStatus(SunshineState::kFailed, "Could not generate web credentials");
            return false;
        }
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
               << "output_name = " << Narrow(output_name) << "\n"
               // SolStream crops a rectangle out of the captured display, so the
               // cursor Sunshine composites in is a second cursor a round trip
               // behind the local one. The client turns it off per session; this
               // is the same answer for the first frame.
               << "capture = ddx\n"
               << "min_log_level = info\n"
               << "log_path = " << Narrow(config_dir) << "\\sunshine.log\n"
               << "credentials_file = " << Narrow(config_dir) << "\\credentials.json\n"
               << "file_state = " << Narrow(config_dir) << "\\state.json\n"
               << "file_apps = " << Narrow(config_dir) << "\\apps.json\n";
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
            char buffer[192];
            std::snprintf(buffer, sizeof(buffer),
                          "Sunshine running on base port %u (%s copy)",
                          (unsigned) base_port, location.bundled ? "bundled" : "installed");
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
    std::lock_guard<std::mutex> lock(g_mutex);
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
