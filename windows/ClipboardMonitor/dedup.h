#pragma once

/// @file dedup.h
/// Clipboard deduplication engine: seq + hash + origin tracking,
/// format allowlist, and rate limiting.
///
/// Thread safety: NOT thread-safe. All methods must be called from
/// a single thread or serialised externally.

#include <cstdint>
#include <string>
#include <string_view>
#include <unordered_map>
#include <vector>

#include "clipboard_input_protocol.h"

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// ClipboardData
// ══════════════════════════════════════════════════════════════════════════════

/// A single clipboard format + data snapshot.
struct ClipboardFormatData {
    uint32_t formatId;       ///< Windows clipboard format (CF_UNICODETEXT, etc.)
    std::string formatName;  ///< Registered format name (for CFSTR_*)
    std::vector<uint8_t> data;
    uint64_t hash{};         ///< SHA-256 truncated to 64 bits (for dedup)
};

/// Full clipboard snapshot (multiple formats).
struct ClipboardSnapshot {
    uint64_t sequence{};                     ///< Monotonic per-origin
    uint32_t originId{};                     ///< Session-scoped origin
    std::vector<ClipboardFormatData> formats;

    [[nodiscard]] bool IsEmpty() const noexcept { return formats.empty(); }
};

// ══════════════════════════════════════════════════════════════════════════════
// DedupEngine
// ══════════════════════════════════════════════════════════════════════════════
//
// Tracks per-origin sequences and content hashes to suppress loops.
// Implements the spec's dedup rules:
//   - If incoming seq <= last_seen[origin], suppress
//   - If seq is new but hash matches last sent, suppress (loop prevention)
//
class DedupEngine {
public:
    DedupEngine();

    /// Check whether an incoming snapshot should be applied.
    /// Returns true if this is new content (should be forwarded/set).
    [[nodiscard]] bool IsNewContent(const ClipboardSnapshot& snapshot);

    /// Record that a snapshot was sent/applied.
    void RecordSent(const ClipboardSnapshot& snapshot);

    /// Reset all state (on session disconnect / re-pair).
    void Reset();

    // ── Rate limiting ────────────────────────────────────────────────────

    /// Returns true if the operation should be rate-limited.
    [[nodiscard]] bool IsRateLimited();

private:
    struct OriginState {
        uint64_t lastSequence{};
        uint64_t lastHash{};     ///< Hash of last-sent snapshot
    };

    std::unordered_map<uint32_t, OriginState> m_origins;

    // Rate limiting
    uint64_t m_opCount{};
    uint64_t m_windowStart{};
};

// ── Format name resolution ───────────────────────────────────────────────────

/// Convert a Windows clipboard format ID to a human-readable name.
[[nodiscard]] std::string FormatIdToName(uint32_t formatId);

/// Check if a format ID matches one of the allowlisted formats.
[[nodiscard]] bool IsAllowlistedFormat(uint32_t formatId);

/// Compute a 64-bit hash for dedup (truncated SHA-256).
[[nodiscard]] uint64_t ComputeContentHash(std::span<const uint8_t> data);

} // namespace solstream::clipboard
