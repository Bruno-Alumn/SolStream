# What other apps do that SolStream could (survey, not built)

A survey, in November 2026, of what comparable products offer, set against
what SolStream already does, to pick what to build next. The decision is
which of the shortlist to build, and in what order.

Products looked at:

- **Windows apps on a Mac:** Parallels Desktop 26 (Coherence), VMware Fusion,
  CrossOver, UTM.
- **Game and desktop streaming:** Moonlight with Sunshine and its fork Apollo,
  Parsec, Steam Remote Play, GeForce NOW, Shadow.
- **Remote apps and desktops:** Microsoft's Windows App (RemoteApp), Citrix
  Workspace, Jump Desktop, AnyDesk, Splashtop, RustDesk, TeamViewer,
  NoMachine, HP Anyware, Chrome Remote Desktop, Screens.

The field has narrowed. VMware Fusion removed Unity, its one-window-per-app
mode, in 13.6 (September 2024). Whisky stopped in April 2025. NVIDIA dropped
GameStream in 2023. Among Windows-on-Mac products, **Parallels Coherence is the
only actively developed one-window-per-app product**, so it is the one to
measure against. RemoteApp is the closest in shape: a real PC elsewhere, its
apps drawn as local windows.

The core of Coherence is already here: an app per window, ⌘Tab, Dock and
Spotlight launchers, clipboard text and pictures, files dropped onto the PC,
the keyboard layout, and a click that wakes the PC. What the others have
beyond that is mostly the glue between the two systems: links, files going
the other way, Dock alerts, and printing.

Where a claim about another product isn't common knowledge, the survey
checked it against that product's documentation or support pages. Parallels'
notification and Dock-badge behaviour is known only from old forum threads.

## Already designed

These came up in every survey and already have notes here, so they are not
repeated below: [notifications](notifications.md),
[game controllers](game-controllers.md),
[microphone and webcam](microphone-and-webcam.md),
[the sign-in screen](sign-in-screen.md),
[10-bit, HDR and AV1](10-bit-hdr-av1.md) and
[mouse acceleration](mouse-acceleration.md).

## Shortlist: high value, small to medium work

| # | Feature | Who has it | What it would take here |
|---|---|---|---|
| 1 | **Links open on the Mac.** A link clicked in a Windows app opens in the Mac's default browser, and `mailto:` in its mail app. | Parallels, Citrix | A small "SolStream" browser registered on the PC for http, https and mailto (it shows up in Windows' Default apps), which hands the URL to the connected Mac. Falls back to Edge when no Mac is connected. |
| 2 | **Files from the PC to the Mac.** "Send to Mac" in Explorer's right-click menu, landing in `~/Downloads/SolStream`. | Parallels ("Open on Mac"), AnyDesk, Splashtop, RustDesk, TeamViewer | The upload path in reverse. The Explorer verb is a registry entry, no shell extension needed. |
| 3 | **The Dock bounces when an app wants attention.** When a taskbar button flashes on the PC (Outlook, Teams, a finished download), the app's Dock icon bounces. | Parallels (on by default) | A shell hook on the host for `HSHELL_FLASH`, sent to the Mac, which calls `NSApp.requestUserAttention`. |
| 4 | **Live window title and icon.** The Mac window follows the app's title as it changes (the open document, the unread count) and shows the app's own icon. | RemoteApp, Citrix, Parallels | The host already reads both. Send a change when the title changes, through `EVENT_OBJECT_NAMECHANGE`. |
| 5 | **Quit and Force Quit from the Dock.** Quit closes the app on the PC; Force Quit (⌥ right-click, or ⌥⌘⎋) ends a hung one. | Parallels | Quit is `WM_CLOSE` to the app's windows. Force Quit is `TerminateProcess`, after a confirmation, refused for anything elevated. |
| 6 | **Formatted text and files on the clipboard.** Copy styled text, or files in Explorer, and paste on the Mac, and back. | Parallels, AnyDesk, TeamViewer, RDP | RTF and HTML alongside plain text. Files as a list that is fetched only when pasted, reusing the transfer chunks. |
| 7 | **Full screen follows the app.** A game or video that goes full screen on the PC puts its Mac window into full screen, and back. | Parallels | Watch the window's style and size against the virtual display's. |
| 8 | **Quality presets and a connection test.** Three presets (Smooth, Balanced, Sharp) instead of separate knobs, and a "Test connection" button that measures round trip, jitter and loss on the real path, then suggests one. | Steam, GeForce NOW, Moonlight, TeamViewer | The pill already has the numbers. The test is a burst of padded datagrams on the media port. |
| 9 | **Commands before and after an app.** Per app on the PC: run something before it opens and after it closes, such as a power plan, killing a launcher, or mounting a share. | Sunshine, Apollo | A per-app list in the host's settings, run as the user, never elevated, with a timeout. |
| 10 | **Waking and launching show progress.** A Dock click on a sleeping PC shows "Waking the PC… Connecting… Opening Excel…" instead of nothing until the window appears. | Parallels, CrossOver, Moonlight | Mostly the Mac's launch path, see [launcher routes](launcher-routes.md). |

