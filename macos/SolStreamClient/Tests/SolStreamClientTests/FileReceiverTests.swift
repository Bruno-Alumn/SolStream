import XCTest
import AgentChannel
@testable import SolStreamClient

/// What a file sent from the PC is saved as.
final class FileReceiverTests: XCTestCase {

    /// Only its last component, with nothing that is a path or hides it.
    func testANameFromThePCIsJustAName() {
        XCTAssertEqual(FileReceiver.safeName("report.pdf"), "report.pdf")
        XCTAssertEqual(FileReceiver.safeName("C:\\Users\\me\\report.pdf"), "report.pdf")
        XCTAssertEqual(FileReceiver.safeName("../../.ssh/authorized_keys"), "authorized_keys")
        XCTAssertEqual(FileReceiver.safeName(".hidden"), "hidden")
        XCTAssertEqual(FileReceiver.safeName("a:b.txt"), "a_b.txt")
        XCTAssertEqual(FileReceiver.safeName("evil\u{202E}gpj.exe"), "evil_gpj.exe")
        XCTAssertEqual(FileReceiver.safeName(""), "File from PC")
        XCTAssertEqual(FileReceiver.safeName("..."), "File from PC")
        XCTAssertLessThanOrEqual(FileReceiver.units(FileReceiver.safeName(String(repeating: "x", count: 400) + ".txt")), FileReceiver.maxNameUnits)
    }

    /// A name already taken gets a number; nothing is overwritten.
    func testATakenNameGetsANumber() {
        let folder = URL(fileURLWithPath: "/tmp/x")
        let taken: Set<String> = ["/tmp/x/a.txt", "/tmp/x/a 2.txt"]
        XCTAssertEqual(FileReceiver.uniqueURL(for: "a.txt", in: folder) { taken.contains($0.path) }.path,
                       "/tmp/x/a 3.txt")
        XCTAssertEqual(FileReceiver.uniqueURL(for: "b.txt", in: folder) { taken.contains($0.path) }.path,
                       "/tmp/x/b.txt")
        XCTAssertEqual(FileReceiver.uniqueURL(for: "noext", in: folder) { $0.lastPathComponent == "noext" }
                        .lastPathComponent, "noext 2")
    }

    /// A gigabyte is left over after any file.
    func testRoomLeavesAGigabyte() {
        XCTAssertTrue(FileReceiver.hasRoom(for: 100, free: (1 << 30) + 100))
        XCTAssertFalse(FileReceiver.hasRoom(for: 101, free: (1 << 30) + 100))
    }

    /// A file from the PC is quarantined, as a browser download is, so
    /// Gatekeeper checks a script or an app before it runs.
    func testAFileFromThePCIsMarkedAsDownloaded() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-quarantine-\(UUID().uuidString).command")
        try Data("echo hi".utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        FileReceiver.markDownloaded(url)
        let values = try url.resourceValues(forKeys: [.quarantinePropertiesKey])
        let properties = try XCTUnwrap(values.quarantineProperties)
        XCTAssertEqual(properties[kLSQuarantineAgentNameKey as String] as? String, "SolStream")
    }

    /// A long name is cut to what APFS holds -- UTF-16 units of the
    /// decomposed form -- between characters, with room for " 9999".
    func testALongNameIsCutToWhatAPFSHolds() {
        // 250 kanji fit whole in 255 units, though they are 750 bytes.
        let kanji = String(repeating: "資", count: 230) + ".pdf"
        XCTAssertEqual(FileReceiver.safeName(kanji), kanji)
        // 128 emoji are 256 units: cut.
        let emoji = FileReceiver.safeName(String(repeating: "😀", count: 128) + ".txt")
        XCTAssertLessThanOrEqual(FileReceiver.units(emoji), FileReceiver.maxNameUnits)
        XCTAssertTrue(emoji.hasSuffix(".txt") && emoji.hasPrefix("😀"))
        // 100 Ǖ are 200 bytes but 300 units decomposed: cut too.
        let accented = FileReceiver.safeName(String(repeating: "\u{01D5}", count: 100) + ".txt")
        XCTAssertLessThanOrEqual(FileReceiver.units(accented), FileReceiver.maxNameUnits)
        XCTAssertLessThanOrEqual(FileReceiver.units(accented + " 9999"), 255)
        // A first character too long to keep leaves no hidden or empty name.
        let monster = "e" + String(repeating: "\u{301}", count: 300) + "x.txt"
        XCTAssertEqual(FileReceiver.safeName(monster), "File from PC.txt")
        XCTAssertEqual(FileReceiver.safeName("e" + String(repeating: "\u{301}", count: 300)),
                       "File from PC")
        // Characters are kept whole.
        XCTAssertEqual(FileReceiver.prefix("aé資", units: 2), "a")
        XCTAssertEqual(FileReceiver.prefix("aé資", units: 3), "aé")
        XCTAssertEqual(FileReceiver.prefix("aé資", units: 4), "aé資")
        // Short names are left as they are.
        XCTAssertEqual(FileReceiver.safeName("資料.pdf"), "資料.pdf")
    }

