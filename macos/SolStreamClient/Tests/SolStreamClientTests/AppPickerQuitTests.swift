import AppKit
import XCTest
import DesignSystem
@testable import AgentChannel
@testable import SolStreamClient

/// Quitting an open window's app from the picker: its row's menu, VoiceOver
/// and ⌘⌫ ask for it, an installed app offers none, and a row being quit
/// still goes when the PC's next list leaves it out.
///
/// Built off screen throughout, as `AppPickerTests` is.
final class AppPickerQuitTests: XCTestCase {
    private var quits: [(title: String, force: Bool)] = []
    private var chosen = 0

    private let notepad = RemoteWindow(id: 7, pid: 100, title: "Untitled - Notepad",
                                       className: "Notepad", x: 0, y: 0, width: 800, height: 600,
                                       isOccluded: false, occludedBy: nil, captionInset: 31)
    private let calculator = RemoteApp(name: "Calculator", path: "C:\\Calculator.lnk")

    private func makePicker() -> AppPicker {
        _ = NSApplication.shared
        quits = []
        chosen = 0
        let picker = AppPicker(host: "pc", onChoose: { [weak self] _ in self?.chosen += 1 },
                               onCancel: {})
        picker.onQuit = { [weak self] window, force in self?.quits.append((window.title, force)) }
        picker.present(windows: [notepad], apps: [calculator])
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

    private func commandDelete(isRepeat: Bool = false, in window: NSWindow) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: .command, timestamp: 0,
                         windowNumber: window.windowNumber, context: nil, characters: "\u{7F}",
                         charactersIgnoringModifiers: "\u{7F}", isARepeat: isRepeat, keyCode: 51)!
    }

    private func menu(forRow row: Int, of picker: AppPicker) throws -> NSMenu {
        let table = try XCTUnwrap(find(NSTableView.self, in: picker.window.contentView))
        table.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        let menu = try XCTUnwrap(table.menu)
        // Opened without the mouse, as VoiceOver opens it: the selected row's.
        picker.menuNeedsUpdate(menu)
        return menu
    }

    func testAnOpenWindowsMenuOffersQuitAndForceQuit() throws {
        let picker = makePicker()
        let menu = try menu(forRow: 0, of: picker)
        let titles = menu.items.map(\.title)
        XCTAssertEqual(titles, ["Quit \u{201C}Untitled - Notepad\u{201D} on PC",
                                "Force Quit \u{201C}Untitled - Notepad\u{201D} on PC\u{2026}"])
        XCTAssertTrue(menu.items[1].isAlternate, "Force Quit is under ⌥")

        let quit = menu.items[0]
        _ = (quit.target as? NSObject)?.perform(quit.action, with: quit)
        let force = menu.items[1]
        _ = (force.target as? NSObject)?.perform(force.action, with: force)
        XCTAssertEqual(quits.map(\.force), [false, true])
        XCTAssertEqual(quits.first?.title, "Untitled - Notepad")
    }

    func testAnInstalledAppHasNoQuit() throws {
        let picker = makePicker()
        let menu = try menu(forRow: 1, of: picker)
        XCTAssertTrue(menu.items.isEmpty)
        XCTAssertNil(picker.customActions(for: .launch(calculator)))
    }

    func testVoiceOverOffersTheSameQuit() throws {
        let picker = makePicker()
        let actions = try XCTUnwrap(picker.customActions(for: .running(notepad)))
        XCTAssertEqual(actions.map(\.name), ["Quit \u{201C}Untitled - Notepad\u{201D} on PC",
                                             "Force Quit \u{201C}Untitled - Notepad\u{201D} on PC\u{2026}"])
        _ = actions[0].handler?()
        XCTAssertEqual(quits.map(\.force), [false])
    }

    func testCommandDeleteInTheListQuitsTheSelectedOpenWindow() throws {
        let picker = makePicker()
        let window = picker.window
        let table = try XCTUnwrap(find(NSTableView.self, in: window.contentView))
        window.makeFirstResponder(table)

        table.keyDown(with: commandDelete(isRepeat: true, in: window))
        XCTAssertTrue(quits.isEmpty, "a held key quits nothing")
        table.keyDown(with: commandDelete(in: window))
        XCTAssertEqual(quits.map(\.title), ["Untitled - Notepad"])

        table.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        table.keyDown(with: commandDelete(in: window))
        XCTAssertEqual(quits.count, 1, "an installed app has nothing to quit")
    }

    /// In the field, ⌘⌫ edits what was typed; only an empty field passes it on.
    func testCommandDeleteInTheFieldQuitsOnlyWithNothingTyped() throws {
        let picker = makePicker()
        let window = picker.window
        let field = try XCTUnwrap(find(DS.Field.self, in: window.contentView))
        window.makeFirstResponder(field)
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView)
        let command = #selector(NSResponder.deleteToBeginningOfLine(_:))

        editor.insertText("note")
        XCTAssertFalse(picker.control(field, textView: editor, doCommandBy: command))
        XCTAssertTrue(quits.isEmpty)

        field.stringValue = ""
        XCTAssertTrue(picker.control(field, textView: editor, doCommandBy: command))
        XCTAssertEqual(quits.map(\.title), ["Untitled - Notepad"])
    }

    /// The row being quit is marked and is neither opened nor quit again, and
    /// the PC's list without it still drops it.
    func testARowBeingQuitIsHeldButStillGoes() throws {
        let picker = makePicker()
        let window = picker.window
        let table = try XCTUnwrap(find(NSTableView.self, in: window.contentView))
        window.makeFirstResponder(table)

        picker.setQuitting(notepad, true)
        XCTAssertTrue(picker.isQuitting(notepad))
        table.keyDown(with: commandDelete(in: window))
        XCTAssertTrue(quits.isEmpty, "asked once")
        table.keyDown(with: NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                                             timestamp: 0, windowNumber: window.windowNumber,
                                             context: nil, characters: "\r",
                                             charactersIgnoringModifiers: "\r", isARepeat: false,
                                             keyCode: 36)!)
        XCTAssertEqual(chosen, 0, "not opened on its way out")

        picker.present(windows: [], apps: [calculator])
        XCTAssertEqual(table.numberOfRows, 1)
        XCTAssertFalse(picker.isQuitting(notepad))
    }
}
