<div align="center">

<img src="docs/media/logo.png" width="128" height="128" alt="SolStream app icon">

# SolStream

**Windows apps, at home on your Mac.**

Each app from your PC opens in its own native Mac window.

<a href="https://github.com/Bruno-Alumn/SolStream/releases/latest"><img src="https://img.shields.io/badge/Download_for_Mac_%26_PC-2A64F5?style=for-the-badge&logo=apple&logoColor=white" alt="Download SolStream for Mac and PC" height="36"></a>

<a href="https://github.com/Bruno-Alumn/SolStream/releases/latest"><img src="https://img.shields.io/github/v/release/Bruno-Alumn/SolStream?style=flat-square&color=2A64F5&label=release" alt="Latest release"></a>
<img src="https://img.shields.io/badge/macOS-14%2B-1f2937?style=flat-square&logo=apple&logoColor=white" alt="macOS 14 or later">
<img src="https://img.shields.io/badge/Windows-10_%7C_11-1f2937?style=flat-square&logo=windows&logoColor=white" alt="Windows 10 or 11">
<img src="https://img.shields.io/badge/license-All_rights_reserved-6b7280?style=flat-square" alt="All rights reserved">

[Features](#features) · [Install](#install) · [Using SolStream](#using-solstream) · [Troubleshooting](#troubleshooting) · [Privacy](#privacy) · [Contribute](#contribute)

</div>

---

SolStream brings individual apps from your Windows PC to your Mac. Each one
appears as a regular Mac window you can move, resize, put in full screen and
switch to with <kbd>⌘</kbd><kbd>Tab</kbd>, while the app keeps running on the
PC. Not a remote desktop or a second screen to squint at: only the app, right
where you’re working.

<div align="center">
  <img src="docs/media/demo.gif" width="860" alt="Calculator and a command prompt from a Windows PC, each in its own window on a Mac. Calculator works out 12 × 3 and the prompt prints a line typed on the Mac.">
</div>

## Features

**Feels like a Mac app**

- Stream several apps at once, each in its own window.
- Resize a window and the app re-lays itself out on the PC instead of being
  scaled.
- Add a Windows app to the Dock, Spotlight and Launchpad.
- Copy and paste text and pictures both ways; drop files on a window to send
  them to the PC.
- Your keyboard layout, Caps Lock and input methods work as usual.
- Apps run on a virtual display, leaving the PC’s own monitor untouched.

**Fast and dependable**

- Hardware H.264 or HEVC encoding; 49 fps at 3600×2338 in testing.
- Sound from only the streamed apps on Windows 11, in Opus or lossless.
- A gaming mode with raw mouse input.
- Reconnects by itself after Wi-Fi drops, network changes and restarts.

**Private by design**

- Pairing-token authentication and AES-256-GCM on every packet.
- Signed updates that ask before installing.

<div align="center">
  <img src="docs/media/resize.gif" width="640" alt="PhotoCraft, an image editor running on the PC, in a Mac window. Dragging the window's corner resizes it, and the editor re-lays itself out at each size.">
  <br><sub>Resize the window and the app adapts its layout on the PC.</sub>
</div>

## Install

You need a Mac with macOS 14 or later and a PC with Windows 10 or 11 (ideally
with a GPU video encoder), on the same network or both on
[Tailscale](https://tailscale.com/download).

1. Download both installers from the
   [latest release](https://github.com/Bruno-Alumn/SolStream/releases/latest).
2. **On the Mac,** open `SolStream-X.Y.Z-macOS.dmg` and drag **SolStream** into
   **Applications**.
3. **On the PC,** run `SolStreamSetup-X.Y.Z.exe` and keep **Set up a virtual
   display** selected. Setup adds its firewall rules and starts the host in
   the system tray at sign-in.

> **A note about signing:** the installers aren’t signed with a paid
> certificate yet, so each system warns you the first time. On the Mac, open
> SolStream, dismiss the warning, then choose **Open Anyway** in System
> Settings › Privacy & Security. On the PC, choose **More info** › **Run
> anyway** on the “Windows protected your PC” screen.

## Using SolStream

1. **Open SolStream on the Mac.** It finds the PC on your network. If it
   doesn’t, enter the PC’s name or IP address in the host list.
2. **Pair, once per PC.** Click SolStream in the PC’s system tray and enter
   the pairing token it shows.
3. **Choose an app.** Pick an open window or anything from the Start menu,
   Steam and Epic games included.

<img src="docs/media/stream-controls.png" width="260" align="right" alt="The stream's controls: frame rate, latency and bandwidth, the host display, volume, sound quality, Desktop or Gaming mouse, and video quality.">

| Action | What it does |
|:--|:--|
| Click the frame rate in the title bar | Open the stream controls: volume, quality, mouse mode |
| Choose **Gaming mouse** | Give a game raw mouse input |
| <kbd>⌃</kbd><kbd>⌥</kbd> | Release the mouse from a game |
| Pinch on the trackpad | Zoom in the app |
| Drop files on a window | Send them to the PC’s clipboard; paste with <kbd>⌘</kbd><kbd>V</kbd> |
| Right-click an app › **Add to Dock** | Open it from the Dock, Spotlight or Launchpad |
| **Title bar › Hide** | Remove the app’s own title bar |

SolStream reopens the app you were streaming when you quit, and keeps the
Mac’s display awake during a stream. Everything else is in
**SolStream › Settings**.

<br clear="right">

## Troubleshooting

<details>
<summary><strong>The Mac doesn't find the PC</strong></summary>

Discovery uses a broadcast on UDP 47629, which doesn't cross routers or VPNs.
Enter the PC's name or IP address in the host list instead. To connect from
another network, install Tailscale on both machines and sign in to the same
account. Setup opens TCP 47630 and UDP 47629 and 47631 in Windows Firewall;
third-party firewalls need the same ports open.
</details>

<details>
<summary><strong>Clicks and keystrokes don't reach an app</strong></summary>

The host runs without administrator rights, and Windows blocks it from
controlling apps that run as administrator, including Windows' own UAC
prompts. Respond to those at the PC, or run the app without administrator
rights.

An app set to run as administrator stops at Windows' prompt on the PC when
it's opened from the Mac, and SolStream says so. Answer the prompt at the PC,
then pick the app under *Open windows*; or turn off *Run as administrator* for
it.
</details>

<details>
<summary><strong>I hear the whole PC instead of the app</strong></summary>

Per-app audio requires Windows 11. On Windows 10, SolStream sends all of the
PC's audio.
</details>

<details>
<summary><strong>The PC is asleep</strong></summary>

Once SolStream has connected to a PC, it remembers how to wake it. When that
PC doesn't answer, the connect window offers **Wake PC**. This needs
Wake-on-LAN turned on for the PC's network adapter (in Device Manager, and on
some PCs in the BIOS), and the Mac on the same network: the wake signal
doesn't cross routers or Tailscale. A PC waiting at the Windows sign-in
screen looks the same as one asleep: SolStream runs once you sign in.
</details>

<details>
<summary><strong>The connection drops when I sign out of Windows</strong></summary>

The host runs inside your Windows session, so it stops when you sign out and
starts again when you sign back in. Locking the PC doesn't stop it.
</details>

<details>
<summary><strong>Uninstalling</strong></summary>

- **Mac:** quit SolStream and move it to the Trash. Pairings are stored in
  `~/Library/Application Support/SolStream`; delete that folder to remove them.
- **PC:** Settings › Apps › SolStream › **Uninstall**. This removes the host,
  its firewall rules, its sign-in task and the virtual display it installed.
</details>

## Privacy

SolStream has no accounts and no analytics. Your apps, keystrokes and files
travel only between your own Mac and PC, encrypted end to end.

A Mac must prove it knows the PC’s pairing token before the host accepts any
command; after that, the control channel and all media are encrypted with
AES-256-GCM. Run the host on a trusted network, or reach it over a VPN such
as Tailscale.

The only other network requests are update checks to GitHub: the Mac app when
it opens and the PC host shortly after it starts, then once a day. Nothing is
installed without your confirmation, never during a stream, and a download
that doesn’t verify against the signing key built into both apps is discarded
([details](docs/updates.md)).

### Permissions

| Permission | Why it’s needed |
|:--|:--|
| **Local Network** (Mac) | Finds and connects to your PC on your network or VPN. |
| **Windows Firewall rules** (PC) | Setup opens TCP 47630 and UDP 47629 and 47631 so the Mac can reach the host. |

## Contribute

- **Found something broken?** [Open an issue](https://github.com/Bruno-Alumn/SolStream/issues/new)
  with what you did, what happened, and your macOS and Windows versions.
- **Found a security problem?** Report it privately as described in
  [SECURITY.md](SECURITY.md).

SolStream isn’t open source, so pull requests can’t be merged as they are,
but bug reports and ideas are always welcome.

Much of SolStream was built with AI coding agents, then compiled, tested and
exercised on real hardware before merging.

<details>
<summary><strong>Build from source</strong></summary>
<br>

**Mac client** (Xcode command-line tools, macOS 14 or later):

```bash
cd macos/SolStreamClient && swift build && swift test
```

`scripts/package-macos.sh --dev` builds the `.app`, `.zip` and `.dmg`; add
`--universal` to include Intel Macs.

**Windows host** (CMake and Visual Studio's C++ tools):

```
cmake --build build --target SolStreamAgent --config Release
```

`scripts/package-windows.ps1` builds `dist\SolStreamSetup-X.Y.Z.exe`, the
complete installer. On a Mac, `sh windows/SolStreamAgent/build-cross.sh`
checks that the Windows code compiles; release builds require MSVC.

Releases are published by pushing a version tag; see
[`docs/releasing.md`](docs/releasing.md). The icons are generated from
[`assets/logo`](assets/logo/README.md).

| Path | Contents |
| --- | --- |
| `macos/SolStreamClient/` | The Mac app, a Swift package. |
| `windows/SolStreamAgent/` | The Windows host ([README](windows/SolStreamAgent/README.md)). |
| `windows/SolStreamAgent/media/` | Capture, encoding, audio and the transport. |
| `windows/VirtualDisplay/` | Virtual display setup. |
| `assets/logo/` | The logo and the icon generator. |
| `scripts/` | Packaging and release signing. |
| `docs/` | Design notes and README media. |

</details>

<details>
<summary><strong>Architecture</strong></summary>
<br>

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

The **host** moves the selected app onto the virtual display, captures it with
Windows.Graphics.Capture and encodes it on the GPU. The **Mac client** decodes
the stream with VideoToolbox, crops each app into its own window and sends
keyboard and mouse input back. The two communicate over an encrypted TCP
control channel and SMT/1, SolStream's UDP media transport
([specification](docs/transport-smt1.md)).

</details>

---

The Windows host includes [libopus](https://opus-codec.org) 1.6.1 (BSD
3-clause) for audio ([notes](third_party/opus/SOLSTREAM.md); run
`SolStream.exe --licenses` to print its license). The
[Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
(MIT) is not bundled: setup downloads a pinned, hash-verified release, and
uninstalling removes it ([details](installer/README.md)).

**All rights reserved:** © 2026 Bruno-Alumn. There is no open-source license:
the code may be read here, but not copied, modified or redistributed without
the owner's permission.

<sub>More Mac apps by Bruno-Alumn: [Tuckaway](https://github.com/Bruno-Alumn/Tuckaway) · [ThockBox](https://github.com/Bruno-Alumn/ThockBox)</sub>
