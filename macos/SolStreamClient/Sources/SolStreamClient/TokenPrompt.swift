import AppKit
import DesignSystem
import SolStreamLogging
import MediaSession
import AgentChannel

/// Asks for the host's pairing token.
///
/// The token used to be settable only with `--agent-token` on the command line,
/// which meant the answer to "SolStream says my PC needs a token" was to open
/// Terminal — for an application whose entire premise is that the user never
/// has to think about any of this.
///
/// Built from the design system rather than being an NSAlert. NSAlert was the
/// obvious choice — a modal question with two answers is exactly what it is, and
/// it gives focus, Escape and Return for free — but it is also the only surface
/// in the whole pairing flow that ignores the design: a light system panel with
/// a system-accent default button, in the middle of an application with its own.
/// The first thing anybody pairing a PC sees should not be the one screen that
/// looks like it belongs to a different program.
///
/// Presented as a sheet so it is still modal to its window, and Escape and
/// Return are wired by hand, which is the whole cost of leaving NSAlert behind.
enum TokenPrompt {
    /// - Parameter rejected: the stored token was tried and turned down, as
    ///   opposed to there never having been one. Worth saying, because the two
    ///   have different causes — a rotated token versus a first connection.
    @MainActor
    static func present(host: String, rejected: Bool, over parent: NSWindow?,
                        completion: @escaping (String?) -> Void) {
        guard let parent else {
            // No window to hang a sheet on — during early startup, or in tests.
            // Answering nil is honest: the caller treats it as "not supplied".
            completion(nil)
            return
        }
        // One at a time. The connection asks again each time it reconnects,
        // and AppKit queues a second sheet on a window behind the first: the
        // token typed into the first was accepted, and the next copy of the
        // same question came straight up in its place, looking for all the
        // world like a sheet that would not go away. The one already up takes
        // the newer question -- its words, and who gets the answer.
        if let showing = Sheet.showing(over: parent) {
            showing.retarget(host: host, rejected: rejected, completion: completion)
            return
        }
        Sheet(host: host, rejected: rejected, completion: completion).present(over: parent)
    }

    /// Take down the token sheet over `parent`, if there is one, without
    /// answering it: the connection authenticated some other way. Whether
    /// there was one.
    @MainActor
    @discardableResult
    static func withdraw(over parent: NSWindow) -> Bool {
        guard let showing = Sheet.showing(over: parent) else { return false }
        Log.info("[agent] authenticated meanwhile; taking the token sheet down")
        showing.withdraw()
        return true
    }

    /// The sheet itself. Retained by its own completion handler until dismissed,
    /// because nothing else holds a reference to it once `present` returns.
    @MainActor
    final class Sheet: NSObject {
        let window: NSWindow
        private let field = DS.Field(placeholder: "Paste the token", mono: true)
        private var completion: (String?) -> Void
        private var done = false
        private var keepAlive: Sheet?
        private let heading: NSTextField
        private let body: NSTextField
        private weak var parent: NSWindow?
        /// Every sheet up now; see `TokenPrompt.present`.
        private static var live: [Sheet] = []

        static func showing(over parent: NSWindow) -> Sheet? {
            live.first { $0.parent === parent && !$0.done }
        }

        static func headingText(host: String, rejected: Bool) -> String {
            rejected ? "\(host) didn't accept that token" : "\(host) needs a pairing token"
        }

