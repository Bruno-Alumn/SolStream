import CryptoKit
import Network
import XCTest
@testable import AgentChannel
@testable import MediaSession

/// Coming back to a host that is still holding this Mac's last connection, over
/// a real socket. A stand-in host on IPv6 loopback turns the Mac away, offers
/// it a takeover, and plays auth v2 and the channel keys the way the agent
/// does.
///
/// AgentReconnectTests decides each case on paper. These check that the
/// connection acts on the decision: that it knocks again or stops, says it is
/// waiting or that it has failed, and sends nothing while a takeover is out --
/// the host reads exactly one line then, and a request read in its place is
/// never answered.
final class AgentReconnectLoopbackTests: XCTestCase {

    /// Holds the tokens and the client id, so no test reads or writes the
    /// person's own.
    private var folder: URL!
    private var suite: String!
    /// The id every connection made in a test sends.
    private var clientID: String!

    override func setUpWithError() throws {
        try super.setUpWithError()
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-reconnect-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        TokenStore.directoryOverride = folder
        // A path, not a name: a named suite leaves its plist behind in
        // ~/Library/Preferences after every run, even once emptied.
        suite = folder.appendingPathComponent("defaults").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        AgentConnection.clientIDDefaultsOverride = defaults
        clientID = AgentConnection.clientID(in: defaults)
    }

