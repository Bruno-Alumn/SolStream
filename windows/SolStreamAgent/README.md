# SolStream Agent

The Windows half of single-application streaming. It places a chosen
application window at a known rectangle on a chosen display and reports where
it is, so the Mac can crop that rectangle out of the single video stream and
present it as a native window.

Plain Win32 only — `SetWindowPos`, `EnumWindows`, `GetMonitorInfo`, a socket.
No D3D, no WinRT, no COM. That is deliberate: it is developed on a Mac and
cross-compiled, so it must be the kind of code that can be written correctly
without a debugger.

## Building

On Windows (what you actually run):

```
cmake --build build --target SolStreamAgent --config Release
```

On macOS/Linux, to catch compile and link errors early:

```
brew install mingw-w64
./build-cross.sh
```

The cross build links statically and imports only OS DLLs, so the resulting
`SolStreamAgent.exe` is self-contained on Windows 10+.

## Running

```
SolStreamAgent.exe --port 47997
```

It **listens**, so Windows Firewall will prompt once on first run and you must
allow it on the private/Tailscale network. (An earlier design dialled out to
avoid this; listening turned out simpler and needs no knowledge of the Mac's
address.) No admin rights, no driver, no service. Kill it in Task Manager and
the machine is exactly as it was.

## It must run in the interactive session

Verified on real hardware, and it is not optional. A process launched over SSH
runs in **session 0**, where `EnumDisplayMonitors` reports a phantom
`WinDisc` 1024x768 display and `EnumWindows` returns **nothing** — session 0
has no access to the logged-on user's desktop. The same agent launched into the
console session (7 on this machine) correctly reports `\\.\DISPLAY1`
2560x1440 and the real window list.

So in production the agent is a **logon-triggered scheduled task**, not a
service. For development, `dev-remote.sh` builds over SSH but launches through
an interactive scheduled task:

```
schtasks /create /tn SolStreamAgentDev /tr "...\run_agent.bat" /sc ONLOGON /it /f
schtasks /run /tn SolStreamAgentDev
```

Sockets are not session-isolated, so once it is running in the user's session it
can still be driven over loopback from an SSH session.

Remove the dev task with `schtasks /delete /tn SolStreamAgentDev /f`.

## Protocol

Newline-delimited JSON over TCP, one request per line, one reply per line.
On connect the agent sends a `hello` then a `displays` message unprompted.

Only one client is served at a time, which is all the Mac needs. A second
connection is REFUSED with a `busy` line naming the host, rather than left in
the accept backlog to look like a connection that is merely slow.

## Where it listens

Loopback by default, so out of the box the Mac cannot reach it at all. Anywhere
else, a token is required as well (see below) — but the bound address is still
worth choosing carefully, so that the token is a second lock rather than the
only one.

```
--bind 100.64.0.5     one address; prefer a VPN interface
--listen-all          every interface; a plain LAN is an open door
```

Binding a Tailscale (or similar) address is the sensible middle: those peers are
already device-authenticated at the network layer, so the socket is reachable from
your own machines and from nowhere else.

## Token

Reachability is not authentication, so a client on a non-loopback address must
present a shared token before **any** command is accepted — including the display
list, which would otherwise leak the machine's monitor layout to anyone who can
open a socket. The token is generated on first run and kept in the user's own
profile at `%LOCALAPPDATA%\SolStream\agent.token`.

```
SolStreamAgent.exe --print-token
```

Paste it into the prompt SolStream shows the first time it connects, or pass it
once with `--agent-token <token>`. Either way it is remembered per host.

`SolStreamAgent.exe --licenses` prints the licence of the one third-party
component compiled in: libopus, which encodes the sound. See
`third_party/opus/SOLSTREAM.md`.

Loopback is exempt, because reaching it already means running as a user on this
machine — strictly more access than the agent grants. That exemption is what lets
an SSH port forward work without a token.

`--no-auth` waives the token, and is **refused on any address but loopback** —
the agent exits rather than starting. It used to be allowed anywhere with a
warning, which was the wrong instrument: the agent starts from a scheduled task
at logon, so the warning went to a log nobody reads on a machine whose owner
believed the VPN was the boundary.

Comparison is constant-time and a wrong token costs a one-second delay, which a
legitimate client never pays and a guesser always does.

What this is **not**: the token authenticates the client to the host and nothing
more. It is sent in plaintext, so it neither encrypts the session nor protects
against someone who can read the traffic. On a home LAN or a VPN that is the right
amount of security for what it guards; on a hostile network it is not.

