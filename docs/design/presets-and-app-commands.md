# Quality presets, a connection test, and commands around an app

Items 8 and 9 of the [feature survey](https://github.com/Bruno-Alumn/SolStream/pull/122).
Neither is built, because each has a question only the owner can answer.

## 8. Presets and a connection test

**What there is.** Settings already has presets for the picture. Video quality
is Automatic, Data saver, Balanced, High or Maximum, each a bitrate, and
Automatic picks by path (20 Mbps at home, 12 over Tailscale). Frame rate,
codec, sound quality and audio buffering are separate choices. The pill on a
stream shows frame rate, latency, bandwidth and dropped frames.

**What is missing** is a way to know which preset suits the network. There are
three ways to tell, from cheapest to most work:

1. **Watch the stream (Mac only).** The pill already counts dropped frames.
   When more than about 5% drop for ten seconds at a quality above Data saver,
   the pill says so and offers the next quality down, with one click. Nothing
   changes on its own. It measures what matters, the stream itself, but only
   once a stream is running.
2. **A round-trip test over the agent channel (Mac only).** Twenty `ping`s
   timed in the Connect window give round trip and jitter, but not loss or
   bandwidth, which TCP hides. It can tell home from internet; it can't tell
   good Wi-Fi from bad, which is the case that needs it.
3. **A real test on the media port (both ends).** The Mac sends a burst of
   padded datagrams at each preset's rate, the host echoes counts back, and
   the Mac reports loss and jitter at each rate, then picks the highest that
   held. This needs a new host command, gated like every new push or reply,
   and an echo on the media socket outside a session.

**Recommendation:** 1 now, and 3 only if 1 turns out not to be enough. 2 is
not worth its button.

**The decision:** may SolStream *offer* to lower quality mid-stream (1)? And
should it ever change it without asking, the way Automatic already picks by
path?

## 9. Commands before and after an app

Sunshine and Apollo run a command before an app opens and after it closes:
switch the power plan, end a launcher, mount a share.

**Where the list lives decides who can run what on the PC.**

- **On the PC, edited on the PC.** A file next to the host's settings,
  `%LOCALAPPDATA%\SolStream\app-commands.json`, keyed by the app's path, with a
  "Edit commands…" item in the tray menu that opens it. Only someone signed in
  to the PC can add a command; a Mac only ever triggers what is already there
  by opening the app. This is the same trust the PC already gives a paired
  Mac, which can open any app.
- **Edited from the Mac.** More convenient, but it means a paired Mac (or a
  stolen pairing token) can make the PC run any command line. Today a Mac can
  only open apps the Start Menu lists. This widens that to everything.

Either way, commands run as the signed-in user, never elevated, with a
timeout (30 s before, 10 s after), and their output goes to the host log.
"After" runs when the streamed window closes, or when the session ends with it
still open.

**Recommendation:** on the PC only.

**The decision:** whether the Mac may ever set them, and whether the feature is
wanted at all for an app streamer as opposed to a game streamer.