    /// Part files a crash left behind are swept; nothing else is.
    func testLeftoverPartFilesAreSwept() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-parts-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let names = [".\(UUID().uuidString).solstream-part", "keep.solstream-part", "report.pdf",
                     ".DS_Store"]
        for name in names {
            try Data("x".utf8).write(to: folder.appendingPathComponent(name))
        }
        // Written to just now: maybe another copy's download in progress.
        FileReceiver.removeLeftoverParts(in: folder)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 4)
        // Untouched for longer than any download goes quiet: swept.
        FileReceiver.removeLeftoverParts(in: folder, now: Date().addingTimeInterval(11 * 60))
        let left = Set(try FileManager.default.contentsOfDirectory(atPath: folder.path))
        XCTAssertEqual(left, ["keep.solstream-part", "report.pdf", ".DS_Store"])
    }

    /// A finished file is moved into place under a number when the name is
    /// taken, and never over what is there.
    func testAFinishedFileIsNumberedNotOverwritten() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-move-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        try Data("old".utf8).write(to: folder.appendingPathComponent("a.txt"))
        let partial = folder.appendingPathComponent(".p.solstream-part")
        try Data("new".utf8).write(to: partial)
        let moved = try XCTUnwrap(FileReceiver.move(partial, toName: "a.txt", in: folder))
        XCTAssertEqual(moved.lastPathComponent, "a 2.txt")
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent("a.txt"), encoding: .utf8), "old")
        XCTAssertEqual(try String(contentsOf: moved, encoding: .utf8), "new")
        XCTAssertNil(FileReceiver.move(partial, toName: "b.txt", in: folder))   // already gone
    }

    /// The host's reason a download stopped is shown when it is written for
    /// a person; an older host's note for the log is not.
    func testOnlyTheHostsSentencesAreShown() {
        XCTAssertEqual(AgentConnection.downloadReason(
            "The file changed on the PC while it was being sent. Send it again once it's saved."),
            "The file changed on the PC while it was being sent. Send it again once it's saved.")
        XCTAssertNil(AgentConnection.downloadReason("no such file on offer"))
        XCTAssertNil(AgentConnection.downloadReason("offset out of range"))
        XCTAssertNil(AgentConnection.downloadReason("the file can no longer be read"))
        XCTAssertNil(AgentConnection.downloadReason(""))
        XCTAssertNil(AgentConnection.downloadReason(String(repeating: "A", count: 301)))
        // A script without case, or a sentence that ends otherwise, is shown.
        XCTAssertEqual(AgentConnection.downloadReason("ファイルが変更されました。"),
                       "ファイルが変更されました。")
        XCTAssertEqual(AgentConnection.downloadReason("Error 5!"), "Error 5!")
    }

    /// A file from the PC says how far it has come, and what is still to come.
    func testTheProgressLine() {
        XCTAssertEqual(FileReceiver.receivingText(name: "photo.jpg", percent: 40, queued: 0),
                       "Receiving photo.jpg from the PC… 40%")
        XCTAssertEqual(FileReceiver.receivingText(name: "photo.jpg", percent: 140, queued: 2),
                       "Receiving photo.jpg from the PC… 100% · 2 more to come")
        XCTAssertTrue(FileReceiver.waitingText(name: "photo.jpg").contains("photo.jpg"))
    }

    func testThePercentIsWholeAndBounded() {
        XCTAssertEqual(FileReceiver.percent(received: 0, of: 1000), 0)
        XCTAssertEqual(FileReceiver.percent(received: 499, of: 1000), 49)
        XCTAssertEqual(FileReceiver.percent(received: 2000, of: 1000), 100)
        XCTAssertEqual(FileReceiver.percent(received: -5, of: 1000), 0)
        XCTAssertEqual(FileReceiver.percent(received: 0, of: 0), 100)
        // Large files do not overflow.
        XCTAssertEqual(FileReceiver.percent(received: 4_000_000_000, of: 8_000_000_000), 50)
    }

}
