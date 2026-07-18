#include "pipe_client_validator.h"

#include <wintrust.h>
#include <softpub.h>

#pragma comment(lib, "wintrust.lib")

namespace solstream::input {

// ══════════════════════════════════════════════════════════════════════════════
// Validate
// ══════════════════════════════════════════════════════════════════════════════

bool PipeClientValidator::Validate(HANDLE pipeHandle) {
    if (m_validated)
        return true;  // Already validated — no re-validation needed

    // Step 1: Get the client process ID.
    DWORD clientPID = 0;
    if (!GetNamedPipeClientProcessId(pipeHandle, &clientPID) || clientPID == 0)
        return false;

    // Step 2: Open the process (hold open to prevent PID recycling).
    HANDLE hProcess = OpenProcess(
        PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_DUP_HANDLE,
        FALSE, clientPID);
    if (!hProcess)
        return false;

    // Step 3: Get process creation time for PID recycling check.
    FILETIME createTime{}, exitTime{}, kernelTime{}, userTime{};
    if (!GetProcessTimes(hProcess, &createTime, &exitTime, &kernelTime, &userTime)) {
        CloseHandle(hProcess);
        return false;
    }

    // Step 4: Get the process image path.
    wchar_t imagePath[MAX_PATH]{};
    DWORD pathSize = MAX_PATH;
    if (!QueryFullProcessImageNameW(hProcess, 0, imagePath, &pathSize)) {
        CloseHandle(hProcess);
        return false;
    }

    // Step 5: Verify the binary signature.
    if (!VerifyBinarySignature(imagePath)) {
        CloseHandle(hProcess);
        return false;
    }

    // Success — store the handle and PID.
    m_clientProcess = hProcess;
    m_clientPID = clientPID;
    m_creationTime = (static_cast<uint64_t>(createTime.dwHighDateTime) << 32)
                     | static_cast<uint64_t>(createTime.dwLowDateTime);
    m_validated = true;

    return true;
}

void PipeClientValidator::ReleaseProcess() {
    if (m_clientProcess) {
        CloseHandle(m_clientProcess);
        m_clientProcess = nullptr;
    }
    m_clientPID = 0;
    m_validated = false;
    m_creationTime = 0;
}

// ══════════════════════════════════════════════════════════════════════════════
// Signature verification
// ══════════════════════════════════════════════════════════════════════════════

bool PipeClientValidator::VerifyBinarySignature(const std::wstring& path) {
    WINTRUST_FILE_INFO fileInfo{};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = path.c_str();
    fileInfo.hFile = nullptr;
    fileInfo.pgKnownSubject = nullptr;

    WINTRUST_DATA trustData{};
    trustData.cbStruct = sizeof(trustData);
    trustData.dwUnionChoice = WTD_CHOICE_FILE;
    trustData.pFile = &fileInfo;
    trustData.dwUIChoice = WTD_UI_NONE;            // No UI
    trustData.fdwRevocationChecks = WTD_REVOKE_NONE;
    trustData.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL;
    trustData.dwStateAction = WTD_STATEACTION_IGNORE;

    GUID policyGUID = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    LONG status = WinVerifyTrust(nullptr, &policyGUID, &trustData);
    return status == ERROR_SUCCESS;
}

} // namespace solstream::input
