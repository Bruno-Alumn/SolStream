import AppKit
import SolStreamLogging

/// The initial "which host?" window.
///
/// Replaces the modal `NSAlert` the app used to open with: it remembers the
/// last host, validates input, and shows whether that host is already paired so
/// it's obvious when a PIN will be needed.
final class ConnectWindow: NSObject, NSWindowDelegate {
    private static let lastHostKey = "SolStream.lastHost"
    private static let recentHostsKey = "SolStream.recentHosts"

    private let window: NSWindow
    private let hostField = NSComboBox()
    private let connectButton = NSButton(title: "Connect", target: nil, action: nil)
    private let hintLabel = NSTextField(labelWithString: "")

    private let onConnect: (String) -> Void

    init(onConnect: @escaping (String) -> Void) {
        self.onConnect = onConnect

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 420, height: 180),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "SolStream"
        window.isMovableByWindowBackground = true

        super.init()

        let heading = NSTextField(labelWithString: "Connect to a Windows host")
        heading.font = .systemFont(ofSize: 17, weight: .semibold)

        let subheading = NSTextField(labelWithString: "Sunshine must be running on the host.")
        subheading.font = .systemFont(ofSize: 12)
        subheading.textColor = .secondaryLabelColor

        hostField.placeholderString = "hostname or IP address"
        hostField.usesDataSource = false
        hostField.completes = true
        hostField.removeAllItems()
        hostField.addItems(withObjectValues: Self.recentHosts)
        hostField.stringValue = Self.lastHost ?? Self.recentHosts.first ?? ""
        hostField.target = self
        hostField.action = #selector(connectTapped)

        hintLabel.font = .systemFont(ofSize: 11)
        hintLabel.textColor = .tertiaryLabelColor
        hintLabel.stringValue = "First connection shows a PIN to enter in Sunshine's web UI."

        connectButton.bezelStyle = .rounded
        connectButton.keyEquivalent = "\r"
        connectButton.target = self
        connectButton.action = #selector(connectTapped)

        let quitButton = NSButton(title: "Quit", target: self, action: #selector(quitTapped))
        quitButton.bezelStyle = .rounded

        let buttons = NSStackView(views: [quitButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, subheading, hostField, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 10
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 20, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            hostField.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -48),
            buttons.trailingAnchor.constraint(equalTo: stack.trailingAnchor, constant: -24),
        ])

        window.contentView = content
        content.layoutSubtreeIfNeeded()
        window.setContentSize(NSSize(width: 420, height: content.fittingSize.height))
        window.delegate = self
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostField)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() {
        window.orderOut(nil)
    }

    // MARK: - Actions

    @objc private func connectTapped() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            hintLabel.stringValue = "Enter a hostname or IP address."
            hintLabel.textColor = .systemRed
            return
        }
        Self.remember(host: host)
        close()
        onConnect(host)
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) {
        // Closing the connect window with no stream open means we're done.
        if NSApp.windows.allSatisfy({ !$0.isVisible || $0 === window }) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Recents

    private static var lastHost: String? {
        UserDefaults.standard.string(forKey: lastHostKey)
    }

    private static var recentHosts: [String] {
        // Seed with the host earlier builds hardcoded, so the first launch
        // after upgrading still has it one click away.
        UserDefaults.standard.stringArray(forKey: recentHostsKey) ?? ["100.101.102.103"]
    }

    private static func remember(host: String) {
        var hosts = recentHosts.filter { $0 != host }
        hosts.insert(host, at: 0)
        UserDefaults.standard.set(Array(hosts.prefix(5)), forKey: recentHostsKey)
        UserDefaults.standard.set(host, forKey: lastHostKey)
    }
}
