import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// What a typed address is dialled as, and where discovery's questions go.
final class DialableAddressTests: XCTestCase {
    /// The PC's port is fixed: one typed with the address is taken off, and
    /// brackets round an IPv6 address, rather than the lot going to the name
    /// lookup and failing as "not answering".
    func testATypedPortOrBracketsAreTakenOff() {
        XCTAssertEqual(ConnectWindow.dialable(" 192.168.1.5:47630 "), "192.168.1.5")
        XCTAssertEqual(ConnectWindow.dialable("desktop-pc:47630"), "desktop-pc")
        XCTAssertEqual(ConnectWindow.dialable("[fd7a:115c::1]"), "fd7a:115c::1")
        XCTAssertEqual(ConnectWindow.dialable("[fd7a:115c::1]:47630"), "fd7a:115c::1")
        // An IPv6 address without brackets has its colons left alone.
        XCTAssertEqual(ConnectWindow.dialable("fd7a:115c::1"), "fd7a:115c::1")
        // Not a port after the colon: left for the lookup to say no to.
        XCTAssertEqual(ConnectWindow.dialable("desktop:pc"), "desktop:pc")
        XCTAssertEqual(ConnectWindow.dialable("100.64.0.7"), "100.64.0.7")
        XCTAssertEqual(ConnectWindow.dialable("   "), "")
        // Only ASCII digits are a port.
        XCTAssertEqual(ConnectWindow.dialable("pc:4²"), "pc:4²")
    }

    /// One broadcast address per IPv4 network the Mac is up on, never the
    /// all-ones one already asked or zero.
    func testInterfaceBroadcastsAreRealAndDistinct() {
        let found = HostBrowser.interfaceBroadcasts()
        XCTAssertEqual(Set(found).count, found.count)
        XCTAssertFalse(found.contains(INADDR_BROADCAST))
        XCTAssertFalse(found.contains(0))
    }

    /// The peer reached decides too: a name in /etc/hosts for an SSH tunnel
    /// leads to loopback, and a token-less agent there is this machine's.
    func testTheReachedPeerIsLoopbackOnlyAt127OrColonColon1() {
        XCTAssertTrue(AgentConnection.isLoopback(.hostPort(host: "127.0.0.1", port: 47630)))
        XCTAssertTrue(AgentConnection.isLoopback(.hostPort(host: "127.9.9.9", port: 47630)))
        XCTAssertTrue(AgentConnection.isLoopback(.hostPort(host: "::1", port: 47630)))
        XCTAssertFalse(AgentConnection.isLoopback(.hostPort(host: "192.168.1.5", port: 47630)))
        XCTAssertFalse(AgentConnection.isLoopback(.hostPort(host: "fd7a:115c::1", port: 47630)))
        XCTAssertFalse(AgentConnection.isLoopback(nil))
    }
}