        func retarget(host: String, rejected: Bool, completion: @escaping (String?) -> Void) {
            let heading = Self.headingText(host: host, rejected: rejected)
            // Said when it changes -- a token refused while the sheet is up --
            // which nothing on screen announces by itself.
            if heading != self.heading.stringValue { DS.announce(heading) }
            self.heading.stringValue = heading
            window.title = heading
            body.stringValue = Self.bodyText(rejected: rejected)
            self.completion = completion
            // A heading that went from one line to two, or back, resizes the
            // sheet with it.
            // Grown or shrunk from the bottom, so the top stays against the
            // parent's title bar as a sheet's does.
            if let content = window.contentView {
                content.layoutSubtreeIfNeeded()
                let size = content.fittingSize
                var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
                frame.origin = NSPoint(x: window.frame.minX,
                                       y: window.frame.maxY - frame.height)
                window.setFrame(frame, display: true, animate: window.isVisible
                    && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
            }
        }

        /// For the tests: what VoiceOver calls the token field.
        var fieldAccessibilityLabel: String? { field.accessibilityLabel() }

        func withdraw() {
            completion = { _ in }
            finish(nil)
        }

        static func bodyText(rejected: Bool) -> String {
            // Points at the host window, which shows the token with a Copy
            // button. The old text told people to open a Command Prompt and run
            // `SolStreamAgent.exe --print-token` — an executable name that has
            // not existed since the installed binary became SolStream.exe, for
            // a token the window has been displaying all along.
            rejected
                ? """
                The token may have changed on the PC, or part of it was missed. \
                Open SolStream on the PC, press Copy beside "Pairing token", and \
                paste it here.
                """
                : """
                Open SolStream on the Windows PC. It shows the token under \
                "Pairing token", with a Copy button beside it.

                Paste it below — SolStream remembers it for this PC, so this \
                is asked once.
                """
        }

        init(host: String, rejected: Bool, completion: @escaping (String?) -> Void) {
            self.completion = completion
            heading = NSTextField(labelWithString: Self.headingText(host: host, rejected: rejected))
            body = NSTextField(wrappingLabelWithString: Self.bodyText(rejected: rejected))
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 250),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
            super.init()

            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            // Hidden, but what VoiceOver names the sheet by, rather than nothing.
            window.title = Self.headingText(host: host, rejected: rejected)
            field.setAccessibilityLabel("Pairing token")
            window.backgroundColor = DS.ground
            window.isMovableByWindowBackground = false

            heading.font = DS.title
            heading.textColor = DS.text
            // Two lines rather than one cut short: with a MagicDNS name the
            // words cut were the ones saying whether the token was missing or
            // refused.
            heading.usesSingleLineMode = false
            heading.cell?.wraps = true
            heading.lineBreakMode = .byWordWrapping
            heading.maximumNumberOfLines = 2
            // A name too long even for two lines ends in an ellipsis rather
            // than losing the line that says what happened.
            heading.cell?.truncatesLastVisibleLine = true
            heading.preferredMaxLayoutWidth = 440 - DS.Metric.inset * 2

            body.font = DS.body
            body.textColor = DS.textSecondary

            let connect = DS.Button(title: "Connect", style: .primary,
                                    target: self, action: #selector(accept))
            let cancel = DS.Button(title: "Cancel", target: self, action: #selector(dismiss))
            connect.keyEquivalent = "\r"
            cancel.keyEquivalent = "\u{1b}"

            // Trailing, primary last, as in every other SolStream window.
            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let buttons = NSStackView(views: [spacer, cancel, connect])
            buttons.orientation = .horizontal
            buttons.spacing = DS.Space.x3

            // The token is data, so the field is mono; the box around it draws
            // the hairline and, while it has focus, the accent ring.
            let fieldBox = DS.FieldBox(field: field)

            let stack = NSStackView(views: [heading, body, fieldBox, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = DS.Space.x2
            stack.setCustomSpacing(DS.Space.x4, after: body)
            stack.setCustomSpacing(DS.Space.x6, after: fieldBox)
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.setHuggingPriority(.init(1), for: .vertical)

            let inset = DS.Metric.inset
            // A ground of its own rather than only the window's background
            // colour: a sheet is drawn over a system material, which shows
            // through as a warm grey in the dark theme and plain white in the
            // light one, and neither is `ground`.
            let content = DS.Box(fill: DS.ground)
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                content.widthAnchor.constraint(equalToConstant: 440),
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: inset),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -inset),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: inset),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -inset),
                heading.widthAnchor.constraint(equalTo: stack.widthAnchor),
                body.widthAnchor.constraint(equalTo: stack.widthAnchor),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
                fieldBox.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            window.contentView = content
            window.setContentSize(content.fittingSize)
        }

        func present(over parent: NSWindow) {
            keepAlive = self
            self.parent = parent
            Self.live.append(self)
            parent.beginSheet(window) { [weak self] _ in
                // Covers the sheet being dismissed by any route, including one
                // that never went through the buttons.
                self?.finish(nil)
            }
            // Or the first keystroke — or ⌘V, which is how a token actually
            // arrives — goes nowhere.
            window.makeFirstResponder(field)
        }

        @objc private func accept() {
            let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            // Return with nothing pasted -- or a paste that missed -- is not a
            // choice to stop pairing: the sheet stays for the token. Cancel is
            // how to stop.
            guard !token.isEmpty else {
                NSSound.beep()
                DS.announce("Paste the pairing token first.")
                window.makeFirstResponder(field)
                return
            }
            finish(token)
        }

        @objc private func dismiss() { finish(nil) }

        private func finish(_ token: String?) {
            guard !done else { return }
            done = true
            Self.live.removeAll { $0 === self }
            if let parent = window.sheetParent {
                parent.endSheet(window)
            }
            completion(token)
            keepAlive = nil
        }
    }
}
