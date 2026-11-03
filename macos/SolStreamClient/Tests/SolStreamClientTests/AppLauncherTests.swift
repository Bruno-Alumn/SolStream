import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// A launcher is a folder SolStream writes: what is in it, and what it is
/// called. Made in a temporary folder; nothing here touches the Dock.
final class AppLauncherTests: XCTestCase {
    private var folder: URL!
    private let notepad = AppLink(host: "gaming-pc",
                                  app: RemoteApp(name: "Notepad", path: #"C:\Start\Notepad.lnk"#))

    override func setUpWithError() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("AppLauncherTests-\(UUID())", isDirectory: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: folder)
    }

    private func icon(_ side: Int, margin: Int = 0) -> CGImage {
        let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(srgbRed: 0.1, green: 0.4, blue: 0.9, alpha: 1))
        context.fill(CGRect(x: margin, y: margin, width: side - 2 * margin, height: side - 2 * margin))
        return context.makeImage()!
    }

    func testALauncherHandsItsLinkToThisSolStream() throws {
        let launcher = try AppLauncher.make(notepad, icon: icon(64), opener: "com.example.solstream",
                                            in: folder)
        XCTAssertEqual(launcher.lastPathComponent, "Notepad (PC).app")

        let contents = launcher.appendingPathComponent("Contents")
        let plistData = try Data(contentsOf: contents.appendingPathComponent("Info.plist"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil)
            as? [String: Any])
        XCTAssertEqual(plist["CFBundleExecutable"] as? String, "launch")
        XCTAssertEqual(plist["CFBundleName"] as? String, "Notepad (PC)")
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        XCTAssertTrue((plist["CFBundleIdentifier"] as? String)?.hasPrefix("com.example.solstream.app.") == true)

        let script = contents.appendingPathComponent("MacOS/launch")
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: script.path))
        let text = try String(contentsOf: script, encoding: .utf8)
        XCTAssertTrue(text.hasPrefix("#!/bin/sh\n"))
        XCTAssertTrue(text.contains("/usr/bin/open -b 'com.example.solstream' "
                                    + "\"$(dirname \"$0\")/../Resources/App.solstream\""))

        XCTAssertEqual(AppLauncher.link(inLauncher: launcher), notepad)
        let icns = contents.appendingPathComponent("Resources/AppIcon.icns")
        XCTAssertGreaterThan(try Data(contentsOf: icns).count, 10_000)
    }

    /// The same app -- the same shortcut on the same PC -- made again, with
    /// its PC written another way, replaces its own launcher.
    func testMakingItAgainReplacesItInPlace() throws {
        let first = try AppLauncher.make(notepad, icon: nil, opener: "x", in: folder)
        var again = notepad
        again.host = "Gaming-PC."
        let second = try AppLauncher.make(again, icon: nil, opener: "x", in: folder)
        XCTAssertEqual(first, second)
        XCTAssertEqual(AppLauncher.link(inLauncher: second), again)
        let left = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(left, ["Notepad (PC).app"], "no staging folder is left behind")
    }

    func testTheSameAppOnAnotherPCIsNamedAfterThatPC() throws {
        _ = try AppLauncher.make(notepad, icon: nil, opener: "x", in: folder)
        var office = notepad
        office.host = "office-pc"
        let other = try AppLauncher.make(office, icon: nil, opener: "x", in: folder)
        XCTAssertEqual(other.lastPathComponent, "Notepad (office-pc).app")
        XCTAssertEqual(AppLauncher.link(inLauncher: folder.appendingPathComponent("Notepad (PC).app")),
                       notepad, "the first PC's launcher is left alone")
    }

    func testFileNamesFinderTakes() {
        XCTAssertEqual(AppLauncher.fileName("AC/DC: Live"), "AC-DC- Live")
        XCTAssertEqual(AppLauncher.fileName("..hidden"), "hidden")
        XCTAssertEqual(AppLauncher.fileName("  "), "App")
        XCTAssertEqual(AppLauncher.fileName(String(repeating: "a", count: 200)).utf8.count, 120)
        // Cut by bytes, which the file system counts, between characters.
        let emoji = AppLauncher.fileName(String(repeating: "🎮", count: 60))
        XCTAssertLessThanOrEqual(emoji.utf8.count, 120)
        XCTAssertTrue(emoji.allSatisfy { $0 == "🎮" })
        // Nothing that disguises a name.
        XCTAssertEqual(AppLauncher.fileName("evil\u{202E}gpj.exe"), "evilgpj.exe")
    }

    /// An app the PC renamed keeps its launcher -- found by what it opens,
    /// under its old name -- rather than gaining a second with the same id.
    func testARenamedAppKeepsItsLauncher() throws {
        let first = try AppLauncher.make(notepad, icon: nil, opener: "x", in: folder)
        var renamed = notepad
        renamed.name = "Notepad Classic"
        let second = try AppLauncher.make(renamed, icon: nil, opener: "x", in: folder)
        XCTAssertEqual(first, second)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path).count, 1)
    }

    /// Forget Paired PCs takes SolStream's launchers, and only those.
    func testRemovingLaunchersTakesOnlyOurs() throws {
        _ = try AppLauncher.make(notepad, icon: nil, opener: "x", in: folder)
        let foreign = folder.appendingPathComponent("Other.app", isDirectory: true)
        try FileManager.default.createDirectory(at: foreign, withIntermediateDirectories: true)
        XCTAssertEqual(AppLauncher.removeAll(in: folder), 1)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: folder.path), ["Other.app"])
    }

    func testTheIdentifierIsTheSameEachTimeAndDiffersPerPC() {
        let a = AppLauncher.identifier(for: notepad, opener: "o")
        XCTAssertEqual(a, AppLauncher.identifier(for: notepad, opener: "o"))
        var office = notepad
        office.host = "office-pc"
        XCTAssertNotEqual(a, AppLauncher.identifier(for: office, opener: "o"))
    }

    func testAQuoteInTheOpenerCannotEndTheScriptsString() {
        let script = AppLauncher.script(for: notepad, opener: "a'b")
        XCTAssertTrue(script.contains(#"-b 'a'\''b' "#))
    }

    func testAnIconsEmptyMarginIsTrimmedToASquare() throws {
        let trimmed = try XCTUnwrap(AppLauncher.trimmed(icon(256, margin: 96)))
        XCTAssertEqual(trimmed.width, 64)
        XCTAssertEqual(trimmed.height, 64)
        XCTAssertNil(AppLauncher.trimmed(icon(16, margin: 8)), "nothing drawn is no icon")
    }

    func testTheTileIsDrawnWithOrWithoutAnIcon() {
        XCTAssertEqual(AppLauncher.icon(from: icon(64), badge: nil, name: "Steam")?.width, 1024)
        XCTAssertEqual(AppLauncher.icon(from: nil, badge: icon(512), name: "Steam")?.width, 1024)
    }

    func testFindingATileInTheDocksList() {
        let tile: [String: Any] = ["tile-data": ["file-data": ["_CFURLString": "file:///A.app/"]]]
        XCTAssertEqual(AppLauncher.url(ofTile: tile), "file:///A.app/")
        XCTAssertNil(AppLauncher.url(ofTile: ["tile-type": "spacer-tile"]))
    }

    /// Two apps of one name on one PC get a launcher each.
    func testTwoAppsOfOneNameGetALauncherEach() throws {
        _ = try AppLauncher.make(notepad, icon: nil, opener: "x", in: folder)
        let other = AppLink(host: "gaming-pc", name: "Notepad", path: #"C:\Other\Notepad.lnk"#)
        let second = try AppLauncher.make(other, icon: nil, opener: "x", in: folder)
        XCTAssertNotEqual(second.lastPathComponent, "Notepad (PC).app")
        XCTAssertEqual(AppLauncher.link(inLauncher: folder.appendingPathComponent("Notepad (PC).app")),
                       notepad, "the first app's launcher is left alone")
        // And each is found again as its own.
        XCTAssertEqual(try AppLauncher.make(other, icon: nil, opener: "x", in: folder), second)
    }
}
