import XCTest
@testable import SolStreamClient

/// The "Automatic" choices hinge on telling a Tailscale path from the home
/// network, by address or by MagicDNS name.
final class StreamSettingsTests: XCTestCase {

    func testTailscaleAddressesAndNamesCountAsRemote() {
        XCTAssertTrue(StreamSettings.isRemote(host: "100.101.102.103"))
        XCTAssertTrue(StreamSettings.isRemote(host: "100.64.0.1"))
        XCTAssertTrue(StreamSettings.isRemote(host: "pc.tailnet-1234.ts.net"))
        XCTAssertTrue(StreamSettings.isRemote(host: "PC.Tailnet.TS.NET."))
    }

    func testTheHomeNetworkDoesNot() {
        XCTAssertFalse(StreamSettings.isRemote(host: "192.168.1.20"))
        XCTAssertFalse(StreamSettings.isRemote(host: "10.0.0.5"))
        XCTAssertFalse(StreamSettings.isRemote(host: "100.63.0.1"), "just below Tailscale's range")
        XCTAssertFalse(StreamSettings.isRemote(host: "100.128.0.1"), "just above it")
        XCTAssertFalse(StreamSettings.isRemote(host: "desktop-example.local"))
    }

    func testAutomaticQualityStartsLowerOverTailscale() {
        XCTAssertEqual(StreamSettings.VideoQuality.automatic.bitrateKbps(remote: false), 20_000)
        XCTAssertEqual(StreamSettings.VideoQuality.automatic.bitrateKbps(remote: true), 12_000)
        XCTAssertEqual(StreamSettings.VideoQuality.maximum.bitrateKbps(remote: true), 50_000,
                       "an explicit choice is not lowered for the path")
    }
}
