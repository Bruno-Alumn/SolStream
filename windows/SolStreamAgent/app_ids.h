// app_ids.h — which Start Menu entries and Store applications the host offers.
//
// Each check decides what ends up in a string ShellExecute opens, so each is
// strict and kept apart from the Win32 calls that find the entries, where it
// can be tested.

#pragma once

#include <string>

namespace solstream {

/// How an application from the Store is named to ShellExecute: the shell's
/// Apps folder and the application's AppUserModelID.
inline constexpr wchar_t kAppsFolderPrefix[] = L"shell:AppsFolder\\";

/// Whether `path` names a Store application rather than a shortcut file.
bool IsAppsFolderPath(const std::wstring& path);

/// Whether an AppUserModelID is a packaged application's: Package!App, the
/// package family name, a bang, and the application's id within it, in the
/// characters those can have. Desktop applications' ids, and paths to their
/// .exe, are not.
bool IsPackagedAppId(const wchar_t* id);

/// Whether a .url shortcut's target is an application to open rather than a
/// page or file: steam:// and com.epicgames.launcher:// are; http, https,
/// file and nothing at all are not.
bool IsLaunchableUrl(const std::wstring& target);

}  // namespace solstream
