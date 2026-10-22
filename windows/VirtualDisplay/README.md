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
match the client exactly and the encoder scales by 1.0.

The cost is a driver install, which needs administrator rights (setup asks once,
and does it), plus something that can break across Windows updates.

It is **not** a kernel-mode driver, despite what an earlier version of this file
said. `MttVDD.inf` declares `UmdfService=MttVDD` and `UmdfExtensions = IddCx0102`
— it is a user-mode driver on the User-Mode Driver Framework, which is what IddCx
indirect displays are. It cannot bugcheck the machine; a crash takes out the
driver host process, not Windows. Worth knowing before weighing up whether to
offer it to other people, which setup now does.

## Driver

[MikeTheTech's Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver),
an IddCx indirect display driver. It is signed by the SignPath Foundation, so it
installs without enabling test-signing — which matters, because test-signing is a
machine-wide relaxation of driver signature enforcement and not something worth
turning on for this.

SolStream installs one pinned release of it, and keeps the download only if its
SHA-256 is the one compiled in: `kDriverVersion` in `driver_install.h`,
`kPackageSha256` in `driver_install.cpp`. `installer/README.md` has the sequence.

Its mode list is `vdd_settings.xml`, in `C:\VirtualDisplayDriver` unless the
driver's `VDDPATH` registry value says otherwise (`VddSettingsFolder`, in
`display_setup.cpp`), read when the device starts. Adding a mode therefore needs a
device restart, not just a file edit. That is why SolStream seeds a whole ladder
of Mac screen sizes up front (`kLadder`: nine modes, from 2560×1440 to 3840×2160)
and afterwards only ever *switches* between them.

**Capture works on it.** The host captures the display with
Windows.Graphics.Capture (`media/capture.cpp`, `CreateForMonitor`) and encodes it
at its own size, so nothing is resampled. `spike/swapchain/RESULTS.md` measured
49 fps at the full 3600×2338, with no loss.

## Setup

SolStream does this itself; there is nothing to run by hand. Setup installs the
driver on a PC that has none, and then `ConfigureVirtualDisplay`
(`display_setup.cpp`) makes the display fit to stream:

1. It teaches the driver its modes in `vdd_settings.xml` — the ladder, and the
   requested size if that is not on it — and turns the driver's HDR off there.
   The original file is kept once, as `vdd_settings.xml.solstream-backup`.
2. It restarts the device (`pnputil /restart-device`) so the driver re-reads the
   file, when the file changed.
3. It attaches the display to the desktop at 3600×2338, to the right of every
   other display, so it never overlaps a real monitor's coordinates.
4. It sets the display's DPI scaling to 200%.
5. It turns "Use HDR" off on the display itself.

The host runs the same function every time it starts, at logon and unelevated.
What is already right is left alone, because re-applying a mode is a display
reconfiguration that moves every window on the PC, and the part that writes the
driver's file under `C:\` needs administrator rights and is reported as undone.
The host window's **Set up** button, the tray's *Set up virtual display…* and
`SolStream.exe --install-display-driver` run all of it elevated.
`SolStream.exe --configure-display`, from an elevated prompt in the interactive
session, runs just this part for a driver that is already there.

