import Network
import XCTest
@testable import AgentChannel

/// How the agent channel reads a line it was not expecting to be able to read:
/// text in the PC's code page from an older host, and a push that will not
/// parse at all. Either used to end the session.
final class AgentLineTests: XCTestCase {

    /// A line as an older host wrote it: each character sent as one byte, which
    /// for these Latin letters is what code page 1252 has them as.
    private func codePage(_ text: String) -> Data {
        Data(text.unicodeScalars.map { UInt8($0.value) })
    }

    private func message(_ reading: AgentConnection.LineReading,
                         file: StaticString = #filePath, line: UInt = #line)
        -> (message: [String: Any], repaired: Bool)? {
        guard case .message(let message, let repaired) = reading else {
            XCTFail("expected a message, got \(reading)", file: file, line: line)
            return nil
        }
        return (message, repaired)
    }

    private func isUnreadable(_ reading: AgentConnection.LineReading) -> Bool {
        if case .unreadable = reading { return true }
        return false
    }

    // MARK: - Text that is not UTF-8

    func testACoveringWindowsCodePageTitleIsReadWithReplacements() {
        let line = codePage(#"{"type":"occluded","id":7,"by":"Sécurité Windows"}"#)
        XCTAssertNil(try? JSONSerialization.jsonObject(with: line),
                     "the line has to be one a strict parse refuses, or this tests nothing")
        guard let read = message(AgentConnection.read(line: line)) else { return }
        XCTAssertTrue(read.repaired)
        XCTAssertEqual(read.message["type"] as? String, "occluded")
        XCTAssertEqual((read.message["id"] as? NSNumber)?.uint64Value, 7)
        XCTAssertEqual(read.message["by"] as? String, "S\u{FFFD}curit\u{FFFD} Windows")
    }

    func testAnOlderHostsGreetingWithAnAccentedNameStillConnects() {
        let line = codePage(#"{"type":"hello","version":2,"host":"JÜRGEN-PC","needsAuth":true,"#
                            + #""challenge":"00ff","channelCrypto":2}"#)
        guard let read = message(AgentConnection.read(line: line)) else { return }
        XCTAssertTrue(read.repaired)
        XCTAssertEqual(read.message["host"] as? String, "J\u{FFFD}RGEN-PC")
        XCTAssertEqual(read.message["challenge"] as? String, "00ff",
                       "the handshake's own fields come through untouched")
        XCTAssertEqual(read.message["needsAuth"] as? Bool, true)
    }

    func testUTF8IsReadAsItIs() {
        let line = Data(#"{"type":"occluded","id":7,"by":"Sécurité Windows — セキュリティ"}"#.utf8)
        guard let read = message(AgentConnection.read(line: line)) else { return }
        XCTAssertFalse(read.repaired)
        XCTAssertEqual(read.message["by"] as? String, "Sécurité Windows — セキュリティ")
    }

    // MARK: - Lines that will not parse

    func testAPushThatWillNotParseIsPassedOver() {
        let broken = [
            (#"{"type":"occluded","id":7,"by":}"#, "occluded"),
            (#"{"type":"cursor","shape":"#, "cursor"),
            (#"{"type":"closed","id":}"#, "closed"),
            (#"{"type":"windowsChanged""#, "windowsChanged"),
            (#"{"type":"occluded","id":7,"by":"{\"type\":\"windows\"}","#, "occluded"),
        ]
        for (text, type) in broken {
            guard case .unreadablePush(let named) = AgentConnection.read(line: Data(text.utf8)) else {
                XCTFail("\(text) should have been passed over")
                continue
            }
            XCTAssertEqual(named, type)
        }
    }

    /// A reply cannot be skipped: the replies are matched to requests by order
    /// alone, so one missing hands every later answer to the wrong caller.
    func testAnythingElseThatWillNotParseStillCostsTheConnection() {
        for text in [
            #"{"type":"windows","windows":["#,
            #"{"type":"displays","displays":[{"name":}]}"#,
            #"{"type":"hello","version":"#,
            #"{"type":"auth","ok":tru}"#,
            #"{"type":"busy","message":}"#,
            #"{"type":"occludedSoon","by":}"#,
            #"{"type":"occl"#,
            #"{ "type": "occluded", "by": }"#,
            "[1, 2]",
            "not JSON at all",
        ] {
            XCTAssertTrue(isUnreadable(AgentConnection.read(line: Data(text.utf8))),
                          "\(text) should not have been skipped")
        }
    }

    /// A host whose send fails partway keeps the socket, so the next line it
    /// writes runs on from the half it cut off. Skipping that push would skip
    /// the reply behind it as well.
    func testAPushCutShortWithAReplyBehindItStillCostsTheConnection() {
        for line in [
            codePage(#"{"type":"occluded","id":7,"by":"Sé"#)
                + Data(#"{"type":"windows","windows":[]}"#.utf8),
            Data(#"{"type":"occluded","id":7,"by":}{"type":"pong"}"#.utf8),
            Data(#"{"type":"cursor","shape":{"type":"apps","apps":[]}"#.utf8),
            Data(#"{"type":"closed","id":{"type":"clipboard","ok":true,"seq":3}"#.utf8),
            Data(#"{"type":"windowsChanged"{"type":"pong"}"#.utf8),
        ] {
            XCTAssertTrue(isUnreadable(AgentConnection.read(line: line)),
                          "\(String(decoding: line, as: UTF8.self)) should not have been skipped")
        }
    }

    func testTheTypeIsReadFromTheLinesFirstBytes() {
        XCTAssertEqual(AgentConnection.leadingType(of: Data(#"{"type":"cursor","shape":"#.utf8)),
                       "cursor")
        XCTAssertEqual(AgentConnection.leadingType(of: Data(#"{"type":""}"#.utf8)), "")
        XCTAssertNil(AgentConnection.leadingType(of: Data(#"{"type":"cursor"#.utf8)))
        XCTAssertNil(AgentConnection.leadingType(of: Data(#"{"id":1,"type":"cursor"}"#.utf8)))
        XCTAssertNil(AgentConnection.leadingType(of: Data()))
    }

    // MARK: - Over a socket

    /// The whole path, against a stand-in for an older host on this Mac's own
    /// loopback: a greeting naming JÜRGEN-PC in code page 1252, a push that will
    /// not parse, and a covering window's title in the code page. The session
    /// has to survive all three and still match the next reply to its request.
    func testASessionSurvivesAnOlderHostsCodePageTextAndABrokenPush() throws {
        let tokens = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-lines-\(UUID().uuidString)", isDirectory: true)
        TokenStore.directoryOverride = tokens
        defer {
            TokenStore.directoryOverride = nil
            try? FileManager.default.removeItem(at: tokens)
        }

        var greeting = Data()
        for text in [
            #"{"type":"hello","version":2,"host":"JÜRGEN-PC","needsAuth":false,"challenge":"00"}"#,
            #"{"type":"displays","displays":[{"name":"\\\\.\\DISPLAY1","adapter":"x","x":0,"#
                + #""y":0,"w":1920,"h":1080,"primary":true,"captured":true}]}"#,
            #"{"type":"occluded","id":7,"by":}"#,
            #"{"type":"occluded","id":7,"by":"Sécurité Windows"}"#,
        ] {
            greeting.append(codePage(text))
            greeting.append(0x0A)
        }
        let host = FakeHost(greeting: greeting, replies: [
            "windows": #"{"type":"windows","windows":[{"id":1,"pid":2,"title":"Paramètres","#
                + #""class":"C","x":0,"y":0,"w":10,"h":10}]}"#,
            "ping": #"{"type":"pong"}"#,
        ])
        let port = try host.start()
        defer { host.stop() }

        let agent = AgentConnection(host: "::1", port: port)
        defer { agent.disconnect() }
        var dropped = false
        let connected = expectation(description: "greeted")
        connected.assertForOverFulfill = false
        agent.onState = { state in
            switch state {
            case .connected(host: let name):
                XCTAssertEqual(name, "J\u{FFFD}RGEN-PC")
                connected.fulfill()
            case .disconnected:
                dropped = true
            default:
                break
            }
        }
        let occluded = expectation(description: "the readable push arrived")
        agent.onOccluded = { id, by in
            XCTAssertEqual(id, 7)
            XCTAssertEqual(by, "S\u{FFFD}curit\u{FFFD} Windows")
            occluded.fulfill()
        }
        agent.connect()
        wait(for: [connected, occluded], timeout: 5)

        let answered = expectation(description: "the next reply reached its request")
        agent.windows { windows in
            XCTAssertEqual(windows.map(\.title), ["Paramètres"])
            answered.fulfill()
        }
        wait(for: [answered], timeout: 5)
        XCTAssertFalse(dropped, "the connection should have survived every line")
    }
}

/// Just enough of a host to greet one Mac and answer its requests, listening
/// on IPv6 loopback only.
private final class FakeHost {
    private let greeting: Data
    private let replies: [String: String]
    private let queue = DispatchQueue(label: "FakeHost")
    private var listener: NWListener?
    private var connections: [NWConnection] = []

    init(greeting: Data, replies: [String: String]) {
        self.greeting = greeting
        self.replies = replies
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
            self?.serve(connection)
        }
        listener.start(queue: queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = listener.port?.rawValue else {
            throw NWError.posix(.EADDRNOTAVAIL)
        }
        return port
    }

    func stop() {
        queue.sync {
            connections.forEach { $0.cancel() }
            connections.removeAll()
            listener?.cancel()
            listener = nil
        }
    }

    private func serve(_ connection: NWConnection) {
        connections.append(connection)
        connection.start(queue: queue)
        connection.send(content: greeting, completion: .contentProcessed { _ in })
        read(connection, buffered: Data())
    }

    private func read(_ connection: NWConnection, buffered: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) {
            [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffered
            if let data { buffer.append(data) }
            while let newline = buffer.firstIndex(of: 0x0A) {
                let line = buffer[buffer.startIndex..<newline]
                buffer.removeSubrange(buffer.startIndex...newline)
                let request = (try? JSONSerialization.jsonObject(with: Data(line))) as? [String: Any]
                if let command = request?["cmd"] as? String, let reply = self.replies[command] {
                    connection.send(content: Data((reply + "\n").utf8),
                                    completion: .contentProcessed { _ in })
                }
            }
            if isComplete || error != nil { return }
            self.read(connection, buffered: buffer)
        }
    }
}
