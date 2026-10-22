# Host installer

There is no separate installer project, and this directory holds no code. The
application installs itself: `windows/SolStreamAgent/installer.cpp` is the whole
of it, and `scripts/package-windows.ps1` produces one file,
`dist\SolStreamSetup.exe`, which is the agent binary under a different name. Run
from anywhere other than `%ProgramFiles%\SolStream` it shows the setup screen;
what it copies into Program Files is itself, named `SolStream.exe`. That is the
only arrangement in which the installer and the program it installs cannot drift
apart, which is why there is nothing here to build.

This file used to describe an installer that had not been written, for an
architecture that has since been abandoned. Both the Inno Setup script
(`solstream.iss`, removed — it is in git history) and the plan that replaced it
were written when SolStream was a front end for Sunshine, and every step that
mentioned Sunshine, its service, its web-UI credentials or its GPL obligations
describes something that is no longer installed, run or shipped. SolStream
captures, encodes and sends the picture itself.

## What one run does

Verified behaviour, read off `installer.cpp`. The user downloads one executable
and runs it; the setup screen offers a desktop shortcut, a Start-menu shortcut
and starting at logon, all three on by default and all three reversible.

1. **Elevation** — setup re-launches itself with `runas` and waits. The UAC
   prompt is deliberately visible: it is the moment the user agrees to a program
   writing to Program Files, opening firewall ports and registering a logon task.
   The elevated half writes its outcome to a file in `%ProgramData%\SolStream`,
   because a second process has no other way to tell the setup window why it
   failed.
2. **The copy** — anything already running out of the install directory is
   stopped, then the executable — the file, not its directory — is copied to
   `%ProgramFiles%\SolStream\SolStream.exe`. This is the only step whose failure
   fails the install; everything after it can go wrong and still leave something
   a person can use.
3. **Firewall** — two `netsh advfirewall` rules, each naming both the program and
   its ports: TCP 47630 for the agent channel, and UDP 47631 and 47629 for the
   media transport and discovery, on the private and public profiles. Naming the
   program is what stops Windows raising its own allow prompt, which on this
   project once landed on a display with no monitor and blocked every click for
   days. Naming the ports as well is what stops the rule opening every port the
   executable might ever bind.
4. **Shortcuts and Add/Remove Programs** — written to the all-users folders,
   because the install itself is machine-wide.
5. **The agent** — registered as a **logon-triggered scheduled task** named
   "SolStream Host", from XML rather than from `schtasks`' own switches, and then
   started. Not a service: a process in session 0 sees a phantom 1024x768 desktop
   and no windows at all, so a service cannot do the agent's job.

A firewall rule `netsh` refused, or a logon task Windows would not register,
comes back as a warning on a successful install rather than as a failure — what
is left works, and telling somebody the install failed invites them to "fix" it
by installing again over the top. `%ProgramData%\SolStream\solstream-install.log`
is the file to ask for when an install goes wrong on a machine nobody was
watching.

## The virtual display, if you want one

SolStream streams a virtual display (`vdd.h` says why it still depends on one),
so setup offers to put one on a PC that has none: a ticked box, "Set up a
virtual display (recommended)", shown only when the Virtual Display Driver is
missing. With it ticked, the elevated half of setup does this before it copies
SolStream anywhere (`driver_install.cpp`):

