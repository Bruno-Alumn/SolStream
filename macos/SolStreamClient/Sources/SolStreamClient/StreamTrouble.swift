import Foundation

/// What the stream windows say when the picture is in trouble, decided in one
/// place from the trouble and from what the agent channel is doing.
///
/// Three reporters speak to the same windows -- the frame watchdog, the media
/// session's own end, and the agent channel's state -- and each used to decide
/// alone. So a final "Lost the connection" was painted over by the watchdog's
/// "Reconnecting…" a moment later, and "Stream failed" with its Try Again was
/// shown while the channel was coming back by itself, where pressing it threw
/// away windows that `onReconnected` was about to restore.
extension AppDelegate {
    /// The agent channel, as far as the windows' message goes.
    enum ChannelOutlook: Equatable {
        /// A socket is up.
        case up
        /// Down, and coming back by itself: `onReconnected` will restart the
        /// stream when it does.
        case returning
        /// Down for good -- refused, or closed on purpose. Nothing will bring
        /// the picture back without the person.
        case gone
    }

    static func outlook(isConnected: Bool, willReconnect: Bool) -> ChannelOutlook {
        // `willReconnect` first: it goes false a moment before the socket is
        // released, and a channel being torn down for good is not "up".
        guard willReconnect else { return .gone }
        return isConnected ? .up : .returning
    }

    enum StreamTrouble: Equatable {
        /// No frames for this long; a keyframe has been asked for.
        case stalled(seconds: Int)
        /// Asked repeatedly, and nothing came.
        case lost
        /// The media session ended: the host went quiet, or the socket would
        /// not open.
        case failed(String)
        /// A restart did not get the host streaming again. The message is the
        /// host's, when it gave one.
        case restartFailed(String?)
    }

    enum StreamNotice: Equatable {
        /// Open the stream again, over the channel that is up.
        case restart
        /// A spinner: something is already on its way to put it right.
        case status(title: String, detail: String)
        /// An error, with Try Again.
        case error(title: String, detail: String)
        /// Leave the windows as they are: the channel has already said
        /// something final, and its reason is the one worth reading.
        case keep
    }

    /// - Parameter canRestart: whether another restart may be tried now -- the
    ///   recovery's attempts are not used up.
    /// - Parameter finalErrorShown: whether the channel's own final failure is
    ///   already on the windows.
    static func notice(for trouble: StreamTrouble, channel: ChannelOutlook, host: String,
                       canRestart: Bool, finalErrorShown: Bool) -> StreamNotice {
        let waiting = StreamNotice.status(title: "Reconnecting…",
                                          detail: "Waiting for \(host) to answer")
        switch channel {
        case .gone:
            if finalErrorShown { return .keep }
            return .error(title: "Lost the connection",
                          detail: "\(host) is no longer connected. Try Again to pick the app again.")
        case .returning:
            if case .stalled(let seconds) = trouble {
                return .status(title: "Reconnecting…",
                               detail: "No picture for \(seconds)s — asking \(host) for a new frame")
            }
            return waiting
        case .up:
            switch trouble {
            case .stalled(let seconds):
                return .status(title: "Reconnecting…",
                               detail: "No picture for \(seconds)s — asking \(host) for a new frame")
            case .lost:
                return .restart
            case .failed(let message):
                return canRestart ? .restart : .error(title: "Stream failed", detail: message)
            case .restartFailed(let message):
                return canRestart
                    ? .restart
                    : .error(title: "Lost the stream",
                             detail: message ?? "\(host) did not start streaming again.")
            }
        }
    }
}
