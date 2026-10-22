import AppKit
import DesignSystem

/// The host chooser: a two-line control that opens a list of the same two-line
/// rows over itself.
///
/// Deliberately not an `NSPopUpButton` or an `NSComboBox`. Both give one line of
/// plain text per row, and this list needs a live state dot on every row, a
/// discovery footer that keeps running while the list is open, and a manual-entry
/// field as its last row. Reaching any of that through a stock control means
/// fighting it.
///
/// It is also not an `NSPopover`, for one specific reason: the list opens *over*
/// the control with the selected row aligned to it, so choosing a host does not
/// make the thing you chose appear to jump. NSPopover always anchors with an
/// arrow beside its target, which cannot express that. A borderless panel can.
final class HostDropdown: DS.Box {
    /// One part of a row's second line: words, or an address or number. The two
    /// are set differently — see `DS.detail` — so the row has to know which is
    /// which rather than being handed one joined string.
    enum Detail: Equatable {
        case words(String)
        case data(String)

        static func line(_ parts: [Detail], colour: NSColor) -> NSAttributedString {
            DS.detail(parts.map {
                switch $0 {
                case .words(let text): return (text, isData: false)
                case .data(let text): return (text, isData: true)
                }
            }, colour: colour)
        }
    }

    struct Item: Equatable {
        /// Which group a row belongs to. Dividers separate *kinds*, never
        /// individual rows.
        enum Kind { case discovered, recent }

        var address: String
        var name: String?
        var detail: [Detail]
        var dotState: DS.Dot.State
        var kind: Kind
    }

    /// The open list is rebuilt when these change, and only then: the
    /// connect window sets both on every refresh, a network change makes
    /// one, and a rebuild is a new list.
    var items: [Item] = [] { didSet { if isOpen, items != oldValue { rebuildList() } } }
    /// Shown as the running footer while mDNS is still looking.
    var isDiscovering: Bool = true {
        didSet { if isOpen, isDiscovering != oldValue { rebuildList() } }
    }

    /// Fired when a row is committed, or when an address is typed into the last
    /// row and entered.
    var onPick: ((String) -> Void)?

    private(set) var selectedAddress: String = ""

    // The closed control.
    private let dot = DS.Dot()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let chevron = NSImageView()
    private var tracking: NSTrackingArea?

    // The open list.
    private var panel: NSPanel?
    private var rows: [RowView] = []
    private var manualField: NSTextField?
    private var highlighted: Int = 0
    private var monitor: Any?
    private var typeAhead = ""
    private var typeAheadCleared: Date = .distantPast

    private var isOpen: Bool { panel != nil }

    // Metrics come straight from the design: two-line rows 48 high whatever the
    // subtitle says, 12 in from the edge, and a list that pads its rows by 4 so
    // their 8px corners sit concentric inside its 12px ones.
    private enum M {
        static let rowHeight: CGFloat = DS.Metric.rowHeight
        static let compactHeight: CGFloat = DS.Metric.rowHeight - DS.Space.x3
        static let rowInsetX: CGFloat = DS.Space.x3
        static let listPad: CGFloat = DS.Space.x1
        static let gap: CGFloat = DS.Space.x3
        static let dividerHeight: CGFloat = 1 + DS.Space.x1 * 2
        static let corner: CGFloat = DS.Metric.cardRadius
    }

    /// The list is exactly as wide as the control, plus its own padding, so
    /// the rows' text lines up with the control's text underneath it.
    private var listWidth: CGFloat { max(bounds.width, 320) }

