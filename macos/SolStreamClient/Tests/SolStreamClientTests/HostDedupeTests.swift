import XCTest
@testable import AgentChannel

/// One PC should be one row.
///
/// A machine running SolStream advertises `_nvstream._tcp` twice — SolStream's
/// own Sunshine and whatever the user already had — both under the machine's
/// own hostname, so Bonjour renames the second to "NAME(1)". Seen for real in
/// the connect window: the same PC listed twice, identically, with no way to
/// tell which entry reached which instance.
final class HostDedupeTests: XCTestCase {
    private func host(_ name: String, _ address: String) -> DiscoveredHost {
        DiscoveredHost(name: name, address: address)
    }

    /// Discovery is keyed on the ADDRESS a host answered from, so a machine
    /// cannot appear twice however it names itself.
    ///
    /// It used to be keyed on the Bonjour instance name, which could arrive as
    /// both "DESKTOP-EXAMPLE" and "DESKTOP-EXAMPLE(1)" for one PC — the rename
    /// Bonjour applies when it thinks a name is taken. That produced one machine
    /// on two rows, one of which reached a name that did not resolve, and a
    /// helper existed to collapse them. A host that is discovered by answering
    /// has nothing left to resolve, so there is nothing left to collapse.
    func testRecentsAreHiddenWhenDiscoveryAlreadyFoundTheMachine() {
        let discovered = [host("DESKTOP-EXAMPLE", "192.168.1.40")]
        let recents = ["192.168.1.40", "desktop-example.local", "10.7.0.2"]
        XCTAssertEqual(HostBrowser.recentsWorthShowing(recents, discovered: discovered),
                       ["10.7.0.2"])
    }

    /// The rename suffix is still stripped when matching recents: a Mac that
    /// connected to "PC(1).local" once should not now see it listed beside the
    /// same PC found as "PC".
    func testARenamedRecentStillMatchesTheMachine() {
        let discovered = [host("DESKTOP(1)", "192.168.1.40")]
        XCTAssertEqual(HostBrowser.recentsWorthShowing(["desktop.local"],
                                                       discovered: discovered),
                       [])
    }


    /// A name that merely ends in brackets is not a rename.
    func testBracketsWithoutDigitsAreNotARename() {
        XCTAssertNil(HostBrowser.baseName(of: "Media (Living Room)"))
        XCTAssertNil(HostBrowser.baseName(of: "PC"))
        XCTAssertNil(HostBrowser.baseName(of: "(2)"))
        XCTAssertEqual(HostBrowser.baseName(of: "PC(2)"), "PC")
        XCTAssertEqual(HostBrowser.baseName(of: "PC(11)"), "PC")
    }

}

/// The connect list draws rows from two places — hosts discovered on the network
/// now, and addresses this Mac has connected to before. They overlap, and an
/// exact string match does not notice: seen for real, "DESKTOP-EXAMPLE(1)" from
/// discovery sat directly above "DESKTOP-EXAMPLE.local" from recents.
final class RecentsAgainstDiscoveryTests: XCTestCase {
    private func host(_ name: String, _ address: String) -> DiscoveredHost {
        DiscoveredHost(name: name, address: address)
    }

    func testARecentThatIsAlreadyDiscoveredIsDropped() {
        let rows = HostBrowser.recentsWorthShowing(
            ["DESKTOP-EXAMPLE.local"],
            discovered: [host("DESKTOP-EXAMPLE", "192.168.1.40")])
        XCTAssertTrue(rows.isEmpty)
    }

    /// The case that was actually on screen: discovery only had the renamed
    /// advertisement, and the remembered address used the real hostname.
    func testTheRenamedAdvertisementStillMatchesTheRememberedHostname() {
        let rows = HostBrowser.recentsWorthShowing(
            ["DESKTOP-EXAMPLE.local"],
            discovered: [host("DESKTOP-EXAMPLE(1)", "192.168.1.40")])
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
            discovered: [host("DESKTOP-EXAMPLE", "192.168.1.40")])
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
