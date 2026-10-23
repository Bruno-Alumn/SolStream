<p align="center">
  <img src="docs/media/icon.png" width="96" alt="SolStream icon">
</p>

<h1 align="center">SolStream</h1>

<p align="center">
  <strong>One Windows app on your Mac, in a window of its own.</strong><br>
  macOS 14+ &middot; Windows 10 or 11 &middot; release 1.0.1
</p>

<p align="center">
  <img src="docs/media/demo.gif" width="860" alt="Calculator and a command prompt from a Windows PC, each in its own window on a Mac. Calculator works out 12 × 3 and the prompt prints a line typed on the Mac.">
</p>

You don't get a remote desktop. You get the app, as a normal macOS window you
can move, resize, full-screen and ⌘-Tab to. It keeps running on your PC.

<p align="center">
  <img src="docs/media/resize.gif" width="640" alt="PhotoCraft, an image editor running on the PC, in a Mac window. Dragging the window's corner resizes it, and the editor re-lays itself out at each size.">
  <br><sub>Resize the window and the app on the PC lays itself out again. Nothing is scaled.</sub>
</p>

## Features

- **One window per app:** stream several at once, each in its own Mac window.
- **A screen of its own:** apps run on a virtual display sized to your Mac, so your PC's monitor is left alone.
- **Fast:** hardware H.264 over SolStream's own UDP transport, 49 fps at 3600×2338 in testing.
- **Your keyboard:** keys go by position, so the PC's layout decides what they type. Caps Lock stays in step.
- **App sound:** just the streamed apps on Windows 11, the whole PC on Windows 10. Opus or lossless.
- **Gaming mode:** the game gets raw mouse movement. ⌃⌥ gives the mouse back.
- **Recovers by itself:** after a Wi-Fi drop, a network change or a host restart.
- **Secure:** paired with a token, with every packet encrypted (AES-256-GCM).
- **Signed updates:** both programs find new releases, check the signature and ask before installing.

## Install

Get both files from the [latest release](https://github.com/Bruno-Alumn/SolStream/releases/latest).

| | File | Then |
| --- | --- | --- |
| **Mac** | `SolStream-X.Y.Z-macOS.dmg` | Drag SolStream into Applications. |
| **Windows PC** | `SolStreamSetup-X.Y.Z.exe` | Run it, and leave *Set up a virtual display* ticked. |

Neither file has a paid signature yet, so each system warns you once:

- **Mac:** System Settings → Privacy & Security → *Open Anyway*.
- **PC:** on "Windows protected your PC", click *More info* → *Run anyway*.

## Getting started

1. **Open SolStream on the Mac.** It finds the PC on your network. Away from
   home, use [Tailscale](https://tailscale.com/download) on both machines.
2. **Pair once.** Type in the token shown in SolStream's window on the PC (click
   its tray icon).
3. **Pick an app**, an open window or one from the Start menu. It opens in its
   own Mac window.

## While streaming

<img src="docs/media/stream-controls.png" width="260" align="right" alt="The stream's controls: frame rate, latency and bandwidth, the host display, volume, sound quality, Desktop or Gaming mouse, and video quality.">

Click the **frame-rate number** in a window's title bar for volume, sound
quality, the mouse mode and video quality.

- **Desktop** mouse: the PC's pointer goes exactly where yours does.
- **Gaming** mouse: click in and the game has the mouse. Press **⌃⌥** to get it
  back. Games that show a pointer in their menus give it back on their own.
- Apps that draw their own title bar (Chrome, Discord, Explorer) can hide it
  from the same menu.

Everything else is in **SolStream › Settings**.

<br clear="right">

## Updates

Both programs check a minute after they start and then daily. You can also
check from the Mac's SolStream menu or the PC's tray menu. Nothing installs
until you say so, and never mid-stream.

<details>
<summary>While this repository is private</summary>

GitHub hides a private repository's releases, so the updaters find nothing and
the setup guides' *Get it* links show a 404 unless you're signed in. To test
updates, make a fine-grained token for this repository with *Contents:
Read-only* and an expiry date, and give it to the program as
`SOLSTREAM_GITHUB_TOKEN`:

- **Mac:** quit SolStream, then run this and paste the token:

  ```bash
  /bin/bash -c 'read -rsp "Token: " t && SOLSTREAM_GITHUB_TOKEN="$t" exec open -a SolStream'
  ```

- **PC:** add it as a *user* environment variable (not a system one), then
  restart SolStream from the tray.

Details are in [`docs/updates.md`](docs/updates.md).

</details>

## How it works

```
   macOS                                  Windows
   ┌───────────────────┐                  ┌────────────────────────┐
   │ SolStream.app     │  control, TCP    │ SolStream.exe          │
   │  picker           │◄────47630───────►│  windows, apps, launch │
   │  window + decode  │   encrypted      │  window placement      │
   │  input capture    │                  │  keys for the session  │
   │                   │                  │                        │
   │                   │  SMT/1, UDP      │  Windows.Graphics      │
   │                   │◄────47631───────►│   .Capture             │
   │                   │  AES-256-GCM     │  hardware H.264        │
   └───────────────────┘                  │  per-app sound, Opus   │
                                          └───────────┬────────────┘
                                                      │ captures
                                                      ▼
                                              virtual display
```

The **host** on the PC moves the app onto the virtual display, captures it and
encodes it on the graphics card. The **Mac client** decodes it with
VideoToolbox, cuts each app's window out for a window of its own, and sends
your keyboard and mouse back. They talk over a TCP control channel and SMT/1,
SolStream's own encrypted UDP transport ([design](docs/transport-smt1.md)). The
Mac finds the PC with a broadcast on UDP 47629.

<details>
<summary>Building from source</summary>

**Mac client** (Xcode command-line tools, macOS 14+):

```bash
cd macos/SolStreamClient && swift build && swift test
```

`scripts/package-macos.sh --dev` makes the `.app`, `.zip` and `.dmg`. Add
`--universal` for Intel Macs too.

**Windows host** (CMake and MSVC):

```
cmake --build build --target SolStreamAgent --config Release
```

`scripts/package-windows.ps1` makes `dist\SolStreamSetup-X.Y.Z.exe`, the whole
installer. On a Mac, `sh windows/SolStreamAgent/build-cross.sh` checks that the
Windows code compiles; only MSVC builds the real thing.

Releases: [`docs/releasing.md`](docs/releasing.md).

| Path | What's in it |
| --- | --- |
| `macos/SolStreamClient/` | The Mac app, a Swift package. |
| `windows/SolStreamAgent/` | The Windows host ([README](windows/SolStreamAgent/README.md)). |
| `windows/SolStreamAgent/media/` | Capture, encode and send. |
| `windows/VirtualDisplay/` | The virtual display setup. |
| `scripts/` | Packaging and release signing. |
| `docs/` | Design notes and the pictures here. |

</details>

## Licence

All rights reserved; there is no open-source licence. You may read the code
here but not copy, change or redistribute it without the owner's permission.

The Windows host includes [libopus](https://opus-codec.org) 1.6.1 (BSD
3-clause) for sound ([why](third_party/opus/SOLSTREAM.md);
`SolStream.exe --licenses` prints it). The
[Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
(MIT) isn't bundled: setup downloads a pinned, hash-checked release and
uninstall removes it ([details](installer/README.md)). Everything else comes
with macOS and Windows.
