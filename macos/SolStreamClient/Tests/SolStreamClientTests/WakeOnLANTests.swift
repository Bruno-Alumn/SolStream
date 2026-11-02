import XCTest
@testable import SolStreamClient

/// The magic packet that wakes a sleeping PC, and what is kept to send it.
final class WakeOnLANTests: XCTestCase {
    func testAHardwareAddressIsReadEitherWay() {
        XCTAssertEqual(WakeOnLAN.bytes(of: "0A:1B:C2:00:FF:09"), [0x0A, 0x1B, 0xC2, 0x00, 0xFF, 0x09])
        XCTAssertEqual(WakeOnLAN.bytes(of: "0a-1b-c2-00-ff-09"), [0x0A, 0x1B, 0xC2, 0x00, 0xFF, 0x09])
        XCTAssertNil(WakeOnLAN.bytes(of: "0A:1B:C2:00:FF"), "five bytes")
        XCTAssertNil(WakeOnLAN.bytes(of: "0A:1B:C2:00:FF:GG"))
        XCTAssertNil(WakeOnLAN.bytes(of: "00:00:00:00:00:00"), "no adapter has it")
    }

    func testTheMagicPacketIsSixFFsAndTheAddressSixteenTimes() {
        let mac: [UInt8] = [1, 2, 3, 4, 5, 6]
        let packet = WakeOnLAN.magicPacket(for: mac)
        XCTAssertEqual(packet.count, 102)
        XCTAssertEqual(Array(packet.prefix(6)), [UInt8](repeating: 0xFF, count: 6))
        for copy in 0..<16 {
            XCTAssertEqual(Array(packet[(6 + copy * 6)..<(12 + copy * 6)]), mac)
        }
    }

    func testItGoesEverywhereHereAndToThePCsOwnNetwork() {
        let targets = [WakeOnLAN.Target(mac: "0A:1B:C2:00:FF:09", broadcast: "192.168.1.255"),
                       WakeOnLAN.Target(mac: "0A:1B:C2:00:FF:0A", broadcast: "192.168.1.255"),
                       WakeOnLAN.Target(mac: "0A:1B:C2:00:FF:0B", broadcast: nil)]
        XCTAssertEqual(WakeOnLAN.destinations(for: targets), ["255.255.255.255", "192.168.1.255"])
    }

    func testWhatAPCSaidIsKeptForItAlone() throws {
        let suite = FileManager.default.temporaryDirectory
            .appendingPathComponent("wake-\(UUID().uuidString)").path
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { UserDefaults().removePersistentDomain(forName: suite) }

        XCTAssertEqual(WakeOnLAN.targets(for: "gaming-pc", in: defaults), [])
        let target = WakeOnLAN.Target(mac: "0A:1B:C2:00:FF:09", broadcast: "192.168.1.255")
        WakeOnLAN.setTargets([target, WakeOnLAN.Target(mac: "bad", broadcast: nil)],
                             for: "Gaming-PC", in: defaults)
        XCTAssertEqual(WakeOnLAN.targets(for: "gaming-pc", in: defaults), [target],
                       "by name whatever its case, and without what is not an address")
        XCTAssertEqual(WakeOnLAN.targets(for: "office-pc", in: defaults), [])

        // A PC that now reports none is forgotten.
        WakeOnLAN.setTargets([], for: "gaming-pc", in: defaults)
        XCTAssertEqual(WakeOnLAN.targets(for: "gaming-pc", in: defaults), [])
    }

    /// A PC that reports only the adapter it is up on now keeps the one it
    /// reported before: a desktop connected once over Wi-Fi is still woken
    /// over its cable.
    func testWhatAPCSaysIsAddedToWhatItSaidBefore() {
        let wired = WakeOnLAN.Target(mac: "0A:1B:C2:00:FF:09", broadcast: "192.168.1.255")
        let wifi = WakeOnLAN.Target(mac: "0A:1B:C2:00:FF:0A", broadcast: "192.168.1.255")
        let movedWired = WakeOnLAN.Target(mac: "0a:1b:c2:00:ff:09", broadcast: "10.0.0.255")
        XCTAssertEqual(WakeOnLAN.merged([wired], [wifi]), [wifi, wired])
        XCTAssertEqual(WakeOnLAN.merged([wired, wifi], [movedWired]), [movedWired, wifi],
                       "the newer word on the same adapter wins")
        XCTAssertEqual(WakeOnLAN.merged([wired], []), [wired], "nothing up now forgets nothing")
    }
}
