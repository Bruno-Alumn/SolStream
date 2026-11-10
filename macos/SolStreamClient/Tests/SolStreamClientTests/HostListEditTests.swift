import XCTest
@testable import SolStreamClient

/// The connect window's PC list: an address typed into the open list goes to
/// its field, and a used-before address can be taken off the list.
final class HostListEditTests: XCTestCase {
    private var defaults: UserDefaults!
    /// Its own each run: two checkouts testing at once share a suite name.
    private let suite = "HostListEditTests-\(UUID().uuidString)"

    override func setUpWithError() throws {
        try super.setUpWithError()
        defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
        super.tearDown()
    }

    func testAddressCharactersGoToTheField() {
        for character in "aZ09.-:_[]" {
            XCTAssertTrue(HostDropdown.typesAddress(character), "\(character)")
        }
        for character in " /\t!" {
            XCTAssertFalse(HostDropdown.typesAddress(character), "\(character)")
        }
    }

    func testForgettingOneLeavesTheRest() {
        defaults.set(["192.168.1.40", "DESKTOP-ONE", "100.64.0.7"], forKey: "SolStream.recentHosts")
        defaults.set("desktop-one", forKey: "SolStream.lastHost")
        ConnectWindow.forget(host: "desktop-one.", in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "SolStream.recentHosts"),
                       ["192.168.1.40", "100.64.0.7"])
        XCTAssertNil(defaults.string(forKey: "SolStream.lastHost"),
                     "the forgotten PC was still the one the window opens on")
    }

    func testForgettingAnotherKeepsTheLastUsed() {
        defaults.set(["192.168.1.40", "DESKTOP-ONE"], forKey: "SolStream.recentHosts")
        defaults.set("DESKTOP-ONE", forKey: "SolStream.lastHost")
        ConnectWindow.forget(host: "192.168.1.40", in: defaults)
        XCTAssertEqual(defaults.stringArray(forKey: "SolStream.recentHosts"), ["DESKTOP-ONE"])
        XCTAssertEqual(defaults.string(forKey: "SolStream.lastHost"), "DESKTOP-ONE")
    }
}
