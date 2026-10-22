import XCTest
@testable import SolStreamClient

/// The connect window recommends Tailscale only to a Mac that is not on it,
/// and says which of the two things to do: install it, or switch it on.
final class TailscaleTests: XCTestCase {

    /// 100.64.0.0/10 and nothing either side of it.
    func testTheRangeIsExactlyTailscales() {
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("100.63.255.255"), "just below")
        XCTAssertTrue(TailscaleStatus.isTailscaleAddress("100.64.0.0"), "the first address")
        XCTAssertTrue(TailscaleStatus.isTailscaleAddress("100.101.102.103"))
        XCTAssertTrue(TailscaleStatus.isTailscaleAddress("100.127.255.255"), "the last address")
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("100.128.0.0"), "just above")
    }

    func testOnlyAWellFormedAddressCounts() {
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("192.168.1.20"))
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("10.0.0.5"))
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("100.64.0"))
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("100.64.0.1.5"))
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("100.64.0.256"))
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("100.64..1"))
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("100.+64.0.1"))
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress("pc.tailnet-1234.ts.net"),
                       "a name is the caller's business; this sees only addresses")
        XCTAssertFalse(TailscaleStatus.isTailscaleAddress(""))
    }

    /// fd7a:115c:a1e0::/48, however it is written, and nothing either side.
    func testTailscalesIPv6Prefix() {
        XCTAssertTrue(TailscaleStatus.isTailscaleIPv6("fd7a:115c:a1e0::1"))
        XCTAssertTrue(TailscaleStatus.isTailscaleIPv6("fd7a:115c:a1e0:ab12:4843:cd96:6258:b240"))
        XCTAssertTrue(TailscaleStatus.isTailscaleIPv6("FD7A:115C:A1E0::1"))
        XCTAssertTrue(TailscaleStatus.isTailscaleIPv6("fd7a:115c:a1e0::1%utun4"), "a scope is not the address")
        XCTAssertFalse(TailscaleStatus.isTailscaleIPv6("fd7a:115c:a1e1::1"))
        XCTAssertFalse(TailscaleStatus.isTailscaleIPv6("fd7a:115c:a1df:ffff::1"))
        XCTAssertFalse(TailscaleStatus.isTailscaleIPv6("fe80::1%utun4"))
        XCTAssertFalse(TailscaleStatus.isTailscaleIPv6("100.88.1.4"))
        XCTAssertFalse(TailscaleStatus.isTailscaleIPv6("::ffff:100.88.1.4"))
        XCTAssertFalse(TailscaleStatus.isTailscaleIPv6("fd7a:115c:a1e0::1::2"))
        XCTAssertFalse(TailscaleStatus.isTailscaleIPv6(""))
    }

    /// The link-local address every tunnel carries is not one it was given.
    func testOnlyAnIPv6AddressATunnelWasGivenIsItsOwn() {
        XCTAssertFalse(TailscaleStatus.isOwnIPv6("fe80::1:2:3:4%utun4"))
        XCTAssertFalse(TailscaleStatus.isOwnIPv6("febf::1"), "the end of fe80::/10")
        XCTAssertTrue(TailscaleStatus.isOwnIPv6("fec0::1"), "just past it")
        XCTAssertTrue(TailscaleStatus.isOwnIPv6("fd7a:115c:a1e0::1"))
        XCTAssertTrue(TailscaleStatus.isOwnIPv6("2606:4700:110:8a36::2"))
        XCTAssertFalse(TailscaleStatus.isOwnIPv6("100.88.1.4"))
    }

    func testTailscalesTunnelMeansConnectedWhateverIsInstalled() {
        // Installed or not: the daemon can run without the app.
        let tunnels = [["10.7.0.2"], ["fe80::1%utun4", "100.88.1.4", "fd7a:115c:a1e0::1"]]
        XCTAssertEqual(TailscaleStatus.decide(tunnels: tunnels, installed: false),
                       .connected(address: "100.88.1.4"))
        XCTAssertEqual(TailscaleStatus.decide(tunnels: tunnels, installed: true),
                       .connected(address: "100.88.1.4"))
    }

    /// NetBird: the range on a tunnel with nothing but the link-local IPv6
    /// address. Cloudflare WARP: the range beside an IPv6 address of its own
    /// that is not Tailscale's.
    func testAnotherVPNInTheSameRangeIsNotTailscale() {
        let netBird = [["fe80::1%utun100", "100.92.3.4"]]
        XCTAssertEqual(TailscaleStatus.decide(tunnels: netBird, installed: false), .missing)
        let warp = [["100.96.0.2", "2606:4700:110:8a36::2", "fe80::1%utun5"]]
        XCTAssertEqual(TailscaleStatus.decide(tunnels: warp, installed: false), .missing)
        XCTAssertEqual(TailscaleStatus.decide(tunnels: warp, installed: true), .installedButOff)
    }

    /// Tailscale's prefix counts on the same tunnel as the address, not on
    /// another one.
    func testThePrefixMustBeOnTheSameTunnel() {
        let tunnels = [["100.92.3.4"], ["fd7a:115c:a1e0::1"]]
        XCTAssertEqual(TailscaleStatus.decide(tunnels: tunnels, installed: false), .missing)
    }

    /// A tailnet without IPv6 looks like NetBird, so its address counts only
    /// where Tailscale is installed.
    func testWithoutIPv6TheRangeCountsWhereTailscaleIsInstalled() {
        let tunnels = [["fe80::1%utun4", "100.88.1.4"]]
        XCTAssertEqual(TailscaleStatus.decide(tunnels: tunnels, installed: true),
                       .connected(address: "100.88.1.4"))
        XCTAssertEqual(TailscaleStatus.decide(tunnels: tunnels, installed: false), .missing)
    }

    /// Tailscale's own tunnel wins over a guess at another one, wherever it
    /// comes in the list.
    func testTheSureTunnelWinsOverAGuess() {
        let tunnels = [["100.92.3.4"], ["100.88.1.4", "fd7a:115c:a1e0::1"]]
        XCTAssertEqual(TailscaleStatus.decide(tunnels: tunnels, installed: true),
                       .connected(address: "100.88.1.4"))
    }

    func testInstalledWithoutAnAddressIsOff() {
        XCTAssertEqual(TailscaleStatus.decide(tunnels: [["10.7.0.2"]], installed: true), .installedButOff)
        XCTAssertEqual(TailscaleStatus.decide(tunnels: [["fe80::1%utun4"]], installed: true),
                       .installedButOff)
        XCTAssertEqual(TailscaleStatus.decide(tunnels: [], installed: true), .installedButOff)
    }

    func testNeitherIsMissing() {
        XCTAssertEqual(TailscaleStatus.decide(tunnels: [["100.63.0.1", "100.128.0.1", "fd7a:115c:a1e0::1"]],
                                              installed: false),
                       .missing)
        XCTAssertEqual(TailscaleStatus.decide(tunnels: [], installed: false), .missing)
    }

    /// Connected says nothing; the other two say what to do, with the button
    /// that does it.
    func testWhatEachOneSays() {
        XCTAssertNil(TailscaleStatus.connected(address: "100.88.1.4").advice)
        XCTAssertEqual(TailscaleStatus.installedButOff.advice?.action, "Open Tailscale")
        XCTAssertEqual(TailscaleStatus.installedButOff.advice?.words,
                       "Tailscale is installed but off. Turn it on to reach your PC away from home.")
        XCTAssertEqual(TailscaleStatus.missing.advice?.action, "Get Tailscale")
        XCTAssertEqual(TailscaleStatus.missing.advice?.words,
                       "Away from home? Tailscale connects this Mac and your PC from anywhere, free.")
    }

    /// The real reading runs without a fault and only ever reports what the
    /// classifier would accept, whatever this Mac happens to be on.
    func testTheRealReadingIsConsistent() {
        if case .connected(let address) = TailscaleStatus.current() {
            XCTAssertTrue(TailscaleStatus.isTailscaleAddress(address))
            XCTAssertTrue(TailscaleStatus.tunnels().contains { $0.contains(address) })
        }
    }
}
