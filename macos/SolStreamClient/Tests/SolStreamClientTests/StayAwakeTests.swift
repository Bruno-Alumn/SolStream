import XCTest
@testable import SolStreamClient

/// The display stays on while a stream is open, and only then.
final class StayAwakeTests: XCTestCase {
    func testHeldOnceAndReleasedOnce() {
        var begun = 0, ended = 0
        let awake = StayAwake(begin: { _ in begun += 1; return NSObject() },
                              end: { _ in ended += 1 })
        awake.hold()
        awake.hold()   // Switch App over a stream already held
        XCTAssertTrue(awake.isHeld)
        XCTAssertEqual(begun, 1)
        awake.release()
        awake.release()
        XCTAssertFalse(awake.isHeld)
        XCTAssertEqual(ended, 1)
    }

    func testLetGoWhenItGoes() {
        var ended = 0
        var awake: StayAwake? = StayAwake(begin: { _ in NSObject() }, end: { _ in ended += 1 })
        awake?.hold()
        awake = nil
        XCTAssertEqual(ended, 1)
    }
}
