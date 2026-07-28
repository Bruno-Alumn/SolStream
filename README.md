# SolStream

Run one Windows application in a window on your Mac.

Not a desktop in a box. One application, in one native macOS window, with its own
title bar and traffic lights, that you move and resize and ⌘-Tab to like anything
else on the Mac. The PC it is actually running on is meant to stop being
something you think about.

## How it works

SolStream is two programs and a borrowed protocol.

A **host application** runs on the Windows PC. It enumerates the windows and
installed applications, launches things on request, and parks the window being
streamed on a **virtual display** — a display with no physical panel, sized to
match the Mac exactly. That last part is the whole trick: capture the real
monitor and anything the user drags over the application is streamed as though it
were part of it, and the resolution is whatever the monitor happens to be.

A **macOS client** shows the picker, opens the window, and decodes the video.

Between them is **Sunshine**, bundled and run as a child process, doing the
capture and the encoding, speaking the GameStream protocol that Moonlight
clients speak. SolStream's client is a Moonlight client that crops one window's
rectangle out of the captured display and draws it, rather than showing a
desktop.

```
   macOS                                  Windows
   ┌───────────────────┐                  ┌────────────────────────┐
   │ SolStream.app     │  agent socket    │ SolStreamAgent.exe     │
   │  picker           │◄────47630───────►│  windows, apps, launch │
   │  window + decode  │                  │  window placement      │
   │                   │                  └───────────┬────────────┘
   │                   │                              │ spawns
   │                   │   video / audio / input      ▼
   │                   │◄────47600 + offsets────  Sunshine
   └───────────────────┘                              │ captures
                                                      ▼
                                              virtual display
```

Ports come from one base (47600) plus fixed offsets, so a SolStream host can sit
beside a Sunshine the user already installed without either noticing.

## Layout

| Path | What it is |
| --- | --- |
| `windows/SolStreamAgent/` | The Windows host application. See its [README](windows/SolStreamAgent/README.md). |
| `windows/VirtualDisplay/` | Setting up the virtual display it streams from. |
| `macos/SolStreamClient/` | The macOS client, a SwiftPM package. |
| `scripts/` | Packaging and installing, both platforms. |
| `docs/` | Architecture and design notes. |

## Building

**macOS client** — needs Xcode's toolchain, macOS 14 or newer:

```bash
cd macos/SolStreamClient && swift build && swift test
```

`scripts/package-macos.sh --dev` produces `SolStream.app`.

**Windows host** — needs CMake and MSVC. `sh windows/SolStreamAgent/build-cross.sh`
compiles with mingw as an offline syntax check, but MSVC is the source of truth;
a green mingw build has hidden a total MSVC failure before.

```
cmake --build build --target SolStreamAgent --config Release
```

`scripts/package-windows.ps1` builds the folder that ships. Installing is the
executable's own job — `SolStream.exe --install` copies itself into Program
Files, opens the ports it needs and registers itself to start at logon, asking
for administrator rights once, visibly. `--uninstall` undoes it.

## Licensing

SolStream's own code has **no licence yet**; without one, default copyright
applies and nobody else may copy, modify or distribute it. That is a decision for
the project owner, not an oversight to be papered over — pick one before
publishing this anywhere.

What it is built on, and on what terms:

| Component | Licence | How it is used |
| --- | --- | --- |
| [Sunshine](https://github.com/LizardByte/Sunshine) (LizardByte) | GPL-3.0 | Bundled as an **unmodified binary** and run as a **separate child process**. Nothing links against it and nothing of it is modified, so this is aggregation rather than a derived work. The packaging step ships its licence text and a notice alongside it. |
| [ENet](https://github.com/lsalzman/enet) 1.3.18 (lsalzman) | MIT | Vendored source at `macos/SolStreamClient/Sources/CEnet/`, lightly adapted to build as a SwiftPM C target. Upstream copyright notice retained. |
| [Virtual Display Driver](https://github.com/VirtualDisplay/Virtual-Display-Driver) | see upstream | Installed separately by the setup script, not redistributed here. |

Opus decoding uses macOS's own `AudioToolbox`; nothing is vendored for it.

If you change how Sunshine is built, linked or patched, the aggregation argument
above stops holding and GPL-3.0 starts applying to what you ship. Re-read it
before doing that.
