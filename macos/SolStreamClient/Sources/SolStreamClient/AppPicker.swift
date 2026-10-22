import AppKit
import DesignSystem
import SolStreamLogging
import MediaSession
import AgentChannel

/// "Which application?"
///
/// One ranked list, no modes and no group headers. Windows already open sort
/// first and carry a live dot; installed applications do not. The selected row
/// says what Return will do — "Attach" or "Launch".
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
        /// Said only on the selected row; see `present`.
        var note: String? = nil
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
    private let tableView = PickerTableView()
    private let scrollView = NSScrollView()
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let spinner = NSProgressIndicator()
    private let backButton: DS.Button
    private let openButton: DS.Button

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
        backButton = DS.Button(title: "Back", target: nil, action: nil)
        openButton = DS.Button(title: "Open", style: .primary, target: nil, action: nil)

        // The title bar is transparent and the content runs under it, so the
        // window is one graphite surface with the traffic lights on it, and the
        // title is the content's own heading rather than small grey text in a
        // strip. The window still carries its title and subtitle for the Window
        // menu and VoiceOver; it just does not draw them.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 600),
                          styleMask: [.titled, .closable, .miniaturizable, .resizable,
                                      .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = host
        window.subtitle = "Choose an application"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DS.ground
        window.minSize = NSSize(width: 440, height: 420)

        super.init()
        build(host: host)
        window.delegate = self
    }

    private func build(host: String) {
        let heading = DS.label("Choose an application", font: DS.title)
        let subheading = NSTextField(labelWithString: "")
        let lead = NSMutableAttributedString(string: "Open windows and installed apps on ", attributes: [
            .font: DS.body, .foregroundColor: DS.textSecondary,
        ])
        lead.append(NSAttributedString(string: host, attributes: [
            .font: DS.mono, .foregroundColor: DS.textSecondary,
        ]))
        subheading.attributedStringValue = lead
        subheading.lineBreakMode = .byTruncatingMiddle

        searchField.placeholder = "Search"
        searchField.target = self
        searchField.action = #selector(searchChanged)
        // Filter as it is typed rather than on Return: the list is the answer,
        // so making the user commit to see it would be a step for nothing.
        searchField.delegate = self

        // The design's field rather than NSSearchField's own bezel. It used to
        // carry a "⌘F" hint at its end that nothing honoured; the field has
        // focus from the moment the window opens, so a magnifier says what it
        // is for without promising a shortcut.
        let magnifier = NSImageView(image: NSImage(systemSymbolName: "magnifyingglass",
                                                   accessibilityDescription: nil) ?? NSImage())
        magnifier.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        magnifier.contentTintColor = DS.textMuted
        let searchBox = DS.FieldBox(field: searchField, leading: magnifier)

        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("app"))
        column.resizingMask = .autoresizingMask
        tableView.addTableColumn(column)
        tableView.headerView = nil
        tableView.rowHeight = DS.Metric.rowHeight
        tableView.dataSource = self
        tableView.delegate = self
        tableView.target = self
        // One click opens: the list is a set of things to open, not a set of
        // things to select and then confirm, and a click that only highlighted
        // left a second step for no reason. The arrows still only move the
        // highlight, and Return opens it.
        tableView.action = #selector(rowClicked)
        tableView.onReturn = { [weak self] in self?.openTapped() }
        tableView.onEscape = { [weak self] in self?.backTapped() }
        // Typing with the list focused goes on searching, as it would if the
        // focus had never left the field.
        tableView.onTyping = { [weak self] text in self?.continueSearch(with: text) }
        tableView.backgroundColor = .clear
        tableView.style = .plain
        tableView.selectionHighlightStyle = .regular
        tableView.intercellSpacing = NSSize(width: 0, height: 2)
        tableView.gridStyleMask = []

        scrollView.documentView = tableView
        // Hover follows the pointer, not just its crossings: rows scrolled
        // under a pointer that does not move get no exit, and kept their
        // highlight; see `refreshHover`.
        scrollView.contentView.postsBoundsChangedNotifications = true
        NotificationCenter.default.addObserver(self, selector: #selector(refreshHover),
                                               name: NSView.boundsDidChangeNotification,
                                               object: scrollView.contentView)
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.translatesAutoresizingMaskIntoConstraints = false

        // The list sits on a card — `surface`, a hairline edge — so it reads as
        // one object against the ground, with its rows inset by 4 so their 8px
        // corners sit concentric inside the card's 12.
        let listCard = DS.card()
        listCard.addSubview(scrollView)
        let pad = DS.Space.x1
        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: listCard.leadingAnchor, constant: pad),
            scrollView.trailingAnchor.constraint(equalTo: listCard.trailingAnchor, constant: -pad),
            scrollView.topAnchor.constraint(equalTo: listCard.topAnchor, constant: pad),
            scrollView.bottomAnchor.constraint(equalTo: listCard.bottomAnchor, constant: -pad),
        ])

        statusLabel.font = DS.body
        statusLabel.textColor = DS.textMuted
        statusLabel.stringValue = "Asking the PC what it can run…"
        // A failure message is a sentence, not a label. Left to size itself the
        // window grew wider than the screen to fit one on a single line, and the
        // end of the message — the part that says what to do — went off the
        // right edge where it could not be read at all.
        statusLabel.maximumNumberOfLines = 3
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.preferredMaxLayoutWidth = 260

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

        // One bar along the bottom: what the PC said on the left, the two ways
        // out on the right with the primary last. The "↩ to open" hint that
        // used to sit between them is said by the primary button itself now,
        // and by the selected row.
        let footerSpacer = NSView()
        footerSpacer.setContentHuggingPriority(.init(1), for: .horizontal)
        let footer = NSStackView(views: [spinner, statusLabel, footerSpacer, backButton, openButton])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        footer.spacing = DS.Space.x3
        footer.setCustomSpacing(DS.Space.x2, after: spinner)

        let stack = NSStackView(views: [heading, subheading, searchBox, listCard, footer])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.x3
        stack.setCustomSpacing(DS.Space.x1, after: heading)
        stack.setCustomSpacing(DS.Space.x5, after: subheading)
        stack.setCustomSpacing(DS.Space.x5, after: listCard)
        let inset = DS.Metric.inset
        stack.edgeInsets = NSEdgeInsets(top: DS.Metric.titleBar + DS.Space.x5, left: inset,
                                        bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false
        stack.setHuggingPriority(.defaultLow, for: .vertical)
        listCard.setContentHuggingPriority(.init(1), for: .vertical)

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        for view in [subheading, searchBox, listCard, footer] as [NSView] {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2).isActive = true
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
            //
            // Said quietly: on the selected row's second line, where the choice
            // is being made, and in every such row's tooltip. It used to be said
            // twice on every row — in the subtitle and again as an "own
            // controls" chip — and on a PC where most open windows are modern
            // apps that sat on nearly every row, which is the same mistake as
            // the old "title bar hidden" one.
            Row(title: $0.title,
                subtitle: "Open window",
                note: $0.hidesCaptionWhenCropped ? nil : "own window buttons",
                key: "\($0.className)/\($0.id)",
                isRunning: true,
                drawsOwnControls: !$0.hidesCaptionWhenCropped,
                choice: .running($0))
        }
        built += apps.map {
            Row(title: $0.name, subtitle: "Installed app", key: $0.path,
                isRunning: false, drawsOwnControls: false, choice: .launch($0))
        }

        allRows = built
        setSpinning(false)
        statusLabel.stringValue = "\(windows.count) window\(windows.count == 1 ? "" : "s") open"
            + " · \(apps.count) app\(apps.count == 1 ? "" : "s")"
        statusLabel.textColor = DS.textMuted
        applyFilter()
        if let keepKey, let again = rows.firstIndex(where: { $0.key == keepKey }) {
            tableView.selectRowIndexes(IndexSet(integer: again), byExtendingSelection: false)
            tableView.scrollRowToVisible(again)
        }
    }

    func showFailure(_ message: String) {
        setSpinning(false)
        statusLabel.stringValue = message
        statusLabel.textColor = DS.danger
    }

    /// A launch is slow — a cold start is many seconds — so the row grows a
    /// progress line in place rather than a modal taking the window over. The
    /// list stays interactive; nothing about it moves.
    func showBusy(_ message: String) {
        setSpinning(true)
        statusLabel.textColor = DS.textMuted
        statusLabel.stringValue = message
        openButton.isEnabled = false
        busyRow = tableView.selectedRow >= 0 ? tableView.selectedRow : nil
        if let busyRow { tableView.reloadData(forRowIndexes: [busyRow], columnIndexes: [0]) }
    }

    func clearBusy() {
        setSpinning(false)
        let previous = busyRow
        busyRow = nil
        if let previous, previous < rows.count {
            tableView.reloadData(forRowIndexes: [previous], columnIndexes: [0])
        }
        openButton.isEnabled = tableView.selectedRow >= 0
    }

    /// Hidden as well as stopped: a stopped spinner that is merely not drawn
    /// still holds its slot in the footer, and the status text sat indented by
    /// a spinner's width for no visible reason.
    private func setSpinning(_ spinning: Bool) {
        spinner.isHidden = !spinning
        if spinning { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }
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
        refreshHover()
    }

    /// Put the hover on whichever row is under the pointer now, and on no
    /// other. Tracking areas only report the pointer crossing a row's edge,
    /// and a list scrolled by the wheel or trackpad moves the rows instead:
    /// the row that slid out from under the pointer never heard it leave, and
    /// a reused row view brought its highlight to a new title.
    @objc private func refreshHover() {
        let pointer = tableView.convert(window.mouseLocationOutsideOfEventStream, from: nil)
        let visible = tableView.visibleRect
        let under = visible.contains(pointer) ? tableView.row(at: pointer) : -1
        tableView.enumerateAvailableRowViews { view, row in
            (view as? PickerRowView)?.hovering = row == under
        }
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
        // One open at a time, and the check has to be here rather than on the
        // button. `showBusy` disables the Open button, which is exactly right
        // for the button — but this method is also what a click on a row and
        // Return in the field or the list call, and none of those asks the
        // button whether it is enabled. Clicking a row that was
        // already starting therefore ran the whole flow a second time: a second
        // media session negotiated over the top of the first, and a second
        // window for the same application. `busyRow` is what `showBusy` sets and
        // what the selection handler already derives enablement from, so gating
        // on it here covers all three routes with the state that already exists.
        guard busyRow == nil else { return }
        let index = tableView.selectedRow
        guard index >= 0, index < rows.count else { return }
        onChoose(rows[index].choice)
    }

    @objc private func rowClicked() {
        let row = tableView.clickedRow
        guard row >= 0, row < rows.count else { return }
        tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        openTapped()
    }

    /// Typing that reached the list, back into the search field.
    private func continueSearch(with text: String) {
        window.makeFirstResponder(searchField)
        searchField.currentEditor()?.insertText(text)
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

    /// Back to choosing a PC. Escape does this too -- from the list, and from
    /// the search field once it is empty; with something typed, Escape clears
    /// that first, as it does in every Mac search field.
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

        let cell = tableView.makeView(withIdentifier: PickerCell.reuseIdentifier, owner: self)
            as? PickerCell ?? PickerCell()
        let monogram = cell.tile
        monogram.configure(name: entry.title, key: entry.key)
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

        let busy = row == busyRow
        cell.configure(title: entry.title,
                       subtitle: busy ? "Starting on the PC — usually 10 s cold" : entry.subtitle,
                       // Installed applications get no dot at all rather than a
                       // grey one: the dot means "this is live". A launch under
                       // way is the amber working dot.
                       note: busy ? nil : entry.note,
                       dot: busy ? .working : (entry.isRunning ? .live : nil),
                       action: entry.isRunning ? "Attach" : "Launch")
        // The longer story behind "own window buttons", for anybody who
        // wonders: these keep their own minimise and close inside the picture.
        cell.toolTip = entry.drawsOwnControls
            ? "This app draws its own window buttons, so they appear inside the streamed window."
            : nil
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        openButton.isEnabled = tableView.selectedRow >= 0 && busyRow == nil
    }
}

