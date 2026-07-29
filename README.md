# SolStream

Run one Windows application in a window on your Mac.

Not a desktop in a box. One application, in one native macOS window, with its own
title bar and traffic lights, that you move and resize and ⌘-Tab to like anything
else on the Mac. The PC it is actually running on is meant to stop being
something you think about.

## How it works

SolStream is two programs and a protocol it owns.

A **host application** runs on the Windows PC. It enumerates the windows and
installed applications, launches things on request, parks the window being
streamed on a **virtual display** — a display with no physical panel, sized to
match the Mac exactly — and then captures, encodes and sends the picture itself.

A **macOS client** shows the picker, opens the window, decodes the video and
sends back the keyboard and mouse.

Between them is **SMT/1**, SolStream's own media transport: plain UDP carrying
AES-256-GCM, with the keys agreed over the agent channel that has already
authenticated both ends. There is no third program, no pairing PIN, no
certificate exchange and no forward-error-correction tax on the bandwidth.
`docs/transport-smt1.md` is the design; it was written clean-room from
requirements.

```
   macOS                                  Windows
   ┌───────────────────┐                  ┌────────────────────────┐
   │ SolStream.app     │  agent channel   │ SolStream.exe          │
   │  picker           │◄────47630───────►│  windows, apps, launch │
   │  window + decode  │   newline-JSON   │  window placement      │
   │  input capture    │                  │  keys for the session  │
   │                   │                  │                        │
   │                   │  SMT/1, one UDP  │  Windows.Graphics      │
   │                   │◄────47631───────►│   .Capture             │
   │                   │  AES-256-GCM     │  hardware H.264        │
   └───────────────────┘                  │  WASAPI loopback       │
                                          └───────────┬────────────┘
                                                      │ captures
                                                      ▼
                                              virtual display
```

Measured against a real host, capture to the last byte on the wire: **6.7 ms at
best, 9.7 ms on average** at 3600×2338.

## Layout

| Path | What it is |
| --- | --- |
| `windows/SolStreamAgent/` | The Windows host application. See its [README](windows/SolStreamAgent/README.md). |
| `windows/SolStreamAgent/media/` | SMT/1's host half: capture, encode, packetize, pace, send. |
| `macos/SolStreamClient/Sources/MediaSession/` | SMT/1's client half. |
| `windows/VirtualDisplay/` | Setting up the virtual display it streams from. |
| `macos/SolStreamClient/` | The macOS client, a SwiftPM package. |
| `spike/` | Throwaway programs that answered one question each, kept for their results. |
| `scripts/` | Packaging, both platforms. |
| `docs/` | Architecture and design notes. |

## Building

**macOS client** — needs Xcode's toolchain, macOS 14 or newer:

```bash
cd macos/SolStreamClient && swift build && swift test
```

`scripts/package-macos.sh --dev` produces `SolStream.app`.

**Windows host** — needs CMake and MSVC.

```
cmake --build build --target SolStreamAgent --config Release
```

`sh windows/SolStreamAgent/build-cross.sh` compiles with mingw as an offline
syntax check, but MSVC is the source of truth and the media path is MSVC-only:
Windows.Graphics.Capture arrives through C++/WinRT and the encoder through Media
Foundation, and mingw has neither. A green mingw build has hidden a total MSVC
failure before.

`scripts/package-windows.ps1` produces `SolStreamSetup.exe` — one file, which is
the whole package. Installing is the executable's own job: run it and it offers
to copy itself into Program Files, open the two ports it needs and start at
logon, asking for administrator rights once, visibly. `--uninstall` undoes it.

## Licensing

SolStream's own code has **no licence yet**; without one, default copyright
applies and nobody else may copy, modify or distribute it. That is a decision for
the project owner, not an oversight to be papered over — pick one before
publishing this anywhere.

**There are no third-party dependencies.** There used to be three:

| Component | Licence | What happened to it |
| --- | --- | --- |
| [Sunshine](https://github.com/LizardByte/Sunshine) | GPL-3.0 | Removed. It did the capture and encoding and spoke GameStream; SolStream does both itself now, over SMT/1. Nothing in what ships is under the GPL and there is no obligation left to meet. |
| [ENet](https://github.com/lsalzman/enet) 1.3.18 | MIT | Removed with the GameStream control stream that used it. |
| Opus | — | Removed. Audio is 48 kHz stereo PCM: 1.5 Mbit/s beside video's 20, and no codec latency. |
| [Virtual Display Driver](https://github.com/VirtualDisplay/Virtual-Display-Driver) | see upstream | Still optional, still installed separately by the user, never redistributed here. |

Everything else is in the box: BCrypt and Media Foundation and
Windows.Graphics.Capture on Windows, CryptoKit and VideoToolbox and AudioUnit on
macOS.
