# SolStream Agent

The Windows half of single-application streaming. It places a chosen
application window at a known rectangle on a chosen display and reports where
it is, so the Mac can crop that rectangle out of the single video stream and
present it as a native window. The same program captures that display, encodes
it and sends it (`media/`), shows the host window and tray icon, and installs
and updates itself.

The control side is plain Win32 — `SetWindowPos`, `EnumWindows`,
`GetMonitorInfo`, a socket. That is deliberate: it is developed on a Mac, so
that part has to be the kind of code that can be written correctly without a
debugger. The media path beside it is not: capture is Windows.Graphics.Capture
through C++/WinRT on Direct3D 11, encoding is Media Foundation, the sound is
WASAPI and libopus, the host window is Direct2D, and the logon task and the
shortcuts are COM. mingw has none of that, so only MSVC builds the real thing.

## Building

On Windows (what you actually run):

```
cmake --build build --target SolStreamAgent --config Release
```

That leaves `build\bin\release\SolStreamAgent.exe`. On macOS/Linux, to catch
compile and link errors early:

```
brew install mingw-w64
./build-cross.sh
```

The cross build links statically and imports only OS DLLs, so the resulting
`SolStreamAgent.exe` is self-contained on Windows 10+. It has no media path, so
it can listen and place windows but cannot stream.

## Running

```
SolStreamAgent.exe --headless
```

One program, two names. A build is `SolStreamAgent.exe`; setup copies it to
`%ProgramFiles%\SolStream\SolStream.exe`, and the logon task starts that copy as
`SolStream.exe --listen-all --background`, straight to the tray. Give a copy
you run yourself at least one argument: an uninstalled copy started with none
opens the setup window instead of an agent. `--headless` means no window and the
log on the console. `--port` moves the control socket from 47630, but the Mac
always dials 47630, so that is for tunnels and tests.

It **listens**, so Windows Firewall will prompt once on first run and you must
allow it on the private/Tailscale network. (An earlier design dialled out to
avoid this; listening turned out simpler and needs no knowledge of the Mac's
address.) An installed host does not prompt: the installer has written its
rules by then (see Installing). Run from a build it needs no admin rights, no
driver and no service. What it leaves behind is a few small files in
`%LOCALAPPDATA%\SolStream` (the token, a log, a counter) and, if the PC has a
virtual display, that display set up the way it streams.

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

Newline-delimited JSON over TCP, one request per line, one reply per line, until
the connection proves the token; from then on every message in both directions
is a sealed record (see Pairing). On connect the agent sends a `hello`
unprompted:

```
{"type":"hello","version":2,"host":"pc-one.example","needsAuth":true,"challenge":"…","channelCrypto":2}
```

The `displays` message follows at once only where no token is needed. Otherwise
it follows the reply that accepts the token, so the monitor layout is not
volunteered to anyone who can open the socket. Until then the agent answers
`ping`, `status` and `auth` and nothing else; any other command gets
`{"type":"error","message":"unauthenticated","needsAuth":true}`.

Only one client is served at a time, which is all the Mac needs. Once that
client has proved the token, a second connection is REFUSED with a `busy` line
naming the host, rather than left in the accept backlog to look like a
connection that is merely slow. A connection that arrives while the first is
still sitting on the token prompt, or while an update is being installed, is
closed without a word instead: `busy` would be untrue, because nobody is
streaming, and the Mac takes a plain close to mean "try again shortly".

## Where it listens

Three ports, from `ports.h`. The Mac's copy of the table is
`macos/SolStreamClient/Sources/AgentChannel/StreamPorts.swift`, and the two have
to agree.

```
TCP 47630    this protocol
UDP 47631    SMT/1: the video, the sound, and the input coming back
UDP 47629    discovery: a Mac asks, the host answers with its computer name
```

Discovery is one datagram each way. It discloses the computer's name and nothing
else, to whoever is on the same network segment, and grants nothing: every
command still needs the token.

A build run by hand binds the control socket to loopback by default, so out of
the box the Mac cannot reach it at all. The installed copy does not: the logon
task starts it with `--listen-all`, and a copy running from Program Files binds
every interface unless it is given `--bind`, because an installed host that only
answered on loopback would be one no Mac could reach. Anywhere else, a token is
required as well (see below) — but the bound address is still worth choosing
carefully, so that the token is a second lock rather than the only one.

