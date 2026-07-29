# Proving the token stops crossing the wire

`fakehost.py` is a host that is not SolStream. It speaks the greeting and prints
exactly what the client says back, which is a better test than tcpdump because it
also exercises the case that matters most.

    python3 spike/auth-v2/fakehost.py with-challenge   # then start the client
    python3 spike/auth-v2/fakehost.py no-challenge

**with-challenge** — the client must send `proof` and `cnonce` and must not send
the token. The script recomputes the HMAC independently in Python, so a pass
means Swift's CryptoKit, Windows' BCrypt and Python's hashlib all agree.

**no-challenge** — the client must send NOTHING and hang up. An agent older than
auth v2 and an impersonator that simply omits the challenge are indistinguishable
on the wire, so the only safe response to both is refusal. A client that falls
back to sending the token here hands it to whichever of the two it was talking
to, permanently, for a secret that roots the media key schedule.

It caught a stale binary the first time it ran: the client sent the old
`{"cmd":"auth","token":...}` because `swift build` produces debug and the `.app`
being launched was an older release build. A test that has never failed has not
been shown to work — this one has.
