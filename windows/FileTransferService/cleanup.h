#pragma once

/// @file cleanup.h
/// Manages session-scoped transfer directories, orphan file sweeping,
/// per-session quotas, and upload accounting.
///
/// Thread safety: all public methods are thread-safe (internal mutex).

#include <Windows.h>
#include <cstdint>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

namespace solstream::filetransfer {

// ── Session tracking ────────────────────────────────────────────────────────

struct SessionInfo {
    std::wstring sessionId;
    uint64_t     totalBytes{};        ///< Committed bytes
    uint64_t     reservedBytes{};     ///< Bytes reserved by active uploads
    uint64_t     fileCount{};         ///< Number of committed files
    uint64_t     createdAt{};         ///< nanoseconds (steady_clock)
    uint64_t     lastActivity{};      ///< nanoseconds (steady_clock)
    uint32_t     activeUploads{};     ///< Currently reserving uploads
};

// ── CleanupEngine ────────────────────────────────────────────────────────────
//
// Tracks active sessions, enforces per-session quotas, and runs periodic
// orphan sweeps. Sessions inactive for kOrphanTTL are eligible for sweep.
//
class CleanupEngine {
public:
    CleanupEngine();
    ~CleanupEngine();

    CleanupEngine(const CleanupEngine&) = delete;
    CleanupEngine& operator=(const CleanupEngine&) = delete;

    /// Register a new session.  Creates the session directory under
    /// TransferRoot().  Returns false if the session already exists
    /// or the sessionId is invalid.
    [[nodiscard]] bool CreateSession(const std::wstring& sessionId);

    /// Remove a session and all its files.  First deletes files from
    /// disk, then removes the session from tracking.  Safe to call
    /// on a non-existent or already-removed session.
    void RemoveSession(const std::wstring& sessionId);

    /// Check that a new file of the given size fits within the session
    /// quota and concurrency limit.  On success, increments reservedBytes
    /// and activeUploads; caller must call CommitFile() or RollbackUpload().
    [[nodiscard]] bool ReserveUpload(const std::wstring& sessionId,
                                      uint64_t fileSize);

    /// Commit a completed upload — adds file to session totals and
    /// decrements reservedBytes and activeUploads.
    void CommitFile(const std::wstring& sessionId, uint64_t fileSize);

    /// Roll back a reserved upload (on failure).
    void RollbackUpload(const std::wstring& sessionId);

    /// Run an orphan sweep: remove sessions with no active uploads
    /// that have been inactive for longer than kOrphanTTL, and sessions
    /// older than kSessionMaxAge even if active.
    void SweepOrphans();

    /// Get the list of active session IDs.
    [[nodiscard]] std::vector<std::wstring> GetActiveSessions() const;

    // ── Constants ────────────────────────────────────────────────────────
    static constexpr uint64_t kOrphanTTLSec    = 5 * 60;     // 5 minutes
    static constexpr uint64_t kSessionMaxAgeSec = 3600;       // 1 hour
    static constexpr uint64_t kSweepIntervalSec = 300;        // 5 minutes

private:
    mutable std::mutex m_mutex;
    std::unordered_map<std::wstring, SessionInfo> m_sessions;

    // Delete a directory recursively.  Must NOT be called while holding
    // m_mutex (it blocks for I/O).
    static bool RecursiveDelete(const std::wstring& dir);

    // Determine the steady-clock timestamp in nanoseconds.
    static uint64_t Now() noexcept;
};

} // namespace solstream::filetransfer