1. **Download** one pinned release of the
   [Virtual Display Driver](https://github.com/VirtualDrivers/Virtual-Display-Driver)
   (MIT, signed by SignPath Foundation, user-mode): the 132 KB driver-only zip
   of `kDriverVersion`, over the updater's HTTPS path, GitHub hosts only. Its
   SHA-256 is compiled in, and anything else is thrown away unread.
2. **Unpack** it with System32's `tar` into a fresh folder in ProgramData that
   only SYSTEM and administrators can write to, so nothing can swap a file in
   between the check and the install.
3. **Install** it into the driver store with `SetupCopyOEMInf`. This is where
   Windows checks the signature and, the first time, asks the person whether
   to trust SignPath Foundation — the setup screen says that prompt is coming.
4. **Create the device.** `pnputil /add-driver /install` stages a package but
   never creates a device node for a root-enumerated device, which is why a
   driver installed that way did nothing. SolStream does what devcon's
   `install` does: a `Root\MttVDD` device node, registered, then
   `UpdateDriverForPlugAndPlayDevices` to bind the driver.
5. **Set it up** with `display_setup.cpp`: seed the mode ladder in
   `vdd_settings.xml` (the driver's VDDPATH, or `C:\VirtualDisplayDriver`),
   turn its HDR off, cycle it, attach it, scale it to 200%.

The driver goes in first because the host chooses what to capture as it
starts. A driver that cannot be installed is not a failed install: SolStream
streams the main display meanwhile, and setup's summary says why and what is
left to do. That is the host window's **Set up** button when the failure left
no device of the driver's; when it left one that didn't start, it is a restart
or Device Manager, since **Set up** is not offered for it. That button, and
the tray's "Set up virtual display…", run the same steps elevated
(`SolStream.exe --install-display-driver`), and the running host then switches
its capture to the new display without restarting. When Windows says the
install needs a restart, the device may not start before it, so that is not
called a failure: setup and the window say to restart the PC to finish, and the
host sets the display up when it starts after the restart. Until then the
device is not called switched off (Windows marks it as waiting for a restart):
setup, the window and the tray keep saying to restart, and offer no **Set up**.

Setup installs only on a PC with no device of the driver's at all. One that is
there but switched off or failing is somebody's own: setup says it is off and
where to turn it on, and installs nothing over it. What SolStream does install
it records under `HKLM\SOFTWARE\SolStream`, each piece only if this install made
it: the store package only if `SetupCopyOEMInf` (with `SP_COPY_NOOVERWRITE`)
actually added it, the device by its instance ID, and the settings folder if it
created one — or, in a folder that was already there, the `vdd_settings.xml` it
wrote and the backup of it SolStream made. That folder is created with a
protected access list (administrators and SYSTEM write, everyone else reads),
and nothing elevated writes or deletes through a junction or link there. A
failed or declined install takes those pieces back at once. Uninstalling
removes exactly the recorded pieces, without forcing: another device with the
same driver, or a package something else is using, stays. A device Windows
won't remove stays recorded, and its package and settings stay with it rather
than being deleted from under it. A settings record is kept until what it
names is gone, so a folder that still holds somebody else's files is left, and
still known to be SolStream's. A PC set up by an earlier build, which recorded
only the package, has its device found by the package it was installed from,
and only when exactly one device was.

ARM PCs aren't offered the tick box at all. The project's ARM64 build needs
test signing, which is not something to switch on for somebody, so setup and
the host window say where to get the driver instead. They say the same when
the download fails.

## After setup

Setup ends on a summary rather than a sentence: whether SolStream is running,
whether the virtual display is ready, whether this PC is on Tailscale (with a
**Get Tailscale** button when it is not), and the three steps on the Mac — get
the app, pick this PC, type the pairing token. The host window lists the
Tailscale address beside the local one when there is one.

## Known gaps

- **Nothing is signed with a certificate.** `scripts/package-windows.ps1` builds
  and copies with no `signtool` step; CI (`.github/workflows/ci.yml`) and the
  release workflow (`release.yml`) run it on GitHub's Windows runners. What makes
  a release trustworthy to the updater is the signed SHA256SUMS
  (docs/updates.md), which does nothing for SmartScreen. Unsigned, the user meets
  "Windows protected your PC" and an *Unknown publisher* prompt at the UAC
  dialog. Code signing is a cost rather than a technique: nothing in the
  engineering removes that prompt, only a certificate does. The macOS side of the
  fence is different — `scripts/package-macos.sh` signs and can notarise — so
  "SolStream is signed" is a statement that needs a platform attached to it.
- **No installer is tested automatically.** The clean-VM run is a manual
  procedure.
- **The driver is a pinned upstream asset.** Setup fetches one release asset of
  the Virtual Display Driver by URL and checks it against a hash compiled in. If
  the project removes or replaces that asset, every download fails with a
  pointer to installing the driver by hand. The fix is to pin a new release:
  download it, check its contents and signer, then update `kDriverVersion` in
  `driver_install.h` and `kPackageSha256` in `driver_install.cpp`. `kPackageUrl`
  is built from `kDriverVersion`; it needs changing only if the project renames
  the asset.

## Constraints worth knowing before changing any of this

- **Not MSI.** Deferred custom actions run as SYSTEM in session 0, where
  attaching a display silently does nothing. An elevated copy of
  `SolStreamSetup.exe` stays in the user's interactive session, which is the
  whole reason the install is an ordinary program and not a package format.
  **Not MSIX** — it cannot install drivers, which forecloses ever bundling one.
- **The driver is user-mode.** `MttVDD.inf` declares `UmdfService` and
  `UmdfExtensions = IddCx0102`. It still needs admin to install, but it cannot
  bugcheck the machine.
- **Do not import the driver's signing certificate into TrustedPublisher** to
  suppress the consent dialog. Microsoft's own guidance is that this should never
  be done for a package distributed outside your organisation. Let the dialog
  appear.
- **Licensing still needs deciding.** The GPL-3.0 obligation went with Sunshine,
  since nothing of it is distributed any more. The repository has no root
  LICENSE, so its own code is all-rights-reserved by default — that has to be
  settled before anything is handed to anybody.