    override func tearDown() {
        AgentConnection.busyTimingOverride = nil
        AgentConnection.clientIDDefaultsOverride = nil
        TokenStore.directoryOverride = nil
        UserDefaults().removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: folder)
        super.tearDown()
    }

    private static let token = "00112233445566778899aabbccddeeff"

    // MARK: - A host that predates the takeover

    /// The host has not noticed the Mac's last connection is dead, and turns
    /// it away twice before it does.
    func testABusyFromAnOlderHostOnAReconnectIsWaitedOut() throws {
        let lose = DispatchSemaphore(value: 0)
        let host = ScriptedHost { index, connection in
            switch index {
            case 0:
                connection.greetWithoutAuth()
                _ = lose.wait(timeout: .now() + 10)
                connection.close()
            case 1, 2:
                connection.send(ScriptedHost.busy())
                Thread.sleep(forTimeInterval: 0.2)
                connection.close()
            default:
                connection.greetWithoutAuth()
            }
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port)
        defer { agent.disconnect() }
        let states = StateRecord(agent)
        connectAndWaitForGreeting(agent)

        let back = expectation(description: "reconnected")
        agent.onReconnected = { back.fulfill() }
        lose.signal()
        wait(for: [back], timeout: 30)
        XCTAssertEqual(states.failures, [], "a busy from an older host on a reconnect is not final")
        XCTAssertFalse(states.waits.isEmpty, "the wait is said")
        XCTAssertEqual(host.connections, 4)
    }

    func testABusyFromAnOlderHostOnAFirstConnectionIsFinal() throws {
        let host = ScriptedHost { _, connection in
            connection.send(ScriptedHost.busy())
            Thread.sleep(forTimeInterval: 0.3)
            connection.close()
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port)
        defer { agent.disconnect() }
        let states = StateRecord(agent)
        let failed = expectation(description: "failed")
        states.onFailure = { _ in failed.fulfill() }
        agent.connect()
        wait(for: [failed], timeout: 5)
        XCTAssertEqual(states.failures, [ScriptedHost.anotherMac],
                       "the host's own words, as a Mac that predates the takeover shows them")
        XCTAssertFalse(agent.willReconnect)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(host.connections, 1, "no second knock")
    }

    // MARK: - A host that offers a takeover

    /// The host offers the session back and this Mac asks for it. A request
    /// made before the host answers must wait for the answer: then the auth
    /// proof, and only then the request, sealed.
    func testATakeoverHoldsEveryRequestUntilTheHostAnswers() throws {
        let lose = DispatchSemaphore(value: 0)
        let asked = DispatchSemaphore(value: 0)
        let answer = DispatchSemaphore(value: 0)
        let seen = Observations()
        let host = ScriptedHost { index, connection in
            switch index {
            case 0:
                guard let greeting = connection.greetAndAuthenticate(token: Self.token) else { return }
                seen.set("firstAuthClient", greeting.auth["client"])
                _ = lose.wait(timeout: .now() + 10)
                connection.close()
            case 1:
                let challenge = ScriptedHost.randomHex(32)
                seen.set("challenge", challenge)
                connection.send(ScriptedHost.busy(offering: challenge))
                seen.set("takeover", ScriptedHost.json(connection.readLine(timeout: 5)))
                asked.signal()
                _ = answer.wait(timeout: .now() + 10)
                // Long enough for a request that was not held to have arrived.
                Thread.sleep(forTimeInterval: 0.8)
                seen.set("bytesBeforeAnswer", connection.buffered.count)
                guard let greeting = connection.greetAndAuthenticate(token: Self.token) else { return }
                seen.set("secondAuthClient", greeting.auth["client"])
                guard connection.readRecord(timeout: 3) != nil else { return }
                seen.set("sealedRequest", true)
                connection.sendRecord(ScriptedHost.windows, sealedBy: greeting.channel)
            default:
                seen.set("unexpected", index)
            }
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port, token: Self.token)
        defer { agent.disconnect() }
        let states = StateRecord(agent)
        connectAndWaitForGreeting(agent)

        let back = expectation(description: "reconnected")
        agent.onReconnected = { back.fulfill() }
        lose.signal()
        XCTAssertEqual(asked.wait(timeout: .now() + 10), .success, "no takeover was asked for")

        let answered = expectation(description: "windows answered")
        var titles: [String] = []
        agent.windows { windows in
            titles = windows.map(\.title)
            answered.fulfill()
        }
        answer.signal()
        wait(for: [back, answered], timeout: 10)

        let takeover = try XCTUnwrap(seen.get("takeover") as? [String: Any])
        XCTAssertEqual(takeover["cmd"] as? String, "takeover")
        XCTAssertEqual(takeover["client"] as? String, clientID)
        let challenge = try XCTUnwrap(seen.get("challenge") as? String)
        let nonce = try XCTUnwrap(Data(smtHex: takeover["cnonce"] as? String ?? ""))
        let proof = try XCTUnwrap(AgentConnection.takeoverProof(
            token: Self.token, challenge: challenge, clientNonce: nonce, clientID: clientID))
        XCTAssertEqual(takeover["proof"] as? String, AgentConnection.hex(proof))
        XCTAssertEqual(seen.get("bytesBeforeAnswer") as? Int, 0,
                       "nothing may follow the takeover until it is answered")
        XCTAssertEqual(seen.get("sealedRequest") as? Bool, true,
                       "the held request went after the auth, sealed")
        XCTAssertEqual(titles, ["Notepad"], "and was answered")
        XCTAssertEqual(seen.get("firstAuthClient") as? String, clientID)
        XCTAssertEqual(seen.get("secondAuthClient") as? String, clientID)
        XCTAssertNil(seen.get("unexpected"))
        XCTAssertEqual(states.failures, [])
    }

    /// A request already on its way when the offer comes. The host reads one
    /// line and takes it for the answer, so asking now would hand it the
    /// request instead, and its reply slot to whatever came next. The offer is
    /// left alone and the `busy` is the refusal it otherwise is.
    func testNoTakeoverIsAskedForWithARequestAlreadyOnTheWire() throws {
        let seen = Observations()
        let host = ScriptedHost { _, connection in
            // Offered only once the request has arrived, so it was on the wire
            // before the offer was.
            seen.set("first", ScriptedHost.json(connection.readLine(timeout: 5)))
            connection.send(ScriptedHost.busy(offering: ScriptedHost.randomHex(32)))
            seen.set("after", connection.readLine(timeout: 1.5))
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port, token: Self.token)
        defer { agent.disconnect() }
        let states = StateRecord(agent)
        let failed = expectation(description: "failed")
        states.onFailure = { _ in failed.fulfill() }
        let answered = expectation(description: "windows answered")
        var titles: [String]?
        agent.connect()
        agent.windows { windows in
            titles = windows.map(\.title)
            answered.fulfill()
        }
        wait(for: [failed, answered], timeout: 5)

        let first = try XCTUnwrap(seen.get("first") as? [String: Any])
        XCTAssertEqual(first["cmd"] as? String, "windows", "the request was on the wire first")
        XCTAssertEqual(states.failures, [ScriptedHost.anotherMac],
                       "the busy was handled as a refusal")
        XCTAssertEqual(titles, [], "and the request failed with the connection")
        // Long enough for a takeover request to have followed.
        Thread.sleep(forTimeInterval: 2)
        XCTAssertNil(seen.get("after"), "no takeover was asked for")
        XCTAssertEqual(host.connections, 1)
    }

    /// Back during a slow launch, and the same PC chosen again: the host is
    /// still letting go of this Mac's own session, so even a first connection
    /// waits for it rather than being told another Mac is streaming.
    func testAHostLettingGoOfThisMacsSessionIsWaitedForOnAFirstConnection() throws {
        let seen = Observations()
        let host = ScriptedHost { index, connection in
            connection.send(ScriptedHost.busy(offering: ScriptedHost.randomHex(32)))
            let takeover = ScriptedHost.json(connection.readLine(timeout: 5))
            seen.append("clients", takeover?["client"] as? String ?? "none")
            if index == 0 {
                connection.send(ScriptedHost.busy(holder: "self"))
                Thread.sleep(forTimeInterval: 0.2)
                connection.close()
            } else {
                connection.greetAndAuthenticate(token: Self.token)
            }
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port, token: Self.token)
        defer { agent.disconnect() }
        let states = StateRecord(agent)
        let greeted = expectation(description: "greeted")
        agent.onDisplays = { _ in greeted.fulfill() }
        agent.connect()
        wait(for: [greeted], timeout: 15)
        XCTAssertEqual(states.failures, [])
        XCTAssertEqual(states.waits.count, 1)
        XCTAssertEqual(host.connections, 2)
        XCTAssertEqual(seen.get("clients") as? [String], [clientID, clientID])
    }

    /// Somebody else has the PC. Final even on a reconnect, where a host that
    /// could not say would be waited for.
    func testAHostThatNamesAnotherMacIsFinalEvenWhileReconnecting() throws {
        let lose = DispatchSemaphore(value: 0)
        let host = ScriptedHost { index, connection in
            if index == 0 {
                connection.greetAndAuthenticate(token: Self.token)
                _ = lose.wait(timeout: .now() + 10)
                connection.close()
            } else {
                connection.send(ScriptedHost.busy(offering: ScriptedHost.randomHex(32)))
                _ = connection.readLine(timeout: 5)
                connection.send(ScriptedHost.busy(holder: "other"))
                Thread.sleep(forTimeInterval: 0.2)
                connection.close()
            }
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port, token: Self.token)
        defer { agent.disconnect() }
        let states = StateRecord(agent)
        connectAndWaitForGreeting(agent)

        let failed = expectation(description: "failed")
        states.onFailure = { _ in failed.fulfill() }
        lose.signal()
        wait(for: [failed], timeout: 10)
        XCTAssertEqual(states.failures, [ScriptedHost.anotherMac])
        XCTAssertEqual(states.waits, [], "not a wait: waiting will not change it")
        XCTAssertFalse(agent.willReconnect)
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(host.connections, 2, "no knock after the one that was refused")
    }

    // MARK: - The bound

    /// A host that goes on saying it is letting go of this Mac's session --
    /// stuck in a command, or held live by a second copy of the app -- is
    /// given up on once the patience has run out since the loss, and then
    /// left alone.
    ///
    /// On a shorter clock than the app's 45 seconds, so the test does not
    /// spend a minute waiting. The patience still has to outlast the two
    /// seconds the Mac waits before its first knock after the loss, or it
    /// would give up on that knock without ever having waited.
    func testAHostThatNeverLetsGoIsGivenUpOnAndLeftAlone() throws {
        let timing = AgentConnection.BusyTiming(patience: 4, firstRetry: 0.2, longestRetry: 0.6)
        AgentConnection.busyTimingOverride = timing
        let lose = DispatchSemaphore(value: 0)
        let host = ScriptedHost { index, connection in
            if index == 0 {
                connection.greetAndAuthenticate(token: Self.token)
                _ = lose.wait(timeout: .now() + 10)
                connection.close()
            } else {
                connection.send(ScriptedHost.busy(offering: ScriptedHost.randomHex(32)))
                _ = connection.readLine(timeout: 5)
                connection.send(ScriptedHost.busy(holder: "self"))
                Thread.sleep(forTimeInterval: 0.2)
                connection.close()
            }
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port, token: Self.token)
        defer { agent.disconnect() }
        let states = StateRecord(agent)
        connectAndWaitForGreeting(agent)

        let failed = expectation(description: "gave up")
        states.onFailure = { _ in failed.fulfill() }
        let lost = Date()
        lose.signal()
        wait(for: [failed], timeout: timing.patience + 10)
        let waited = Date().timeIntervalSince(lost)
        XCTAssertGreaterThanOrEqual(waited, timing.patience)
        XCTAssertLessThan(waited, timing.patience + 5,
                          "given up within a retry or so of the patience running out")
        XCTAssertFalse(agent.willReconnect)
        XCTAssertGreaterThanOrEqual(states.waits.count, 3, "it knocked again meanwhile, and said so")
        // Not the host's "still letting go", which promises a wait that is
        // over: nothing tries again after this.
        XCTAssertEqual(states.failures, [AgentConnection.heldByThisMacMessage(host: "::1")])
        XCTAssertFalse(states.failures.contains { $0.contains("letting go") })

        // Longer than the longest wait between knocks, and than the two
        // seconds a reconnect would wait.
        let knocks = host.connections
        Thread.sleep(forTimeInterval: 3)
        XCTAssertEqual(host.connections, knocks, "no more knocking after giving up")
    }

    // MARK: - Asking for the displays again

    /// A reply with no list in it is no answer: the caller is told nil and the
    /// greeting's list is kept. A list with nothing in it is an answer, and
    /// replaces the list, so a display that has gone is not streamed from.
    func testADisplayAnswerWithNoListKeepsTheListAndAnEmptyOneReplacesIt() throws {
        let seen = Observations()
        let host = ScriptedHost { _, connection in
            connection.greetWithoutAuth()
            seen.set("first", ScriptedHost.json(connection.readLine(timeout: 5))?["cmd"])
            connection.send(#"{"type":"displays"}"#)
            _ = connection.readLine(timeout: 5)
            connection.send(#"{"type":"displays","displays":[]}"#)
            Thread.sleep(forTimeInterval: 2)
        }
        let port = try host.start()
        defer { host.stop() }
        let agent = AgentConnection(host: "::1", port: port)
        defer { agent.disconnect() }
        connectAndWaitForGreeting(agent)
        XCTAssertEqual(agent.displays.map(\.width), [1920])

        let noList = expectation(description: "reply with no list")
        agent.refreshDisplays { displays in
            XCTAssertNil(displays, "the caller is told there was no answer")
            noList.fulfill()
        }
        wait(for: [noList], timeout: 5)
        XCTAssertEqual(seen.get("first") as? String, "displays")
        XCTAssertEqual(agent.displays.map(\.width), [1920], "the greeting's list is kept")

        let empty = expectation(description: "empty list")
        agent.refreshDisplays { displays in
            XCTAssertEqual(displays, [], "the caller is told what came")
            empty.fulfill()
        }
        wait(for: [empty], timeout: 5)
        XCTAssertEqual(agent.displays, [], "a PC with no display says so")
    }

    // MARK: - Helpers

    /// Connect, and wait for the host's first display list.
    private func connectAndWaitForGreeting(_ agent: AgentConnection) {
        let greeted = expectation(description: "first greeting")
        greeted.assertForOverFulfill = false
        agent.onDisplays = { _ in greeted.fulfill() }
        agent.connect()
        wait(for: [greeted], timeout: 5)
        agent.onDisplays = nil
    }
}

/// What a connection reported, in order. Its callbacks arrive on the main
/// queue, where the test reads it.
private final class StateRecord {
    private(set) var states: [AgentConnection.State] = []
    /// Called for the first failure only. A second is for the test to count in
    /// `failures`, not to fulfil an expectation twice.
    var onFailure: ((String) -> Void)?

    init(_ agent: AgentConnection) {
        agent.onState = { [weak self] state in
            guard let self else { return }
            self.states.append(state)
            if case .failed(let message) = state, self.failures.count == 1 {
                self.onFailure?(message)
            }
        }
    }

    var failures: [String] {
        states.compactMap { if case .failed(let message) = $0 { return message } else { return nil } }
    }

    var waits: [String] {
        states.compactMap { if case .waiting(let message) = $0 { return message } else { return nil } }
    }
}

/// What a host's connections saw, written from their threads and read by the
/// test once they are done.
private final class Observations {
    private let lock = NSLock()
    private var values: [String: Any] = [:]

    func set(_ key: String, _ value: Any?) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func append(_ key: String, _ value: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = (values[key] as? [String] ?? []) + [value]
    }

    func get(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }
}

/// A host that serves each connection with a script of its own, on a thread of
/// its own, listening on IPv6 loopback only.
private final class ScriptedHost {
    private let queue = DispatchQueue(label: "ScriptedHost")
    private let script: (Int, ScriptedConnection) -> Void
    private var listener: NWListener?
    private let lock = NSLock()
    private var accepted: [ScriptedConnection] = []

    /// - Parameter script: run for each connection, with how many came before it.
    init(script: @escaping (Int, ScriptedConnection) -> Void) {
        self.script = script
    }

    /// How many connections have arrived.
    var connections: Int {
        lock.lock()
        defer { lock.unlock() }
        return accepted.count
    }

    func start() throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: "::1", port: .any)
        let listener = try NWListener(using: parameters)
        self.listener = listener
        let ready = DispatchSemaphore(value: 0)
        listener.stateUpdateHandler = { state in
            switch state {
            case .ready, .failed, .cancelled: ready.signal()
            default: break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            let scripted = ScriptedConnection(connection, queue: self.queue)
            self.lock.lock()
            let index = self.accepted.count
            self.accepted.append(scripted)
            self.lock.unlock()
            DispatchQueue.global().async { self.script(index, scripted) }
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw NWError.posix(.EADDRNOTAVAIL)
        }
        return port
    }

    func stop() {
        lock.lock()
        let all = accepted
        lock.unlock()
        all.forEach { $0.close() }
        listener?.cancel()
        listener = nil
    }

    // MARK: What the agent says

    static let anotherMac = "TEST-PC is already streaming to another Mac. Disconnect there first."
    static let sameMac = "TEST-PC is still letting go of this Mac's last connection."

    static let displays = #"{"type":"displays","displays":[{"name":"\\\\.\\DISPLAY1","adapter":"x","#
        + #""x":0,"y":0,"w":1920,"h":1080,"primary":true,"captured":true}]}"#
    static let windows = #"{"type":"windows","windows":[{"id":1,"pid":2,"title":"Notepad","#
        + #""class":"C","x":0,"y":0,"w":10,"h":10}]}"#

    /// A refusal as the agent words it: as every host has always sent it with
    /// neither argument, with the offer of a takeover, or naming the holder.
    static func busy(offering challenge: String? = nil, holder: String? = nil) -> String {
        var fields: [String: Any] = ["type": "busy", "virtualDisplay": false]
        fields["message"] = holder == "self" ? sameMac : anotherMac
        if let challenge {
            fields["takeover"] = 1
            fields["challenge"] = challenge
        }
        if let holder { fields["holder"] = holder }
        let data = try! JSONSerialization.data(withJSONObject: fields)
        return String(decoding: data, as: UTF8.self)
    }

    static func randomHex(_ count: Int) -> String {
        (0..<count).map { _ in String(format: "%02x", UInt8.random(in: 0...255)) }.joined()
    }

    static func json(_ line: String?) -> [String: Any]? {
        guard let line else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any]
    }
}

