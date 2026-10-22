// window_restore.cpp — see window_restore.h.

#include "window_restore.h"

#include <cerrno>
#include <climits>
#include <cstdlib>
#include <sstream>

namespace solstream {

namespace {

/// The first line of the record. A record without it -- anything else that
/// happens to be at that path, or a future format -- is not read at all.
constexpr char kOwedHeader[] = "SolStream owed windows 1";

/// The numbers on one window's line, in order.
constexpr int kOwedFields = 14;

}  // namespace

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

std::string FormatOwedWindows(const std::vector<OwedWindow>& windows) {
    std::ostringstream out;
    out << kOwedHeader << "\n";
    for (const OwedWindow& owed : windows) {
        const WINDOWPLACEMENT& p = owed.placement;
        out << owed.window << ' ' << owed.pid << ' ' << owed.removed_style << ' '
            << (owed.topmost ? 1 : 0) << ' '
            << p.flags << ' ' << p.showCmd << ' '
            << p.ptMinPosition.x << ' ' << p.ptMinPosition.y << ' '
            << p.ptMaxPosition.x << ' ' << p.ptMaxPosition.y << ' '
            << p.rcNormalPosition.left << ' ' << p.rcNormalPosition.top << ' '
            << p.rcNormalPosition.right << ' ' << p.rcNormalPosition.bottom << "\n";
    }
    return out.str();
}

std::vector<OwedWindow> ParseOwedWindows(const std::string& text) {
    std::vector<OwedWindow> windows;
    std::istringstream in(text);
    std::string line;
    if (!std::getline(in, line)) {
        return windows;
    }
    if (!line.empty() && line.back() == '\r') { line.pop_back(); }
    if (line != kOwedHeader) {
        return windows;
    }
    while (std::getline(in, line)) {
        // Every field as a signed 64-bit number first, so a negative or
        // oversized one is caught by the range checks below rather than
        // wrapping silently into a plausible value.
        long long field[kOwedFields] = {};
        const char* cursor = line.c_str();
        int count = 0;
        bool whole = true;
        while (count < kOwedFields) {
            while (*cursor == ' ') { ++cursor; }
            if (*cursor == '\0' || *cursor == '\r') {
                break;
            }
            char* end = nullptr;
            errno = 0;
            const long long value = std::strtoll(cursor, &end, 10);
            if (end == cursor || errno != 0 || (*end != ' ' && *end != '\0' && *end != '\r')) {
                whole = false;
                break;
            }
            field[count++] = value;
            cursor = end;
        }
        while (*cursor == ' ' || *cursor == '\r') { ++cursor; }
        if (!whole || count != kOwedFields || *cursor != '\0') {
            continue;
        }
        auto in_range = [](long long value, long long low, long long high) {
            return value >= low && value <= high;
        };
        // A window handle is 32 significant bits even in a 64-bit process.
        if (!in_range(field[0], 1, 0xFFFFFFFFLL) || !in_range(field[1], 1, 0xFFFFFFFFLL)
            || !in_range(field[2], 0, 0xFFFFFFFFLL) || !in_range(field[3], 0, 1)
            || !in_range(field[4], 0, 0xFFFF) || !in_range(field[5], 0, 11)) {
            continue;
        }
        bool coordinates = true;
        for (int i = 6; i < kOwedFields; ++i) {
            coordinates = coordinates && in_range(field[i], INT_MIN, INT_MAX);
        }
        if (!coordinates) {
            continue;
        }
        OwedWindow owed;
        owed.window = (uint64_t) field[0];
        owed.pid = (uint32_t) field[1];
        owed.removed_style = (uint64_t) field[2];
        owed.topmost = field[3] != 0;
        WINDOWPLACEMENT& p = owed.placement;
        p.length = sizeof(WINDOWPLACEMENT);
        p.flags = (UINT) field[4];
        p.showCmd = (UINT) field[5];
        p.ptMinPosition = POINT{(LONG) field[6], (LONG) field[7]};
        p.ptMaxPosition = POINT{(LONG) field[8], (LONG) field[9]};
        p.rcNormalPosition = RECT{(LONG) field[10], (LONG) field[11],
                                  (LONG) field[12], (LONG) field[13]};
        if (p.rcNormalPosition.right <= p.rcNormalPosition.left
            || p.rcNormalPosition.bottom <= p.rcNormalPosition.top) {
            continue;
        }
        windows.push_back(owed);
    }
    return windows;
}

bool SaveOwedWindows(const std::wstring& path, const std::vector<OwedWindow>& windows) {
    if (path.empty()) {
        return false;
    }
    if (windows.empty()) {
        return DeleteFileW(path.c_str()) || GetLastError() == ERROR_FILE_NOT_FOUND;
    }
    // Written beside it and moved over it, so a host killed mid-write -- the
    // very case this record is for -- leaves the last whole record rather than
    // half of a new one.
    const std::wstring temporary = path + L".new";
    HANDLE file = CreateFileW(temporary.c_str(), GENERIC_WRITE, 0, nullptr,
                              CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return false;
    }
    const std::string text = FormatOwedWindows(windows);
    DWORD written = 0;
    const bool wrote = WriteFile(file, text.data(), (DWORD) text.size(), &written, nullptr)
                    && written == text.size();
    CloseHandle(file);
    if (!wrote || !MoveFileExW(temporary.c_str(), path.c_str(), MOVEFILE_REPLACE_EXISTING)) {
        DeleteFileW(temporary.c_str());
        return false;
    }
    return true;
}

std::vector<OwedWindow> LoadOwedWindows(const std::wstring& path) {
    if (path.empty()) {
        return {};
    }
    HANDLE file = CreateFileW(path.c_str(), GENERIC_READ, FILE_SHARE_READ, nullptr,
                              OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, nullptr);
    if (file == INVALID_HANDLE_VALUE) {
        return {};
    }
    // Eight windows of a line each is well under this; anything longer is not
    // a record this host wrote.
    std::string text(64 * 1024, '\0');
    DWORD read = 0;
    const bool ok = ReadFile(file, text.data(), (DWORD) text.size(), &read, nullptr);
    CloseHandle(file);
    if (!ok) {
        return {};
    }
    text.resize(read);
    return ParseOwedWindows(text);
}

}  // namespace solstream