```
--bind 100.64.0.5     one address; prefer a VPN interface
--listen-all          every interface; a plain LAN is an open door
```

Binding a Tailscale (or similar) address is the sensible middle: those peers are
already device-authenticated at the network layer, so the socket is reachable from
your own machines and from nowhere else.

An address that does not exist yet, such as a VPN interface at logon, is waited
for, up to five minutes, rather than given up on.

## Token

Reachability is not authentication, so a host that listens beyond loopback makes
every client prove it holds a shared token before **any** command is accepted —
`ping`, `status` and the proof itself aside, and including the display list,
which would otherwise leak the machine's monitor layout to anyone who can open a
socket. The token is generated on first run and kept in the user's own profile at
`%LOCALAPPDATA%\SolStream\agent.token`.

```
SolStream.exe --print-token
```

Paste it into the prompt SolStream shows the first time it connects, or pass it
once with `--agent-token <token>`. Either way it is remembered per host.

`SolStream.exe --licenses` prints the licence of the one third-party
component compiled in: libopus, which encodes the sound. See
`third_party/opus/SOLSTREAM.md`.

Where the host is bound to loopback alone no token is asked for, because
reaching it already means running as a user on this machine — strictly more
access than the agent grants. That exemption is what lets an SSH port forward
work without a token. An installed host listens beyond loopback, so it asks
everyone, local or not.

`--no-auth` waives the token, and is **refused on any address but loopback** —
the agent exits rather than starting. It used to be allowed anywhere with a
warning, which was the wrong instrument: the agent starts from a scheduled task
at logon, so the warning went to a log nobody reads on a machine whose owner
believed the VPN was the boundary.

Comparison is constant-time, and a wrong proof is counted rather than slept on: a
delay would hold the one client slot shut against the paired Mac, which is the
attacker's goal rather than his cost. The third refused proof on a connection
drops it, and the next connection starts again at three. A connection that has
proved nothing is dropped after 15 seconds of silence, and after two minutes
however busy it keeps the line. One that has proved the token is dropped after 30
seconds of silence, which the Mac's ten-second `ping` never allows. The proof is
the only way in: the cleartext `{"cmd":"auth","token":…}` of the first version is
refused with a message to update SolStream on the Mac, not accepted, because
accepting it would be a downgrade to a session with no encryption.

What this is **not**: protection against someone who has the token. Anyone who
can read it can pair with this PC, and the file is not encrypted — deliberately,
since the point is for the person at the machine to read it and give it to their
Mac. The host window hides it while a Mac is connected. What it does protect
against is someone who can only read the traffic: the token is never sent, and
everything after the proof is encrypted (see Pairing).

## Commands

