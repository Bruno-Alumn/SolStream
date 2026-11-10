import XCTest
@testable import SolStreamClient

/// Settings says what Reopen the last app will open, and what Dock apps
/// there are.
final class SettingsDockAppsTests: XCTestCase {
    func testTheReopenCaption() {
        let notepad = AppLink(host: "gaming-pc", name: "Notepad", path: #"C:\Notepad.lnk"#)
        XCTAssertEqual(SettingsPane.reopenCaption(notepad, on: true), "Next launch: Notepad on gaming-pc.")
        XCTAssertEqual(SettingsPane.reopenCaption(nil, on: true), "Nothing was open at the last quit.")
        XCTAssertEqual(SettingsPane.reopenCaption(notepad, on: false), "SolStream opens on the list of PCs.")
    }

    func testTheDockAppsCaption() {
        XCTAssertTrue(SettingsPane.dockAppsCaption(0).contains("Add to Dock"))
        XCTAssertEqual(SettingsPane.dockAppsCaption(1), "1 app, in Applications › SolStream Apps.")
        XCTAssertEqual(SettingsPane.dockAppsCaption(3), "3 apps, in Applications › SolStream Apps.")
    }

    /// Only launchers that read, and not a crash's staging bundle.
    func testAllReadsOnlyLaunchers() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("SettingsDockApps-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = AppLink(host: "pc", name: "Notepad", path: #"C:\Notepad.lnk"#)
        _ = try AppLauncher.make(link, icon: nil, opener: "com.solstream.test", in: folder)
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("Junk.app"),
                                                withIntermediateDirectories: true)
        XCTAssertEqual(AppLauncher.all(in: folder).map(\.name), ["Notepad"])
    }
}
