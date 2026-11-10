import AppKit
import XCTest
@testable import SolStreamClient

/// The Help menu goes to the project's own pages, and to headings the README
/// really has.
final class HelpMenuTests: XCTestCase {
    func testTheItemsInOrder() {
        let menu = HelpMenu.make(target: AppDelegate(), action: #selector(AppDelegate.openHelpLink(_:)))
        XCTAssertEqual(menu.items.map { $0.isSeparatorItem ? "-" : $0.title },
                       ["SolStream Help", "Troubleshooting", "-",
                        "Get SolStream for Windows", "Report an Issue"])
        for item in menu.items where !item.isSeparatorItem {
            XCTAssertNotNil(item.representedObject as? URL, item.title)
            XCTAssertEqual(item.keyEquivalent, "", "\(item.title): ⌘ keys belong to the PC in a stream")
        }
    }

    func testEveryLinkIsTheProjectsOwn() {
        for link in HelpMenu.links.compactMap({ $0 }) {
            XCTAssertEqual(link.url.scheme, "https", link.title)
            XCTAssertEqual(link.url.host, "github.com", link.title)
            XCTAssertTrue(link.url.path.hasPrefix("/Bruno-Alumn/SolStream"), link.title)
        }
        XCTAssertEqual(HelpMenu.links.compactMap { $0 }.first { $0.title.contains("Windows") }?.url,
                       SetupGuide.windowsDownload)
        XCTAssertEqual(HelpMenu.links.compactMap { $0 }.last?.url.absoluteString,
                       "https://github.com/Bruno-Alumn/SolStream/issues/new")
    }

    /// GitHub anchors a heading by its words, lower case, hyphenated: a
    /// renamed heading would leave the item opening the page's top.
    func testTheReadmeHasTheHeadingsLinkedTo() throws {
        let readme = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let headings = try String(contentsOf: readme, encoding: .utf8)
            .split(separator: "\n")
            .filter { $0.hasPrefix("## ") }
            .map { $0.dropFirst(3).lowercased().replacingOccurrences(of: " ", with: "-") }
        for link in HelpMenu.links.compactMap({ $0 }) {
            guard let anchor = link.url.fragment else { continue }
            XCTAssertTrue(headings.contains(anchor), "README has no heading for #\(anchor)")
        }
    }

    func testHelpStaysOnDuringAStream() {
        XCTAssertTrue(AppDelegate.hostMenuAllows(#selector(AppDelegate.openHelpLink(_:)),
                                                 connected: true, streaming: true))
    }
}