| request | reply |
|---|---|
| `{"cmd":"ping"}` | `{"type":"pong"}` (before authentication) |
| `{"cmd":"status"}` | `{"type":"status","ok":true,"agent":"listening","clients","streaming","mediaPort","captureDisplay","virtualDisplay"}` (before authentication) |
| `{"cmd":"auth","proof":"…","cnonce":"…","channelCrypto":2,"cpub":"…"}` | `{"type":"auth","ok":true,"channelCrypto":2,"hpub","hauth"}`, or `{"type":"auth","ok":false,"message":"bad token"}` |
| `{"cmd":"displays"}` | `{"type":"displays","displays":[{"name","adapter","x","y","w","h","primary","captured"}]}` |
| `{"cmd":"windows"}` | `{"type":"windows","windows":[{"id","pid","title","class","x","y","w","h","exStyle","captionInset","naturalW","naturalH","occluded","occludedBy"}]}` |
| `{"cmd":"apps"}` | `{"type":"apps","apps":[{"name","path"}]}` |
| `{"cmd":"icon","id":N}` or `{"cmd":"icon","path":"…"}` | `{"type":"icon","ok":true,"id","w","h","bgra"}`, base64, 64x64 |
| `{"cmd":"clipboard"}` or `{"cmd":"clipboard","seq":N}` | `{"type":"clipboard","ok":true,"seq","truncated","text"}`, or `"unchanged":true` when `seq` is still current |
| `{"cmd":"clipboard","text":"…"}` | `{"type":"clipboard","ok":true,"seq"}` |
| `{"cmd":"media","op":"open","cpub":"…","cnonce":"…","display":"\\\\.\\DISPLAY5"}` | `{"type":"media","ok":true,"ver":1,"hpub","hnonce","hcount","hauth","streaming","hport"}` |
| `{"cmd":"media","op":"stats"}` | `{"type":"media","ok":true,"op":"stats","stats":{…}}` |
| `{"cmd":"media","op":"stop"}` | `{"type":"media","ok":true,"op":"stop"}` |
| `{"cmd":"media","op":"retarget","display":"…"}` or `"window":N` | `{"type":"media","ok":bool,"op":"retarget"}` |
| `{"cmd":"canvas","display":"\\\\.\\DISPLAY7","w":..,"h":..}` | `{"type":"canvas","ok":bool,"w","h","hz"}` |
| `{"cmd":"launch","path":"…","timeoutMs":N}` | `{"type":"window","id":N,"alive":true,…}` |
| `{"cmd":"window","id":N}` | `{"type":"window","id":N,"alive":bool,"minimized":bool,"x","y","w","h","captionInset"}` |
| `{"cmd":"place","id":N,"x":..,"y":..,"w":..,"h":..}` | `{"type":"placed","ok":bool,"x","y","w","h","minW","minH","maxW","maxH","resizable","border","missed","titleBar","program"}` |
| `{"cmd":"focus","id":N}` | `{"type":"focused","ok":bool,"foreground":bool}` |
| `{"cmd":"lock","id":N,"on":1}` | `{"type":"locked","ok":bool,"on":bool}` |
| `{"cmd":"topmost","id":N,"on":1}` | `{"type":"topmost","ok":bool,"on":bool}` |

`lock` and `topmost` take `"on":1` or `"on":0`, and read an absent `on` as 1.
Nothing reads a field called `topmost`, so `{"cmd":"topmost","id":N,"topmost":false}`
pins the window instead of releasing it.

