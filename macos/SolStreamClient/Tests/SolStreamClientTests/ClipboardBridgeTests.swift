import AppKit
import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// When the clipboard bridge talks to the host, and what it does with the
/// answers. Against a stand-in host and a pasteboard of the test's own, never
/// the general one the person is using.
final class ClipboardBridgeTests: XCTestCase {

    /// Records what the bridge asks, and answers when the test says so.
    private final class FakeHost {
        var reads: [Int?] = []
        var writes: [String] = []
        private var pendingReads: [(AgentConnection.RemoteClipboard?) -> Void] = []
        private var pendingWrites: [(Int?) -> Void] = []

        var host: ClipboardBridge.Host {
            ClipboardBridge.Host(
                read: { [unowned self] since, completion in
                    self.reads.append(since)
                    self.pendingReads.append(completion)
                },
                write: { [unowned self] text, completion in
                    self.writes.append(text)
                    self.pendingWrites.append(completion)
                })
        }

        var isWaiting: Bool { !pendingReads.isEmpty || !pendingWrites.isEmpty }

        func answerRead(text: String = "", sequence: Int, unchanged: Bool = false,
                        isPrivate: Bool = false) {
            guard !pendingReads.isEmpty else { return XCTFail("no read to answer") }
            pendingReads.removeFirst()(AgentConnection.RemoteClipboard(
                text: text, sequence: sequence, isUnchanged: unchanged,
                wasTruncated: false, isPrivate: isPrivate))
        }

        func failRead() {
            guard !pendingReads.isEmpty else { return XCTFail("no read to fail") }
            pendingReads.removeFirst()(nil)
        }

        func answerWrite(sequence: Int?) {
            guard !pendingWrites.isEmpty else { return XCTFail("no write to answer") }
            pendingWrites.removeFirst()(sequence)
        }
    }

    private var fake: FakeHost!
    private var pasteboard: NSPasteboard!
    private var bridge: ClipboardBridge!
    /// Whether one of the stream's windows has the keyboard.
    private var streamHasKeyboard = false

    override func setUp() {
        super.setUp()
        fake = FakeHost()
        pasteboard = NSPasteboard(name: NSPasteboard.Name("SolStream.tests.\(UUID().uuidString)"))
        streamHasKeyboard = false
        bridge = ClipboardBridge(host: fake.host, pasteboard: pasteboard) { [unowned self] in
            self.streamHasKeyboard
        }
    }

    override func tearDown() {
        bridge.stop()
        bridge = nil
        pasteboard.releaseGlobally()
        pasteboard = nil
        fake = nil
        super.tearDown()
    }

    /// Run what the bridge queued on the main queue for an answer.
    private func settle() {
        let drained = expectation(description: "main queue drained")
        DispatchQueue.main.async { drained.fulfill() }
        wait(for: [drained], timeout: 2)
    }

