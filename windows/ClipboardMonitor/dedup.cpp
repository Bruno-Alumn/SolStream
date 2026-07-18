#include "dedup.h"

#include <algorithm>
#include <array>
#include <chrono>
#include <cstddef>
#include <cstring>
#include <span>

#define WIN32_LEAN_AND_MEAN
#include <Windows.h>

namespace solstream::clipboard {

// ══════════════════════════════════════════════════════════════════════════════
// Helper: FNV-1a 64-bit hash (fast, no crypto dependency for dedup)
// ══════════════════════════════════════════════════════════════════════════════

static uint64_t Fnv1a64(std::span<const uint8_t> data) noexcept {
    uint64_t hash = 0xCBF29CE484222325ULL;
    for (auto b : data) {
        hash ^= static_cast<uint64_t>(b);
        hash *= 0x100000001B3ULL;
    }
    return hash;
}

uint64_t ComputeContentHash(std::span<const uint8_t> data) {
    return Fnv1a64(data);
}

// ══════════════════════════════════════════════════════════════════════════════
// Format identification
// ══════════════════════════════════════════════════════════════════════════════

std::string FormatIdToName(uint32_t formatId) {
    // Standard clipboard formats.
    switch (formatId) {
    case CF_TEXT:            return "CF_TEXT";
    case CF_BITMAP:          return "CF_BITMAP";
    case CF_METAFILEPICT:    return "CF_METAFILEPICT";
    case CF_SYLK:            return "CF_SYLK";
    case CF_DIF:             return "CF_DIF";
    case CF_TIFF:            return "CF_TIFF";
    case CF_OEMTEXT:         return "CF_OEMTEXT";
    case CF_DIB:             return "CF_DIB";
    case CF_PALETTE:         return "CF_PALETTE";
    case CF_PENDATA:         return "CF_PENDATA";
    case CF_RIFF:            return "CF_RIFF";
    case CF_WAVE:            return "CF_WAVE";
    case CF_UNICODETEXT:     return "CF_UNICODETEXT";
    case CF_ENHMETAFILE:     return "CF_ENHMETAFILE";
    case CF_HDROP:           return "CF_HDROP";
    case CF_LOCALE:          return "CF_LOCALE";
    case CF_DIBV5:           return "CF_DIBV5";
    default: {
        // Registered format — try to get the name from the system.
        wchar_t nameBuf[256]{};
        if (GetClipboardFormatNameW(formatId, nameBuf,
                                     static_cast<int>(std::size(nameBuf)))) {
            int len = WideCharToMultiByte(CP_UTF8, 0, nameBuf, -1,
                                          nullptr, 0, nullptr, nullptr);
            if (len > 0) {
                std::string utf8(static_cast<size_t>(len - 1), '\0');
                WideCharToMultiByte(CP_UTF8, 0, nameBuf, -1,
                                    utf8.data(), len, nullptr, nullptr);
                return utf8;
            }
        }
        return "CF_(" + std::to_string(formatId) + ")";
    }
    }
}

bool IsAllowlistedFormat(uint32_t formatId) {
    switch (formatId) {
    case CF_TEXT:
    case CF_UNICODETEXT:
    case CF_HDROP:
    case CF_DIB:
        return true;
    default: {
        // Check for registered clipboard format names.
        wchar_t nameBuf[64]{};
        if (GetClipboardFormatNameW(formatId, nameBuf,
                                     static_cast<int>(std::size(nameBuf)))) {
            // Compare case-insensitively.
            std::array<const wchar_t*, 1> allowed = {
                L"CFSTR_FILECONTENTS"
            };
            for (auto a : allowed) {
                if (_wcsicmp(nameBuf, a) == 0)
                    return true;
            }
        }
        return false;
    }
    }
}

// ══════════════════════════════════════════════════════════════════════════════
// DedupEngine
// ══════════════════════════════════════════════════════════════════════════════

DedupEngine::DedupEngine() {
    m_windowStart = static_cast<uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
}

bool DedupEngine::IsNewContent(const ClipboardSnapshot& snapshot) {
    // Fast path: no origin tracking yet → always new.
    auto it = m_origins.find(snapshot.originId);
    if (it == m_origins.end())
        return true;

    // Rule 1: suppress if seq not strictly greater.
    if (snapshot.sequence <= it->second.lastSequence)
        return false;

    // Rule 2: suppress if hash matches last-sent snapshot (loop prevention).
    if (!snapshot.formats.empty()) {
        uint64_t combinedHash = 0;
        for (const auto& fmt : snapshot.formats)
            combinedHash ^= fmt.hash;

        if (combinedHash == it->second.lastHash)
            return false;
    }

    return true;
}

void DedupEngine::RecordSent(const ClipboardSnapshot& snapshot) {
    auto& state = m_origins[snapshot.originId];
    state.lastSequence = snapshot.sequence;

    // Compute combined hash.
    uint64_t combinedHash = 0;
    for (const auto& fmt : snapshot.formats)
        combinedHash ^= fmt.hash;
    state.lastHash = combinedHash;
}

void DedupEngine::Reset() {
    m_origins.clear();
    m_opCount = 0;
    m_windowStart = static_cast<uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
}

bool DedupEngine::IsRateLimited() {
    auto now = static_cast<uint64_t>(
        std::chrono::steady_clock::now().time_since_epoch().count());
    auto elapsed = (now - m_windowStart) / 1'000'000'000ULL;  // nanoseconds → sec

    if (elapsed >= 1) {
        // Reset window.
        m_opCount = 1;
        m_windowStart = now;
        return false;
    }

    ++m_opCount;
    return m_opCount > kMaxOpsPerSecond;
}

bool DedupEngine::IsFormatAllowed(uint32_t formatId) {
    return IsAllowlistedFormat(formatId);
}

bool DedupEngine::IsSizeAllowed(const ClipboardFormatData& fmt) {
    return fmt.data.size() <= kMaxBytesPerFormat;
}

} // namespace solstream::clipboard
