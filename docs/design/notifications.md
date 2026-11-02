# Windows notifications on the Mac (design, not built)

The goal: a toast on the PC, from Teams, Outlook, Discord or anything else,
shows in the Mac's Notification Center, and clicking it opens that app's
window on the Mac.

The Mac half is ordinary work: `UNUserNotificationCenter`, one permission
prompt, and a click that opens the app through the same path a Dock launcher
uses (`AppLink`). The host half is not, and it needs a decision.

## Why it isn't built

Windows hands other apps' notifications to exactly one API,
`Windows.UI.Notifications.Management.UserNotificationListener`, and only to
an app that:

1. has **package identity**, and
2. declares the `userNotificationListener` capability, and
3. is granted access by the user (one Windows prompt).

SolStream's host is a plain, unpackaged Win32 program, so it has no identity.
Giving it one means shipping it as, or alongside, an MSIX package, and any
MSIX package has to be **signed with a certificate Windows trusts**. The
releases are not code-signed on Windows today (see the README's
installation notes).

## Options

| | How | Cost | Risk |
|---|---|---|---|
| **A. Sparse package** (recommended) | Keep `SolStream.exe` as it is, and register a small signed "sparse" MSIX that gives it identity (`Add-AppxPackage -ExternalLocation`). Then `UserNotificationListener` works, and so does reading each toast's app name, title, body and icon. | A code-signing certificate (a few hundred dollars a year, or Azure Trusted Signing). Setup registers the package. | Low. Supported by Microsoft for exactly this. |
| **B. Read Windows' notification database** | Poll `%LOCALAPPDATA%\Microsoft\Windows\Notifications\wpndatabase.db` (SQLite) for new toasts. | A SQLite reader in the host. | Undocumented. Its schema has changed between Windows versions, and it may be locked. |
| **C. Watch toasts appear on screen** | UI Automation, watching for the toast windows the shell opens. | Moderate. | Fragile. It misses toasts sent to the action center while Focus Assist is on, and reads only what is drawn. |
| **D. Don't** | — | — | — |

## Recommendation

**A**, once there is a Windows code-signing certificate. That certificate
would also remove the "Windows protected your PC" warning on install, which
is worth having on its own. Until then, nothing: B and C would ship
something that breaks quietly on a Windows update.

## What it would take once signed

- **Host:**
  - Register the sparse package from setup.
  - Request listener access once, from the tray window.
  - Subscribe to `NotificationChanged`.
  - Push `{"type":"notification","app":…,"title":…,"body":…,"aumid":…}` to the Mac over the agent channel. It is sealed like everything else.
- **Mac:**
  - Post it with `UNUserNotificationCenter`.
  - On click, resolve `aumid` or the app name to a Start Menu app, and open it with `AppLink`.
  - Add a switch in Settings, on by default once permission is given.
- **Privacy:** notifications carry message text. They would cross only while
  the Mac is connected and the switch is on, and never anything Windows
  marks as private on the lock screen.
