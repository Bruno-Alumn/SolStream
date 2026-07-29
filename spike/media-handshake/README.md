# Why this is a spike and not a test target

`main.swift` drives one media handshake against a live host. It builds and runs,
and it does not work — **not because of the product**.

A bare command-line binary is denied local-network access on macOS 14+ where the
signed `.app` bundle is granted it. The denial is silent: the connection reports
`connecting` and never advances, the host never sees a TCP connection, and there
is nothing in any log to say a permission was refused. Tailscale's 100.x
addresses count as local network for this purpose.

It also has a second lesson worth keeping. The first version blocked the main
thread on a semaphore while waiting for a state change that `AgentConnection`
delivers with `DispatchQueue.main.async` — so it was waiting on the queue it was
blocking. A run loop fixes that; AppKit hides it in the real client.

So the handshake is measured through the real app instead, with
`SOLSTREAM_MEDIA_TEST=1` set. That hook lives in `AgentConnection.swift` and goes
away once a media session is opened as a matter of course rather than on request.
