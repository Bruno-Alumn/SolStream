import AppKit
import SolStreamLogging
import StreamConnection

/// "Which application?" — shown once the host's agent answers.
///
/// Two kinds of entry, deliberately in one list: windows already open on the
/// host, which are attached to instantly, and applications from its Start Menu,
/// which are launched first. A user thinks "I want Photoshop", not "I want to
/// attach to a window" — so the distinction is a subtitle, not a mode.
final class AppPicker: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    enum Choice {
        case running(RemoteWindow)
        case launch(RemoteApp)
    }

    private struct Row {
        let title: String
        let subtitle: String
        let choice: Choice
    }

    private let window: NSWindow
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let openButton = NSButton(title: "Open", target: nil, action: nil)
    private let spinner = NSProgressIndicator()

    private var allRows: [Row] = []
    private var rows: [Row] = []

    private let onChoose: (Choice) -> Void
    private let onCancel: () -> Void

    init(host: String, onChoose: @escaping (Choice) -> Void, onCancel: @escaping () -> Void) {
        self.onChoose = onChoose
        self.onCancel = onCancel

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 520),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = "Open on \(host)"
        // See AppWindow.build(): a directly-created NSWindow releases itself on
        // close, which double-releases against the strong property below.
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 380, height: 320)

        super.init()

        let heading = NSTextField(labelWithString: "Choose an application")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        searchField.placeholderString = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        searchField.sendsWholeSearchString = false
        searchField.sendsSearchStringImmediately = true

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = 38
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openTapped)
        tableView.style = .inset

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .bezelBorder

        statusLabel.font = .systemFont(ofSize: 11)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.stringValue = "Asking the host what it can run…"

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)

        openButton.bezelStyle = .rounded
        openButton.keyEquivalent = "\r"
        openButton.target = self
        openButton.action = #selector(openTapped)
        openButton.isEnabled = false

        let backButton = NSButton(title: "Back", target: self, action: #selector(backTapped))
        backButton.bezelStyle = .rounded

        let status = NSStackView(views: [spinner, statusLabel])
        status.orientation = .horizontal
        status.spacing = 6

        let buttons = NSStackView(views: [backButton, NSView(), openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, searchField, scrollView, status, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            searchField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -40),
        ])

        window.contentView = content
        window.delegate = self
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(searchField)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.orderOut(nil)
    }

    /// Fill the list. Running windows come first: attaching is instant, and if
    /// the thing you want is already open you almost never want a second copy.
    func present(windows: [RemoteWindow], apps: [RemoteApp]) {
        var built: [Row] = windows.map {
            Row(title: $0.title,
                subtitle: $0.hidesCaptionWhenCropped
                    ? "Running — title bar hidden"
                    : "Running",
                choice: .running($0))
        }
        built += apps.map { Row(title: $0.name, subtitle: "Application", choice: .launch($0)) }

        allRows = built
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "\(windows.count) open, \(apps.count) installed"
        applyFilter()
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
    }

    func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = message
        statusLabel.textColor = .systemRed
    }

    /// Launching is slow — a cold start can take many seconds — so the picker
    /// stays up saying so rather than leaving a dead window on screen.
    func showBusy(_ message: String) {
        spinner.startAnimation(nil)
        statusLabel.textColor = .tertiaryLabelColor
        statusLabel.stringValue = message
        openButton.isEnabled = false
        tableView.isEnabled = false
    }

    func clearBusy() {
        spinner.stopAnimation(nil)
        tableView.isEnabled = true
        openButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Filtering

    @objc private func searchChanged() {
        applyFilter()
    }

    private func applyFilter() {
        let needle = searchField.stringValue.trimmingCharacters(in: .whitespaces)
        rows = needle.isEmpty
            ? allRows
            : allRows.filter { $0.title.localizedCaseInsensitiveContains(needle) }
        tableView.reloadData()
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        openButton.isEnabled = !rows.isEmpty
    }

    // MARK: - Actions

    @objc private func openTapped() {
        let index = tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        onChoose(rows[index].choice)
    }

    @objc private func backTapped() {
        close()
        onCancel()
    }

    func windowWillClose(_ notification: Notification) {
        onCancel()
    }

    // MARK: - Table

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let entry = rows[row]

        let title = NSTextField(labelWithString: entry.title)
        title.font = .systemFont(ofSize: 13)
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: entry.subtitle)
        subtitle.font = .systemFont(ofSize: 10)
        subtitle.textColor = .secondaryLabelColor

        let stack = NSStackView(views: [title, subtitle])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 1
        return stack
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = tableView.selectedRow >= 0
    }
}
