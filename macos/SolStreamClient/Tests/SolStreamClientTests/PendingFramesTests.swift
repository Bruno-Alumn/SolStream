import XCTest
@testable import SolStreamClient

/// The frames waiting for the decoder: in order, an IDR replacing what
/// waits, and a backlog dropped whole until the next IDR.
final class PendingFramesTests: XCTestCase {
    private func frame(_ byte: UInt8) -> Data { Data([byte]) }

    func testFramesWaitInOrder() {
        var pending = PendingFrames()
        XCTAssertEqual(pending.push(frame(1), isIdr: true), .queued)
        XCTAssertEqual(pending.push(frame(2), isIdr: false), .queued)
        XCTAssertEqual(pending.push(frame(3), isIdr: false), .queued)
        XCTAssertEqual(pending.takeAll().map { $0.data }, [frame(1), frame(2), frame(3)])
        XCTAssertFalse(pending.hasFrames)
    }

    func testAnIdrReplacesWhatWaits() {
        var pending = PendingFrames()
        _ = pending.push(frame(1), isIdr: false)
        _ = pending.push(frame(2), isIdr: false)
        XCTAssertEqual(pending.push(frame(3), isIdr: true), .queued)
        let taken = pending.takeAll()
        XCTAssertEqual(taken.map { $0.data }, [frame(3)])
        XCTAssertEqual(taken.map { $0.isIdr }, [true])
    }

    func testABacklogIsDroppedUntilTheNextIdr() {
        var pending = PendingFrames()
        for i in 0..<PendingFrames.maxBacklog {
            XCTAssertEqual(pending.push(frame(UInt8(i)), isIdr: false), .queued)
        }
        XCTAssertEqual(pending.push(frame(99), isIdr: false), .droppedBacklog)
        XCTAssertFalse(pending.hasFrames)
        // Nothing built on what was dropped gets through...
        XCTAssertEqual(pending.push(frame(100), isIdr: false), .droppedFrame)
        XCTAssertFalse(pending.hasFrames)
        // ...until an IDR.
        XCTAssertEqual(pending.push(frame(101), isIdr: true), .queued)
        XCTAssertEqual(pending.push(frame(102), isIdr: false), .queued)
        XCTAssertEqual(pending.takeAll().map { $0.data }, [frame(101), frame(102)])
    }

    func testNothingAfterStop() {
        var pending = PendingFrames()
        _ = pending.push(frame(1), isIdr: true)
        pending.stop()
        XCTAssertFalse(pending.hasFrames)
        XCTAssertEqual(pending.push(frame(2), isIdr: true), .droppedFrame)
        XCTAssertFalse(pending.hasFrames)
    }
}
