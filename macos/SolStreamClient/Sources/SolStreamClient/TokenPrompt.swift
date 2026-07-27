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
/// An NSAlert rather than something built out of the design system: this is a
/// modal question with two answers, which is exactly what NSAlert is, and it
/// inherits focus, Escape, and Return for free.
enum TokenPrompt {
    /// - Parameter rejected: the stored token was tried and turned down, as
    ///   opposed to there never having been one. Worth saying, because the two
    ///   have different causes — a rotated token versus a first connection.
    @MainActor
    static func present(host: String, rejected: Bool, completion: @escaping (String?) -> Void) {
        let alert = NSAlert()
        alert.messageText = rejected
            ? "\(host) didn't accept that token"
            : "\(host) needs a pairing token"
        alert.informativeText = """
            The token is printed by the SolStream agent on the Windows PC. \
            Open a Command Prompt there and run:

            SolStreamAgent.exe --print-token

            Paste the line it prints below. SolStream remembers it for this \
            host, so this is asked once.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Connect")
        alert.addButton(withTitle: "Cancel")

        // Tokens are pasted, essentially always, and a paste that silently
        // brings a trailing newline along should not read as a wrong token.
        let field = DS.Field(placeholder: "Paste the token", mono: true)
        field.frame = NSRect(x: 0, y: 0, width: 320, height: 24)
        field.translatesAutoresizingMaskIntoConstraints = true
        alert.accessoryView = field

        // Without this the text field is not first responder and the first
        // keystroke or ⌘V goes nowhere.
        alert.window.initialFirstResponder = field

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else {
            completion(nil)
            return
        }
        let token = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        completion(token.isEmpty ? nil : token)
    }
}
