import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// An application asked for from outside the picker is found again by its
/// shortcut, then its name, then -- for a window alone -- its title.
final class AppLinkTests: XCTestCase {
    private func window(_ title: String, id: UInt64 = 1) -> RemoteWindow {
        RemoteWindow(id: id, pid: 100, title: title, className: "Window",
                     x: 0, y: 0, width: 800, height: 600,
                     isOccluded: false, occludedBy: nil, captionInset: 31)
    }

    private let notepad = RemoteApp(name: "Notepad", path: #"C:\ProgramData\Start\Notepad.lnk"#)
    private let teams = RemoteApp(name: "Microsoft Teams", path: #"C:\Start\Microsoft Teams.lnk"#)
    private let teamsShort = RemoteApp(name: "Teams", path: #"C:\Start\Teams.lnk"#)

    func testAnApplicationIsFoundByItsShortcutFirst() {
        let renamed = RemoteApp(name: "Notepad (new)", path: notepad.path)
        let link = AppLink(host: "pc", app: notepad)
        guard case .launch(let app) = link.choice(windows: [], apps: [renamed]) else {
            return XCTFail("the shortcut is the same application under a new name")
        }
        XCTAssertEqual(app, renamed)
    }

    func testThenByItsName() {
        let moved = RemoteApp(name: "notepad", path: #"D:\Elsewhere\Notepad.lnk"#)
        let link = AppLink(host: "pc", app: notepad)
        guard case .launch(let app) = link.choice(windows: [], apps: [moved]) else {
            return XCTFail("the name is the same application in a new place")
        }
        XCTAssertEqual(app, moved)
    }

    func testAnApplicationThatIsGoneIsNotStandInForByAWindow() {
        // A window titled "Notepad" from something else is not Notepad: an
        // installed application's link opens that application or nothing.
        let link = AppLink(host: "pc", app: notepad)
        XCTAssertNil(link.choice(windows: [window("Notepad")], apps: [teams]))
    }

    func testAWindowAloneIsFoundByItsExactTitle() {
        let link = AppLink(host: "pc", name: "Build output")
        guard case .running(let found) = link.choice(windows: [window("Build output (2)", id: 1),
                                                               window("Build output", id: 2)],
                                                     apps: []) else {
            return XCTFail("the window is open")
        }
        XCTAssertEqual(found.id, 2)
        XCTAssertNil(link.choice(windows: [window("Build output (2)")], apps: []))
    }

    func testAnOpenWindowIsKeptAsTheApplicationItSurelyBelongsTo() {
        let link = AppLink.of(.running(window("Untitled - Notepad")), host: "pc",
                              apps: [teams, notepad])
        XCTAssertEqual(link, AppLink(host: "pc", app: notepad))
        // The longest of the names that are sure, not the first.
        XCTAssertEqual(AppLink.of(.running(window("Chat | Microsoft Teams")), host: "pc",
                                  apps: [teamsShort, teams]),
                       AppLink(host: "pc", app: teams))
    }

    func testAWindowNoApplicationOwnsIsKeptByItsTitle() {
        let link = AppLink.of(.running(window("Setup - Steam tips - Google Chrome")), host: "pc",
                              apps: [RemoteApp(name: "Steam", path: "s.lnk")])
        XCTAssertEqual(link, AppLink(host: "pc", name: "Setup - Steam tips - Google Chrome"))
    }

    func testSameApplicationAndSamePC() {
        let link = AppLink(host: "Gaming-PC.", app: notepad)
        XCTAssertTrue(link.sameApp(as: AppLink(host: "gaming-pc", app: notepad)))
        XCTAssertFalse(link.sameApp(as: AppLink(host: "office-pc", app: notepad)))
        XCTAssertFalse(link.sameApp(as: AppLink(host: "gaming-pc", app: teams)))
        XCTAssertTrue(AppLink(host: "pc", name: "Notepad")
            .sameApp(as: AppLink(host: "pc", name: "notepad")))
    }

    func testTheFileRoundTripsAndRefusesWhatIsNotOne() throws {
        let link = AppLink(host: "pc", app: notepad)
        XCTAssertEqual(AppLink.decode(try link.encoded()), link)
        XCTAssertNil(AppLink.decode(Data("not json".utf8)))
        XCTAssertNil(AppLink.decode(Data(#"{"version":2,"link":{"host":"pc","name":"x"}}"#.utf8)),
                     "a later format is not read as this one")
        XCTAssertNil(AppLink.decode(Data(#"{"version":1,"link":{"host":" ","name":"x"}}"#.utf8)))
    }

    func testTheLastOneOpenIsKeptAndForgotten() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "AppLinkTests-\(UUID())"))
        XCTAssertNil(AppLink.last(in: defaults))
        let link = AppLink(host: "pc", app: notepad)
        AppLink.setLast(link, in: defaults)
        XCTAssertEqual(AppLink.last(in: defaults), link)
        AppLink.setLast(nil, in: defaults)
        XCTAssertNil(AppLink.last(in: defaults))
    }

    func testOnlyASmallLinkFileIsOpened() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLinkTests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let link = AppLink(host: "pc", app: notepad)
        let file = folder.appendingPathComponent("App.solstream")
        try link.encoded().write(to: file)
        XCTAssertEqual(AppDelegate.link(at: file), link)

        let wrongKind = folder.appendingPathComponent("App.json")
        try link.encoded().write(to: wrongKind)
        XCTAssertNil(AppDelegate.link(at: wrongKind))

        let huge = folder.appendingPathComponent("Huge.solstream")
        try Data(count: 128 * 1024).write(to: huge)
        XCTAssertNil(AppDelegate.link(at: huge))
    }
}
