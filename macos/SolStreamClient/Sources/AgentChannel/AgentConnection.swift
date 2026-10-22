import Foundation
import CoreGraphics
import CryptoKit
import MediaSession
import Network
import Security
import SolStreamLogging

/// A remote display on the Windows host.
public struct RemoteDisplay: Sendable, Equatable {
    /// The `DXGI_OUTPUT_DESC.DeviceName` form, e.g. `\\.\DISPLAY1`. This is the
    /// exact string the `media open` command takes as its `display`.
    public let name: String
    /// The GDI adapter driving it, e.g. `NVIDIA GeForce RTX 4070 SUPER` or
    /// `Virtual Display Driver`.
    public let adapter: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let isPrimary: Bool
    /// Whether this is the display the host resolved as its capture display.
    ///
    /// Authoritative, and it has to be: the stream carries one display, the Mac
    /// crops a rectangle out of it, and placing windows anywhere else means
    /// every crop comes from the wrong pixels. That does not fail loudly — it
    /// arrives as a picture, with frames counted and nothing dropped.
    public let isCaptured: Bool

    /// A display with no physical panel behind it, produced by an indirect
    /// display driver. This is the one worth streaming: it can be sized to match
    /// the Mac exactly, and nothing the user has open on the real monitor can
    /// ever be dragged across the crop.
    public var isVirtual: Bool {
        let lowered = adapter.lowercased()
        return lowered.contains("virtual") || lowered.contains("idd")
    }
}

/// A top-level window on the Windows host.
public struct RemoteWindow: Sendable, Equatable, Identifiable {
    public let id: UInt64
    public let pid: Int
    public let title: String
    public let className: String
    /// The window's CLIENT AREA in virtual-desktop coordinates — the region
    /// that gets cropped out of the stream, excluding the frame.
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    /// Something opaque is drawn over this window on the host, so the crop
    /// would show that instead of the app.
    public let isOccluded: Bool
    public let occludedBy: String?
    /// Pixels of non-client caption above the client area.
    ///
    /// Zero means the application draws its own caption *inside* the client area
    /// — Explorer, Chrome and Discord all do — so the minimise/maximise/close
    /// buttons share a strip with tabs and the address bar and cannot be cropped
    /// away without taking those with them.
    public let captionInset: Int

    /// True when the window's title bar is drawn by Windows rather than by the
    /// application, so cropping the client area already excludes it.
    public var hidesCaptionWhenCropped: Bool { captionInset > 4 }

    /// The client area's size once the window is on the capture display.
    ///
    /// `width` and `height` are pixels at the scaling of whatever monitor the
    /// window is on NOW, and moving it onto the 200% capture display grows it by
    /// the ratio of the two. Opening the Mac window at the old size and then
    /// holding the host window to it clipped any fixed-size dialog — Character
    /// Map came out a third short on a 125% primary. A host that predates this
    /// reports nothing, and the current size is used as before.
    public var naturalWidth: Int = 0
    public var naturalHeight: Int = 0
    public var naturalSize: CGSize {
        naturalWidth > 0 && naturalHeight > 0
            ? CGSize(width: naturalWidth, height: naturalHeight)
            : CGSize(width: width, height: height)
    }

    public var frame: CGRect {
        CGRect(x: x, y: y, width: width, height: height)
    }
}

/// A launchable application on the host, from its Start Menu shortcut.
public struct RemoteApp: Sendable, Equatable, Identifiable, Hashable {
    public let name: String
    /// The `.lnk` path, passed straight back to the agent to launch.
    public let path: String

    public var id: String { path }
}

/// A tracked window's live state on the host.
public struct RemoteWindowStatus: Sendable, Equatable {
    public let isAlive: Bool
    public let isMinimized: Bool
    public let frame: CGRect
    public let captionInset: Int
    /// Something on the host is drawn over this window, so the crop is showing
    /// that instead of the application.
    public let isOccluded: Bool
    public let occludedBy: String?
}

/// Talks to the SolStream agent running on the Windows host.
///
/// Newline-delimited JSON over TCP. The agent greets with `hello` and
/// `displays` unprompted, then answers one reply per request in order.
///
/// The agent must be running in the host's *interactive* session — a process in
/// session 0 sees a phantom 1024x768 display and no windows at all.
public final class AgentConnection {
    public enum State: Equatable {
        case disconnected
        case connecting
        case connected(host: String)
        /// Reached, healthy, and waiting to be told who we are. `rejected` is
        /// true when a stored token was tried and turned down, which is worth
        /// saying differently from never having had one.
        case needsToken(host: String, rejected: Bool)
        case failed(String)
        /// Turned away for now, and trying again by itself: the host is still
        /// holding the connection this Mac lost. Not a failure -- the words
        /// say what is being waited for.
        case waiting(String)
    }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.solstream.agent")

    /// Guards the few things below that the rest of the app reads from wherever
    /// it happens to be standing — the display list, and
    /// the flag `isConnected` answers from. Everything else in this class
    /// belongs to `queue` and is only ever touched there.
    ///
    /// A lock rather than a `queue.sync`, because every writer is already
    /// standing on `queue` when it writes: a `sync` onto the queue you are
    /// running on deadlocks on the spot.
    private let stateLock = NSLock()

    private var storedConnection: NWConnection?
    /// The socket, which belongs to `queue` like everything around it.
    ///
    /// Computed only so that `connectionIsUp` cannot drift away from it. Five
    /// places assign to `connection` — `openConnection`, the failure branch of
    /// the state handler, `disconnect`, the receive completion and
    /// `dropConnection` — and a mirror that has to be updated by hand at each
    /// of them is a mirror that will eventually be wrong at one of them.
    private var connection: NWConnection? {
        get { storedConnection }
        set {
            storedConnection = newValue
            stateLock.lock()
            connectionIsUp = newValue != nil
            stateLock.unlock()
        }
    }
    /// Exactly `connection != nil`, kept as a Bool so that reading it from
    /// another thread does not mean touching the NWConnection reference itself.
    /// Guarded by `stateLock`.
    private var connectionIsUp = false
    private var buffer = Data()
    /// Replies arrive in request order, so a FIFO of continuations is enough —
    /// no request ids needed in the protocol.
    private var pending: [Pending] = []
    private var nextRequestID: UInt64 = 0

    private struct Pending {
        let id: UInt64
        let command: String
        /// Counted from when this request reaches the head of the queue: the
        /// host answers one at a time and in order, so a quick question behind
        /// a slow launch is not late until the launch is done.
        let timeout: TimeInterval
        let completion: (Result<[String: Any], Error>) -> Void
    }

    /// How long the host gets to answer, by command. A reply that never comes
    /// otherwise wedges everything queued behind it — with no request ids the
    /// FIFO cannot skip one — so running out drops the connection, which fails
    /// every waiter once and lets the reconnect start clean.
    private static func timeout(for request: [String: Any]) -> TimeInterval {
        switch request["cmd"] as? String {
        case "launch":
            let asked = (request["timeoutMs"] as? Int).map { Double($0) / 1000 } ?? 25
            return max(30, asked + 5)
        case "apps": return 30
        case "media" where request["op"] as? String == "open": return 15
        default: return 10
        }
    }

    /// The auth reply gets the same bound: everything sent meanwhile is held
    /// behind it.
    private static let authTimeout: TimeInterval = 10

    /// Set while the auth proof is on the wire and its reply has not come back.
    ///
    /// NOTHING ELSE MAY BE SENT IN THAT WINDOW. The host switches to reading
    /// sealed records the moment it has written the reply, and this side switches
    /// when it has read it — so a command sent in between goes out in the clear
    /// and lands in a host that has already switched. It reads the JSON as a
    /// sealed record, the tag fails, and it drops the connection, which is
    /// exactly what it should do about bytes it cannot authenticate.
    ///
    /// The heartbeat runs on a timer, and anyone already holding this
    /// connection can ask it something while the proof is on the wire, so
    /// those requests are held here and sent once the reply has landed.
    private var authInFlight = false
    private var heldWhileAuthenticating: [(request: [String: Any],
                                           completion: (Result<[String: Any], Error>) -> Void)] = []

    private var storedDisplays: [RemoteDisplay] = []

    /// The host's displays, as of the last list it sent.
    ///
    /// Guarded, and not merely against a stale read. This is written on `queue`
    /// and read from the main thread, and an Array of structs is a pointer to a
    /// heap buffer with a reference count on it — so a read that races the write
    /// is two threads moving the same count and one of them possibly reading a
    /// buffer the other has just released. That is a crash, not an out-of-date
    /// answer, and it happens no more often than the host changing its displays
    /// at the moment the picker draws.
    public var displays: [RemoteDisplay] {
        stateLock.lock()
        defer { stateLock.unlock() }
        return storedDisplays
    }

    private func setDisplays(_ value: [RemoteDisplay]) {
        stateLock.lock()
        storedDisplays = value
        stateLock.unlock()
    }

    /// Whether the display list the host volunteers is still to come.
    ///
    /// The agent sends exactly one unprompted `displays` per connection, as the
    /// last part of the greeting: straight after `hello` for a host that wants
    /// no token, straight after the auth reply for one that does. Every
    /// `displays` message after that one is the answer to a `displays` request,
    /// and this flag is what tells them apart — the two are byte-for-byte
    /// identical on the wire.
    private var greetingDisplaysPending = false

    public var onState: ((State) -> Void)?
    public var onDisplays: (([RemoteDisplay]) -> Void)?
    /// The Windows cursor changed shape. Pushed by the host, not polled.
    public var onCursorShape: ((String) -> Void)?
    /// The host's last cursor push, kept whether or not anyone is listening.
    /// The host says its state once after authentication -- while the picker
    /// holds the connection and nobody has set `onCursorShape` -- and after
    /// that only on change, so a window opened during a game that already hides
    /// its cursor would otherwise never hear "hidden". Main thread.
    public private(set) var lastCursorShape: String?
    /// The host declares on its pushes that it reports a hidden cursor at all,
    /// which a host built before that reporting never does.
    public private(set) var cursorReportsHidden = false
    /// A window this client was streaming has been closed on the host. Pushed
    /// the moment the host notices, so the Mac window goes with it rather than
    /// sitting there showing the last frame of an application that has quit.
    public var onWindowClosed: ((UInt64) -> Void)?
    /// Some window on the host has opened, closed or been renamed. Carries
    /// nothing: it is a nudge to re-read the list, not the list itself.
    public var onWindowsChanged: (() -> Void)?
    /// Something belonging to another application on the PC is sitting on top of
    /// the window with this id. An empty name means it has gone away again.
    public var onOccluded: ((UInt64, String) -> Void)?