/// One connection to the scripted host, read a line or a record at a time.
private final class ScriptedConnection {
    private let connection: NWConnection
    private let condition = NSCondition()
    private var received = Data()
    private var closed = false

    init(_ connection: NWConnection, queue: DispatchQueue) {
        self.connection = connection
        connection.start(queue: queue)
        receive()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            let ended = isComplete || error != nil
            self.condition.lock()
            if let data { self.received.append(data) }
            if ended { self.closed = true }
            self.condition.broadcast()
            self.condition.unlock()
            if !ended { self.receive() }
        }
    }

    func send(_ line: String) {
        connection.send(content: Data((line + "\n").utf8), completion: .contentProcessed { _ in })
    }

    func sendRecord(_ message: String, sealedBy channel: ChannelCrypto) {
        let record = try! channel.sealAsHost(Data(message.utf8))
        connection.send(content: record, completion: .contentProcessed { _ in })
    }

    func close() {
        connection.cancel()
    }

    /// Everything received and not yet read.
    var buffered: Data {
        condition.lock()
        defer { condition.unlock() }
        return received
    }

    func readLine(timeout: TimeInterval) -> String? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if let newline = received.firstIndex(of: 0x0A) {
                let line = received[received.startIndex..<newline]
                received.removeSubrange(received.startIndex...newline)
                return String(decoding: line, as: UTF8.self)
            }
            if closed || !condition.wait(until: deadline) { return nil }
        }
    }

    /// One length-prefixed record, still sealed. Nil for anything that is not
    /// one -- cleartext JSON reads as a length far past any record's.
    func readRecord(timeout: TimeInterval) -> Data? {
        let deadline = Date().addingTimeInterval(timeout)
        condition.lock()
        defer { condition.unlock() }
        while true {
            if received.count >= 4 {
                let length = received.prefix(4).reduce(0) { $0 << 8 | Int($1) }
                guard length > 0, length <= ChannelCrypto.maxMessage + 64 else { return nil }
                if received.count >= 4 + length {
                    let record = received.prefix(4 + length)
                    received.removeFirst(4 + length)
                    return Data(record)
                }
            }
            if closed || !condition.wait(until: deadline) { return nil }
        }
    }

    /// The greeting of a host that asks for no token.
    func greetWithoutAuth() {
        send(#"{"type":"hello","version":2,"host":"TEST-PC","needsAuth":false}"#)
        send(ScriptedHost.displays)
    }

    /// The greeting, auth v2 and the channel keys, as the agent does them, and
    /// the display list sealed under those keys. Nil, having closed nothing,
    /// when the Mac's first line is not a proof of `token`.
    @discardableResult
    func greetAndAuthenticate(token: String) -> (auth: [String: Any], channel: ChannelCrypto)? {
        let challenge = ScriptedHost.randomHex(32)
        send(#"{"type":"hello","version":2,"host":"TEST-PC","needsAuth":true,"#
             + #""challenge":"\#(challenge)","channelCrypto":2}"#)
        guard let auth = ScriptedHost.json(readLine(timeout: 5)),
              auth["cmd"] as? String == "auth",
              let nonce = auth["cnonce"] as? String,
              let clientPublic = Data(smtHex: auth["cpub"] as? String ?? ""),
              let proof = auth["proof"] as? String,
              let tokenBytes = Data(smtHex: token),
              let challengeBytes = Data(smtHex: challenge),
              let nonceBytes = Data(smtHex: nonce) else { return nil }
        var message = Data("SolStream agent auth v2".utf8)
        message += challengeBytes
        message += nonceBytes
        let expected = HMAC<SHA256>.authenticationCode(for: message,
                                                       using: SymmetricKey(data: tokenBytes))
        guard Data(expected).smtHex == proof,
              let peer = try? P256.KeyAgreement.PublicKey(x963Representation: clientPublic) else {
            return nil
        }
        let hostKey = P256.KeyAgreement.PrivateKey()
        guard let shared = try? hostKey.sharedSecretFromKeyAgreement(with: peer),
              let channel = ChannelCrypto(token: token, challenge: challenge, clientNonce: nonce,
                                          clientPublic: clientPublic,
                                          hostPublic: hostKey.publicKey.x963Representation,
                                          secret: shared.withUnsafeBytes { Data($0) }) else {
            return nil
        }
        send(#"{"type":"auth","ok":true,"channelCrypto":2,"#
             + #""hpub":"\#(hostKey.publicKey.x963Representation.smtHex)","#
             + #""hauth":"\#(channel.hostAuth)"}"#)
        sendRecord(ScriptedHost.displays, sealedBy: channel)
        return (auth, channel)
    }
}
