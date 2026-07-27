import AppKit
import DesignSystem
import SolStreamLogging

/// A dot and an fps count, living in the streamed window's title bar.
///
/// It is always there and it never moves, which is the point: quality
/// information that appears only when something is wrong teaches you to dread it,
/// and one that jumps around draws the eye away from the application. Click it for
/// the detail. Nothing about quality is ever pushed at you.
final class QualityPill: NSView {

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

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.cornerCurve = .continuous

        label.font = DS.monoSmall
        label.textColor = DS.textMuted
        label.alignment = .center

        for child in [dot, label] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            widthAnchor.constraint(equalToConstant: 62),
            heightAnchor.constraint(equalToConstant: 18),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 5),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -6),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func updateLayer() {
        layer?.backgroundColor = DS.chromeRaised.withAlphaComponent(0.6).cgColor
    }

    private func refresh() {
        label.stringValue = stats.fps > 0 ? "\(stats.fps)" : "—"
        // Healthy is the accent; struggling is the accent with its chroma pulled
        // down; stopped is grey. State never gets a hue of its own.
        switch stats.fps {
        case 0: dot.state = .dead
        case 1..<24: dot.state = .idle
        default: dot.state = .live
        }
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

    private func buildDetail() -> NSView {
        func metric(_ value: String, _ caption: String) -> NSView {
            let big = NSTextField(labelWithString: value)
            big.font = DS.monoBody
            big.textColor = DS.textPrimary
            let small = NSTextField(labelWithString: caption)
            small.font = DS.monoSmall
            small.textColor = DS.textFaint
            let column = NSStackView(views: [big, small])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 1
            return column
        }

        let row = NSStackView(views: [
            metric(stats.fps > 0 ? "\(stats.fps)" : "—", "fps"),
            metric(stats.latencyMs.map { "\($0) ms" } ?? "—", "latency"),
            metric(stats.bitrateMbps.map { String(format: "%.0f Mb/s", $0) } ?? "—", "bandwidth"),
        ])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = 22

        let dropped = NSTextField(labelWithString:
            "\(stats.droppedFrames) dropped of \(Self.compact(stats.totalFrames))")
        dropped.font = DS.monoSmall
        dropped.textColor = DS.textMuted

        func line(_ caption: String, _ value: String) -> NSView {
            let left = NSTextField(labelWithString: caption)
            left.font = DS.secondary
            left.textColor = DS.textMuted
            let right = NSTextField(labelWithString: value)
            right.font = DS.monoSmall
            right.textColor = DS.textSecondary
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [left, spacer, right])
            stack.orientation = .horizontal
            return stack
        }

        let stack = NSStackView(views: [
            row,
            dropped,
            DS.hairlineView(),
            line("Audio", stats.audioActive ? "playing" : "silent — nothing playing on the PC"),
            line("Host display", stats.hostDisplay.isEmpty ? "—" : stats.hostDisplay),
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 18, bottom: 16, right: 18)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: 320, height: 190))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
            dropped.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36),
        ])
        for view in stack.arrangedSubviews where view is NSStackView && view !== row {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -36).isActive = true
        }
        return container
    }

    private static func compact(_ value: UInt64) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1f M", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.0f k", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}
