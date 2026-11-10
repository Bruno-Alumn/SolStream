import XCTest
@testable import SolStreamClient

/// The picker's search finds an app by its words in any order, and lets go
/// of case and accents.
final class AppPickerSearchTests: XCTestCase {
    private func score(_ title: String, _ query: String) -> Int? {
        AppPicker.score(title: title, query: query)
    }

    func testWordsInAnyOrder() {
        XCTAssertNotNil(score("Visual Studio Code", "visual code"))
        XCTAssertNotNil(score("Visual Studio Code", "code visual"))
        XCTAssertNotNil(score("Visual Studio Code", "  Studio   CODE "))
    }

    func testEveryWordHasToBeThere() {
        XCTAssertNil(score("Notepad", "note pad x"))
        XCTAssertNil(score("Visual Studio Code", "visual basic"))
    }

    func testAccentsCaseAndWidthLetGo() {
        XCTAssertNotNil(score("Café Manager", "cafe"))
        XCTAssertNotNil(score("cafe manager", "CAFÉ"))
        XCTAssertNotNil(score("Ｎｏｔｅｐａｄ", "notepad"))
    }

    /// One word scores as it always did: prefix, then a word's start, then
    /// anywhere.
    func testOneWordScoresAsBefore() {
        XCTAssertEqual(score("Code", "code"), 100)
        XCTAssertEqual(score("Visual Studio Code", "code"), 60)
        XCTAssertEqual(score("Unicode Viewer", "code"), 20)
        XCTAssertEqual(score("Anything", ""), 0)
        XCTAssertEqual(score("Anything", "   "), 0)
    }

    /// The words as typed, together, rank above the same words apart.
    func testTheWordsTogetherRankFirst() throws {
        let together = try XCTUnwrap(score("Studio Code Helper", "studio code"))
        let apart = try XCTUnwrap(score("Code Studio Helper", "studio code"))
        XCTAssertGreaterThan(together, apart)
    }

    /// However the space between them was typed, or a title spells it.
    func testAnySpaceBetweenTheWords() {
        let single = score("Visual Studio Code", "visual studio")
        XCTAssertEqual(score("Visual Studio Code", "visual  studio"), single)
        XCTAssertEqual(score("Visual Studio Code", "visual\tstudio"), single)
        XCTAssertEqual(score("Visual\u{00A0}Studio Code", "visual studio"), single)
        XCTAssertEqual(AppPicker.fold("  Café\u{3000}Bar \n"), "cafe bar")
    }
}
