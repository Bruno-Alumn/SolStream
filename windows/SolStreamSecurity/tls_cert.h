#pragma once

/// @file tls_cert.h
/// Self-signed TLS certificate generation using BCrypt (CNG).
/// Generates a 2048-bit RSA key pair and self-signed X.509 certificate
/// with SHA-256 signature. Certificate is stored in PEM format.
///
/// Thread safety: all functions are thread-safe (stateless).

#include <Windows.h>
#include <cstdint>
#include <string>
#include <vector>

namespace solstream::security {

// ── TLS certificate generation ──────────────────────────────────────────────

/// Generate a self-signed TLS certificate and private key.
/// Uses BCrypt CNG for RSA-2048 key generation and certificate creation.
///
/// @param certPem  Output: PEM-encoded certificate.
/// @param keyPem   Output: PEM-encoded private key.
/// @param subjectName  Subject CN (e.g. L"SolStream").
/// @return True on success.
[[nodiscard]] bool GenerateSelfSignedCert(
    std::string& certPem,
    std::string& keyPem,
    const std::wstring& subjectName = L"SolStream");

/// Save certificate and key to files.
/// @param certPath  Path for .pem certificate file.
/// @param keyPath   Path for .pem key file.
/// @return True on success.
[[nodiscard]] bool SaveCertToFiles(
    const std::wstring& certPath,
    const std::wstring& keyPath,
    const std::string& certPem,
    const std::string& keyPem);

/// Load certificate and key from files.
[[nodiscard]] bool LoadCertFromFiles(
    const std::wstring& certPath,
    const std::wstring& keyPath,
    std::string& certPem,
    std::string& keyPem);

/// Compute SHA-256 fingerprint of a PEM certificate.
/// Returns 32 bytes of the SHA-256 hash.
[[nodiscard]] std::vector<uint8_t> ComputeCertFingerprint(
    const std::string& certPem);

} // namespace solstream::security
