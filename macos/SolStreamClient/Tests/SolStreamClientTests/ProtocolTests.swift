import XCTest
@testable import AgentChannel
@testable import MediaSession
@testable import VideoDecoder
@testable import InputCapture

/// What is left of the protocol tests after GameStream went.
///
/// The bulk of this file used to assemble datagrams the way Sunshine's
/// `videoBroadcastThread` does -- 32-byte headers, Reed-Solomon shards, FEC
/// block arithmetic -- so that a change breaking interoperability failed here
/// rather than silently producing a black window. There is nothing to be
/// interoperable with any more. The Annex-B handling stayed, because the
/// decoder still takes Annex-B, and SMT/1 has tests of its own in SMTTests.
final class ProtocolTests: XCTestCase {

    private func sampleAnnexBFrame(sliceBytes: Int) -> Data {
        var frame = Data()
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x67, 0x42, 0x00, 0x0A, 0xF8, 0x41, 0xA2])
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x68, 0xCE, 0x38, 0x80])
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x65])
        frame.append(Data((0..<sliceBytes).map { UInt8(($0 % 250) + 1) }))
        return frame
    }

    // MARK: - Annex-B handling

    func testAnnexBSplitFindsEveryNalUnit() {
        let frame = sampleAnnexBFrame(sliceBytes: 32)
        let units = VideoDecoder.splitAnnexB(frame).map { Data(frame[$0]) }
        XCTAssertEqual(units.count, 3)
        XCTAssertEqual(units[0].first! & 0x1F, 7, "first NAL is SPS")
        XCTAssertEqual(units[1].first! & 0x1F, 8, "second NAL is PPS")
        XCTAssertEqual(units[2].first! & 0x1F, 5, "third NAL is an IDR slice")
    }

    func testAnnexBSplitHandlesThreeByteStartCodes() {
        var frame = Data([0x00, 0x00, 0x01, 0x67, 0x01, 0x02])
        frame.append(contentsOf: [0x00, 0x00, 0x00, 0x01, 0x68, 0x03])
        let units = VideoDecoder.splitAnnexB(frame).map { Data(frame[$0]) }

        XCTAssertEqual(units.count, 2)
        XCTAssertEqual(units[0], Data([0x67, 0x01, 0x02]))
        XCTAssertEqual(units[1], Data([0x68, 0x03]))
    }

}

/// The client picks which host display to park applications on. Getting this
/// wrong is not a visible error: it streams the real monitor instead, and every
/// crop then shows whatever the user happens to have open there.
final class DisplaySelectionTests: XCTestCase {

    private func display(_ name: String, adapter: String,
                         primary: Bool = false, captured: Bool = false,
                         width: Int = 1920, height: Int = 1080) -> RemoteDisplay {
        RemoteDisplay(name: name, adapter: adapter, x: 0, y: 0,
                      width: width, height: height,
                      isPrimary: primary, isCaptured: captured)
    }

    /// "Virtual" and "being streamed" are different questions, and the second is
    /// the one that matters. The host decides what Sunshine encodes; a client
    /// that infers it from the adapter string agrees only by luck, and against a
    /// Sunshine the user set up themselves it does not agree at all.
    func testBeingCapturedIsIndependentOfBeingVirtual() {
        let physicalAndStreamed = display("\\\\.\\DISPLAY1",
                                          adapter: "NVIDIA GeForce RTX 4070 SUPER",
                                          primary: true, captured: true)
        XCTAssertFalse(physicalAndStreamed.isVirtual)
        XCTAssertTrue(physicalAndStreamed.isCaptured)

        let virtualAndIdle = display("\\\\.\\DISPLAY5", adapter: "Virtual Display Driver")
        XCTAssertTrue(virtualAndIdle.isVirtual)
        XCTAssertFalse(virtualAndIdle.isCaptured)
    }

    func testVirtualDisplayIsRecognisedByAdapter() {
        XCTAssertTrue(display("\\\\.\\DISPLAY6", adapter: "Virtual Display Driver").isVirtual)
        XCTAssertTrue(display("\\\\.\\DISPLAY2", adapter: "IddSampleDriver Device").isVirtual)
    }

    func testPhysicalAdapterIsNotVirtual() {
        XCTAssertFalse(display("\\\\.\\DISPLAY1", adapter: "NVIDIA GeForce RTX 4070 SUPER").isVirtual)
        XCTAssertFalse(display("\\\\.\\DISPLAY1", adapter: "Radeon RX 580 Series").isVirtual)
    }

