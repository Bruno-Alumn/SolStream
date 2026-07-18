#include "helper_signing.h"

#include <wintrust.h>
#include <softpub.h>
#include <cryptuiapi.h>

#include <cwchar>

#pragma comment(lib, "wintrust.lib")
#pragma comment(lib, "crypt32.lib")
#pragma comment(lib, "cryptui.lib")

namespace solstream::security {

// ══════════════════════════════════════════════════════════════════════════════
// VerifyHelperSignature
// ══════════════════════════════════════════════════════════════════════════════

bool VerifyHelperSignature(const std::wstring& binaryPath) {
    WINTRUST_FILE_INFO fileInfo{};
    fileInfo.cbStruct = sizeof(fileInfo);
    fileInfo.pcwszFilePath = binaryPath.c_str();
    fileInfo.hFile = nullptr;
    fileInfo.pgKnownSubject= nullptr;

    WINTRUST_DATA trustData{};
    trustData.cbStruct = sizeof(trustData);
    trustData.dwUnionChoice = WTD_CHOICE_FILE;
    trustData.pFile = &fileInfo;
    trustData.dwUIChoice = WTD_UI_NONE;
    trustData.fdwRevocationChecks = WTD_REVOKE_NONE;
    trustData.dwProvFlags = WTD_CACHE_ONLY_URL_RETRIEVAL |
                            WTD_USE_DEFAULT_OSVER_CHECK;
    trustData.dwStateAction = WTD_STATEACTION_VERIFY;
    trustData.hWVTStateData = nullptr;

    GUID policyGUID = WINTRUST_ACTION_GENERIC_VERIFY_V2;
    LONG status = WinVerifyTrust(nullptr, &policyGUID, &trustData);

    // Close the verification state.
    trustData.dwStateAction = WTD_STATEACTION_CLOSE;
    WinVerifyTrust(nullptr, &policyGUID, &trustData);

    return status == ERROR_SUCCESS;
}

// ══════════════════════════════════════════════════════════════════════════════
// VerifyPublisher
// ══════════════════════════════════════════════════════════════════════════════

bool VerifyPublisher(const std::wstring& binaryPath,
                     const std::wstring& expectedCN)
{
    // Get the certificate context from the signed file.
    HCERTSTORE hStore = nullptr;
    HCRYPTMSG hMsg = nullptr;
    PCCERT_CONTEXT pCertContext = nullptr;

    BOOL result = CryptQueryObject(
        CERT_QUERY_OBJECT_FILE,
        binaryPath.c_str(),
        CERT_QUERY_CONTENT_FLAG_ALL,
        CERT_QUERY_FORMAT_FLAG_ALL,
        0,
        nullptr, nullptr, nullptr,
        &hStore, &hMsg, &pCertContext);

    if (!result || !pCertContext) {
        if (pCertContext) CertFreeCertificateContext(pCertContext);
        if (hStore) CertCloseStore(hStore, 0);
        if (hMsg) CryptMsgClose(hMsg);
        return false;
    }

    // Get the subject name from the certificate.
    wchar_t subjectName[256]{};
    DWORD nameSize = 256;
    CertGetNameStringW(pCertContext, CERT_NAME_SIMPLE_DISPLAY_TYPE,
                       0, nullptr, subjectName, nameSize);

    CertFreeCertificateContext(pCertContext);
    if (hStore) CertCloseStore(hStore, 0);
    if (hMsg) CryptMsgClose(hMsg);

    // Compare case-insensitively.
    return _wcsicmp(subjectName, expectedCN.c_str()) == 0;
}

// ══════════════════════════════════════════════════════════════════════════════
// HasSignature
// ══════════════════════════════════════════════════════════════════════════════

bool HasSignature(const std::wstring& binaryPath) {
    // Quick check: try to get the signature timestamp.
    HCERTSTORE hStore = nullptr;
    HCRYPTMSG hMsg = nullptr;
    PCCERT_CONTEXT pCertContext = nullptr;

    BOOL result = CryptQueryObject(
        CERT_QUERY_OBJECT_FILE,
        binaryPath.c_str(),
        CERT_QUERY_CONTENT_FLAG_ALL,
        CERT_QUERY_FORMAT_FLAG_ALL,
        0,
        nullptr, nullptr, nullptr,
        &hStore, &hMsg, &pCertContext);

    if (pCertContext) CertFreeCertificateContext(pCertContext);
    if (hStore) CertCloseStore(hStore, 0);
    if (hMsg) CryptMsgClose(hMsg);

    return result != FALSE;
}

} // namespace solstream::security
