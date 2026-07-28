import AppKit
import DesignSystem
import SolStreamLogging
import StreamConnection

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
/// a system-accent default button, in the middle of a dark violet application.
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
        let sheet = Sheet(host: host, rejected: rejected, completion: completion)
        guard let parent else {
            // No window to hang a sheet on — during early startup, or in tests.
            // Answering nil is honest: the caller treats it as "not supplied".
            completion(nil)
            return
        }
        sheet.present(over: parent)
    }

    /// The sheet itself. Retained by its own completion handler until dismissed,
    /// because nothing else holds a reference to it once `present` returns.
    @MainActor
    private final class Sheet: NSObject {
        private let window: NSWindow
        private let field = DS.Field(placeholder: "Paste the token", mono: true)
        private let completion: (String?) -> Void
        private var done = false
        private var keepAlive: Sheet?

        init(host: String, rejected: Bool, completion: @escaping (String?) -> Void) {
            self.completion = completion
            window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 250),
                              styleMask: [.titled, .fullSizeContentView],
                              backing: .buffered, defer: false)
            super.init()

            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.backgroundColor = DS.ground
            window.isMovableByWindowBackground = false

            let heading = NSTextField(labelWithString:
                rejected ? "\(host) didn't accept that token"
                         : "\(host) needs a pairing token")
            heading.font = DS.title
            heading.textColor = DS.textPrimary
            heading.lineBreakMode = .byTruncatingTail

            // Points at the host window, which shows the token with a Copy
            // button. The old text told people to open a Command Prompt and run
            // `SolStreamAgent.exe --print-token` — an executable name that has
            // not existed since the installed binary became SolStream.exe, for a
            // token the window has been displaying all along.
            let body = NSTextField(wrappingLabelWithString: """
                Open SolStream on the Windows PC. It shows the token under \
                "Pairing token", with a Copy button beside it.

                Paste it below — SolStream remembers it for this host, so this \
                is asked once.
                """)
            body.font = DS.secondary
            body.textColor = DS.textMuted

            let connect = DS.OutlinedButton(title: "Connect", primary: true,
                                            target: self, action: #selector(accept))
            let cancel = DS.OutlinedButton(title: "Cancel", target: self,
                                           action: #selector(dismiss))
            connect.keyEquivalent = "\r"
            cancel.keyEquivalent = "\u{1b}"

            let spacer = NSView()
            spacer.setContentHuggingPriority(.init(1), for: .horizontal)
            let buttons = NSStackView(views: [cancel, spacer, connect])
            buttons.orientation = .horizontal

            let stack = NSStackView(views: [heading, body, field, buttons])
            stack.orientation = .vertical
            stack.alignment = .leading
            stack.spacing = 14
            stack.translatesAutoresizingMaskIntoConstraints = false
            stack.setHuggingPriority(.init(1), for: .vertical)

            let content = NSView()
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -24),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 24),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -24),
                buttons.widthAnchor.constraint(equalTo: stack.widthAnchor),
                field.widthAnchor.constraint(equalTo: stack.widthAnchor),
            ])
            window.contentView = content
        }

        func present(over parent: NSWindow) {
            keepAlive = self
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
            finish(token.isEmpty ? nil : token)
        }

        @objc private func dismiss() { finish(nil) }

        private func finish(_ token: String?) {
            guard !done else { return }
            done = true
            if let parent = window.sheetParent {
                parent.endSheet(window)
            }
            completion(token)
            keepAlive = nil
        }
    }
}
