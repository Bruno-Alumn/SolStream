import XCTest
@testable import SolStreamClient

/// A PC whose SolStream is older than this Mac's is said to be, once: the
/// features that need both ends do nothing until it is updated.
final class OutdatedHostTests: XCTestCase {
    func testAnOlderHostIsNamed() {
        let note = StreamSession.outdatedHostNote(hostVersion: "1.0.5", macVersion: "1.0.9")
        XCTAssertEqual(note, "SolStream on the PC is 1.0.5, older than this Mac's 1.0.9. "
                       + "Update it on the PC so everything works.")
    }

    func testAHostThatSaysNothingIsOlder() {
        XCTAssertNotNil(StreamSession.outdatedHostNote(hostVersion: nil, macVersion: "1.0.9"))
    }

    func testTheSameOrNewerHostIsNotMentioned() {
        XCTAssertNil(StreamSession.outdatedHostNote(hostVersion: "1.0.9", macVersion: "1.0.9"))
        XCTAssertNil(StreamSession.outdatedHostNote(hostVersion: "1.1.0", macVersion: "1.0.9"))
        XCTAssertNil(StreamSession.outdatedHostNote(hostVersion: "1.0.10", macVersion: "1.0.9"))
    }

    /// A development build has no version to compare, nor does a host that
    /// says something that is not one.
    func testNothingToCompareSaysNothing() {
        XCTAssertNil(StreamSession.outdatedHostNote(hostVersion: "1.0.5", macVersion: "0.0.0"))
        XCTAssertNil(StreamSession.outdatedHostNote(hostVersion: "weird", macVersion: "1.0.9"))
    }
}
