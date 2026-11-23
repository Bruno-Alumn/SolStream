import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// Where a window added to a running stream goes on the capture display, and
/// what the windows already there give up for it.
///
/// Every streamed window is a crop of one picture, so two host windows sharing
/// pixels each show the other. Nothing here may ever overlap.
final class TileAllocatorTests: XCTestCase {
    /// The virtual display as the PC reports it: off to the right of a real
    /// monitor, so nothing here may assume the origin is zero.
    private let display = RemoteDisplay(name: #"\\.\DISPLAY13"#, adapter: "Virtual Display Driver",
                                        x: 3440, y: 0, width: 3600, height: 2338,
                                        isPrimary: false, isCaptured: true)
    private var canvas: CGRect { AppDelegate.displayRect(display) }

    private func window(_ id: UInt64, _ width: Int, _ height: Int,
                        caption: Int = 31) -> RemoteWindow {
        RemoteWindow(id: id, pid: 100, title: "App \(id)", className: "Window",
                     x: 0, y: 0, width: width, height: height,
                     isOccluded: false, occludedBy: nil, captionInset: caption)
    }

    private func assertApart(_ rects: [CGRect], gap: CGFloat = 0,
                             file: StaticString = #filePath, line: UInt = #line) {
        for (i, a) in rects.enumerated() {
            for b in rects[(i + 1)...] {
                XCTAssertFalse(overlaps(a.insetBy(dx: -gap / 2, dy: -gap / 2),
                                        b.insetBy(dx: -gap / 2, dy: -gap / 2)),
                               "\(a) and \(b) overlap", file: file, line: line)
            }
        }
    }

    // MARK: - One window, as before

    func testOneWindowStillHasTheWholeDisplay() {
        XCTAssertEqual(AppDelegate.tileLayout(count: 1, on: display), [canvas])
    }

    /// The request a window makes inside a room as big as the display is the
    /// one it made before rooms: moved up and left to stay on, then cut down.
    func testARequestInsideTheWholeDisplayIsTheOldOne() {
        let inside = AppWindow.request(size: CGSize(width: 1600, height: 1000),
                                       at: CGPoint(x: 3440, y: 0), within: canvas)
        XCTAssertEqual(inside, CGRect(x: 3440, y: 0, width: 1600, height: 1000))
        let tooBig = AppWindow.request(size: CGSize(width: 5000, height: 3000),
                                       at: CGPoint(x: 4000, y: 500), within: canvas)
        XCTAssertEqual(tooBig, canvas)
        let offTheEdge = AppWindow.request(size: CGSize(width: 1000, height: 800),
                                           at: CGPoint(x: 6800, y: 2000), within: canvas)
        XCTAssertEqual(offTheEdge, CGRect(x: 6040, y: 1538, width: 1000, height: 800))
    }

    // MARK: - The allocator

    func testAnEmptyDisplayGivesTheTopLeftAtFullSize() {
        let rect = TileAllocator.allocate(canvas: canvas, inUse: [],
                                          wanted: CGSize(width: 1200, height: 900))
        XCTAssertEqual(rect, CGRect(x: 3440, y: 0, width: 1200, height: 900))
    }

    func testANewWindowGoesBesideTheOneThereAndClearOfIt() {
        let first = CGRect(x: 3440, y: 0, width: 1800, height: 1200)
        let rect = TileAllocator.allocate(canvas: canvas, inUse: [first],
                                          wanted: CGSize(width: 1200, height: 900))
        XCTAssertNotNil(rect)
        guard let rect else { return }
        XCTAssertEqual(rect.size, CGSize(width: 1200, height: 900), "there is room at full size")
        XCTAssertTrue(canvas.contains(rect))
        assertApart([first, rect], gap: TileAllocator.gap)
        XCTAssertEqual(rect.minY, 0, "the highest place there is")
    }