| request | reply |
|---|---|
| `{"cmd":"displays"}` | `{"type":"displays","displays":[{"name","adapter","x","y","w","h","primary"}]}` |
| `{"cmd":"windows"}` | `{"type":"windows","windows":[{"id","pid","title","class","x","y","w","h","captionInset","occluded"}]}` |
| `{"cmd":"apps"}` | `{"type":"apps","apps":[{"name","path"}]}` |
| `{"cmd":"media","op":"open","cpub":"…","cnonce":"…","display":"\\\\.\\DISPLAY5"}` | `{"type":"media","ok":true,"hpub","hnonce","hcount","hauth","hport","streaming"}` |
| `{"cmd":"media","op":"stats"}` | `{"type":"media","ok":true,"stats":{…}}` |
| `{"cmd":"media","op":"stop"}` | `{"type":"media","ok":true}` |
| `{"cmd":"canvas","display":"\\\\.\\DISPLAY7","w":..,"h":..}` | `{"type":"canvas","ok":bool,"w","h"}` |
| `{"cmd":"launch","path":"…","timeoutMs":N}` | `{"type":"window","id":N,"alive":true,…}` |
| `{"cmd":"window","id":N}` | `{"type":"window","id":N,"alive":bool,"minimized":bool,"x","y","w","h","captionInset"}` |
| `{"cmd":"place","id":N,"x":..,"y":..,"w":..,"h":..}` | `{"type":"placed","ok":true,"x","y","w","h"}` |
| `{"cmd":"focus","id":N}` | `{"type":"focused","ok":true}` |
| `{"cmd":"topmost","id":N,"topmost":bool}` | `{"type":"topmost","ok":true}` |

`displays[].name` is the `DXGI_OUTPUT_DESC.DeviceName` form (`\\.\DISPLAY1`) —
the same string the media session names, so the capture display
can be selected without the user copying anything by hand. `adapter` is the GDI
adapter description, which is how the Mac tells a virtual display from a real one.

Window `x/y/w/h` describe the **client area** in virtual-desktop coordinates,
not the window frame. That is what gets cropped out of the stream, and it is
what `place` positions: the agent measures the current frame-to-client offset
and compensates, rather than computing it from `AdjustWindowRect`, which does
not account for DPI scaling, custom frames, or DWM's invisible resize borders.

`captionInset` is how many pixels of non-client title bar sit above the client
area. Because the crop *is* the client area, a window reporting 31 there has its
minimise/maximise/close buttons excluded for free. A window reporting 0 draws its
own caption inside the client area — Explorer, Chrome and Discord all do — and
there the buttons share a strip with tabs and the address bar, so cropping them
off would take real UI with them. The Mac leaves those alone and polls `window`
instead, so that closing the application from inside the stream ends the session.

`launch` **blocks** until the application shows a window, which can be many
seconds for a cold start. It watches for a window that was not open before,
preferring one belonging to the process it started; if none appears it falls back
to a newly-focused window, because an application that was already running
usually reuses its existing window instead of opening another.

`canvas` points a display at the mode that best fits what the Mac asks for — the
smallest offered mode covering both axes, so a window is never upscaled, falling
back to the largest if nothing covers it. It only ever *switches* between modes
the driver already offers, which is immediate. Adding a mode is the expensive
operation (a device restart), so the modes are seeded once by
`windows/VirtualDisplay/setup-virtual-display.ps1`.

The Mac only asks this of a **virtual** display. A physical monitor is somebody's
actual screen and its mode is not ours to change.

## Pairing

The Mac has to prove it holds this PC's pairing token before the agent answers
anything. The token is sixteen random bytes, shown on the host application's own
window under "Pairing token", and typed into the Mac once.

It never crosses the wire. The host sends a challenge in its `hello`; the Mac
answers `HMAC-SHA256(token, "SolStream agent auth v2" || challenge || cnonce)`,
and the same token is mixed into the input key material of every media session.

There used to be a whole section here about approving a Sunshine PIN on the
user's behalf: its web UI behind a self-signed certificate, credentials the user
had to create first, DPAPI storage for the password, and a POST to a local
`/api/pin` that skipped its CSRF check because the request carried no Origin.
All of it existed to spare a non-technical user a browser. There is no PIN now.

## Toolchain differences that bite

The cross build uses mingw-w64, your build uses MSVC, and they do not agree.
mingw is the more permissive of the two, so **the Windows build is the source
of truth** — a clean `./build-cross.sh` does not prove MSVC will be happy.
Known divergences, all handled in the source:

