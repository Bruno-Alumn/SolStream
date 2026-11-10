import XCTest
@testable import SolStreamClient

/// SolStream's Dock menu offers the apps added to the Dock, and the last
/// one opened, whatever is streaming.
final class DockMenuTests: XCTestCase {
    private let notepad = AppLink(host: "pc", name: "Notepad", path: #"C:\Notepad.lnk"#)
    private let excel = AppLink(host: "pc", name: "Excel", path: #"C:\Excel.lnk"#)
    private let paint = AppLink(host: "pc", name: "Paint", path: #"C:\Paint.lnk"#)

    func testLaunchersByNameWithTheLastFirst() {
        let entries = AppDelegate.dockOpenEntries(launchers: [notepad, excel], last: paint,
                                                  streaming: nil)
        XCTAssertEqual(entries.map(\.title), ["Reopen Paint", "Open Excel", "Open Notepad"])
    }

    /// The last one is not offered twice, nor the app on screen at all.
    func testNoRepeatsAndNotWhatIsOnScreen() {
        let entries = AppDelegate.dockOpenEntries(launchers: [notepad, excel], last: notepad,
                                                  streaming: excel)
        XCTAssertEqual(entries.map(\.title), ["Open Notepad"])
        XCTAssertTrue(AppDelegate.dockOpenEntries(launchers: [], last: nil, streaming: nil).isEmpty)
    }

    /// Two PCs with an app of one name: each is named with its PC.
    func testTwinsAreNamedWithTheirPC() {
        let office = AppLink(host: "office", name: "Notepad", path: #"C:\Notepad.lnk"#)
        let entries = AppDelegate.dockOpenEntries(launchers: [notepad, office], last: nil,
                                                  streaming: nil)
        XCTAssertEqual(Set(entries.map(\.title)), ["Open Notepad on pc", "Open Notepad on office"])
    }

    /// A launcher made before the app's shortcut moved is still the app on
    /// screen, and the same app as the last one: listed once, or not at all.
    func testAnOldShortcutIsStillTheSameApp() {
        let oldNotepad = AppLink(host: "PC", name: "notepad", path: #"C:\Old\Notepad.lnk"#)
        XCTAssertTrue(AppDelegate.dockOpenEntries(launchers: [oldNotepad], last: nil,
                                                  streaming: notepad).isEmpty)
        XCTAssertEqual(AppDelegate.dockOpenEntries(launchers: [oldNotepad, notepad], last: notepad,
                                                   streaming: nil).count, 1)
    }

}
