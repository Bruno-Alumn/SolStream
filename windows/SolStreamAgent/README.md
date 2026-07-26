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

## Protocol

Newline-delimited JSON over TCP, one request per line, one reply per line.
On connect the agent sends a `hello` then a `displays` message unprompted.

| request | reply |
|---|---|
| `{"cmd":"displays"}` | `{"type":"displays","displays":[{"name","x","y","w","h","primary"}]}` |
| `{"cmd":"windows"}` | `{"type":"windows","windows":[{"id","pid","title","class","x","y","w","h"}]}` |
| `{"cmd":"place","id":N,"x":..,"y":..,"w":..,"h":..}` | `{"type":"placed","ok":true,"x","y","w","h"}` |
| `{"cmd":"focus","id":N}` | `{"type":"focused","ok":true}` |

`displays[].name` is the `DXGI_OUTPUT_DESC.DeviceName` form (`\\.\DISPLAY1`) —
the same string Sunshine's `output_name` setting takes, so the capture display
can be selected without the user copying anything by hand.

Window `x/y/w/h` describe the **client area** in virtual-desktop coordinates,
not the window frame. That is what gets cropped out of the stream, and it is
what `place` positions: the agent measures the current frame-to-client offset
and compensates, rather than computing it from `AdjustWindowRect`, which does
not account for DPI scaling, custom frames, or DWM's invisible resize borders.

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
