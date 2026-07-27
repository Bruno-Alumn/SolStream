# SolStream Agent

The Windows half of single-application streaming. It places a chosen
application window at a known rectangle on a chosen display and reports where
it is, so the Mac can crop that rectangle out of the single Sunshine stream and
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
schtasks /create /tn SolStreamAgentDev /tr "...\run_agent.bat" /sc ONCE /st 00:00 /it /f
schtasks /run /tn SolStreamAgentDev
```

Sockets are not session-isolated, so once it is running in the user's session it
can still be driven over loopback from an SSH session.

Remove the dev task with `schtasks /delete /tn SolStreamAgentDev /f`.

## Protocol

Newline-delimited JSON over TCP, one request per line, one reply per line.
On connect the agent sends a `hello` then a `displays` message unprompted.

Only one client is served at a time, which is all the Mac needs — but it does
mean a second connection blocks in the accept backlog rather than being refused.

| request | reply |
|---|---|
| `{"cmd":"displays"}` | `{"type":"displays","displays":[{"name","adapter","x","y","w","h","primary"}]}` |
| `{"cmd":"windows"}` | `{"type":"windows","windows":[{"id","pid","title","class","x","y","w","h","captionInset","occluded"}]}` |
| `{"cmd":"apps"}` | `{"type":"apps","apps":[{"name","path"}]}` |
| `{"cmd":"pair","pin":"1234","name":"…"}` | `{"type":"paired","ok":bool,"reason","message"}` |
| `{"cmd":"canvas","display":"\\\\.\\DISPLAY7","w":..,"h":..}` | `{"type":"canvas","ok":bool,"w","h"}` |
| `{"cmd":"launch","path":"…","timeoutMs":N}` | `{"type":"window","id":N,"alive":true,…}` |
| `{"cmd":"window","id":N}` | `{"type":"window","id":N,"alive":bool,"minimized":bool,"x","y","w","h","captionInset"}` |
| `{"cmd":"place","id":N,"x":..,"y":..,"w":..,"h":..}` | `{"type":"placed","ok":true,"x","y","w","h"}` |
| `{"cmd":"focus","id":N}` | `{"type":"focused","ok":true}` |
| `{"cmd":"topmost","id":N,"topmost":bool}` | `{"type":"topmost","ok":true}` |

`displays[].name` is the `DXGI_OUTPUT_DESC.DeviceName` form (`\\.\DISPLAY1`) —
the same string Sunshine's `output_name` setting takes, so the capture display
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

## Pairing without the web UI

Sunshine's own pairing asks the user to open its web UI, get past a self-signed
certificate warning, create credentials and find the PIN page. `pair` does that
step for them: the Mac sends the PIN it is displaying and the agent POSTs it to
Sunshine's local `/api/pin`.

Two things make that possible. `/api/pin` takes HTTP Basic auth, and its CSRF
check is skipped outright for a request carrying neither `Origin` nor `Referer` —
those cannot be browser-initiated, so a non-browser client needs no token
(`confighttp.cpp`, `validate_csrf_token`). The reply is judged on its body rather
than its status, because `nvhttp::pin()` returns false inside an HTTP 200 when no
client is actually waiting to pair.

Sunshine stores only a salted hash of its web UI password, so the plaintext cannot
be read back off disk. Supply it once:

```
SolStreamAgent.exe --set-sunshine-credentials
```

It prompts (the password is never taken as an argument, where the process list
would expose it), stores it with DPAPI under `%LOCALAPPDATA%\SolStream\`, and
immediately checks it against Sunshine so a wrong password fails now rather than
mid-pairing. DPAPI ties the blob to the Windows *user account*, not the session —
verified by writing it from an SSH session (session 0) and decrypting it from the
agent in the console session.

With no credentials stored, `pair` returns `reason:"no-credentials"` and the Mac
falls back to displaying the PIN, which is no worse than Sunshine's own flow.

Store/UWP applications are **not** listed by `apps`: it walks the Start Menu for
`.lnk` shortcuts, and packaged apps (Notepad and Calculator on Windows 11) are
surfaced from the app database rather than as shortcuts. Every classic desktop
application is there.

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
- Not yet implemented: `SetWinEventHook` lifecycle events (window created,
  renamed, destroyed) and icon extraction. The Mac currently has to poll
  `windows`.
