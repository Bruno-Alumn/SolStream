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

    func testMakingItAgainReplacesItInPlace() throws {
        let first = try AppLauncher.make(notepad, icon: nil, opener: "x", in: folder)
        var renamed = notepad
        renamed.path = #"C:\Elsewhere\Notepad.lnk"#
        let second = try AppLauncher.make(renamed, icon: nil, opener: "x", in: folder)
        XCTAssertEqual(first, second)
        XCTAssertEqual(AppLauncher.link(inLauncher: second), renamed)
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
        XCTAssertEqual(AppLauncher.fileName(String(repeating: "a", count: 100)).count, 60)
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
        XCTAssertEqual(AppLauncher.icon(from: icon(64), badge: nil)?.width, 1024)
        XCTAssertEqual(AppLauncher.icon(from: nil, badge: icon(512))?.width, 1024)
    }

    func testFindingATileInTheDocksList() {
        let tile: [String: Any] = ["tile-data": ["file-data": ["_CFURLString": "file:///A.app/"]]]
        XCTAssertEqual(AppLauncher.url(ofTile: tile), "file:///A.app/")
        XCTAssertNil(AppLauncher.url(ofTile: ["tile-type": "spacer-tile"]))
    }
}
