#include "tls_cert.h"

#include <bcrypt.h>
#include <ncrypt.h>
#include <wincrypt.h>

#include <cstring>
#include <format>
#include <fstream>
#include <span>
#include <sstream>
#include <vector>

#pragma comment(lib, "bcrypt.lib")
#pragma comment(lib, "ncrypt.lib")
#pragma comment(lib, "crypt32.lib")

namespace solstream::security {

// ══════════════════════════════════════════════════════════════════════════════
// PEM encoding helpers
// ══════════════════════════════════════════════════════════════════════════════

namespace {

std::string Base64Encode(const std::vector<uint8_t>& data) {
    DWORD needed = 0;
    CryptBinaryToStringA(data.data(), (DWORD)data.size(),
                         CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                         nullptr, &needed);
    if (needed == 0) return {};

    std::string result(needed, '\0');
    CryptBinaryToStringA(data.data(), (DWORD)data.size(),
                         CRYPT_STRING_BASE64 | CRYPT_STRING_NOCRLF,
                         result.data(), &needed);
    // Remove trailing null.
    while (!result.empty() && result.back() == '\0')
        result.pop_back();
    return result;
}

std::vector<uint8_t> Base64Decode(const std::string& b64) {
    DWORD needed = 0;
    CryptStringToBinaryA(b64.data(), (DWORD)b64.size(),
                         CRYPT_STRING_BASE64, nullptr, &needed,
                         nullptr, nullptr);
    if (needed == 0) return {};

    std::vector<uint8_t> result(needed);
    CryptStringToBinaryA(b64.data(), (DWORD)b64.size(),
                         CRYPT_STRING_BASE64,
                         result.data(), &needed, nullptr, nullptr);
    return result;
}

std::string PemEncode(const std::string& label,
                      const std::vector<uint8_t>& derData)
{
    auto b64 = Base64Encode(derData);

    std::string pem;
    pem += "-----BEGIN " + label + "-----\n";
    // Wrap at 64 characters.
    for (size_t i = 0; i < b64.size(); i += 64)
        pem += b64.substr(i, 64) + "\n";
    pem += "-----END " + label + "-----\n";
    return pem;
}

std::vector<uint8_t> PemDecode(const std::string& pem,
                                const std::string& label)
{
    auto begin = pem.find("-----BEGIN " + label + "-----");
    if (begin == std::string::npos) return {};
    begin = pem.find('\n', begin);
    if (begin == std::string::npos) return {};
    ++begin;

    auto end = pem.find("-----END " + label + "-----");
    if (end == std::string::npos) return {};

    auto b64 = pem.substr(begin, end - begin);
    // Strip newlines.
    b64.erase(std::remove(b64.begin(), b64.end(), '\n'), b64.end());
    b64.erase(std::remove(b64.begin(), b64.end(), '\r'), b64.end());

    return Base64Decode(b64);
}

} // anonymous namespace

// ══════════════════════════════════════════════════════════════════════════════
// Certificate generation
// ══════════════════════════════════════════════════════════════════════════════

bool GenerateSelfSignedCert(
    std::string& certPem, std::string& keyPem,
    const std::wstring& subjectName)
{
    // 1. Create an RSA-2048 key in a temporary key container using NCrypt.
    NCRYPT_PROV_HANDLE hProv{};
    NCRYPT_KEY_HANDLE hKey{};

    SECURITY_STATUS ss = NCryptOpenStorageProvider(&hProv, MS_KEY_STORAGE_PROVIDER, 0);
    if (ss != ERROR_SUCCESS) return false;

    ss = NCryptCreatePersistedKey(hProv, &hKey, NCRYPT_RSA_ALGORITHM,
                                   L"SolStreamTempKey", 0, 0);
    if (ss != ERROR_SUCCESS) { NCryptFreeObject(hProv); return false; }

    DWORD keyLen = 2048;
    NCryptSetProperty(hKey, NCRYPT_LENGTH_PROPERTY,
                      (PBYTE)&keyLen, sizeof(keyLen), 0);
    NCryptFinalizeKey(hKey, 0);

    // 2. Export the public key as a CERT_PUBLIC_KEY_INFO.
    DWORD pubKeyBlobSize = 0;
    NCryptExportKey(hKey, 0, BCRYPT_PUBLIC_KEY_BLOB,
                    nullptr, nullptr, 0, &pubKeyBlobSize, 0);

    std::vector<uint8_t> pubKeyBlob(pubKeyBlobSize);
    NCryptExportKey(hKey, 0, BCRYPT_PUBLIC_KEY_BLOB,
                    nullptr, pubKeyBlob.data(), (DWORD)pubKeyBlob.size(),
                    &pubKeyBlobSize, 0);

    // Convert BCRYPT_RSAKEY_BLOB → CERT_PUBLIC_KEY_INFO.
    CERT_PUBLIC_KEY_INFO pubKeyInfo{};
    DWORD infoSize = sizeof(pubKeyInfo);
    if (!CryptDecodeObjectEx(X509_ASN_ENCODING, X509_PUBLIC_KEY_INFO,
                              pubKeyBlob.data(), (DWORD)pubKeyBlob.size(),
                              CRYPT_DECODE_ALLOC_FLAG, nullptr,
                              &pubKeyInfo, &infoSize))
    { NCryptDeleteKey(hKey); NCryptFreeObject(hProv); return false; }

    // 3. Build the subject name.
    std::wstring subject = L"CN=" + subjectName;
    DWORD subjectSize = (DWORD)(subject.size() + 1) * sizeof(wchar_t);

    // 4. Create the self-signed certificate context.
    // Build CERT_NAME_BLOB from the subject string.
    CERT_NAME_BLOB subjectBlob{};
    if (!CertStrToNameW(X509_ASN_ENCODING, subject.c_str(),
                         CERT_X500_NAME_STR, nullptr,
                         nullptr, &subjectBlob.cbData, nullptr))
    { LocalFree(pubKeyInfo.PublicKey.pbData); NCryptDeleteKey(hKey);
      NCryptFreeObject(hProv); return false; }

    std::vector<uint8_t> subjectEncoded(subjectBlob.cbData);
    CertStrToNameW(X509_ASN_ENCODING, subject.c_str(),
                   CERT_X500_NAME_STR, nullptr,
                   subjectEncoded.data(), &subjectBlob.cbData, nullptr);
    subjectBlob.pbData = subjectEncoded.data();

    // Set validity: 10 years from now.
    SYSTEMTIME now{};
    GetSystemTime(&now);
    FILETIME ftNow{}, ftEnd{};
    SystemTimeToFileTime(&now, &ftNow);

    // Add 10 years.
    ULARGE_INTEGER ui;
    ui.LowPart = ftNow.dwLowDateTime;
    ui.HighPart = ftNow.dwHighDateTime;
    ui.QuadPart += 10ULL * 365 * 24 * 60 * 60 * 10000000ULL;  // 10 years
    ftEnd.dwLowDateTime = ui.LowPart;
    ftEnd.dwHighDateTime = ui.HighPart;

    // Create the certificate.
    PCCERT_CONTEXT pCert = CertCreateSelfSignCertificate(
        hProv, &subjectBlob, 0, nullptr,
        &pubKeyInfo, nullptr, &now, &ftEnd, nullptr);
    if (!pCert)
    { LocalFree(pubKeyInfo.PublicKey.pbData); NCryptDeleteKey(hKey);
      NCryptFreeObject(hProv); return false; }

    // 5. Export certificate to DER.
    DWORD certDerSize = pCert->cbCertEncoded;
    std::vector<uint8_t> certDer(pCert->cbCertEncoded);
    std::memcpy(certDer.data(), pCert->pbCertEncoded, certDerSize);

    // 6. Export private key to PEM.
    DWORD keyBlobSize = 0;
    NCryptExportKey(hKey, 0, NCRYPT_PRIVATE_KEY_BLOB,
                    nullptr, nullptr, 0, &keyBlobSize, 0);
    std::vector<uint8_t> keyBlob(keyBlobSize);
    NCryptExportKey(hKey, 0, NCRYPT_PRIVATE_KEY_BLOB,
                    nullptr, keyBlob.data(), (DWORD)keyBlob.size(),
                    &keyBlobSize, 0);

    // 7. PEM encode both.
    // For CNG private key blobs, we need to wrap them in a PKCS#8 structure.
    // We use the raw private key export; in production this would be PKCS#8.
    // For now, export the key as a PEM-encoded private key via CryptExportPublicKeyInfoEx.
    certPem = PemEncode("CERTIFICATE", certDer);

    // Export private key using the legacy CryptoAPI for PKCS#8 PEM.
    // First export the certificate's associated key context.
    HCRYPTPROV_OR_NCRYPT_KEY_HANDLE hCNGKey = hKey;
    DWORD keySpec = CERT_NCRYPT_KEY_SPEC;
    BOOL bFreeKey = FALSE;

    DWORD pkcs8Size = 0;
    CryptExportPKCS8(hProv, 0, nullptr, nullptr, &pkcs8Size);
    std::vector<uint8_t> pkcs8(pkcs8Size);
    CryptExportPKCS8(hProv, 0, nullptr, pkcs8.data(), &pkcs8Size);

    keyPem = PemEncode("PRIVATE KEY", pkcs8);

    // Cleanup.
    CertFreeCertificateContext(pCert);
    LocalFree(pubKeyInfo.PublicKey.pbData);
    NCryptDeleteKey(hKey);
    NCryptFreeObject(hProv);

    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// File I/O
// ══════════════════════════════════════════════════════════════════════════════

bool SaveCertToFiles(const std::wstring& certPath,
                      const std::wstring& keyPath,
                      const std::string& certPem,
                      const std::string& keyPem)
{
    std::ofstream certFile(certPath);
    if (!certFile) return false;
    certFile << certPem;
    certFile.close();

    std::ofstream keyFile(keyPath);
    if (!keyFile) return false;
    keyFile << keyPem;
    keyFile.close();

    return true;
}

bool LoadCertFromFiles(const std::wstring& certPath,
                        const std::wstring& keyPath,
                        std::string& certPem,
                        std::string& keyPem)
{
    std::ifstream certFile(certPath);
    if (!certFile) return false;
    certPem.assign(std::istreambuf_iterator<char>(certFile),
                    std::istreambuf_iterator<char>());

    std::ifstream keyFile(keyPath);
    if (!keyFile) return false;
    keyPem.assign(std::istreambuf_iterator<char>(keyFile),
                   std::istreambuf_iterator<char>());

    return !certPem.empty() && !keyPem.empty();
}

// ══════════════════════════════════════════════════════════════════════════════
// Fingerprint computation
// ══════════════════════════════════════════════════════════════════════════════

std::vector<uint8_t> ComputeCertFingerprint(const std::string& certPem) {
    // Decode PEM to DER first.
    auto derData = PemDecode(certPem, "CERTIFICATE");
    if (derData.empty()) return {};

    // SHA-256 hash.
    HCRYPTPROV hProv{};
    if (!CryptAcquireContextW(&hProv, nullptr, nullptr,
                               PROV_RSA_AES, CRYPT_VERIFYCONTEXT))
        return {};

    HCRYPTHASH hHash{};
    CryptCreateHash(hProv, CALG_SHA_256, 0, 0, &hHash);

    std::vector<uint8_t> fp(32);
    DWORD fpSize = (DWORD)fp.size();

    CryptHashData(hHash, derData.data(), (DWORD)derData.size(), 0);
    CryptGetHashParam(hHash, HP_HASHVAL, fp.data(), &fpSize, 0);

    CryptDestroyHash(hHash);
    CryptReleaseContext(hProv, 0);

    fp.resize(fpSize);
    return fp;
}

} // namespace solstream::security