/// Solar's row: transparent at rest, `raised` under the pointer, and selected as
/// `accentTint` with a 3px accent bar on the leading edge — not the system blue,
/// and not Nocturne's purple outline, which was the heaviest thing in the window.
private final class PickerRowView: NSTableRowView {
    /// Set by the picker from where the pointer is; see `refreshHover`.
    var hovering = false {
        didSet {
            guard hovering != oldValue else { return }
            needsDisplay = true
            syncCell()
        }
    }

    override var isSelected: Bool {
        didSet { syncCell() }
    }

    // The cell paints its own text colours from the selection, so the system's
    // "emphasized" inversion has nothing to do and must not try.
    override var isEmphasized: Bool {
        get { false }
        set {}
    }

    override func didAddSubview(_ subview: NSView) {
        super.didAddSubview(subview)
        syncCell()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                 .inVisibleRect],
                                       owner: self))
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    private func syncCell() {
        for case let cell as PickerCell in subviews {
            cell.setState(selected: isSelected, hovered: hovering)
        }
    }

    private var shape: NSBezierPath {
        NSBezierPath(roundedRect: bounds, xRadius: DS.Metric.rowRadius, yRadius: DS.Metric.rowRadius)
    }

    override func drawBackground(in dirtyRect: NSRect) {
        guard hovering, !isSelected else { return }
        DS.raised.setFill()
        shape.fill()
    }

    override func drawSelection(in dirtyRect: NSRect) {
        guard selectionHighlightStyle != .none else { return }
        DS.accentTint.setFill()
        shape.fill()
        let barHeight = bounds.height - DS.Space.x6
        let bar = NSRect(x: 0, y: (bounds.height - barHeight) / 2,
                         width: DS.Metric.selectionBar, height: barHeight)
        DS.accent.setFill()
        NSBezierPath(roundedRect: bar, xRadius: DS.Metric.selectionBar / 2,
                     yRadius: DS.Metric.selectionBar / 2).fill()
        // A tint alone is a low-contrast signal; Increase Contrast adds an edge.
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
            DS.accent.setStroke()
            let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: DS.Metric.rowRadius, yRadius: DS.Metric.rowRadius)
            edge.lineWidth = 1
            edge.stroke()
        }
    }
}

