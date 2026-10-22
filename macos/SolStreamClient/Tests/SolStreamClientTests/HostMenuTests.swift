import AppKit
import XCTest
@testable import SolStreamClient

/// The Host menu greys out what has nothing to act on, found by the actions'
/// own names, as the menu finds them.
final class HostMenuTests: XCTestCase {
    private let disconnect = NSSelectorFromString("disconnectHost")
    private let switchApp = NSSelectorFromString("switchApp")

    func testDisconnectNeedsSomethingConnected() {
        XCTAssertFalse(AppDelegate.hostMenuAllows(disconnect, connected: false, streaming: false),
                       "nothing to leave: it used to build a second connect window")
        XCTAssertTrue(AppDelegate.hostMenuAllows(disconnect, connected: true, streaming: false))
        XCTAssertTrue(AppDelegate.hostMenuAllows(disconnect, connected: false, streaming: true))
    }

    func testSwitchAppNeedsAStreamWindow() {
        XCTAssertFalse(AppDelegate.hostMenuAllows(switchApp, connected: false, streaming: false))
        XCTAssertFalse(AppDelegate.hostMenuAllows(switchApp, connected: true, streaming: false),
                       "the picker is already the place to switch from")
        XCTAssertTrue(AppDelegate.hostMenuAllows(switchApp, connected: true, streaming: true))
    }

    func testEverythingElseIsLeftOn() {
        let others = [NSSelectorFromString("forgetHosts"), NSSelectorFromString("showSettings"),
                      #selector(NSApplication.orderFrontStandardAboutPanel(_:))]
        for action in others {
            XCTAssertTrue(AppDelegate.hostMenuAllows(action, connected: false, streaming: false),
                          NSStringFromSelector(action))
        }
        XCTAssertTrue(AppDelegate.hostMenuAllows(nil, connected: false, streaming: false))
    }

    /// The names above are the ones the menu is built with: a rename would
    /// otherwise leave these tests passing against nothing.
    func testTheNamesAreTheDelegatesActions() {
        let delegate = AppDelegate()
        XCTAssertTrue(delegate.responds(to: disconnect))
        XCTAssertTrue(delegate.responds(to: switchApp))
    }
}
