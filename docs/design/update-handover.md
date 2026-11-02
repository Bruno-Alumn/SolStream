# Handing a verified update to the elevated installer (design, not built)

## The gap

The updater checks the setup file's signed SHA-256 while holding the file
open, so nothing can open it for writing. Then it starts it elevated through
UAC.

Windows enforces file sharing against handles, not against mapped views. So
a program running as the same user can do this before the check:

1. Open the downloaded file, which sits in `%LOCALAPPDATA%\SolStream\Updates`
   when an earlier prompt was dismissed.
2. Map it writable.
3. Close its handle. The mapping stays, and no handle is left to block the hold.

After the check, while the UAC prompt is up, it writes through the mapping.
The elevated process then runs bytes nobody verified.

This needs malware already running as the user, which can do a lot anyway.
But it turns that into administrator rights on the next update the user
approves, and stopping exactly that is what the hold is for.

## Fix

Let something that is already trusted check the bytes, after elevation, on a
copy nobody else can write:

1. The unelevated updater downloads and checks as today. Then it starts the
   **installed** `SolStream.exe` elevated, not the download. That file lives
   in Program Files, which only administrators can write. The command is
   `--apply-update "<download>" <sha256> <version>`.
2. The elevated, installed copy:
   - copies the download into a fresh private folder under ProgramData, the
     same pattern as `PrivateDirectory` and `RelaunchFromTemp`;
   - hashes **the copy**;
   - checks the hash and version against the arguments;
   - runs the copy with `--install`.
3. The copy can't change after its hash is taken, because no other account
   can write to its folder. The download can, but it is no longer what runs.

The SHA-256 only needs to come from the signed `SHA256SUMS`. The elevated side
can also re-verify the signature itself, since it has the key compiled in.

## Costs

- A new command-line mode in the host. `--apply-update` refuses any path
  outside the user's Updates folder.
- One more process hop during an update.
- The first update after shipping this still goes the old way, because the
  copy doing the update is the old one.

## Live check before merging

Update on the PC from a build with this to one after it, both from the tray
prompt and from Settings. Then check the Updates folder and the private folder
are cleaned up.
