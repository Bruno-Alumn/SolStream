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

    func testAnAddressOnTheTailnetMeansConnectedWhateverIsInstalled() {
        // Installed or not: the daemon can run without the app.
        XCTAssertEqual(TailscaleStatus.decide(addresses: ["10.7.0.2", "100.88.1.4"], installed: false),
                       .connected(address: "100.88.1.4"))
        XCTAssertEqual(TailscaleStatus.decide(addresses: ["100.88.1.4"], installed: true),
                       .connected(address: "100.88.1.4"))
    }

    func testInstalledWithoutAnAddressIsOff() {
        XCTAssertEqual(TailscaleStatus.decide(addresses: ["10.7.0.2"], installed: true), .installedButOff)
        XCTAssertEqual(TailscaleStatus.decide(addresses: [], installed: true), .installedButOff)
    }

    func testNeitherIsMissing() {
        XCTAssertEqual(TailscaleStatus.decide(addresses: ["100.63.0.1", "100.128.0.1"], installed: false),
                       .missing)
        XCTAssertEqual(TailscaleStatus.decide(addresses: [], installed: false), .missing)
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
        }
    }
}
