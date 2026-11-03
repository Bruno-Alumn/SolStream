#include "crash_report.h"

#include <windows.h>
#include <dbghelp.h>

#include <cstdlib>
#include <cwchar>
#include <exception>
#include <string>

#include "util.h"

namespace solstream {
namespace {

wchar_t g_log_path[MAX_PATH * 2];
wchar_t g_dump_path[MAX_PATH * 2];
wchar_t g_exe_path[MAX_PATH * 2];
wchar_t g_command_line[8192];
volatile bool g_restart = false;
ULONGLONG g_installed_at = 0;
volatile LONG g_crashing = 0;
/// How many times in a row the host may come back after a crash: a host
/// that crashes every few minutes should stay down and say so, not churn.
constexpr int kMaxRestarts = 5;

using MiniDumpWriteDumpFn = BOOL(WINAPI*)(HANDLE, DWORD, HANDLE, MINIDUMP_TYPE,
                                          PMINIDUMP_EXCEPTION_INFORMATION,
                                          PMINIDUMP_USER_STREAM_INFORMATION,
                                          PMINIDUMP_CALLBACK_INFORMATION);
MiniDumpWriteDumpFn g_write_dump = nullptr;

/// Straight to the file, not through Log(): the crash may have happened with
/// Log's lock held.
void AppendLine(const char* text) {
    HANDLE file = CreateFileW(g_log_path, FILE_APPEND_DATA,
                              FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, nullptr,
                              OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return;
    }
    DWORD written = 0;
    WriteFile(file, text, (DWORD) strlen(text), &written, nullptr);
    CloseHandle(file);
}

/// Says where, starts the next copy, writes the dump, and ends this one --
/// in that order: the dump is the step most likely to fail or hang in a
/// crashing process (on an exhausted stack, or with the heap or loader lock
/// held), and it must not cost the restart.
[[noreturn]] void ReportAndEnd(DWORD code, EXCEPTION_POINTERS* info, const char* what) {
    // One report. Another thread crashing meanwhile waits for this one to end
    // the process, rather than going to Windows Error Reporting mid-dump; a
    // second fault on this thread, inside the report, ends it there and then.
    static volatile DWORD reporting_thread = 0;
    if (InterlockedExchange(&g_crashing, 1) != 0) {
        if (reporting_thread == GetCurrentThreadId()) {
            TerminateProcess(GetCurrentProcess(), code);
        }
        Sleep(INFINITE);
    }
    reporting_thread = GetCurrentThreadId();

    const EXCEPTION_RECORD* record = info ? info->ExceptionRecord : nullptr;
    const void* address = record ? record->ExceptionAddress : nullptr;
    HMODULE module = nullptr;
    char where[MAX_PATH + 32] = "an unknown place";
    if (address && GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                                          | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                      (LPCSTR) address, &module)) {
        char path[MAX_PATH] = {};
        const char* base = "?";
        if (GetModuleFileNameA(module, path, MAX_PATH)) {
            base = strrchr(path, '\\') ? strrchr(path, '\\') + 1 : path;
        }
        wsprintfA(where, "%s+0x%lX", base,
                  (unsigned long) ((const char*) address - (const char*) module));
    } else if (address) {
        // Outside every module -- a jump through a freed object, say -- the
        // whole address, whose top half says heap, stack or null.
        const unsigned long long at = (unsigned long long) (uintptr_t) address;
        wsprintfA(where, "0x%08lX%08lX", (unsigned long) (at >> 32), (unsigned long) at);
    }
    SYSTEMTIME now;
    GetLocalTime(&now);
    char line[MAX_PATH + 256];
    wsprintfA(line,
              "%04u-%02u-%02u %02u:%02u:%02u  [%lu] [crash] %s 0x%08lX at %s "
              "(thread %lu, up %lu s)\r\n",
              now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
              GetCurrentProcessId(), what, code, where, GetCurrentThreadId(),
              (unsigned long) ((GetTickCount64() - g_installed_at) / 1000));
    AppendLine(line);

    // Not after a crash in the first minute, which would only crash again.
    if (g_restart && GetTickCount64() - g_installed_at >= 60 * 1000) {
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};
        if (CreateProcessW(g_exe_path, g_command_line, nullptr, nullptr, FALSE, 0, nullptr,
                           nullptr, &startup, &process)) {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            AppendLine("                     [crash] started SolStream again\r\n");
        }
    }

