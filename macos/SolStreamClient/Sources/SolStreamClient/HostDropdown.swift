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
final class HostDropdown: NSView {
    struct Item: Equatable {
        /// Which group a row belongs to. Dividers separate *kinds*, never
        /// individual rows.
        enum Kind { case discovered, recent }

        var address: String
        var name: String?
        var detail: String
        var dotState: DS.Dot.State
        var kind: Kind
    }

    var items: [Item] = [] { didSet { if isOpen { rebuildList() } } }
    /// Shown as the running footer while mDNS is still looking.
    var isDiscovering: Bool = true { didSet { if isOpen { rebuildList() } } }

    /// Fired when a row is committed, or when an address is typed into the last
    /// row and entered.
    var onPick: ((String) -> Void)?

    private(set) var selectedAddress: String = ""

    // The closed control.
    private let dot = DS.Dot()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let chevron = NSTextField(labelWithString: "⌄")

    // The open list.
    private var panel: NSPanel?
    private var rows: [RowView] = []
    private var manualField: NSTextField?
    private var highlighted: Int = 0
    private var monitor: Any?
    private var typeAhead = ""
    private var typeAheadCleared: Date = .distantPast

    private var isOpen: Bool { panel != nil }

    // Metrics come straight from the design: 8px radius, 5.6px of vertical
    // padding around the list, rows padded 5.6/11.2, and a fixed row height that
    // a subtitle never changes.
    private enum M {
        static let rowHeight: CGFloat = 44
        static let rowInsetX: CGFloat = 11.2
        static let rowInsetY: CGFloat = 5.6
        static let listPadY: CGFloat = 5.6
        static let gap: CGFloat = 8.4
        static let corner: CGFloat = 8
        static let width: CGFloat = 356
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        build()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit { removeMonitor() }

    // MARK: - The closed control