    /// Shared secret for the agent, when it asks for one. Remembered per host so
    /// it is entered once rather than every session.
    private var token: String?
    /// The two nonces from the auth v2 handshake, kept because the media key
    /// schedule is derived from the same exchange that authenticated it -- there
    /// is no second handshake and no second secret.
    private var authChallenge: String?
    private var authClientNonce: Data?
    /// Whether the host offered to encrypt the channel, and the keys once it is.
    ///
    /// Negotiated rather than assumed. A mismatch here is not a degraded
    /// channel: it is a socket where each end reads the other's bytes as the
    /// wrong thing entirely, so both halves have to agree before either switches.
    private var hostOffersChannelCrypto = false
    private var channel: ChannelCrypto?
    /// Held between sending the proof and reading the reply that names the
    /// host's half. Dropped the moment the keys are derived.
    private var pendingEphemeral: P256.KeyAgreement.PrivateKey?
    private var pendingChallenge: String?
    private var pendingClientNonce: String?

    public static func storedToken(for host: String) -> String? {
        TokenStore.token(for: host)
    }

    /// Whether a token is held for `host`, without reading it.
    public static func hasStoredToken(for host: String) -> Bool {
        TokenStore.hasToken(for: host)
    }

    public static func rememberToken(_ token: String, for host: String) {
        TokenStore.set(token, for: host)
    }

    /// Drop a token the host refused, so the next connection asks for a new one
    /// rather than silently retrying something already known to be wrong.
    public static func forgetToken(for host: String) {
        TokenStore.remove(for: host)
    }

