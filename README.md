# SolStream

SolStream puts a single Windows app on your Mac, in its own window.

You don't get a remote desktop. You get the app: a normal macOS window with
traffic lights and a title bar, which you can move, resize, full-screen and
⌘-Tab to like anything else. The app keeps running on your PC. With any luck
you stop noticing that.

## Install

Grab both files from the [Releases page](https://github.com/Bruno-Alumn/SolStream/releases):

- **Mac** (macOS 14 or later): `SolStream-X.Y.Z-macOS.dmg`. Open it and drag
  SolStream into Applications.
- **Windows PC**: `SolStreamSetup-X.Y.Z.exe`. Run it. It installs itself, asks
  for administrator rights once, and from then on starts quietly in the tray
  when you log in.

Neither file is signed with a paid certificate yet, so both systems complain
the first time:

- On the Mac, macOS says it couldn't check the app for malware. Close the
  warning, go to System Settings → Privacy & Security and click *Open Anyway*.
- On the PC, SmartScreen says "Windows protected your PC". Click *More info*,
  then *Run anyway*. The admin prompt after that will say *Unknown publisher*.

## Using it

1. Open SolStream on the Mac. It finds the PC on your network, or over
   Tailscale if you're away from home.
2. The first time, type in the pairing token. You'll find it in SolStream's
   window on the PC (click the tray icon).
3. Pick an app, either one that's already open or one from the Start menu.
   It opens in its own Mac window.

Click the fps number in a stream window's title bar for the controls you'll
reach for mid-stream: volume and mute, Desktop or Gaming mouse, and video
quality. Everything else lives in SolStream › Settings.

Gaming mode is for games that take over the mouse. Click into the window and
the mouse belongs to the game. Press ⌃⌥ (Control-Option) to get it back. In
games that show a cursor in their menus, such as Minecraft's pause screen, you
get the mouse back without pressing anything.

## Updates

Both programs check for a new release a minute after they start, then once a
day. You can also check by hand: *Check for Updates…* in the Mac's SolStream
menu, or *Check for updates* in the tray menu on the PC.

When an update turns up, you'll see a notice. Nothing installs until you say
so, and never in the middle of a stream. Every release comes with a list of
checksums signed by a key that's built into both programs. The updater checks
that signature and then the file itself, and throws away anything that doesn't
match.

A few things to expect:

- The Mac app replaces itself, so it has to sit somewhere you can write to,
  like Applications. If it can't, it tells you instead of asking for an admin
  password.
- macOS may ask for Local Network access again after an update.
- On Windows, installing an update asks for admin rights, same as the first
  install.

### While this repository is private

GitHub hides the releases of a private repository from anyone who isn't signed
in, so the updaters find nothing and stay quiet. To test updates in the
meantime, create a fine-grained personal access token limited to this
repository, with *Contents: Read-only* and an expiry date. Give it to the
program as `SOLSTREAM_GITHUB_TOKEN`.

- **Mac:** quit SolStream, then run this in Terminal and paste the token when
  it asks:

  ```bash
  /bin/bash -c 'read -rsp "Token: " t && SOLSTREAM_GITHUB_TOKEN="$t" exec open -a SolStream'
  ```

  The token only exists for that one launch. Don't use `launchctl setenv`,
  because that hands it to every app you open.
- **PC:** add it as a *user* variable under *Edit environment variables for
  your account* in the Start menu (not a system variable, which every account
  on the PC can read). Then quit SolStream from the tray and start it again.

Once the repository is public, none of this is needed and you can delete the
token. [`docs/updates.md`](docs/updates.md) has the full details.

## How it works

There are two programs, plus a protocol of their own between them.

The **host** runs on the PC. It lists your windows and installed apps, starts
apps when asked, and moves the one you're streaming onto a **virtual display**.
That's a screen with no monitor behind it, sized to match your Mac exactly, so
nothing you do on the real monitor ends up in the stream. Then the host
captures the window, encodes it with the graphics card's H.264 encoder and
sends it. Sound comes from the streamed apps only, compressed with Opus or
sent lossless, whichever you pick.

The **Mac client** shows the app picker, opens the windows, decodes the video
with VideoToolbox and sends your keyboard and mouse back.

The two talk over a TCP control channel and SMT/1, SolStream's own media
transport. SMT/1 is plain UDP with AES-256-GCM on every packet. Both channels
are encrypted, with keys agreed once the Mac has proved it knows the pairing
token. The design is in [`docs/transport-smt1.md`](docs/transport-smt1.md).

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

On a real PC at 3600×2338 (a little more than 4K), with full-screen content
the GPU redraws constantly, it held 49 fps without losing a frame. The time
from capture to the last byte leaving the PC was 6.4 ms at best and 20.6 ms on
average.

## Building

**Mac client.** You need Xcode's command-line tools on macOS 14 or newer.

```bash
cd macos/SolStreamClient && swift build && swift test
```

`scripts/package-macos.sh --dev` builds `SolStream.app`, and from it
`dist/SolStream-X.Y.Z-macOS.zip` and `.dmg`. Add `--universal` to include
Intel Macs, as releases do. The version always comes from the `VERSION` file.

**Windows host.** You need CMake and Visual Studio's C++ tools (MSVC).

```
cmake --build build --target SolStreamAgent --config Release
```

`scripts/package-windows.ps1` turns that into `dist\SolStreamSetup-X.Y.Z.exe`,
plus a copy named `SolStreamSetup.exe`. That one file is the whole installer:
run it and it copies itself into Program Files, opens the two ports it needs
and sets itself to start at logon. `--uninstall` reverses all of it.

On a Mac you can sanity-check the Windows code with
`sh windows/SolStreamAgent/build-cross.sh`, which compiles it with mingw. Only
MSVC builds the real thing, though. The capture and encoding code needs
C++/WinRT and Media Foundation, which mingw doesn't have, and a clean mingw
build has hidden a broken MSVC one before.

To publish a release, push a version tag. See
[`docs/releasing.md`](docs/releasing.md).

## Where things are

| Path | What's in it |
| --- | --- |
| `macos/SolStreamClient/` | The Mac app, a Swift package. |
| `macos/SolStreamClient/Sources/MediaSession/` | The Mac half of SMT/1. |
| `windows/SolStreamAgent/` | The Windows host. It has its own [README](windows/SolStreamAgent/README.md). |
| `windows/SolStreamAgent/media/` | The PC half of SMT/1: capture, encode, packetize, pace, send. |
| `windows/VirtualDisplay/` | Setting up the virtual display. |
| `scripts/` | Packaging for both platforms, and release signing. |
| `.github/workflows/` | CI and the release pipeline. |
| `docs/` | Design notes. |
| `spike/` | Small throwaway programs, each written to answer one question, kept for the answers. |

## Licence

All rights reserved. SolStream has no open-source licence. If you have access
to this repository you can read the code, but you can't copy, change or
redistribute it without the owner's permission.

The Windows host includes one outside library: [libopus](https://opus-codec.org)
1.6.1 (BSD 3-clause), which compresses the sound unless you choose Lossless.
Windows has no Opus encoder of its own, and its built-in AAC encoder can't do
64 or 256 kbit/s and adds about 50 ms of delay. What was taken and why is in
[`third_party/opus/SOLSTREAM.md`](third_party/opus/SOLSTREAM.md), and
`SolStream.exe --licenses` prints the licence. The Mac decodes Opus with
AudioToolbox.

Two earlier dependencies are gone. [Sunshine](https://github.com/LizardByte/Sunshine)
(GPL-3.0) used to do the capture and encoding, and
[ENet](https://github.com/lsalzman/enet) (MIT) carried its control stream.
SolStream does both itself now, so nothing it ships is under the GPL.

The [Virtual Display Driver](https://github.com/VirtualDisplay/Virtual-Display-Driver)
is optional, installed separately, and never bundled.

Everything else comes with the operating systems: BCrypt, Media Foundation and
Windows.Graphics.Capture on Windows; CryptoKit, VideoToolbox, AudioUnit and
AudioToolbox on the Mac.
