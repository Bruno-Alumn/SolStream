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
