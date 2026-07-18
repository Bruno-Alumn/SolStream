#include "path_validator.h"

#include <rpc.h>
#include <cwctype>

#include <algorithm>
#include <array>
#include <cwchar>
#include <span>
#include <vector>

#pragma comment(lib, "rpcrt4.lib")

namespace solstream::filetransfer {

// ── Helpers ─────────────────────────────────────────────────────────────────

namespace {

/// Check if a path component matches a Windows reserved device name.
bool IsReservedName(const std::wstring& component) {
    static const wchar_t* kReserved[] = {
        L"CON", L"PRN", L"AUX", L"NUL",
        L"COM1", L"COM2", L"COM3", L"COM4",
        L"COM5", L"COM6", L"COM7", L"COM8", L"COM9",
        L"LPT1", L"LPT2", L"LPT3", L"LPT4",
        L"LPT5", L"LPT6", L"LPT7", L"LPT8", L"LPT9",
    };
    // Strip trailing dots and spaces (Windows normalises these).
    auto trimmed = component;
    while (!trimmed.empty() && (trimmed.back() == L'.' || trimmed.back() == L' '))
        trimmed.pop_back();

    for (auto r : kReserved) {
        if (_wcsicmp(trimmed.c_str(), r) == 0)
            return true;
    }
    return false;
}

/// Dynamically resolve GetFinalPathNameByHandleW with proper buffer sizing.
std::wstring GetFinalPath(HANDLE hFile) {
    // Start with a reasonable buffer and grow if needed.
    DWORD bufSize = MAX_PATH + 8;
    std::vector<wchar_t> buf(bufSize);

    DWORD needed = GetFinalPathNameByHandleW(
        hFile, buf.data(), bufSize, VOLUME_NAME_DOS);

    if (needed == 0)
        return {};

    if (needed >= bufSize) {
        // Buffer too small — resize and retry.
        buf.resize(static_cast<size_t>(needed) + 1);
        needed = GetFinalPathNameByHandleW(
            hFile, buf.data(), needed + 1, VOLUME_NAME_DOS);
        if (needed == 0)
            return {};
    }

    return std::wstring(buf.data(), static_cast<size_t>(needed));
}

} // anonymous namespace

// ══════════════════════════════════════════════════════════════════════════════
// TransferRoot
// ══════════════════════════════════════════════════════════════════════════════

const std::wstring& TransferRoot() {
    static const std::wstring root = []() -> std::wstring {
        // Query the required buffer size first.
        DWORD needed = GetTempPathW(0, nullptr);
        if (needed == 0)
            needed = MAX_PATH;

        std::vector<wchar_t> tmp(static_cast<size_t>(needed) + 2);
        DWORD len = GetTempPathW(static_cast<DWORD>(tmp.size()), tmp.data());
        if (len == 0 || len > tmp.size())
            return L"C:\\SolStream\\transfers\\";

        std::wstring rootPath(tmp.data(), static_cast<size_t>(len));
        // Ensure trailing backslash.
        if (rootPath.back() != L'\\')
            rootPath += L'\\';
        rootPath += L"SolStream\\transfers\\";

        // Create the root directory recursively.
        size_t pos = 0;
        while ((pos = rootPath.find_first_of(L'\\', pos)) != std::wstring::npos) {
            std::wstring segment = rootPath.substr(0, pos + 1);
            if (segment.size() > 3) {  // Skip drive root "C:\"
                CreateDirectoryW(segment.c_str(), nullptr);
            }
            ++pos;
        }

        // Canonicalise the root by opening it and resolving the real path.
        HANDLE hRoot = CreateFileW(
            rootPath.c_str(),
            GENERIC_READ,
            FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
            nullptr,
            OPEN_EXISTING,
            FILE_FLAG_BACKUP_SEMANTICS,
            nullptr);

        if (hRoot != INVALID_HANDLE_VALUE) {
            auto canonical = GetFinalPath(hRoot);
            CloseHandle(hRoot);
            if (!canonical.empty()) {
                // Strip \\?\ prefix if present.
                if (canonical.size() >= 4 && canonical[0] == L'\\' &&
                    canonical[1] == L'\\' && canonical[2] == L'?' &&
                    canonical[3] == L'\\')
                    canonical = canonical.substr(4);
                if (canonical.back() != L'\\')
                    canonical += L'\\';
                return canonical;
            }
        }

        return rootPath;
    }();
    return root;
}

// ══════════════════════════════════════════════════════════════════════════════
// Sanitisation
// ══════════════════════════════════════════════════════════════════════════════

bool IsValidSessionId(const std::wstring& sessionId) {
    if (sessionId.empty() || sessionId.size() > 128)
        return false;

    if (IsReservedName(sessionId))
        return false;

    for (auto ch : sessionId) {
        // Reject: / \ : * ? " < > | and ..
        if (ch == L'/' || ch == L'\\' || ch == L':' || ch == L'*' ||
            ch == L'?' || ch == L'\"' || ch == L'<' || ch == L'>' ||
            ch == L'|')
            return false;
        // Reject control characters.
        if (static_cast<unsigned>(ch) < 32)
            return false;
    }

    // Reject parent-directory token.
    if (sessionId == L"." || sessionId == L"..")
        return false;

    return true;
}

bool IsValidFileName(const std::wstring& fileName) {
    if (fileName.empty() || fileName.size() > 255)
        return false;

    if (IsReservedName(fileName))
        return false;

    // Also reject if the base name (before extension) is reserved.
    // Windows treats CON.txt, NUL.log, etc. as reserved.
    auto dotPos = fileName.find(L'.');
    if (dotPos != std::wstring::npos) {
        std::wstring baseName = fileName.substr(0, dotPos);
        if (IsReservedName(baseName))
            return false;
    }

    for (auto ch : fileName) {
        if (ch == L'/' || ch == L'\\' || ch == L':' || ch == L'*' ||
            ch == L'?' || ch == L'\"' || ch == L'<' || ch == L'>' ||
            ch == L'|')
            return false;
        if (static_cast<unsigned>(ch) < 32)
            return false;
    }

    if (fileName == L"." || fileName == L"..")
        return false;

    // Reject trailing dots and spaces (Windows normalises these away,
    // allowing file and file. to alias).
    if (!fileName.empty() && (fileName.back() == L'.' || fileName.back() == L' '))
        return false;

    return true;
}

bool IsValidExtension(const std::wstring& extension) {
    if (extension.empty() || extension.size() > 64)
        return false;
    if (extension[0] != L'.')
        return false;
    // Reject parent-directory token.
    if (extension == L".." || extension == L".")
        return false;
    for (size_t i = 1; i < extension.size(); ++i) {
        auto ch = extension[i];
        if (ch == L'/' || ch == L'\\' || ch == L':' || ch == L'*' ||
            ch == L'?' || ch == L'\"' || ch == L'<' || ch == L'>' ||
            ch == L'|')
            return false;
        if (static_cast<unsigned>(ch) < 32)
            return false;
    }
    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// UUID generation
// ══════════════════════════════════════════════════════════════════════════════

std::wstring GenerateUUID() {
    UUID uuid{};
    RPC_STATUS status = UuidCreate(&uuid);
    if (status != RPC_S_OK && status != RPC_S_UUID_LOCAL_ONLY)
        return {};  // Cannot generate safe UUID — fail closed.

    RPC_WSTR str = nullptr;
    if (UuidToStringW(&uuid, &str) != RPC_S_OK)
        return {};

    std::wstring result(reinterpret_cast<const wchar_t*>(str));
    RpcStringFreeW(&str);

    // UuidToStringW returns e.g. "47a0c8b0-84a1-11eb-8dcd-0242ac130003"
    // (no braces).  Just return it directly.
    return result;
}

// ══════════════════════════════════════════════════════════════════════════════
// Path validation
// ══════════════════════════════════════════════════════════════════════════════

bool ValidateFilePath(const std::wstring& absolutePath) {
    if (absolutePath.empty())
        return false;

    // Open WITHOUT FILE_FLAG_OPEN_REPARSE_POINT so that any symlink or
    // junction on the final component IS followed.  We want to validate
    // the resolved target, not the link itself.
    HANDLE hFile = CreateFileW(
        absolutePath.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        nullptr);

    if (hFile == INVALID_HANDLE_VALUE)
        return false;

    auto realPath = GetFinalPath(hFile);
    CloseHandle(hFile);

    if (realPath.empty())
        return false;

    std::wstring root = TransferRoot();

    // Normalise both paths: strip \\?\ prefix.
    auto stripPrefix = [](std::wstring& p) {
        if (p.size() >= 4 && p[0] == L'\\' && p[1] == L'\\' &&
            p[2] == L'?' && p[3] == L'\\')
            p.erase(0, 4);
        // Also handle \\?\UNC\ prefix.
        if (p.size() >= 8 && p[0] == L'U' && p[1] == L'N' &&
            p[2] == L'C' && p[3] == L'\\')
            p.erase(0, 4);
    };
    stripPrefix(realPath);
    stripPrefix(root);

    // Strip trailing separator for prefix comparison.
    if (root.back() == L'\\')
        root.pop_back();

    // Compare case-insensitively: realPath must start with root.
    if (realPath.size() < root.size())
        return false;

    if (_wcsnicmp(realPath.c_str(), root.c_str(), root.size()) != 0)
        return false;

    // After the prefix, the next character (if any) must be a separator.
    // This prevents matches like "transfers_evil" when root is "transfers".
    if (realPath.size() > root.size() && realPath[root.size()] != L'\\')
        return false;

    return true;
}

// ══════════════════════════════════════════════════════════════════════════════
// Staging path creation
// ══════════════════════════════════════════════════════════════════════════════

std::wstring CreateStagingPath(
    const std::wstring& sessionId,
    const std::wstring& extension)
{
    if (!IsValidSessionId(sessionId))
        return {};
    if (!IsValidExtension(extension))
        return {};

    std::wstring stageDir = TransferRoot() + sessionId + L"\\stage\\";

    // Create the directory tree recursively.
    auto createAll = [](const std::wstring& dir) -> bool {
        size_t pos = TransferRoot().size();
        while ((pos = dir.find_first_of(L'\\', pos)) != std::wstring::npos) {
            std::wstring segment = dir.substr(0, pos + 1);
            if (!CreateDirectoryW(segment.c_str(), nullptr) &&
                GetLastError() != ERROR_ALREADY_EXISTS)
                return false;
            ++pos;
        }
        return true;
    };

    if (!createAll(stageDir))
        return {};

    // Verify the stage directory is not a symlink/junction.
    HANDLE hDir = CreateFileW(
        stageDir.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        nullptr);
    if (hDir == INVALID_HANDLE_VALUE)
        return {};

    auto canonical = GetFinalPath(hDir);
    bool dirOk = false;
    if (!canonical.empty()) {
        // Strip \\?\ prefix if present.
        auto stripPrefix = [](std::wstring& p) {
            if (p.size() >= 4 && p[0] == L'\\' && p[1] == L'\\' &&
                p[2] == L'?' && p[3] == L'\\')
                p.erase(0, 4);
            if (p.size() >= 8 && p[0] == L'U' && p[1] == L'N' &&
                p[2] == L'C' && p[3] == L'\\')
                p.erase(0, 4);
        };
        stripPrefix(canonical);

        // Check that canonical path starts with TransferRoot().
        std::wstring root = TransferRoot();
        stripPrefix(root);
        if (root.back() != L'\\')
            root += L'\\';

        if (canonical.size() >= root.size() &&
            _wcsnicmp(canonical.c_str(), root.c_str(), root.size()) == 0)
            dirOk = true;
    }
    CloseHandle(hDir);

    if (!dirOk)
        return {};

    // Generate a unique staging path and CREATE_NEW the file (atomic
    // reservation — fails if the path already exists).
    for (int attempt = 0; attempt < 3; ++attempt) {
        std::wstring path = stageDir + GenerateUUID() + extension;
        if (path.empty())
            continue;

        HANDLE hFile = CreateFileW(
            path.c_str(),
            GENERIC_WRITE,
            0,  // no sharing while we own it
            nullptr,
            CREATE_NEW,  // fail if already exists
            FILE_ATTRIBUTE_NORMAL,
            nullptr);

        if (hFile != INVALID_HANDLE_VALUE) {
            CloseHandle(hFile);
            return path;
        }
    }

    return {};
}

// ══════════════════════════════════════════════════════════════════════════════
// Atomic finalization
// ══════════════════════════════════════════════════════════════════════════════

std::wstring AtomicFinalize(
    const std::wstring& stagingPath,
    const std::wstring& finalName,
    const std::wstring& sessionId)
{
    // Validate all inputs up front.
    if (stagingPath.empty() || !IsValidFileName(finalName) ||
        !IsValidSessionId(sessionId))
        return {};

    // Verify the staging path is inside the expected stage directory.
    std::wstring expectedPrefix = TransferRoot() + sessionId + L"\\stage\\";
    if (stagingPath.size() < expectedPrefix.size() ||
        _wcsnicmp(stagingPath.c_str(), expectedPrefix.c_str(),
                   expectedPrefix.size()) != 0)
        return {};

    // Build the final directory and ensure it exists.
    std::wstring finalDir = TransferRoot() + sessionId + L"\\";
    if (!CreateDirectoryW(finalDir.c_str(), nullptr) &&
        GetLastError() != ERROR_ALREADY_EXISTS)
        return {};

    std::wstring finalPath = finalDir + finalName;

    // Validate the FINAL path BEFORE any move.
    // We open the path if it exists; if it doesn't exist yet, we still
    // check that the target directory is safe.
    HANDLE hExisting = CreateFileW(
        finalPath.c_str(),
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        nullptr,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS,
        nullptr);

    if (hExisting != INVALID_HANDLE_VALUE) {
        // A file already exists — check it's inside the root.
        auto existingPath = GetFinalPath(hExisting);
        CloseHandle(hExisting);

        if (existingPath.empty() || !ValidateFilePath(existingPath))
            return {};
    } else {
        // File doesn't exist yet — validate the directory portion.
        std::wstring dirPart = finalPath.substr(0, finalPath.find_last_of(L'\\'));
        if (!ValidateFilePath(dirPart))
            return {};
    }

    // Now perform the atomic rename.
    if (!MoveFileExW(stagingPath.c_str(), finalPath.c_str(),
                     MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH))
        return {};

    // Validate the final path after the move (catches races during rename).
    if (!ValidateFilePath(finalPath)) {
        // Rollback: try to move the file back to staging.
        MoveFileExW(finalPath.c_str(), stagingPath.c_str(),
                    MOVEFILE_WRITE_THROUGH);
        return {};
    }

    return finalPath;
}

} // namespace solstream::filetransfer
