import XCTest
@testable import AgentChannel

/// Which links from the PC this Mac opens: web and mail, nothing else.
final class LinkFromPCTests: XCTestCase {

    func testWebAndMailLinksOpen() {
        XCTAssertNotNil(AgentConnection.linkToOpen("https://example.com/a?b=c"))
        XCTAssertNotNil(AgentConnection.linkToOpen("HTTP://example.com"))
        XCTAssertNotNil(AgentConnection.linkToOpen("mailto:someone@example.com"))
    }

    /// Whatever the host sends, nothing that runs or reads something on the Mac.
    func testAnythingElseIsRefused() {
        for text in ["file:///etc/passwd", "javascript:alert(1)", "ssh://host",
                     "x-apple.systempreferences:", "smb://server/share", "https://",
                     "mailto:", "https://example.com/a b", "https://example.com/\n", "",
                     "https://example.com/" + String(repeating: "a", count: 9000)] {
            XCTAssertNil(AgentConnection.linkToOpen(text), text)
        }
    }
}
