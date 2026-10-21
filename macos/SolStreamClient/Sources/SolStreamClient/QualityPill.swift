import AppKit
import DesignSystem
import InputCapture
import SolStreamLogging

/// A dot and an fps count, living in the streamed window's title bar.
///
/// It is always there and it never moves, which is the point: quality
/// information that appears only when something is wrong teaches you to dread it,
/// and one that jumps around draws the eye away from the application. Click it for
/// the detail. Nothing about quality is ever pushed at you.
///
/// Drawn as a Solar chip — `raised`, radius 6, 20 high — with the number in mono,
/// because it is a live number and must not reflow as it changes.
final class QualityPill: DS.Box {

    struct Stats {
        var fps: Int = 0
        var latencyMs: Int?
        var bitrateMbps: Double?
        var droppedFrames: UInt64 = 0
        var totalFrames: UInt64 = 0
        var audioActive: Bool = false
        var hostDisplay: String = ""
    }

    private let dot = DS.Dot(state: .idle)
    private let label = NSTextField(labelWithString: "—")
    private var popover: NSPopover?

    var stats = Stats() {
        didSet { refresh() }
    }

    init() {
        super.init(fill: DS.raised, radius: DS.Metric.chipRadius)

        label.font = DS.mono
        label.textColor = DS.textSecondary
        label.alignment = .center
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Stream quality")

        for child in [dot, label] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            // Fixed, so "9" to "120" never nudges the title bar.
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: DS.Metric.chipHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.x2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: DS.Space.x1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.x2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        label.stringValue = stats.fps > 0 ? "\(stats.fps)" : "—"
        setAccessibilityValue(stats.fps > 0 ? "\(stats.fps) frames per second" : "no frames")
        // Frames arriving is green, whatever the rate; nothing arriving is the
        // idle grey. Not amber below some threshold: capture is change-driven,
        // so a still application streams at 15 fps and is perfectly healthy —
        // an amber dot there cried wolf on every dialog. A stream that really
        // is in trouble says so in the status card, in words.
        dot.state = stats.fps > 0 ? .live : .idle
    }

    override func mouseDown(with event: NSEvent) {
        togglePopover()
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let content = NSViewController()
        content.view = buildDetail()

        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    func buildDetail() -> NSView {
        func metric(_ value: String, _ caption: String) -> NSView {
            // Headline size with monospaced digits: the figure is the point of
            // the popover, and it must not reflow as it changes.
            let big = DS.label(value, font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold))
            let small = DS.label(caption, font: DS.caption, colour: DS.textMuted)
            let column = NSStackView(views: [big, small])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            return column
        }

        let row = NSStackView(views: [
            metric(stats.fps > 0 ? "\(stats.fps)" : "—", "fps"),
            metric(stats.latencyMs.map { "\($0) ms" } ?? "—", "latency"),
            metric(stats.bitrateMbps.map { String(format: "%.0f Mb/s", $0) } ?? "—", "bandwidth"),
        ])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = DS.Space.x5

        let dropped = NSTextField(labelWithString: "")
        dropped.attributedStringValue = DS.detail([
            ("\(stats.droppedFrames) dropped of \(Self.compact(stats.totalFrames))", isData: true),
        ])

        func line(_ caption: String, _ value: String, isData: Bool = false) -> NSView {
            let left = DS.label(caption, font: DS.body, colour: DS.textMuted)
            let right = DS.label(value, font: isData ? DS.mono : DS.body, colour: DS.textSecondary)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [left, spacer, right])
            stack.orientation = .horizontal
            return stack
        }

        // The mouse mode lives here, beside the numbers it affects, rather than
        // in a menu: it is a per-moment choice -- a game now, a spreadsheet in
        // a minute -- and this is the one control on the streamed window.
        let modes = NSSegmentedControl(labels: ["Desktop", "Gaming"], trackingMode: .selectOne,
                                       target: self, action: #selector(pointerModeChosen(_:)))
        modes.selectedSegment = InputCapture.pointerMode == .gaming ? 1 : 0
        modes.segmentStyle = .rounded
        modes.selectedSegmentBezelColor = DS.accent
        // Hugs its labels, so the spacer -- not the control -- takes the slack
        // and the toggle sits against the right edge like the values above it.
        modes.setContentHuggingPriority(.required, for: .horizontal)
        modes.setAccessibilityLabel("Mouse mode")
        let mouseLabel = DS.label("Mouse", font: DS.body, colour: DS.textMuted)
        let modeSpacer = NSView()
        modeSpacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let mouseRow = NSStackView(views: [mouseLabel, modeSpacer, modes])
        mouseRow.orientation = .horizontal
        let mouseHint = DS.label(Self.pointerHint(InputCapture.pointerMode),
                                 font: DS.caption, colour: DS.textMuted)
        mouseHint.lineBreakMode = .byWordWrapping
        mouseHint.maximumNumberOfLines = 2
        mouseHint.preferredMaxLayoutWidth = 280
        self.mouseHint = mouseHint

        let stack = NSStackView(views: [
            row,
            dropped,
            DS.hairlineView(),
            line("Audio", stats.audioActive ? "playing" : "silent — nothing playing on the PC"),
            line("Host display", stats.hostDisplay.isEmpty ? "—" : stats.hostDisplay, isData: true),
            DS.hairlineView(),
            mouseRow,
            mouseHint,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.x3
        stack.setCustomSpacing(DS.Space.x2, after: row)
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.x5, left: DS.Space.x5,
                                        bottom: DS.Space.x4, right: DS.Space.x5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 262))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Space.x5 * 2),
            dropped.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Space.x5 * 2),
        ])
        for view in stack.arrangedSubviews where view is NSStackView && view !== row {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Space.x5 * 2).isActive = true
        }
        // As tall as what it holds, measured, rather than a fixed guess that
        // either clipped the mouse rows or left a band of empty popover.
        container.layoutSubtreeIfNeeded()
        container.setFrameSize(NSSize(width: 320, height: ceil(stack.fittingSize.height)))
        return container
    }

    private weak var mouseHint: NSTextField?

    @objc private func pointerModeChosen(_ sender: NSSegmentedControl) {
        let mode: InputCapture.PointerMode = sender.selectedSegment == 1 ? .gaming : .desktop
        InputCapture.pointerMode = mode
        mouseHint?.stringValue = Self.pointerHint(mode)
    }

    private static func pointerHint(_ mode: InputCapture.PointerMode) -> String {
        switch mode {
        case .desktop:
            return "The PC's pointer goes exactly where yours is. Best for ordinary apps."
        case .gaming:
            return "Click in the window to capture the mouse for games. ⌃⌥ releases it."
        }
    }

    private static func compact(_ value: UInt64) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1f M", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.0f k", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}
