#include "crash_report.h"

#include <windows.h>
#include <dbghelp.h>

#include <cwchar>
#include <string>

#include "util.h"

namespace solstream {
namespace {

wchar_t g_log_path[MAX_PATH * 2];
wchar_t g_dump_path[MAX_PATH * 2];
wchar_t g_exe_path[MAX_PATH * 2];
wchar_t g_command_line[8192];
bool g_restart = false;
ULONGLONG g_installed_at = 0;
volatile LONG g_crashing = 0;

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

LONG WINAPI OnCrash(EXCEPTION_POINTERS* info) {
    // One report: a second fault inside this one, or on another thread at
    // the same moment, goes to Windows as it would have.
    if (InterlockedExchange(&g_crashing, 1) != 0) {
        return EXCEPTION_CONTINUE_SEARCH;
    }
    const EXCEPTION_RECORD* record = info ? info->ExceptionRecord : nullptr;
    const void* address = record ? record->ExceptionAddress : nullptr;
    HMODULE module = nullptr;
    char module_name[MAX_PATH] = "?";
    if (address && GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS
                                          | GET_MODULE_HANDLE_EX_FLAG_UNCHANGED_REFCOUNT,
                                      (LPCSTR) address, &module)) {
        char path[MAX_PATH] = {};
        if (GetModuleFileNameA(module, path, MAX_PATH)) {
            const char* base = strrchr(path, '\\');
            lstrcpynA(module_name, base ? base + 1 : path, MAX_PATH);
        }
    }
    SYSTEMTIME now;
    GetLocalTime(&now);
    char line[512];
    wsprintfA(line,
              "%04u-%02u-%02u %02u:%02u:%02u  [%lu] [crash] exception 0x%08lX at %s+0x%lX "
              "(thread %lu, up %lu s)%s\r\n",
              now.wYear, now.wMonth, now.wDay, now.wHour, now.wMinute, now.wSecond,
              GetCurrentProcessId(), record ? record->ExceptionCode : 0UL, module_name,
              (unsigned long) ((const char*) address - (const char*) module),
              GetCurrentThreadId(),
              (unsigned long) ((GetTickCount64() - g_installed_at) / 1000),
              g_write_dump ? "; minidump in crash.dmp" : "");
    AppendLine(line);

    if (g_write_dump) {
        HANDLE dump = CreateFileW(g_dump_path, GENERIC_WRITE, 0, nullptr, CREATE_ALWAYS,
                                  FILE_ATTRIBUTE_NORMAL, nullptr);
        if (dump != INVALID_HANDLE_VALUE) {
            MINIDUMP_EXCEPTION_INFORMATION exception{GetCurrentThreadId(), info, FALSE};
            g_write_dump(GetCurrentProcess(), GetCurrentProcessId(), dump,
                         (MINIDUMP_TYPE) (MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules),
                         info ? &exception : nullptr, nullptr, nullptr);
            CloseHandle(dump);
        }
    }

    // Not after a crash in the first minute, which would only crash again.
    if (g_restart && GetTickCount64() - g_installed_at >= 60 * 1000) {
        STARTUPINFOW startup{};
        startup.cb = sizeof(startup);
        PROCESS_INFORMATION process{};
        if (CreateProcessW(g_exe_path, g_command_line, nullptr, nullptr, FALSE, 0, nullptr,
                           nullptr, &startup, &process)) {
            CloseHandle(process.hThread);
            CloseHandle(process.hProcess);
            AppendLine("                     [crash] started again\r\n");
        }
    }
    return EXCEPTION_EXECUTE_HANDLER;
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
    g_restart = restart
                && GetModuleFileNameW(nullptr, g_exe_path, MAX_PATH * 2) > 0
                && _snwprintf_s(g_command_line, _TRUNCATE, L"%ls --after-crash %lu",
                                GetCommandLineW(), GetCurrentProcessId()) > 0;
    g_installed_at = GetTickCount64();
    SetUnhandledExceptionFilter(OnCrash);
}

void WaitForCrashedCopy(unsigned long pid) {
    if (HANDLE crashed = OpenProcess(SYNCHRONIZE, FALSE, pid)) {
        WaitForSingleObject(crashed, 15000);
        CloseHandle(crashed);
    }
}

}  // namespace solstream