    func testItShrinksProportionallyWhenItHasTo() {
        // The left two thirds taken: 1184 pixels free across, less the gap.
        let left = CGRect(x: 3440, y: 0, width: 2400, height: 2338)
        let wanted = CGSize(width: 2000, height: 1500)
        guard let rect = TileAllocator.allocate(canvas: canvas, inUse: [left], wanted: wanted) else {
            return XCTFail("there is room for it smaller")
        }
        XCTAssertLessThan(rect.width, wanted.width)
        XCTAssertEqual(rect.width / rect.height, wanted.width / wanted.height, accuracy: 0.01)
        XCTAssertTrue(canvas.contains(rect))
        assertApart([left, rect], gap: TileAllocator.gap)
    }

    func testNothingBelowTheMinimum() {
        // A sliver down the right-hand side, narrower than any window.
        let most = CGRect(x: 3440, y: 0, width: 3200, height: 2338)
        XCTAssertNil(TileAllocator.allocate(canvas: canvas, inUse: [most],
                                            wanted: CGSize(width: 1600, height: 1000)))
    }

    func testAFullDisplayHasNoRoom() {
        XCTAssertNil(TileAllocator.allocate(canvas: canvas, inUse: [canvas],
                                            wanted: CGSize(width: 800, height: 600)))
    }

    /// A window smaller than the minimum is not refused for being small: the
    /// minimum is only how far a bigger one may be shrunk.
    func testASmallWindowFitsAtItsOwnSize() {
        let rect = TileAllocator.allocate(canvas: canvas, inUse: [],
                                          wanted: CGSize(width: 300, height: 200))
        XCTAssertEqual(rect?.size, CGSize(width: 300, height: 200))
    }

    /// Closing a window is leaving it out of what is in use: its pixels are
    /// given out again, to the same place.
    func testAClosedWindowsRoomIsFreeAgain() {
        let first = CGRect(x: 3440, y: 0, width: 3600, height: 1100)
        let wanted = CGSize(width: 1600, height: 1000)
        guard let second = TileAllocator.allocate(canvas: canvas, inUse: [first], wanted: wanted) else {
            return XCTFail("room below the first")
        }
        XCTAssertGreaterThanOrEqual(second.minY, first.maxY + TileAllocator.gap)
        let again = TileAllocator.allocate(canvas: canvas, inUse: [second], wanted: wanted)
        XCTAssertEqual(again?.origin, canvas.origin, "the first one's corner is free again")
    }

    /// Eight windows of a sensible size, added one after another, never touch.
    func testWindowsAddedOneByOneNeverOverlap() {
        var inUse: [CGRect] = []
        for _ in 0..<8 {
            guard let rect = TileAllocator.allocate(canvas: canvas, inUse: inUse,
                                                    wanted: CGSize(width: 1100, height: 700)) else {
                break
            }
            XCTAssertTrue(canvas.contains(rect))
            inUse.append(rect)
        }
        XCTAssertGreaterThanOrEqual(inUse.count, 6)
        assertApart(inUse, gap: TileAllocator.gap)
    }

    // MARK: - Room to grow, up to a neighbour

    func testAWindowOnItsOwnMayGrowToTheWholeDisplay() {
        let current = CGRect(x: 4000, y: 300, width: 1200, height: 800)
        XCTAssertEqual(TileAllocator.room(around: current, others: [], canvas: canvas), canvas)
        XCTAssertNil(AppWindow.roomLimit(room: canvas, strip: 0, hasNeighbours: false),
                     "a window on its own is held to nothing but the app's own limits")
    }

    func testGrowingRightStopsAtTheNeighboursEdge() {
        let current = CGRect(x: 3440, y: 0, width: 1200, height: 900)
        let neighbour = CGRect(x: 5400, y: 0, width: 1200, height: 900)
        let size = TileAllocator.room(around: current, others: [neighbour], canvas: canvas).size
        // Up to the neighbour less the gap, and on down the display below it:
        // the larger of the two ways to grow.
        let right = CGRect(origin: current.origin, size: size)
        XCTAssertFalse(overlaps(right, neighbour.insetBy(dx: -TileAllocator.gap,
                                                         dy: -TileAllocator.gap)))
        XCTAssertTrue(right.contains(current))
        XCTAssertTrue(canvas.contains(right))
        XCTAssertEqual(size.width, 5400 - TileAllocator.gap - 3440, "stopped at the neighbour")
        XCTAssertEqual(size.height, 2338, "nothing below it, so the whole height")
    }

