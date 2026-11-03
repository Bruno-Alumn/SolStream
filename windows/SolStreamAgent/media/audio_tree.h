// audio_tree.h — which streamed apps' sound to capture, given who started whom.
//
// Windows captures an app's sound together with everything it started
// (PROCESS_LOOPBACK_MODE_INCLUDE_TARGET_PROCESS_TREE; there is no mode for the
// app alone). So two streamed apps where one started the other -- Steam and a
// game launched from it -- were both captured, and the second was heard twice,
// 6 dB louder and clipping. Kept apart from audio.cpp to be tested.

#pragma once

#include <algorithm>
#include <cstdint>
#include <map>
#include <vector>

namespace solstream::media {

/// A process, as a snapshot of all of them gives it: its parent, and when it
/// started (any steady unit), since a parent id outlives its process and can
/// come back as another's -- a "parent" that started after its child is not.
struct ProcessEntry {
    uint32_t parent = 0;
    uint64_t started = 0;
};

/// `wanted`, less any whose ancestor is in it: that ancestor's capture already
/// includes them. Sorted, as `wanted` is.
inline std::vector<uint32_t> WithoutDescendants(const std::vector<uint32_t>& wanted,
                                                const std::map<uint32_t, ProcessEntry>& all) {
    std::vector<uint32_t> kept;
    for (uint32_t pid : wanted) {
        bool covered = false;
        uint32_t at = pid;
        // A chain is short; the bound is for a snapshot that loops.
        for (int depth = 0; depth < 64 && !covered; ++depth) {
            const auto self = all.find(at);
            if (self == all.end()) { break; }
            const uint32_t parent = self->second.parent;
            const auto up = all.find(parent);
            // Back round to itself: a loop in a snapshot, not an ancestor.
            if (parent == 0 || parent == at || parent == pid || up == all.end()
                || up->second.started > self->second.started) {
                break;
            }
            covered = std::binary_search(wanted.begin(), wanted.end(), parent);
            at = parent;
        }
        if (!covered) { kept.push_back(pid); }
    }
    return kept;
}

}  // namespace solstream::media
