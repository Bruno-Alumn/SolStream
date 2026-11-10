import XCTest
@testable import SolStreamClient

/// The first-run guide: there only until a pairing succeeds, and ticking its
/// steps off from what the connect window already knows.
final class SetupGuideTests: XCTestCase {

    func testAPairedMacSeesNoGuide() {
        XCTAssertNil(SetupGuide.steps(paired: true, discovered: 0, reachable: nil))
        XCTAssertNil(SetupGuide.steps(paired: true, discovered: 2, reachable: true))
        XCTAssertNil(SetupGuide.steps(paired: true, discovered: 0, reachable: false))
    }

    /// Nothing found yet: installing on the PC is the step to do.
    func testWithNoPCFoundTheFirstStepIsCurrent() {
        let expected: [SetupGuide.Step] = [.current, .upcoming, .upcoming]
        XCTAssertEqual(SetupGuide.steps(paired: false, discovered: 0, reachable: nil), expected)
        XCTAssertEqual(SetupGuide.steps(paired: false, discovered: 0, reachable: false), expected,
                       "a host that is not answering proves nothing about the PC")
    }

    /// A PC that discovery found has SolStream installed and running, so the
    /// first two steps are done and picking it is what is left.
    func testDiscoveringAPCDoesTheFirstTwoSteps() {
        let expected: [SetupGuide.Step] = [.done, .done, .current]
        XCTAssertEqual(SetupGuide.steps(paired: false, discovered: 1, reachable: nil), expected)
        XCTAssertEqual(SetupGuide.steps(paired: false, discovered: 3, reachable: false), expected,
                       "the host on show not answering does not undo another being found")
    }

    /// The same for a host that answered without being discovered: a typed
    /// Tailscale address, which Bonjour never sees.
    func testAHostThatAnsweredDoesTheFirstTwoSteps() {
        XCTAssertEqual(SetupGuide.steps(paired: false, discovered: 0, reachable: true),
                       [.done, .done, .current])
    }
}

/// With Local Network access off, nothing found says nothing about the PC.
final class SetupGuideBlockedSearchTests: XCTestCase {
    func testABlockedSearchDoesNotAskToInstallOnThePC() {
        XCTAssertNil(SetupGuide.steps(paired: false, discovered: 0, reachable: nil,
                                      cannotSearch: true))
        // A PC that answered is still found, and the guide goes on to connect.
        XCTAssertEqual(SetupGuide.steps(paired: false, discovered: 0, reachable: true,
                                        cannotSearch: true), [.done, .done, .current])
        // Unchanged otherwise.
        XCTAssertEqual(SetupGuide.steps(paired: false, discovered: 0, reachable: nil),
                       [.current, .upcoming, .upcoming])
    }

    func testTheLinkOpensLocalNetworkPrivacy() {
        XCTAssertEqual(ConnectHint.localNetworkSettings.scheme, "x-apple.systempreferences")
        XCTAssertTrue(ConnectHint.localNetworkSettings.absoluteString.hasSuffix("Privacy_LocalNetwork"))
        XCTAssertEqual(ConnectHint.localNetworkAction, "Open Local Network Settings")
    }

    /// Offered only for a denied search, steady while a PC is checked, and
    /// not for a PC reached another way.
    func testTheLinkIsForADenialAlone() {
        let offers = ConnectWindow.offersLocalNetworkSettings
        XCTAssertTrue(offers(true, 0, "", nil))
        XCTAssertTrue(offers(true, 0, "192.168.1.5", nil), "while checking")
        XCTAssertTrue(offers(true, 0, "192.168.1.5", false), "not answering: the denial still")
        XCTAssertFalse(offers(false, 0, "", nil), "offline: no setting fixes that")
        XCTAssertFalse(offers(true, 1, "", nil), "something was found")
        XCTAssertFalse(offers(true, 0, "192.168.1.5", true), "the PC answered")
        XCTAssertFalse(offers(true, 0, "100.101.7.42", nil), "Tailscale needs no local network")
        XCTAssertFalse(offers(true, 0, "desk.tail1a2b3c.ts.net", nil))
    }

}
