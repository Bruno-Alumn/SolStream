import AppKit

/// Solar — the design system for SolStream's chrome. The spec is
/// `docs/design-system.md`; the Windows host carries the same values in
/// `host_theme.h`, and the two change together or not at all.
///
/// A deep, neutral graphite chrome — still the darkest thing on screen, so a
/// streamed application stays the brightest — and ONE warm accent, sun amber,
/// spent on the single most important thing on each screen: the primary button,
/// the selected row, the focus ring, a working dot. Everything else is neutral.
///
/// It replaces Nocturne, whose every surface sat within a few steps of navy and
/// whose only accent was a desaturated purple used as a line. That was coherent
/// but dim: with monospace carrying most labels as well, nothing on a screen was
/// obviously the first thing to look at.
///
/// State gets real hues now, but only two and only small: a green dot for live
/// and a coral one for failed. The words still carry the severity; the colour
/// just makes it findable.
public enum DS {

    // MARK: - Colour

    /// Each token is a role with a dark and a light value, so drawing code never
    /// needs to know which theme it is in. The Increase Contrast variants are
    /// optional and only the edges use them: a 1px line is the one thing in this
    /// palette that genuinely depends on that setting.
    private static func dynamic(dark: NSColor, light: NSColor,
                                darkContrast: NSColor? = nil,
                                lightContrast: NSColor? = nil) -> NSColor {
        NSColor(name: nil) { appearance in
            switch appearance.bestMatch(from: [.darkAqua, .aqua,
                                               .accessibilityHighContrastDarkAqua,
                                               .accessibilityHighContrastAqua]) {
            case .accessibilityHighContrastDarkAqua?: return darkContrast ?? dark
            case .accessibilityHighContrastAqua?: return lightContrast ?? light
            case .darkAqua?: return dark
            default: return light
            }
        }
    }

