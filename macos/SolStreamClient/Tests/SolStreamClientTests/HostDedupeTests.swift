import XCTest
@testable import StreamConnection

/// One PC should be one row.
///
/// A machine running SolStream advertises `_nvstream._tcp` twice — SolStream's
/// own Sunshine and whatever the user already had — both under the machine's
/// own hostname, so Bonjour renames the second to "NAME(1)". Seen for real in
/// the connect window: the same PC listed twice, identically, with no way to
/// tell which entry reached which instance.
final class HostDedupeTests: XCTestCase {
    private func host(_ name: String, _ address: String?) -> DiscoveredHost {
        DiscoveredHost(name: name, address: address)
    }

    func testTwoAdvertisementsOfOneMachineCollapse() {
        let rows = HostBrowser.oneRowPerMachine([
            host("DESKTOP-EXAMPLE", "192.168.1.40"),
            host("DESKTOP-EXAMPLE(1)", "192.168.1.40"),
        ])
        XCTAssertEqual(rows.count, 1)
        // The name Bonjour did not have to rename: "PC" reads as the machine,
        // "PC(1)" reads as a mistake.
        XCTAssertEqual(rows.first?.name, "DESKTOP-EXAMPLE")
    }

    /// Order of arrival must not decide which name survives — mDNS makes no
    /// promises about which advertisement resolves first.
    func testTheUnrenamedNameWinsWhicheverArrivesFirst() {
        for pair in [["DESKTOP(1)", "DESKTOP"], ["DESKTOP", "DESKTOP(1)"]] {
            let rows = HostBrowser.oneRowPerMachine([
                host(pair[0], "10.0.0.5"), host(pair[1], "10.0.0.5"),
            ])
            XCTAssertEqual(rows.map(\.name), ["DESKTOP"], "arrival order changed the answer")
        }
    }

    /// Two genuinely different PCs must stay two rows, whatever they are called.
    func testDifferentMachinesAreNotCollapsed() {
        let rows = HostBrowser.oneRowPerMachine([
            host("GAMING-PC", "192.168.1.40"),
            host("OFFICE-PC", "192.168.1.41"),
        ])
        XCTAssertEqual(rows.count, 2)
    }

    /// Even two machines that happen to share a name are two machines. Only the
    /// address identifies one.
    func testSameNameDifferentAddressesStaySeparate() {
        let rows = HostBrowser.oneRowPerMachine([
            host("DESKTOP", "192.168.1.40"),
            host("DESKTOP", "10.7.0.2"),
        ])
        XCTAssertEqual(rows.count, 2)
    }

    /// A host that has not resolved yet keeps its row. Dropping it would hide a
    /// PC that is merely slow to answer, which is worse than a duplicate.
    func testUnresolvedHostsStillAppear() {
        let rows = HostBrowser.oneRowPerMachine([host("SLOW-PC", nil)])
        XCTAssertEqual(rows.map(\.name), ["SLOW-PC"])
    }

    /// But an unresolved "(1)" for a machine already listed is that machine's
    /// second advertisement arriving late, not a new PC.
    func testUnresolvedDuplicateOfAKnownMachineIsDropped() {
        let rows = HostBrowser.oneRowPerMachine([
            host("DESKTOP-EXAMPLE", "192.168.1.40"),
            host("DESKTOP-EXAMPLE(1)", nil),
        ])
        XCTAssertEqual(rows.map(\.name), ["DESKTOP-EXAMPLE"])
    }

    func testRowsAreSortedByName() {
        let rows = HostBrowser.oneRowPerMachine([
            host("ZED", "10.0.0.3"), host("alpha", "10.0.0.1"), host("Mid", "10.0.0.2"),
        ])
        XCTAssertEqual(rows.map(\.name), ["alpha", "Mid", "ZED"])
    }

    /// The case actually seen: neither advertisement resolved, so the rows
    /// showed their ".local" fallbacks and an address-only rule collapsed
    /// nothing. Bonjour's own "(n)" rename has to be enough on its own.
    func testUnresolvedDuplicatesCollapseByTheRenameSuffix() {
        let rows = HostBrowser.oneRowPerMachine([
            host("DESKTOP-EXAMPLE", nil),
            host("DESKTOP-EXAMPLE(1)", nil),
        ])
        XCTAssertEqual(rows.map(\.name), ["DESKTOP-EXAMPLE"])
    }