- `windows.h` defines `min`/`max` as macros unless `NOMINMAX` is set, which
  turns `std::max(` into `std::(` and makes MSVC emit "illegal token on right
  side of `::`". mingw does not define them at all.
- mingw pulls in `<cstdarg>`/`<cstdlib>` transitively; MSVC does not.
- `SetProcessDpiAwarenessContext` is guarded behind an API level in the MSVC
  SDK, hence the explicit `_WIN32_WINNT 0x0A00`.
- `_wtoi` is a Microsoft extension. Standard `std::wcstol` is used instead.

## Notes for future work

- The process is per-monitor DPI aware (v2). Without that every coordinate
  would be silently rescaled by Windows on any display not at 100%.
- Cloaked windows are filtered out; UWP leaves invisible ghost windows that
  otherwise fill the list.
- Window lifecycle is watched with `SetWinEventHook` (created, shown, hidden,
  destroyed, renamed) and pushed to the Mac as a debounced `windowsChanged`
  nudge, so the picker's list is live rather than a snapshot taken on connect.
  The hook is installed on the message-loop thread, because an out-of-context
  hook delivers its callbacks through the loop of the thread that set it.

## Installing

`scripts/package-windows.ps1` builds the folder that ships; `SolStream.exe --install`
puts it in place. Installation is a step rather than a copy for one reason:

Windows will not let a program accept connections it has never been asked
about. Normally it asks — the first time a program listens, a dialog appears and
the answer becomes a firewall rule. SolStream starts from a logon task, which
has no desktop to show a dialog on, so nothing asks and Windows decides for
itself: it writes a **Block** rule, and the host silently accepts nothing.

That block cannot be undone by adding permission afterwards. An explicit Block
beats an Allow, so a later "allow this program" rule changes nothing. Measured:
with SolStream's binaries blocked this way, ports 47595–47630 were refused from
the Mac while 22, 47984 and 47989 stayed open, and neither a program-scoped nor
a port-scoped Allow rule reopened them.

So the installer creates its rules **before** anything listens, and removes
stale Blocks for its own paths rather than trying to out-rank them.

## Why a logon task rather than a Windows service

Every other program of this kind installs itself as a service, so the obvious
question is why this does not. The answer is session 0.

A service runs in session 0, which has a phantom 1024x768 display, no window
station and no user desktop. From there this program can see none of the things
it exists to see: `EnumWindows` returns nothing of the user's, the display list
is a fiction, and it has nowhere to put its own window. A service could only
launch the real work into the interactive session and supervise it, which is a
second program and a supervision protocol to maintain for no gain.

Against that, what a service buys is: the host keeps running when nobody is
logged in. But nothing SolStream does is useful then. There is no desktop to
capture, no application windows to place, and the virtual display's contents
would be a logon screen. Streaming a PC that nobody is logged into is not a
feature that was lost.

So: a logon task, running interactively as the logged-on user. It starts when
they log in, which is exactly when there is something to stream.

## The virtual display

SolStream streams a virtual display rather than a real monitor. That is not a
preference:

* a window can be any size, instead of being capped by the monitor's resolution;
* the display's mode can be matched to the Mac exactly, so every pixel is 1:1
  rather than resampled;
* nothing can be dragged over the streamed window by somebody at the PC, because
  nobody is looking at that display.

Without one, SolStream captures a real screen and all three stop being true.

No driver is bundled with this repository. Setup offers to install one, ticked
by default, when the PC has none: the
[Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
(MIT, user-mode UMDF, signed by SignPath Foundation). It downloads one pinned
release, keeps it only if its SHA-256 matches the one in `driver_install.cpp`,
installs it, and creates the `Root\MttVDD` device `pnputil` never made. The host
window's **Set up** button and `SolStream.exe --install-display-driver` run the
same steps. Uninstalling removes only what that install added.
`installer/README.md` has the whole sequence, and how ownership is recorded.

A driver installed by hand works just as well: start SolStream and it picks
that display, and the media session names it when a Mac connects.

## One Mac at a time

The agent serves one client and refuses the next with a `busy` line naming the
host, rather than leaving it in the accept backlog. There is one capture, one
encoder and one media socket, so two Macs streaming from one PC is not
supportable however the socket is written. What it can do is say so in 8ms
instead of appearing to connect forever.

The refusal carries the same fields as `status`, so a second Mac (or a person
diagnosing one) can still tell whether the host is healthy.
