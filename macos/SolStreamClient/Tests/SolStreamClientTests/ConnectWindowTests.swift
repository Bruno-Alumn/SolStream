import AppKit
import XCTest
import DesignSystem
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
    private var directory: URL!
    /// The recent hosts, kept in this test's own folder: the standard
    /// defaults of a test run are shared by every test run on the Mac at
    /// the time, and a domain by name leaves a file behind in Preferences.
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-connect-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defaults = UserDefaults(suiteName: directory.appendingPathComponent("defaults").path)
        // Paired, so no setup steps: a Mac that knows how this works.
        TokenStore.directoryOverride = directory
        for host in ["192.168.1.20", "192.168.1.21", "100.101.102.103"] {
            TokenStore.set("00112233445566778899aabbccddeeff", for: host)
        }
    }

    override func tearDown() {
        defaults = nil
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
                                    reach: { world.reach($0) },
                                    defaults: defaults)
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

    /// The Tailscale line's link: the one beside the line's words, not the
    /// setup guide's, which comes first.
    private func tailscaleLink(in window: NSWindow) -> LinkButton? {
        var found: LinkButton?
        func walk(_ view: NSView) {
            if found == nil, let row = view as? NSStackView,
               row.views.contains(where: { ($0 as? NSTextField)?.stringValue.contains("Tailscale") == true }) {
                found = row.views.lazy.compactMap { $0 as? LinkButton }.first
            }
            view.subviews.forEach(walk)
        }
        window.contentView.map(walk)
        return found
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

    /// With only Tailscale's command line there is no app to open, so the
    /// line says what to run and offers no link.
    func testTheCommandLineAloneGetsWordsAndNoLink() throws {
        let world = World(tailscale: .commandLineButOff(daemonRunning: true), answering: [])
        let (connect, window) = try makeWindow(world)
        try pick("192.168.1.20", in: window)
        waitUntil { self.shown(in: window).contains("Not answering") }
        XCTAssertTrue(shown(in: window).contains("sudo tailscale up"))
        let link = try XCTUnwrap(tailscaleLink(in: window))
        XCTAssertTrue(link.isHiddenOrHasHiddenAncestor)

        // With the app, the same line has its link: this is the line's own.
        world.tailscale = .installedButOff
        connect.networkChanged()
        XCTAssertTrue(shown(in: window).contains("Turn it on"))
        XCTAssertFalse(link.isHiddenOrHasHiddenAncestor)
        XCTAssertEqual(link.words, "Open Tailscale")
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

    /// Tailscale going down with the window still key -- switched off from
    /// its menu-bar item, or dropped by itself -- changes the network, and a
    /// Tailscale address that answered through it is asked again.
    func testTailscaleGoingDownIsNoticedWithoutTheWindowComingForward() throws {
        let world = World(tailscale: .connected(address: "100.88.1.4"), answering: ["100.101.102.103"])
        let (connect, window) = try makeWindow(world)
        try pick("100.101.102.103", in: window)
        waitUntil { self.shown(in: window).contains("Reachable and paired") }
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))

        world.tailscale = .installedButOff
        world.answering = []
        let before = world.probes
        connect.networkChanged()
        XCTAssertFalse(shown(in: window).contains("Reachable"), "the old answer is not kept")
        waitUntil { world.probes > before && self.shown(in: window).contains("Not answering") }
        XCTAssertGreaterThan(world.probes, before)
        XCTAssertTrue(shown(in: window).contains("Tailscale is off on this Mac"))
    }

    /// Another tailnet, chosen from Tailscale's menu: Tailscale stays on
    /// throughout, with another address, and a PC that answered on the old
    /// tailnet is asked again.
    func testSwitchingTailnetsAsksATailscaleAddressAgain() throws {
        let world = World(tailscale: .connected(address: "100.88.1.4"), answering: ["100.101.102.103"])
        let (connect, window) = try makeWindow(world)
        try pick("100.101.102.103", in: window)
        waitUntil { self.shown(in: window).contains("Reachable and paired") }
        XCTAssertTrue(shown(in: window).contains("Reachable and paired"))

        world.tailscale = .connected(address: "100.77.5.6")
        world.answering = []
        let before = world.probes
        connect.networkChanged()
        XCTAssertFalse(shown(in: window).contains("Reachable"), "the old tailnet's answer is not kept")
        waitUntil { world.probes > before && self.shown(in: window).contains("Not answering") }
        XCTAssertGreaterThan(world.probes, before)
    }

    /// The host list open, with an address half typed into it, when
    /// Tailscale comes up: the address stays where it was.
    func testANetworkChangeLeavesAnAddressBeingTyped() throws {
        let world = World(tailscale: .installedButOff, answering: [])
        let (connect, _) = try makeWindow(world)
        let list = try XCTUnwrap(connect.openDropdownForTesting())
        let field = try XCTUnwrap(find(DS.Field.self, in: list.contentView))
        list.makeFirstResponder(field)
        field.currentEditor()?.insertText("100.101.")

        world.tailscale = .connected(address: "100.88.1.4")
        connect.networkChanged()
        let now = try XCTUnwrap(find(DS.Field.self, in: connect.openDropdownForTesting()?.contentView))
        XCTAssertEqual(now.stringValue, "100.101.")
        XCTAssertNotNil(now.currentEditor(), "still being typed into")
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

    /// Closed -- Connect pressed, say -- the window takes no more answers:
    /// one already on its way is dropped, and the address is not
    /// remembered by it.
    func testAClosedWindowTakesNoAnswer() throws {
        let world = World(tailscale: .connected(address: "100.88.1.4"), answering: ["100.101.102.103"])
        let (connect, window) = try makeWindow(world)
        world.delayNext("100.101.102.103", by: 0.4)
        try pick("100.101.102.103", in: window)
        waitUntil { world.probes > 0 }
        connect.close()
        RunLoop.main.run(until: Date().addingTimeInterval(0.8))
        XCTAssertFalse(shown(in: window).contains("Reachable"))
        XCTAssertNil(defaults.object(forKey: "SolStream.recentHosts"))
    }

    /// A search of the other paired addresses, still out when the window
    /// closes -- Connect pressed meanwhile -- takes no answer: the address
    /// last used stays the one remembered, and nothing more is sent.
    func testARouteSearchOutAtCloseTakesNoAnswer() throws {
        defaults.set("192.168.1.21", forKey: "SolStream.lastHost")
        defaults.set(["192.168.1.21", "100.101.102.103"], forKey: "SolStream.recentHosts")
        let world = World(tailscale: .connected(address: "100.88.1.4"), answering: ["100.101.102.103"])
        world.delayNext("100.101.102.103", by: 0.5)
        let (connect, window) = try makeWindow(world)
        connect.probeForTesting()
        // The remembered address fails, and the search for another is out.
        waitUntil { world.probes >= 2 }
        XCTAssertEqual(world.probes, 2)

        connect.close()
        RunLoop.main.run(until: Date().addingTimeInterval(1))
        XCTAssertEqual(defaults.string(forKey: "SolStream.lastHost"), "192.168.1.21")
        XCTAssertEqual(defaults.stringArray(forKey: "SolStream.recentHosts"),
                       ["192.168.1.21", "100.101.102.103"])
        XCTAssertFalse(shown(in: window).contains("Reachable"))
        XCTAssertEqual(world.probes, 2)
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
