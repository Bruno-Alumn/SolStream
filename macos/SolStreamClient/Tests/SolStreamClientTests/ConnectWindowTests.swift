import AppKit
import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// The connect window's Tailscale line and what it says after Tailscale goes
/// on or off.
///
/// Built off screen and never shown, so there is no discovery; whether
/// Tailscale is on and whether a host answers are both stood in for, so
/// nothing here touches the network. Hosts are picked through the host row,
/// the way a person picks one.
final class ConnectWindowTests: XCTestCase {
    private static let keys = ["SolStream.lastHost", "SolStream.recentHosts"]
    private var saved: [String: Any] = [:]
    private var directory: URL!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        saved = [:]
        for key in Self.keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
            UserDefaults.standard.removeObject(forKey: key)
        }
        // Paired, so no setup steps: a Mac that knows how this works.
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-connect-\(UUID().uuidString)", isDirectory: true)
        TokenStore.directoryOverride = directory
        for host in ["192.168.1.20", "192.168.1.21", "100.101.102.103"] {
            TokenStore.set("00112233445566778899aabbccddeeff", for: host)
        }
    }

    override func tearDown() {
        for key in Self.keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        TokenStore.directoryOverride = nil
        try? FileManager.default.removeItem(at: directory)
        super.tearDown()
    }

    // MARK: - Helpers

    /// Stand-ins for the two readings, changeable as a test goes on.
    private final class World: @unchecked Sendable {
        private let lock = NSLock()
        private var _tailscale: TailscaleStatus
        private var _answering: Set<String>
        private var _delays: [String: TimeInterval] = [:]
        private var _probes = 0

        init(tailscale: TailscaleStatus, answering: Set<String>) {
            _tailscale = tailscale
            _answering = answering
        }

        var tailscale: TailscaleStatus {
            get { lock.lock(); defer { lock.unlock() }; return _tailscale }
            set { lock.lock(); _tailscale = newValue; lock.unlock() }
        }

        var answering: Set<String> {
            get { lock.lock(); defer { lock.unlock() }; return _answering }
            set { lock.lock(); _answering = newValue; lock.unlock() }
        }

        /// How many probes have been sent. Counted off the main thread, where
        /// the probes run, and read on it.
        var probes: Int {
            lock.lock(); defer { lock.unlock() }; return _probes
        }

        /// The next probe of `host` takes this long, as a probe through a
        /// tunnel still waking does.
        func delayNext(_ host: String, by seconds: TimeInterval) {
            lock.lock(); _delays[host] = seconds; lock.unlock()
        }

        func reach(_ host: String) -> Bool {
            lock.lock()
            _probes += 1
            let answers = _answering.contains(host)
            let delay = _delays.removeValue(forKey: host)
            lock.unlock()
            if let delay { Thread.sleep(forTimeInterval: delay) }
            return answers
        }
    }

    private func makeWindow(_ world: World) throws -> (ConnectWindow, NSWindow) {
        let connect = ConnectWindow(onConnect: { _ in XCTFail("nothing here connects") },
                                    readTailscale: { world.tailscale },
                                    reach: { world.reach($0) })
        let window = try XCTUnwrap(NSApp.windows.first { $0.delegate === connect })
        addTeardownBlock { connect.close() }
        return (connect, window)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    /// Every label the window is showing, joined, to look for words in.
    private func shown(in window: NSWindow) -> String {
        var found: [String] = []
        func walk(_ view: NSView) {
            if let field = view as? NSTextField, !field.isHiddenOrHasHiddenAncestor {
                found.append(field.stringValue)
            }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return found.joined(separator: "\n")
    }

    private func pick(_ host: String, in window: NSWindow) throws {
        let row = try XCTUnwrap(find(HostDropdown.self, in: window.contentView))
        row.onPick?(host)
    }

    /// Let the probe come back: it runs off the main thread and answers on it.
    private func waitUntil(_ timeout: TimeInterval = 2, _ condition: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
        }
    }

    private func becomeKey(_ connect: ConnectWindow, _ window: NSWindow) {
        connect.windowDidBecomeKey(Notification(name: NSWindow.didBecomeKeyNotification, object: window))
    }

    // MARK: - The Tailscale line

    /// A paired Mac without Tailscale, at home: the line's words come up
    /// when the PC does not answer and go when it does, and the buttons under
    /// them stay where they were throughout.
    func testTheButtonsStayPutWhateverTheProbeSays() throws {
        let world = World(tailscale: .missing, answering: ["192.168.1.21"])
        let (_, window) = try makeWindow(world)
        let words = try XCTUnwrap(TailscaleStatus.missing.advice?.words)
        let opened = window.frame
        XCTAssertFalse(shown(in: window).contains(words), "nothing to say while checking")

        try pick("192.168.1.20", in: window)
        waitUntil { self.shown(in: window).contains("Not answering") }
        XCTAssertTrue(shown(in: window).contains(words), "not answering: maybe away from home")
        XCTAssertEqual(window.frame, opened)

        try pick("192.168.1.21", in: window)
        waitUntil { self.shown(in: window).contains("Reachable and paired") }
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))
        XCTAssertFalse(shown(in: window).contains(words), "answering: nothing to recommend")
        XCTAssertEqual(window.frame, opened)
    }

    /// On Tailscale there is nothing to recommend, so the line takes no room.
    func testOnTailscaleTheLineTakesNoRoom() throws {
        let (_, without) = try makeWindow(World(tailscale: .missing, answering: []))
        let (_, with) = try makeWindow(World(tailscale: .connected(address: "100.88.1.4"), answering: []))
        XCTAssertLessThan(with.frame.height, without.frame.height)
    }

    // MARK: - Tailscale going on or off

    func testTailscaleComingUpOrGoingDownAsksATailscaleAddressAgain() throws {
        let world = World(tailscale: .connected(address: "100.88.1.4"), answering: ["100.101.102.103"])
        let (connect, window) = try makeWindow(world)
        try pick("100.101.102.103", in: window)
        waitUntil { self.shown(in: window).contains("Reachable and paired") }
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))

        // Off, while the PC showed as answering: that answer came through a
        // tunnel that is gone, and a PC that answered is never asked again
        // by itself.
        world.tailscale = .installedButOff
        world.answering = []
        let before = world.probes
        becomeKey(connect, window)
        XCTAssertFalse(shown(in: window).contains("Reachable"), "the old answer is not kept")
        waitUntil { world.probes > before && self.shown(in: window).contains("Not answering") }
        XCTAssertGreaterThan(world.probes, before)
        XCTAssertTrue(shown(in: window).contains("Tailscale is off on this Mac"))

        // On again: the window says it is checking, not that the PC is not
        // answering and should be looked at.
        world.tailscale = .connected(address: "100.88.1.4")
        world.answering = ["100.101.102.103"]
        becomeKey(connect, window)
        XCTAssertFalse(shown(in: window).contains("Not answering"))
        XCTAssertTrue(shown(in: window).contains("Checking"))
        waitUntil { self.shown(in: window).contains("Reachable and paired") }
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))
    }

    /// A probe already under way when Tailscale came up answers for the
    /// tunnel as it was, after the fresh probe has answered for it as it is.
    /// The older answer is dropped.
    func testAnAnswerFromBeforeTailscaleCameUpIsDropped() throws {
        let world = World(tailscale: .installedButOff, answering: [])
        let (connect, window) = try makeWindow(world)
        world.delayNext("100.101.102.103", by: 0.6)
        try pick("100.101.102.103", in: window)
        // The slow probe is under way.
        waitUntil { world.probes > 0 }
        XCTAssertEqual(world.probes, 1)

        world.tailscale = .connected(address: "100.88.1.4")
        world.answering = ["100.101.102.103"]
        becomeKey(connect, window)
        waitUntil { self.shown(in: window).contains("Reachable and paired") }
        // Long enough for the slow probe to have come back.
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))
        XCTAssertFalse(shown(in: window).contains("Not answering"))
    }

    /// A probe sent after Tailscale came up answers for the tunnel as it is,
    /// however late the window's own reading of Tailscale is by the time the
    /// answer comes back. That answer is kept, not taken for one from before
    /// and asked for again.
    func testAnAnswerFromAfterTailscaleCameUpIsKept() throws {
        let world = World(tailscale: .installedButOff, answering: [])
        let (_, window) = try makeWindow(world)
        // Up since the window last looked, and the probe slow enough for
        // the window's reading to be due again when it answers.
        world.tailscale = .connected(address: "100.88.1.4")
        world.answering = ["100.101.102.103"]
        world.delayNext("100.101.102.103", by: 3.2)
        try pick("100.101.102.103", in: window)
        waitUntil(5) { self.shown(in: window).contains("Reachable and paired") }
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))
        XCTAssertEqual(world.probes, 1)
    }

    /// Tailscale changing under an address on the home network says nothing
    /// new about it once it has answered, so it is not asked again.
    func testAHomeAddressThatAnsweredIsNotAskedAgain() throws {
        let world = World(tailscale: .connected(address: "100.88.1.4"), answering: ["192.168.1.21"])
        let (connect, window) = try makeWindow(world)
        try pick("192.168.1.21", in: window)
        waitUntil { self.shown(in: window).contains("Reachable and paired") }
        let probes = world.probes

        world.tailscale = .installedButOff
        becomeKey(connect, window)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        XCTAssertEqual(world.probes, probes)
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))
    }
}
