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

## The virtual display is not installed by setup

Nothing in the packaged build ships a display driver, and nothing downloads one.
`vdd.cpp` looks for root-enumerated (`ROOT\DISPLAY\...`) display devices and
reports whether one is present and started; the host window shows an advisory
with an "Install driver" button when there is none. That button runs `pnputil`
elevated on `driver\SolStreamDisplay.inf` beside the executable — a file
`package-windows.ps1` does not produce — so on a downloaded build it always takes
the other path, which tells the user that no driver is bundled and which indirect
display driver SolStream is tested against. `windows/VirtualDisplay/README.md`
names it and explains why a virtual display beats an HDMI dummy plug.

Once a driver exists, `display_setup.cpp` does the rest from inside the
application: seed the mode ladder, turn the driver's HDR off, cycle the device so
it re-reads its settings, attach it and set its scaling. That was a PowerShell
script (`windows/VirtualDisplay/setup-virtual-display.ps1`, still here and still
the reference for what the steps are) which the application never ran, so
pressing "Install driver" used to give you a driver and none of the setup.

One thing learned the hard way and worth keeping: `pnputil /add-driver ...
/install` stages a package but does not create a device node for a
root-enumerated device. Something has to create the node — `nefconw`, or a
SetupAPI sequence of our own — and nothing in SolStream does, which is part of
why a driver the user installs themselves is currently the path that works.

## Known gaps

- **Nothing is signed, and there is no CI.** `scripts/package-windows.ps1` builds
  and copies; it has no `signtool` step, and there is no workflow anywhere in the
  repository — the packaging scripts are run by hand. Unsigned, the user meets
  "Windows protected your PC" and an *Unknown publisher* prompt at the UAC
  dialog. Code signing is a cost rather than a technique: nothing in the
  engineering removes that prompt, only a certificate does. The macOS side of the
  fence is different — `scripts/package-macos.sh` signs and can notarise — so
  "SolStream is signed" is a statement that needs a platform attached to it.
- **No installer is tested automatically.** The clean-VM run is a manual
  procedure.

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
