import AppKit
import DesignSystem
import SolStreamLogging
import StreamConnection

/// "Which PC?"
///
/// Reachability and pairing state are shown on the host row itself rather than
/// behind a dialog, so connecting is one step and a problem is legible before you
/// press anything. The dot is the only coloured thing on the row: accent means
/// reachable, grey means not. The primary button relabels — `Pair & Connect`
/// rather than a second button — so there is never more than one way forward.
final class ConnectWindow: NSObject, NSWindowDelegate {
    private static let lastHostKey = "SolStream.lastHost"
    private static let recentHostsKey = "SolStream.recentHosts"

    /// What we know about a host before connecting to it.
    private struct HostState {
        var address: String
        var name: String?
        var isReachable: Bool?      // nil while unknown
        var isPaired: Bool
        var latency: TimeInterval?

        var needsPairing: Bool { !isPaired }
    }

    private let window: NSWindow
    private let hostField = NSComboBox()
    private let dot = DS.Dot()
    private let detailLabel = NSTextField(labelWithString: "")
    private let hintLabel = NSTextField(labelWithString: "")
    private let connectButton: DS.OutlinedButton
    private let quitButton: DS.OutlinedButton

    private let browser = HostBrowser()
    private var discovered: [DiscoveredHost] = []
    private var state: HostState
    private var probe: DispatchWorkItem?

    private let onConnect: (String) -> Void

    init(onConnect: @escaping (String) -> Void) {
        self.onConnect = onConnect
        self.state = HostState(address: Self.lastHost ?? Self.recentHosts.first ?? "",
                               name: nil, isReachable: nil, isPaired: false, latency: nil)

        connectButton = DS.OutlinedButton(title: "Connect", primary: true, target: nil, action: nil)
        quitButton = DS.OutlinedButton(title: "Quit", target: nil, action: nil)

        // 420x280: the extra height over a bare prompt is what lets reachability,
        // latency and pairing live on the row instead of in an alert.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 280),
                          styleMask: [.titled, .closable, .miniaturizable],
                          backing: .buffered, defer: false)
        window.title = "SolStream"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DS.ground
        window.isMovableByWindowBackground = true

