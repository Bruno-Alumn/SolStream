import AppKit

/// Nocturne — the design system for SolStream's chrome.
///
/// A dark, near-neutral ground with one blurple accent used only as a line, a dot
/// or a glow. The premise is that an application whose job is to disappear should
/// be the darkest surface in the room, not the loudest: the chrome recedes to the
/// value of a bezel so the remote app is the brightest thing on screen.
///
/// State never gets its own hue. Healthy is the accent, degraded is the accent
/// with its chroma pulled down, dead is muted grey. That is what keeps a window
/// full of somebody else's colours from having to compete with ours.
public enum DS {

    // MARK: - Colour

    /// Each token is a pair: the dark value, then the light one. Light mode is the
    /// same ramp inverted rather than a separate palette, so a token means the
    /// same thing in both — "ground" is always the furthest back.
    private static func dynamic(dark: NSColor, light: NSColor) -> NSColor {
        NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        }
    }

    private static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    /// The furthest-back surface. Window backgrounds.
    public static let ground = dynamic(dark: hex(0x161826), light: hex(0xF3F5FE))
    /// Raised surfaces: cards, rows, fields.
    public static let chrome = dynamic(dark: hex(0x232532), light: hex(0xE4E7F5))
    /// A pressed or selected row.
    public static let chromeRaised = dynamic(dark: hex(0x292B31), light: hex(0xF9FAFE))
    /// The one accent. Lines, dots and glows only — never a filled area larger
    /// than a button.
    public static let accent = dynamic(dark: hex(0x9184D9), light: hex(0x5D5294))
    /// Accent for text on the ground, where the base value is too dim to read.
    public static let accentBright = dynamic(dark: hex(0xB5ABFC), light: hex(0x4B4190))
    /// Text inside an outlined action. Its own step in the design, lighter
    /// than `accentBright` — that one is the link-hover tone and reads hot
    /// against a border of the same hue.
    public static let accentOnOutline = dynamic(dark: hex(0xD2CEFD), light: hex(0x423A6A))
    /// A wash of accent, for the inside of a selected row or a focus ring.
    public static let accentTint = dynamic(dark: hex(0x423A6A), light: hex(0xE8E5FF))
    public static let textPrimary = dynamic(dark: hex(0xE9E9ED), light: hex(0x292B31))
    public static let textSecondary = dynamic(dark: hex(0xB2B6CA), light: hex(0x595D6C))
    /// Labels, units, anything explanatory.
    public static let textMuted = dynamic(dark: hex(0x9397AB), light: hex(0x595D6C))
    /// The dimmest readable step: placeholder text, disabled labels.
    public static let textFaint = dynamic(dark: hex(0x75798C), light: hex(0x424450))
    /// Separators. One pixel, never a border box.
    public static let hairline = dynamic(dark: hex(0x3F424D), light: hex(0xCFD3E5))
    /// Degraded: the accent with its chroma pulled down rather than a new hue.
    public static let degraded = dynamic(dark: hex(0x796CBF, alpha: 0.55),
                                         light: hex(0x796CBF, alpha: 0.55))
    /// Dead. Not red — nothing in this palette shouts.
    public static let dead = dynamic(dark: hex(0x595D6C), light: hex(0xB2B6CA))

    // MARK: - Type

    /// Falls back cleanly: Inter and IBM Plex Mono are the intended faces, but the
    /// system faces have the same proportions and nothing is bundled.
    private static func face(_ names: [String], size: CGFloat, weight: NSFont.Weight) -> NSFont {
        for name in names {
            if let font = NSFont(name: name, size: size) {
                return font
            }
        }
        return .systemFont(ofSize: size, weight: weight)
    }

    private static let sans = ["Inter", "SF Pro Text", "Helvetica Neue"]
    private static let mono = ["IBM Plex Mono", "SF Mono", "Menlo"]

    public static var title: NSFont { face(sans, size: 25, weight: .medium) }
    public static var section: NSFont { face(sans, size: 16, weight: .medium) }
    public static var body: NSFont { face(sans, size: 15, weight: .regular) }
    public static var secondary: NSFont { face(sans, size: 13, weight: .regular) }
    /// Numbers and state. Anything that changes while you watch it is monospaced,
    /// so it does not reflow as the value changes.
    public static var monoSmall: NSFont { face(mono, size: 11, weight: .regular) }
    public static var monoBody: NSFont { face(mono, size: 13, weight: .regular) }

    // MARK: - Metric

    public enum Metric {
        /// The streamed window's chrome. Deliberately thin: the app is the point.
        public static let titleBar: CGFloat = 28
        public static let corner: CGFloat = 10
        public static let rowCorner: CGFloat = 8
        public static let gutter: CGFloat = 20
        public static let rowHeight: CGFloat = 52
        public static let dot: CGFloat = 7
        public static let monogram: CGFloat = 32
    }

    // MARK: - Parts

    /// A small state dot. The only coloured thing on a row.
    public final class Dot: NSView {
        public enum State {
            case live, idle, dead
        }

        public var state: State = .idle {
            didSet { needsDisplay = true }
        }

        /// A slow pulse says "still listening". Under Reduce Motion it holds
        /// steady instead — the dot still says live, it just stops moving.
        public var pulses: Bool = false {
            didSet { updateAnimation() }
        }

        public init(state: State = .idle) {
            self.state = state
            super.init(frame: NSRect(x: 0, y: 0, width: Metric.dot, height: Metric.dot))
            wantsLayer = true
            translatesAutoresizingMaskIntoConstraints = false
            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Metric.dot),
                heightAnchor.constraint(equalToConstant: Metric.dot),
            ])
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public override func draw(_ dirtyRect: NSRect) {
            let colour: NSColor
            switch state {
            case .live: colour = DS.accent
            case .idle: colour = DS.textFaint
            case .dead: colour = DS.dead
            }
            colour.setFill()
            NSBezierPath(ovalIn: bounds.insetBy(dx: 0.5, dy: 0.5)).fill()
        }

        private func updateAnimation() {
            layer?.removeAnimation(forKey: "pulse")
            guard pulses, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            let fade = CABasicAnimation(keyPath: "opacity")
            fade.fromValue = 1.0
            fade.toValue = 0.35
            fade.duration = 1.1
            fade.autoreverses = true
            fade.repeatCount = .infinity
            layer?.add(fade, forKey: "pulse")
        }
    }

    /// A deterministic monogram, for use until the agent can extract real icons.
    ///
    /// Tinted by hashing the executable path into four accent/neutral steps, so a
    /// given application is always the same colour. Occupies the same slot and
    /// size a real icon will, so icons drop in later without reflow.
    public final class Monogram: NSView {
        private let label = NSTextField(labelWithString: "")
        private var tint: NSColor = DS.chromeRaised

        public init(name: String, key: String) {
            super.init(frame: NSRect(x: 0, y: 0, width: Metric.monogram, height: Metric.monogram))
            wantsLayer = true
            layer?.cornerRadius = 7
            layer?.cornerCurve = .continuous
            translatesAutoresizingMaskIntoConstraints = false

            label.stringValue = Self.initials(from: name)
            label.font = DS.monoSmall
            label.alignment = .center
            label.translatesAutoresizingMaskIntoConstraints = false
            addSubview(label)

            NSLayoutConstraint.activate([
                widthAnchor.constraint(equalToConstant: Metric.monogram),
                heightAnchor.constraint(equalToConstant: Metric.monogram),
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
            tint = .clear
            needsDisplay = true
        }

        private lazy var iconLayer: CALayer = {
            let sublayer = CALayer()
            layer?.addSublayer(sublayer)
            return sublayer
        }()

        public override func updateLayer() {
            layer?.backgroundColor = tint.cgColor
        }

        private func apply(step: Int) {
            switch step {
            case 0: tint = DS.accentTint;   label.textColor = DS.accentOnOutline
            case 1: tint = DS.chromeRaised; label.textColor = DS.accentBright
            case 2: tint = DS.chromeRaised; label.textColor = DS.textSecondary
            default: tint = DS.chrome;      label.textColor = DS.textMuted
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

    /// A small tag. Padded properly: a background drawn tight around the glyphs
    /// reads as a rendering mistake rather than a tag.
    public final class Chip: NSTextField {
        private let padding = NSSize(width: 14, height: 5)

        public init(_ text: String) {
            super.init(frame: .zero)
            stringValue = text
            font = DS.monoSmall
            textColor = DS.textMuted
            isEditable = false
            isBordered = false
            isSelectable = false
            drawsBackground = false
            alignment = .center
            wantsLayer = true
            layer?.cornerRadius = 4
            layer?.cornerCurve = .continuous
            translatesAutoresizingMaskIntoConstraints = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width += padding.width
            size.height += padding.height
            return size
        }

        public override func updateLayer() {
            layer?.backgroundColor = DS.chromeRaised.cgColor
        }

        public override func draw(_ dirtyRect: NSRect) {
            // Centre the text inside the padded box.
            let inset = bounds.insetBy(dx: padding.width / 2, dy: padding.height / 2)
            attributedStringValue.draw(in: inset)
        }
    }

    /// A one-pixel separator. Never a border box — the design uses single lines.
    public static func hairlineView() -> NSView {
        let line = NSView()
        line.wantsLayer = true
        line.translatesAutoresizingMaskIntoConstraints = false
        line.layer?.backgroundColor = hairline.cgColor
        line.heightAnchor.constraint(equalToConstant: 1).isActive = true
        return line
    }

    /// The design's outlined action: a hairline box that fills with accent tint on
    /// hover, rather than a solid button competing with the content.
    public final class OutlinedButton: NSButton {
        private var isPrimary: Bool = false

        public init(title: String, primary: Bool = false, target: AnyObject?, action: Selector?) {
            super.init(frame: .zero)
            self.isPrimary = primary
            self.title = title
            self.target = target
            self.action = action
            isBordered = false
            wantsLayer = true
            font = DS.secondary
            layer?.cornerRadius = 6
            layer?.cornerCurve = .continuous
            layer?.borderWidth = 1
            contentTintColor = primary ? DS.accentOnOutline : DS.textSecondary
            translatesAutoresizingMaskIntoConstraints = false
            heightAnchor.constraint(equalToConstant: 30).isActive = true
            // A minimum width so short labels ("Quit") still read as a button
            // rather than a box drawn tight around three letters.
            widthAnchor.constraint(greaterThanOrEqualToConstant: primary ? 108 : 76).isActive = true
            restyle()
        }

        /// NSButton sizes to its title; the design wants breathing room inside the
        /// outline, so pad the intrinsic width.
        public override var intrinsicContentSize: NSSize {
            var size = super.intrinsicContentSize
            size.width += 28
            return size
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { fatalError() }

        public override func updateLayer() {
            restyle()
        }

        private func restyle() {
            layer?.borderColor = (isPrimary ? DS.accent : DS.hairline).cgColor
            layer?.backgroundColor = (isPrimary ? DS.accentTint : .clear).cgColor
            attributedTitle = NSAttributedString(string: title, attributes: [
                .font: DS.secondary,
                // This is what actually draws — an attributedTitle wins over
                // contentTintColor, so both have to agree.
                .foregroundColor: isPrimary ? DS.accentOnOutline : DS.textSecondary,
            ])
        }

        public func setPrimary(_ primary: Bool) {
            isPrimary = primary
            restyle()
        }
    }
}
