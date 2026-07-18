#pragma once

/// @file path_validator.h
/// Safe path canonicalisation via GetFinalPathNameByHandleW.
/// Detects symlink/junction escape attacks and TOCTOU races.
///
/// Thread safety: all functions are thread-safe (stateless).

#ifndef WIN32_LEAN_AND_MEAN
#define WIN32_LEAN_AND_MEAN
#endif
#include <Windows.h>

#include <cstdint>
#include <string>
#include <string_view>

namespace solstream::filetransfer {

// ── Constants ───────────────────────────────────────────────────────────────

/// Root directory for all transfers. Files must reside here.
/// Created on first call.  Returns the canonical path (resolved via
/// GetFinalPathNameByHandleW on a handle to the root directory itself).
[[nodiscard]] const std::wstring& TransferRoot();

/// Maximum file size: 2 GiB.
constexpr uint64_t kMaxFileSize = 2ULL * 1024 * 1024 * 1024;

/// Maximum concurrent uploads per session.
constexpr uint32_t kMaxConcurrentUploads = 3;

/// Per-session total quota: 10 GiB.
constexpr uint64_t kSessionQuota = 10ULL * 1024 * 1024 * 1024;

// ── Sanitisation ────────────────────────────────────────────────────────────

/// Validate a session ID string.  Rejects empty strings, strings
/// containing path separators (/ \), parent-directory tokens (..),
/// or Windows reserved device names (CON, NUL, etc.).
/// @return True if the session ID is safe to use in a filesystem path.
[[nodiscard]] bool IsValidSessionId(const std::wstring& sessionId);

/// Validate a file name.  Rejects empty names, names containing path
/// separators (/ \), parent-directory tokens (..), ADS syntax (:),
/// Windows reserved device names (including with extensions like
/// CON.txt, NUL.log), and trailing dots/spaces.
/// @return True if the name is safe for use as a single file component.
[[nodiscard]] bool IsValidFileName(const std::wstring& fileName);

/// Validate a file extension (including the leading dot).
/// Rejects empty extensions, extensions containing path separators,
/// parent tokens, or ADS syntax.
[[nodiscard]] bool IsValidExtension(const std::wstring& extension);

// ── Path validation ─────────────────────────────────────────────────────────

/// Canonicalize a file path and verify it is inside the transfer root.
/// Opens the file normally (without OPEN_REPARSE_POINT) so that any
/// symlink/junction is followed and the *target* path is validated.
///
/// @param absolutePath  The absolute path to validate (must exist).
/// @return True if the path is valid and inside TransferRoot().
[[nodiscard]] bool ValidateFilePath(const std::wstring& absolutePath);

/// Create a safe staging path under TransferRoot() and reserve it
/// atomically (CREATE_NEW).  The path is:
///   TransferRoot() + sessionId + L"\\stage\\" + UUID + extension
///
/// @param sessionId  Pre-validated session identifier.
/// @param extension  File extension including dot (e.g. L".tmp").
/// @return Full path to the newly created empty staging file, or
///         empty on failure.
[[nodiscard]] std::wstring CreateStagingPath(
    const std::wstring& sessionId,
    const std::wstring& extension = L".tmp");

/// Atomically rename a staging file to its final name inside the
/// session's output directory.  Both sessionId and finalName must
/// already have passed IsValidSessionId / IsValidFileName checks.
/// The final path is validated before the rename occurs, and the
/// rename uses MOVEFILE_REPLACE_EXISTING only when a prior transfer
/// with the same name existed.
///
/// @param stagingPath  Full path to the staged file.
/// @param finalName    Pre-validated final filename (not full path).
/// @param sessionId    Pre-validated session identifier.
/// @return Full path to the final validated file, or empty on failure.
///         On failure no persistent side-effect occurs (rename is not
///         attempted unless validation passes).
[[nodiscard]] std::wstring AtomicFinalize(
    const std::wstring& stagingPath,
    const std::wstring& finalName,
    const std::wstring& sessionId);

/// Generate a UUID string for staging file names.
[[nodiscard]] std::wstring GenerateUUID();

} // namespace solstream::filetransfer
