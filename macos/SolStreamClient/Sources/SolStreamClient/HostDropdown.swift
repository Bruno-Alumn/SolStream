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
        /// This Mac holds a pairing token for it: Forget Pairing is offered.
        var paired = false
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
    /// Take a "Used before" address off the list: right-click, or ⌘⌫ on its
    /// highlighted row. Nil leaves recent rows as they are.
    var onForget: ((String) -> Void)?
    /// Forget a paired PC's token: right-click on its row. Nil offers nothing.
    var onForgetPairing: ((Item) -> Void)?

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
    /// The same keys as typed, case and all, for the field they may go to.
    private var typedAhead = ""
    private var typeAheadCleared: Date = .distantPast

    private var isOpen: Bool { panel != nil }

    // Metrics come straight from the design: two-line rows 48 high whatever the
    // subtitle says, 12 in from the edge, and a list that pads its rows by 4 so
    // their 8px corners sit concentric inside its 12px ones.
    private enum M {
        static let rowHeight: CGFloat = DS.Metric.rowHeight
        static let compactHeight: CGFloat = DS.Metric.rowHeightCompact
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
    ///
    /// An open list follows a new host too, its check mark and its
    /// highlight, as it did when every refresh rebuilt it -- but without a
    /// rebuild, which would take an address being typed with it. Left
    /// behind, the list went on marking the host the window had just given
    /// up on, and Enter chose it again.
    func setSelection(address: String, name: String?, detail: [Detail], dotState: DS.Dot.State) {
        let moved = address != selectedAddress
        let before = accessibilityValue() as? String
        selectedAddress = address
        titleLabel.stringValue = name ?? (address.isEmpty ? "Choose a PC" : address)
        // Without a name the title IS the address, and addresses are set in mono.
        titleLabel.font = (name == nil && !address.isEmpty) ? DS.mono : DS.body
        detailLabel.attributedStringValue = Detail.line(detail, colour: DS.textMuted)
        spokenDetail = detail
        dot.state = dotState
        // Said again when it changes -- a check coming back, a PC waking --
        // as a pop-up button's value is.
        if accessibilityValue() as? String != before {
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
        if isOpen, moved {
            // The same rule as opening the list: the selected row, or the first.
            highlighted = rows.firstIndex { $0.address == address } ?? 0
            applyHighlight()
        }
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
    /// What VoiceOver hears as the open list's current row, for the tests.
    var accessibleCurrentRowForTesting: String? {
        (listView?.accessibilitySelectedChildren()?.first as? NSView)?.accessibilityLabel()
    }

    /// The list's own window, so a test can capture it rather than the screen.
    var listWindow: NSWindow? { panel }

    // Reachable without a mouse. A plain view is not an accessibility element
    // and never takes focus, so VoiceOver read two loose labels and Tab went
    // past it: there was no way to choose a PC, or to type one in, from the
    // keyboard.
    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .popUpButton }
    override func accessibilityLabel() -> String? { "PC" }
    /// The PC and what is known of it -- "DESKTOP, Not answering" -- not its
    /// name alone: the dot and the line under it are how everyone else sees
    /// whether it is awake, paired, or there at all.
    override func accessibilityValue() -> Any? {
        Self.spokenValue(title: titleLabel.stringValue, detail: spokenDetail)
    }

    /// The detail as said: its parts joined with commas rather than the
    /// line's dots, and without the round trip, which changes with every
    /// probe and would have VoiceOver say the whole line again each time.
    private var spokenDetail: [Detail] = []

    static func spokenValue(title: String, detail: [Detail]) -> String {
        let parts = detail.compactMap { part -> String? in
            switch part {
            case .words(let text), .data(let text):
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                return trimmed.isEmpty || trimmed.hasSuffix(" ms") ? nil : trimmed
            }
        }
        return ([title] + parts).joined(separator: ", ")
    }
    override func accessibilityPerformPress() -> Bool {
        isOpen ? closeList(commit: false) : openList()
        return true
    }

    // In the Tab loop as a pop-up button is: when Full Keyboard Access is on.
    // Always focusable, it took focus as the connect window opened -- and with
    // it the Return meant for Connect.
    override var acceptsFirstResponder: Bool { NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }
    override var focusRingMaskBounds: NSRect { bounds }
    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: DS.Metric.fieldRadius,
                     yRadius: DS.Metric.fieldRadius).fill()
    }

    override func keyDown(with event: NSEvent) {
        // Space, ↓ and ↑ open it, as they do a pop-up button. Not Return: that
        // is the default button's, and Connect is what it should press.
        switch event.keyCode {
        case 49, 125, 126:
            if !isOpen { openList() }
        default:
            super.keyDown(with: event)
        }
    }

    // MARK: - The open list

    private func openList() {
        guard let window else { return }
        rebuildRows()

        // A floating surface: `surface` with an `edge` rather than a hairline,
        // because it has to hold its own against the window it covers.
        let content = ListView()
        content.onKey = { [weak self] key in self?.handle(key) ?? false }
        content.accessibleRows = { [weak self] in self?.rows ?? [] }
        content.accessibleCurrent = { [weak self] in
            guard let self, self.rows.indices.contains(self.highlighted) else { return nil }
            return self.rows[self.highlighted]
        }
        content.accessibleField = { [weak self] in self?.manualField }
        content.accessibleFooter = { [weak self] in self?.discoveryLabel }
        listView = content

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
        // On the screen, whatever that costs the alignment: a borderless window
        // is not kept there by AppKit, and with a few PCs known and the window
        // low on a small display the list ran off the bottom -- taking the
        // address field in its last row with it.
        var frame = NSRect(x: screenRect.minX - M.listPad, y: screenRect.origin.y,
                           width: panelWidth, height: height)
        if let visible = window.screen?.visibleFrame {
            // The bottom kept when it cannot all fit: the address field is the
            // last row.
            frame.origin.y = max(min(frame.minY, visible.maxY - frame.height), visible.minY)
            frame.origin.x = min(max(frame.minX, visible.minX), visible.maxX - frame.width)
        }
        panel.setFrame(frame, display: false)

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
        // Blue and pulsing: the design's "working" dot, which is exactly what
        // discovery is doing.
        let pulse = DS.Dot(state: .working)
        let label = DS.label("Looking for more PCs…", font: DS.body, colour: DS.textMuted)
        // One of the list's children to VoiceOver, so stepping through it
        // reaches it as it did before the list was one.
        discoveryLabel = label
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
        field.setAccessibilityLabel("PC address")
        field.target = self
        field.action = #selector(manualCommitted)
        manualField = field

        let chip = DS.Chip("⌘K")
        // The shortcut is the menu's to say; read out, it is an orphan "⌘K".
        chip.setAccessibilityElement(false)
        let box = DS.FieldBox(field: field, trailing: chip)
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
            if item.paired, onForgetPairing != nil {
                row.onForgetPairing = { [weak self] in
                    // The list closes first: the question is asked over the
                    // window, and a list left open would sit over it.
                    self?.closeList(commit: false)
                    self?.onForgetPairing?(item)
                }
            }
            if item.kind == .recent, onForget != nil {
                row.onForget = { [weak self] in self?.onForget?(item.address) }
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
        // The highlight is the list's selection to VoiceOver, which otherwise
        // heard nothing as ↓ and ↑ moved it: the list has keyboard focus, and
        // says which of its rows is current when that changes.
        // Only when it moved: hover over the row already highlighted, or a
        // refresh that lands on it again, would say the same row over.
        let current = rows.indices.contains(highlighted) ? rows[highlighted] : nil
        if let listView, current !== announcedRow {
            announcedRow = current
            NSAccessibility.post(element: listView, notification: .selectedChildrenChanged)
        }
    }

    /// The open list's content, for VoiceOver: the rows, the discovery line
    /// and the field.
    private weak var listView: ListView?
    private weak var announcedRow: NSView?
    private weak var discoveryLabel: NSView?

    @objc private func manualCommitted() {
        let typed = ConnectWindow.dialable(manualField?.stringValue ?? "")
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
        listView = nil
        announcedRow = nil
        discoveryLabel = nil
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
        case 51, 117:
            // ⌘⌫ takes a used-before address off the list, as it removes an
            // item from a list across macOS. ⌫ alone is a typing mistake
            // being put right: it takes back the last key typed into the
            // list, never a row -- typed "19", the highlight on 192.168.1.40,
            // ⌫ would otherwise have taken that address away.
            if event.modifierFlags.contains(.command) {
                if rows.indices.contains(highlighted), let forget = rows[highlighted].onForget {
                    forget()
                }
            } else if !typeAhead.isEmpty {
                typeAhead.removeLast()
                typedAhead.removeLast()
                typeAheadCleared = Date()
                if let index = rows.firstIndex(where: { $0.searchKey.hasPrefix(typeAhead) }) {
                    highlighted = index
                    applyHighlight()
                }
            }
            return true
        default:
            return jumpByPrefix(event)
        }
    }

    private func move(by delta: Int) {
        guard !rows.isEmpty else { return }
        highlighted = min(max(highlighted + delta, 0), rows.count - 1)
        applyHighlight()
    }

    /// Typing jumps to the first row starting with what has been typed. After
    /// a pause a key starts afresh when it would match nothing added to what
    /// came before, so "of" finds OFFICE-TOWER but a later "o" finds the next
    /// o -- and "192.1", a pause, "6" still runs on to 192.168…
    ///
    /// What no row starts with is an address being typed: it goes to the
    /// last row's field, everything typed so far with it, and on from there.
    /// The keys were swallowed before, and somebody typing 192.168.1.40 into
    /// the open list saw nothing happen at all.
    private func jumpByPrefix(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control, .option]),
              let typed = event.characters, let first = typed.first,
              Self.typesAddress(first) else { return false }
        let key = typed.lowercased()
        let matches: (String) -> Int? = { prefix in
            self.rows.firstIndex { $0.searchKey.hasPrefix(prefix) }
        }
        if Date().timeIntervalSince(typeAheadCleared) > 1.0,
           matches(typeAhead + key) == nil, matches(key) != nil {
            typeAhead = ""
            typedAhead = ""
        }
        typeAhead += key
        typedAhead += typed
        typeAheadCleared = Date()
        if let index = matches(typeAhead) {
            highlighted = index
            applyHighlight()
        } else if let field = manualField {
            field.stringValue = typedAhead
            typeAhead = ""
            typedAhead = ""
            panel?.makeFirstResponder(field)
            let end = (field.stringValue as NSString).length
            field.currentEditor()?.selectedRange = NSRange(location: end, length: 0)
        }
        return true
    }

    /// A character an address or a PC's name can hold.
    static func typesAddress(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || ".-:_[]".contains(character)
    }

    // MARK: - Row

    private final class RowView: DS.Box {
        let address: String
        let kind: Item.Kind
        let searchKey: String
        var onClick: (() -> Void)?
        var onHover: ((Bool) -> Void)?
        /// Set for a used-before row: what takes it off the list.
        var onForget: (() -> Void)? { didSet { offerActions() } }
        /// Set for a paired PC's row: what forgets its token.
        var onForgetPairing: (() -> Void)? { didSet { offerActions() } }

        /// The row's menu, to VoiceOver as well.
        private func offerActions() {
            var actions: [NSAccessibilityCustomAction] = []
            if onForgetPairing != nil {
                actions.append(NSAccessibilityCustomAction(name: "Forget Pairing") { [weak self] in
                    self?.onForgetPairing?()
                    return true
                })
            }
            if onForget != nil {
                actions.append(NSAccessibilityCustomAction(name: "Remove from List") { [weak self] in
                    self?.onForget?()
                    return true
                })
            }
            setAccessibilityCustomActions(actions.isEmpty ? nil : actions)
        }

        /// The titles of the row's menu, for tests.
        var menuTitles: [String] { rowMenu()?.items.map(\.title) ?? [] }

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
            // Selected to VoiceOver is where the arrows are; the PC already
            // chosen is said as the row's value.
            setAccessibilitySelected(isHighlighted)
        }

        override func mouseEntered(with event: NSEvent) { onHover?(true) }
        override func mouseExited(with event: NSEvent) { onHover?(false) }
        override func mouseDown(with event: NSEvent) { onClick?() }

        override func menu(for event: NSEvent) -> NSMenu? { rowMenu() }

        private func rowMenu() -> NSMenu? {
            guard onForget != nil || onForgetPairing != nil else { return nil }
            let menu = NSMenu()
            if onForgetPairing != nil {
                menu.addItem(withTitle: "Forget Pairing…", action: #selector(forgetPairingChosen),
                             keyEquivalent: "").target = self
            }
            if onForget != nil {
                menu.addItem(withTitle: "Remove from List", action: #selector(forgetChosen),
                             keyEquivalent: "").target = self
            }
            return menu
        }

        @objc private func forgetChosen() { onForget?() }
        @objc private func forgetPairingChosen() { onForgetPairing?() }

        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .button }
        override func accessibilityLabel() -> String? {
            let more = detailLabel.stringValue
            return more.isEmpty ? titleLabel.stringValue : titleLabel.stringValue + ", " + more
        }
        override func accessibilityPerformPress() -> Bool {
            onClick?()
            return true
        }
        override func accessibilityValue() -> Any? { isChecked ? "chosen" : nil }
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

        // A list to VoiceOver, its highlighted row the selected one.
        var accessibleRows: (() -> [NSView])?
        var accessibleCurrent: (() -> NSView?)?
        var accessibleField: (() -> NSView?)?
        var accessibleFooter: (() -> NSView?)?
        override func isAccessibilityElement() -> Bool { true }
        override func accessibilityRole() -> NSAccessibility.Role? { .list }
        override func accessibilityLabel() -> String? { "PCs" }
        override func accessibilityChildren() -> [Any]? {
            (accessibleRows?() ?? []) + [accessibleFooter?(), accessibleField?()].compactMap { $0 }
        }
        override func accessibilitySelectedChildren() -> [Any]? {
            accessibleCurrent?().map { [$0] } ?? []
        }
    }
}
