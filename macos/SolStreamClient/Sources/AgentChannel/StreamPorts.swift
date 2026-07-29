import Foundation

/// Where the host listens.
///
/// This used to be a table of GameStream offsets — https, http, web UI, video,
/// control, audio, rtsp — all derived from a Sunshine base port by adding a
/// fixed number, because those offsets belong to the protocol rather than to
/// any particular host. None of them exist any more. SolStream speaks to
/// SolStream, and there are three ports in the whole system.
public enum StreamPorts {
    /// The agent's control socket: newline-JSON, token-authenticated, sixteen
    /// commands. Everything starts here, including the media session's keys.
    public static let agent: UInt16 = 47630

    /// The media socket, SMT/1. The host names it in its answer to `media open`
    /// rather than this being assumed, so a host that has to move it can.
    public static let defaultMedia: UInt16 = 47631

    /// Where a Mac asks "is anybody there" and a host answers. Broadcast, so it
    /// reaches only a local network — which is the only place a user could
    /// plausibly not know the address of their own PC.
    public static let discovery: UInt16 = 47629
}