    /// Answer a `needsToken` with what the user typed.
    ///
    /// The connection is still open at this point, so this authenticates in
    /// place: the agent sends the display list once it is satisfied, which is
    /// the same sequence a session with a stored token goes through.
    public func supplyToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        // On `queue`, because everything below it belongs to `queue`. This
        // writes `token`, `authInFlight`, `pendingEphemeral`, `pendingChallenge`
        // and `pendingClientNonce` and pushes the auth proof at `connection`,
        // and it is called from the token sheet on the main thread — so it ran
        // against the receive callback, which reads and writes every one of
        // them. What that can produce is a proof interleaved with a record
        // `send` was in the middle of writing, or `authInFlight` set after the
        // reply that clears it has already been handled, which leaves every
        // later request held for the life of the connection.
        queue.async { [weak self] in
            guard let self else { return }
            // A token that is not hexadecimal cannot be a SolStream token: the
            // host makes 16 random bytes and prints them as hex, and the proof
            // is an HMAC keyed with those bytes. `authenticate` returns false
            // for that exactly as it does for a greeting that carried no
            // challenge, and treating the two alike meant a mistyped or
            // half-pasted token was announced as host impersonation and then
            // cleared `wantsConnection`, so there was no way back short of
            // restarting the app. Ask again instead — the socket is untouched
            // and the challenge from the greeting is still good.
            guard Self.bytes(fromHex: trimmed) != nil else {
                Log.error("[agent] the token typed for \(self.host) is not hexadecimal; "
                          + "asking again rather than dropping the connection")
                self.report(.needsToken(host: self.host, rejected: true))
                return
            }
            self.token = trimmed
            // The other failure that is not the host's fault: the socket went
            // while the sheet was open. `authenticate` says false to that too,
            // and calling it impersonation would be just as wrong. Whatever
            // closed the socket has already reported itself; a reconnect, if one
            // is coming, meets the greeting with this token now to hand.
            guard self.connection != nil else {
                Log.error("[agent] the connection to \(self.host) closed before the "
                          + "token could be used")
                return
            }
            if !self.authenticate(with: trimmed) {
                Log.error("[agent] \(self.host) offered no auth challenge; refusing to send the token")
                self.report(.failed("\(self.host) is running an older version of SolStream, or "
                                    + "something is impersonating it. Update SolStream on that PC."))
                self.dropConnection(AgentError.unexpectedDowngrade, reconnect: false)
            }
        }
    }

    public init(host: String, port: UInt16 = StreamPorts.agent, token: String? = nil) {
        self.host = host
        self.port = port
        self.token = token ?? Self.storedToken(for: host)
        self.clientID = Self.clientIDDefaultsOverride.map { Self.clientID(in: $0) }
            ?? Self.installClientID
        self.busyTiming = Self.busyTimingOverride ?? .standard
    }

    // MARK: - Coming back to a host that is still holding the last connection

    /// This copy of SolStream's name for itself, sent with every auth proof.
    ///
    /// The host serves one Mac at a time and learns that one has gone only
    /// when its socket says so. A Mac whose network changes under it -- Wi-Fi
    /// to Ethernet, a new address after waking, a Wi-Fi drop long enough for a
    /// request to time out -- leaves a socket behind that no FIN ever closes,
    /// and reconnects into a host that is still counting it. Knowing which Mac
    /// holds the session is what lets a host hand it back to that Mac and to
    /// no other. Random, so it says nothing about this Mac; kept per install
    /// rather than per launch, so a relaunched app can take back a session the
    /// last one left there. A host that predates it ignores the field.
    private let clientID: String

    static let clientIDKey = "SolStream.agentClientID"

    /// Made once per process, from what `clientID(in:)` keeps.
    static let installClientID = clientID(in: .standard)

    /// For tests, so a connection they make keeps its id in defaults of their
    /// own rather than writing one into the standard defaults. Read when the
    /// connection is made.
    static var clientIDDefaultsOverride: UserDefaults?

    /// The id kept in `defaults`, made and kept there the first time.
    static func clientID(in defaults: UserDefaults) -> String {
        if let stored = defaults.string(forKey: clientIDKey), isClientID(stored) {
            return stored
        }
        var bytes = Data(count: 16)
        let generated = bytes.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 16, $0.baseAddress!)
        }
        let fresh = generated == errSecSuccess
            ? hex(bytes)
            : UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
        defaults.set(fresh, forKey: clientIDKey)
        return fresh
    }

    /// 32 lowercase hex digits, the only shape the host accepts as an id.
    static func isClientID(_ text: String) -> Bool {
        text.utf8.count == 32 && text.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }

    /// Who the host says holds its one session, when it turns this Mac away.
    enum BusyHolder: Equatable {
        /// A host that cannot say: it predates the question, or the request
        /// that would have asked it proved nothing.
        case unknown
        /// This Mac's own last connection, which the host is letting go of.
        case thisMac
        /// Somebody else. Final: waiting will not change it.
        case anotherMac

        init(field: Any?) {
            switch field as? String {
            case "self": self = .thisMac
            case "other": self = .anotherMac
            default: self = .unknown
            }
        }
    }

    enum BusyAction: Equatable {
        case retry(after: TimeInterval)
        case giveUp
    }

    /// How long to go on knocking on a host that says it is busy.
    ///
    /// Past the host's own 30-second idle timeout, after which it lets go of a
    /// session that has gone silent whatever else it knows, with room for the
    /// reconnect that notices. A host still busy after this is busy with
    /// somebody else, or stuck, and the person is better told.
    static let busyPatience: TimeInterval = 45

    /// How long to go on knocking on a busy host, and how far apart.
    struct BusyTiming: Equatable {
        /// Since the session was lost, or since the first `busy` when there
        /// was none.
        var patience: TimeInterval
        /// The wait before knocking again the first time. Each wait after it
        /// is half as long again, up to `longestRetry`.
        var firstRetry: TimeInterval
        var longestRetry: TimeInterval

        /// The app's own.
        static let standard = BusyTiming(patience: AgentConnection.busyPatience,
                                         firstRetry: 2, longestRetry: 6)
    }

    /// For tests, so a connection they make can give up in seconds rather than
    /// in the app's 45. Read when the connection is made.
    static var busyTimingOverride: BusyTiming?

    /// What to do about a `busy`.
    ///
    /// Final for a Mac connecting afresh to a host that cannot say whose the
    /// session is -- coming back in two seconds finds the same Mac connected,
    /// and a loop against a busy host looks just like one against a broken
    /// one. But a Mac REconnecting is almost always being turned away by its
    /// own last connection, which the host has not yet noticed is dead, so it
    /// knocks again for `busyPatience` before saying anything final. A host
    /// that can say settles it either way.
    /// - Parameter reconnecting: whether this follows the loss of a session
    ///   this connection had, rather than a first connection.
    /// - Parameter waited: since that session was lost, or since the first
    ///   `busy` when there was none.
    /// - Parameter timing: the app's own, unless a test has a shorter one.
    static func busyAction(holder: BusyHolder, reconnecting: Bool, waited: TimeInterval,
                           retries: Int, timing: BusyTiming = .standard) -> BusyAction {
        switch holder {
        case .anotherMac:
            return .giveUp
        case .thisMac:
            break
        case .unknown:
            guard reconnecting else { return .giveUp }
        }
        guard waited < timing.patience else { return .giveUp }
        // Soon at first, because the host may let go at any moment; then every
        // few seconds, so the wait ends close to when the host frees the slot.
        return .retry(after: min(timing.firstRetry * pow(1.5, Double(max(retries, 0))),
                                 timing.longestRetry))
    }

    /// What is left on screen once a host has said for `busyPatience` that it
    /// is still holding this Mac's own session. Most likely another copy of
    /// SolStream on this Mac is using it, live.
    static func heldByThisMacMessage(host: String) -> String {
        "\(host) is still holding a connection from this Mac. Close any other SolStream "
            + "window on this Mac, or try again in a minute."
    }

    /// What a takeover proof is: an HMAC under the pairing token of
    ///
    ///     "SolStream agent takeover v1" || challenge || cnonce || client id
    ///
    /// A label of its own, so it can never stand in for an auth proof, and the
    /// id inside it, so it cannot be replayed under another id. Nil for a
    /// token or challenge that is not hex of the right length.
    static func takeoverProof(token: String, challenge: String, clientNonce: Data,
                              clientID: String) -> Data? {
        guard let tokenBytes = bytes(fromHex: token), !tokenBytes.isEmpty,
              let challengeBytes = bytes(fromHex: challenge), challengeBytes.count == 32,
              clientNonce.count == 32, isClientID(clientID) else { return nil }
        var message = Data("SolStream agent takeover v1".utf8)
        message += challengeBytes
        message += clientNonce
        message += Data(clientID.utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: message,
                                                    using: SymmetricKey(data: tokenBytes)))
    }

    /// The request that answers a host's offer of a takeover.
    static func takeoverRequest(token: String, challenge: String, clientNonce: Data,
                                clientID: String) -> [String: Any]? {
        guard let proof = takeoverProof(token: token, challenge: challenge,
                                        clientNonce: clientNonce, clientID: clientID) else {
            return nil
        }
        return ["cmd": "takeover", "client": clientID,
                "cnonce": hex(clientNonce), "proof": hex(proof)]
    }

    /// How long a takeover may take to be answered. The host waits up to eight
    /// seconds for the old session to let go before it says anything.
    private static let takeoverTimeout: TimeInterval = 12

    /// Whether the connection now open has completed its greeting.
    private var sessionUp = false
    /// When the last session this object held was lost without being asked
    /// to close. Nil while one is up, and before there has been one.
    private var sessionLostAt: Date?
    /// When the first `busy` of the present wait came, for a wait that has no
    /// lost session to count from.
    private var busySince: Date?
    private var busyRetries = 0
    /// `BusyTiming.standard`, or a test's shorter one.
    private let busyTiming: BusyTiming
    /// Whether this connection has been offered a takeover and has asked for
    /// one, and whether the answer is still to come. Everything sent meanwhile
    /// is held, as it is while the auth proof is out: the host reads exactly
    /// one line from a Mac it has offered a takeover to.
    private var takeoverAsked = false
    private var takeoverInFlight = false

    /// Note that the socket has gone, for `busyAction`'s sake.
    private func noteConnectionLost() {
        guard sessionUp else { return }
        sessionUp = false
        sessionLostAt = Date()
    }

    /// The host is serving somebody and has said so, before any greeting.
    private func handleBusy(_ message: [String: Any]) {
        let text = message["message"] as? String
            ?? "\(host) is already streaming to another Mac."
        // A host that can tell its sessions apart offers to hand back one this
        // Mac left there. A host that predates the offer never makes it.
        if !takeoverAsked, (message["takeover"] as? NSNumber)?.intValue == 1,
           let challenge = message["challenge"] as? String {
            takeoverAsked = true
            if askToTakeOver(challenge: challenge) { return }
        }
        takeoverInFlight = false

        let now = Date()
        if busySince == nil { busySince = now }
        let waited = now.timeIntervalSince(sessionLostAt ?? busySince ?? now)
        let holder = BusyHolder(field: message["holder"])
        switch Self.busyAction(holder: holder, reconnecting: sessionLostAt != nil,
                               waited: waited, retries: busyRetries, timing: busyTiming) {
        case .retry(let delay):
            busyRetries += 1
            Log.info("[agent] \(host) is still holding a session (\(holder)); "
                     + "trying again in \(String(format: "%.1f", delay))s")
            report(.waiting("Waiting for \(host) to let go of the last connection…"))
            dropConnection(AgentError.hostBusy, after: delay)
        case .giveUp:
            // The host's words for its own session are about a wait in
            // progress -- "still letting go" -- and nothing will try again
            // after this, so they are not the ones to leave on screen.
            let shown = holder == .thisMac ? Self.heldByThisMacMessage(host: host) : text
            Log.error("[agent] \(text)")
            // Before the report, so whoever hears it already finds
            // `willReconnect` false.
            wantsConnection = false
            report(.failed(shown))
            dropConnection(AgentError.hostBusy, reconnect: false)
        }
    }

    /// Answer a host's offer of a takeover, if this Mac can.
    /// - Returns: whether the request went out. False leaves the `busy` to be
    ///   handled as the refusal it otherwise is.
    private func askToTakeOver(challenge: String) -> Bool {
        // Only with nothing already on the wire. The host reads one line here,
        // and a request that went out before the `busy` arrived would be read
        // in its place and never answered -- and its reply slot then filled by
        // the answer to whatever was asked next.
        guard let connection, pending.isEmpty, !authInFlight,
              let token, !token.isEmpty else { return false }
        var clientNonce = Data(count: 32)
        let generated = clientNonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard generated == errSecSuccess,
              let request = Self.takeoverRequest(token: token, challenge: challenge,
                                                 clientNonce: clientNonce, clientID: clientID),
              var line = try? JSONSerialization.data(withJSONObject: request) else {
            return false
        }
        line.append(0x0A)
        Log.info("[agent] \(host) is holding a session; asking for it in case it is this Mac's")
        takeoverInFlight = true
        connection.send(content: line, completion: .contentProcessed { error in
            if let error { Log.error("[agent] could not send the takeover request: \(error)") }
        })
        queue.asyncAfter(deadline: .now() + Self.takeoverTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.takeoverInFlight else { return }
            Log.error("[agent] \(self.host) did not answer the takeover; dropping the connection")
            self.dropConnection(AgentError.timedOut)
        }
        return true
    }

    deinit {
        connection?.cancel()
    }

    /// Set between `connect()` and `disconnect()`, and cleared when the host
    /// refuses us for good.
    ///
    /// The difference between a socket that closed and a socket we closed. Only
    /// the first is worth reconnecting. Mirrored under `stateLock` for
    /// `willReconnect`.
    private var wantsConnection = false {
        didSet {
            stateLock.lock()
            wantsConnectionMirror = wantsConnection
            stateLock.unlock()
        }
    }
    private var wantsConnectionMirror = false

    /// Whether this connection is up or will come back by itself. False once
    /// it has been disconnected, or the host has refused it in a way a retry
    /// cannot fix (busy with another Mac, impersonation, downgrade) — a caller
    /// waiting for it should then say so rather than wait.
    public var willReconnect: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return wantsConnectionMirror
    }
    private var heartbeat: DispatchSourceTimer?
    private var reconnectAttempt = 0
    private var reconnectPending = false

    /// The agent drops a client that has said nothing for 30 seconds — a peer
    /// that vanishes without a FIN otherwise blocks its single-client accept
    /// loop forever. Ten seconds is comfortably inside that with room for a lost
    /// packet or two.
    private static let heartbeatInterval: TimeInterval = 10

    /// Re-established after an unexpected close. Everything the host was told
    /// about a window — where to put it, that it must stay on top, that it may
    /// not be resized — lives in the agent's memory and is undone when the
    /// socket drops, so somebody has to say it all again.
    public var onReconnected: (() -> Void)?

    /// Set when a reconnected socket becomes ready, cleared when the handshake
    /// that follows has finished and `onReconnected` has been called.
    private var reconnectedNeedsAnnouncing = false

    /// Say the connection is carrying commands again, once.
    ///
    /// Called when the greeting's `displays` arrives, which the host sends only
    /// once it is satisfied — not at `.ready`, where nothing has been proved
    /// yet and every command `onReconnected` sends would come back
    /// "unauthenticated". By then `displays` is current too, which is what the
    /// stream's recovery compares its capture display against.
    private func announceReconnection() {
        guard reconnectedNeedsAnnouncing else { return }
        reconnectedNeedsAnnouncing = false
        DispatchQueue.main.async { [weak self] in self?.onReconnected?() }
    }

    public func connect() {
        // On `queue`, like `disconnect()` and `supplyToken()`, because
        // everything `openConnection` touches belongs to `queue`: `connection`,
        // `buffer`, `channel`, `authInFlight`, `heldWhileAuthenticating` and
        // the rest of the handshake state are all read and written by the
        // receive callback. This is called from the picker and from the stream
        // windows on the main thread, and a reconnect that is already in flight
        // runs the receive callback at the same moment — so the check for an
        // existing connection, the clearing of the buffer and the assignment of
        // the new socket all ran against it.
        queue.async { [weak self] in
            guard let self else { return }
            // Asked for, so not a reconnect: a `busy` from here is counted
            // afresh rather than against a session lost some time ago.
            self.sessionLostAt = nil
            self.busySince = nil
            self.busyRetries = 0
            self.openConnection()
        }
    }

    private func openConnection() {
        guard connection == nil else { return }
        wantsConnection = true
        report(.connecting)

        // THE CHANNEL BELONGS TO ONE CONNECTION AND MUST NOT OUTLIVE IT. Its
        // keys come from a challenge and two ephemeral points that only that
        // socket ever saw, so carrying one into the next connection means
        // meeting a fresh cleartext `hello` with a key nobody used to write it.
        //
        // Clearing it in the `hello` handler — where this used to live — cannot
        // work, because `drainLines` consults `channel` BEFORE it parses
        // anything: a stale channel intercepts the very line whose handler would
        // have cleared it, the record fails its tag, the connection drops, and
        // every reconnect for the rest of the process's life fails the same way
        // three milliseconds in. That is what turned one lost session into an
        // app that could never reach the host again without being restarted.
        channel = nil
        pendingEphemeral = nil
        buffer.removeAll()
        authInFlight = false
        heldWhileAuthenticating.removeAll()
        // A fresh socket gets a fresh greeting, and the greeting's display list
        // with it.
        greetingDisplaysPending = true
        reconnectedNeedsAnnouncing = false
        sessionUp = false
        takeoverAsked = false
        takeoverInFlight = false

        guard let port = NWEndpoint.Port(rawValue: port) else {
            report(.failed("bad port"))
            return
        }
        let endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(host), port: port)
        // A host that is not answering should say so in seconds, not in a
        // minute. The default TCP connect timeout is around 60s, and measured
        // against a name that resolved to an address nothing was listening on,
        // the picker sat on "asking the host what it can run…" for 61 seconds
        // before anything was reported. Ten is long enough for a slow network
        // and short enough to be a wait rather than a hang — and the reconnect
        // backoff then does the waiting instead, where it belongs.
        let options = NWProtocolTCP.Options()
        options.connectionTimeout = 10
        let parameters = NWParameters(tls: nil, tcp: options)
        let connection = NWConnection(to: endpoint, using: parameters)
        self.connection = connection

        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                Log.info("[agent] connected to \(self.host):\(self.port)")
                let reconnected = self.reconnectAttempt > 0
                self.reconnectAttempt = 0
                self.receive()
                self.startHeartbeat()
                if reconnected {
                    // Noted, not announced: TCP being up is not the same as the
                    // connection being able to carry a command. See
                    // `announceReconnection`, which is called once the greeting
                    // is complete.
                    self.reconnectedNeedsAnnouncing = true
                }
            case .failed(let error):
                Log.error("[agent] connection failed: \(error)")
                self.report(.failed(error.localizedDescription))
                self.failPending(error)
                self.noteConnectionLost()
                // Nil it, or `connect()` early-returns on a dead NWConnection
                // for the rest of this object's life and no reconnect — manual
                // or automatic — can ever succeed.
                self.connection?.cancel()
                self.connection = nil
                self.stopHeartbeat()
                self.scheduleReconnect()
            case .waiting(let error):
                // NWConnection does NOT fail on an unreachable or filtered port —
                // it sits in .waiting and retries forever. Left unhandled that is
                // a spinner with no error and no end, which is exactly what a
                // loopback-bound agent looked like from another machine.
                // The log keeps the whole story: which port, and the fact that
                // an agent bound to one address answers on that address only.
                Log.error("[agent] cannot reach \(self.host):\(self.port): \(error). "
                          + "If SolStream is running there, it may be bound to one "
                          + "address only, or a firewall may be blocking the port.")
                self.report(.failed(Self.explain(error, host: self.host, port: self.port)))
                self.failPending(error)
                // While reconnecting, .waiting is a dead end: it retries only on
                // a network path change, so a PC that refused the connection
                // because it was mid-reboot would never be tried again once it
                // came back. Treat it as the failure it is and back off.
                if self.reconnectAttempt > 0 {
                    self.connection?.cancel()
                    self.connection = nil
                    self.stopHeartbeat()
                    self.scheduleReconnect()
                }
            case .cancelled:
                self.report(.disconnected)
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    /// Say something often enough that the host never thinks we have gone away.
    ///
    /// Without this the agent closes the socket after 30 seconds of silence, and
    /// silence is the normal state of a client sitting in the picker — nothing
    /// is being polled while no window is open. The next thing the user does
    /// then goes out over a dead socket: the window is never placed on its tile,
    /// never pinned, never locked, and when they close the application on the
    /// host there is no channel left for the host to say so on. All of it fails
    /// without a single error, because a request that cannot be sent looks
    /// exactly like one whose answer has not arrived yet.
    private func startHeartbeat() {
        heartbeat?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.heartbeatInterval,
                       repeating: Self.heartbeatInterval, leeway: .seconds(1))
        timer.setEventHandler { [weak self] in
            guard let self, self.connection != nil else { return }
            self.send(["cmd": "ping"]) { _ in }
        }
        heartbeat = timer
        timer.resume()
    }

    private func stopHeartbeat() {
        heartbeat?.cancel()
        heartbeat = nil
    }

    /// Come back after a socket we did not close.
    ///
    /// Backed off, because the usual causes — the host asleep, the agent
    /// restarting, the network gone — are not fixed by asking faster. Capped so
    /// a machine that comes back after an hour is still picked up.
    /// - Parameter fixedDelay: when to try, in place of the backoff -- for a
    ///   host that is known to be about to let go, where doubling the wait
    ///   only delays the moment it has.
    private func scheduleReconnect(after fixedDelay: TimeInterval? = nil) {
        // Two paths report the same death — the receive completion and the
        // connection's own state handler — and both call this. Without the
        // guard a single drop counts as two attempts, so the backoff doubles
        // for a failure that happened once.
        guard wantsConnection, connection == nil, !reconnectPending else { return }
        reconnectPending = true
        reconnectAttempt += 1
        let delay = fixedDelay ?? min(pow(2.0, Double(min(reconnectAttempt, 5))), 30.0)
        Log.info("[agent] reconnecting to \(host) in \(Int(delay))s (attempt \(reconnectAttempt))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectPending = false
            guard self.wantsConnection, self.connection == nil else { return }
            // Straight to the body: this is already on `queue`, and going
            // through `connect()` would only queue another hop behind it.
            self.openConnection()
        }
    }

    /// Turn a network error into something a person can act on.
    /// Short enough to read where it is shown, and about something the person
    /// reading it can do.
    ///
    /// The previous wording told them to restart the agent with
    /// "--bind <this PC's address>", which is advice for whoever is developing
    /// this and nobody else — an installed SolStream is started by a logon task
    /// and never sees a command line. It was also long enough that the picker's
    /// footer cut it off mid-sentence, so the one clause that mattered was the
    /// one that did not fit.
    ///
    /// The detail still goes to the log, where somebody diagnosing it will look.
    private static func explain(_ error: NWError, host: String, port: UInt16) -> String {
        switch error {
        case .posix(.ECONNREFUSED):
            return "\(host) is there, but SolStream is not running on it."
        case .posix(.ETIMEDOUT), .posix(.EHOSTUNREACH), .posix(.ENETUNREACH):
            return "No answer from \(host). Check SolStream is running on that PC."
        default:
            return "Can't reach \(host): \(error.localizedDescription)"
        }
    }

    /// Whether a socket is up and this connection can carry a request now.
    ///
    /// Not "wants to be connected": `wantsConnection` stays true through the
    /// whole reconnect backoff, and a caller that asks a question during it gets
    /// an immediate failure rather than an answer.
    ///
    /// This reads the Bool the `connection` setter maintains rather than the
    /// NWConnection reference. It used to read the reference, from the main
    /// thread, while `queue` was free to be replacing it — and a reference is
    /// not loaded and stored atomically, so what that risks is retaining a
    /// pointer mid-assignment rather than getting a slightly stale answer.
    public var isConnected: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return connectionIsUp
    }

    /// Drop every push callback, without touching the socket.
    ///
    /// Handing a live connection from the stream to the picker means handing
    /// over the callbacks with it, and those close over the windows that have
    /// just gone. Clearing them is the price of not reconnecting.
    public func resetCallbacks() {
        onState = nil
        onDisplays = nil
        onCursorShape = nil
        onWindowClosed = nil
        onReconnected = nil
        onWindowsChanged = nil
        onOccluded = nil
    }

    public func disconnect() {
        // Release the callbacks as well as the socket. They are stored here, so
        // a call site that captures this object strongly makes it retain itself
        // — and then the socket is never cancelled and whatever else the closure
        // captured is pinned too. Clearing them means one such mistake costs a
        // stale closure rather than a permanent leak.
        resetCallbacks()
        queue.async { [weak self] in
            guard let self else { return }
            // Before cancelling: `.cancelled` and the receive completion both
            // run through paths that would otherwise queue a reconnect to a host
            // the user has just left.
            self.wantsConnection = false
            self.stopHeartbeat()
            self.connection?.cancel()
            self.connection = nil
            self.failPending(AgentError.disconnected)
        }
        // Not in resetCallbacks: handing the connection to the picker keeps it,
        // and with it what the host last said about its cursor.
        lastCursorShape = nil
        cursorReportsHidden = false
    }

    // MARK: - Requests

    /// Ask for the host's current top-level windows.
    public func windows(completion: @escaping ([RemoteWindow]) -> Void) {
        send(["cmd": "windows"]) { result in
            guard case .success(let message) = result,
                  let raw = message["windows"] as? [[String: Any]] else {
                completion([])
                return
            }
            completion(raw.compactMap(Self.parseWindow))
        }
    }

    /// PROVE we hold the token. It is never sent.
    ///
    ///     proof = HMAC-SHA256(tokenBytes, "SolStream agent auth v2"
    ///                                      || challenge || cnonce)
    ///
    /// The old handshake wrote the token itself to a plaintext TCP socket, which
    /// made anything that could answer on 47630 first -- an ARP spoof, or simply
    /// winning the race on the next automatic reconnect -- a permanent
    /// disclosure oracle for a bearer secret. That matters more now than it did:
    /// the token is about to become the root of the media key schedule, so
    /// losing it costs every future session and not just this one.
    ///
    /// Sent without going through `send`, because the reply is pushed like
    /// `hello` rather than consuming a pending slot.
    private func authenticate(with token: String) -> Bool {
        guard let connection,
              let challenge = authChallenge,
              let tokenBytes = Self.bytes(fromHex: token),
              let challengeBytes = Self.bytes(fromHex: challenge),
              challengeBytes.count == 32 else { return false }

        var clientNonce = Data(count: 32)
        let generated = clientNonce.withUnsafeMutableBytes {
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }
        guard generated == errSecSuccess else { return false }

        var message = Data("SolStream agent auth v2".utf8)
        message += challengeBytes
        message += clientNonce
        let proof = HMAC<SHA256>.authenticationCode(for: message,
                                                    using: SymmetricKey(data: tokenBytes))

        // Kept: the same two nonces seed the media key schedule, so the handshake
        // that authenticates is also the one that agrees the keys.
        self.authClientNonce = clientNonce

        var request: [String: Any] = [
            "cmd": "auth",
            "proof": Self.hex(Data(proof)),
            "cnonce": Self.hex(clientNonce),
            // Which Mac this is, so the host can hand this session back to it
            // -- and to no other -- if it reconnects while the host is still
            // holding it. See `clientID`.
            "client": clientID,
        ]
        // The same message that proves the token also carries an ephemeral
        // public point, so the channel's keys cost no extra round trip. The
        // private half lives only until the reply names the host's point, and
        // that is the whole of what forward secrecy is.
        if hostOffersChannelCrypto {
            let ephemeral = P256.KeyAgreement.PrivateKey()
            request["channelCrypto"] = 2
            request["cpub"] = ephemeral.publicKey.x963Representation.smtHex
            pendingEphemeral = ephemeral
            pendingChallenge = challenge
            pendingClientNonce = Self.hex(clientNonce)
        }
        guard let line = try? JSONSerialization.data(withJSONObject: request) else {
            return false
        }
        var payload = line
        payload.append(0x0A)
        // Closed before the send, not after: the reply is what reopens it, and
        // a reply cannot arrive before this line has gone out.
        authInFlight = true
        connection.send(content: payload, completion: .contentProcessed { error in
            if let error { Log.error("[agent] could not send the auth proof: \(error)") }
        })
        queue.asyncAfter(deadline: .now() + Self.authTimeout) { [weak self, weak connection] in
            guard let self, let connection, self.connection === connection,
                  self.authInFlight else { return }
            Log.error("[agent] \(self.host) did not answer the auth proof; dropping the connection")
            self.dropConnection(AgentError.timedOut)
        }
        return true
    }

    /// Give the request at the head of the queue its time to be answered.
    private func armHeadTimeout() {
        guard let head = pending.first else { return }
        queue.asyncAfter(deadline: .now() + head.timeout) { [weak self] in
            guard let self, self.pending.first?.id == head.id else { return }
            Log.error("[agent] \(self.host) did not answer \(head.command) within "
                      + "\(Int(head.timeout))s; dropping the connection")
            self.dropConnection(AgentError.timedOut)
        }
    }

    /// Send everything that was held while the proof was in flight, now that the
    /// framing has settled — sealed if the channel came up, in the clear if it
    /// did not. Both ends agree on which by this point, which is the whole
    /// reason for waiting.
    private func releaseHeldRequests() {
        authInFlight = false
        let held = heldWhileAuthenticating
        heldWhileAuthenticating.removeAll()
        for item in held {
            send(item.request, completion: item.completion)
        }
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    static func bytes(fromHex hex: String) -> Data? {
        guard hex.count % 2 == 0 else { return nil }
        var out = Data(capacity: hex.count / 2)
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else { return nil }
            out.append(byte)
            index = next
        }
        return out
    }

    /// What the host should capture, and how.
    public struct MediaRequest: Sendable {
        /// `\\.\DISPLAYn`, as the `displays` command names it.
        public var display: String?
        public var fps: Int = 60
        public var bitrate: Int = 20_000_000
        public var audio: Bool = true
        /// The encode canvas this Mac wants, in host pixels.
        ///
        /// Left nil, the host encodes the source at whatever size it is, which
        /// is the only thing it could do before these existed. Set, it clamps
        /// them to what its encoder will take and encodes at that instead — so a
        /// window smaller than the display it sits on costs the bitrate of the
        /// window rather than of the whole desktop, and a 6K display does not
        /// arrive as pixels the Mac only ever throws away.
        public var width: Int?
        public var height: Int?
        /// How the sound should come, when `audio` asks for it. PCM is what
        /// every host sends unasked; anything else is a request a host that
        /// predates it ignores. See `AudioEncoding`.
        public var audioEncoding: AudioEncoding
        /// Whose sound: the whole PC's, which every host sends unasked, or
        /// the streamed apps' alone.
        public var audioSource: AudioSource

        public init(display: String? = nil,
                    fps: Int = 60, bitrate: Int = 20_000_000, audio: Bool = true,
                    width: Int? = nil, height: Int? = nil,
                    audioEncoding: AudioEncoding = .pcm, audioSource: AudioSource = .system) {
            self.display = display
            self.fps = fps
            self.bitrate = bitrate
            self.audio = audio
            self.width = width
            self.height = height
            self.audioEncoding = audioEncoding
            self.audioSource = audioSource
        }
    }

    /// The keys, the UDP port, and whether the host actually started sending.
    public struct MediaSession: Sendable {
        public let keys: MediaKeys
        public let port: UInt16
        public let streaming: Bool
        public let message: String?
        /// How the host said it will send its sound. PCM from a host that
        /// said nothing, because that is what one that predates the choice
        /// sends.
        public var audioCodec: AudioEncoding.Codec = .pcm
        /// Whose sound the host said it will send; the whole PC's from a host
        /// that said nothing.
        public var audioSource: AudioSource = .system
        /// The host takes keys by position, as scan codes. False for a host
        /// that said nothing, which takes them only by virtual key.
        public var takesScanCodes = false
    }

    /// The `media open` command's fields beyond the key material.
    ///
    /// Everything a host might not know is sent only when it means something,
    /// so a host that predates a field sees the same command it always saw:
    /// the canvas only when one is set, and the sound's encoding and source
    /// only when they are something other than the whole PC's PCM that every
    /// host sends unasked.
    static func mediaOpenFields(_ request: MediaRequest) -> [String: Any] {
        var fields: [String: Any] = ["fps": request.fps, "bitrate": request.bitrate,
                                     "audio": request.audio ? 1 : 0]
        if let display = request.display { fields["display"] = display }
        // Absent means "host decides", which is what every earlier build did by
        // having nothing to send.
        if let width = request.width { fields["width"] = width }
        if let height = request.height { fields["height"] = height }
        if request.audio, request.audioEncoding.codec != .pcm {
            fields["audioCodec"] = request.audioEncoding.codec.rawValue
            fields["audioBitrate"] = request.audioEncoding.bitrate
            fields["audioFrameMs"] = request.audioEncoding.frameMilliseconds
        }
        if request.audio, request.audioSource != .system {
            fields["audioSource"] = request.audioSource.rawValue
        }
        return fields
    }

    /// Whose sound a `media open` reply says it will be: the whole PC's, from a
    /// host that says nothing or names something this build does not know.
    static func audioSource(inReply reply: [String: Any]) -> AudioSource {
        (reply["audioSource"] as? String).flatMap(AudioSource.init(rawValue:)) ?? .system
    }

    /// What a `media open` reply says the sound will be. A host that predates
    /// the choice says nothing and sends PCM, and so does one that names a
    /// codec this build has never heard of -- it cannot be sending anything
    /// this build would play, so the packets' own format bytes decide.
    static func audioCodec(inReply reply: [String: Any]) -> AudioEncoding.Codec {
        (reply["audioCodec"] as? String).flatMap(AudioEncoding.Codec.init(rawValue:)) ?? .pcm
    }

    /// Whether a `media open` reply says the host takes keys by position. A
    /// host that predates scan codes says nothing, and is sent virtual keys.
    static func takesScanCodes(inReply reply: [String: Any]) -> Bool {
        (reply["scancodes"] as? Int ?? 0) >= 1
    }

    /// Stop the host's media session, leaving the agent channel up.
    public func closeMediaSession() {
        send(["cmd": "media", "op": "stop"]) { _ in }
    }

    /// Open a media session: ephemeral ECDH over the channel that already
    /// authenticated us.
    ///
    /// Returns nil if the host's `hostAuth` does not match what this Mac
    /// derived. That check is the whole point of doing it here: without it the
    /// first sign of a key mismatch is every packet failing its authentication
    /// tag, which is indistinguishable from a broken network.
    public func openMediaSession(_ request: MediaRequest = .init()) async -> MediaSession? {
        // Read on `queue`, where the token is written: this runs on the main
        // actor, and a token typed or cleared mid-read is a data race.
        guard let token = queue.sync(execute: { self.token }) else {
            Log.error("[media] no token, so no key material")
            return nil
        }
        let priv = P256.KeyAgreement.PrivateKey()
        let cpub = priv.publicKey.x963Representation
        var cnonce = Data(count: 32)
        guard cnonce.withUnsafeMutableBytes({
            SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!)
        }) == errSecSuccess else { return nil }

        var message: [String: Any] = ["cmd": "media", "op": "open", "ver": 1,
                                      "cpub": cpub.smtHex, "cnonce": cnonce.smtHex]
        message.merge(Self.mediaOpenFields(request)) { _, field in field }

        let reply: [String: Any]
        do {
            reply = try await withCheckedThrowingContinuation { continuation in
                send(message) { result in
                    continuation.resume(with: result)
                }
            }
        } catch {
            Log.error("[media] the host did not answer the open: \(error)")
            return nil
        }
        guard reply["ok"] as? Bool == true,
              let hpubHex = reply["hpub"] as? String,
              let hnonceHex = reply["hnonce"] as? String,
              let hcountText = reply["hcount"] as? String,
              let hauthHex = reply["hauth"] as? String,
              let hpub = Data(smtHex: hpubHex), hpub.count == 65,
              let hnonce = Data(smtHex: hnonceHex),
              let hcount = UInt64(hcountText) else {
            Log.error("[media] the host refused: \(reply["message"] as? String ?? "?")")
            return nil
        }

        guard let peer = try? P256.KeyAgreement.PublicKey(x963Representation: [UInt8](hpub)),
              let shared = try? priv.sharedSecretFromKeyAgreement(with: peer) else {
            Log.error("[media] the host's public key is not on the curve")
            return nil
        }
        let secret = shared.withUnsafeBytes { Data($0) }

        guard let keys = MediaKeySchedule.derive(clientPublic: cpub, hostPublic: hpub,
                                                 clientNonce: cnonce, hostNonce: hnonce,
                                                 hostCount: hcount, secret: secret,
                                                 token: token) else {
            Log.error("[media] key derivation failed")
            return nil
        }
        guard keys.hostAuth.smtHex == hauthHex else {
            // Both ends did the same arithmetic on different inputs, which for a
            // key schedule means somebody is not who this Mac thinks they are.
            Log.error("[media] the host derived DIFFERENT keys -- refusing the session")
            return nil
        }
        let streaming = reply["streaming"] as? Bool ?? false
        let message2 = reply["message"] as? String
        // `UInt16(...)` traps on anything that does not fit, and this number
        // comes off the wire: a host answering with 70000, or with -1, would
        // not produce a failed session, it would kill the client where it
        // stands. Only a host that has already authenticated can get this far,
        // so this is a buggy peer rather than an attacker — but a buggy peer
        // should not be able to take the app down either. Anything unusable
        // falls back to the port the host would have named anyway.
        let claimed = reply["hport"] as? Int ?? Int(StreamPorts.defaultMedia)
        let port = UInt16(exactly: claimed) ?? StreamPorts.defaultMedia
        if Int(port) != claimed {
            Log.error("[media] \(host) named \(claimed) as its media port, which is not a "
                      + "port number; trying \(port) instead")
        }
        let audioCodec = Self.audioCodec(inReply: reply)
        let audioSource = Self.audioSource(inReply: reply)
        Log.info("[media] session \(hcount) open, keys agree (sid \(keys.sessionTag)), "
                 + "host \(streaming ? "is streaming" : "is NOT streaming: \(message2 ?? "?")")")
        if request.audio, request.audioEncoding.codec != audioCodec {
            // Said here because nothing else would: the stream plays either
            // way, and only the bandwidth gives it away.
            Log.info("[media] asked for \(request.audioEncoding.summary) sound; the host "
                     + (reply["audioCodec"] == nil ? "predates the choice and sends PCM"
                                                   : "sends \(audioCodec.rawValue)"))
        }
        if request.audio, request.audioSource != audioSource {
            Log.info("[media] asked for the streamed apps' sound alone; the host sends "
                     + "the whole PC's" + (reply["audioSource"] == nil ? " (it predates the choice)" : ""))
        }
        return MediaSession(keys: keys, port: port, streaming: streaming, message: message2,
                            audioCodec: audioCodec, audioSource: audioSource,
                            takesScanCodes: Self.takesScanCodes(inReply: reply))
    }

    /// Ask for the host's displays.
    public func refreshDisplays(completion: (([RemoteDisplay]) -> Void)? = nil) {
        send(["cmd": "displays"]) { [weak self] result in
            guard case .success(let message) = result else {
                completion?([])
                return
            }
            let displays = Self.parseDisplays(message)
            self?.setDisplays(displays)
            completion?(displays)
        }
    }

    public struct RemoteClipboard: Sendable, Equatable {
        public let text: String
        public let sequence: Int
        public let isUnchanged: Bool
        public let wasTruncated: Bool
        /// The application that put it there marked it as not for clipboard
        /// tools, as password managers do, so the host did not send it. The
        /// text is empty, which is all a host from before this flag says.
        public let isPrivate: Bool
    }

    /// Read the host's clipboard, skipping the transfer if it has not changed.
    ///
    /// `since` is the sequence number from the previous read. Windows bumps it on
    /// every clipboard change, so passing it back turns the common case — polling
    /// and finding nothing new — into a few bytes rather than the whole contents.
    public func clipboard(since: Int?, completion: @escaping (RemoteClipboard?) -> Void) {
        var request: [String: Any] = ["cmd": "clipboard"]
        if let since { request["seq"] = since }
        send(request) { result in
            guard case .success(let message) = result,
                  message["ok"] as? Bool == true,
                  let sequence = message["seq"] as? Int else {
                completion(nil)
                return
            }
            completion(RemoteClipboard(text: message["text"] as? String ?? "",
                                       sequence: sequence,
                                       isUnchanged: message["unchanged"] as? Bool ?? false,
                                       wasTruncated: message["truncated"] as? Bool ?? false,
                                       isPrivate: message["private"] as? Bool ?? false))
        }
    }

    /// Largest clipboard text either side sends, measured in the Mac's line
    /// endings, and the largest line either end will read. Both mirror the
    /// constants in main.cpp and have to move with them — whichever side hits
    /// its line cap first drops the control channel, and the picture stays
    /// live while every window command quietly stops working.
    public static let maxClipboardBytes = 256 * 1024
    static let maxLineBytes = 4 * 1024 * 1024
    /// Largest text a set carries. The Mac cuts its copy to `maxClipboardBytes`
    /// while its lines end in LF, then gives every line Windows' CR, which can
    /// at most double it. No host cuts a set, and six times this still clears
    /// `maxLineBytes`.
    public static let maxClipboardSetBytes = 2 * maxClipboardBytes

    /// Trim to fit the host's clipboard budget, measured in UTF-8 bytes.
    ///
    /// Bytes rather than characters because that is what the agent counts, and
    /// the two differ by up to 4×: 100k of CJK text is well inside any character
    /// limit and three times over the byte one. Trimmed by `Character` so a
    /// grapheme cluster — or worse, a UTF-8 sequence — is never cut in half.
    public static func clipboardPayload(_ text: String, limit: Int = maxClipboardBytes)
        -> (text: String, truncated: Bool) {
        let utf8 = text.utf8
        guard utf8.count > limit else { return (text, false) }

        // Seek straight to the byte cap, then walk back to the nearest Character
        // boundary. Repeatedly dropping Characters and re-measuring would be
        // quadratic, and sizing the drop from the byte overshoot removes far too
        // much when the text is multi-byte — 2 MB of flag emoji is 1.75 MB over,
        // which is more Characters than the string has, so it would trim the
        // whole clipboard away.
        guard let capped = utf8.index(utf8.startIndex, offsetBy: limit,
                                      limitedBy: utf8.endIndex) else { return (text, false) }
        var boundary = capped
        while boundary > utf8.startIndex, String.Index(boundary, within: text) == nil {
            boundary = utf8.index(before: boundary)
        }
        guard let cut = String.Index(boundary, within: text) else { return ("", true) }
        return (String(text[text.startIndex..<cut]), true)
    }

    /// Trim a set to its budget. A `clipboardPayload` in Windows' line endings
    /// passes whole: measured against the Mac's budget instead, a copy that
    /// fit as LF lost its tail once every line had gained a CR.
    static func clipboardSetPayload(_ text: String) -> (text: String, truncated: Bool) {
        clipboardPayload(text, limit: maxClipboardSetBytes)
    }

    /// Put text on the host's clipboard, already in Windows' line endings: a
    /// `clipboardPayload` once every LF has gained its CR.
    public func setClipboard(_ text: String, completion: ((Int?) -> Void)? = nil) {
        let (text, truncated) = Self.clipboardSetPayload(text)
        if truncated {
            Log.info("[clipboard] trimmed to \(text.utf8.count) bytes for the host")
        }
        send(["cmd": "clipboard", "text": text]) { result in
            guard case .success(let message) = result,
                  message["ok"] as? Bool == true else {
                completion?(nil)
                return
            }
            completion?(message["seq"] as? Int)
        }
    }

    /// A window's or application's icon.
    ///
    /// Fetched one at a time and on demand, so a picker listing hundreds of
    /// applications does not extract hundreds of icons before it can draw. The
    /// host sends raw BGRA rather than PNG, so neither end needs an image codec.
    public func icon(windowID: UInt64? = nil, path: String? = nil,
                     completion: @escaping (CGImage?) -> Void) {
        var request: [String: Any] = ["cmd": "icon"]
        if let windowID { request["id"] = windowID }
        if let path { request["path"] = path }
        send(request) { result in
            guard case .success(let message) = result,
                  message["ok"] as? Bool == true,
                  let width = message["w"] as? Int, let height = message["h"] as? Int,
                  // Before the multiply below, not after it. `*` traps on
                  // overflow, and both of these come off the wire: a host
                  // answering with w = h = 2^32 does not produce a wrong icon,
                  // it kills the whole client on the spot. The agent extracts
                  // icons at 64 pixels square, so anything past a few hundred
                  // is not an icon whatever else it is.
                  width > 0, height > 0, width <= 1024, height <= 1024,
                  let base64 = message["bgra"] as? String,
                  let bytes = Data(base64Encoded: base64),
                  bytes.count == width * height * 4 else {
                completion(nil)
                return
            }
            completion(Self.image(fromBGRA: bytes, width: width, height: height))
        }
    }

    private static func image(fromBGRA bytes: Data, width: Int, height: Int) -> CGImage? {
        guard let provider = CGDataProvider(data: bytes as CFData) else { return nil }
        // Windows hands over straight (un-premultiplied) alpha in BGRA order, and
        // says so here rather than converting: Core Graphics will do the right
        // thing given an accurate description.
        return CGImage(width: width, height: height,
                       bitsPerComponent: 8, bitsPerPixel: 32,
                       bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue:
                           CGImageAlphaInfo.first.rawValue | CGBitmapInfo.byteOrder32Little.rawValue),
                       provider: provider, decode: nil,
                       shouldInterpolate: true, intent: .defaultIntent)
    }

    /// Applications the host can launch, from its Start Menu shortcuts.
    public func apps(completion: @escaping ([RemoteApp]) -> Void) {
        send(["cmd": "apps"]) { result in
            guard case .success(let message) = result,
                  let raw = message["apps"] as? [[String: Any]] else {
                completion([])
                return
            }
            completion(raw.compactMap { entry in
                guard let name = entry["name"] as? String,
                      let path = entry["path"] as? String else { return nil }
                return RemoteApp(name: name, path: path)
            })
        }
    }

    /// Start an application and wait for the window it opens.
    ///
    /// The agent blocks until a window appears, so this reply is slow by design
    /// — a cold application start can take many seconds, and the alternative is
    /// making the Mac guess which new window belongs to what it just launched.
    public func launch(path: String, timeout: TimeInterval = 25,
                       completion: @escaping (UInt64?) -> Void) {
        send(["cmd": "launch", "path": path,
              "timeoutMs": Int(timeout * 1000)]) { result in
            guard case .success(let message) = result,
                  message["alive"] as? Bool == true,
                  let id = (message["id"] as? NSNumber)?.uint64Value else {
                if case .success(let message) = result,
                   let error = message["message"] as? String {
                    Log.error("[agent] launch failed: \(error)")
                }
                completion(nil)
                return
            }
            completion(id)
        }
    }

    /// Ask the host to render at a given size.
    ///
    /// The Mac wants the capture display to match its own screen: a larger canvas
    /// spends bitrate on pixels it will never show, a smaller one gets upscaled.
    /// The host switches to the smallest mode that covers the request and reports
    /// what it actually achieved, which may differ — its mode list is fixed.
    public func setCanvas(display: String, width: Int, height: Int,
                          completion: @escaping (CGSize?) -> Void) {
        send(["cmd": "canvas", "display": display, "w": width, "h": height]) { result in
            guard case .success(let message) = result,
                  message["ok"] as? Bool == true,
                  let w = message["w"] as? Int, let h = message["h"] as? Int else {
                completion(nil)
                return
            }
            completion(CGSize(width: w, height: h))
        }
    }

    /// One window's live state. `isAlive` false means the user closed it.
    public func windowStatus(id: UInt64, completion: @escaping (RemoteWindowStatus?) -> Void) {
        send(["cmd": "window", "id": id]) { result in
            guard case .success(let message) = result,
                  let alive = message["alive"] as? Bool else {
                completion(nil)
                return
            }
            completion(RemoteWindowStatus(
                isAlive: alive,
                isMinimized: message["minimized"] as? Bool ?? false,
                frame: CGRect(x: message["x"] as? Int ?? 0, y: message["y"] as? Int ?? 0,
                              width: message["w"] as? Int ?? 0, height: message["h"] as? Int ?? 0),
                captionInset: message["captionInset"] as? Int ?? 0,
                isOccluded: message["occluded"] as? Bool ?? false,
                occludedBy: message["occludedBy"] as? String))
        }
    }

    /// Move and size a window so its client area lands exactly on `rect`, in
    /// the host's virtual-desktop coordinates. The reply carries the rectangle
    /// actually achieved, which may differ if the app enforces a minimum size.
    /// What a `place` achieved, and the smallest the host will let that window
    /// become. The minimum comes from the window itself rather than being
    /// guessed from the result.
    public struct Placement: Sendable, Equatable {
        public let frame: CGRect
        public let minimumSize: CGSize
        /// Zero on an axis the application does not limit.
        public var maximumSize: CGSize = .zero
        /// False for a window with no sizing border -- a dialog laid out once
        /// for one size. The host only moves those, and reports the size the
        /// application chose; this side has to hold its window at that size.
        public var isResizable = true
        /// Width of the host window's resize grab area, in host pixels.
        public let resizeBorder: CGFloat
        /// How far, in host pixels summed over both axes and both corners, the
        /// client area ended up from what was asked for — AFTER the host has
        /// corrected itself as far as it can.
        ///
        /// Zero is the ordinary answer. Anything above it is the application
        /// enforcing a size of its own, and that is worth telling apart from
        /// SolStream having computed the wrong target: the two used to be the same
        /// silent outcome, with this window resizing itself to match whatever came
        /// back either way.
        public let missed: Int
        /// Host pixels at the top of the client area holding a title bar the
        /// application draws there itself -- Chrome's tab strip, Discord's bar --
        /// with its own minimise, maximise and close. Zero when it draws none, or
        /// on a host too old to measure it.
        public var titleBarHeight: CGFloat = 0
        /// The program that owns the window, "Discord.exe", for choices kept per
        /// application. Empty on a host that predates it.
        public var program = ""
    }

    public func place(windowID: UInt64, at rect: CGRect,
                      completion: ((Placement?) -> Void)? = nil) {
        send([
            "cmd": "place",
            "id": windowID,
            "x": Int(rect.minX), "y": Int(rect.minY),
            "w": Int(rect.width), "h": Int(rect.height)
        ]) { result in
            guard case .success(let message) = result,
                  message["ok"] as? Bool == true,
                  let x = message["x"] as? Int, let y = message["y"] as? Int,
                  let w = message["w"] as? Int, let h = message["h"] as? Int else {
                completion?(nil)
                return
            }
            let minimum = CGSize(width: message["minW"] as? Int ?? 0,
                                 height: message["minH"] as? Int ?? 0)
            var placement = Placement(frame: CGRect(x: x, y: y, width: w, height: h),
                                      minimumSize: minimum,
                                      resizeBorder: CGFloat(message["border"] as? Int ?? 0),
                                      // Absent on a host that predates the field,
                                      // which reads as "landed exactly" — the same
                                      // thing every such host implicitly claimed.
                                      missed: message["missed"] as? Int ?? 0)
            // Both absent on an older host: no maximum, and resizable, which is
            // what this side assumed before the fields existed.
            placement.maximumSize = CGSize(width: message["maxW"] as? Int ?? 0,
                                           height: message["maxH"] as? Int ?? 0)
            placement.isResizable = message["resizable"] as? Bool ?? true
            placement.titleBarHeight = CGFloat(max(message["titleBar"] as? Int ?? 0, 0))
            placement.program = message["program"] as? String ?? ""
            completion?(placement)
        }
    }

    /// Pin a window above ordinary windows so nothing can cover its tile.
    ///
    /// The Mac crops a rectangle out of the captured display, so anything drawn
    /// over the tile is streamed as if it were part of the app. Safe for our own
    /// tiles because they never overlap each other.
    public func setTopmost(windowID: UInt64, _ on: Bool) {
        send(["cmd": "topmost", "id": windowID, "on": on ? 1 : 0]) { _ in }
    }

    /// Stop the window being resized on the host.
    ///
    /// The crop is a fixed rectangle on the shared canvas, so a window resized
    /// over the stream stops lining up with it — the user would drag an edge and
    /// see desktop appear where the application used to be. Size is driven from
    /// the macOS window instead, which is the one they are actually looking at.
    /// `place` keeps working: the Mac asking for a size is what the lock exists to
    /// protect, not what it blocks.
    public func setResizeLock(windowID: UInt64, _ on: Bool) {
        send(["cmd": "lock", "id": windowID, "on": on ? 1 : 0]) { _ in }
    }

    /// Ask the host to give this window the keyboard focus.
    ///
    /// The answer is worth reading rather than dropping. Keystrokes are injected
    /// on the host into whatever window holds the foreground there, so a focus
    /// the host could not take does not degrade gracefully — the stream keeps
    /// looking perfect while everything typed goes into another application.
    /// There is nothing the Mac can do about it from here, but a log line turns
    /// "my typing disappears" into something diagnosable.
    public func focus(windowID: UInt64) {
        send(["cmd": "focus", "id": windowID]) { result in
            guard case .success(let reply) = result else { return }
            if reply["foreground"] as? Bool == false {
                Log.info("[agent] the host could not focus window \(windowID);"
                         + " keystrokes will go to whatever is focused there")
            }
        }
    }

    // MARK: - Transport

    private func send(_ request: [String: Any],
                      completion: @escaping (Result<[String: Any], Error>) -> Void) {
        queue.async { [weak self] in
            guard let self, let connection = self.connection else {
                completion(.failure(AgentError.disconnected))
                return
            }
            // Held, not dropped and not sent: see `authInFlight`. The wait is
            // one round trip on a socket that is already open. A takeover in
            // flight holds them the same way, and for the same kind of reason:
            // the host reads exactly one line before it answers.
            if self.authInFlight || self.takeoverInFlight {
                self.heldWhileAuthenticating.append((request, completion))
                return
            }
            guard let body = try? JSONSerialization.data(withJSONObject: request) else {
                completion(.failure(AgentError.badRequest))
                return
            }
            var line: Data
            if let channel = self.channel {
                // Sealed and length-prefixed. Newline framing is not merely
                // unnecessary past this point, it is unusable: ciphertext
                // contains 0x0A as often as any other byte.
                guard let record = try? channel.seal(body) else {
                    completion(.failure(AgentError.badRequest))
                    return
                }
                line = record
            } else {
                line = body
                line.append(0x0A)  // the agent splits on newlines
            }

            self.nextRequestID &+= 1
            self.pending.append(Pending(id: self.nextRequestID,
                                        command: request["cmd"] as? String ?? "?",
                                        timeout: Self.timeout(for: request),
                                        completion: completion))
            if self.pending.count == 1 { self.armHeadTimeout() }
            connection.send(content: line, completion: .contentProcessed {
                [weak self, weak connection] error in
                guard let error else { return }
                Log.error("[agent] send failed: \(error)")
                // Dropped, not just failed: a request the host may still answer
                // would otherwise hand its reply to whatever is asked next. Only
                // if this is still the current socket — a late error from the
                // last one must not take down its replacement.
                self?.queue.async {
                    guard let self, let connection, self.connection === connection else { return }
                    self.dropConnection(error)
                }
            })
        }
    }

    private func receive() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }

            if let data, !data.isEmpty {
                self.buffer.append(data)
                self.drainLines()
            }
            if isComplete || error != nil {
                Log.info("[agent] connection closed")
                self.noteConnectionLost()
                self.stopHeartbeat()
                // Nil it here too, not just fail the waiters: connect() refuses
                // to run while `connection` is non-nil, so a closed-but-retained
                // NWConnection makes reconnecting impossible for the rest of the
                // process's life.
                self.connection?.cancel()
                self.connection = nil
                self.failPending(error ?? AgentError.disconnected)
                self.report(.disconnected)
                self.scheduleReconnect()
                return
            }
            self.receive()
        }
    }

    private func drainLines() {
        // Two framings, and which is in force changes exactly once per
        // connection: newline-delimited until the auth reply has arrived,
        // length-prefixed sealed records after it.
        while true {
            var line = Data()
            if let channel = self.channel {
                do {
                    guard let opened = try channel.open(from: &buffer) else { return }
                    line = opened
                } catch {
                    Log.error("[agent] a record on the encrypted channel did not "
                              + "authenticate — dropping the connection")
                    dropConnection(AgentError.protocolDesync)
                    return
                }
            } else {
                guard let newline = buffer.firstIndex(of: 0x0A) else { break }
                line = Data(buffer[buffer.startIndex..<newline])
                buffer.removeSubrange(buffer.startIndex...newline)
            }
            if line.isEmpty { continue }
            switch Self.read(line: line) {
            case .message(let message, let repaired):
                if repaired {
                    Log.info("[agent] a \(message["type"] as? String ?? "?") message "
                             + "was not UTF-8; read it with replacement characters")
                }
                handle(message)
            case .unreadablePush(let type):
                Log.error("[agent] skipped a \(type) message that would not parse")
            case .unreadable:
                // A reply, or a line that may hold one: a push the host cut
                // short has the next line it wrote run on behind it. Skipping it
                // leaves the reply queue one short for the rest of the session:
                // `handle` pops one waiting completion per reply, so from here
                // on every answer would go to the caller before it. There are
                // no request ids to resynchronise with, so the only honest
                // recovery is to drop the connection.
                Log.error("[agent] unparseable line — dropping the connection "
                          + "rather than misrouting every later reply")
                dropConnection(AgentError.protocolDesync)
                return
            }
        }

        // A peer that never sends a newline must not grow this without bound.
        // Sized against the agent's own line cap — see the budget note beside
        // kMaxLineBytes in main.cpp; the two have to be chosen together.
        if buffer.count > Self.maxLineBytes {
            Log.error("[agent] response over \(Self.maxLineBytes) bytes, dropping the connection")
            dropConnection(AgentError.oversizedResponse)
        }
    }

    /// Tear the channel down and leave it in a state a later `connect()` can use.
    ///
    /// `connection` is nilled deliberately: `connect()` early-returns while it is
    /// non-nil, so leaving a dead NWConnection in place makes every future
    /// reconnect attempt a silent no-op.
    /// - Parameter reconnect: whether coming back is the right response. It is
    ///   for a desync — a fresh connection is exactly what resynchronises — and
    ///   it is not for a host that failed the impersonation check, where
    ///   retrying just hands the same secret to the same stranger again.
    /// - Parameter delay: when to come back, in place of the usual backoff.
    private func dropConnection(_ error: Error, reconnect: Bool = true,
                                after delay: TimeInterval? = nil) {
        if !reconnect { wantsConnection = false }
        noteConnectionLost()
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        stopHeartbeat()
        failPending(error)
        report(.disconnected)
        if reconnect { scheduleReconnect(after: delay) }
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""

        // hello and the first displays message are pushed unprompted, so they
        // must not consume a pending reply slot.
        switch type {
        case "hello":
            // A takeover the host granted is answered by the greeting itself:
            // from here the connection is an ordinary new one. What was held
            // meanwhile goes once the framing has settled -- with the auth
            // reply when a proof goes out below, and here when none does.
            let tookOver = takeoverInFlight
            takeoverInFlight = false
            if tookOver {
                Log.info("[agent] \(self.host) handed back this Mac's last session")
            }
            defer {
                if tookOver, !authInFlight { releaseHeldRequests() }
            }
            let host = message["host"] as? String ?? self.host
            let version = message["version"] as? Int ?? 0
            // Before any branch below needs it: a token supplied later by the
            // user authenticates against the challenge from THIS greeting.
            authChallenge = message["challenge"] as? String
            // Version 2 exactly. A host offering something else stays in the
            // clear rather than having both ends read each other's bytes as the
            // wrong thing entirely.
            //
            // This greeting is cleartext and unauthenticated, so what it says
            // here settles nothing on its own — see the check on the auth reply,
            // which refuses to carry on unencrypted with a host this Mac holds a
            // token for, however the negotiation went.
            hostOffersChannelCrypto = (message["channelCrypto"] as? Int ?? 0) == 2
            channel = nil
            pendingEphemeral = nil
            Log.info("[agent] host \(host), protocol v\(version)")
            report(.connected(host: host))
            // The greeting says whether a token is wanted. Answering it here,
            // before anything else is sent, keeps authentication out of every
            // other call site — and the agent withholds even the display list
            // until it is satisfied, so there is nothing to race with.
            if message["needsAuth"] as? Bool == true {
                guard let token, !token.isEmpty else {
                    Log.error("[agent] \(host) requires a token and none is stored")
                    // Not a failure: the connection is open and healthy, it is
                    // simply waiting to be told who we are. Ask, rather than
                    // tearing down and telling the user to find a command line.
                    report(.needsToken(host: host, rejected: false))
                    return
                }
                // NO FALLBACK. A greeting with no challenge is either an agent
                // older than auth v2 or something pretending to be one, and
                // there is no way to tell them apart -- so the only safe
                // response to both is to refuse. Falling back to sending the
                // token would hand it to whichever of the two it was.
                guard authenticate(with: token) else {
                    Log.error("[agent] \(host) did not offer an auth challenge")
                    report(.failed("\(host) is running an older version of SolStream, "
                                   + "or something is impersonating it. Update SolStream "
                                   + "on that PC."))
                    dropConnection(AgentError.unexpectedDowngrade, reconnect: false)
                    return
                }
            } else if token != nil {
                // A stored token means the real agent on this host asks for one.
                // Something answering here that says it does not is either a
                // different machine at this address or an impersonator hoping we
                // will just carry on in the clear, with every window title,
                // application name and clipboard transfer readable to it.
                Log.error("[agent] \(host) did not ask for the token this Mac holds for it")
                report(.failed("\(host) did not ask for the token this Mac has stored "
                               + "for it. Something may be impersonating your PC."))
                dropConnection(AgentError.unexpectedDowngrade, reconnect: false)
            }
            return
        case "auth":
            let accepted = message["ok"] as? Bool == true
            if accepted {
                if let token { Self.rememberToken(token, for: host) }
                // This reply is the last thing that arrives in the clear, and
                // it carries the host's half of the exchange. The switch happens
                // here and not a message earlier or later.
                if let ephemeral = pendingEphemeral,
                   let challenge = pendingChallenge,
                   let clientNonce = pendingClientNonce,
                   let hpubHex = message["hpub"] as? String,
                   let hpub = Data(smtHex: hpubHex),
                   let hauth = message["hauth"] as? String,
                   let peer = try? P256.KeyAgreement.PublicKey(x963Representation: [UInt8](hpub)),
                   let shared = try? ephemeral.sharedSecretFromKeyAgreement(with: peer),
                   let derived = ChannelCrypto(
                       token: token ?? "", challenge: challenge,
                       clientNonce: clientNonce,
                       clientPublic: ephemeral.publicKey.x963Representation,
                       hostPublic: hpub,
                       secret: shared.withUnsafeBytes { Data($0) }) {
                    // The host proving it derived the same bytes is the ONLY
                    // thing here that authenticates the host to this Mac — the
                    // challenge-response runs the other way.
                    guard derived.hostAuth == hauth else {
                        Log.error("[agent] \(host) derived DIFFERENT channel keys — "
                                  + "refusing the connection")
                        pendingEphemeral = nil
                        dropConnection(AgentError.protocolDesync, reconnect: false)
                        return
                    }
                    channel = derived
                    Log.info("[agent] token accepted; the channel is encrypted from "
                             + "here, with an ephemeral key")
                } else if pendingEphemeral != nil {
                    Log.error("[agent] \(host) accepted the token but would not "
                              + "agree channel keys")
                } else {
                    Log.info("[agent] token accepted")
                }
                pendingEphemeral = nil
                // Whether this connection is encrypted at all was decided by a
                // field in the cleartext, unauthenticated `hello`, and nothing
                // after it confirms the answer. So anything sitting between the
                // two machines can delete `channelCrypto` from the greeting —
                // or `hpub` from this reply — and both ends fall back to
                // plaintext on their own, each of them satisfied. Nothing looks
                // wrong afterwards: the session works, and the window titles,
                // the application list and every clipboard transfer cross in
                // the clear.
                //
                // A Mac holding a token for this host knows the real agent on
                // it asks for one, and every agent that asks for one also
                // offers the channel. So an unencrypted channel at this point
                // is either a build old enough to need updating or somebody in
                // the middle, and there is no way to tell those apart — which
                // makes stopping the right answer to both. Not reconnecting,
                // for the same reason as the impersonation check above: coming
                // straight back gets the same stripped greeting from the same
                // stranger.
                if channel == nil, token != nil {
                    Log.error("[agent] \(host) took the token but the channel is not "
                              + "encrypted — refusing to carry on in the clear")
                    report(.failed("\(host) would not encrypt the connection. Update "
                                   + "SolStream on that PC; if it is already up to "
                                   + "date, something may be impersonating it."))
                    dropConnection(AgentError.unexpectedDowngrade, reconnect: false)
                    return
                }
            } else {
                Log.error("[agent] token rejected")
                Self.forgetToken(for: host)
                // And forget it here too, not only on disk. It was cleared from
                // UserDefaults and left in this object, so a reconnect before the
                // user had typed a new one read the field rather than the store
                // and sent the same refused proof again — burning one of the
                // host's three attempts per reconnect, and reporting
                // `rejected: true` about a token the person had never been shown.
                token = nil
                report(.needsToken(host: host, rejected: true))
            }
            // Whichever way it went, the framing is now settled on both ends.
            releaseHeldRequests()
            return
        case "cursor":
            // Unsolicited, like hello: the host pushes it when the Windows
            // cursor changes shape, so it must not consume a pending reply slot.
            if let shape = message["shape"] as? String {
                let reportsHidden = (message["reportsHidden"] as? NSNumber)?.boolValue ?? false
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.lastCursorShape = shape
                    self.cursorReportsHidden = reportsHidden
                    self.onCursorShape?(shape)
                }
            }
            return
        case "busy":
            // The host is already serving a Mac and said so instead of leaving
            // us in its accept backlog. Which Mac, and so whether to wait, is
            // `handleBusy`'s question.
            handleBusy(message)
            return
        case "closed":
            // Also unsolicited. Distinct from the `window` reply, which carries
            // `alive` and answers a poll — this one is the host volunteering
            // that an application has quit, and it must not be mistaken for the
            // answer to whatever was in flight when it arrived.
            if let id = (message["id"] as? NSNumber)?.uint64Value {
                DispatchQueue.main.async { [weak self] in self?.onWindowClosed?(id) }
            }
            return
        case "occluded":
            // Unsolicited, and already debounced by the host.
            if let id = (message["id"] as? NSNumber)?.uint64Value {
                let by = message["by"] as? String ?? ""
                DispatchQueue.main.async { [weak self] in self?.onOccluded?(id, by) }
            }
            return
        case "windowsChanged":
            // Unsolicited too, and debounced by the host. Nothing to consume a
            // pending slot with — whoever cares re-asks for the list.
            DispatchQueue.main.async { [weak self] in self?.onWindowsChanged?() }
            return
        case "displays" where greetingDisplaysPending:
            // Told from a reply by WHERE IT SITS IN THE CONNECTION, because the
            // two are identical on the wire and the host sends the unprompted
            // one exactly once, to finish the greeting.
            //
            // What used to stand here was "treat it as a push if nothing is
            // pending", and that is wrong the moment anything is in flight when
            // the greeting's list lands. `releaseHeldRequests` arranges
            // precisely that: it re-sends everything held during the handshake
            // from inside the same receive that is about to read the push, so
            // the push is handed to one of them as its answer. `pending` is a
            // FIFO and the protocol has no request ids, so from that point on
            // every reply goes to the caller before it, for the life of the
            // connection — a window's dimensions arriving as the answer to a
            // clipboard read, and so on down the queue.
            greetingDisplaysPending = false
            // A session again: whatever was lost has been got back, and the
            // next `busy` starts a wait of its own.
            sessionUp = true
            sessionLostAt = nil
            busySince = nil
            busyRetries = 0
            let snapshot = Self.parseDisplays(message)
            setDisplays(snapshot)
            Log.info("[agent] \(snapshot.count) display(s): "
                     + snapshot.map { "\($0.name) \($0.width)x\($0.height)" }.joined(separator: ", "))
            DispatchQueue.main.async { [weak self] in self?.onDisplays?(snapshot) }
            // The greeting is complete — the host sends this only once it is
            // satisfied — so a reconnect can be announced, with `displays`
            // already current for whoever checks the capture display.
            announceReconnection()
            return
        default:
            break
        }

        guard !pending.isEmpty else {
            Log.debug("[agent] unsolicited \(type) message")
            return
        }
        let answered = pending.removeFirst()
        armHeadTimeout()
        answered.completion(.success(message))
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        // Held requests never reached the socket, so nothing will ever answer
        // them. Leaving them queued would hand them to the NEXT connection,
        // where they would consume reply slots that belong to its own traffic.
        let held = heldWhileAuthenticating
        heldWhileAuthenticating.removeAll()
        authInFlight = false
        for item in waiting {
            item.completion(.failure(error))
        }
        for item in held {
            item.completion(.failure(error))
        }
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    // MARK: - Parsing

    /// What one line from the host turned out to be.
    enum LineReading {
        /// A message to handle. `repaired` when it could only be read once the
        /// bytes in it that are not UTF-8 had been replaced.
        case message([String: Any], repaired: Bool)
        /// A push that would not parse, of a kind that can be passed over, and
        /// alone on its line.
        case unreadablePush(String)
        /// Anything else that would not parse.
        case unreadable
    }

    /// The pushes a line that will not parse may be skipped for: unprompted,
    /// answering no request, and carrying nothing the connection depends on.
    /// Missing one costs a cursor shape or a warning, where dropping the
    /// connection over it costs the session -- and its reconnect re-locks the
    /// same windows under the same covering window, so the push comes again.
    ///
    /// Not `hello` or `auth`, which carry the handshake; not `displays`, which
    /// is a reply as often as it is the greeting's push; and not `busy`, which
    /// decides whether this Mac gives up, waits, or asks for its session back.
    static let skippablePushes: Set<String> = ["cursor", "closed", "occluded", "windowsChanged"]

    static func read(line: Data) -> LineReading {
        if let message = try? JSONSerialization.jsonObject(with: line) as? [String: Any] {
            return .message(message, repaired: false)
        }
        // An older host reads the PC's name and a covering window's title with
        // Windows' ANSI calls, so they arrive in the PC's code page: an é from
        // code page 1252 is a lone 0xE9, and JSONSerialization refuses the
        // whole line over it. The rest of the line is sound, so read it again
        // with what is not UTF-8 replaced. A name shown with a U+FFFD in it
        // beats a PC that can never be connected to.
        let repaired = Data(String(decoding: line, as: UTF8.self).utf8)
        if repaired != line,
           let message = try? JSONSerialization.jsonObject(with: repaired) as? [String: Any] {
            return .message(message, repaired: true)
        }
        // Only a push alone on its line. A host whose send fails partway keeps
        // the socket, and its next line runs on from the half it cut off: a
        // reply behind a broken push would be skipped with it, and every later
        // answer handed to the caller before its own.
        if let type = leadingType(of: line), skippablePushes.contains(type),
           !holdsAnotherMessage(line) {
            return .unreadablePush(type)
        }
        return .unreadable
    }

    /// What the host starts every line it writes with.
    private static let lineOpening = Data(#"{"type":""#.utf8)

    /// Whether a second message starts after a line's first byte. The host
    /// escapes every quote inside a string, so `{"type":"` can only ever open
    /// a message.
    private static func holdsAnotherMessage(_ line: Data) -> Bool {
        line.dropFirst().range(of: lineOpening) != nil
    }

    /// The `type` a line names in its first bytes, for a line that will not
    /// parse. The host starts every line it writes with `{"type":"`.
    static func leadingType(of line: Data) -> String? {
        let head = [UInt8](line.prefix(64))
        guard head.starts(with: lineOpening) else { return nil }
        let rest = head.dropFirst(lineOpening.count)
        guard let close = rest.firstIndex(of: UInt8(ascii: "\"")) else { return nil }
        return String(decoding: rest[..<close], as: UTF8.self)
    }

    private static func parseDisplays(_ message: [String: Any]) -> [RemoteDisplay] {
        guard let raw = message["displays"] as? [[String: Any]] else { return [] }
        return raw.compactMap { entry in
            guard let name = entry["name"] as? String,
                  let x = entry["x"] as? Int, let y = entry["y"] as? Int,
                  let w = entry["w"] as? Int, let h = entry["h"] as? Int else { return nil }
            return RemoteDisplay(name: name,
                                 adapter: entry["adapter"] as? String ?? "",
                                 x: x, y: y, width: w, height: h,
                                 isPrimary: entry["primary"] as? Bool ?? false,
                                 isCaptured: entry["captured"] as? Bool ?? false)
        }
    }

    private static func parseWindow(_ entry: [String: Any]) -> RemoteWindow? {
        guard let id = (entry["id"] as? NSNumber)?.uint64Value,
              let x = entry["x"] as? Int, let y = entry["y"] as? Int,
              let w = entry["w"] as? Int, let h = entry["h"] as? Int else { return nil }
        var window = RemoteWindow(id: id,
                                  pid: entry["pid"] as? Int ?? 0,
                                  title: entry["title"] as? String ?? "",
                                  className: entry["class"] as? String ?? "",
                                  x: x, y: y, width: w, height: h,
                                  isOccluded: entry["occluded"] as? Bool ?? false,
                                  occludedBy: entry["occludedBy"] as? String,
                                  captionInset: entry["captionInset"] as? Int ?? 0)
        window.naturalWidth = entry["naturalW"] as? Int ?? 0
        window.naturalHeight = entry["naturalH"] as? Int ?? 0
        return window
    }
}

public enum AgentError: Error {
    case disconnected
    case badRequest
    /// A line arrived that could not be parsed, so replies can no longer be
    /// matched to the requests that asked for them.
    case protocolDesync
    case oversizedResponse
    /// The host stopped asking for a token it had previously required.
    case unexpectedDowngrade
    /// The host is already serving a Mac. There is one capture, one encoder and
    /// one media socket on that PC, so when the Mac is another one this is a
    /// fact about the host rather than a transient failure; when it is this
    /// Mac's own lost connection, it passes once the host lets go of it.
    case hostBusy
    /// The host did not answer in time. The connection is dropped and rebuilt.
    case timedOut
}
