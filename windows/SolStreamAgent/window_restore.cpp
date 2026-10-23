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
constexpr char kOwedHeader[] = "SolStream owed windows 2";

/// The numbers on one window's line, in order.
constexpr int kOwedFields = 15;

/// Up to `count` whole numbers separated by spaces, and nothing else on the
/// line. Signed 64-bit, so a negative or oversized one is caught by the range
/// checks of whoever asked rather than wrapping into a plausible value. Field
/// 0 of a window line is the handle, which fits; anything past LLONG_MAX fails.
bool ReadNumbers(const std::string& line, long long* field, int count) {
    const char* cursor = line.c_str();
    int got = 0;
    while (got < count) {
        while (*cursor == ' ') { ++cursor; }
        if (*cursor == '\0' || *cursor == '\r') {
            break;
        }
        char* end = nullptr;
        errno = 0;
        const long long value = std::strtoll(cursor, &end, 10);
        if (end == cursor || errno != 0 || (*end != ' ' && *end != '\0' && *end != '\r')) {
            return false;
        }
        field[got++] = value;
        cursor = end;
    }
    while (*cursor == ' ' || *cursor == '\r') { ++cursor; }
    return got == count && *cursor == '\0';
}

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

WINDOWPLACEMENT PlacementForRestore(const WINDOWPLACEMENT& saved, bool visible) {
    WINDOWPLACEMENT placement = saved;
    if (!visible) {
        placement.showCmd = SW_HIDE;
    }
    return placement;
}

uint64_t BootSecond(uint64_t filetime_now, uint64_t tick_ms) {
    const uint64_t now = filetime_now / 10000000ull;
    const uint64_t up = tick_ms / 1000ull;
    return now > up ? now - up : 0;
}

bool RecordIsFromThisBoot(const OwedRecord& record, uint64_t boot_second, uint64_t tick_ms) {
    if (record.boot == 0 || boot_second == 0) {
        return false;
    }
    const uint64_t apart = record.boot > boot_second ? record.boot - boot_second
                                                     : boot_second - record.boot;
    return apart <= kBootSlackSeconds && record.written <= tick_ms;
}

std::string FormatOwedWindows(const OwedRecord& record) {
    std::ostringstream out;
    out << kOwedHeader << "\n";
    out << record.boot << ' ' << record.written << "\n";
    for (const OwedWindow& owed : record.windows) {
        const WINDOWPLACEMENT& p = owed.placement;
        out << owed.window << ' ' << owed.pid << ' ' << owed.process_created << ' '
            << owed.removed_style << ' ' << (owed.topmost ? 1 : 0) << ' '
            << p.flags << ' ' << p.showCmd << ' '
            << p.ptMinPosition.x << ' ' << p.ptMinPosition.y << ' '
            << p.ptMaxPosition.x << ' ' << p.ptMaxPosition.y << ' '
            << p.rcNormalPosition.left << ' ' << p.rcNormalPosition.top << ' '
            << p.rcNormalPosition.right << ' ' << p.rcNormalPosition.bottom << "\n";
    }
    return out.str();
}

OwedRecord ParseOwedWindows(const std::string& text) {
    OwedRecord record;
    std::istringstream in(text);
    std::string line;
    if (!std::getline(in, line)) {
        return record;
    }
    if (!line.empty() && line.back() == '\r') { line.pop_back(); }
    if (line != kOwedHeader) {
        return record;
    }
    long long when[2] = {};
    if (!std::getline(in, line) || !ReadNumbers(line, when, 2) || when[0] <= 0 || when[1] < 0) {
        return record;
    }
    record.boot = (uint64_t) when[0];
    record.written = (uint64_t) when[1];
    while (std::getline(in, line)) {
        long long field[kOwedFields] = {};
        if (!ReadNumbers(line, field, kOwedFields)) {
            continue;
        }
        auto in_range = [](long long value, long long low, long long high) {
            return value >= low && value <= high;
        };
        // A window handle is 32 significant bits even in a 64-bit process.
        if (!in_range(field[0], 1, 0xFFFFFFFFLL) || !in_range(field[1], 1, 0xFFFFFFFFLL)
            || field[2] <= 0
            || !in_range(field[3], 0, 0xFFFFFFFFLL) || !in_range(field[4], 0, 1)
            || !in_range(field[5], 0, 0xFFFF) || !in_range(field[6], 0, 11)) {
            continue;
        }
        bool coordinates = true;
        for (int i = 7; i < kOwedFields; ++i) {
            coordinates = coordinates && in_range(field[i], INT_MIN, INT_MAX);
        }
        if (!coordinates) {
            continue;
        }
        OwedWindow owed;
        owed.window = (uint64_t) field[0];
        owed.pid = (uint32_t) field[1];
        owed.process_created = (uint64_t) field[2];
        owed.removed_style = (uint64_t) field[3];
        owed.topmost = field[4] != 0;
        WINDOWPLACEMENT& p = owed.placement;
        p.length = sizeof(WINDOWPLACEMENT);
        p.flags = (UINT) field[5];
        p.showCmd = (UINT) field[6];
        p.ptMinPosition = POINT{(LONG) field[7], (LONG) field[8]};
        p.ptMaxPosition = POINT{(LONG) field[9], (LONG) field[10]};
        p.rcNormalPosition = RECT{(LONG) field[11], (LONG) field[12],
                                  (LONG) field[13], (LONG) field[14]};
        if (p.rcNormalPosition.right <= p.rcNormalPosition.left
            || p.rcNormalPosition.bottom <= p.rcNormalPosition.top) {
            continue;
        }
        record.windows.push_back(owed);
    }
    return record;
}

bool SaveOwedWindows(const std::wstring& path, const OwedRecord& record) {
    if (path.empty()) {
        return false;
    }
    if (record.windows.empty()) {
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
    const std::string text = FormatOwedWindows(record);
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

OwedRecord LoadOwedWindows(const std::wstring& path) {
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