    func testGrowingDownStopsAtTheNeighbourBelow() {
        let current = CGRect(x: 3440, y: 0, width: 3600, height: 900)
        let below = CGRect(x: 3440, y: 1500, width: 3600, height: 800)
        let size = TileAllocator.room(around: current, others: [below], canvas: canvas).size
        XCTAssertEqual(size, CGSize(width: 3600, height: 1500 - TileAllocator.gap))
    }

    /// Up to the display's own edges, and left only as far as a neighbour in
    /// the top-left corner allows.
    func testNeverPastTheDisplaysEdgeNorIntoANeighbour() {
        let current = CGRect(x: 6000, y: 1800, width: 800, height: 400)
        let room = TileAllocator.room(around: current,
                                      others: [CGRect(x: 3440, y: 0, width: 500, height: 500)],
                                      canvas: canvas)
        XCTAssertEqual(room, CGRect(x: 3940 + TileAllocator.gap, y: 0,
                                    width: 7040 - 3940 - TileAllocator.gap, height: 2338))
    }

    /// Free space beside a neighbour is a staircase: whichever way it grows,
    /// the room it is given is free all over and holds the window as it is.
    func testTheRoomBesideTwoNeighboursIsFreeAllOver() {
        let current = CGRect(x: 4000, y: 800, width: 1000, height: 600)
        let others = [CGRect(x: 5600, y: 0, width: 1440, height: 1000),
                      CGRect(x: 3440, y: 1700, width: 2000, height: 638)]
        let room = TileAllocator.room(around: current, others: others, canvas: canvas)
        XCTAssertTrue(room.contains(current))
        XCTAssertTrue(canvas.contains(room))
        for other in others {
            XCTAssertFalse(overlaps(room, other.insetBy(dx: -TileAllocator.gap,
                                                    dy: -TileAllocator.gap)))
        }
        XCTAssertGreaterThan(room.width * room.height, current.width * current.height,
                             "there is free space to grow into")
    }

    /// An app that would not be made small enough already reaches a
    /// neighbour: its room is not made smaller than it, nor bigger that way.
    func testAWindowAlreadyOverANeighbourKeepsWhatItHasAndGrowsNoFurtherThatWay() {
        let current = CGRect(x: 3440, y: 0, width: 2000, height: 900)
        let neighbour = CGRect(x: 5300, y: 0, width: 1000, height: 900)
        let room = TileAllocator.room(around: current, others: [neighbour], canvas: canvas)
        XCTAssertTrue(room.contains(current))
        XCTAssertEqual(room.maxX, current.maxX)
    }

    /// The window's ceiling is the room's size, less the app's own title bar
    /// when the picture leaves it out; the smaller of that and the app's own
    /// maximum is applied in `applySizeLimits`.
    func testTheNeighbourCapIsTheRoomLessTheHiddenTitleBar() {
        let room = CGRect(x: 3440, y: 31, width: 1944, height: 2307)
        XCTAssertEqual(AppWindow.roomLimit(room: room, strip: 0, hasNeighbours: true),
                       CGSize(width: 1944, height: 2307))
        XCTAssertEqual(AppWindow.roomLimit(room: room, strip: 40, hasNeighbours: true),
                       CGSize(width: 1944, height: 2267))
    }

    /// A request made by any path -- a drag, full screen, the code -- is cut
    /// down to the room, so it can never reach the neighbour.
    func testARequestTooBigForTheRoomIsCutToIt() {
        let room = CGRect(x: 3440, y: 31, width: 1944, height: 2307)
        let request = AppWindow.request(size: CGSize(width: 3600, height: 2338),
                                        at: CGPoint(x: 3440, y: 31), within: room)
        XCTAssertEqual(request, room)
    }

    // MARK: - Adding to the stream

    func testAWindowStreamedAlreadyIsNotAddedTwice() {
        let streamed = [(id: UInt64(7), occupied: CGRect(x: 3440, y: 0, width: 1000, height: 800))]
        XCTAssertEqual(AppDelegate.addition(of: window(7, 800, 600), to: streamed, canvas: canvas),
                       .alreadyStreamed)
    }

