import AppKit
import DesignSystem

/// The three steps from nothing to a stream, shown in the connect window on a
/// Mac that has never paired with a PC.
///
/// Somebody who has just installed the Mac end of SolStream sees "Connect to
/// your PC" and a host row that says nothing was found -- because the other
/// half is not installed yet, and nothing on the screen said there was another
/// half. This says so, and then gets out of the way: it is derived from the
/// pairing tokens, so the first pairing that succeeds removes it for good,
/// with nothing to dismiss and nothing remembered about having shown it.
///
/// The steps tick themselves off from what the window already knows. A PC
/// that discovery found, or that answered on the agent's port, has SolStream
/// installed and running, so the first two are done and the third -- the one
/// the window below is for -- is the one to do.
enum SetupGuide {
    enum Step: Equatable {
        case done, current, upcoming
    }

    static let windowsDownload = URL(string: "https://github.com/Bruno-Alumn/SolStream/releases/latest")!

    /// Each step's state, or nil when the guide should not be shown at all.
    ///
    /// - Parameters:
    ///   - paired: this Mac holds a pairing token for some PC.
    ///   - discovered: how many SolStream PCs discovery has found.
    ///   - reachable: whether the host on show answered; nil while unknown.
    static func steps(paired: Bool, discovered: Int, reachable: Bool?) -> [Step]? {
        guard !paired else { return nil }
        let found = discovered > 0 || reachable == true
        return found ? [.done, .done, .current] : [.current, .upcoming, .upcoming]
    }
}

/// The card the steps are drawn in: `surface`, a hairline, one row per step
/// with its state dot, and the first step's link to the Windows download.
final class SetupGuideView: NSView {
    /// Width the step text wraps at, worked out from the card's: a wrapping
    /// label asked for its fitting size without one answers with its
    /// single-line width, and the window is sized from fitting sizes.
    private let textWidth: CGFloat

    private struct Row {
        let dot: DS.Dot
        let text: NSTextField
        let words: String
        let number: Int
    }

    /// Body size, so the number sits on the words' baseline; medium and
    /// tabular, so 1, 2 and 3 take one width and the words line up.
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .medium)

    private var rows: [Row] = []
    private var states: [SetupGuide.Step] = []

    /// - Parameter width: the card's width, which the window decides.
    init(width: CGFloat) {
        // The card's inset each side, then the dot, the number and the gaps
        // between them and the words.
        textWidth = width - DS.Metric.cardInset * 2 - DS.Metric.dot - DS.Space.x3
            - DS.Space.x2 - DS.Space.x2
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        build(width: width)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func build(width: CGFloat) {
        let card = DS.card()
        addSubview(card)

        // A caption, not a heading: the window's heading is still the thing
        // to read, and this is the note on how to get there the first time.
        let caption = DS.label("First time here", font: DS.caption, colour: DS.textMuted)

        let link = LinkButton(title: "Get it for Windows", font: DS.caption,
                              target: self, action: #selector(getForWindows))
        link.setAccessibilityLabel("Get SolStream for Windows. Opens the download page.")

        let words = [
            "Install SolStream on your PC.",
            "Run it. Setup adds a virtual display so the picture fits this Mac, "
                + "and shows a pairing token.",
            "Pick your PC below and type the token.",
        ]
        var stepViews: [NSView] = []
        for (index, sentence) in words.enumerated() {
            let dot = DS.Dot(state: .idle)
            // Current is a steady amber, not the pulse: the pulse means
            // something is under way, and nothing is until the person does it.
            dot.holdsSteady = true
            let text = NSTextField(wrappingLabelWithString: "")
            text.preferredMaxLayoutWidth = textWidth
            text.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            rows.append(Row(dot: dot, text: text, words: sentence, number: index + 1))

            // The dot sits on the text's first line, not halfway down a
            // two-line step: it marks where the step starts.
            let dotHolder = NSView()
            dotHolder.translatesAutoresizingMaskIntoConstraints = false
            dotHolder.addSubview(dot)
            let lineHeight = ceil(DS.body.boundingRectForFont.height)
            NSLayoutConstraint.activate([
                dotHolder.widthAnchor.constraint(equalToConstant: DS.Metric.dot),
                dotHolder.heightAnchor.constraint(equalToConstant: lineHeight),
                dot.centerXAnchor.constraint(equalTo: dotHolder.centerXAnchor),
                dot.centerYAnchor.constraint(equalTo: dotHolder.centerYAnchor),
            ])

            var column: [NSView] = [text]
            if index == 0 { column.append(link) }
            let textColumn = NSStackView(views: column)
            textColumn.orientation = .vertical
            textColumn.alignment = .leading
            textColumn.spacing = DS.Space.x1

            // The number in a column of its own, so a step that wraps wraps
            // under its words rather than under its number, and the link under
            // the first step starts where the words do.
            let number = DS.label("\(index + 1)", font: Self.numberFont, colour: DS.textMuted)
            number.alignment = .right
            number.widthAnchor.constraint(equalToConstant: DS.Space.x2).isActive = true

            let row = NSStackView(views: [dotHolder, number, textColumn])
            row.orientation = .horizontal
            row.alignment = .top
            row.spacing = DS.Space.x3
            row.setCustomSpacing(DS.Space.x2, after: number)
            stepViews.append(row)
        }

        let stack = NSStackView(views: [caption] + stepViews)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.x3
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        let inset = DS.Metric.cardInset
        NSLayoutConstraint.activate([
            card.leadingAnchor.constraint(equalTo: leadingAnchor),
            card.trailingAnchor.constraint(equalTo: trailingAnchor),
            card.topAnchor.constraint(equalTo: topAnchor),
            card.bottomAnchor.constraint(equalTo: bottomAnchor),
            widthAnchor.constraint(equalToConstant: width),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor, constant: inset),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -inset),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: inset),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -inset),
        ])
        show([.current, .upcoming, .upcoming])
    }

    /// Mark each step. Only colours change, never sizes, so the window does
    /// not move when a PC turns up and two steps tick over.
    func show(_ next: [SetupGuide.Step]) {
        guard next != states, next.count == rows.count else { return }
        states = next
        for (row, state) in zip(rows, next) {
            switch state {
            case .done: row.dot.state = .live
            case .current: row.dot.state = .working
            case .upcoming: row.dot.state = .idle
            }
            // The step to do now is the one in full ink; the others step
            // back, done ones furthest, so the eye lands on the current one.
            let ink: NSColor = state == .current ? DS.text
                : (state == .done ? DS.textMuted : DS.textSecondary)
            row.text.attributedStringValue = NSAttributedString(string: row.words, attributes: [
                .font: DS.body, .foregroundColor: ink,
            ])
            let said: String
            switch state {
            case .done: said = "done"
            case .current: said = "to do now"
            case .upcoming: said = "to do"
            }
            row.text.setAccessibilityLabel("Step \(row.number), \(said): \(row.words)")
        }
    }

    @objc private func getForWindows() {
        NSWorkspace.shared.open(SetupGuide.windowsDownload)
    }
}