        super.init()
        build()
        window.delegate = self
        refresh()
    }

    private func build() {
        let heading = NSTextField(labelWithString: "Connect to a Windows host")
        heading.font = DS.title
        heading.textColor = DS.textPrimary

        let subheading = NSTextField(labelWithString: "SolStream streams one app, not the desktop.")
        subheading.font = DS.secondary
        subheading.textColor = DS.textMuted

        // ── The host row ────────────────────────────────────────────────────
        //
        // The editable field IS the name line rather than sitting under one, so
        // the address is never shown twice. Its own chevron is the affordance for
        // picking a discovered host; the detail line underneath carries
        // reachability, pairing and latency.
        hostField.isEditable = true
        hostField.usesDataSource = false
        hostField.completes = true
        hostField.font = DS.section
        hostField.textColor = DS.textPrimary
        hostField.isBordered = false
        hostField.drawsBackground = false
        hostField.focusRingType = .none
        hostField.delegate = self
        hostField.target = self
        hostField.action = #selector(hostChanged)
        hostField.placeholderString = "hostname or IP address"
        hostField.stringValue = state.address

        detailLabel.font = DS.monoSmall
        detailLabel.textColor = DS.textMuted

        let row = NSView()
        row.wantsLayer = true
        row.layer?.backgroundColor = DS.chrome.cgColor
        row.layer?.cornerRadius = DS.Metric.rowCorner
        row.layer?.cornerCurve = .continuous
        row.translatesAutoresizingMaskIntoConstraints = false
        for child in [dot, hostField, detailLabel] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            row.addSubview(child)
        }

        hintLabel.font = DS.secondary
        hintLabel.textColor = DS.textMuted
        hintLabel.lineBreakMode = .byWordWrapping
        hintLabel.maximumNumberOfLines = 2
        hintLabel.preferredMaxLayoutWidth = 356

        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        connectButton.keyEquivalent = "\r"
        quitButton.target = self
        quitButton.action = #selector(quitTapped)

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [quitButton, spacer, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = 10

        let stack = NSStackView(views: [heading, subheading, row, hintLabel, buttons])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.setCustomSpacing(6, after: heading)
        stack.setCustomSpacing(20, after: subheading)
        stack.edgeInsets = NSEdgeInsets(top: 30, left: 32, bottom: 26, right: 32)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.wantsLayer = true
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            row.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            row.heightAnchor.constraint(equalToConstant: 62),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),

            dot.leadingAnchor.constraint(equalTo: row.leadingAnchor, constant: 16),
            dot.centerYAnchor.constraint(equalTo: hostField.centerYAnchor),

            hostField.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
            hostField.trailingAnchor.constraint(equalTo: row.trailingAnchor, constant: -10),
            hostField.topAnchor.constraint(equalTo: row.topAnchor, constant: 10),

            detailLabel.leadingAnchor.constraint(equalTo: hostField.leadingAnchor, constant: 4),
            detailLabel.trailingAnchor.constraint(lessThanOrEqualTo: row.trailingAnchor, constant: -12),
            detailLabel.topAnchor.constraint(equalTo: hostField.bottomAnchor, constant: 4),
        ])

        window.contentView = content
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(hostField)
        NSApp.activate(ignoringOtherApps: true)
        startDiscovery()
        scheduleProbe()
    }

    func close() {
        browser.stop()
        probe?.cancel()
        window.orderOut(nil)
    }

    // MARK: - State

    /// Everything the row and the button say is derived from one state, so they
    /// can never disagree with each other.
    private func refresh() {
        state.isPaired = ClientIdentity.shared.isPaired(host: state.address)

        var parts: [String] = []
        // The discovered name, when there is one, is worth more than repeating the
        // address the field is already showing.
        if let name = state.name { parts.append(name) }
        switch state.isReachable {
        case .some(true):
            parts.append(state.isPaired ? "paired" : "not paired")
            if let latency = state.latency {
                parts.append("\(Int(latency * 1000)) ms")
            }
            dot.state = .live
        case .some(false):
            parts.append("unreachable")
            dot.state = .dead
        case nil:
            parts.append(state.address.isEmpty ? "enter an address" : "checking…")
            dot.state = .idle
        }
        detailLabel.stringValue = parts.joined(separator: " · ")

        switch (state.isReachable, state.needsPairing) {
        case (.some(true), true):
            hintLabel.stringValue = "Pairing needed — the PC approves it for you, or shows a PIN."
            connectButton.title = "Pair & Connect"
        case (.some(true), false):
            hintLabel.stringValue = "Reachable and paired. Connecting is one step."
            connectButton.title = "Connect"
        case (.some(false), _):
            hintLabel.stringValue = "Not answering on port 47989. Check the PC is awake and "
                                  + "Sunshine is running."
            connectButton.title = "Connect"
        case (nil, _):
            hintLabel.stringValue = discovered.isEmpty
                ? "First connection shows a PIN, unless the PC can approve it itself."
                : "Found \(discovered.map(\.name).joined(separator: ", ")) on this network."
            connectButton.title = "Connect"
        }
        connectButton.setPrimary(true)
        connectButton.isEnabled = !state.address.isEmpty
    }

    /// Reachability is checked by opening the Sunshine port, not by pinging: what
    /// matters is whether the thing we need is listening, not whether the machine
    /// replies to ICMP.
    private func scheduleProbe() {
        probe?.cancel()
        let address = state.address
        guard !address.isEmpty else {
            state.isReachable = nil
            refresh()
            return
        }
        let work = DispatchWorkItem { [weak self] in
            let started = Date()
            let reachable = Self.canReachSunshine(host: address)
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self, self.state.address == address else { return }
                self.state.isReachable = reachable
                self.state.latency = reachable ? elapsed : nil
                self.refresh()
            }
        }
        probe = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private static func canReachSunshine(host: String, port: UInt16 = 47989) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0
    }

    // MARK: - Discovery

    private func startDiscovery() {
        browser.onChange = { [weak self] hosts in
            guard let self else { return }
            self.discovered = hosts
            let targets = hosts.map(\.connectTarget)
            let typed = self.hostField.stringValue
            self.hostField.removeAllItems()
            self.hostField.addItems(withObjectValues: targets
                + Self.recentHosts.filter { !targets.contains($0) })
            self.hostField.stringValue = typed

            // Offer the one obvious choice rather than making them open the menu,
            // but never overwrite something already typed.
            if typed.isEmpty, let first = hosts.first {
                self.hostField.stringValue = first.connectTarget
                self.state.address = first.connectTarget
                self.state.name = first.name
                self.scheduleProbe()
            } else if let match = hosts.first(where: { $0.connectTarget == typed }) {
                self.state.name = match.name
            }
            self.refresh()
        }
        browser.start()
    }

    // MARK: - Actions

    @objc private func hostChanged() {
        let typed = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != state.address else { return }
        state.address = typed
        state.name = discovered.first { $0.connectTarget == typed }?.name
        state.isReachable = nil
        state.latency = nil
        refresh()
        scheduleProbe()
    }

    @objc private func connectTapped() {
        let host = hostField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            hintLabel.stringValue = "Enter a hostname or IP address."
            hintLabel.textColor = DS.accentBright
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
        browser.stop()
        probe?.cancel()
        if NSApp.windows.allSatisfy({ !$0.isVisible || $0 === window }) {
            NSApp.terminate(nil)
        }
    }

    // MARK: - Recents

    private static var lastHost: String? {
        UserDefaults.standard.string(forKey: lastHostKey)
    }

    private static var recentHosts: [String] {
        // No default. This used to seed one developer's Tailscale address into
        // every install's recents list, where it showed up as a host the user
        // had supposedly connected to before.
        UserDefaults.standard.stringArray(forKey: recentHostsKey) ?? []
    }

    private static func remember(host: String) {
        var hosts = recentHosts.filter { $0 != host }
        hosts.insert(host, at: 0)
        UserDefaults.standard.set(Array(hosts.prefix(5)), forKey: recentHostsKey)
        UserDefaults.standard.set(host, forKey: lastHostKey)
    }
}

extension ConnectWindow: NSComboBoxDelegate {
    func comboBoxSelectionDidChange(_ notification: Notification) {
        // The field's value updates after this returns, so read it on the next turn.
        DispatchQueue.main.async { [weak self] in self?.hostChanged() }
    }

    func controlTextDidChange(_ obj: Notification) {
        hostChanged()
    }
}