    /// But a "(n)" that resolved to a DIFFERENT machine is a different machine.
    func testRenamedEntryAtAnotherAddressSurvives() {
        let rows = HostBrowser.oneRowPerMachine([
            host("DESKTOP", "192.168.1.40"),
            host("DESKTOP(1)", "192.168.1.99"),
        ])
        XCTAssertEqual(rows.count, 2)
    }

    /// A name that merely ends in brackets is not a rename.
    func testBracketsWithoutDigitsAreNotARename() {
        XCTAssertNil(HostBrowser.baseName(of: "Media (Living Room)"))
        XCTAssertNil(HostBrowser.baseName(of: "PC"))
        XCTAssertNil(HostBrowser.baseName(of: "(2)"))
        XCTAssertEqual(HostBrowser.baseName(of: "PC(2)"), "PC")
        XCTAssertEqual(HostBrowser.baseName(of: "PC(11)"), "PC")
    }

    func testAMachineNamedWithBracketsIsNotCollapsedAway() {
        let rows = HostBrowser.oneRowPerMachine([
            host("Media (Living Room)", nil),
        ])
        XCTAssertEqual(rows.count, 1)
    }

    func testNothingFoundIsNoRows() {
        XCTAssertTrue(HostBrowser.oneRowPerMachine([]).isEmpty)
    }
}

/// The connect list draws rows from two places — hosts discovered on the network
/// now, and addresses this Mac has connected to before. They overlap, and an
/// exact string match does not notice: seen for real, "DESKTOP-EXAMPLE(1)" from
/// discovery sat directly above "DESKTOP-EXAMPLE.local" from recents.
final class RecentsAgainstDiscoveryTests: XCTestCase {
    private func host(_ name: String, _ address: String?) -> DiscoveredHost {
        DiscoveredHost(name: name, address: address)
    }

    func testARecentThatIsAlreadyDiscoveredIsDropped() {
        let rows = HostBrowser.recentsWorthShowing(
            ["DESKTOP-EXAMPLE.local"],
            discovered: [host("DESKTOP-EXAMPLE", nil)])
        XCTAssertTrue(rows.isEmpty)
    }

    /// The case that was actually on screen: discovery only had the renamed
    /// advertisement, and the remembered address used the real hostname.
    func testTheRenamedAdvertisementStillMatchesTheRememberedHostname() {
        let rows = HostBrowser.recentsWorthShowing(
            ["DESKTOP-EXAMPLE.local"],
            discovered: [host("DESKTOP-EXAMPLE(1)", nil)])
        XCTAssertTrue(rows.isEmpty, "one PC was listed twice")
    }

    /// A remembered IP is the same machine when discovery resolved to it.
    func testARecentAddressMatchesAResolvedHost() {
        let rows = HostBrowser.recentsWorthShowing(
            ["192.168.1.40"],
            discovered: [host("GAMING-PC", "192.168.1.40")])
        XCTAssertTrue(rows.isEmpty)
    }

    /// Hostnames are case-insensitive; the remembered spelling need not match.
    func testMatchingIgnoresCase() {
        let rows = HostBrowser.recentsWorthShowing(
            ["desktop-example.LOCAL"],
            discovered: [host("DESKTOP-EXAMPLE", nil)])
        XCTAssertTrue(rows.isEmpty)
    }

    /// A remembered host that is genuinely elsewhere keeps its row — that is the
    /// whole point of remembering it, since mDNS does not cross subnets.
    func testAnUnrelatedRecentSurvives() {
        let rows = HostBrowser.recentsWorthShowing(
            ["10.7.0.2", "OFFICE-PC.local"],
            discovered: [host("GAMING-PC", "192.168.1.40")])
        XCTAssertEqual(rows, ["10.7.0.2", "OFFICE-PC.local"])
    }

    func testWithNothingDiscoveredEveryRecentSurvives() {
        let recents = ["10.7.0.2", "GAMING-PC.local"]
        XCTAssertEqual(HostBrowser.recentsWorthShowing(recents, discovered: []), recents)
    }

    /// Order is the caller's, not ours: recents are listed most-recent-first.
    func testSurvivingRecentsKeepTheirOrder() {
        let rows = HostBrowser.recentsWorthShowing(
            ["c.local", "a.local", "b.local"], discovered: [])
        XCTAssertEqual(rows, ["c.local", "a.local", "b.local"])
    }
}
