#pragma once

/// @file pipe_client_validator.h
/// Validates that the process connecting to InputInjector's named pipe
/// is the legitimate, signed ClipboardMonitor.exe.
///
/// Uses GetNamedPipeClientProcessId + WinVerifyTrust to verify the
/// client's binary signature.

#include <Windows.h>
#include <cstdint>
#include <string>

namespace solstream::input {

// ══════════════════════════════════════════════════════════════════════════════
// PipeClientValidator
// ══════════════════════════════════════════════════════════════════════════════
//
// Verifies:
//   1. The connecting process PID is valid.
//   2. The process binary is signed with the SolStream certificate
//      (WinVerifyTrust succeeds).
//   3. The process creation time is not stale (no PID recycling).
//
class PipeClientValidator {
public:
    PipeClientValidator() = default;

    /// Validate a client connection on the given pipe handle.
    /// Returns true if the client is authenticated.
    /// On success, stores the client's process handle (held open
    /// to prevent PID recycling).
    [[nodiscard]] bool Validate(HANDLE pipeHandle);

    /// Release the held process handle (on disconnect).
    void ReleaseProcess();

    /// Get the validated client PID.
    [[nodiscard]] DWORD GetClientPID() const noexcept { return m_clientPID; }

private:
    /// Verify a binary's digital signature via WinVerifyTrust.
    [[nodiscard]] static bool VerifyBinarySignature(const std::wstring& path);

    HANDLE m_clientProcess{};
    DWORD  m_clientPID{};
    bool   m_validated{false};

    /// Expected process creation time for PID recycling prevention.
    uint64_t m_creationTime{};
};

} // namespace solstream::input
