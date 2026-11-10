import AppKit
import XCTest
@testable import SolStreamClient

/// The token sheet's heading wraps to a second line for a long PC name
/// rather than cutting off whether the token was missing or refused.
@MainActor
final class TokenSheetHeadingTests: XCTestCase {
    func testALongNameMakesTheSheetTallerNotShorter() throws {
        let short = TokenPrompt.Sheet(host: "PC", rejected: true) { _ in }
        let long = TokenPrompt.Sheet(host: "desktop-k3j9qx.tail1a2b3c.ts.net", rejected: true) { _ in }
        let shortHeight = try XCTUnwrap(short.window.contentView).fittingSize.height
        let longHeight = try XCTUnwrap(long.window.contentView).fittingSize.height
        XCTAssertGreaterThan(longHeight, shortHeight, "the long heading did not wrap")
    }

    /// Retargeting to a long name sizes the sheet as one made for it.
    func testRetargetResizes() throws {
        let host = "desktop-k3j9qx.tail1a2b3c.ts.net"
        let sheet = TokenPrompt.Sheet(host: "PC", rejected: true) { _ in }
        sheet.retarget(host: host, rejected: true) { _ in }
        let fresh = TokenPrompt.Sheet(host: host, rejected: true) { _ in }
        XCTAssertEqual(sheet.window.frame.height, fresh.window.frame.height)
    }

    /// VoiceOver names the sheet by its heading, hidden title and all, and the
    /// field by what it takes; a retarget renames the sheet with it.
    func testTheSheetAndItsFieldHaveNames() {
        let sheet = TokenPrompt.Sheet(host: "PC", rejected: false) { _ in }
        XCTAssertEqual(sheet.window.title,
                       TokenPrompt.Sheet.headingText(host: "PC", rejected: false))
        sheet.retarget(host: "PC", rejected: true) { _ in }
        XCTAssertEqual(sheet.window.title,
                       TokenPrompt.Sheet.headingText(host: "PC", rejected: true))
        XCTAssertEqual(sheet.fieldAccessibilityLabel, "Pairing token")
    }

}
