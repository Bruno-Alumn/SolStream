// window_restore.cpp — see window_restore.h.

#include "window_restore.h"

#include <climits>
#include <cstdlib>

namespace solstream {

long long PlacementDistance(const RECT& wanted, const RECT& got) {
    return llabs((long long) got.left - wanted.left)
         + llabs((long long) got.top - wanted.top)
         + llabs((long long) got.right - wanted.right)
         + llabs((long long) got.bottom - wanted.bottom);
}

int RestorePlacement(const WINDOWPLACEMENT& saved,
                     const std::function<bool(const WINDOWPLACEMENT&)>& set,
                     const std::function<bool(WINDOWPLACEMENT&)>& get,
                     bool* matched) {
    if (matched) { *matched = false; }
    int calls = 0;
    long long best = LLONG_MAX;
    for (int attempt = 0; attempt < kRestorePlacementAttempts; ++attempt) {
        if (!set(saved)) {
            break;
        }
        ++calls;
        WINDOWPLACEMENT now{};
        now.length = sizeof(now);
        if (!get(now)) {
            break;
        }
        const long long distance = PlacementDistance(saved.rcNormalPosition,
                                                     now.rcNormalPosition);
        if (distance == 0) {
            if (matched) { *matched = true; }
            break;
        }
        // No closer than the last try: the application is holding a size of
        // its own, and asking again would land in the same place.
        if (distance >= best) {
            break;
        }
        best = distance;
    }
    return calls;
}

}  // namespace solstream