    private static func hex(_ value: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: 1)
    }

    /// Window background. The furthest-back surface.
    public static let ground = dynamic(dark: hex(0x0E0F12), light: hex(0xF7F6F3))
    /// Cards, fields, the list background.
    public static let surface = dynamic(dark: hex(0x17191E), light: hex(0xFFFFFF))
    /// A hovered row, a secondary button, a chip.
    public static let raised = dynamic(dark: hex(0x20232A), light: hex(0xEFEDE8))
    /// Separators and resting borders. One pixel, never a box.
    public static let hairline = dynamic(dark: hex(0x2A2D35), light: hex(0xE4E1DA),
                                         darkContrast: hex(0x3A3E48),
                                         lightContrast: hex(0xCFCBC2))
    /// Hovered borders, and the edge of a surface that floats — a list panel or
    /// a popover. A step stronger than `hairline`, because it has to hold its
    /// own against whatever it is covering rather than divide two things on the
    /// same plane.
    public static let edge = dynamic(dark: hex(0x3A3E48), light: hex(0xCFCBC2),
                                     darkContrast: hex(0x7C818D),
                                     lightContrast: hex(0x6A6F79))

    public static let text = dynamic(dark: hex(0xF2F2F4), light: hex(0x17181B))
    /// Supporting text: the sentence under a title, a row's second line.
    public static let textSecondary = dynamic(dark: hex(0xA9ADB8), light: hex(0x4A4E57))
    /// Labels and captions.
    public static let textMuted = dynamic(dark: hex(0x7C818D), light: hex(0x6A6F79))
    /// Placeholders and disabled labels ONLY — never anything that must be read.
    public static let textFaint = dynamic(dark: hex(0x5A5F6B), light: hex(0x9A9EA6))

    /// Sun amber. The primary button's fill, a working dot, the focus ring, the
    /// caret. One thing per screen.
    public static let accent = dynamic(dark: hex(0xFFB547), light: hex(0xF59E0B))
    public static let accentHover = dynamic(dark: hex(0xFFC56E), light: hex(0xFBB13C))
    public static let accentPressed = dynamic(dark: hex(0xE89A2A), light: hex(0xD97706))
    /// Text on a filled accent. The same near-black in both themes: amber is
    /// light in both, so it always wants dark ink.
    public static let onAccent = dynamic(dark: hex(0x1A1205), light: hex(0x1A1205))
    /// The accent used as text or a 1px line on `ground`/`surface`, where the
    /// fill value is too pale to read in the light theme.
    public static let accentInk = dynamic(dark: hex(0xFFC66B), light: hex(0xB45309))
    /// A selected row, text selection, a primary tag's ground.
    public static let accentTint = dynamic(dark: hex(0x2B2418), light: hex(0xFDF0DA))
    /// Text that sits on `accentTint`.
    public static let accentTintInk = dynamic(dark: hex(0xFFD699), light: hex(0x8A4B06))

    /// Live / connected. A dot, never a fill.
    public static let live = dynamic(dark: hex(0x4ADE80), light: hex(0x16A34A))
    /// Failed. A dot, or the words of a destructive action.
    public static let danger = dynamic(dark: hex(0xFF6B6B), light: hex(0xDC2626))

    /// A dynamic colour pinned to one appearance, for the few surfaces that
    /// hold the dark theme whatever the system says (the card over video).
    public static func resolved(_ colour: NSColor, in appearance: NSAppearance) -> CGColor {
        var result = colour.cgColor
        appearance.performAsCurrentDrawingAppearance { result = colour.cgColor }
        return result
    }

    // MARK: - Type

    /// SF Pro for all UI text. SF Mono only for addresses, tokens and live
    /// numbers — Nocturne set most labels in mono, and a screen where
    /// everything is "data" has no data in it. Labels are sentence case; no
    /// caps, no tracking.
    public static var display: NSFont { .systemFont(ofSize: 26, weight: .semibold) }
    public static var title: NSFont { .systemFont(ofSize: 20, weight: .semibold) }
    public static var headline: NSFont { .systemFont(ofSize: 15, weight: .semibold) }
    public static var body: NSFont { .systemFont(ofSize: 13, weight: .regular) }
    public static var caption: NSFont { .systemFont(ofSize: 11, weight: .medium) }
    /// Addresses, tokens, and numbers that change while you watch them — which
    /// is the reason they are monospaced: they do not reflow as the value moves.
    public static var mono: NSFont { .monospacedSystemFont(ofSize: 12, weight: .regular) }

    // MARK: - Space and shape

    /// The spacing scale. Nothing on screen is spaced by a number not in it.
    public enum Space {
        public static let x1: CGFloat = 4
        public static let x2: CGFloat = 8
        public static let x3: CGFloat = 12
        public static let x4: CGFloat = 16
        public static let x5: CGFloat = 20
        public static let x6: CGFloat = 24
        public static let x8: CGFloat = 32
        public static let x12: CGFloat = 48
    }

    public enum Metric {
        /// The streamed window's chrome. Deliberately thin: the app is the point.
        public static let titleBar: CGFloat = 28
        /// Every window's content inset.
        public static let inset: CGFloat = 24
        public static let buttonHeight: CGFloat = 32
        public static let buttonRadius: CGFloat = 8
        public static let fieldHeight: CGFloat = 36
        public static let fieldRadius: CGFloat = 8
        /// Two-line rows; `rowHeightCompact` for one line.
        public static let rowHeight: CGFloat = 48
        public static let rowHeightCompact: CGFloat = 36
        public static let rowRadius: CGFloat = 8
        public static let cardRadius: CGFloat = 12
        public static let cardInset: CGFloat = 16
        public static let chipHeight: CGFloat = 20
        public static let chipRadius: CGFloat = 6
        public static let tile: CGFloat = 32
        public static let tileRadius: CGFloat = 8
        public static let dot: CGFloat = 8
        /// The accent bar on a selected row's leading edge.
        public static let selectionBar: CGFloat = 3
    }

    // MARK: - Parts

    /// A layer-backed rectangle whose colours are re-resolved every time it is
    /// drawn.
    ///
    /// `layer.backgroundColor = colour.cgColor` resolves a dynamic colour ONCE,
    /// against whatever appearance happens to be current at that moment, and
    /// never again — so a view built that way keeps the theme it was born in
    /// when the Mac switches between light and dark. Doing it in `updateLayer`
    /// is what makes it follow: AppKit sets the view's own appearance as current
    /// around that call, and calls it again when the appearance changes.
    open class Box: NSView {
        public var fill: NSColor? { didSet { needsDisplay = true } }
        public var stroke: NSColor? { didSet { needsDisplay = true } }
        public var strokeWidth: CGFloat = 1 { didSet { needsDisplay = true } }
        public var radius: CGFloat = 0 { didSet { needsDisplay = true } }

        public init(fill: NSColor? = nil, stroke: NSColor? = nil, radius: CGFloat = 0) {
            self.fill = fill
            self.stroke = stroke
            self.radius = radius
            super.init(frame: .zero)
            wantsLayer = true
            layerContentsRedrawPolicy = .onSetNeedsDisplay
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) { fatalError() }

        open override var wantsUpdateLayer: Bool { true }

        open override func updateLayer() {
            guard let layer else { return }
            layer.backgroundColor = fill?.cgColor
            layer.borderColor = stroke?.cgColor
            layer.borderWidth = stroke == nil ? 0 : strokeWidth
            layer.cornerRadius = radius
            layer.cornerCurve = .continuous
        }

        open override func viewDidChangeEffectiveAppearance() {
            super.viewDidChangeEffectiveAppearance()
            needsDisplay = true
        }
    }

    /// A card: `surface`, a hairline edge, radius 12. Content goes inside at
    /// `Metric.cardInset`.
    public static func card() -> Box {
        Box(fill: surface, stroke: hairline, radius: Metric.cardRadius)
    }

    /// A one-pixel separator. Never a border box — the design uses single lines.
    public static func hairlineView() -> NSView {
        let line = Box(fill: hairline)
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// A label in one of the design's roles.
    public static func label(_ string: String, font: NSFont = DS.body,
                             colour: NSColor = DS.text) -> NSTextField {
        let label = NSTextField(labelWithString: string)
        label.font = font
        label.textColor = colour
        label.lineBreakMode = .byTruncatingTail
        return label
    }

    /// A caption line that mixes words with an address or a number: the words in
    /// `caption`, the data in `mono`, so the one font change on the line marks
    /// the part you might copy.
    public static func detail(_ parts: [(String, isData: Bool)],
                              colour: NSColor = DS.textMuted) -> NSAttributedString {
        let result = NSMutableAttributedString()
        for (index, part) in parts.enumerated() {
            if index > 0 {
                result.append(NSAttributedString(string: "  ·  ", attributes: [
                    .font: caption, .foregroundColor: textFaint,
                ]))
            }
            result.append(NSAttributedString(string: part.0, attributes: [
                .font: part.isData ? NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
                                   : caption,
                .foregroundColor: colour,
            ]))
        }
        return result
    }

    /// A small state dot.
    ///
    /// `live` is connected, `working` is the accent and pulses while something is
    /// under way, `danger` is failed, `idle` is nothing known. Under Reduce
    /// Motion the pulse holds steady instead — the dot still says working, it
    /// just stops moving.
    public final class Dot: NSView {
        public enum State {
            case live, working, danger, idle
        }

        public var state: State = .idle {
            didSet { needsDisplay = true; updateAnimation() }
        }

        /// A working dot that should NOT pulse — a steady "attention" rather than
        /// "in progress", such as a stream running below its usual frame rate.
        public var holdsSteady = false {
            didSet { updateAnimation() }
        }

        private var displayOptionsObserver: NSObjectProtocol?

        public init(state: State = .idle) {
            self.state = state
            super.init(frame: NSRect(x: 0, y: 0, width: Metric.dot, height: Metric.dot))
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Metric.dot),
                heightAnchor.constraint(equalToConstant: Metric.dot),
            ])
            // Reduce Motion can be switched on while a dot is pulsing; it has to
            // stop then, not at the next state change.
            displayOptionsObserver = NSWorkspace.shared.notificationCenter.addObserver(
                forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
                object: nil, queue: .main) { [weak self] _ in self?.updateAnimation() }
            updateAnimation()
        }

        deinit {
            if let displayOptionsObserver {
                NSWorkspace.shared.notificationCenter.removeObserver(displayOptionsObserver)
            }
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public override func draw(_ dirtyRect: NSRect) {
            let colour: NSColor
            switch state {
            case .live: colour = DS.live
            case .working: colour = DS.accent
            case .danger: colour = DS.danger
            case .idle: colour = DS.textFaint
            }
            colour.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            // A layer animation does not survive the layer being torn down and
            // rebuilt, which happens when a view changes windows.
            updateAnimation()
        }

        private func updateAnimation() {
            layer?.removeAnimation(forKey: "pulse")
            guard state == .working, !holdsSteady,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.3
            fade.duration = 0.9
            fade.autoreverses = true
            fade.repeatCount = .infinity
            fade.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            layer?.add(fade, forKey: "pulse")
        }
    }

    /// An application's tile: a deterministic monogram until the host sends the
    /// real icon.
    ///
    /// Tinted by hashing the executable path into four steps, so a given
    /// application is always the same tile. Occupies the same slot and size a
    /// real icon does, so the icon drops in later without reflow.
    public final class Monogram: NSView {
        private let label = NSTextField(labelWithString: "")
        private var tint: NSColor? = DS.raised

        public init(name: String, key: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: Metric.tile, height: Metric.tile))
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false

            label.stringValue = Self.initials(from: name)
            label.font = .systemFont(ofSize: 12, weight: .semibold)
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Metric.tile),
                heightAnchor.constraint(equalToConstant: Metric.tile),
                label.centerXAnchor.constraint(equalTo: centerXAnchor),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            apply(step: Self.step(for: key))
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        /// Swap in the real icon once the host has produced one. The tile keeps
        /// its slot and size, so nothing reflows when it arrives.
        public func setIcon(_ image: CGImage?) {
            guard let image else { return }
            iconLayer.contents = image
            iconLayer.frame = bounds.insetBy(dx: 2, dy: 2)
            iconLayer.contentsGravity = .resizeAspect
            label.isHidden = true
            tint = nil
            needsDisplay = true
        }

        private lazy var iconLayer: CALayer = {
            let sublayer = CALayer()
            layer?.addSublayer(sublayer)
            return sublayer
        }()

        // Without this `updateLayer` is never called, and the tile was drawn
        // with no ground at all.
        public override var wantsUpdateLayer: Bool { true }

        public override func updateLayer() {
            layer?.backgroundColor = tint?.cgColor
            layer?.cornerRadius = Metric.tileRadius
            layer?.cornerCurve = .continuous
        }

        private func apply(step: Int) {
            switch step {
            case 0: tint = DS.accentTint; label.textColor = DS.accentTintInk
            case 1: tint = DS.raised;     label.textColor = DS.accentInk
            case 2: tint = DS.raised;     label.textColor = DS.textSecondary
            default: tint = DS.raised;    label.textColor = DS.textMuted
            }
            needsDisplay = true
        }

        static func initials(from name: String) -> String {
            let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
                .filter { $0.first?.isLetter == true || $0.first?.isNumber == true }
            if words.count >= 2 {
                return String(words[0].prefix(1) + words[1].prefix(1)).uppercased()
            }
            let letters = name.filter { $0.isLetter || $0.isNumber }
            return String(letters.prefix(2)).uppercased()
        }

        /// FNV-1a, so the same path always lands on the same step regardless of
        /// where the list happens to put it.
        static func step(for key: String) -> Int {
            var hash: UInt64 = 0xCBF2_9CE4_8422_2325
            for byte in key.lowercased().utf8 {
                hash ^= UInt64(byte)
                hash = hash &* 0x0000_0100_0000_01B3
            }
            return Int(hash % 4)
        }
    }

    /// A small tag: `raised`, caption text in `textMuted`, radius 6, 20 high.
    /// Padded properly — a background drawn tight around the glyphs reads as a
    /// rendering mistake rather than a tag.
    public final class Chip: Box {
        public let label: NSTextField

        public init(_ text: String) {
            label = DS.label(text, font: DS.caption, colour: DS.textMuted)
            super.init(fill: DS.raised, radius: Metric.chipRadius)
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)
            NSLayoutConstraint.activate([
                heightAnchor.constraint(equalToConstant: Metric.chipHeight),
                label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.x2),
                label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.x2),
                label.centerYAnchor.constraint(equalTo: centerYAnchor),
            ])
            setContentHuggingPriority(.required, for: .horizontal)
            setContentCompressionResistancePriority(.required, for: .horizontal)
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) { fatalError() }
    }

    /// A text field the way the design draws every one of them: no bezel and no
    /// system focus ring of its own — `FieldBox` draws both — and an accent caret.
    ///
    /// The caret is the fiddly part. `insertionPointColor` belongs to
    /// `NSTextView`, and an `NSTextField` does not own its editor — the window
    /// lends it one on focus and takes it back afterwards. So the colour has to
    /// be applied to that borrowed editor each time the field gains focus, not
    /// once at construction.
    public final class Field: NSTextField {
        /// Placeholder text, drawn in `textFaint` rather than the system's grey.
        public var placeholder: String {
            didSet { applyPlaceholder() }
        }

        public init(placeholder: String, mono: Bool = false, readOnly: Bool = false) {
            self.placeholder = placeholder
            super.init(frame: .zero)
            font = mono ? DS.mono : DS.body
            textColor = readOnly ? DS.textSecondary : DS.text
            isBordered = false
            isBezeled = false
            drawsBackground = false
            focusRingType = .none
            isEditable = !readOnly
            isSelectable = true
            lineBreakMode = .byTruncatingTail
            cell?.usesSingleLineMode = true
            cell?.wraps = false
            cell?.isScrollable = true
            translatesAutoresizingMaskIntoConstraints = false
            applyPlaceholder()
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

        private func applyPlaceholder() {
            placeholderAttributedString = NSAttributedString(string: placeholder, attributes: [
                .font: font ?? DS.body,
                .foregroundColor: DS.textFaint,
            ])
        }

        public override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if let editor = currentEditor() as? NSTextView {
                editor.insertionPointColor = DS.accent
                // Selection is the same accent tint a selected row uses, rather
                // than the system blue.
                editor.selectedTextAttributes = [
                    .backgroundColor: DS.accentTint,
                    .foregroundColor: DS.text,
                ]
            }
            return became
        }
    }

    /// The visible field: `surface`, a 1px hairline, and — while the field inside
    /// has focus — a 2px accent ring in place of that hairline.
    ///
    /// Focus is read from the window's first responder rather than from the
    /// field's own begin/end callbacks. Those fire on editing, not on focus, so a
    /// field clicked into and left without typing would keep its ring.
    public final class FieldBox: Box {
        public let field: Field
        private var observation: NSKeyValueObservation?

        /// - Parameters:
        ///   - leading: an icon before the text (16pt), such as a magnifier.
        ///   - trailing: an accessory after it, such as a shortcut chip.
        public init(field: Field, leading: NSView? = nil, trailing: NSView? = nil) {
            self.field = field
            super.init(fill: DS.surface, stroke: DS.hairline, radius: Metric.fieldRadius)
            addSubview(field)
            var constraints = [
                heightAnchor.constraint(equalToConstant: Metric.fieldHeight),
                field.centerYAnchor.constraint(equalTo: centerYAnchor),
            ]
            if let leading {
                leading.translatesAutoresizingMaskIntoConstraints = false
                addSubview(leading)
                constraints += [
                    leading.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Space.x3),
                    leading.centerYAnchor.constraint(equalTo: centerYAnchor),
                    field.leadingAnchor.constraint(equalTo: leading.trailingAnchor, constant: Space.x2),
                ]
            } else {
                constraints.append(field.leadingAnchor.constraint(equalTo: leadingAnchor,
                                                                  constant: Space.x3))
            }
            if let trailing {
                trailing.translatesAutoresizingMaskIntoConstraints = false
                addSubview(trailing)
                constraints += [
                    trailing.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -Space.x2),
                    trailing.centerYAnchor.constraint(equalTo: centerYAnchor),
                    field.trailingAnchor.constraint(equalTo: trailing.leadingAnchor, constant: -Space.x2),
                ]
            } else {
                constraints.append(field.trailingAnchor.constraint(equalTo: trailingAnchor,
                                                                   constant: -Space.x3))
            }
            NSLayoutConstraint.activate(constraints)
        }

        @available(*, unavailable)
        public required init?(coder: NSCoder) { fatalError() }

        public override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            observation = window?.observe(\.firstResponder, options: [.initial, .new]) {
                [weak self] window, _ in
                DispatchQueue.main.async { self?.setFocused(Self.holdsFocus(window, field: self?.field)) }
            }
        }

        private static func holdsFocus(_ window: NSWindow, field: Field?) -> Bool {
            guard let field else { return false }
            if window.firstResponder === field { return true }
            // While editing, the first responder is the window's shared field
            // editor, whose delegate is the field being edited.
            if let editor = window.firstResponder as? NSTextView,
               editor.isFieldEditor, editor.delegate === field { return true }
            return false
        }

        private func setFocused(_ focused: Bool) {
            stroke = focused ? DS.accent : DS.hairline
            strokeWidth = focused ? 2 : 1
        }

        /// The padding is part of the field: a click there should not miss.
        public override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(field)
        }
    }

    /// The design's two buttons.
    ///
    /// `primary` is the screen's one way forward: an `accent` fill with
    /// `onAccent` text, brightening on hover and deepening while pressed.
    /// `secondary` is everything else: `raised`, a hairline that lifts to `edge`
    /// on hover. Drawn entirely here rather than through the cell, so the fill,
    /// the label and the hover all come from the same tokens in both themes.
    public final class Button: NSButton {
        public enum Style { case primary, secondary }

        public var style: Style { didSet { needsDisplay = true } }
        private var hovering = false { didSet { needsDisplay = true } }
        private var tracking: NSTrackingArea?

        /// Body size at medium weight: a label on a fill looks thinner than the
        /// same weight on the ground, and medium puts it back level.
        private static let labelFont = NSFont.systemFont(ofSize: 13, weight: .medium)

        public init(title: String, style: Style = .secondary, target: AnyObject?, action: Selector?) {
            self.style = style
            super.init(frame: .zero)
            self.title = title
            self.target = target
            self.action = action
            isBordered = false
            setButtonType(.momentaryPushIn)
            focusRingType = .default
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: Metric.buttonHeight).isActive = true
            // A minimum width so a short label ("Quit") still reads as a button
            // rather than a box drawn tight around three letters.
            widthAnchor.constraint(greaterThanOrEqualToConstant: 80).isActive = true
            setContentHuggingPriority(.required, for: .horizontal)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public override var title: String {
            didSet { invalidateIntrinsicContentSize(); needsDisplay = true }
        }

        public override var isEnabled: Bool {
            didSet { needsDisplay = true }
        }

        public override var isHighlighted: Bool {
            didSet { needsDisplay = true }
        }

        public override var intrinsicContentSize: NSSize {
            let width = (title as NSString).size(withAttributes: [.font: Self.labelFont]).width
            return NSSize(width: ceil(width) + Space.x4 * 2, height: Metric.buttonHeight)
        }

        public override func updateTrackingAreas() {
            super.updateTrackingAreas()
            if let tracking { removeTrackingArea(tracking) }
            let area = NSTrackingArea(rect: .zero,
                                      options: [.mouseEnteredAndExited, .activeInActiveApp,
                                                .inVisibleRect],
                                      owner: self)
            addTrackingArea(area)
            tracking = area
        }

        public override func mouseEntered(with event: NSEvent) { hovering = true }
        public override func mouseExited(with event: NSEvent) { hovering = false }

        public override func draw(_ dirtyRect: NSRect) {
            let pressed = isHighlighted || (cell?.isHighlighted ?? false)
            let shape = NSBezierPath(roundedRect: bounds,
                                     xRadius: Metric.buttonRadius, yRadius: Metric.buttonRadius)
            let ink: NSColor
            switch style {
            case .primary:
                // Disabled, it gives the amber up entirely rather than fading
                // it: amber at partial opacity over graphite is a muddy brown
                // that reads as a colour of its own, not as "not yet".
                guard isEnabled else {
                    DS.raised.setFill()
                    shape.fill()
                    ink = DS.textFaint
                    break
                }
                (pressed ? DS.accentPressed : (hovering ? DS.accentHover : DS.accent)).setFill()
                shape.fill()
                ink = DS.onAccent
            case .secondary:
                (pressed ? DS.hairline : DS.raised).setFill()
                shape.fill()
                let edge = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                        xRadius: Metric.buttonRadius - 0.5,
                                        yRadius: Metric.buttonRadius - 0.5)
                ((hovering && isEnabled) ? DS.edge : DS.hairline).setStroke()
                edge.lineWidth = 1
                edge.stroke()
                ink = isEnabled ? DS.text : DS.textFaint
            }
            let label = NSAttributedString(string: title, attributes: [
                .font: Self.labelFont,
                .foregroundColor: ink,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: (bounds.width - size.width) / 2,
                                   y: (bounds.height - size.height) / 2))
        }

        // Full Keyboard Access draws the ring around the shape that is actually
        // there, rather than a square around a rounded button.
        public override func drawFocusRingMask() {
            NSBezierPath(roundedRect: bounds, xRadius: Metric.buttonRadius,
                         yRadius: Metric.buttonRadius).fill()
        }

        public override var focusRingMaskBounds: NSRect { bounds }
    }
}
