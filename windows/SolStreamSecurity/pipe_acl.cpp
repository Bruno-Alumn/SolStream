#include "pipe_acl.h"

#include <aclapi.h>
#include <sddl.h>
#include <vector>

#pragma comment(lib, "advapi32.lib")

namespace solstream::security {

// ══════════════════════════════════════════════════════════════════════════════
// BuildRestrictivePipeACL
// ══════════════════════════════════════════════════════════════════════════════

bool BuildRestrictivePipeACL(DWORD targetPID,
                              SECURITY_ATTRIBUTES& attributes)
{
    // Open the target process to get its SID.
    HANDLE hProcess = OpenProcess(PROCESS_QUERY_INFORMATION, FALSE, targetPID);
    if (!hProcess)
        return false;

    HANDLE hToken = nullptr;
    if (!OpenProcessToken(hProcess, TOKEN_QUERY, &hToken)) {
        CloseHandle(hProcess);
        return false;
    }

    // Get the token's user SID.
    DWORD tokenInfoSize = 0;
    GetTokenInformation(hToken, TokenUser, nullptr, 0, &tokenInfoSize);
    if (tokenInfoSize == 0) {
        CloseHandle(hToken);
        CloseHandle(hProcess);
        return false;
    }

    auto tokenInfo = std::vector<uint8_t>(tokenInfoSize);
    if (!GetTokenInformation(hToken, TokenUser, tokenInfo.data(),
                              (DWORD)tokenInfo.size(), &tokenInfoSize)) {
        CloseHandle(hToken);
        CloseHandle(hProcess);
        return false;
    }

    auto& tu = *reinterpret_cast<TOKEN_USER*>(tokenInfo.data());
    PSID pSid = tu.User.Sid;

    CloseHandle(hToken);
    CloseHandle(hProcess);

    // Build the DACL entries:
    // 1. Allow the process SID (GENERIC_READ | GENERIC_WRITE)
    // 2. Deny Everyone
    // 3. Deny Network
    // 4. Deny Anonymous Logon

    EXPLICIT_ACCESSW allowAccess{};
    allowAccess.grfAccessPermissions = GENERIC_READ | GENERIC_WRITE;
    allowAccess.grfAccessMode = GRANT_ACCESS;
    allowAccess.grfInheritance = NO_INHERITANCE;
    allowAccess.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    allowAccess.Trustee.TrusteeType = TRUSTEE_IS_USER;
    allowAccess.Trustee.ptstrName = reinterpret_cast<LPWSTR>(pSid);

    // Deny Everyone.
    EXPLICIT_ACCESSW denyEveryone{};
    denyEveryone.grfAccessPermissions = GENERIC_ALL;
    denyEveryone.grfAccessMode = DENY_ACCESS;
    denyEveryone.grfInheritance = NO_INHERITANCE;
    denyEveryone.Trustee.TrusteeForm = TRUSTEE_IS_WELL_KNOWN_GROUPS;
    denyEveryone.Trustee.TrusteeType = TRUSTEE_IS_GROUP;
    denyEveryone.Trustee.ptstrName = (LPWSTR)L"Everyone";

    // Deny Network.
    EXPLICIT_ACCESSW denyNetwork{};
    denyNetwork.grfAccessPermissions = GENERIC_ALL;
    denyNetwork.grfAccessMode = DENY_ACCESS;
    denyNetwork.grfInheritance = NO_INHERITANCE;
    denyNetwork.Trustee.TrusteeForm = TRUSTEE_IS_WELL_KNOWN_GROUPS;
    denyNetwork.Trustee.TrusteeType = TRUSTEE_IS_GROUP;
    denyNetwork.Trustee.ptstrName = (LPWSTR)L"NETWORK";

    // Deny Anonymous Logon.
    EXPLICIT_ACCESSW denyAnonymous{};
    denyAnonymous.grfAccessPermissions = GENERIC_ALL;
    denyAnonymous.grfAccessMode = DENY_ACCESS;
    denyAnonymous.grfInheritance = NO_INHERITANCE;
    denyAnonymous.Trustee.TrusteeForm = TRUSTEE_IS_WELL_KNOWN_GROUPS;
    denyAnonymous.Trustee.TrusteeType = TRUSTEE_IS_GROUP;
    denyAnonymous.Trustee.ptstrName = (LPWSTR)L"ANONYMOUS LOGON";

    EXPLICIT_ACCESSW entries[] = {
        allowAccess, denyEveryone, denyNetwork, denyAnonymous
    };

    PACL pACL = nullptr;
    DWORD result = SetEntriesInAclW(ARRAYSIZE(entries), entries,
                                     nullptr, &pACL);
    if (result != ERROR_SUCCESS)
        return false;

    // Create the security descriptor.
    PACL pSystemACL = nullptr;
    PSECURITY_DESCRIPTOR pSD = LocalAlloc(LPTR, SECURITY_DESCRIPTOR_MIN_LENGTH);
    if (!pSD) {
        LocalFree(pACL);
        return false;
    }

    if (!InitializeSecurityDescriptor(pSD, SECURITY_DESCRIPTOR_REVISION)) {
        LocalFree(pSD);
        LocalFree(pACL);
        return false;
    }

    if (!SetSecurityDescriptorDacl(pSD, TRUE, pACL, FALSE)) {
        LocalFree(pSD);
        LocalFree(pACL);
        return false;
    }

    attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
    attributes.lpSecurityDescriptor = pSD;
    attributes.bInheritHandle = FALSE;

    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// BuildSelfOnlyPipeACL
// ══════════════════════════════════════════════════════════════════════════════

bool BuildSelfOnlyPipeACL(SECURITY_ATTRIBUTES& attributes) {
    // Get the current process's token SID.
    HANDLE hToken = nullptr;
    if (!OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &hToken))
        return false;

    DWORD tokenInfoSize = 0;
    GetTokenInformation(hToken, TokenUser, nullptr, 0, &tokenInfoSize);
    if (tokenInfoSize == 0) { CloseHandle(hToken); return false; }

    auto tokenInfo = std::vector<uint8_t>(tokenInfoSize);
    if (!GetTokenInformation(hToken, TokenUser, tokenInfo.data(),
                              (DWORD)tokenInfo.size(), &tokenInfoSize)) {
        CloseHandle(hToken); return false;
    }

    auto& tu = *reinterpret_cast<TOKEN_USER*>(tokenInfo.data());
    PSID pSid = tu.User.Sid;
    CloseHandle(hToken);

    EXPLICIT_ACCESSW allowAccess{};
    allowAccess.grfAccessPermissions = GENERIC_READ | GENERIC_WRITE;
    allowAccess.grfAccessMode = GRANT_ACCESS;
    allowAccess.grfInheritance = NO_INHERITANCE;
    allowAccess.Trustee.TrusteeForm = TRUSTEE_IS_SID;
    allowAccess.Trustee.TrusteeType = TRUSTEE_IS_USER;
    allowAccess.Trustee.ptstrName = reinterpret_cast<LPWSTR>(pSid);

    PACL pACL = nullptr;
    SetEntriesInAclW(1, &allowAccess, nullptr, &pACL);

    PSECURITY_DESCRIPTOR pSD = LocalAlloc(LPTR, SECURITY_DESCRIPTOR_MIN_LENGTH);
    if (!pSD) { LocalFree(pACL); return false; }

    InitializeSecurityDescriptor(pSD, SECURITY_DESCRIPTOR_REVISION);
    SetSecurityDescriptorDacl(pSD, TRUE, pACL, FALSE);

    attributes.nLength = sizeof(SECURITY_ATTRIBUTES);
    attributes.lpSecurityDescriptor = pSD;
    attributes.bInheritHandle = FALSE;

    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// IsDACLExplicit
// ══════════════════════════════════════════════════════════════════════════════

bool IsDACLExplicit(const SECURITY_DESCRIPTOR* sd) {
    if (!sd) return false;

    BOOL daclPresent = FALSE;
    BOOL daclDefaulted = FALSE;
    PACL pACL = nullptr;

    if (!GetSecurityDescriptorDacl(const_cast<SECURITY_DESCRIPTOR*>(sd),
                                    &daclPresent, &pACL, &daclDefaulted))
        return false;

    return daclPresent && !daclDefaulted && pACL != nullptr;
}

} // namespace solstream::security
