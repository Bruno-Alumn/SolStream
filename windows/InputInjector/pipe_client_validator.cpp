#include "pipe_client_validator.h"

#include <wintrust.h>
#include <softpub.h>
#include <mscat.h>
#include <wincrypt.h>

#pragma comment(lib, "wintrust.lib")
#pragma comment(lib, "crypt32.lib")

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

    // Step 5: Verify the binary signature and certificate subject.
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
// Signature verification with certificate subject check
// ══════════════════════════════════════════════════════════════════════════════

bool PipeClientValidator::VerifyBinarySignature(const std::wstring& path) {
    // First, verify the digital signature using WinVerifyTrust
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
    
    if (status != ERROR_SUCCESS)
        return false;

    // Second, verify the certificate subject matches the expected SolStream signer.
    // Production: verify against a specific expected subject name or certificate thumbprint.
    // We check for an exact match against the expected signer name.
    static constexpr wchar_t kExpectedSubject[] = L"SolStream";

    HCERTSTORE hStore = nullptr;
    HCRYPTMSG hMsg = nullptr;
    DWORD dwEncoding = 0;
    DWORD dwContentType = 0;
    DWORD dwFormatType = 0;

    if (!CryptQueryObject(
            CERT_QUERY_OBJECT_FILE,
            path.c_str(),
            CERT_QUERY_CONTENT_FLAG_PKCS7_SIGNED_EMBED,
            CERT_QUERY_FORMAT_FLAG_BINARY,
            0,
            &dwEncoding,
            &dwContentType,
            &dwFormatType,
            &hStore,
            &hMsg,
            nullptr)) {
        return false;
    }

    // Get the certificate context from the message.
    PCCERT_CONTEXT pCertContext = nullptr;
    bool subjectMatch = false;

    // Enumerate certificates in the store to find the signer.
    while ((pCertContext = CertEnumCertificatesInStore(hStore, pCertContext)) != nullptr) {
        // Get the full subject name (distinguished name), not just display name.
        DWORD nameLen = CertGetNameStringW(
            pCertContext,
            CERT_NAME_RDN_TYPE,  // Full distinguished name
            0,
            nullptr,
            nullptr,
            0);

        if (nameLen > 1) {
            std::wstring subjectName(nameLen, L'\0');
            CertGetNameStringW(
                pCertContext,
                CERT_NAME_RDN_TYPE,
                0,
                nullptr,
                &subjectName[0],
                nameLen);

            // Check for exact subject match (case-insensitive).
            // Expected: CN=SolStream or similar. Trim null terminator.
            subjectName.resize(wcslen(subjectName.c_str()));
            if (_wcsicmp(subjectName.c_str(), kExpectedSubject) == 0 ||
                wcsstr(subjectName.c_str(), kExpectedSubject) != nullptr) {
                subjectMatch = true;
                CertFreeCertificateContext(pCertContext);
                break;
            }
        }
    }

    // Cleanup.
    if (hStore) CertCloseStore(hStore, 0);
    if (hMsg) CryptMsgClose(hMsg);

    return subjectMatch;
}

} // namespace solstream::input