    func testNoMoreThanTheHostHolds() {
        let streamed = (0..<8).map { (id: UInt64($0), occupied: CGRect(x: 3440 + $0 * 10, y: 0,
                                                                       width: 5, height: 5)) }
        XCTAssertEqual(AppDelegate.addition(of: window(99, 800, 600), to: streamed, canvas: canvas),
                       .full)
    }

    func testNoRoomIsSaidRatherThanOverlapping() {
        let streamed = [(id: UInt64(1), occupied: canvas)]
        XCTAssertEqual(AppDelegate.addition(of: window(2, 800, 600), to: streamed, canvas: canvas),
                       .noRoom)
    }

    /// The client area it is given leaves room above for its own title bar,
    /// and the whole of it, title bar and all, misses the window already there.
    func testANewWindowsTitleBarIsInsideItsRoom() {
        let first = CGRect(x: 3440, y: 0, width: 1800, height: 1231)
        let streamed = [(id: UInt64(1), occupied: first)]
        guard case .add(let tile) = AppDelegate.addition(of: window(2, 1200, 900, caption: 31),
                                                         to: streamed, canvas: canvas) else {
            return XCTFail("there is room beside it")
        }
        XCTAssertEqual(tile.size, CGSize(width: 1200, height: 900))
        let frame = CGRect(x: tile.minX, y: tile.minY - 31, width: tile.width, height: tile.height + 31)
        XCTAssertTrue(canvas.contains(frame))
        assertApart([first, frame], gap: TileAllocator.gap)
    }

    /// The whole of it, as the windows do it: added one after another, then
    /// each dragged as big as it will go in turn. However that goes, no two
    /// ever come within the gap of each other or leave the display.
    func testWindowsAddedAndThenGrownNeverOverlap() {
        // One window on its own, showing part of the display, title bar off
        // the top as it is on the PC.
        var frames: [UInt64: CGRect] = [1: CGRect(x: 3440, y: 0, width: 2000, height: 1300)]
        for id in UInt64(2)...UInt64(5) {
            let streamed = frames.map { (id: $0.key, occupied: $0.value) }
            guard case .add(let tile) = AppDelegate.addition(of: window(id, 1000, 700, caption: 31),
                                                             to: streamed, canvas: canvas) else {
                return XCTFail("window \(id) found no room")
            }
            frames[id] = CGRect(x: tile.minX, y: tile.minY - 31,
                                width: tile.width, height: tile.height + 31)
            assertApart(Array(frames.values), gap: TileAllocator.gap)
        }
        for id in frames.keys.sorted() {
            let others = frames.filter { $0.key != id }.map(\.value)
            let grown = TileAllocator.room(around: frames[id]!, others: others, canvas: canvas)
            XCTAssertTrue(grown.contains(frames[id]!))
            XCTAssertTrue(canvas.contains(grown))
            frames[id] = grown
            assertApart(Array(frames.values), gap: TileAllocator.gap)
        }
    }

    /// `--app-window "A,B"`: the first window is placed before the second
    /// exists, with the second's tile counted as taken, so its room is its
    /// own tile and no more.
    func testTheFirstOfTwoGridWindowsKeepsToItsOwnTile() {
        let tiles = AppDelegate.tileLayout(count: 2, on: display)
        XCTAssertEqual(tiles.count, 2)
        let room = TileAllocator.room(around: tiles[0], others: [tiles[1]], canvas: canvas)
        XCTAssertEqual(room, tiles[0])
        let request = AppWindow.request(size: CGSize(width: 2600, height: 1700),
                                        at: tiles[0].origin, within: room)
        XCTAssertEqual(request.map { overlaps($0, tiles[1]) }, false)
    }

    /// A window that closes leaves its neighbour free to grow over where it was.
    func testAClosedNeighboursSpaceCanBeGrownInto() {
        let current = CGRect(x: 3440, y: 0, width: 1200, height: 900)
        let neighbour = CGRect(x: 5400, y: 0, width: 1200, height: 900)
        let held = TileAllocator.room(around: current, others: [neighbour], canvas: canvas)
        XCTAssertLessThan(held.width, canvas.width)
        XCTAssertEqual(TileAllocator.room(around: current, others: [], canvas: canvas), canvas)
    }