    private func copyOnTheMac(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    // MARK: - Mac to PC

    /// The case that pasted the old clipboard: copied in another application,
    /// then ⌘Tab to the stream and ⌘V. The copy waits while the stream does not
    /// have the keyboard, and goes the moment it does — not a tick later.
    func testAHeldMacCopyGoesTheMomentTheStreamTakesTheKeyboard() {
        bridge.start(resuming: false)
        copyOnTheMac("copied in Safari")

        // Some other window of the Mac's taking the keyboard sends nothing.
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [], "a copy made elsewhere went before the stream had the keyboard")
        XCTAssertEqual(fake.reads, [], "the PC's clipboard was asked for over a copy still to send")

        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["copied in Safari"])
    }

    func testTheMacsLinesReachThePCAsWindowsLines() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("one\ntwo")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["one\r\ntwo"])
    }

    /// Measured against the host's budget as the Mac's lines, not Windows':
    /// those are a byte longer each, and a copy that fits would lose its tail.
    func testAMacCopyThatFitsTheBudgetIsSentWhole() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        // 256,000 bytes in the Mac's lines, 262,400 in Windows'.
        let text = String(repeating: String(repeating: "x", count: 39) + "\n", count: 6_400)
        XCTAssertLessThanOrEqual(text.utf8.count, AgentConnection.maxClipboardBytes)
        copyOnTheMac(text)
        bridge.syncNow()
        XCTAssertEqual(fake.writes.count, 1)
        XCTAssertGreaterThan(fake.writes.first?.utf8.count ?? 0, AgentConnection.maxClipboardBytes)
        XCTAssertEqual(fake.writes.first.map(ClipboardBridge.macLineEndings), text)
    }

    /// And one that does not fit is cut to the budget in the Mac's lines,
    /// then given Windows'.
    func testAMacCopyOverTheBudgetIsCutBeforeItGainsItsReturns() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        let text = String(repeating: String(repeating: "x", count: 39) + "\n", count: 8_000)
        copyOnTheMac(text)
        bridge.syncNow()
        let sent = fake.writes.first.map(ClipboardBridge.macLineEndings) ?? ""
        XCTAssertEqual(sent.utf8.count, AgentConnection.maxClipboardBytes)
        XCTAssertTrue(text.hasPrefix(sent))
    }

    /// A copy marked as a password's is never sent, keyboard or not.
    func testAPrivateMacCopyIsNeverSent() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("hunter2", forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [])
    }

    /// The host's sequence number after our own write is adopted, so the next
    /// question carries it and the write is not read back as the PC's copy.
    func testOurOwnWriteIsNotReadBack() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("sent")
        bridge.syncNow()
        fake.answerWrite(sequence: 41)
        settle()

        bridge.syncNow()
        XCTAssertEqual(fake.reads.last, 41)
        fake.answerRead(text: "sent", sequence: 42)
        settle()
        XCTAssertEqual(fake.writes, ["sent"], "the same text was sent twice")
    }

    // MARK: - PC to Mac

    /// The other half: ⌘C in the stream, ⌘Tab to Notes, ⌘V. Losing the
    /// keyboard asks the host at once, and its answer lands on the Mac with
    /// the Mac's line endings.
    func testGivingUpTheKeyboardBringsThePCsCopyOverAtOnce() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        bridge.syncNow()
        fake.answerRead(text: "", sequence: 1)
        settle()

        streamHasKeyboard = false
        bridge.syncNow()
        XCTAssertEqual(fake.reads.last, 1)
        fake.answerRead(text: "copied\r\non the PC", sequence: 2)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied\non the PC")
    }

    /// Marked private, the host's answer is passed over even with text in it:
    /// the flag is what says so, not the text being empty.
    func testAPrivateCopyOnThePCIsNotBroughtOver() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("what the Mac had")
        bridge.syncNow()
        fake.answerWrite(sequence: 6)
        settle()

        bridge.syncNow()
        fake.answerRead(text: "hunter2", sequence: 7, isPrivate: true)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "what the Mac had")
    }

    // MARK: - Pace

    /// A sync asked for while a question is on the wire is not dropped: it
    /// goes as soon as the answer is in, ahead of the next tick.
    func testASyncAskedForMidRequestGoesWhenTheAnswerIsIn() {
        bridge.start(resuming: false)
        bridge.syncNow()
        XCTAssertEqual(fake.reads.count, 1)

        copyOnTheMac("copied while asking")
        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [], "a second request went out over the first")

        fake.answerRead(sequence: 3, unchanged: true)
        settle()
        XCTAssertEqual(fake.writes, ["copied while asking"])
    }

    func testTheHostIsAskedBrisklyWhileTheStreamHasTheKeyboard() {
        bridge.start(resuming: false)
        XCTAssertEqual(bridge.pollInterval, ClipboardBridge.idleInterval)

        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(bridge.pollInterval, ClipboardBridge.briskInterval)
    }

    /// A host that could not answer is left alone for a while, but a change
    /// of keyboard still asks it straight away: a paste is about to depend on
    /// the answer.
    func testAChangeOfKeyboardAsksAgainEvenAfterAFailedRead() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        bridge.syncNow()
        fake.failRead()
        settle()
        let asked = fake.reads.count

        streamHasKeyboard = false
        bridge.syncNow()
        XCTAssertEqual(fake.reads.count, asked + 1)
    }

    func testAStoppedBridgeAsksNothing() {
        bridge.start(resuming: false)
        bridge.stop()
        streamHasKeyboard = true
        copyOnTheMac("after the stop")
        bridge.syncNow()
        XCTAssertEqual(fake.reads, [])
        XCTAssertEqual(fake.writes, [])
        XCTAssertNil(bridge.pollInterval)
    }
}
