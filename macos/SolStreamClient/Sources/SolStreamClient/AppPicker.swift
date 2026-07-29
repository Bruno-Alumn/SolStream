import AppKit
import DesignSystem
import SolStreamLogging
import MediaSession
import StreamConnection

/// "Which application?"
///
/// One ranked list, no modes and no group headers. Windows already open sort
/// first, carry a live dot and say "Attach"; installed applications say "Launch".
/// Typing re-ranks the whole list by match score with open windows keeping a
/// bonus, because the thing you can see is usually the thing you meant.
final class AppPicker: NSObject, NSWindowDelegate, NSTableViewDataSource, NSTableViewDelegate {

    enum Choice {
        case running(RemoteWindow)
        case launch(RemoteApp)
    }

    private struct Row {
        let title: String
        let subtitle: String
        /// Stable across the list, so the tile colour never depends on position.
        let key: String
        let isRunning: Bool
        /// The application paints its own window buttons, which the crop cannot
        /// remove without taking its tabs with them.
        let drawsOwnControls: Bool
        let choice: Choice
        var score: Int = 0
    }

    /// Not private: the token sheet hangs off it, so that asking for a token
    /// happens on the window the person is already looking at.
    let window: NSWindow
    private let searchField = DS.Field(placeholder: "")
    /// The search row: the field plus its shortcut hint, on the design's plain
    /// surface rather than NSSearchField's own bezel and magnifier.
    private let searchRow = NSView()
    private let tableView = NSTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "↩ to open")
    private let spinner = NSProgressIndicator()
    private let backButton: DS.OutlinedButton
    private let openButton: DS.OutlinedButton

    private var allRows: [Row] = []
    private var rows: [Row] = []
    private var busyRow: Int?
    private var iconCache: [String: CGImage] = [:]
    private var requestedIcons: Set<String> = []
    /// Set by the owner so rows can ask the host for their icon.
    weak var agent: AgentConnection?

    private let onChoose: (Choice) -> Void
    private let onCancel: () -> Void

    init(host: String, onChoose: @escaping (Choice) -> Void, onCancel: @escaping () -> Void) {
        self.onChoose = onChoose
        self.onCancel = onCancel
        backButton = DS.OutlinedButton(title: "Back", target: nil, action: nil)
        openButton = DS.OutlinedButton(title: "Open", primary: true, target: nil, action: nil)

        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 560),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable],
                          backing: .buffered, defer: false)
        window.title = host
        window.subtitle = "Choose an application"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DS.ground
        window.minSize = NSSize(width: 420, height: 380)

        super.init()
        build(host: host)
        window.delegate = self
    }

    private func build(host: String) {
        searchField.placeholderString = "Search windows and apps on \(host)"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // Filter as it is typed rather than on Return: the list is the answer,
        // so making the user commit to see it would be a step for nothing.
        searchField.delegate = self

        let searchHint = NSTextField(labelWithString: "⌘F")
        searchHint.font = DS.monoSmall
        searchHint.textColor = DS.textMuted
        searchHint.translatesAutoresizingMaskIntoConstraints = false

        searchRow.wantsLayer = true
        searchRow.layer?.backgroundColor = DS.chrome.cgColor
        searchRow.layer?.cornerRadius = DS.Metric.rowCorner
        searchRow.layer?.cornerCurve = .continuous
        searchRow.translatesAutoresizingMaskIntoConstraints = false
        searchRow.addSubview(searchField)
        searchRow.addSubview(searchHint)
        NSLayoutConstraint.activate([
            searchRow.heightAnchor.constraint(equalToConstant: 38),
            searchField.leadingAnchor.constraint(equalTo: searchRow.leadingAnchor, constant: 12),
            searchField.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
            searchField.trailingAnchor.constraint(equalTo: searchHint.leadingAnchor, constant: -8),
            searchHint.trailingAnchor.constraint(equalTo: searchRow.trailingAnchor, constant: -12),
            searchHint.centerYAnchor.constraint(equalTo: searchRow.centerYAnchor),
        ])

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = DS.Metric.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        tableView.doubleAction = #selector(openTapped)
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.gridStyleMask = []

        scrollView.documentView = tableView
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder

        statusLabel.font = DS.monoSmall
        statusLabel.textColor = DS.textFaint
        statusLabel.stringValue = "asking the host what it can run…"
        // A failure message is a sentence, not a label. Left to size itself the
        // window grew wider than the screen to fit one on a single line, and the
        // end of the message — the part that says what to do — went off the
        // right edge where it could not be read at all.
        statusLabel.lineBreakMode = .byWordWrapping
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.preferredMaxLayoutWidth = 380
        hintLabel.font = DS.monoSmall
        hintLabel.textColor = DS.textFaint
        hintLabel.alignment = .right

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false
        spinner.startAnimation(nil)

        openButton.target = self
        openButton.action = #selector(openTapped)
        openButton.keyEquivalent = "\r"
        openButton.isEnabled = false
        backButton.target = self
        backButton.action = #selector(backTapped)

        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let footer = NSStackView(views: [spinner, statusLabel, footerSpacer, hintLabel])
        footer.orientation = .horizontal
        footer.spacing = 7

        let buttonSpacer = NSView()
        buttonSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [backButton, buttonSpacer, openButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [searchRow, scrollView,
                                        DS.hairlineView(), footer, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.setCustomSpacing(8, after: scrollView)
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 22, bottom: 20, right: 22)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for view in [searchRow, scrollView, footer, buttons] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -44).isActive = true
        }
        window.contentView = content
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

    // MARK: - Contents

    func present(windows: [RemoteWindow], apps: [RemoteApp]) {
        // This is now a refresh as well as a first fill: the host says whenever a
        // window opens or closes anywhere on the PC. Two things follow.
        //
        // A launch already under way owns the list — the row is showing its
        // progress and the window it is waiting for is about to appear, which
        // would rebuild the list out from under it.
        guard busyRow == nil else { return }
        // And nobody asked for this refresh, so it must not move the selection.
        // applyFilter drops it back to the first row, which is right when the
        // person is typing and wrong when something opened Notepad on the PC
        // while they were arrowing down the list.
        let keepKey = tableView.selectedRow >= 0 && tableView.selectedRow < rows.count
            ? rows[tableView.selectedRow].key : nil

        var built: [Row] = windows.map {
            // Annotate the exception, not the rule. A Windows-drawn title bar is
            // the normal case and is simply cropped away, so saying "title bar
            // hidden" on nearly every row told the user nothing — and read as a
            // claim about the window's state on the PC right now, which it never
            // was. What is worth flagging is the opposite: an application that
            // draws its own caption inside the client area, whose minimise and
            // close buttons therefore arrive inside the stream.
            Row(title: $0.title,
                subtitle: $0.hidesCaptionWhenCropped ? "open" : "open · has its own window buttons",
                key: "\($0.className)/\($0.id)",
                isRunning: true,
                drawsOwnControls: !$0.hidesCaptionWhenCropped,
                choice: .running($0))
        }
        built += apps.map {
            Row(title: $0.name, subtitle: "application", key: $0.path,
                isRunning: false, drawsOwnControls: false, choice: .launch($0))
        }

        allRows = built
        spinner.stopAnimation(nil)
        statusLabel.stringValue = "\(windows.count) window\(windows.count == 1 ? "" : "s") open"
            + " · \(apps.count) app\(apps.count == 1 ? "" : "s") installed"
        statusLabel.textColor = DS.textMuted
        applyFilter()
        if let keepKey, let again = rows.firstIndex(where: { $0.key == keepKey }) {
            tableView.selectRowIndexes(IndexSet(integer: again), byExtendingSelection: false)
            tableView.scrollRowToVisible(again)
        }
    }

    func showFailure(_ message: String) {
        spinner.stopAnimation(nil)
        statusLabel.stringValue = message
        statusLabel.textColor = DS.accentBright
    }

    /// A launch is slow — a cold start is many seconds — so the row grows a
    /// progress line in place rather than a modal taking the window over. The
    /// list stays interactive; nothing about it moves.
    func showBusy(_ message: String) {
        spinner.startAnimation(nil)
        statusLabel.textColor = DS.textMuted
        statusLabel.stringValue = message
        openButton.isEnabled = false
        busyRow = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        if let busyRow { tableView.reloadData(forRowIndexes: [busyRow], columnIndexes: [0]) }
    }

    func clearBusy() {
        spinner.stopAnimation(nil)
        let previous = busyRow
        busyRow = nil
        if let previous, previous < rows.count {
            tableView.reloadData(forRowIndexes: [previous], columnIndexes: [0])
        }
        openButton.isEnabled = tableView.selectedRow >= 0
    }

    // MARK: - Ranking

    @objc private func searchChanged() { applyFilter() }

    private func applyFilter() {
        let needle = searchField.stringValue.trimmingCharacters(in: .whitespaces).lowercased()
        var scored: [Row] = []
        for var row in allRows {
            guard !needle.isEmpty else {
                // No query: open windows first, each group alphabetical.
                row.score = row.isRunning ? 1_000 : 0
                scored.append(row)
                continue
            }
            guard let score = Self.match(row.title.lowercased(), needle) else { continue }
            // An open window keeps a bonus: what you can see is usually what you
            // meant, and attaching is instant where launching is not.
            row.score = score + (row.isRunning ? 40 : 0)
            scored.append(row)
        }
        rows = scored.sorted {
            $0.score != $1.score ? $0.score > $1.score
                : $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending
        }
        tableView.reloadData()
        if !rows.isEmpty {
            tableView.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        }
        openButton.isEnabled = !rows.isEmpty
    }

    /// Prefix beats word-start beats substring; nil means no match at all.
    static func match(_ haystack: String, _ needle: String) -> Int? {
        guard !needle.isEmpty else { return 0 }
        guard let range = haystack.range(of: needle) else { return nil }
        if range.lowerBound == haystack.startIndex { return 100 }
        let before = haystack[haystack.index(before: range.lowerBound)]
        if before == " " || before == "-" || before == "_" { return 60 }
        return 20
    }

    // MARK: - Actions

    @objc private func openTapped() {
        let index = tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        onChoose(rows[index].choice)
    }

    /// Move the highlighted row, keeping it on screen. Clamped rather than
    /// wrapped: holding ↓ should come to rest at the last row, not cycle.
    private func moveSelection(by delta: Int) {
        guard !rows.isEmpty else { return }
        let current = tableView.selectedRow
        let next = min(max((current < 0 ? 0 : current) + delta, 0), rows.count - 1)
        tableView.selectRowIndexes(IndexSet(integer: next), byExtendingSelection: false)
        tableView.scrollRowToVisible(next)
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

    func tableView(_ tableView: NSTableView, rowViewForRow row: Int) -> NSTableRowView? {
        PickerRowView()
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?,
                   row: Int) -> NSView? {
        let entry = rows[row]

        let dot = DS.Dot(state: entry.isRunning ? .live : .idle)
        dot.pulses = entry.isRunning
        // Installed applications get no dot at all rather than a grey one: the
        // dot means "this is live", and an absent one is quieter than a dim one.
        dot.isHidden = !entry.isRunning

        let monogram = DS.Monogram(name: entry.title, key: entry.key)
        // Cached across reloads: the list redraws on every keystroke, and asking
        // the host again each time would make typing hit the network.
        if let cached = iconCache[entry.key] {
            monogram.setIcon(cached)
        } else if !requestedIcons.contains(entry.key) {
            requestedIcons.insert(entry.key)
            let key = entry.key
            let connection = agent
            let fetch: (@escaping (CGImage?) -> Void) -> Void
            switch entry.choice {
            case .running(let window):
                fetch = { connection?.icon(windowID: window.id, completion: $0) }
            case .launch(let app):
                fetch = { connection?.icon(path: app.path, completion: $0) }
            }
            fetch { [weak self] image in
                guard let image else { return }
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.iconCache[key] = image
                    // Only the rows currently showing this key need redrawing.
                    for (index, row) in self.rows.enumerated() where row.key == key {
                        self.tableView.reloadData(forRowIndexes: [index], columnIndexes: [0])
                    }
                }
            }
        }

        let title = NSTextField(labelWithString: entry.title)
        title.font = DS.body
        title.textColor = DS.textPrimary
        title.lineBreakMode = .byTruncatingTail

        let subtitle = NSTextField(labelWithString: row == busyRow
                                   ? "starting on the PC — usually 10s cold"
                                   : entry.subtitle)
        subtitle.font = DS.monoSmall
        subtitle.textColor = row == busyRow ? DS.accentBright : DS.textFaint

        let labels = NSStackView(views: [title, subtitle])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 1

        let action = NSTextField(labelWithString: entry.isRunning ? "Attach" : "Launch")
        action.font = DS.monoSmall
        action.textColor = DS.textFaint

        let cell = NSView()
        for child in [dot, monogram, labels, action] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            cell.addSubview(child)
        }
        var constraints: [NSLayoutConstraint] = [
            dot.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            monogram.leadingAnchor.constraint(equalTo: cell.leadingAnchor, constant: 23),
            monogram.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: monogram.trailingAnchor, constant: 11),
            labels.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            action.trailingAnchor.constraint(equalTo: cell.trailingAnchor, constant: -10),
            action.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: action.leadingAnchor, constant: -10),
        ]

        // The chip warns before you open it, not after: these keep their own
        // window buttons inside the picture.
        if entry.drawsOwnControls {
            let chip = DS.Chip("own controls")
            cell.addSubview(chip)
            constraints += [
                chip.trailingAnchor.constraint(equalTo: action.leadingAnchor, constant: -12),
                chip.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
                labels.trailingAnchor.constraint(lessThanOrEqualTo: chip.leadingAnchor, constant: -10),
            ]
        }
        NSLayoutConstraint.activate(constraints)
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = tableView.selectedRow >= 0 && busyRow == nil
    }
}