    init() {
        super.init(fill: DS.surface, stroke: DS.hairline, radius: DS.Metric.fieldRadius)
        build()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { removeMonitor() }

    // MARK: - The closed control

    private func build() {
        titleLabel.font = DS.body
        titleLabel.textColor = DS.text
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.lineBreakMode = .byTruncatingTail
        chevron.image = NSImage(systemSymbolName: "chevron.up.chevron.down",
                                accessibilityDescription: nil)
        chevron.symbolConfiguration = .init(pointSize: 11, weight: .semibold)
        chevron.contentTintColor = DS.textMuted

        for child in [dot, titleLabel, detailLabel, chevron] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: M.rowHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.rowInsetX + 2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: M.gap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor,
                                                 constant: -M.gap),
            titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor,
                                                  constant: -M.gap),
            detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.rowInsetX),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Update what the closed control shows.
    func setSelection(address: String, name: String?, detail: [Detail], dotState: DS.Dot.State) {
        selectedAddress = address
        titleLabel.stringValue = name ?? (address.isEmpty ? "Choose a PC" : address)
        // Without a name the title IS the address, and addresses are set in mono.
        titleLabel.font = (name == nil && !address.isEmpty) ? DS.mono : DS.body
        detailLabel.attributedStringValue = Detail.line(detail, colour: DS.textMuted)
        dot.state = dotState
    }

    // Hover lifts the hairline to `edge`, the same thing a secondary button
    // does, because this is the control you press to change host.
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { stroke = DS.edge }
    override func mouseExited(with event: NSEvent) { stroke = DS.hairline }

    override func mouseDown(with event: NSEvent) {
        isOpen ? closeList(commit: false) : openList()
    }

    /// Open the list without a click. Used by `--test-dropdown` to photograph
    /// the open state, which is otherwise only reachable through the mouse.
    func openForTesting() { if !isOpen { openList() } }

    /// The list's own window, so a test can capture it rather than the screen.
    var listWindow: NSWindow? { panel }

    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityValue() -> Any? { titleLabel.stringValue }

    // MARK: - The open list

    private func openList() {
        guard let window else { return }
        rebuildRows()

        // A floating surface: `surface` with an `edge` rather than a hairline,
        // because it has to hold its own against the window it covers.
        let content = ListView()
        content.onKey = { [weak self] key in self?.handle(key) ?? false }

        let stack = NSStackView(views: listChildren())
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: M.listPad, left: M.listPad,
                                        bottom: M.listPad, right: M.listPad)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])

        let height = stack.fittingSize.height
        // Not a .nonactivatingPanel, and ListPanel exists only to say
        // canBecomeKey — a borderless panel refuses to become key otherwise.
        //
        // As a non-activating panel this list could never become key, so nothing
        // inside it ever saw a keystroke: ↓ ↑ ⏎ ⎋ and type-to-jump were all
        // written, wired up, and dead, and the manual-entry field could be
        // clicked but never typed into, which left no way at all to reach a host
        // that mDNS had not found. It stays a child window, so the connect window
        // behind it goes on drawing as active.
        let panelWidth = listWidth + M.listPad * 2
        let panel = ListPanel(contentRect: NSRect(x: 0, y: 0, width: panelWidth, height: height),
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false

        // Align the selected row over the control, so the chosen host does not
        // appear to move when the list opens. The panel starts one pad to the
        // left of the control so the rows inside it, not its edge, line up.
        let originInWindow = convert(bounds, to: nil)
        var screenRect = window.convertToScreen(originInWindow)
        let selectedIndex = max(0, rows.firstIndex { $0.address == selectedAddress } ?? 0)
        let offsetToSelected = M.listPad + CGFloat(rowOffset(before: selectedIndex))
        screenRect.origin.y -= (height - M.rowHeight - offsetToSelected)
        panel.setFrame(NSRect(x: screenRect.minX - M.listPad, y: screenRect.origin.y,
                              width: panelWidth, height: height), display: false)

        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        highlighted = selectedIndex
        applyHighlight()
        panel.makeFirstResponder(content)
        // Adding it as a child is not enough: without this the key window is
        // still the connect window and every key press goes there.
        panel.makeKey()

        installMonitor()
    }

    /// Vertical distance from the top of the list to row `index`, counting the
    /// dividers that fall before it.
    private func rowOffset(before index: Int) -> CGFloat {
        var offset: CGFloat = 0
        for i in 0..<min(index, rows.count) {
            offset += M.rowHeight
            if i + 1 < rows.count, rows[i].kind != rows[i + 1].kind { offset += M.dividerHeight }
        }
        return offset
    }

    private func listChildren() -> [NSView] {
        var children: [NSView] = []
        for (index, row) in rows.enumerated() {
            children.append(row)
            // Dividers separate kinds of entry, never every row.
            if index + 1 < rows.count, rows[index].kind != rows[index + 1].kind {
                children.append(divider())
            }
        }
        if !rows.isEmpty { children.append(divider()) }
        if isDiscovering { children.append(discoveryFooter()) }
        children.append(manualRow())
        return children
    }

    /// A hairline, inset to where row text starts and stops. Plain rather than
    /// the fading gradient Nocturne used: Solar's rule is one pixel of
    /// `hairline`, and a line that fades into a darker surface reads as smudge.
    private func divider() -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        let line = DS.hairlineView()
        holder.addSubview(line)
        NSLayoutConstraint.activate([
            holder.heightAnchor.constraint(equalToConstant: M.dividerHeight),
            holder.widthAnchor.constraint(equalToConstant: listWidth),
            line.leadingAnchor.constraint(equalTo: holder.leadingAnchor, constant: M.rowInsetX),
            line.trailingAnchor.constraint(equalTo: holder.trailingAnchor, constant: -M.rowInsetX),
            line.centerYAnchor.constraint(equalTo: holder.centerYAnchor),
        ])
        return holder
    }

    /// Discovery keeps running while the list is open, so it gets a row of its
    /// own rather than disappearing the moment the list is shown.
    private func discoveryFooter() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        // Amber and pulsing: the design's "working" dot, which is exactly what
        // discovery is doing.
        let pulse = DS.Dot(state: .working)
        let label = DS.label("Looking for more PCs…", font: DS.body, colour: DS.textMuted)
        for child in [pulse, label] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(child)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: M.compactHeight),
            row.widthAnchor.constraint(equalToConstant: listWidth),
            pulse.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: M.rowInsetX + 2),
            pulse.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            label.leadingAnchor.constraint(equalTo: pulse.trailingAnchor, constant: M.gap),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// Manual entry is the last row of the list, not a separate field beside it.
    /// It is drawn as the design's field — surface, hairline, an accent ring
    /// while typing — because it is one, and the ⌘K that reaches it sits in a
    /// chip at its end.
    private func manualRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let field = DS.Field(placeholder: "Enter a hostname or IP address", mono: true)
        field.target = self
        field.action = #selector(manualCommitted)
        manualField = field

        let box = DS.FieldBox(field: field, trailing: DS.Chip("⌘K"))
        row.addSubview(box)
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: DS.Metric.fieldHeight + M.listPad),
            row.widthAnchor.constraint(equalToConstant: listWidth),
            box.leadingAnchor.constraint(equalTo: row.leadingAnchor),
            box.trailingAnchor.constraint(equalTo: row.trailingAnchor),
            box.bottomAnchor.constraint(equalTo: row.bottomAnchor),
        ])
        return row
    }

    private func rebuildRows() {
        rows = items.map { item in
            let row = RowView(item: item, width: listWidth, height: M.rowHeight,
                              insetX: M.rowInsetX, gap: M.gap)
            row.onClick = { [weak self] in
                self?.selectedAddress = item.address
                self?.closeList(commit: true)
            }
            row.onHover = { [weak self] hovering in
                guard hovering, let self, let index = self.rows.firstIndex(of: row) else { return }
                self.highlighted = index
                self.applyHighlight()
            }
            return row
        }
    }

    /// The list again, for what it holds now. An address half typed into
    /// the last row goes over to the new one, with the focus and the caret
    /// where they were: the field went with the old list, and somebody
    /// typing the PC's Tailscale address lost it when Tailscale came up.
    private func rebuildList() {
        guard isOpen else { return }
        let typed = manualField?.stringValue ?? ""
        let caret = manualField?.currentEditor()?.selectedRange
        closeList(commit: false)
        openList()
        guard let field = manualField else { return }
        field.stringValue = typed
        if let caret {
            panel?.makeFirstResponder(field)
            field.currentEditor()?.selectedRange = caret
        }
    }

    private func applyHighlight() {
        for (index, row) in rows.enumerated() {
            row.setHighlighted(index == highlighted)
            row.setChecked(row.address == selectedAddress)
        }
    }

    @objc private func manualCommitted() {
        let typed = manualField?.stringValue.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !typed.isEmpty else { return }
        selectedAddress = typed
        closeList(commit: true)
    }

    private func closeList(commit: Bool) {
        removeMonitor()
        if let panel {
            window?.removeChildWindow(panel)
            panel.orderOut(nil)
        }
        panel = nil
        rows = []
        manualField = nil
        if commit { onPick?(selectedAddress) }
    }

    // MARK: - Keyboard

    private func installMonitor() {
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) {
            [weak self] event in
            guard let self, let panel = self.panel else { return event }
            // A click anywhere outside the list dismisses it without choosing.
            if event.window !== panel {
                self.closeList(commit: false)
            }
            return event
        }
    }

    private func removeMonitor() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    /// - Returns: true when the key was consumed.
    private func handle(_ event: NSEvent) -> Bool {
        // ⌘K, which the manual row has always advertised and never honoured.
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "k" {
            if let field = manualField { panel?.makeFirstResponder(field) }
            return true
        }
        switch event.keyCode {
        case 125:  // ↓
            move(by: 1); return true
        case 126:  // ↑
            move(by: -1); return true
        case 36:   // ⏎ commits the highlighted row
            if rows.indices.contains(highlighted) {
                selectedAddress = rows[highlighted].address
                closeList(commit: true)
            }
            return true
        case 53:   // ⎋ closes and restores
            closeList(commit: false); return true
        default:
            return jumpByPrefix(event)
        }
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), rows.count - 1)
        applyHighlight()
    }

    /// Typing jumps to the first row starting with what has been typed. The
    /// buffer clears after a pause, so "of" finds OFFICE-TOWER but a later "o"
    /// starts again rather than searching for "ofo".
    private func jumpByPrefix(_ event: NSEvent) -> Bool {
        guard let characters = event.charactersIgnoringModifiers?.lowercased(),
              let first = characters.first, first.isLetter || first.isNumber else { return false }
        if Date().timeIntervalSince(typeAheadCleared) > 1.0 { typeAhead = "" }
        typeAhead += characters
        typeAheadCleared = Date()
        if let index = rows.firstIndex(where: { $0.searchKey.hasPrefix(typeAhead) }) {
            highlighted = index
            applyHighlight()
        }
        return true
    }

    // MARK: - Row

    private final class RowView: DS.Box {
        let address: String
        let kind: Item.Kind
        let searchKey: String
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?

        private let detail: [Detail]
        private let dot = DS.Dot()
        private let titleLabel = NSTextField(labelWithString: "")
        private let detailLabel = NSTextField(labelWithString: "")
        /// The selected row's accent bar, on its leading edge.
        private let bar = DS.Box(fill: DS.accent, radius: DS.Metric.selectionBar / 2)
        private var isHighlighted = false
        private var isChecked = false

        init(item: Item, width: CGFloat, height: CGFloat, insetX: CGFloat, gap: CGFloat) {
            address = item.address
            kind = item.kind
            searchKey = (item.name ?? item.address).lowercased()
            detail = item.detail
            super.init(radius: DS.Metric.rowRadius)

            dot.state = item.dotState
            titleLabel.stringValue = item.name ?? item.address
            // A row without a name is titled by its address, which is data.
            titleLabel.font = item.name == nil ? DS.mono : DS.body
            titleLabel.textColor = DS.text
            titleLabel.lineBreakMode = .byTruncatingTail
            detailLabel.lineBreakMode = .byTruncatingTail
            bar.isHidden = true

            for child in [bar, dot, titleLabel, detailLabel] as [NSView] {
                child.translatesAutoresizingMaskIntoConstraints = false
                addSubview(child)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: height),
                widthAnchor.constraint(equalToConstant: width),
                bar.leadingAnchor.constraint(equalTo: leadingAnchor),
                bar.centerYAnchor.constraint(equalTo: centerYAnchor),
                bar.widthAnchor.constraint(equalToConstant: DS.Metric.selectionBar),
                bar.heightAnchor.constraint(equalToConstant: height - DS.Space.x6),
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX + 2),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: gap),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                     constant: -insetX),
                titleLabel.bottomAnchor.constraint(equalTo: centerYAnchor, constant: 1),
                detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor,
                                                      constant: -insetX),
                detailLabel.topAnchor.constraint(equalTo: centerYAnchor, constant: 2),
            ])
            restyle()

            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                     .inVisibleRect],
                                           owner: self))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// The row under the pointer or the arrow keys: `raised`.
        func setHighlighted(_ highlighted: Bool) {
            isHighlighted = highlighted
            restyle()
        }

        /// The host already chosen: `accentTint`, its subtitle in
        /// `accentTintInk`, and the accent bar — Solar's selected row, in place
        /// of the check mark Nocturne put at the end. Under Increase Contrast it
        /// also gains an accent edge, because a tint alone is a low-contrast
        /// signal.
        func setChecked(_ checked: Bool) {
            isChecked = checked
            restyle()
        }

        private func restyle() {
            fill = isChecked ? DS.accentTint : (isHighlighted ? DS.raised : nil)
            bar.isHidden = !isChecked
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            stroke = (isChecked && contrast) ? DS.accent : nil
            detailLabel.attributedStringValue = Detail.line(
                detail, colour: isChecked ? DS.accentTintInk : DS.textMuted)
            setAccessibilitySelected(isChecked)
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func mouseDown(with event: NSEvent) { onClick?() }
    }

    /// A borderless panel returns false from `canBecomeKey`, whatever else is
    /// done to it. This exists only to say otherwise.
    private final class ListPanel: NSPanel {
        override var canBecomeKey: Bool { true }
    }

    /// Content view that forwards key presses to the dropdown rather than
    /// beeping at them.
    private final class ListView: DS.Box {
        var onKey: ((NSEvent) -> Bool)?

        init() {
            super.init(fill: DS.surface, stroke: DS.edge, radius: M.corner)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }
}