/// One row's contents: the tile, the title, a second line with the live dot,
/// and — on the selected or hovered row only — the verb.
///
/// The verb was on every row, in mono, beside a chip on most of them; a list of
/// thirty rows each ending "Launch" is thirty times the same word. On the
/// selected row it says what Return will do, which is the one place it helps.
private final class PickerCell: NSTableCellView {
    static let reuseIdentifier = NSUserInterfaceItemIdentifier("PickerCell")

    let tile = DS.Monogram(name: "", key: "")
    private let titleLabel = DS.label("")
    private let subtitleLabel = DS.label("", font: DS.caption, colour: DS.textMuted)
    private let actionLabel = DS.label("", font: DS.caption, colour: DS.textMuted)
    private let dotView = DS.Dot()
    private var action = ""
    private var subtitle = ""
    private var note: String?

    /// Built once and reused by the table: the list reloads on every keystroke
    /// and every window opened on the PC.
    init() {
        super.init(frame: .zero)
        identifier = Self.reuseIdentifier
        titleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        subtitleLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        // A hidden dot is detached by the stack view, so a row without one
        // does not keep its slot.
        let secondLine = NSStackView(views: [dotView, subtitleLabel])
        secondLine.orientation = .horizontal
        secondLine.alignment = .centerY
        secondLine.spacing = 6

        let labels = NSStackView(views: [titleLabel, secondLine])
        labels.orientation = .vertical
        labels.alignment = .leading
        labels.spacing = 2

        actionLabel.alignment = .right
        actionLabel.setContentHuggingPriority(.required, for: .horizontal)
        actionLabel.setContentCompressionResistancePriority(.required, for: .horizontal)

        for child in [tile, labels, actionLabel] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            tile.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.x3),
            tile.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.leadingAnchor.constraint(equalTo: tile.trailingAnchor, constant: DS.Space.x3),
            labels.centerYAnchor.constraint(equalTo: centerYAnchor),
            actionLabel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.x3),
            actionLabel.centerYAnchor.constraint(equalTo: centerYAnchor),
            labels.trailingAnchor.constraint(lessThanOrEqualTo: actionLabel.leadingAnchor,
                                             constant: -DS.Space.x3),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    func configure(title: String, subtitle: String, note: String?, dot: DS.Dot.State?,
                   action: String) {
        titleLabel.stringValue = title
        self.subtitle = subtitle
        self.note = note
        self.action = action
        dotView.isHidden = dot == nil
        if let dot { dotView.state = dot }
        setAccessibilityLabel("\(title), \(subtitle)")
        // The row view sets the real state when the cell lands in it.
        setState(selected: false, hovered: false)
    }

    func setState(selected: Bool, hovered: Bool) {
        subtitleLabel.textColor = selected ? DS.accentTintInk : DS.textMuted
        subtitleLabel.stringValue = (selected ? note : nil).map { "\(subtitle) · \($0)" } ?? subtitle
        actionLabel.textColor = selected ? DS.accentTintInk : DS.textMuted
        actionLabel.stringValue = selected ? "\(action)  ↩" : (hovered ? action : "")
    }
}

