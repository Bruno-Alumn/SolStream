#pragma once

/// @file pipe_acl.h
/// SECURITY_ATTRIBUTES builder for named pipe ACL hardening.
/// Enforces PIPE_REJECT_REMOTE_CLIENTS, explicit DACL with process-
/// specific SID, and prohibition of NullDACL.
///
/// Thread safety: all functions are thread-safe (stateless).

#include <Windows.h>
#include <cstdint>
#include <string>

namespace solstream::security {

// ── Named pipe ACL ──────────────────────────────────────────────────────────

/// Build a SECURITY_ATTRIBUTES with an explicit DACL that:
///   - Allows only the specified process SID
///   - Denies Everyone, Network, Anonymous Logon
///   - Includes PIPE_REJECT_REMOTE_CLIENTS flag
///
/// @param targetPID  PID of the allowed connecting process.
/// @param attributes Output: populated SECURITY_ATTRIBUTES.
///                   The caller must free lpSecurityDescriptor via
///                   LocalFree() after use.
/// @return True on success.
[[nodiscard]] bool BuildRestrictivePipeACL(
    DWORD targetPID,
    SECURITY_ATTRIBUTES& attributes);

/// Build a SECURITY_ATTRIBUTES that allows only the current process
/// (for self-pipe or intra-process communication).
[[nodiscard]] bool BuildSelfOnlyPipeACL(
    SECURITY_ATTRIBUTES& attributes);

/// Verify that a SECURITY_DESCRIPTOR is not NullDACL.
/// Returns true if the DACL is explicitly set and non-null.
[[nodiscard]] bool IsDACLExplicit(const SECURITY_DESCRIPTOR* sd);

} // namespace solstream::security
