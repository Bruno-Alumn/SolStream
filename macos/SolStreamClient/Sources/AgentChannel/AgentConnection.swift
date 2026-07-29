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
    /// exact string Sunshine's `output_name` setting takes.
    public let name: String
    /// The GDI adapter driving it, e.g. `NVIDIA GeForce RTX 4070 SUPER` or
    /// `Virtual Display Driver`.
    public let adapter: String
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int
    public let isPrimary: Bool
    /// Whether this is the display Sunshine is actually encoding.
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
    }

    private let host: String
    private let port: UInt16
    private let queue = DispatchQueue(label: "com.solstream.agent")

    private var connection: NWConnection?
    private var buffer = Data()
    /// Replies arrive in request order, so a FIFO of continuations is enough —
    /// no request ids needed in the protocol.
    private var pending: [(Result<[String: Any], Error>) -> Void] = []

    public private(set) var displays: [RemoteDisplay] = []

    /// Identifies the Sunshine process now running on the host, so a client can
    /// tell a restart from a continuation. Empty if Sunshine is not running.
    public private(set) var sunshineInstance: String = ""

    public var onState: ((State) -> Void)?
    public var onDisplays: (([RemoteDisplay]) -> Void)?
    /// The Windows cursor changed shape. Pushed by the host, not polled.
    public var onCursorShape: ((String) -> Void)?
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

    private static func tokenKey(for host: String) -> String {
        "SolStream.agentToken.\(host)"
    }

    public static func storedToken(for host: String) -> String? {
        UserDefaults.standard.string(forKey: tokenKey(for: host))
    }

    public static func rememberToken(_ token: String, for host: String) {
        UserDefaults.standard.set(token, forKey: tokenKey(for: host))
    }

    /// Drop a token the host refused, so the next connection asks for a new one
    /// rather than silently retrying something already known to be wrong.
    public static func forgetToken(for host: String) {
        UserDefaults.standard.removeObject(forKey: tokenKey(for: host))
    }

    /// Answer a `needsToken` with what the user typed.
    ///
    /// The connection is still open at this point, so this authenticates in
    /// place: the agent sends the display list once it is satisfied, which is
    /// the same sequence a session with a stored token goes through.
    public func supplyToken(_ token: String) {
        let trimmed = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        self.token = trimmed
        if !authenticate(with: trimmed) {
            Log.error("[agent] \(host) offered no auth challenge; refusing to send the token")
            report(.failed("\(host) is running an older version of SolStream, or "
                           + "something is impersonating it. Update SolStream on that PC."))
            dropConnection(AgentError.unexpectedDowngrade, reconnect: false)
        }
    }

    public init(host: String, port: UInt16 = StreamPorts.agent, token: String? = nil) {
        self.host = host
        self.port = port
        self.token = token ?? Self.storedToken(for: host)
    }

    deinit {
        connection?.cancel()
    }

    /// Set between `connect()` and `disconnect()`.
    ///
    /// The difference between a socket that closed and a socket we closed. Only
    /// the first is worth reconnecting.
    private var wantsConnection = false
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

    public func connect() {
        guard connection == nil else { return }
        wantsConnection = true
        report(.connecting)

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
                    DispatchQueue.main.async { [weak self] in self?.onReconnected?() }
                }
            case .failed(let error):
                Log.error("[agent] connection failed: \(error)")
                self.report(.failed(error.localizedDescription))
                self.failPending(error)
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
    private func scheduleReconnect() {
        // Two paths report the same death — the receive completion and the
        // connection's own state handler — and both call this. Without the
        // guard a single drop counts as two attempts, so the backoff doubles
        // for a failure that happened once.
        guard wantsConnection, connection == nil, !reconnectPending else { return }
        reconnectPending = true
        reconnectAttempt += 1
        let delay = min(pow(2.0, Double(min(reconnectAttempt, 5))), 30.0)
        Log.info("[agent] reconnecting to \(host) in \(Int(delay))s (attempt \(reconnectAttempt))")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.reconnectPending = false
            guard self.wantsConnection, self.connection == nil else { return }
            self.connect()
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

    public func disconnect() {
        // Release the callbacks as well as the socket. They are stored here, so
        // a call site that captures this object strongly makes it retain itself
        // — and then the socket is never cancelled and whatever else the closure
        // captured is pinned too. Clearing them means one such mistake costs a
        // stale closure rather than a permanent leak.
        onState = nil
        onDisplays = nil
        onCursorShape = nil
        onWindowClosed = nil
        onReconnected = nil
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

        guard let line = try? JSONSerialization.data(withJSONObject: [
            "cmd": "auth",
            "proof": Self.hex(Data(proof)),
            "cnonce": Self.hex(clientNonce),
        ]) else { return false }
        var payload = line
        payload.append(0x0A)
        connection.send(content: payload, completion: .contentProcessed { error in
            if let error { Log.error("[agent] could not send the auth proof: \(error)") }
        })
        return true
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

    /// Open a media session: ephemeral ECDH over the channel that already
    /// authenticated us.
    ///
    /// This replaces GameStream's entire setup -- HTTP pairing, HTTPS /launch and
    /// seven RTSP round trips -- with one command, because two programs that
    /// have already proved who they are to each other do not need introducing
    /// again.
    ///
    /// Returns nil if the host's `hostAuth` does not match what this Mac
    /// derived. That check is the whole point of doing it here: without it the
    /// first sign of a key mismatch is every packet failing its authentication
    /// tag, which is indistinguishable from a broken network.
    /// What the host should capture, and how.
    public struct MediaRequest: Sendable {
        /// `\\.\DISPLAYn`, as the `displays` command names it.
        public var display: String?
        /// A window id from the `windows` command, if a single window is wanted.
        public var window: UInt64?
        public var fps: Int = 60
        public var bitrate: Int = 20_000_000
        public var audio: Bool = true

        public init(display: String? = nil, window: UInt64? = nil,
                    fps: Int = 60, bitrate: Int = 20_000_000, audio: Bool = true) {
            self.display = display
            self.window = window
            self.fps = fps
            self.bitrate = bitrate
            self.audio = audio
        }
    }

    /// The keys, the UDP port, and whether the host actually started sending.
    public struct MediaSession: Sendable {
        public let keys: MediaKeys
        public let port: UInt16
        public let streaming: Bool
        public let message: String?
    }

    /// Stop the host's media session, leaving the agent channel up.
    public func closeMediaSession() {
        send(["cmd": "media", "op": "stop"]) { _ in }
    }

    /// Point the running session at something else. Costs one keyframe and no
    /// renegotiation: the keys, the socket and the counter all survive.
    public func retargetMedia(window: UInt64?, display: String?) {
        var message: [String: Any] = ["cmd": "media", "op": "retarget"]
        if let window { message["window"] = window }
        if let display { message["display"] = display }
        send(message) { _ in }
    }

    public func openMediaSession(_ request: MediaRequest = .init()) async -> MediaSession? {
        guard let token else {
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
                                      "cpub": cpub.smtHex, "cnonce": cnonce.smtHex,
                                      "fps": request.fps, "bitrate": request.bitrate,
                                      "audio": request.audio ? 1 : 0]
        if let display = request.display { message["display"] = display }
        if let window = request.window { message["window"] = window }

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
        let port = UInt16(reply["hport"] as? Int ?? 47631)
        Log.info("[media] session \(hcount) open, keys agree (sid \(keys.sessionTag)), "
                 + "host \(streaming ? "is streaming" : "is NOT streaming: \(message2 ?? "?")")")
        return MediaSession(keys: keys, port: port, streaming: streaming, message: message2)
    }

    /// Ask for the host's displays.
    public func refreshDisplays(completion: (([RemoteDisplay]) -> Void)? = nil) {
        send(["cmd": "displays"]) { [weak self] result in
            guard case .success(let message) = result else {
                completion?([])
                return
            }
            let displays = Self.parseDisplays(message)
            self?.displays = displays
            completion?(displays)
        }
    }

    public enum PairingResult: Sendable, Equatable {
        case paired
        /// The host has no stored Sunshine credentials, so it cannot pair on the
        /// user's behalf. Fall back to showing the PIN.
        case needsHostSetup(String)
        case failed(String)
    }

    /// Ask the host to approve this client's pairing PIN.
    ///
    /// Sunshine normally requires a human to type the PIN into its web UI. The
    /// agent runs on the host and can post it to Sunshine's local API instead, so
    /// the user never sees a browser, a certificate warning, or a PIN page.
    public func pair(pin: String, clientName: String,
                     completion: @escaping (PairingResult) -> Void) {
        send(["cmd": "pair", "pin": pin, "name": clientName]) { result in
            guard case .success(let message) = result else {
                completion(.failed("the agent did not answer"))
                return
            }
            if message["ok"] as? Bool == true {
                completion(.paired)
                return
            }
            let detail = message["message"] as? String ?? "the host refused the pairing"
            if message["reason"] as? String == "no-credentials" {
                completion(.needsHostSetup(detail))
            } else {
                completion(.failed(detail))
            }
        }
    }

    public struct RemoteClipboard: Sendable, Equatable {
        public let text: String
        public let sequence: Int
        public let isUnchanged: Bool
        public let wasTruncated: Bool
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
                                       wasTruncated: message["truncated"] as? Bool ?? false))
        }
    }

    /// Largest clipboard text the host will take, and the largest line either
    /// end will read. Both mirror the constants in main.cpp and have to move
    /// with them — whichever side hits its line cap first drops the control
    /// channel, and the picture stays live while every window command quietly
    /// stops working.
    static let maxClipboardBytes = 256 * 1024
    static let maxLineBytes = 4 * 1024 * 1024

    /// Trim to fit the host's clipboard budget, measured in UTF-8 bytes.
    ///
    /// Bytes rather than characters because that is what the agent counts, and
    /// the two differ by up to 4×: 100k of CJK text is well inside any character
    /// limit and three times over the byte one. Trimmed by `Character` so a
    /// grapheme cluster — or worse, a UTF-8 sequence — is never cut in half.
    static func clipboardPayload(_ text: String) -> (text: String, truncated: Bool) {
        let utf8 = text.utf8
        guard utf8.count > maxClipboardBytes else { return (text, false) }

        // Seek straight to the byte cap, then walk back to the nearest Character
        // boundary. Repeatedly dropping Characters and re-measuring would be
        // quadratic, and sizing the drop from the byte overshoot removes far too
        // much when the text is multi-byte — 2 MB of flag emoji is 1.75 MB over,
        // which is more Characters than the string has, so it would trim the
        // whole clipboard away.
        guard let capped = utf8.index(utf8.startIndex, offsetBy: maxClipboardBytes,
                                      limitedBy: utf8.endIndex) else { return (text, false) }
        var boundary = capped
        while boundary > utf8.startIndex, String.Index(boundary, within: text) == nil {
            boundary = utf8.index(before: boundary)
        }
        guard let cut = String.Index(boundary, within: text) else { return ("", true) }
        return (String(text[text.startIndex..<cut]), true)
    }

    public func setClipboard(_ text: String, completion: ((Int?) -> Void)? = nil) {
        let (text, truncated) = Self.clipboardPayload(text)
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
        /// Width of the host window's resize grab area, in host pixels.
        public let resizeBorder: CGFloat
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
            completion?(Placement(frame: CGRect(x: x, y: y, width: w, height: h),
                                  minimumSize: minimum,
                                  resizeBorder: CGFloat(message["border"] as? Int ?? 0)))
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
            guard var line = try? JSONSerialization.data(withJSONObject: request) else {
                completion(.failure(AgentError.badRequest))
                return
            }
            line.append(0x0A)  // the agent splits on newlines

            self.pending.append(completion)
            connection.send(content: line, completion: .contentProcessed { error in
                if let error {
                    Log.error("[agent] send failed: \(error)")
                    self.queue.async { self.failPending(error) }
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
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            if line.isEmpty { continue }
            guard let message = try? JSONSerialization.jsonObject(with: Data(line))
                    as? [String: Any] else {
                // Skipping an unparseable line leaves the reply queue one short
                // for the rest of the session: `handle` pops one waiting
                // completion per reply, so from here on every answer would go to
                // the caller before it. There are no request ids to resynchronise
                // with, so the only honest recovery is to drop the connection.
                Log.error("[agent] unparseable line — dropping the connection "
                          + "rather than misrouting every later reply")
                dropConnection(AgentError.protocolDesync)
                return
            }
            handle(message)
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
    private func dropConnection(_ error: Error, reconnect: Bool = true) {
        if !reconnect { wantsConnection = false }
        connection?.cancel()
        connection = nil
        buffer.removeAll()
        stopHeartbeat()
        failPending(error)
        report(.disconnected)
        if reconnect { scheduleReconnect() }
    }

    private func handle(_ message: [String: Any]) {
        let type = message["type"] as? String ?? ""

        // hello and the first displays message are pushed unprompted, so they
        // must not consume a pending reply slot.
        switch type {
        case "hello":
            let host = message["host"] as? String ?? self.host
            let version = message["version"] as? Int ?? 0
            sunshineInstance = message["sunshineInstance"] as? String ?? ""
            // Before any branch below needs it: a token supplied later by the
            // user authenticates against the challenge from THIS greeting.
            authChallenge = message["challenge"] as? String
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
                // A hook for measuring the media handshake against a real
                // host, because a bare CLI binary cannot: macOS local-network
                // privacy grants the signed .app and denies an unsigned
                // executable, silently, and the symptom is a connection that
                // reports "connecting" forever. Removed once the session is
                // opened as a matter of course rather than on request.
                if ProcessInfo.processInfo.environment["SOLSTREAM_MEDIA_TEST"] == "1" {
                    Task { [weak self] in
                        try? await Task.sleep(nanoseconds: 400_000_000)
                        _ = await self?.openMediaSession()
                    }
                }
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
                // will just carry on — and what we carry on to do is hand it the
                // pairing PIN, which is the one secret that makes every proof in
                // the pairing handshake meaningful.
                Log.error("[agent] \(host) did not ask for the token this Mac holds for it")
                report(.failed("\(host) did not ask for the token this Mac has stored "
                               + "for it. Something may be impersonating your PC."))
                dropConnection(AgentError.unexpectedDowngrade, reconnect: false)
            }
            return
        case "auth":
            if message["ok"] as? Bool == true {
                if let token { Self.rememberToken(token, for: host) }
                Log.info("[agent] token accepted")
            } else {
                Log.error("[agent] token rejected")
                Self.forgetToken(for: host)
                report(.needsToken(host: host, rejected: true))
            }
            return
        case "cursor":
            // Unsolicited, like hello: the host pushes it when the Windows
            // cursor changes shape, so it must not consume a pending reply slot.
            if let shape = message["shape"] as? String {
                DispatchQueue.main.async { [weak self] in self?.onCursorShape?(shape) }
            }
            return
        case "busy":
            // The host is already serving another Mac and said so instead of
            // leaving us in its accept backlog. Not a retryable failure: coming
            // back in two seconds finds the same Mac still connected, and a
            // reconnect loop against a busy host is indistinguishable from one
            // against a broken one.
            let message = message["message"] as? String
                ?? "\(host) is already streaming to another Mac."
            Log.error("[agent] \(message)")
            report(.failed(message))
            dropConnection(AgentError.hostBusy, reconnect: false)
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
        case "displays" where pending.isEmpty:
            displays = Self.parseDisplays(message)
            Log.info("[agent] \(displays.count) display(s): "
                     + displays.map { "\($0.name) \($0.width)x\($0.height)" }.joined(separator: ", "))
            let snapshot = displays
            DispatchQueue.main.async { [weak self] in self?.onDisplays?(snapshot) }
            return
        default:
            break
        }

        guard !pending.isEmpty else {
            Log.debug("[agent] unsolicited \(type) message")
            return
        }
        let completion = pending.removeFirst()
        completion(.success(message))
    }

    private func failPending(_ error: Error) {
        let waiting = pending
        pending.removeAll()
        for completion in waiting {
            completion(.failure(error))
        }
    }

    private func report(_ state: State) {
        DispatchQueue.main.async { [weak self] in self?.onState?(state) }
    }

    // MARK: - Parsing

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
        return RemoteWindow(id: id,
                            pid: entry["pid"] as? Int ?? 0,
                            title: entry["title"] as? String ?? "",
                            className: entry["class"] as? String ?? "",
                            x: x, y: y, width: w, height: h,
                            isOccluded: entry["occluded"] as? Bool ?? false,
                            occludedBy: entry["occludedBy"] as? String,
                            captionInset: entry["captionInset"] as? Int ?? 0)
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
    /// The host is already serving another Mac. Sunshine runs one session, so
    /// this is a fact about the host rather than a transient failure.
    case hostBusy
}