    /// An agent that predates the `adapter` field must not have every display
    /// silently classed as virtual.
    func testMissingAdapterIsNotVirtual() {
        XCTAssertFalse(display("\\\\.\\DISPLAY1", adapter: "").isVirtual)
    }
}

/// The pointer is mapped onto the picture, not onto the view.
///
/// The video layer scales with .resizeAspect, so a crop whose shape differs from
/// the view's is letterboxed. Measuring from the view's edges then puts the host
/// pointer off by an amount that grows with distance from the centre — a drift
/// that gets worse the further the mouse travels.
final class PointerMappingTests: XCTestCase {

    private func unit(_ point: CGPoint, view: CGSize, source: CGRect) -> CGPoint? {
        InputCapture.unitPoint(viewPoint: point, viewSize: view, source: source, isFlipped: true)
    }

    /// Shapes match, so the picture fills the view and the mapping is linear.
    func testMatchingAspectMapsLinearly() {
        let view = CGSize(width: 800, height: 500)
        let source = CGRect(x: 100, y: 50, width: 1600, height: 1000)

        XCTAssertEqual(unit(CGPoint(x: 0, y: 0), view: view, source: source)?.x ?? -1, 0, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 400, y: 250), view: view, source: source)?.x ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 400, y: 250), view: view, source: source)?.y ?? -1, 0.5, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 800, y: 500), view: view, source: source)?.x ?? -1, 1, accuracy: 0.001)
    }

    /// A picture wider than the view is letterboxed top and bottom. The centre
    /// still maps to the centre; the rows above and below it are not picture.
    func testLetterboxedVerticallyIgnoresTheBars() {
        let view = CGSize(width: 800, height: 800)
        let source = CGRect(x: 0, y: 0, width: 1600, height: 800)   // 2:1 into a square
        // Picture is 800x400, centred, so bars are 200pt tall.
        XCTAssertNil(unit(CGPoint(x: 400, y: 100), view: view, source: source))
        XCTAssertNil(unit(CGPoint(x: 400, y: 700), view: view, source: source))

        let middle = unit(CGPoint(x: 400, y: 400), view: view, source: source)
        XCTAssertEqual(middle?.y ?? -1, 0.5, accuracy: 0.001)
        // Top edge of the picture, 200pt down the view.
        XCTAssertEqual(unit(CGPoint(x: 400, y: 200), view: view, source: source)?.y ?? -1,
                       0, accuracy: 0.001)
    }

    /// A picture taller than the view is pillarboxed — the case the user saw as
    /// bars down each side.
    func testPillarboxedHorizontallyIgnoresTheBars() {
        let view = CGSize(width: 800, height: 800)
        let source = CGRect(x: 0, y: 0, width: 400, height: 800)    // 1:2 into a square
        // Picture is 400x800, centred, so bars are 200pt wide.
        XCTAssertNil(unit(CGPoint(x: 100, y: 400), view: view, source: source))
        XCTAssertEqual(unit(CGPoint(x: 200, y: 400), view: view, source: source)?.x ?? -1,
                       0, accuracy: 0.001)
        XCTAssertEqual(unit(CGPoint(x: 600, y: 400), view: view, source: source)?.x ?? -1,
                       1, accuracy: 0.001)
    }

    /// The regression itself: measuring across the whole view instead of the
    /// picture. Half way down a letterboxed view is NOT half way down the image,
    /// and the error is largest at the extremes.
    func testDriftGrowsWithDistanceWhenLetterboxed() {
        let view = CGSize(width: 800, height: 800)
        let source = CGRect(x: 0, y: 0, width: 1600, height: 800)

        // Naive mapping: y / viewHeight. Correct mapping accounts for the bars.
        for viewY in stride(from: 200.0, through: 600.0, by: 100.0) {
            let naive = viewY / view.height
            let correct = unit(CGPoint(x: 400, y: viewY), view: view, source: source)!.y
            let error = abs(naive - correct)
            if viewY == 400 {
                XCTAssertEqual(error, 0, accuracy: 0.001, "no error at the centre")
            } else {
                XCTAssertGreaterThan(error, 0.1, "the naive mapping is off away from the centre")
            }
        }
    }

    func testDegenerateSizesAreRejected() {
        XCTAssertNil(unit(CGPoint(x: 1, y: 1), view: .zero,
                          source: CGRect(x: 0, y: 0, width: 10, height: 10)))
        XCTAssertNil(unit(CGPoint(x: 1, y: 1), view: CGSize(width: 10, height: 10),
                          source: .zero))
    }
}
