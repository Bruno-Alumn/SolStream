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

    /// A link to the PC's own machine reaches this Mac's if opened here, and
    /// a name and password in a link are only ever a disguise: refused.
    func testLinksToThisMachineOrWithCredentialsAreRefused() {
        for text in ["http://localhost:8080/", "http://LOCALHOST/", "http://127.0.0.1/admin",
                     "http://127.1.2.3/", "http://[::1]:3000/", "http://0.0.0.0/",
                     "http://app.localhost/", "http://[::ffff:127.0.0.1]/",
                     "https://user:pass@example.com/", "https://user@example.com/",
                     "https://@example.com/", "http://localhost:3000@evil.com/",
                     // Every spelling a browser reads as loopback.
                     "http://2130706433/", "http://0x7f000001/", "http://0177.0.0.1/",
                     "http://127.1/", "http://0x7f.1/", "http://0/", "http://localhost./",
                     "http://127.0.0.1./", "http://[0:0::1]/",
                     "http://[0000:0000:0000:0000:0000:0000:0000:0001]/",
                     "http://[::ffff:7f00:1]/", "http://[::127.0.0.1]/", "http://[::1%25lo0]/",
                     "http://[::]/"] {
            XCTAssertNil(AgentConnection.linkToOpen(text), text)
        }
        // Other machines on the network, and names merely starting alike, open.
        for text in ["http://192.168.1.1/", "http://nas.local/", "http://127.example.com/",
                     "https://localhostel.com/", "http://10.0.0.5:8080/", "http://cafe/",
                     "http://deadbeef.de/", "http://[2001:db8::1]/", "http://[::ffff:c0a8:101]/",
                     "http://3232235777/"] {
            XCTAssertNotNil(AgentConnection.linkToOpen(text), text)
        }
    }

    /// A host asking for no token may be talked to only at this machine's
    /// own loopback -- judged by the address dialled.
    func testOnlyLoopbackMayGoWithoutAToken() {
        for address in ["127.0.0.1", "::1", "localhost", "127.0.0.2"] {
            XCTAssertTrue(AgentConnection.mayGoWithoutToken(dialled: address), address)
        }
        for address in ["192.168.1.5", "100.64.0.7", "desktop-pc", "desktop-pc.local",
                        "fd7a:115c::1", "10.0.0.1"] {
            XCTAssertFalse(AgentConnection.mayGoWithoutToken(dialled: address), address)
        }
    }
}