    private func build() {
        wantsLayer = true
        layer?.backgroundColor = DS.chrome.cgColor
        layer?.cornerRadius = DS.Metric.rowCorner
        layer?.cornerCurve = .continuous

        titleLabel.font = DS.body
        titleLabel.textColor = DS.textPrimary
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = DS.monoSmall
        detailLabel.textColor = DS.textMuted
        detailLabel.lineBreakMode = .byTruncatingTail
        chevron.font = DS.monoSmall
        chevron.textColor = DS.textMuted

        for child in [dot, titleLabel, detailLabel, chevron] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            heightAnchor.constraint(equalToConstant: M.rowHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: M.rowInsetX),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            dot.widthAnchor.constraint(equalToConstant: DS.Metric.dot),
            dot.heightAnchor.constraint(equalToConstant: DS.Metric.dot),

            titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: M.gap),
            titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor,
                                                 constant: -M.gap),
            titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: M.rowInsetY),

            detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: chevron.leadingAnchor,
                                                  constant: -M.gap),
            detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),

            chevron.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -M.rowInsetX),
            chevron.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    /// Update what the closed control shows.
    func setSelection(address: String, name: String?, detail: String, dotState: DS.Dot.State) {
        selectedAddress = address
        titleLabel.stringValue = name ?? (address.isEmpty ? "Choose a PC" : address)
        detailLabel.stringValue = detail
        dot.state = dotState
    }

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

        let content = ListView()
        content.onKey = { [weak self] key in self?.handle(key) ?? false }
        content.wantsLayer = true
        content.layer?.backgroundColor = DS.chrome.cgColor
        content.layer?.cornerRadius = M.corner
        content.layer?.cornerCurve = .continuous
        content.layer?.borderWidth = 1
        content.layer?.borderColor = DS.edgeStrong.cgColor

        let stack = NSStackView(views: listChildren())
        stack.orientation = .vertical
        stack.spacing = 0
        stack.alignment = .leading
        stack.edgeInsets = NSEdgeInsets(top: M.listPadY, left: 0, bottom: M.listPadY, right: 0)
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
        let panel = ListPanel(contentRect: NSRect(x: 0, y: 0, width: M.width, height: height),
                              styleMask: [.borderless],
                              backing: .buffered, defer: false)
        panel.contentView = content
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.isReleasedWhenClosed = false

        // Align the selected row over the control, so the chosen host does not
        // appear to move when the list opens.
        let originInWindow = convert(bounds, to: nil)
        var screenRect = window.convertToScreen(originInWindow)
        let selectedIndex = max(0, rows.firstIndex { $0.address == selectedAddress } ?? 0)
        let offsetToSelected = M.listPadY + CGFloat(rowOffset(before: selectedIndex))
        screenRect.origin.y -= (height - M.rowHeight - offsetToSelected)
        panel.setFrame(NSRect(x: screenRect.minX, y: screenRect.origin.y,
                              width: M.width, height: height), display: false)

        window.addChildWindow(panel, ordered: .above)
        self.panel = panel
        highlighted = selectedIndex
        applyHighlight()
        panel.makeFirstResponder(content)
        // Adding it as a child is not enough: without this the key window is
        // still the connect window and every key press goes there.
        panel.makeKey()

        installMonitor()
        chevron.stringValue = "⌃"
    }

    /// Vertical distance from the top of the list to row `index`, counting the
    /// dividers that fall before it.
    private func rowOffset(before index: Int) -> CGFloat {
        var offset: CGFloat = 0
        for i in 0..<min(index, rows.count) {
            offset += M.rowHeight
            if i + 1 < rows.count, rows[i].kind != rows[i + 1].kind { offset += 1 + 11.2 }
        }
        return offset
    }

    private func listChildren() -> [NSView] {
        var children: [NSView] = []
        for (index, row) in rows.enumerated() {
            children.append(row)
            // Dividers separate kinds of entry, never every row.
            if index + 1 < rows.count, rows[index].kind != rows[index + 1].kind {
                children.append(Self.divider())
            }
        }
        if !rows.isEmpty { children.append(Self.divider()) }
        if isDiscovering { children.append(discoveryFooter()) }
        children.append(manualRow())
        return children
    }

    /// The fading rule: solid across the middle, gone at both ends, inset from
    /// the row padding.
    private static func divider() -> NSView {
        let holder = NSView()
        holder.translatesAutoresizingMaskIntoConstraints = false
        holder.wantsLayer = true
        let line = CAGradientLayer()
        line.startPoint = CGPoint(x: 0, y: 0.5)
        line.endPoint = CGPoint(x: 1, y: 0.5)
        let solid = DS.textPrimary.withAlphaComponent(0.16).cgColor
        line.colors = [NSColor.clear.cgColor, solid, solid, NSColor.clear.cgColor]
        line.locations = [0, 0.14, 0.86, 1]
        holder.layer?.addSublayer(line)
        holder.heightAnchor.constraint(equalToConstant: 1 + 11.2).isActive = true
        holder.widthAnchor.constraint(equalToConstant: M.width).isActive = true
        DispatchQueue.main.async {
            line.frame = CGRect(x: M.rowInsetX, y: 5.6,
                                width: holder.bounds.width - M.rowInsetX * 2, height: 1)
        }
        return holder
    }

    /// Discovery keeps running while the list is open, so it gets a row of its
    /// own rather than disappearing the moment the list is shown.
    private func discoveryFooter() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false
        let pulse = DS.Dot()
        pulse.state = .live
        pulse.pulses = true
        let label = NSTextField(labelWithString: "Looking for more hosts…")
        label.font = DS.secondary
        label.textColor = DS.textMuted
        for child in [pulse, label] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(child)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: M.rowHeight),
            row.widthAnchor.constraint(equalToConstant: M.width),
            pulse.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: M.rowInsetX),
            pulse.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            pulse.widthAnchor.constraint(equalToConstant: DS.Metric.dot),
            pulse.heightAnchor.constraint(equalToConstant: DS.Metric.dot),
            label.leadingAnchor.constraint(equalTo: pulse.trailingAnchor, constant: M.gap),
            label.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    /// Manual entry is the last row of the list, not a separate field beside it.
    private func manualRow() -> NSView {
        let row = NSView()
        row.translatesAutoresizingMaskIntoConstraints = false

        let field = DS.Field(placeholder: "Enter a hostname or IP…")
        field.target = self
        field.action = #selector(manualCommitted)
        manualField = field

        let hint = NSTextField(labelWithString: "⌘K")
        hint.font = DS.monoSmall
        hint.textColor = DS.textMuted

        for child in [field, hint] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(child)
        }
        NSLayoutConstraint.activate([
            row.heightAnchor.constraint(equalToConstant: M.rowHeight),
            row.widthAnchor.constraint(equalToConstant: M.width),
            // Indented to where a title sits, so the dot column stays a column
            // even on the row that has no dot.
            field.leadingAnchor.constraint(equalTo: row.leadingAnchor,
                                           constant: M.rowInsetX + DS.Metric.dot + M.gap),
            field.trailingAnchor.constraint(equalTo: hint.leadingAnchor, constant: -M.gap),
            field.centerYAnchor.constraint(equalTo: row.centerYAnchor),
            hint.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -M.rowInsetX),
            hint.centerYAnchor.constraint(equalTo: row.centerYAnchor),
        ])
        return row
    }

    private func rebuildRows() {
        rows = items.map { item in
            let row = RowView(item: item, width: M.width, height: M.rowHeight,
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

    private func rebuildList() {
        guard isOpen else { return }
        closeList(commit: false)
        openList()
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
        chevron.stringValue = "⌄"
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

    private final class RowView: NSView {
        let address: String
        let kind: Item.Kind
        let searchKey: String
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?

        private let dot = DS.Dot()
        private let titleLabel = NSTextField(labelWithString: "")
        private let detailLabel = NSTextField(labelWithString: "")
        private let check = NSTextField(labelWithString: "✓")
        private var isHighlighted = false

        init(item: Item, width: CGFloat, height: CGFloat, insetX: CGFloat, gap: CGFloat) {
            address = item.address
            kind = item.kind
            searchKey = (item.name ?? item.address).lowercased()
            super.init(frame: .zero)
            translatesAutoresizingMaskIntoConstraints = false
            wantsLayer = true
            layer?.cornerRadius = 6
            layer?.cornerCurve = .continuous

            dot.state = item.dotState
            titleLabel.stringValue = item.name ?? item.address
            titleLabel.font = DS.body
            titleLabel.textColor = DS.textPrimary
            titleLabel.lineBreakMode = .byTruncatingTail
            detailLabel.stringValue = item.detail
            detailLabel.font = DS.monoSmall
            detailLabel.textColor = DS.textMuted
            detailLabel.lineBreakMode = .byTruncatingTail
            check.font = DS.monoSmall
            check.textColor = DS.accent
            check.isHidden = true

            for child in [dot, titleLabel, detailLabel, check] as [NSView] {
                child.translatesAutoresizingMaskIntoConstraints = false
                addSubview(child)
            }
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: height),
                widthAnchor.constraint(equalToConstant: width),
                dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: insetX),
                dot.centerYAnchor.constraint(equalTo: centerYAnchor),
                dot.widthAnchor.constraint(equalToConstant: DS.Metric.dot),
                dot.heightAnchor.constraint(equalToConstant: DS.Metric.dot),
                titleLabel.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: gap),
                titleLabel.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor,
                                                     constant: -gap),
                titleLabel.topAnchor.constraint(equalTo: topAnchor, constant: 5.6),
                detailLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
                detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: check.leadingAnchor,
                                                      constant: -gap),
                detailLabel.topAnchor.constraint(equalTo: titleLabel.bottomAnchor, constant: 1),
                check.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -insetX),
                check.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])

            addTrackingArea(NSTrackingArea(rect: .zero,
                                           options: [.mouseEnteredAndExited, .activeInKeyWindow,
                                                     .inVisibleRect],
                                           owner: self))
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        /// Selection is a tint; hover is the same tint one step lighter. Under
        /// Increase Contrast the selected row also gains an accent edge, because
        /// a tint alone is a low-contrast signal.
        func setHighlighted(_ highlighted: Bool) {
            isHighlighted = highlighted
            layer?.backgroundColor = highlighted ? DS.accentTint.cgColor : NSColor.clear.cgColor
            let contrast = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast
            layer?.borderWidth = (highlighted && contrast) ? 1 : 0
            layer?.borderColor = DS.accent.cgColor
        }

        func setChecked(_ checked: Bool) { check.isHidden = !checked }

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
    private final class ListView: NSView {
        var onKey: ((NSEvent) -> Bool)?
        override var acceptsFirstResponder: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event) != true { super.keyDown(with: event) }
        }
    }
}