extension AppPicker: NSTextFieldDelegate {
    func controlTextDidChange(_ obj: Notification) {
        searchChanged()
    }

    /// Make the search field drive the list, which is what the Open button and
    /// the selected row's "↩" promise.
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
        case #selector(NSResponder.cancelOperation(_:)):
            if searchField.stringValue.isEmpty {
                backTapped()
            } else {
                searchField.stringValue = ""
                applyFilter()
            }
            return true
        default:
            return false
        }
    }
}

/// The list's own keys: Return opens the highlighted row and Escape goes back,
/// whichever of the list and the search field has the focus -- NSTableView
/// does neither by itself, so once a row had been clicked Return did nothing.
/// Anything typed goes back to the search.
private final class PickerTableView: NSTableView {
    var onReturn: (() -> Void)?
    var onEscape: (() -> Void)?
    var onTyping: ((String) -> Void)?

    override func keyDown(with event: NSEvent) {
        let modifiers = event.modifierFlags.intersection([.command, .control, .option])
        switch event.keyCode {
        case 36, 76:  // Return, keypad Enter
            onReturn?()
        case 53:      // Escape
            onEscape?()
        default:
            if modifiers.isEmpty, let text = event.characters,
               let scalar = text.unicodeScalars.first,
               !CharacterSet.controlCharacters.contains(scalar),
               scalar.value < 0xF700 || scalar.value > 0xF8FF {  // not an arrow or function key
                onTyping?(text)
            } else {
                super.keyDown(with: event)
            }
        }
    }
}