/// Selection is an accent-tinted fill with a hairline, not the system blue —
/// nothing in this palette shouts, and the accent is already the "live" colour.
private final class PickerRowView: NSTableRowView {
    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        let shape = NSBezierPath(roundedRect: bounds.insetBy(dx: 2, dy: 0),
                                 xRadius: DS.Metric.rowCorner, yRadius: DS.Metric.rowCorner)
        DS.accentTint.setFill()
        shape.fill()
        DS.accent.withAlphaComponent(0.5).setStroke()
        shape.lineWidth = 1
        shape.stroke()
    }
}

extension AppPicker: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }

    /// Make the search field drive the list, which is what the footer promises.
    ///
    /// The Open button already carries "\r" as its key equivalent, but a focused
    /// NSTextField swallows Return to fire its own action first, so the default
    /// button never saw it: the footer said "↩ to open" and Return merely re-ran
    /// the filter. Typing a few letters and pressing Return is the whole point of
    /// a search field, and it did nothing at all.
    ///
    /// The arrows are here for the same reason — moving the selection should not
    /// require leaving the field and reaching for the mouse.
    func control(_ control: NSControl,
                 textView: NSTextView,
                 doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            openTapped()
            return true
        case #selector(NSResponder.moveDown(_:)):
            moveSelection(by: 1)
            return true
        case #selector(NSResponder.moveUp(_:)):
            moveSelection(by: -1)
            return true
        default:
            return false
        }
    }
}
