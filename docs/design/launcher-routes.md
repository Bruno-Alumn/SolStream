# Launchers and the way to the PC

A Dock launcher, and the app reopened at launch, connect to the address they
were made with and nothing else. The connect window does more:

- it switches to the address the PC is found at on the network when the
  remembered one does not answer (`preferDiscoveredHost`);
- it tries the PC's other paired address -- its Tailscale one away from home --
  when the first is out of reach (`preferAnotherRoute`);
- it offers **Wake PC** when the PC is asleep and its hardware address is known.

A launcher made at home therefore says "No answer from 192.168.1.21" on the
road, though the PC is paired and reachable over Tailscale; and clicked while
the PC sleeps, it offers no way to wake it.

## Options

1. **Launchers go through the connect window's choice.** `open(link:)` asks the
   same probe-and-prefer logic for the link's PC before opening the picker, and
   the picker's failure offers Wake PC for that PC. Most consistent; the first
   click away from home takes a probe timeout longer.
2. **Launchers keep their address, and fail into the connect window** with that
   PC selected and the reason shown, where the existing fallbacks and Wake PC
   are. Simplest; one more click.
3. **A launcher remembers every route the PC has been reached by**, and tries
   them in order. Fastest when it works; needs a per-PC identity the host does
   not yet send (the token's host key fingerprint would do).

## Decision needed

Which of these. Option 2 is a small change and could ship first; option 1 is
what the connect window already promises; option 3 needs a protocol addition.
