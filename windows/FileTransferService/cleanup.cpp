#include "cleanup.h"
#include "path_validator.h"

#include <shellapi.h>

#include <algorithm>
#include <chrono>
#include <string>
#include <utility>

#pragma comment(lib, "shell32.lib")

namespace solstream::filetransfer {

// ══════════════════════════════════════════════════════════════════════════════
// Helpers
// ══════════════════════════════════════════════════════════════════════════════

uint64_t CleanupEngine::Now() noexcept {
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        std::chrono::steady_clock::now().time_since_epoch()).count();
}

// ══════════════════════════════════════════════════════════════════════════════
// Construction / Destruction
// ══════════════════════════════════════════════════════════════════════════════

CleanupEngine::CleanupEngine() = default;

CleanupEngine::~CleanupEngine() {
    // Best-effort cleanup of all session directories on shutdown.
    for (auto& [id, _] : m_sessions) {
        RecursiveDelete(TransferRoot() + id);
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// Session management
// ══════════════════════════════════════════════════════════════════════════════

bool CleanupEngine::CreateSession(const std::wstring& sessionId) {
    if (!IsValidSessionId(sessionId))
        return false;

    std::unique_lock lk(m_mutex);

    if (m_sessions.count(sessionId))
        return false;

    // Create the session directory.  Must not already exist as anything.
    std::wstring dir = TransferRoot() + sessionId;
    if (!CreateDirectoryW(dir.c_str(), nullptr))
        return false;

    SessionInfo info{};
    info.sessionId = sessionId;
    info.createdAt = Now();
    info.lastActivity = info.createdAt;
    m_sessions[sessionId] = std::move(info);
    return true;
}

void CleanupEngine::RemoveSession(const std::wstring& sessionId) {
    // Delete the directory first (while the session still exists in the
    // map, preventing a concurrent CreateSession from reusing the ID).
    std::wstring dir;
    {
        std::lock_guard lk(m_mutex);
        auto it = m_sessions.find(sessionId);
        if (it == m_sessions.end())
            return;
        dir = TransferRoot() + sessionId;
    }

    // Delete outside the lock (filesystem I/O).
    RecursiveDelete(dir);

    // Now remove from tracking.
    std::lock_guard lk(m_mutex);
    m_sessions.erase(sessionId);
}

// ══════════════════════════════════════════════════════════════════════════════
// Upload accounting
// ══════════════════════════════════════════════════════════════════════════════

bool CleanupEngine::ReserveUpload(const std::wstring& sessionId,
                                   uint64_t fileSize)
{
    std::lock_guard lk(m_mutex);

    auto it = m_sessions.find(sessionId);
    if (it == m_sessions.end())
        return false;

    auto& info = it->second;

    // Check per-file size limit.
    if (fileSize > kMaxFileSize)
        return false;

    // Check concurrent upload limit.
    if (info.activeUploads >= kMaxConcurrentUploads)
        return false;

    // Check per-session quota (committed + reserved).
    if (info.totalBytes + info.reservedBytes + fileSize > kSessionQuota)
        return false;

    info.activeUploads++;
    info.reservedBytes += fileSize;
    info.lastActivity = Now();
    return true;
}

void CleanupEngine::CommitFile(const std::wstring& sessionId,
                                uint64_t fileSize)
{
    std::lock_guard lk(m_mutex);

    auto it = m_sessions.find(sessionId);
    if (it == m_sessions.end())
        return;

    auto& info = it->second;
    if (info.activeUploads == 0)
        return;  // No matching reservation

    info.totalBytes += fileSize;
    if (info.reservedBytes >= fileSize)
        info.reservedBytes -= fileSize;
    else
        info.reservedBytes = 0;
    info.fileCount++;
    info.activeUploads--;
    info.lastActivity = Now();
}

void CleanupEngine::RollbackUpload(const std::wstring& sessionId) {
    std::lock_guard lk(m_mutex);

    auto it = m_sessions.find(sessionId);
    if (it == m_sessions.end())
        return;

    auto& info = it->second;
    if (info.activeUploads == 0)
        return;

    info.activeUploads--;
    info.reservedBytes = 0;  // Conservative: clear all reservations
    info.lastActivity = Now();
}

// ══════════════════════════════════════════════════════════════════════════════
// Orphan sweep
// ══════════════════════════════════════════════════════════════════════════════

void CleanupEngine::SweepOrphans() {
    auto now = Now();
    auto ttlNs = kOrphanTTLSec * 1'000'000'000ULL;
    auto maxAgeNs = kSessionMaxAgeSec * 1'000'000'000ULL;

    std::vector<std::wstring> toRemove;

    // Collect candidates under lock.
    {
        std::lock_guard lk(m_mutex);
        for (auto& [id, info] : m_sessions) {
            // Sessions over max age are removed regardless of activity.
            if ((now - info.createdAt) > maxAgeNs) {
                toRemove.push_back(id);
                continue;
            }
            // Sessions inactive past TTL with no active uploads.
            if ((now - info.lastActivity) > ttlNs && info.activeUploads == 0) {
                toRemove.push_back(id);
            }
        }
    }

    // Remove each candidate — RecursiveDelete is outside the lock.
    for (const auto& id : toRemove) {
        RemoveSession(id);
    }
}

std::vector<std::wstring> CleanupEngine::GetActiveSessions() const {
    std::lock_guard lk(m_mutex);
    std::vector<std::wstring> ids;
    ids.reserve(m_sessions.size());
    for (const auto& [id, _] : m_sessions)
        ids.push_back(id);
    return ids;
}

// ══════════════════════════════════════════════════════════════════════════════
// Recursive delete
// ══════════════════════════════════════════════════════════════════════════════

bool CleanupEngine::RecursiveDelete(const std::wstring& dir) {
    if (dir.empty())
        return false;

    // Use SHFileOperation for reliable recursive delete.
    // Build a double-null-terminated path with wildcard.
    SHFILEOPSTRUCTW op{};
    op.wFunc = FO_DELETE;
    op.fFlags = FOF_NO_UI | FOF_SILENT | FOF_NOCONFIRMATION;

    std::wstring searchPath = dir;
    if (searchPath.back() != L'\\')
        searchPath += L'\\';
    searchPath += L'*';
    searchPath.push_back(L'\0');  // Double null for SHFileOperation
    searchPath.push_back(L'\0');
    op.pFrom = searchPath.c_str();

    int result = SHFileOperationW(&op);
    if (result != 0)
        return false;

    // Delete the directory itself.
    return RemoveDirectoryW(dir.c_str()) != FALSE;
}

} // namespace solstream::filetransfer
