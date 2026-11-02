import XCTest
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
}
