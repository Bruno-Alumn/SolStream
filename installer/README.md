# Host installer

Not built yet. This file records what it has to do, so the next person does not
start from the assumptions the old script encoded.

`solstream.iss` used to live here and has been removed. It described the
abandoned fork architecture and could not compile: it packaged
`..\build\bin\release\Sunshine.exe`, which no target produces, plus
`..\sunshine\web\*` and `..\config\solstream.default.conf`, neither of which
exists. It also declared `PrivilegesRequired=lowest` while invoking `schtasks`
and `netsh`. It is in git history if any of it is wanted back.

## What one run has to accomplish

A non-technical user downloads one executable, runs it, and their PC serves the
macOS client. Everything below is verified behaviour, not a guess.

1. **Sunshine** — chain its *official installer* silently rather than
   repackaging. That keeps its LICENSE, NOTICE and web-UI notices travelling with
   it, and means we distribute an unmodified upstream binary. Verify
   `SunshineService` is actually running afterwards rather than trusting an exit
   code.
2. **The virtual display** — `pnputil /add-driver ... /install` stages the
   package, but does **not** create a device node for a root-enumerated device.
   Something has to create the node (`nefconw`, or a SetupAPI sequence we own).
   Then seed the mode ladder and attach it: see
   `windows/VirtualDisplay/setup-virtual-display.ps1`, which does all of this and
   has been run end to end on real hardware.
3. **The agent** — install as a **logon-triggered scheduled task**, not a
   service. A process in session 0 sees a phantom 1024x768 desktop and no windows
   at all, so a service cannot do the agent's job.
4. **Credentials** — generate a Sunshine web-UI password, set it with
   `sunshine.exe --creds`, then hand it to `SolStreamAgent.exe
   --set-sunshine-credentials` so pairing never needs a browser.
5. **Firewall** — per-port rules on the private profile. Sunshine's own rule
   allows *all* inbound TCP and UDP for `sunshine.exe`, which exposes its web UI
   as a side effect. Never open 47990.

## Constraints worth knowing before starting

- **Not MSI.** Deferred custom actions run as SYSTEM in session 0, where
  attaching a display silently does nothing. An Inno Setup elevated process stays
  in the user's interactive session. **Not MSIX** — it cannot install drivers.
- **The driver is user-mode.** `MttVDD.inf` declares `UmdfService` and
  `UmdfExtensions = IddCx0102`. It still needs admin to install, but it cannot
  bugcheck the machine.
- **Do not import the driver's signing certificate into TrustedPublisher** to
  suppress the consent dialog. Microsoft's own guidance is that this should never
  be done for a package distributed outside your organisation. Let the dialog
  appear.
- **Code signing is a cost, not a technique.** Unsigned, the user meets
  "Windows protected your PC" and an *Unknown publisher* prompt. Nothing in the
  engineering removes that.
- **Licensing needs a lawyer, not an engineer.** Sunshine is GPL-3.0. The repo
  also has no root LICENSE, so its own code is currently all-rights-reserved —
  that has to be decided before anything is distributed.
