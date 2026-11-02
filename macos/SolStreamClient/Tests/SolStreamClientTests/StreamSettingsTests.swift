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
        XCTAssertTrue(StreamSettings.isRemote(host: "fd7a:115c:a1e0::1234:5678"))
        XCTAssertTrue(StreamSettings.isRemote(host: "[FD7A:115C:A1E0:AB12::1]"))
    }

    func testTheHomeNetworkDoesNot() {
        XCTAssertFalse(StreamSettings.isRemote(host: "192.168.1.20"))
        XCTAssertFalse(StreamSettings.isRemote(host: "10.0.0.5"))
        XCTAssertFalse(StreamSettings.isRemote(host: "100.63.0.1"), "just below Tailscale's range")
        XCTAssertFalse(StreamSettings.isRemote(host: "100.128.0.1"), "just above it")
        XCTAssertFalse(StreamSettings.isRemote(host: "desktop-example.local"))
        XCTAssertFalse(StreamSettings.isRemote(host: "fd00::1"), "another private IPv6 range")
    }

    func testAutomaticQualityStartsLowerOverTailscale() {
        XCTAssertEqual(StreamSettings.VideoQuality.automatic.bitrateKbps(remote: false), 20_000)
        XCTAssertEqual(StreamSettings.VideoQuality.automatic.bitrateKbps(remote: true), 12_000)
        XCTAssertEqual(StreamSettings.VideoQuality.maximum.bitrateKbps(remote: true), 50_000,
                       "an explicit choice is not lowered for the path")
    }

    func testAHiddenTitleBarIsKeptPerProgramAndOffUntilChosen() {
        let key = "SolStream.hiddenTitleBars"
        let saved = UserDefaults.standard.object(forKey: key)
        defer {
            if let saved {
                UserDefaults.standard.set(saved, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        UserDefaults.standard.removeObject(forKey: key)
        let settings = StreamSettings.shared

        XCTAssertFalse(settings.hidesTitleBar(of: "Discord.exe"), "off for every program until chosen")
        settings.setHidesTitleBar(true, of: "Discord.exe")
        XCTAssertTrue(settings.hidesTitleBar(of: "discord.EXE"), "Windows file names ignore case")
        XCTAssertFalse(settings.hidesTitleBar(of: "msedge.exe"), "one program's choice is not another's")
        settings.setHidesTitleBar(true, of: "msedge.exe")
        settings.setHidesTitleBar(false, of: "DISCORD.exe")
        XCTAssertFalse(settings.hidesTitleBar(of: "Discord.exe"))
        XCTAssertTrue(settings.hidesTitleBar(of: "msedge.exe"))
    }

    /// A bare MagicDNS name says nothing; the address it reached does.
    func testTheAddressReachedDecidesForANameThatCannot() {
        XCTAssertEqual(StreamSettings.route(host: "gaming-pc", reached: "100.101.102.103"),
                       "100.101.102.103")
        XCTAssertTrue(StreamSettings.isRemote(host: StreamSettings.route(host: "gaming-pc",
                                                                         reached: "100.64.0.9")))
        XCTAssertEqual(StreamSettings.route(host: "gaming-pc", reached: "192.168.1.20"), "gaming-pc")
        XCTAssertEqual(StreamSettings.route(host: "pc.tailnet.ts.net", reached: nil),
                       "pc.tailnet.ts.net")
    }
}