`media open` names what to capture with `display` (the capture display, which is
how the Mac asks) or `window`, and may carry `fps` (60 unless told otherwise),
`bitrate` (bits per second, 20 million unless told otherwise), `width` and
`height` (the canvas, each held to 4096), `audio` (`1` or `0`) and `audioSource`
(`"apps"` for the streamed apps' sound alone, which needs Windows build 20348 or
later; anything else, and older Windows, sends the whole PC's). The reply's
`audioSource` says what was asked for: below build 20348 a request for `"apps"`
is answered `"apps"` and the whole PC's sound is sent anyway, and only the host's
log says so. For compressed sound it takes `audioCodec` (`"opus"`),
`audioBitrate` and `audioFrameMs`. With neither a display nor a window it still
agrees the keys, but `streaming` is false and `message` says why. The reply says whether capture and encoding really opened
(`streaming`, with a `message` when they did not), names the UDP port in `hport`,
and, when there is sound, says how it will be sent (`audioCodec`, `audioSource`).

Once the token is proved the agent also pushes lines nobody asked for.
`{"type":"windowsChanged"}` says the set of windows the picker lists has changed,
and the Mac asks for `windows` and `apps` again. `{"type":"closed","id":N}` says
a window the Mac is managing is gone. `{"type":"occluded","id":N,"by":"…"}` says
something now covers one, and `by` is empty once it is clear.
`{"type":"cursor","shape":"arrow","reportsHidden":1}` carries the pointer's shape,
or `"hidden"` while an application has taken the cursor off the screen.

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
What the application draws there is measured separately: `place` replies with
`titleBar`, the height in pixels of the strip an application draws inside its own
client area (0 for none, or when that cannot be told), and `program`, the
executable that owns the window. With those the Mac can leave the strip out of
the picture when the person chooses, and remembers the choice per program.

`launch` **blocks** until the application shows a window, which can be many
seconds for a cold start. It watches for a window that was not open before,
preferring one belonging to the process it started; if none appears it falls back
to a newly-focused window, because an application that was already running
usually reuses its existing window instead of opening another.
It refuses a path that `apps` did not list, and `timeoutMs` is held between one
and sixty seconds (twenty if absent).

`canvas` points a display at the mode that best fits what the Mac asks for — the
smallest offered mode covering both axes, so a window is never upscaled, falling
back to the largest if nothing covers it, and the highest refresh rate among
equals. It only ever *switches* between modes the driver already offers, which is
immediate. Adding a mode is the expensive operation (a device restart), so the
modes are seeded once, ahead of time, by `display_setup.cpp`: setup runs it, and
so does `SolStream.exe --configure-display`. The older, manual route to the same
thing is `windows/VirtualDisplay/setup-virtual-display.ps1`.

The Mac only asks this of a **virtual** display. A physical monitor is somebody's
actual screen and its mode is not ours to change, and the host does not take the
Mac's word for it: it changes only the virtual display it is capturing, and
answers `ok:false` for any other name.

## Pairing

The Mac has to prove it holds this PC's pairing token before the agent answers
anything but `ping` and `status`. The token is sixteen random bytes, shown on the
host application's own window under "Pairing token", and typed into the Mac once.

It never crosses the wire. The host sends a challenge in its `hello`; the Mac
answers `HMAC-SHA256(token, "SolStream agent auth v2" || challenge || cnonce)`,
and the same token is mixed into the input key material of every media session.

The same message that proves the token agrees the keys for the rest of the
connection. The Mac adds an ephemeral P-256 public point (`cpub`) to its proof,
and the host answers with its own (`hpub`) and a `hauth` the Mac checks, which is
the only thing that makes the host prove itself to the Mac. From the next
message on, each message in either direction is one AES-256-GCM record: a
four-byte big-endian length, then an 8-byte SMT/1 header, the ciphertext and a
16-byte tag (`media/channel.h`). The keys come from the ECDH secret and the token
together, so they are forward secret and still authenticated: the host destroys
its ephemeral private key before it builds the reply, and someone who learns the
token later can decrypt nothing they recorded earlier. Encryption is negotiated,
so the host will stay in the clear with a client that proves the token and does
not ask for it. The Mac asks whenever the host offers it in its `hello`, and
refuses to carry on if the connection would end up in the clear.

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

`scripts/package-windows.ps1` builds the one file that ships,
`SolStreamSetup-X.Y.Z.exe`, which is `SolStreamAgent.exe` under another name.
Run from anywhere but `%ProgramFiles%\SolStream` it shows the setup window, whose
**Install** button (or `--install` on the command line) copies it into place as
`%ProgramFiles%\SolStream\SolStream.exe`. Installation is a step rather than a
copy for one reason:

Windows will not let a program accept connections it has never been asked
about. Normally it asks — the first time a program listens, a dialog appears and
the answer becomes a firewall rule. SolStream starts from a logon task, where
nobody is placed to answer it (on this project the dialog once landed on the
virtual display, which no monitor shows), so Windows decides for itself: it
writes a **Block** rule, and the host silently accepts nothing.

That block cannot be undone by adding permission afterwards. An explicit Block
beats an Allow, so a later "allow this program" rule changes nothing. Measured,
back when SolStream ran Sunshine beside it: with the binaries blocked this way,
ports 47595–47630 were refused from the Mac while 22, 47984 and 47989 stayed
open, and neither a program-scoped nor a port-scoped Allow rule reopened them.

So the installer creates its rules **before** anything listens, two of them, each
naming the program and its ports (TCP 47630, and UDP 47631 and 47629) on every
profile. Uninstalling removes every rule that points into the install folder,
Windows' own included, rather than leaving a Block to out-rank the next install's
Allow.

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
release (`kDriverVersion`, in `driver_install.h`), keeps it only if its SHA-256
matches `kPackageSha256` in `driver_install.cpp`, installs it, and creates the
`Root\MttVDD` device `pnputil` never made. The host
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

The refusal is `{"type":"busy","message":"…","virtualDisplay":bool}`: the message
names the host, and `virtualDisplay` says whether it has one, so a second Mac (or
a person diagnosing one) can still tell which PC answered and whether it is set
up. Only a client that has proved the token counts as streaming; an open socket
that has not is closed without a word, as above.