The host then captures that display: the one `FindVirtualAdapter` scores best
(SolStream's own driver first), else any display whose adapter is the Virtual
Display Driver, else the primary monitor, with a line in the log saying so
(`ChooseCaptureDisplay`, in `main.cpp`). It chooses again once **Set up** has
installed one. The Mac follows the display the host says it captures; `--display
<substring>` overrides that, matching either the device name or the adapter.

Before it opens a session the Mac asks the host for a `canvas` the size of its own
screen in pixels (points × backing scale factor, at most 4096 on each axis). The
host switches the virtual display to the smallest mode that covers it, or says it
kept the size it had. The Mac logs the result:

```
[canvas] host display 3600x2338; this Mac shows 3600x2338 physical
```

### By hand

`setup-virtual-display.ps1` in this directory does the same from PowerShell, and
predates SolStream doing it itself. Run it **elevated**, and **in the interactive
session** — from your own PowerShell window, not over SSH:

```powershell
powershell -ExecutionPolicy Bypass -File setup-virtual-display.ps1 -Width 3600 -Height 2338 -Scale 200
```

Leave its `-ConfigureSunshine` switch off: it edits the configuration of a
Sunshine that SolStream no longer runs.

### Why 200% scaling

The DPI scale must match the Mac's backing scale factor, not be left at whatever
Windows guesses (`kDefaultScalePercent`). At 200% Windows draws UI at 2×, macOS
displays it at 2×, and a Windows control ends up the same physical size as a
native macOS one — 1800×1169 logical points on the host mapping onto 1800×1169
Mac points, exactly 1:1.

Windows independently reports 200% as the *recommended* scale for a 3600×2338
display, which is a useful sanity check. It had auto-assigned 250%.

### Resolution is fixed for a session

The encode canvas is agreed once, in `media open` (`width` and `height`), and the
encoder's output size is set when the encoder opens. Changing the display mode
mid-session would mean a new encoder and a new parameter set on the Mac, and a
mode change also fires `WM_DISPLAYCHANGE`, reflowing every application on that
display. A retarget changes what is captured and never the canvas; a client that
wants another size opens a new session (`media/session.cpp`).

So the Mac sizes the display first, with `canvas`, and then the canvas is fixed
and windows are resized *within* it. Two consequences worth remembering: several
windows share one canvas, so it must cover the bounding box of all of them; and
the host encodes the whole display however little of it is in use, so an
oversized canvas is a real bandwidth cost rather than free headroom. Above 4096
pixels on either axis the H.264 encoders open and then never produce a frame, so
both ends hold the canvas to that.

## Gotchas

Each of these cost real time; they are recorded so they do not have to again.

- **Display configuration is session-bound.** A script or program run over SSH or
  as a service lands in session 0, where `EnumDisplayDevices` reports a phantom
  `WinDisc` 1024×768 desktop and attaching a display silently does nothing. Use an
  interactive scheduled task (`/it`) if you must drive it remotely.
- **HDR turns the content into a black rectangle.** Out of the box the driver
  advertises HDR, Windows composes the display in ST.2084 / Rec.2020, and the Mac
  does no PQ tone mapping. White stays white and black stays black, because both
  are endpoints of either curve, and every mid-tone between them is crushed to
  near-black: the window's chrome draws correctly around a black rectangle. It is
  worst in terminals and browsers, and a pure black-on-white application looks
  perfect throughout, which makes it easy to misread as a capture bug. Two
  switches matter. `HDRPlus` and `SDR10bit` in `vdd_settings.xml` stop the driver
  *advertising* HDR; the per-display "Use HDR" toggle is the one that decides,
  because Windows remembers it and re-applies it, so clearing only the file
  leaves the display composing in PQ with a changed bit depth. SolStream turns
  off both.
- **Too many modes make a healthy device with no display.** The driver
  replicates every global `<g_refresh_rate>` across every resolution, so the mode
  count is resolutions × rates, and a long list overflows its target-mode buffer.
  It then logs "Input buffer is too small for target modes" and reports success.
  Each resolution SolStream adds therefore carries one refresh rate of its own.
- **A refused device restart looks like a wait for modes that never come.** No
  administrator rights, or `pnputil` answering 3010 because the device wants a
  reboot, leaves the driver on its old mode list. The restart's result is checked,
  and the new modes take effect after restarting the PC.
- **`CDS_NORESET` is `0x10000000`, not `0x10000`.** The wrong value is not a
  recognised flag and fails with `DISP_CHANGE_BADFLAGS` (-4).
- **`DisplaySwitch.exe /extend` does not attach it.** Stage the mode with
  `ChangeDisplaySettingsEx(..., CDS_UPDATEREGISTRY | CDS_NORESET)` and then apply
  with a null-everything call (`AttachAt`).
- **PowerShell copies nested value-type fields.** `$x.header.type = 1` on a struct
  with a nested `DISPLAYCONFIG_DEVICE_INFO_HEADER` writes to a temporary that is
  discarded, so the call goes out with a zeroed header and fails with
  `ERROR_GEN_FAILURE` (31). The structs in the setup script are flat for this
  reason. The C++ keeps them flat as well, because the SDK headers it is
  cross-compiled against lack some of the requests, and a header whose `size` is
  wrong fails the same way.
- **Display names get renumbered by a device restart** (`\\.\DISPLAY5` became
  `\\.\DISPLAY6` here). The host never caches one: it looks the monitor up by name
  each time (`MonitorFromDeviceName`) and tells the Mac which display it captures
  (`displays[].captured`). A Mac that placed windows on a different display would
  not get an error. Frames would arrive, nothing would be dropped, and the picture
  would be of the wrong pixels.
- **Another product's virtual display is not ours.** A root-enumerated display is
  "a virtual display", and phone-as-monitor and remote-desktop products add theirs
  too. SolStream treats only the Virtual Display Driver, under any of the names it
  has shipped as, as its own: it patches, restarts and captures that one
  (`IsSolStreamDisplayDriver`) and falls back to the primary monitor rather than a
  display it did not size.
- **Nobody is looking at that display.** A Windows Firewall prompt once landed on
  it and sat unanswered for days, and its dimmer took every click meanwhile. The
  host carries windows that are not SolStream's off the capture display and onto
  the primary monitor (`RescueStrandedWindows`). It does not answer them.

## Reverting

Uninstalling SolStream takes back what SolStream's own install added and nothing
else: the device it created, the driver package it put in the driver store, and
the settings folder it made (or, in a folder that was already there, the
`vdd_settings.xml` it wrote and the backup of it). A driver you installed yourself
stays. To switch the display off without uninstalling, disable the device:

```powershell
Get-PnpDevice -Class Display | Where-Object FriendlyName -like '*Virtual Display Driver*' |
    Disable-PnpDevice -Confirm:$false
```

Detaching it in Settings > System > Display ("Disconnect") only lasts until
SolStream next starts, which attaches a running virtual display again. A disabled
one is left alone: SolStream captures the primary monitor, and the host window
says the display is off rather than installing another over it.

The copy of the driver's settings from before SolStream first changed them is
`vdd_settings.xml.solstream-backup`, beside the original. The setup script keeps
the same one. Copy it back over `vdd_settings.xml` and restart the device to put
the driver's own mode list back.
