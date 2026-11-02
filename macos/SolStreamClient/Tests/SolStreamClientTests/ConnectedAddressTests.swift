import Network
import XCTest
@testable import AgentChannel

/// The stream goes to the IPv4 address the agent's connection reached, as
/// dotted digits; anything else leaves it to the name typed.
final class ConnectedAddressTests: XCTestCase {
    func testAnIPv4EndpointIsItsDottedAddress() {
        let endpoint = NWEndpoint.hostPort(host: .ipv4(IPv4Address("192.168.1.21")!), port: 47630)
        XCTAssertEqual(AgentConnection.dottedIPv4(endpoint), "192.168.1.21")
    }

    func testAnythingElseIsNil() {
        XCTAssertNil(AgentConnection.dottedIPv4(nil))
        XCTAssertNil(AgentConnection.dottedIPv4(.hostPort(host: .ipv6(IPv6Address("::1")!), port: 1)))
        XCTAssertNil(AgentConnection.dottedIPv4(.hostPort(host: .name("pc.local", nil), port: 1)))
    }
}
