// links.cpp — see links.h.

#include "links.h"

#include <windows.h>

#include <cctype>

#include "media/log.h"
#include "util.h"

namespace solstream {

namespace {

constexpr wchar_t kClientKey[] = L"SOFTWARE\\Clients\\StartMenuInternet\\SolStream";
constexpr wchar_t kCapabilities[] =
    L"SOFTWARE\\Clients\\StartMenuInternet\\SolStream\\Capabilities";
constexpr wchar_t kProgIdKey[] = L"SOFTWARE\\Classes\\SolStreamURL";
constexpr wchar_t kRegisteredApps[] = L"SOFTWARE\\RegisteredApplications";

/// One string value under HKLM, creating the key. Whether it took.
bool SetString(const std::wstring& key, const wchar_t* name, const std::wstring& value) {
    HKEY handle = nullptr;
    if (RegCreateKeyExW(HKEY_LOCAL_MACHINE, key.c_str(), 0, nullptr, 0,
                        KEY_WRITE | KEY_WOW64_64KEY, nullptr, &handle, nullptr)
        != ERROR_SUCCESS) {
        return false;
    }
    const bool ok = RegSetValueExW(handle, name, 0, REG_SZ,
                                   reinterpret_cast<const BYTE*>(value.c_str()),
                                   static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t)))
                    == ERROR_SUCCESS;
    RegCloseKey(handle);
    return ok;
}

}  // namespace

bool IsForwardableLink(const std::string& url) {
    if (url.empty() || url.size() > 8192) {
        return false;
    }
    for (const char c : url) {
        if (static_cast<unsigned char>(c) <= 0x20 || c == 0x7F) {
            return false;
        }
    }
    std::string scheme;
    const size_t colon = url.find(':');
    if (colon == std::string::npos) {
        return false;
    }
    for (size_t i = 0; i < colon; ++i) {
        scheme += static_cast<char>(std::tolower(static_cast<unsigned char>(url[i])));
    }
    if (scheme == "mailto") {
        return colon + 1 < url.size();
    }
    // A web link has somewhere to go: "https://" and a host.
    return (scheme == "http" || scheme == "https")
        && url.compare(colon, 3, "://") == 0 && colon + 3 < url.size();
}

void RegisterLinkHandler(const std::wstring& exe) {
    const std::wstring icon = exe + L",0";
    const std::wstring client = kClientKey;
    const std::wstring capabilities = kCapabilities;
    const std::wstring prog_id = kProgIdKey;
    bool ok = SetString(client, nullptr, L"SolStream");
    ok = SetString(client + L"\\DefaultIcon", nullptr, icon) && ok;
    // Opened as a browser with no link -- from the Start menu's list -- it is
    // the host's own window, which a second copy brings forward.
    ok = SetString(client + L"\\shell\\open\\command", nullptr, L"\"" + exe + L"\"") && ok;
    ok = SetString(capabilities, L"ApplicationName", L"SolStream") && ok;
    ok = SetString(capabilities, L"ApplicationDescription",
                   L"Opens links on the Mac you're streaming to.") && ok;
    ok = SetString(capabilities, L"ApplicationIcon", icon) && ok;
    for (const wchar_t* scheme : {L"http", L"https", L"mailto"}) {
        ok = SetString(capabilities + L"\\URLAssociations", scheme, L"SolStreamURL") && ok;
    }
    ok = SetString(prog_id, nullptr, L"SolStream link") && ok;
    ok = SetString(prog_id + L"\\DefaultIcon", nullptr, icon) && ok;
    ok = SetString(prog_id + L"\\shell\\open\\command", nullptr,
                   L"\"" + exe + L"\" --open-url \"%1\"") && ok;
    // Relative to HKLM, without the hive, as RegisteredApplications wants.
    ok = SetString(kRegisteredApps, L"SolStream",
                   L"Software\\Clients\\StartMenuInternet\\SolStream\\Capabilities") && ok;
    media::Log(ok ? "[install] offered as a browser in Default apps, for links to open on the Mac"
                  : "[install] could not register as a browser; links stay on the PC");
}

void RemoveLinkHandler() {
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, kClientKey);
    RegDeleteTreeW(HKEY_LOCAL_MACHINE, kProgIdKey);
    HKEY apps = nullptr;
    if (RegOpenKeyExW(HKEY_LOCAL_MACHINE, kRegisteredApps, 0, KEY_SET_VALUE | KEY_WOW64_64KEY,
                      &apps) == ERROR_SUCCESS) {
        RegDeleteValueW(apps, L"SolStream");
        RegCloseKey(apps);
    }
}

}  // namespace solstream
