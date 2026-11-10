import AppKit
import XCTest
@testable import SolStreamClient

/// A pasted token that cannot be one is said in the sheet, before it goes
/// to a PC that would only refuse it.
@MainActor
final class TokenCheckTests: XCTestCase {
    private let token = "00112233445566778899aabbccddeeff"

    func testATokenPassesAsPasted() {
        XCTAssertEqual(try TokenPrompt.check(token).get(), token)
    }

    func testWhiteSpaceAndALabelAreDropped() {
        XCTAssertEqual(try TokenPrompt.check("  0011223344556677\n8899aabbccddeeff \t").get(), token)
        XCTAssertEqual(try TokenPrompt.check("Pairing token: \(token)").get(), token)
        // Nor what cannot be seen: a zero-width space, a byte-order mark, a
        // soft hyphen, a no-break space.
        XCTAssertEqual(try TokenPrompt.check("\u{FEFF}0011223344\u{200B}5566778899\u{00AD}aabb\u{00A0}ccddeeff").get(),
                       token)
    }

    /// The shortest token a PC accepts, 16, is let through: an older one
    /// that still works must not be turned away here.
    func testAnOlderShorterTokenPasses() {
        XCTAssertEqual(try TokenPrompt.check("0123456789abcdef").get(), "0123456789abcdef")
        XCTAssertEqual(try TokenPrompt.check(token + token).get(), token + token)
    }

    func testWhatIsWrongIsSaid() {
        XCTAssertEqual(Self.problem(""), .empty)
        XCTAssertEqual(Self.problem("   \n"), .empty)
        XCTAssertEqual(Self.problem("0123456789abcdefO123"), .notHex("O"))
        XCTAssertEqual(Self.problem("０１２３４５６７８９abcdef0123"), .notHex("０"),
                       "a full-width digit is not one the PC can read")
        XCTAssertEqual(Self.problem(String(token.dropLast(2))), nil, "30 even digits may be an older token")
        XCTAssertEqual(Self.problem(String(token.dropLast())), .incomplete(31))
        XCTAssertEqual(Self.problem("0123456789ab"), .incomplete(12))
    }

    func testTheWordsSayWhatToDo() {
        XCTAssertEqual(TokenPrompt.problemText(.notHex("O")),
                       "A token has only 0–9 and a–f, not “O”. An O may be a zero.")
        XCTAssertEqual(TokenPrompt.problemText(.notHex("l")),
                       "A token has only 0–9 and a–f, not “l”. An l may be a one.")
        XCTAssertEqual(TokenPrompt.problemText(.notHex("g")), "A token has only 0–9 and a–f, not “g”.")
        XCTAssertTrue(TokenPrompt.problemText(.incomplete(31)).hasPrefix("That's 31 characters,"))
        XCTAssertTrue(TokenPrompt.problemText(.incomplete(1)).hasPrefix("That's 1 character,"))
    }

    /// Connect with a bad paste keeps the sheet, says why under the field,
    /// and grows the sheet for the line; editing takes the line away.
    func testTheSheetSaysItAndStays() throws {
        var answered: String?? = .none
        let sheet = TokenPrompt.Sheet(host: "PC", rejected: false) { answered = .some($0) }
        let before = sheet.window.frame.height
        sheet.typed = "0123456789abcdefO123"
        sheet.connect()
        XCTAssertNil(answered ?? nil, "a bad token was sent on")
        XCTAssertEqual(sheet.problemShown, TokenPrompt.problemText(.notHex("O")))
        XCTAssertGreaterThan(sheet.window.frame.height, before)
        NotificationCenter.default.post(name: NSControl.textDidChangeNotification,
                                        object: try XCTUnwrap(Self.field(in: sheet.window.contentView)))
        XCTAssertNil(sheet.problemShown)
        XCTAssertEqual(sheet.window.frame.height, before)
        sheet.typed = " \(token) "
        sheet.connect()
        XCTAssertEqual(answered, .some(token))
    }

    private static func problem(_ raw: String) -> TokenPrompt.Problem? {
        if case .failure(let problem) = TokenPrompt.check(raw) { return problem }
        return nil
    }

    private static func field(in view: NSView?) -> NSTextField? {
        guard let view else { return nil }
        if let field = view as? NSTextField, field.isEditable { return field }
        for child in view.subviews { if let found = field(in: child) { return found } }
        return nil
    }
}
