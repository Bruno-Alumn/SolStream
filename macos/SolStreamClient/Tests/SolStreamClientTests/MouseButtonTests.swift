import AppKit
import XCTest
@testable import InputCapture
@testable import MediaSession

/// Which Mac button becomes which host button.
final class MouseButtonTests: XCTestCase {
    func testTheThreeUsualButtons() {
        XCTAssertEqual(InputCapture.button(for: .leftMouseDown, number: 0), .left)
        XCTAssertEqual(InputCapture.button(for: .rightMouseUp, number: 1), .right)
        XCTAssertEqual(InputCapture.button(for: .otherMouseDown, number: 2), .middle)
    }

    /// Back and forward on a five-button mouse are AppKit's 3 and 4, and they
    /// must arrive as Windows' XBUTTON1 and XBUTTON2 rather than nothing.
    func testTheThumbButtonsAreSent() {
        XCTAssertEqual(InputCapture.button(for: .otherMouseDown, number: 3), .extra1)
        XCTAssertEqual(InputCapture.button(for: .otherMouseUp, number: 3), .extra1)
        XCTAssertEqual(InputCapture.button(for: .otherMouseDown, number: 4), .extra2)
        XCTAssertEqual(InputCapture.button(for: .otherMouseUp, number: 4), .extra2)
    }

    /// The wire numbers the host's switch expects: 4 and 5 are the X buttons.
    func testTheThumbButtonsAreNumberedForTheHost() {
        XCTAssertEqual([UInt8](SMTInput.mouseButton(.extra1, pressed: true)),
                       [SMTInput.Kind.button.rawValue, 2, 4, 1])
        XCTAssertEqual([UInt8](SMTInput.mouseButton(.extra2, pressed: false)),
                       [SMTInput.Kind.button.rawValue, 2, 5, 0])
    }

    /// Windows has no sixth button to give a gaming mouse's extra ones.
    func testButtonsBeyondTheFifthAreNotSent() {
        XCTAssertNil(InputCapture.button(for: .otherMouseDown, number: 5))
        XCTAssertNil(InputCapture.button(for: .otherMouseDown, number: 9))
    }

    func testNonButtonEventsAreNoButton() {
        XCTAssertNil(InputCapture.button(for: .mouseMoved, number: 0))
        XCTAssertNil(InputCapture.button(for: .scrollWheel, number: 3))
    }
}