    if (g_write_dump) {
        HANDLE dump = CreateFileW(g_dump_path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
        if (dump != INVALID_HANDLE_VALUE) {
            MINIDUMP_EXCEPTION_INFORMATION exception{GetCurrentThreadId(), info, FALSE};
            if (g_write_dump(GetCurrentProcess(), GetCurrentProcessId(), dump,
                             (MINIDUMP_TYPE) (MiniDumpWithThreadInfo
                                              | MiniDumpWithUnloadedModules),
                             info ? &exception : nullptr, nullptr, nullptr)) {
                AppendLine("                     [crash] minidump in crash.dmp\r\n");
            }
            CloseHandle(dump);
        }
    }
    // Ended here, not by returning to whatever outer handler the thread has:
    // one that reaches ExitProcess runs DLL detach in a damaged process, which
    // can hang -- holding the single-instance name the next copy waits for.
    TerminateProcess(GetCurrentProcess(), code);
    Sleep(INFINITE);
}

LONG WINAPI OnCrash(EXCEPTION_POINTERS* info) {
    const DWORD code = info && info->ExceptionRecord ? info->ExceptionRecord->ExceptionCode : 0;
    ReportAndEnd(code, info, code == 0xE06D7363 ? "uncaught C++ exception" : "exception");
}

void OnTerminate() {
    ReportAndEnd(ERROR_UNHANDLED_EXCEPTION, nullptr, "std::terminate");
}

void OnPureCall() {
    ReportAndEnd(ERROR_INVALID_FUNCTION, nullptr, "pure virtual call");
}

void OnInvalidParameter(const wchar_t*, const wchar_t*, const wchar_t*, unsigned, uintptr_t) {
    ReportAndEnd(ERROR_INVALID_PARAMETER, nullptr, "invalid parameter to the C runtime");
}

}  // namespace

void InstallCrashReport(bool restart) {
    const std::wstring log = LocalDataPath(L"solstream.log");
    const std::wstring dump = LocalDataPath(L"crash.dmp");
    if (log.empty() || log.size() >= MAX_PATH * 2 || dump.size() >= MAX_PATH * 2) {
        return;
    }
    wcscpy_s(g_log_path, log.c_str());
    wcscpy_s(g_dump_path, dump.c_str());
    // From System32 only, like every other DLL this program loads.
    if (HMODULE dbghelp = LoadLibraryExW(L"dbghelp.dll", nullptr, LOAD_LIBRARY_SEARCH_SYSTEM32)) {
        g_write_dump = (MiniDumpWriteDumpFn) (void*) GetProcAddress(dbghelp, "MiniDumpWriteDump");
    }
    // Each restart adds one more --after-crash to the command line it passes
    // on, so the count of them is how many times in a row this has happened.
    int restarts = 0;
    for (const wchar_t* at = GetCommandLineW(); (at = wcsstr(at, L"--after-crash")) != nullptr;
         at += 13) {
        ++restarts;
    }
    if (restart && restarts >= kMaxRestarts) {
        AppendLine("                     [crash] SolStream has come back after five crashes since it "
                   "was started; the next one is not restarted\r\n");
    }
    g_restart = restart && restarts < kMaxRestarts
                && GetModuleFileNameW(nullptr, g_exe_path, MAX_PATH * 2) > 0
                && _snwprintf_s(g_command_line, _TRUNCATE, L"%ls --after-crash %lu",
                                GetCommandLineW(), GetCurrentProcessId()) > 0;
    g_installed_at = GetTickCount64();
    SetUnhandledExceptionFilter(OnCrash);
    std::set_terminate(OnTerminate);
#ifdef _MSC_VER
    _set_purecall_handler(OnPureCall);
    _set_invalid_parameter_handler(OnInvalidParameter);
#else
    (void) OnPureCall;
    (void) OnInvalidParameter;
#endif
}

void DisableCrashRestart() {
    g_restart = false;
}

void WaitForCrashedCopy(unsigned long pid) {
    if (HANDLE crashed = OpenProcess(SYNCHRONIZE, FALSE, pid)) {
        WaitForSingleObject(crashed, 15000);
        CloseHandle(crashed);
    }
}

}  // namespace solstream
