import AppKit
import XCTest
import DesignSystem
@testable import SolStreamClient

/// The host list, open: what it holds can change under it, and an address
/// being typed into its last row stays.
///
/// Built in a window that is never ordered front, so the list, a child of
/// it, is never on screen either.
final class HostDropdownTests: XCTestCase {
    private func makeDropdown() -> (HostDropdown, NSWindow) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 120),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let dropdown = HostDropdown()
        dropdown.frame = NSRect(x: 20, y: 20, width: 400, height: DS.Metric.rowHeight)
        window.contentView?.addSubview(dropdown)
        dropdown.items = [Self.item("192.168.1.20")]
        dropdown.isDiscovering = false
        addTeardownBlock { dropdown.listWindow.map { window.removeChildWindow($0); $0.orderOut(nil) } }
        return (dropdown, window)
    }

    private static func item(_ address: String) -> HostDropdown.Item {
        HostDropdown.Item(address: address, name: nil, detail: [.words("Used before")],
                          dotState: .idle, kind: .recent)
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    /// The rows marked as the host on show, by their titles.
    private func checkedRows(in panel: NSWindow) -> [String] {
        var found: [String] = []
        func walk(_ view: NSView) {
            if view.isAccessibilitySelected(),
               let title = view.subviews.lazy.compactMap({ $0 as? NSTextField }).first {
                found.append(title.stringValue)
            }
            view.subviews.forEach(walk)
        }
        panel.contentView.map(walk)
        return found
    }

    private func returnKey(in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: "\r",
                         charactersIgnoringModifiers: "\r", isARepeat: false, keyCode: 36)!
    }

    /// The host on show changes under the open list while its rows stay the
    /// same -- the window giving up on one address for another -- and the
    /// list follows without a rebuild: Enter chooses the new host, not the
    /// one it replaced.
    func testAnOpenListFollowsTheHostOnShow() throws {
        let (dropdown, _) = makeDropdown()
        dropdown.items = [Self.item("100.101.102.103"), Self.item("192.168.1.20")]
        dropdown.setSelection(address: "100.101.102.103", name: nil, detail: [], dotState: .live)
        var picked: [String] = []
        dropdown.onPick = { picked.append($0) }
        dropdown.openForTesting()
        let panel = try XCTUnwrap(dropdown.listWindow)
        XCTAssertEqual(checkedRows(in: panel), ["100.101.102.103"])

        dropdown.setSelection(address: "192.168.1.20", name: nil, detail: [], dotState: .live)
        XCTAssertTrue(dropdown.listWindow === panel, "not rebuilt")
        XCTAssertEqual(checkedRows(in: panel), ["192.168.1.20"])
        panel.contentView?.keyDown(with: returnKey(in: panel))
        XCTAssertEqual(picked, ["192.168.1.20"])
    }

    /// The list open, and an address half typed into its last row.
    private func typeIntoTheList(_ dropdown: HostDropdown, _ text: String) throws -> (NSWindow, DS.Field) {
        dropdown.openForTesting()
        let panel = try XCTUnwrap(dropdown.listWindow)
        let field = try XCTUnwrap(find(DS.Field.self, in: panel.contentView))
        panel.makeFirstResponder(field)
        field.currentEditor()?.insertText(text)
        return (panel, field)
    }

    /// Told the same thing again -- as on every refresh of the connect
    /// window -- the open list stays as it is, and so does what is typed.
    func testTheSameRowsAgainLeaveTheListAlone() throws {
        let (dropdown, _) = makeDropdown()
        let (panel, field) = try typeIntoTheList(dropdown, "192.168.1.")

        dropdown.items = [Self.item("192.168.1.20")]
        dropdown.isDiscovering = false
        XCTAssertTrue(dropdown.listWindow === panel, "not rebuilt")
        XCTAssertEqual(field.stringValue, "192.168.1.")
        XCTAssertNotNil(field.currentEditor(), "still being typed into")
    }

    /// New rows rebuild the list, and the address being typed goes over to
    /// the new one, still being typed, with the caret where it was.
    func testANewRowKeepsWhatIsBeingTyped() throws {
        let (dropdown, _) = makeDropdown()
        let (panel, field) = try typeIntoTheList(dropdown, "192.168.1.")
        field.currentEditor()?.selectedRange = NSRange(location: 4, length: 0)

        dropdown.items = [Self.item("192.168.1.20"), Self.item("100.101.102.103")]
        let rebuilt = try XCTUnwrap(dropdown.listWindow)
        XCTAssertFalse(rebuilt === panel, "rebuilt")
        let newField = try XCTUnwrap(find(DS.Field.self, in: rebuilt.contentView))
        XCTAssertEqual(newField.stringValue, "192.168.1.")
        XCTAssertNotNil(newField.currentEditor(), "still being typed into")
        XCTAssertEqual(newField.currentEditor()?.selectedRange, NSRange(location: 4, length: 0))
    }

    /// A list nobody was typing into is rebuilt as it was: on its rows, with
    /// an empty field.
    func testARebuiltListNobodyWasTypingInStaysOnItsRows() throws {
        let (dropdown, _) = makeDropdown()
        dropdown.openForTesting()
        let panel = try XCTUnwrap(dropdown.listWindow)

        dropdown.isDiscovering = true
        let rebuilt = try XCTUnwrap(dropdown.listWindow)
        XCTAssertFalse(rebuilt === panel, "rebuilt")
        let field = try XCTUnwrap(find(DS.Field.self, in: rebuilt.contentView))
        XCTAssertEqual(field.stringValue, "")
        XCTAssertNil(field.currentEditor())
    }
}
