import XCTest
@testable import AgentChannel

/// `windowOpened`: a window a streamed application opened on the PC, which the
/// host tells only a Mac that lists the push.
final class WindowOpenedTests: XCTestCase {

    private func decode(_ text: String) -> OpenedWindow? {
        guard case .message(let message, _) = AgentConnection.read(line: Data(text.utf8)) else {
            XCTFail("the line did not parse: \(text)")
            return nil
        }
        return AgentConnection.openedWindow(from: message)
    }

    func testAnOwnedDialogIsRead() throws {
        let opened = try XCTUnwrap(decode(
            #"{"type":"windowOpened","id":263412,"parent":131330,"pid":4120,"owned":true,"#
            + #""x":-1200,"y":340,"w":640,"h":480,"title":"Save As"}"#))
        XCTAssertEqual(opened, OpenedWindow(id: 263412, parent: 131330, pid: 4120, owned: true,
                                            x: -1200, y: 340, width: 640, height: 480,
                                            title: "Save As"))
    }

    func testAWindowOpenedByTheMacIsReadWithItsTitle() throws {
        let opened = try XCTUnwrap(decode(
            #"{"type":"windowOpened","id":4294967295,"parent":7,"pid":9,"owned":false,"#
            + #""x":0,"y":0,"w":1280,"h":900,"title":"Sign in — アカウント \"x\""}"#))
        XCTAssertEqual(opened.id, 4_294_967_295)
        XCTAssertEqual(opened.parent, 7)
        XCTAssertFalse(opened.owned)
        XCTAssertEqual(opened.title, "Sign in — アカウント \"x\"")
    }

    func testWithoutAnIdOrAParentItIsNothing() {
        XCTAssertNil(decode(#"{"type":"windowOpened","parent":7,"x":0,"y":0,"w":1,"h":1}"#))
        XCTAssertNil(decode(#"{"type":"windowOpened","id":5,"x":0,"y":0,"w":1,"h":1}"#))
        XCTAssertNil(decode(#"{"type":"windowOpened","id":0,"parent":7}"#))
        XCTAssertNil(decode(#"{"type":"windowOpened","id":"5","parent":7}"#))
        XCTAssertNil(decode(#"{"type":"closed","id":5,"parent":7}"#))
    }

    func testWhatIsMissingReadsAsNothing() throws {
        let opened = try XCTUnwrap(decode(#"{"type":"windowOpened","id":5,"parent":7,"w":-3}"#))
        XCTAssertEqual(opened, OpenedWindow(id: 5, parent: 7, pid: 0, owned: false,
                                            x: 0, y: 0, width: 0, height: 0, title: ""))
    }

    /// Listed, so a host sends it -- and only because it is handled, and
    /// passed over when garbled rather than costing the connection.
    func testItIsListedAndPassedOverWhenGarbled() {
        XCTAssertTrue(AgentConnection.understoodPushes.split(separator: " ")
            .contains("windowOpened"))
        XCTAssertTrue(AgentConnection.skippablePushes.contains("windowOpened"))
        let text = #"{"type":"windowOpened","id":7,"parent":"#
        guard case .unreadablePush(let named) = AgentConnection.read(line: Data(text.utf8)) else {
            return XCTFail("a garbled windowOpened should have been passed over")
        }
        XCTAssertEqual(named, "windowOpened")
    }

    func testResettingTheCallbacksLetsGoOfIt() {
        let agent = AgentConnection(host: "::1", port: 1)
        agent.onWindowOpened = { _ in }
        agent.resetCallbacks()
        XCTAssertNil(agent.onWindowOpened)
    }
}
