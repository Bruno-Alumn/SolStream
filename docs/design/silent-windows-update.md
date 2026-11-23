# Updating Windows without the permission prompt (design, not built)

## Where things stand

The Mac replaces its own bundle with one click and no password. On Windows,
since PR #196, the host downloads and verifies an update as soon as it finds
one, says so once in a notification, and a click goes straight to the
installer. What remains is Windows' permission prompt (UAC): SolStream is
installed in Program Files, which only an administrator can write, so every
update has to be elevated. On a standard account that prompt asks for an
administrator's password.

## Options

### A. A SYSTEM scheduled task that installs only signed SolStream releases

- **At install**, the elevated installer registers a task named
  "SolStream Update" that runs as SYSTEM, on demand only (no trigger). Its
  action is the installed `SolStream.exe --apply-signed-update`, from Program
  Files.
- **Any user may start the task.** Its security descriptor grants Read and
  Execute to Authenticated Users, so the unelevated host can run it with
  `ITaskService` and no prompt. The user can start it, not change it.
- **What the task does**, as SYSTEM:
  1. Asks GitHub itself for the latest release. It takes nothing from the
     user's side: no path, no hash, no version. Arguments a standard user
     could set would be a way to run their own code as SYSTEM.
  2. Downloads the installer and `SHA256SUMS` into a folder only SYSTEM can
     write (`%ProgramData%\SolStream\Update`, with its ACL set at creation).
  3. Checks the sums' signature with the key compiled in, then the
     installer's hash. Refuses anything not strictly newer than itself.
  4. Runs it with `--install --quiet`, keeping the settings the current
     install has (`InstalledOptions`).
- **Afterwards**, the installer stops the host and starts the new one in the
  user's session, as it does today. The notification's click then installs
  with no prompt at all.

**Gain:** the Mac's one click, and it works on a standard account with no
administrator's password.

**Cost:** SolStream gains a component that runs as SYSTEM. Its safety rests on
three things:
- the signing key, whose private half is in the release environment;
- the task taking no input;
- the Program Files and ProgramData ACLs.

If the signing key leaked, anyone able to publish a GitHub release on this
repository could run code as SYSTEM on every PC with SolStream installed.
Today the same leak needs the user to accept a prompt.

### B. Install per user, in `%LOCALAPPDATA%\Programs`

- No elevation for updates at all, as on the Mac.
- **What it costs:**
  - The firewall rules and the virtual display driver still need an
    administrator once, at first install.
  - Any program running as the user could replace SolStream's executable,
    the same exposure as the Mac's bundle in `/Applications` when it is
    writable.
  - A move from Program Files needs a migration step in the installer.

### C. Keep the prompt

Notify, pre-download and one click, as now. The prompt stays: one "Yes" on an
administrator account, a password on a standard one.

## The decision

Whether SolStream may run anything as SYSTEM. If yes, A; if updates matter
more than where SolStream lives, B; otherwise C, which is what is built.
The [sign-in screen note](sign-in-screen.md) waits on the same question, and
would share A's installer work.
