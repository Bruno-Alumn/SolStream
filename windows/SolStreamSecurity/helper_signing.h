#pragma once

/// @file helper_signing.h
/// Helper binary signature verification via WinVerifyTrust and
/// GetPublisherCertificate. Used by Sunshine to verify helper
/// EXEs before spawning them.
///
/// Thread safety: all functions are thread-safe (stateless).

#include <Windows.h>
#include <cstdint>
#include <string>

namespace solstream::security {

// ── Helper signature verification ──────────────────────────────────────────

/// Verify that a binary is digitally signed with a trusted certificate.
/// Uses WinVerifyTrust with the GENERIC_VERIFY_V2 policy.
/// @param binaryPath  Full path to the EXE or DLL.
/// @return True if the signature is valid and trusted.
[[nodiscard]] bool VerifyHelperSignature(const std::wstring& binaryPath);

/// Verify that a binary is signed by the expected publisher.
/// Extracts the publisher name from the signing certificate and
/// compares it against the expected name.
/// @param binaryPath     Full path to the binary.
/// @param expectedCN     Expected Common Name (e.g. L"SolStream").
/// @return True if publisher matches.
[[nodiscard]] bool VerifyPublisher(
    const std::wstring& binaryPath,
    const std::wstring& expectedCN);

/// Check if a file has any digital signature at all (even untrusted).
[[nodiscard]] bool HasSignature(const std::wstring& binaryPath);

} // namespace solstream::security
