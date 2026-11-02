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
        /// The formatting each write carried; empty for a plain one.
        var richWrites: [AgentConnection.RichText] = []
        var imageReads: [Int] = []
        var imageWrites: [Data] = []
        private var pendingReads: [(AgentConnection.RemoteClipboard?) -> Void] = []
        private var pendingWrites: [(Int?) -> Void] = []
        private var pendingImageReads: [(Data?) -> Void] = []
        private var pendingImageWrites: [(Int?) -> Void] = []

        var host: ClipboardBridge.Host {
            ClipboardBridge.Host(
                read: { [unowned self] since, completion in
                    self.reads.append(since)
                    self.pendingReads.append(completion)
                },
                write: { [unowned self] text, completion in
                    self.writes.append(text)
                    self.pendingWrites.append(completion)
                },
                readImage: { [unowned self] sequence, completion in
                    self.imageReads.append(sequence)
                    self.pendingImageReads.append(completion)
                },
                writeImage: { [unowned self] png, completion in
                    self.imageWrites.append(png)
                    self.pendingImageWrites.append(completion)
                },
                writeRich: { [unowned self] text, rich, completion in
                    self.writes.append(text)
                    self.richWrites.append(rich)
                    self.pendingWrites.append(completion)
                })
        }

        var isWaiting: Bool {
            !pendingReads.isEmpty || !pendingWrites.isEmpty
                || !pendingImageReads.isEmpty || !pendingImageWrites.isEmpty
        }

        func answerRead(text: String = "", sequence: Int, unchanged: Bool = false,
                        isPrivate: Bool = false, hasImage: Bool = false,
                        rich: AgentConnection.RichText = AgentConnection.RichText()) {
            guard !pendingReads.isEmpty else { return XCTFail("no read to answer") }
            pendingReads.removeFirst()(AgentConnection.RemoteClipboard(
                text: text, sequence: sequence, isUnchanged: unchanged,
                wasTruncated: false, isPrivate: isPrivate, hasImage: hasImage, rich: rich))
        }

        func answerImageRead(_ png: Data?) {
            guard !pendingImageReads.isEmpty else { return XCTFail("no picture read to answer") }
            pendingImageReads.removeFirst()(png)
        }

        func answerImageWrite(sequence: Int?) {
            guard !pendingImageWrites.isEmpty else { return XCTFail("no picture write to answer") }
            pendingImageWrites.removeFirst()(sequence)
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
        // A copy that need not settle: the tests about settling build their own.
        bridge = makeBridge(settleTime: 0)
    }

    private func makeBridge(settleTime: TimeInterval) -> ClipboardBridge {
        ClipboardBridge(host: fake.host, pasteboard: pasteboard, settleTime: settleTime) {
            [unowned self] in self.streamHasKeyboard
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

    /// Let time pass with the main run loop turning, so the bridge's timers
    /// fire.
    private func letTimePass(_ seconds: TimeInterval) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func copyOnTheMac(_ text: String) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// An image, which has no text on the pasteboard at all.
    private func copyAnImageOnTheMac() {
        pasteboard.clearContents()
        pasteboard.setData(Data([0x89, 0x50, 0x4E, 0x47]), forType: .png)
    }

    /// Copied the way a password manager copies: marked concealed.
    private func copyAPasswordOnTheMac(_ text: String) {
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString(text, forType: .string)
        item.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        pasteboard.writeObjects([item])
    }

    // MARK: - Formatting

    /// Copied formatted, as Safari or Notes copy: text, HTML and RTF.
    private func copyFormattedOnTheMac(_ text: String, html: String?, rtf: String?) {
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        if let html { pasteboard.setString(html, forType: .html) }
        if let rtf { pasteboard.setData(Data(rtf.utf8), forType: .rtf) }
    }

    func testAFormattedMacCopyTakesItsFormattingToThePC() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyFormattedOnTheMac("bold", html: "<b>bold</b>", rtf: "{\\rtf1 {\\b bold}}")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["bold"])
        XCTAssertEqual(fake.richWrites,
                       [AgentConnection.RichText(html: "<b>bold</b>", rtf: "{\\rtf1 {\\b bold}}")])
    }

    /// Plain text stays plain: no formatting to send, so the plain write.
    func testAPlainMacCopySendsNoFormatting() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("plain")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["plain"])
        XCTAssertEqual(fake.richWrites, [])
    }

    /// Formatting too big for the channel stays behind; the text still goes.
    func testFormattingOverTheBudgetIsLeftBehind() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        let huge = "<p>" + String(repeating: "x", count: AgentConnection.maxRichClipboardBytes) + "</p>"
        copyFormattedOnTheMac("x", html: huge, rtf: "{\\rtf1 x}")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["x"])
        XCTAssertEqual(fake.richWrites, [AgentConnection.RichText(html: nil, rtf: "{\\rtf1 x}")])
    }

    /// The PC's formatted copy arrives with its HTML and RTF beside the text.
    func testAFormattedPCCopyArrivesFormatted() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        bridge.syncNow()
        fake.answerRead(text: "", sequence: 1)
        settle()
        streamHasKeyboard = false
        bridge.syncNow()
        fake.answerRead(text: "table", sequence: 2,
                        rich: AgentConnection.RichText(html: "<table><tr><td>table</td></tr></table>",
                                                       rtf: "{\\rtf1 table}"))
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "table")
        XCTAssertEqual(pasteboard.string(forType: .html),
                       "<meta charset=\"utf-8\"><table><tr><td>table</td></tr></table>")
        XCTAssertEqual(pasteboard.data(forType: .rtf).flatMap { String(data: $0, encoding: .ascii) },
                       "{\\rtf1 table}")
    }

    /// HTML from the PC is UTF-8 and says nothing about it; AppKit reads it as
    /// Latin-1 unless told. Checked by reading it back as AppKit does.
    func testPCHtmlKeepsItsAccents() throws {
        ClipboardBridge.put(AgentConnection.RichText(html: "<b>café — “q”</b>"), on: pasteboard)
        let html = try XCTUnwrap(pasteboard.data(forType: .html))
        let read = try NSAttributedString(data: html, options: [.documentType: NSAttributedString.DocumentType.html],
                                          documentAttributes: nil)
        XCTAssertEqual(read.string.trimmingCharacters(in: .whitespacesAndNewlines), "café — “q”")
        // One that declares its own is left as it is.
        let declared = "<meta charset='windows-1252'><p>x</p>"
        XCTAssertEqual(ClipboardBridge.declaringUTF8(declared), declared)
    }

    /// RTF travels as the ASCII it is written in; anything else is left out.
    func testOnlyAsciiRTFTravels() {
        let rich = AgentConnection.RichText(html: "<p>café</p>", rtf: "{\\rtf1 café}").travelling()
        XCTAssertEqual(rich.html, "<p>café</p>")
        XCTAssertNil(rich.rtf)
        XCTAssertTrue(AgentConnection.RichText(html: "", rtf: nil).travelling().isEmpty)
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
        copyAPasswordOnTheMac("hunter2")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [])
    }

    // MARK: - A copy settling

    /// Not sent the moment it is first seen, but once it has kept its change
    /// count for the settle time — and then at once, not at the next tick.
    func testAMacCopyGoesOnceItHasSettled() {
        bridge = makeBridge(settleTime: 0.05)
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("settled")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [], "sent the moment it was seen")
        letTimePass(0.15)
        XCTAssertEqual(fake.writes, ["settled"])
    }

    /// A password manager writes the text, then the marker, and the change
    /// count moves only at the first. Seen in between, a password looked like
    /// any other copy and went to the PC.
    func testAPasswordMarkedAMomentAfterItsTextIsNeverSent() {
        bridge = makeBridge(settleTime: 0.05)
        bridge.start(resuming: false)
        streamHasKeyboard = true
        pasteboard.clearContents()
        pasteboard.setString("hunter2", forType: .string)
        let changeCount = pasteboard.changeCount
        bridge.syncNow()

        pasteboard.setData(Data(), forType: NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"))
        XCTAssertEqual(pasteboard.changeCount, changeCount, "the marker moved the change count")
        letTimePass(0.15)
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [])
    }

    /// A copy seen before the stream had the keyboard has settled by the time
    /// it does, and goes the moment the stream takes it.
    func testASettledCopyGoesTheMomentTheStreamTakesTheKeyboard() {
        bridge = makeBridge(settleTime: 0.05)
        bridge.start(resuming: false)
        copyOnTheMac("copied in Safari")
        bridge.syncNow()
        letTimePass(0.1)
        XCTAssertEqual(fake.writes, [])

        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["copied in Safari"])
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

    /// A copy made on the Mac while the PC's answer was on its way is the
    /// newer of the two, and the answer does not overwrite it.
    func testAnAnswerDoesNotOverwriteAMacCopyMadeWhileItWasOnItsWay() {
        bridge.start(resuming: false)
        bridge.syncNow()
        copyOnTheMac("copied in Safari")
        fake.answerRead(text: "copied on the PC before", sequence: 5)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied in Safari")

        // And it goes to the PC in its turn.
        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["copied in Safari"])
    }

    /// The same when the Mac's newer copy is the text that crossed last: the
    /// PC holds something else now, so the copy still goes.
    func testAMacCopyThatBeatsAnAnswerGoesEvenWhenItCrossedBefore() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("x")
        bridge.syncNow()
        fake.answerWrite(sequence: 10)
        settle()

        bridge.syncNow()
        copyOnTheMac("x")
        fake.answerRead(text: "y", sequence: 11)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "x")

        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["x", "x"])
    }

    // MARK: - The same text again

    /// What both clipboards held is forgotten once the PC holds a password:
    /// the same text copied again on the Mac goes, or ⌘V in the stream would
    /// paste the password.
    func testTheSameTextCopiedAgainGoesAfterAPasswordOnThePC() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        fake.answerWrite(sequence: 10)
        settle()

        bridge.syncNow()
        fake.answerRead(sequence: 11, isPrivate: true)
        settle()

        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["ssh deploy@example", "ssh deploy@example"])
    }

    /// The same for an image copied on the PC, which arrives as no text.
    func testTheSameTextCopiedAgainGoesAfterAnImageOnThePC() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        fake.answerWrite(sequence: 10)
        settle()

        bridge.syncNow()
        fake.answerRead(text: "", sequence: 11)
        settle()

        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["ssh deploy@example", "ssh deploy@example"])
    }

    /// The other way round: a password copied on the Mac, then the PC copies
    /// what it had sent before. That is the newer copy, and ⌘V on the Mac
    /// gets it rather than the password.
    func testThePCsCopyReplacesAMacPasswordEvenWhenItCrossedBefore() {
        bridge.start(resuming: false)
        bridge.syncNow()
        fake.answerRead(text: "make deploy", sequence: 2)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "make deploy")

        copyAPasswordOnTheMac("hunter2")
        bridge.syncNow()
        bridge.syncNow()
        XCTAssertEqual(fake.reads.last, 2)
        fake.answerRead(text: "make deploy", sequence: 3)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "make deploy")
    }

    /// The same once the Mac holds an image: the PC copying the text that
    /// crossed last brings it back, or ⌘V on the Mac would paste the image.
    func testThePCsCopyReplacesAnImageOnTheMacEvenWhenItCrossedBefore() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("make deploy")
        bridge.syncNow()
        fake.answerWrite(sequence: 10)
        settle()

        copyAnImageOnTheMac()
        bridge.syncNow()
        XCTAssertEqual(fake.imageWrites.count, 1, "the picture goes to the PC as a picture")
        fake.answerImageWrite(sequence: 11)
        settle()

        bridge.syncNow()
        fake.answerRead(text: "make deploy", sequence: 12)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "make deploy")
        XCTAssertEqual(fake.writes, ["make deploy"], "the image was sent as text")
    }

    // MARK: - Pictures

    /// A real PNG, small: what the Mac's own screenshots are.
    private func png(_ side: Int = 4) -> Data {
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: side, pixelsHigh: side,
                                   bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                   isPlanar: false, colorSpaceName: .deviceRGB,
                                   bytesPerRow: 0, bitsPerPixel: 0)!
        return rep.representation(using: .png, properties: [:])!
    }

    func testAMacPictureGoesToThePCOnceAsPNG() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        let picture = png()
        pasteboard.clearContents()
        pasteboard.setData(picture, forType: .png)
        bridge.syncNow()
        XCTAssertEqual(fake.imageWrites, [picture])
        fake.answerImageWrite(sequence: 3)
        settle()

        // Copied again unchanged: the same picture, which the PC holds.
        pasteboard.clearContents()
        pasteboard.setData(picture, forType: .png)
        bridge.syncNow()
        XCTAssertEqual(fake.imageWrites.count, 1, "the same picture went twice")
        fake.answerRead(sequence: 3, unchanged: true)
        settle()
    }

    /// A screenshot copied by an application that offers only TIFF.
    func testATiffOnlyPictureIsSentAsPNG() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        let tiff = NSImage(data: png())!.tiffRepresentation!
        pasteboard.clearContents()
        pasteboard.setData(tiff, forType: .tiff)
        bridge.syncNow()
        XCTAssertEqual(fake.imageWrites.count, 1)
        XCTAssertEqual(fake.imageWrites.first?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
    }

    /// Finder puts a copied file's icon beside it; the icon is not the copy.
    func testACopyOfFilesSendsNoPicture() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("file:///Users/someone/report.pdf", forType: .fileURL)
        item.setData(NSImage(data: png())!.tiffRepresentation!, forType: .tiff)
        pasteboard.writeObjects([item])
        bridge.syncNow()
        XCTAssertEqual(fake.imageWrites, [])
    }

    /// Finder puts the files' names on the clipboard as text too; that text
    /// is not the copy either.
    func testACopyOfFilesSendsNoText() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        pasteboard.clearContents()
        let item = NSPasteboardItem()
        item.setString("file:///Users/someone/report.pdf", forType: .fileURL)
        item.setString("report.pdf", forType: .string)
        pasteboard.writeObjects([item])
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [])
    }

    /// Copy a link, then open the stream or Switch App: a new bridge is built,
    /// and it used to take the link as its baseline and bring the PC's
    /// clipboard over it.
    func testAMacCopyMadeBetweenBridgesGoesToThePCInsteadOfBeingOverwritten() {
        bridge.start(resuming: false)
        bridge.stop()
        copyOnTheMac("https://example.com/link")

        bridge = makeBridge(settleTime: 0)
        bridge.start(resuming: false)
        bridge.syncNow()
        XCTAssertEqual(fake.reads, [], "the PC's clipboard was asked for over a copy still to send")

        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["https://example.com/link"])
        fake.answerWrite(sequence: 4)
        settle()

        // Asked from the write's own sequence, so what the PC had before is
        // never brought over the link.
        bridge.syncNow()
        XCTAssertEqual(fake.reads.last, 4)
        fake.answerRead(sequence: 4, unchanged: true)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "https://example.com/link")

        // And a copy made on the PC after that comes over as usual.
        bridge.syncNow()
        fake.answerRead(text: "copied on the PC later", sequence: 5)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied on the PC later")
    }

    /// Copies made while sync was off never cross, even when sync is back on
    /// by the time the next stream opens.
    func testAMacCopyMadeWhileSyncWasOffIsNotSentByTheNextBridge() {
        bridge.forgetHandledCopies()   // built with sync off
        copyOnTheMac("copied while sync was off")

        bridge = makeBridge(settleTime: 0)
        bridge.start(resuming: false)
        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [])
    }

    /// With nothing copied on the Mac since, a new bridge brings the PC's
    /// clipboard over as a first one does.
    func testANewBridgeWithNoMacCopySinceBringsThePCsClipboard() {
        bridge.start(resuming: false)
        bridge.stop()

        bridge = makeBridge(settleTime: 0)
        bridge.start(resuming: false)
        bridge.syncNow()
        fake.answerRead(text: "copied on the PC", sequence: 9)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "copied on the PC")
    }

    func testAPCPictureComesToTheMac() {
        bridge.start(resuming: false)
        bridge.syncNow()
        fake.answerRead(sequence: 7, hasImage: true)
        settle()
        XCTAssertEqual(fake.imageReads, [7])
        let picture = png()
        fake.answerImageRead(picture)
        settle()
        XCTAssertEqual(pasteboard.data(forType: .png), picture)
        XCTAssertNotNil(pasteboard.data(forType: .tiff), "for what reads only TIFF")

        // Not sent back: it is the PC's own.
        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.imageWrites, [])
    }

    /// Copied on the Mac while the PC's picture was on its way: the Mac's
    /// copy is newer, and stays.
    func testAMacCopyMadeWhileAPCPictureWasFetchedIsKept() {
        bridge.start(resuming: false)
        bridge.syncNow()
        fake.answerRead(sequence: 7, hasImage: true)
        settle()
        copyOnTheMac("newer")
        fake.answerImageRead(png())
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "newer")
        XCTAssertNil(pasteboard.data(forType: .png))
    }

    /// Files dropped on a window are on the PC's clipboard; a Mac copy made
    /// before the drop, still held, must not go over them when the window
    /// takes the keyboard.
    func testFilesPutOnThePCAreNotReplacedByAHeldMacCopy() {
        bridge.start(resuming: false)
        copyOnTheMac("https://example.com")
        bridge.adopt(remoteSequence: 40)
        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.writes, [], "the held copy went over the files")
        XCTAssertEqual(fake.reads, [40])
    }

    /// A picture that failed to come is asked for once more, and not again.
    func testAPCPictureThatFailedIsAskedForOnceMore() {
        bridge.start(resuming: false)
        bridge.syncNow()
        fake.answerRead(sequence: 7, hasImage: true)
        settle()
        fake.answerImageRead(nil)
        settle()
        bridge.syncNow()
        XCTAssertEqual(fake.reads.last ?? -1, nil, "asked as new, so the picture is named again")
        fake.answerRead(sequence: 7, hasImage: true)
        settle()
        fake.answerImageRead(nil)
        settle()
        bridge.syncNow()
        XCTAssertEqual(fake.reads.last, 7, "a picture the host cannot send is not asked for again")
    }

    /// The same picture copied again after something that did not cross is a
    /// copy worth sending: the PC no longer holds it.
    func testTheSamePictureAfterAPrivateCopyOnThePCGoesAgain() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        let picture = png()
        pasteboard.clearContents()
        pasteboard.setData(picture, forType: .png)
        bridge.syncNow()
        fake.answerImageWrite(sequence: 3)
        settle()
        bridge.syncNow()
        fake.answerRead(sequence: 4, isPrivate: true)
        settle()
        pasteboard.clearContents()
        pasteboard.setData(picture, forType: .png)
        bridge.syncNow()
        XCTAssertEqual(fake.imageWrites.count, 2)
    }

    /// A picture the host could not send leaves the Mac's clipboard alone.
    func testAPCPictureThatDoesNotComeChangesNothing() {
        copyOnTheMac("kept")
        bridge.start(resuming: true)
        bridge.syncNow()
        fake.answerRead(sequence: 1)
        settle()
        bridge.syncNow()
        fake.answerRead(sequence: 2, hasImage: true)
        settle()
        fake.answerImageRead(nil)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "kept")
    }

    /// And once the Mac's clipboard has been emptied, here after a copy that
    /// came from the PC.
    func testThePCsCopyReplacesAnEmptiedMacClipboardEvenWhenItCrossedBefore() {
        bridge.start(resuming: false)
        bridge.syncNow()
        fake.answerRead(text: "make deploy", sequence: 2)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "make deploy")

        pasteboard.clearContents()
        pasteboard.setString("", forType: .string)
        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.reads.last, 2)
        fake.answerRead(text: "make deploy", sequence: 3)
        settle()
        XCTAssertEqual(pasteboard.string(forType: .string), "make deploy")
        XCTAssertEqual(fake.writes, [], "the empty clipboard was sent")
    }

    /// A copy the host did not take — another program held the PC's
    /// clipboard open — is not on the PC, so copying it again sends it again.
    func testTheSameTextCopiedAgainGoesAfterTheHostDidNotTakeIt() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        fake.answerWrite(sequence: nil)
        settle()

        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["ssh deploy@example", "ssh deploy@example"])
    }

    /// Turned on mid-stream, sync starts from nothing having crossed: either
    /// side may have copied anything while it was off.
    func testTurningSyncBackOnForgetsWhatCrossedBefore() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        fake.answerWrite(sequence: 10)
        settle()
        bridge.stop()

        bridge.start(resuming: true)
        bridge.syncNow()
        fake.answerRead(text: "copied on the PC while sync was off", sequence: 14)
        settle()

        copyOnTheMac("ssh deploy@example")
        bridge.syncNow()
        XCTAssertEqual(fake.writes, ["ssh deploy@example", "ssh deploy@example"])
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

    /// Nor is a change of keyboard that came while a read was on the wire
    /// held back when that read fails: it asks again the moment it can.
    func testAChangeOfKeyboardQueuedBehindAFailedReadStillAsks() {
        bridge.start(resuming: false)
        streamHasKeyboard = true
        bridge.syncNow()
        XCTAssertEqual(fake.reads.count, 1)

        streamHasKeyboard = false
        bridge.syncNow()
        fake.failRead()
        settle()
        XCTAssertEqual(fake.reads.count, 2)
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
