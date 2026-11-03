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
        XCTAssertLessThanOrEqual(FileReceiver.safeName(String(repeating: "x", count: 400) + ".txt").utf8.count, 200)
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

    /// A long name is cut by bytes, which the file system counts, between
    /// characters: 150 characters of Japanese would be 450 bytes, past 255.
    func testALongNameIsCutByBytes() {
        let japanese = String(repeating: "資料", count: 60) + ".pdf"   // 360 bytes before .pdf
        let cut = FileReceiver.safeName(japanese)
        XCTAssertLessThanOrEqual(cut.utf8.count, 255)
        XCTAssertTrue(cut.hasSuffix(".pdf"))
        XCTAssertTrue(cut.hasPrefix("資料"))
        XCTAssertEqual(FileReceiver.prefix("aé資", bytes: 3), "aé")
        XCTAssertEqual(FileReceiver.prefix("aé資", bytes: 5), "aé")
        XCTAssertEqual(FileReceiver.prefix("aé資", bytes: 6), "aé資")
        // A character made of several scalars is kept whole or not at all.
        XCTAssertEqual(FileReceiver.prefix("e\u{301}x", bytes: 2), "")
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
        FileReceiver.removeLeftoverParts(in: folder)
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
        XCTAssertNil(AgentConnection.downloadReason(""))
    }
}
