# The virtual display

SolStream shows one Windows application by cropping its rectangle out of a
captured display. Whatever is at those coordinates gets streamed — so if the
application lives on the real monitor, any window dragged over it appears inside
the crop as though it were part of the app.

Pinning the window topmost and detecting occlusion help, but they are mitigations.
Putting the application on a display with **no physical panel** removes the
problem at the source: nothing is ever dragged onto it by accident.

## Why not an HDMI dummy plug

A dummy plug also gives a display nobody looks at, and it is £8 and stateless.
The reason to prefer a virtual display is **resolution**.

For a streamed window to be pixel-crisp, the host window's client area must hold
as many pixels as the Mac window can display: macOS points × backing scale
factor. On the development Mac that is 1800×1169 points at 2×, so **3600×2338**.

No dongle offers 3600×2338. Its EDID has a fixed mode list — you get 2560×1440
(upscaled, visibly soft) or 3840×2160 (≈30% of every encoded frame is canvas you
never show). A virtual display's mode list is a config file, so it can be made to
match the client exactly and Sunshine scales by 1.0.

The cost is a driver install and admin rights, plus something that can break
across Windows updates.

It is **not** a kernel-mode driver, despite what an earlier version of this file
said. `MttVDD.inf` declares `UmdfService=MttVDD`, `UmdfLibraryVersion=2.25.0` and
`UmdfExtensions = IddCx0102` — it is a user-mode driver on the User-Mode Driver
Framework, which is what IddCx indirect displays are. It cannot bugcheck the
machine; a crash takes out the driver host process, not Windows. Worth knowing
before weighing up whether to ship it to other people.

## Driver

[MikeTheTech's Virtual Display Driver](https://github.com/VirtualDisplay/Virtual-Display-Driver),
an IddCx indirect display driver. It is signed by the SignPath Foundation, so it
installs without enabling test-signing — which matters, because test-signing is a
machine-wide relaxation of driver signature enforcement and not something worth
turning on for this.

Its mode list is `C:\VirtualDisplayDriver\vdd_settings.xml`, read when the device
starts. Adding a mode therefore needs a device restart, not just a file edit.

**DXGI desktop duplication works on it.** That was the load-bearing unknown:
Sunshine only offers a display if `desc.AttachedToDesktop && test_dxgi_duplication(...)`
([`display_base.cpp:1111`](../../references/sunshine/src/platform/windows/display_base.cpp)),
and a virtual display that could not be duplicated would have been useless. It
duplicates, and Sunshine encodes it at the full 3600×2338 with no scaling.

## Setup

Run **elevated**, and **in the interactive session** — from your own PowerShell
window, not over SSH:

```powershell
powershell -ExecutionPolicy Bypass -File setup-virtual-display.ps1 -Width 3600 -Height 2338 -Scale 200 -ConfigureSunshine
```

Pick `-Width`/`-Height` from what SolStream logs on startup:

```
[canvas] host display 3600x2338; this Mac is 1800x1169 points @2.0x = 3600x2338 physical
```

The client then selects the virtual display on its own; `--display <substring>`
overrides that, matching either the device name or the adapter.

### Why 200% scaling

The DPI scale must match the Mac's backing scale factor, not be left at whatever
Windows guesses. At 200% Windows draws UI at 2×, macOS displays it at 2×, and a
Windows control ends up the same physical size as a native macOS one — 1800×1169
logical points on the host mapping onto 1800×1169 Mac points, exactly 1:1.

Windows independently reports 200% as the *recommended* scale for a 3600×2338
display, which is a useful sanity check. It had auto-assigned 250%.

### Resolution is fixed for a session

The encode canvas is negotiated once, at `/launch` and in ANNOUNCE. Changing the
display mode mid-session would mean tearing the stream down and reconnecting, and
a mode change also fires `WM_DISPLAYCHANGE`, reflowing every application on that
display and forcing Sunshine to reinitialise capture.

So the canvas is chosen once and windows are resized *within* it. Two consequences
worth remembering: several windows share one canvas, so it must cover the bounding
box of all of them; and Sunshine encodes the whole display however little of it is
in use, so an oversized canvas is a real bandwidth cost rather than free headroom.

## Gotchas

Each of these cost real time; they are recorded so they do not have to again.

- **Display configuration is session-bound.** A script run over SSH or as a
  service lands in session 0, where `EnumDisplayDevices` reports a phantom
  `WinDisc` 1024×768 desktop and attaching a display silently does nothing. Use an
  interactive scheduled task (`/it`) if you must drive it remotely.
- **`CDS_NORESET` is `0x10000000`, not `0x10000`.** The wrong value is not a
  recognised flag and fails with `DISP_CHANGE_BADFLAGS` (-4).
- **`DisplaySwitch.exe /extend` does not attach it.** Stage the mode with
  `ChangeDisplaySettingsEx(..., CDS_UPDATEREGISTRY | CDS_NORESET)` and then apply
  with a null-everything call.
- **PowerShell copies nested value-type fields.** `$x.header.type = 1` on a struct
  with a nested `DISPLAYCONFIG_DEVICE_INFO_HEADER` writes to a temporary that is
  discarded, so the call goes out with a zeroed header and fails with
  `ERROR_GEN_FAILURE` (31). The structs in the setup script are flat for this
  reason.
- **`output_name` takes a device id, not a display name.** Display names get
  renumbered by a device restart (`\\.\DISPLAY5` became `\\.\DISPLAY6` here);
  Sunshine's `{...}` device id is stable. An unmatched value is not an error —
  Sunshine logs `Failed to find device for {...}!` at debug level and silently
  falls back to the default display.

## Reverting

```powershell
# Detach the virtual display (Settings > System > Display, set it to "Disconnect")
# or disable the device outright:
Get-PnpDevice -Class Display | Where-Object FriendlyName -like '*Virtual Display Driver*' |
    Disable-PnpDevice -Confirm:$false
```

The setup script backs up everything it edits alongside the original:

- `C:\VirtualDisplayDriver\vdd_settings.xml.solstream-backup`
- `C:\Program Files\Sunshine\config\sunshine.conf.solstream-backup`

Restoring `sunshine.conf` and restarting `SunshineService` puts Sunshine back to
whichever display it captured before.
