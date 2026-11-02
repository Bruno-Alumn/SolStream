# Mouse acceleration in games

In gaming mode the Mac sends relative mouse motion, already shaped by macOS's
own acceleration. The host injects it with `SendInput` and `MOUSEEVENTF_MOVE`,
which Windows then scales again by the pointer speed slider and, when it is on,
"Enhance pointer precision". There is no `SendInput` flag that skips them.

Games that read raw input (`WM_INPUT`) see the deltas as sent and are fine.
Games and apps that read the cursor -- older titles, many menu-driven games,
RTS camera pans, Unity's legacy input -- get acceleration twice: a fast flick
turns much further than the same distance moved slowly, and a speed slider off
its middle notch scales everything.

## Options

1. **Leave Windows' settings alone** (today). Correct for raw-input games;
   cursor-reading games feel off. Log the PC's settings at session start so a
   complaint can be read from the log.
2. **Turn "Enhance pointer precision" off and the speed to the middle notch for
   the length of a gaming-mode session**, with `SPI_SETMOUSE` and
   `SPI_SETMOUSESPEED` (not persisted to the profile), and put them back when
   the session ends, the mode changes, or the host restarts after a crash (kept
   in the owed record, as windows are). Changes a setting the person chose,
   which they will notice if they use the PC's own mouse during the session.
3. **A Settings switch on the Mac**, "Let SolStream set the PC's mouse for
   games", off by default, doing option 2 when on.

## Decision needed

Which of these. Option 3 is the one that does not change anyone's PC without
asking.
