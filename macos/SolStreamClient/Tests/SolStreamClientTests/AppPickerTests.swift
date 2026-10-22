import AppKit
import XCTest
import DesignSystem
@testable import AgentChannel
@testable import SolStreamClient

/// The picker's keys: typing with the list focused goes on searching, through
/// the field's own editor, and Escape goes back only on a fresh press.
///
/// Built off screen throughout: the window is never ordered front, so the
/// keys are handed to the list and the field's editor directly.
final class AppPickerTests: XCTestCase {
    private var cancels = 0

    private func makePicker() -> AppPicker {
        _ = NSApplication.shared
        cancels = 0
        let picker = AppPicker(host: "pc", onChoose: { _ in }, onCancel: { [weak self] in self?.cancels += 1 })
        let apps = ["Chrome", "Chess", "Calculator", "Notepad"]
            .map { RemoteApp(name: $0, path: "C:\\\($0).lnk") }
        picker.present(windows: [], apps: apps)
        return picker
    }

    private func find<T: NSView>(_ type: T.Type, in view: NSView?) -> T? {
        guard let view else { return nil }
        if let match = view as? T { return match }
        for child in view.subviews {
            if let match = find(type, in: child) { return match }
        }
        return nil
    }

    private func key(_ characters: String, code: UInt16, modifiers: NSEvent.ModifierFlags = [],
                     ignoringModifiers: String? = nil, isRepeat: Bool = false,
                     in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: characters,
                         charactersIgnoringModifiers: ignoringModifiers ?? characters,
                         isARepeat: isRepeat, keyCode: code)!
    }

    /// Make `event` the one the application is handling, as it is when a key
    /// arrives from the keyboard: the field's Escape asks for it. Posted to
    /// this process's own queue and taken straight back off it.
    private func makeCurrent(_ event: NSEvent) {
        NSApp.postEvent(event, atStart: true)
        let taken = NSApp.nextEvent(matching: .keyDown, until: .distantPast, inMode: .default, dequeue: true)
        XCTAssertTrue(taken === event || taken?.keyCode == event.keyCode)
    }

    // MARK: - Typing with the list focused

    func testTypingWithTheListFocusedAddsToTheSearch() throws {
        let picker = makePicker()
        let window = picker.window
        let field = try XCTUnwrap(find(DS.Field.self, in: window.contentView))
        let table = try XCTUnwrap(find(NSTableView.self, in: window.contentView))

        window.makeFirstResponder(field)
        field.currentEditor()?.insertText("ch")
        XCTAssertEqual(table.numberOfRows, 2, "Chrome and Chess")

        window.makeFirstResponder(table)
        table.keyDown(with: key("r", code: 15, in: window))
        XCTAssertEqual(field.stringValue, "chr", "added to the end, not in place of the query")
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertTrue(field.currentEditor() != nil, "the field has the focus again")
    }

    /// The key is what reaches the field, not the characters it made: Delete
    /// takes a letter back, where inserting its character would add one.
    func testDeleteWithTheListFocusedTakesBackALetter() throws {
        let picker = makePicker()
        let window = picker.window
        let field = try XCTUnwrap(find(DS.Field.self, in: window.contentView))
        let table = try XCTUnwrap(find(NSTableView.self, in: window.contentView))

        window.makeFirstResponder(field)
        field.currentEditor()?.insertText("chr")
        window.makeFirstResponder(table)
        table.keyDown(with: key("\u{7f}", code: 51, in: window))
        XCTAssertEqual(field.stringValue, "ch")
        XCTAssertEqual(table.numberOfRows, 2)
    }

    func testWhatCountsAsTyping() throws {
        let window = makePicker().window
        XCTAssertTrue(AppPicker.isTyping(key("r", code: 15, in: window)))
        XCTAssertTrue(AppPicker.isTyping(key(" ", code: 49, in: window)))
        XCTAssertTrue(AppPicker.isTyping(key("R", code: 15, modifiers: .shift, in: window)))
        XCTAssertTrue(AppPicker.isTyping(key("å", code: 0, modifiers: .option, ignoringModifiers: "a",
                                             in: window)), "Option makes letters")
        XCTAssertTrue(AppPicker.isTyping(key("", code: 14, modifiers: .option, ignoringModifiers: "e",
                                             in: window)), "a dead key types nothing yet")
        XCTAssertTrue(AppPicker.isTyping(key("\u{7f}", code: 51, in: window)), "Delete")

        XCTAssertFalse(AppPicker.isTyping(key("c", code: 8, modifiers: .command, in: window)))
        XCTAssertFalse(AppPicker.isTyping(key("a", code: 0, modifiers: .control, in: window)))
        XCTAssertFalse(AppPicker.isTyping(key("\t", code: 48, in: window)), "Tab moves the focus")
        XCTAssertFalse(AppPicker.isTyping(key("\u{F701}", code: 125, modifiers: [.numericPad, .function],
                                              in: window)), "the arrows move the highlight")
        XCTAssertFalse(AppPicker.isTyping(key("\u{F701}", code: 125, modifiers: [.numericPad, .function, .option],
                                              in: window)), "with Option too")
        XCTAssertFalse(AppPicker.isTyping(key("\u{F704}", code: 122, modifiers: .function, in: window)),
                       "a function key")
    }

    // MARK: - Escape

    func testAHeldEscapeInTheListDoesNotGoBack() throws {
        let picker = makePicker()
        let window = picker.window
        let table = try XCTUnwrap(find(NSTableView.self, in: window.contentView))
        window.makeFirstResponder(table)

        table.keyDown(with: key("\u{1b}", code: 53, isRepeat: true, in: window))
        XCTAssertEqual(cancels, 0, "the key repeating from whatever it closed")
        table.keyDown(with: key("\u{1b}", code: 53, in: window))
        XCTAssertEqual(cancels, 1, "a fresh press goes back")
    }

    func testAHeldEscapeInTheEmptySearchDoesNotGoBack() throws {
        let picker = makePicker()
        let window = picker.window
        let field = try XCTUnwrap(find(DS.Field.self, in: window.contentView))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor())

        let held = key("\u{1b}", code: 53, isRepeat: true, in: window)
        makeCurrent(held)
        editor.keyDown(with: held)
        XCTAssertEqual(cancels, 0)

        let fresh = key("\u{1b}", code: 53, in: window)
        makeCurrent(fresh)
        editor.keyDown(with: fresh)
        XCTAssertEqual(cancels, 1)
    }

    /// Clearing what was typed is not going back, so a repeat may do it.
    func testAHeldEscapeStillClearsTheSearch() throws {
        let picker = makePicker()
        let window = picker.window
        let field = try XCTUnwrap(find(DS.Field.self, in: window.contentView))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor())
        editor.insertText("ch")

        let held = key("\u{1b}", code: 53, isRepeat: true, in: window)
        makeCurrent(held)
        editor.keyDown(with: held)
        XCTAssertEqual(field.stringValue, "")
        XCTAssertEqual(cancels, 0)

        makeCurrent(held)
        editor.keyDown(with: held)
        XCTAssertEqual(cancels, 0, "and the next repeat, with nothing left to clear, stays")
    }
}