    // MARK: - The title bar on the capture display

    /// Measured on a 100% monitor, the title bar is half as tall as it will
    /// be on the 200% capture display; it grows with the window.
    func testTheTitleBarIsScaledAsTheWindowIs() {
        var notepad = window(1, 800, 600, caption: 31)
        notepad.naturalWidth = 1600
        notepad.naturalHeight = 1200
        XCTAssertEqual(notepad.naturalCaptionInset, 62)
        // 125% to 200%.
        var dialog = window(2, 1000, 750, caption: 39)
        dialog.naturalWidth = 1600
        dialog.naturalHeight = 1200
        XCTAssertEqual(dialog.naturalCaptionInset, 62)
    }

    func testAHostThatSaysNothingOfTheNaturalSizeKeepsTheMeasuredTitleBar() {
        XCTAssertEqual(window(1, 800, 600, caption: 31).naturalCaptionInset, 31)
        XCTAssertEqual(window(2, 800, 600, caption: 0).naturalCaptionInset, 0)
        XCTAssertEqual(window(3, 800, 600, caption: -4).naturalCaptionInset, 0)
    }

    /// A window added below another leaves room for its title bar as tall as
    /// it will be on the capture display, not as it was measured elsewhere.
    func testANewWindowBelowAnotherLeavesRoomForItsScaledTitleBar() {
        let first = CGRect(x: 3440, y: 0, width: 3600, height: 1000)
        var target = window(2, 800, 500, caption: 31)
        target.naturalWidth = 1600
        target.naturalHeight = 1000
        guard case .add(let tile) = AppDelegate.addition(of: target, to: [(id: 1, occupied: first)],
                                                         canvas: canvas) else {
            return XCTFail("there is room below")
        }
        XCTAssertGreaterThanOrEqual(tile.minY - 62, first.maxY + TileAllocator.gap,
                                    "the title bar at 200% clears the window above")
    }

    // MARK: - Adding to a stream that has ended

    func testNothingIsAddedToAStreamThatHasEnded() {
        let ended = AppDelegate.addGate(streaming: true, recovering: false, connectionLost: false,
                                        ended: true, pictureLive: false)
        guard case .refuse = ended else { return XCTFail("added to an ended stream") }
        let lost = AppDelegate.addGate(streaming: true, recovering: false, connectionLost: true,
                                       ended: false, pictureLive: false)
        guard case .refuse = lost else { return XCTFail("added over a lost connection") }
        let restarting = AppDelegate.addGate(streaming: true, recovering: true, connectionLost: false,
                                             ended: false, pictureLive: false)
        guard case .refuse = restarting else { return XCTFail("added mid-restart") }
        let none = AppDelegate.addGate(streaming: false, recovering: false, connectionLost: false,
                                       ended: false, pictureLive: false)
        guard case .refuse = none else { return XCTFail("added with nothing streaming") }
    }

    /// A stalled stream takes the window, but its card stays until pictures
    /// come again; a live one takes the card down at once.
    func testTheCardComesDownOnlyOverALivePicture() {
        XCTAssertEqual(AppDelegate.addGate(streaming: true, recovering: false, connectionLost: false,
                                           ended: false, pictureLive: false),
                       .open(hidesCard: false))
        XCTAssertEqual(AppDelegate.addGate(streaming: true, recovering: false, connectionLost: false,
                                           ended: false, pictureLive: true),
                       .open(hidesCard: true))
    }

    // MARK: - A place still on its way

    func testTheAnswerToAnOlderPlaceLeavesTheNewerOneInFlight() {
        let older = CGRect(x: 3440, y: 0, width: 1000, height: 700)
        let newer = CGRect(x: 3440, y: 0, width: 1200, height: 800)
        XCTAssertEqual(AppWindow.inFlight(newer, answered: older), newer)
        XCTAssertNil(AppWindow.inFlight(newer, answered: newer))
        XCTAssertNil(AppWindow.inFlight(nil, answered: older))
    }
}

/// Sharing area, not just an edge.
private func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
    a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
}
