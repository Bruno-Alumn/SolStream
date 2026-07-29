import AppKit
import DesignSystem
import SolStreamLogging
import MediaSession
import AgentChannel

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
        /// Whether the agent's port answered. Nil while unknown.
        ///
        /// There was a second flag beside this, `hasAgent`, for the case where the
        /// PC was reachable for streaming but had nothing to take SolStream's
        /// commands — Sunshine bound every interface and the agent bound one, so
        /// the two genuinely disagreed. Both are gone: there is one port, and the
        /// two probes had been reduced to two TCP connects to the same number, so
        /// `hasAgent` could no longer differ from this and the branches that
        /// reported the difference were unreachable. It also cost the agent two
        /// connections per debounced keystroke, on a socket that serves one client
        /// and logs every arrival it turns away.
        var isReachable: Bool?
        var isPaired: Bool
        var latency: TimeInterval?

        var needsPairing: Bool { !isPaired }
    }

    private let window: NSWindow
    private let hostDropdown = HostDropdown()
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
        // One control, not a field plus a menu. It shows the chosen host on two
        // lines with its state dot, and opens a list of the same rows over
        // itself — including, as the last row, the place to type an address that
        // discovery did not find.
        hostDropdown.translatesAutoresizingMaskIntoConstraints = false
        hostDropdown.onPick = { [weak self] address in self?.hostPicked(address) }

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

        let stack = NSStackView(views: [heading, subheading, hostDropdown, hintLabel, buttons])
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
            hostDropdown.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -64),
        ])

        window.contentView = content
    }

    func show() {
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startDiscovery()
        scheduleProbe()
    }

    /// Open the host list, for `--test-dropdown`.
    func openDropdownForTesting() -> NSWindow? {
        hostDropdown.openForTesting()
        return hostDropdown.listWindow
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
        // "Paired" now means one thing: this Mac holds the host's agent
        // token. There is no certificate, no PIN and no TLS key to pin --
        // the token is the whole relationship.
        state.isPaired = AgentConnection.storedToken(for: state.address) != nil

        var dotState: DS.Dot.State = .idle
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
            dotState = .live
        case .some(false):
            parts.append("unreachable")
            dotState = .dead
        case nil:
            parts.append(state.address.isEmpty ? "enter an address" : "checking…")
            dotState = .idle
        }
        hostDropdown.setSelection(address: state.address, name: state.name,
                                  detail: parts.joined(separator: " · "), dotState: dotState)
        hostDropdown.items = hostItems()
        hostDropdown.isDiscovering = browser.isRunning

        switch (state.isReachable, state.needsPairing) {
        case (.some(true), true):
            // What the person will actually be asked for. It used to say the PC
            // "approves it for you, or shows a PIN", which described GameStream's
            // flow: there is no PIN anywhere in SolStream, and nothing on the PC
            // approves anything — the token is on SolStream's own window there,
            // and this Mac proves it.
            hintLabel.stringValue = "Pairing needed — SolStream on the PC shows a token to type in."
            connectButton.title = "Pair & Connect"
        case (.some(true), false):
            hintLabel.stringValue = "Reachable and paired. Connecting is one step."
            connectButton.title = "Connect"
        case (.some(false), _):
            hintLabel.stringValue = "Not answering on port \(StreamPorts.agent). "
                                  + "Check the PC is awake and SolStream is running."
            connectButton.title = "Connect"
        case (nil, _):
            // Without stripping the suffix this line reads "Found
            // DESKTOP-EXAMPLE(1)" — Bonjour's disambiguation for a machine
            // advertising twice, which is exactly the detail the rest of the
            // window works to keep out of the user's way. Nobody's PC is called
            // that.
            let names = discovered
                .map { HostBrowser.baseName(of: $0.name) ?? $0.name }
                .joined(separator: ", ")
            hintLabel.stringValue = discovered.isEmpty
                ? "First connection shows a PIN, unless the PC can approve it itself."
                : "Found \(names) on this network."
            connectButton.title = "Connect"
        }
        connectButton.setPrimary(true)
        connectButton.isEnabled = !state.address.isEmpty
    }

    /// Reachability is checked by opening the port, not by pinging: what matters
    /// is whether the thing we need is listening, not whether the machine replies
    /// to ICMP.
    ///
    /// ONE probe, not two. There were two, back when a PC could answer for
    /// streaming on a port Sunshine bound and have nothing on the agent's — that
    /// is what `hasAgent` recorded. Once the second base port went, both calls
    /// were connecting to 47630 and comparing the answer against itself, which
    /// cost the agent a spare connection per keystroke and could only ever agree.
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
            let reachable = Self.canReach(host: address, port: StreamPorts.agent)
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self, self.state.address == address else { return }
                self.state.isReachable = reachable
                self.state.latency = reachable ? elapsed : nil
                // Remember it here rather than on Connect. Typing an address and
                // then not connecting -- because the stream was for later, or the
                // window was closed, or connecting failed once -- meant typing the
                // whole thing again next time, since nothing but the Connect
                // button ever wrote to the list.
                //
                // Gated on the probe having found something, which is what keeps
                // the list free of half-typed addresses: every keystroke schedules
                // one of these, and "192.168.1.5" on the way to "192.168.1.50" is
                // not a host anyone wants offered back to them.
                if reachable { Self.remember(host: address) }
                self.refresh()
            }
        }
        probe = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    private static func canReach(host: String, port: UInt16) -> Bool {
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

            // Offer the one obvious choice rather than making them open the list,
            // but never overwrite a host already chosen.
            if self.state.address.isEmpty, let first = hosts.first {
                self.state.address = first.connectTarget
                self.state.name = first.name
                self.scheduleProbe()
            } else if let match = hosts.first(where: { $0.connectTarget == self.state.address }) {
                self.state.name = match.name
            }
            self.refresh()
        }
        browser.start()
    }

    // MARK: - Actions

    /// A row was committed, or an address typed into the list's last row.
    private func hostPicked(_ address: String) {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard typed != state.address else { return }
        state.address = typed
        state.name = discovered.first { $0.connectTarget == typed }?.name
        state.isReachable = nil
        state.latency = nil
        refresh()
        scheduleProbe()
    }

    @objc private func connectTapped() {
        let host = state.address.trimmingCharacters(in: .whitespacesAndNewlines)
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

    /// Rows for the list: what is on the network now, then what was used before.
    /// Two kinds, so exactly one divider falls between them.
    private func hostItems() -> [HostDropdown.Item] {
        var items = discovered.map { host in
            HostDropdown.Item(address: host.connectTarget, name: host.name,
                              detail: host.connectTarget
                                  + (AgentConnection.storedToken(for: host.connectTarget) != nil
                                     ? " · paired" : " · not paired"),
                              dotState: .live, kind: .discovered)
        }
        items += HostBrowser.recentsWorthShowing(Self.recentHosts,
                                                 discovered: discovered).map { address in
            HostDropdown.Item(address: address, name: nil,
                              detail: AgentConnection.storedToken(for: address) != nil
                                  ? "paired" : "not paired",
                              dotState: .idle, kind: .recent)
        }
        return items
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
