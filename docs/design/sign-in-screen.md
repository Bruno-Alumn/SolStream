# Staying connected across Windows sign-out (design, not built)

The goal: signing out, or a reboot, doesn't strand the Mac. It can still
reach the PC, see the sign-in screen, and sign in.

## Why it doesn't today

The host runs as the signed-in user, started by a task at sign-in. That's
deliberate: capture, input and the clipboard all need the user's desktop,
and running as the user keeps it unprivileged. Sign out, and the host goes
with the session.

## What the remote-desktop tools do

Parsec, Sunshine and RustDesk all install a **Windows service** running as
SYSTEM. The service:

- starts at boot;
- watches session changes (`WTSRegisterSessionNotification`);
- starts the real capture process **as SYSTEM inside the console session**
  (`WTSGetActiveConsoleSessionId`, `DuplicateTokenEx`,
  `SetTokenInformation(TokenSessionId)`, `CreateProcessAsUser`) on whichever
  desktop is input: `Winlogon` at the sign-in screen, `Default` after it.

Only a SYSTEM process can capture and type on the sign-in screen, and on UAC
prompts. That would also fix the "can't click admin apps" limitation in the
README.

## The cost

- **Security.** The listening process would run as SYSTEM. A bug in the
  agent channel, today a user-level compromise, becomes full control of the
  PC. It needs a split: a SYSTEM broker that only captures and injects, and
  the user-level host doing everything else, with a small reviewed IPC
  between them.
- **Size.** A service, the broker, the IPC, desktop switching on every
  secure-desktop change, and setup and uninstall changes. Several weeks.
- **Trust.** A SYSTEM service is a bigger ask of a user installing an
  unsigned program; it pairs naturally with code signing.

## Recommendation

Do it with the broker split, after code signing. Meanwhile the connect window
now says when a PC is silent that it may be waiting at the sign-in screen (PR
#53), and Windows' own autologon is a stopgap for a dedicated machine.

## Decision needed

Whether SolStream should ever run anything as SYSTEM.
