import XCTest
@testable import SolStreamClient

/// An empty app list says why, and how to get out of it.
final class AppPickerEmptyTests: XCTestCase {
    func testASearchThatMatchesNothingSaysSo() {
        XCTAssertEqual(AppPicker.emptyText(query: "zzz", hasPresented: true),
                       "Nothing on the PC matches \u{201C}zzz\u{201D}. Esc clears the search.")
    }

    func testAnEmptyPCSaysSo() {
        XCTAssertEqual(AppPicker.emptyText(query: "", hasPresented: true),
                       "The PC has no open windows or apps to show.")
    }

    /// Before the list arrives the footer is already saying it is being asked.
    func testNothingBeforeTheListArrives() {
        XCTAssertNil(AppPicker.emptyText(query: "", hasPresented: false))
        XCTAssertNil(AppPicker.emptyText(query: "zzz", hasPresented: false))
    }
}
