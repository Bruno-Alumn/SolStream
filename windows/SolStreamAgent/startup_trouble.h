// startup_trouble.h -- what SolStream says when it can't start on this PC
// because another program already holds its port.
//
// It used to log a line and quit before any window or tray icon existed, so
// a click on the Start menu shortcut did nothing anyone could see: most
// often another SolStream in another user's session (the one-copy check is
// per session), sometimes another program on the port. Apart from main.cpp
// so the wording can be tested.

#pragma once

#include <cwctype>
#include <string>

namespace solstream {

enum class PortHolder { SolStream, Other, Unknown };

/// Who `image` -- the full path of the program holding the port, or empty
/// when it couldn't be found -- is, beside `self`, this program's own path.
inline PortHolder ClassifyHolder(const std::wstring& image, const std::wstring& self) {
    if (image.empty()) {
        return PortHolder::Unknown;
    }
    auto lower = [](std::wstring text) {
        for (wchar_t& c : text) c = (wchar_t) std::towlower(c);
        return text;
    };
    auto base = [](const std::wstring& path) {
        const size_t slash = path.find_last_of(L"\\/");
        return slash == std::wstring::npos ? path : path.substr(slash + 1);
    };
    const std::wstring name = lower(base(image));
    if (lower(image) == lower(self) || name == L"solstream.exe" || name == L"solstreamagent.exe") {
        return PortHolder::SolStream;
    }
    return PortHolder::Other;
}

struct StartupTrouble {
    std::wstring headline;
    std::wstring detail;
};

/// What to say: the port by number always, the program by its file name
/// when it is known, and where the log is.
inline StartupTrouble PortTakenMessage(unsigned port, PortHolder holder,
                                       const std::wstring& image, const std::wstring& log) {
    const size_t slash = image.find_last_of(L"\\/");
    const std::wstring name = slash == std::wstring::npos ? image : image.substr(slash + 1);
    const std::wstring number = std::to_wstring(port);
    StartupTrouble trouble;
    trouble.headline = L"SolStream couldn't start on this PC.";
    switch (holder) {
        case PortHolder::SolStream:
            trouble.detail = L"SolStream is already running, perhaps for another user signed in "
                             L"to this PC, and has port " + number + L". Quit it there (or sign "
                             L"that user out), then open SolStream again.";
            break;
        case PortHolder::Other:
            trouble.detail = name + L" is using port " + number + L", which SolStream needs. "
                             L"Quit it, or restart this PC, then open SolStream again.";
            break;
        case PortHolder::Unknown:
            trouble.detail = L"Another program is using port " + number + L", which SolStream "
                             L"needs -- often another SolStream, for another user signed in to "
                             L"this PC. Quit it, or restart this PC, then open SolStream again.";
            break;
    }
    if (!log.empty()) {
        trouble.detail += L"\n\nSolStream's log: " + log;
    }
    return trouble;
}

}  // namespace solstream
