#include "app_ids.h"

#include <cwchar>

#include "util.h"

namespace solstream {

bool IsAppsFolderPath(const std::wstring& path) {
    const size_t prefix = wcslen(kAppsFolderPrefix);
    return path.size() > prefix && _wcsnicmp(path.c_str(), kAppsFolderPrefix, prefix) == 0;
}

bool IsPackagedAppId(const wchar_t* id) {
    if (!id) {
        return false;
    }
    size_t length = 0, bangs = 0, bang_at = 0;
    for (const wchar_t* c = id; *c; ++c, ++length) {
        if (*c == L'!') {
            ++bangs;
            bang_at = length;
        } else if (!((*c >= L'a' && *c <= L'z') || (*c >= L'A' && *c <= L'Z')
                     || (*c >= L'0' && *c <= L'9') || *c == L'.' || *c == L'-'
                     || *c == L'_')) {
            return false;
        }
    }
    return length <= 256 && bangs == 1 && bang_at > 0 && bang_at + 1 < length;
}

bool IsLaunchableUrl(const std::wstring& target) {
    const std::wstring scheme = FoldCase(target);
    return !scheme.empty() && scheme.rfind(L"http:", 0) != 0
        && scheme.rfind(L"https:", 0) != 0 && scheme.rfind(L"file:", 0) != 0;
}

}  // namespace solstream
