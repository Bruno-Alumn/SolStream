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

    // Second, verify the certificate subject (issuer/signer)
    // Open the file and extract the certificate to check the subject
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

    // Get the certificate context from the message
    PCCERT_CONTEXT pCertContext = nullptr;
    DWORD certCount = 0;
    
    // Enumerate certificates in the store to find the signer
    while ((pCertContext = CertEnumCertificatesInStore(hStore, pCertContext)) != nullptr) {
        // Check if this certificate is the signer by verifying against the message
        // For simplicity, we check the subject name contains "SolStream"
        // In production, this should check against a specific expected subject/thumbprint
        DWORD nameLen = CertGetNameStringW(
            pCertContext,
            CERT_NAME_SIMPLE_DISPLAY_TYPE,
            0,
            nullptr,
            nullptr,
            0);
        
        if (nameLen > 0) {
            std::wstring subjectName(nameLen, L'\0');
            CertGetNameStringW(
                pCertContext,
                CERT_NAME_SIMPLE_DISPLAY_TYPE,
                0,
                nullptr,
                &subjectName[0],
                nameLen);
            
            // Check if the subject contains expected text (e.g., "SolStream")
            // This is a basic check - production should use thumbprint or full subject match
            if (subjectName.find(L"SolStream") != std::wstring::npos) {
                CertFreeCertificateContext(pCertContext);
                CertCloseStore(hStore, 0);
                if (hMsg) CryptMsgClose(hMsg);
                return true;
            }
        }
    }

    // Cleanup
    if (hStore) CertCloseStore(hStore, 0);
    if (hMsg) CryptMsgClose(hMsg);

    return false;  // Certificate subject verification failed
}

} // namespace solstream::input