## Worth doing, larger

| # | Feature | Who has it | Why larger |
|---|---|---|---|
| 11 | **Menus and popups past the window's edge.** A menu or drop-down near the edge is cut off today, because the picture is cropped to the window. | RemoteApp, Citrix, Parallels | Each popup becomes a borderless Mac window of its own, positioned against its owner and cut from the same frame. Input and focus have to follow. |
| 12 | **Open Mac files with a Windows app.** A Windows app appears in Finder's "Open With". The file goes to the PC, opens there, and saves come back. | Parallels, Citrix, CrossOver | Launchers declare document types read from the PC's registry. Sending is easy; bringing saves back means watching the file on the PC. |
| 13 | **Print to a Mac printer.** A "SolStream" printer on the PC sends a PDF to the Mac, which prints it through the Mac's own print dialog. | RDP Easy Print, Parallels, Splashtop | A print-to-PDF queue on the PC through Microsoft's driver. Installing a printer needs administrator rights, so it belongs in setup. |
| 14 | **Sharp text: 4:4:4 colour.** Text drawn in 4:2:0 picks up colour fringes. Desktop apps are mostly text. | Parsec Warp, Sunshine, Splashtop, GeForce NOW | HEVC Range Extensions 4:4:4 on NVIDIA and Intel encoders, only where the Mac decodes it in hardware. Needs live testing on the PC and the Mac's chip. |
| 15 | **A timing overlay.** Encode, network, decode and display time per frame, to answer "why is it laggy". | Moonlight, Steam, Parsec | The host has to stamp its stage times into each frame's header, which is a transport change. |
| 16 | **Touch ID for the Windows password.** Sign in to Windows, or answer UAC, with Touch ID on the Mac. | Parallels 19 and later | Depends on the [sign-in screen](sign-in-screen.md) decision: it needs a credential provider on the PC. |
| 17 | **What each paired Mac may do.** Per pairing: clipboard, files and links each in or out, and which apps. For a family Mac or a work PC. | Apollo, Parsec, Parallels (Isolate Windows) | Permissions stored with each pairing, checked on every command. The pairing model already identifies each Mac. |
| 18 | **Tray icons in the Mac menu bar.** | Parallels, RemoteApp | Windows has no public way to read other apps' tray icons. Possible through UI Automation on the tray, but fragile. |
| 19 | **Start menu in the Mac menu bar.** All the PC's apps a click away, without opening the app list. | Parallels | Cheap once settled whether this is wanted alongside the Dock launchers. |
| 20 | **Sleep the PC when idle.** After N minutes with nothing streamed, the PC sleeps; the next Dock click wakes it. | Parallels (pauses Windows) | Easy on the host. Whether SolStream should ever put somebody's PC to sleep is the question. |

## Left out, and why

- **USB and smart-card passthrough** (Parallels, Citrix, Splashtop, Shadow):
  a kernel driver on Windows for little gain. Controllers, the microphone and
  the camera get channels of their own instead.
- **Shared folders and mounted drives** (Parallels, UTM, RDP): built on a
  local hypervisor's file system, or a redirection driver. The Mac's own file
  sharing over Tailscale, or items 2 and 12, cover most of it.
- **A relay so there's no VPN** (AnyDesk, Parsec, RustDesk): it means running
  servers. Tailscale already does this.
- **Guest links, chat, whiteboards, session recording**: built for support
  desks and sharing with other people. SolStream is one person's Mac and PC.
  The Mac can already record a window.
- **Several monitors as whole desktops** (Parsec, Shadow): off-model. Each
  app is its own window and can go to any Mac display.
- **Snapshots, travel mode, bottles**: belong to a VM or Wine.

## The decision

Which of 1–10 to build, in what order, and whether any of 11–20 should
come first. A suggested order:

1. **Links (1), files to the Mac (2), Dock bounce (3) and live titles (4)**:
   small, felt every day, and they close most of the gap to Coherence.
2. **Quit and Force Quit (5), full screen (7) and progress on launch (10)**:
   polish that makes the windows behave like Mac apps.
3. **Presets and the connection test (8)**: the first thing anyone tries
   when the picture isn't right.
4. **Menus past the edge (11)**, the most visible remaining difference from
   a native window, then **4:4:4 (14)** once it can be tested on the PC.

Item 20 needs a yes or no on its own, because it changes the PC's power
behaviour.
