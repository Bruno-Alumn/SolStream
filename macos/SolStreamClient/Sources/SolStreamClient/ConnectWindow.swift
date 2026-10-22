import AppKit
import DesignSystem
import SolStreamLogging
import MediaSession
import AgentChannel

/// "Which PC?"
///
/// Reachability and pairing state are shown on the host row itself rather than
/// behind a dialog, so connecting is one step and a problem is legible before you
/// press anything. The dot is the only coloured thing on the row: green is
/// reachable, a pulsing amber is still checking, coral is not answering. The
/// primary button relabels — `Pair & Connect` rather than a second button — so
/// there is never more than one way forward.
final class ConnectWindow: NSObject, NSWindowDelegate {
    private static let lastHostKey = "SolStream.lastHost"
    private static let recentHostsKey = "SolStream.recentHosts"
    private static let width: CGFloat = 440

    /// What we know about a host before connecting to it.
    private struct HostState {
        var address: String
        var name: String?
        /// Whether the agent's port answered. Nil while unknown.
        var isReachable: Bool?
        var isPaired: Bool
        var latency: TimeInterval?

        var needsPairing: Bool { !isPaired }
    }

    private let window: NSWindow
    private let hostDropdown = HostDropdown()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private let connectButton: DS.Button
    private let quitButton: DS.Button
    /// "Update 1.1.0 available", in the corner the buttons leave free. Not an
    /// alert and not the accent: the one thing this window is for is the PC,
    /// and the update waits in Settings until somebody wants it.
    private let updateNotice = NSButton(title: "", target: nil, action: nil)
    private var updateObserver: NSObjectProtocol?

    /// The first-run steps, between the subheading and the host row they end
    /// at. See `SetupGuide`.
    private let guide = SetupGuideView(width: ConnectWindow.width - DS.Metric.inset * 2)
    /// "Away from home? Tailscale…" and the one thing to do about it, under
    /// the hint. See `refreshTailscaleAdvice`.
    private let tailscaleRow = NSStackView()
    private let tailscaleWords = NSTextField(wrappingLabelWithString: "")
    private let tailscaleLink = LinkButton(title: "Get Tailscale", font: DS.caption,
                                           target: nil, action: nil)
    private var tailscale = TailscaleStatus.missing
    private var tailscaleCheckedAt: Date?
    /// Whether the Tailscale line is up. Remembered rather than worked out
    /// afresh each time, because "Checking…" says nothing either way and the
    /// line should neither appear nor go while a probe is out.
    private var showsTailscaleAdvice = false
    /// What the window was last sized for: which of the two optional parts
    /// were showing, and what the Tailscale line said, since its two wordings
    /// can wrap differently. The window is re-fitted when this changes and at
    /// no other time.
    private var fittedFor: (guide: Bool, advice: String?)?
    private var stack: NSStackView!

    private let browser = HostBrowser()
    private var discovered: [DiscoveredHost] = []
    private var state: HostState
    private var probe: DispatchWorkItem?
    /// Set once a host is picked or typed in this window. Until then the host on
    /// show is only what was remembered from last time, and discovery is allowed
    /// to replace it with a better one; after it, nothing replaces a choice.
    private var hostChosenHere = false
    /// Set while the other paired addresses are being tried, so a second
    /// failed probe does not start a second search.
    private var searchingRoutes = false

    private let onConnect: (String) -> Void

    init(onConnect: @escaping (String) -> Void) {
        self.onConnect = onConnect
        self.state = HostState(address: Self.lastHost ?? Self.recentHosts.first ?? "",
                               name: nil, isReachable: nil, isPaired: false, latency: nil)

        connectButton = DS.Button(title: "Connect", style: .primary, target: nil, action: nil)
        quitButton = DS.Button(title: "Quit", target: nil, action: nil)

        // 440 wide and exactly as tall as its content. It used to be a fixed
        // 420x280 with the content pinned to the top, which left a band of empty
        // ground under the buttons on every launch. The title bar is transparent
        // and the content runs under it, so the window reads as one surface with
        // the traffic lights sitting on it.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 440, height: 300),
                          styleMask: [.titled, .closable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        window.title = "SolStream"
        window.titleVisibility = .hidden
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.backgroundColor = DS.ground
        window.isMovableByWindowBackground = true

        super.init()
        build()
        window.delegate = self
        refresh()
        refreshUpdateNotice()
        updateObserver = NotificationCenter.default.addObserver(
            forName: Updater.didChange, object: Updater.shared, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshUpdateNotice() }
        }
    }

    deinit {
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
    }

    private func build() {
        // The mark, small: the one piece of brand on the one screen everybody
        // sees first. In the bundle this is the app icon; unbundled it is the
        // generic one, which is why it is an image view and not drawn here.
        let mark = NSImageView(image: NSApp.applicationIconImage ?? NSImage())
        mark.imageScaling = .scaleProportionallyUpOrDown
        mark.translatesAutoresizingMaskIntoConstraints = false
        mark.setAccessibilityElement(false)

        let heading = DS.label("Connect to your PC", font: DS.title)

        let subheading = NSTextField(wrappingLabelWithString:
            "SolStream streams one app from a Windows PC, not the whole desktop.")
        subheading.font = DS.body
        subheading.textColor = DS.textSecondary

        // ── The host row ────────────────────────────────────────────────────
        //
        // One control, not a field plus a menu. It shows the chosen host on two
        // lines with its state dot, and opens a list of the same rows over
        // itself — including, as the last row, the place to type an address that
        // discovery did not find.
        hostDropdown.translatesAutoresizingMaskIntoConstraints = false
        hostDropdown.onPick = { [weak self] address in self?.hostPicked(address) }

        // Supporting text, so `textMuted` rather than secondary: the subheading
        // above is the sentence to read, this is the footnote to the row.
        hintLabel.font = DS.body
        hintLabel.textColor = DS.textMuted
        hintLabel.maximumNumberOfLines = 2

        // A caption and a link, both quiet: this is advice for later, not the
        // way forward, which stays the one amber button.
        tailscaleWords.font = DS.caption
        tailscaleWords.textColor = DS.textMuted
        tailscaleWords.maximumNumberOfLines = 2
        tailscaleWords.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        tailscaleLink.target = self
        tailscaleLink.action = #selector(tailscaleTapped)
        // The link at the trailing end, under the buttons' column, where the
        // eye already goes for what to press.
        tailscaleRow.setViews([tailscaleWords], in: .leading)
        tailscaleRow.setViews([tailscaleLink], in: .trailing)
        tailscaleRow.orientation = .horizontal
        tailscaleRow.alignment = .firstBaseline
        tailscaleRow.spacing = DS.Space.x3
        tailscaleRow.isHidden = true

        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        connectButton.keyEquivalent = "\r"
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        // Escape here is the way out of SolStream, as Escape in the app picker
        // is the way back to here. This window is only up when nothing is
        // streaming, so it never ends a stream. An open PC list takes Escape
        // first and only closes itself.
        quitButton.keyEquivalent = "\u{1b}"

        updateNotice.target = self
        updateNotice.action = #selector(updateNoticeTapped)
        updateNotice.isBordered = false
        updateNotice.image = NSImage(systemSymbolName: "arrow.down.circle",
                                     accessibilityDescription: nil)
        updateNotice.symbolConfiguration = .init(pointSize: 11, weight: .medium)
        updateNotice.imagePosition = .imageLeading
        updateNotice.imageHugsTitle = true
        updateNotice.contentTintColor = DS.textMuted
        updateNotice.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        updateNotice.isHidden = true

        // Both buttons trailing, the primary last, the way every Mac dialog puts
        // them: the eye ends where the way forward is. The update notice, when
        // there is one, takes the leading end of the same line, so it costs
        // the window no height.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [updateNotice, spacer, quitButton, connectButton])
        buttons.orientation = .horizontal
        buttons.spacing = DS.Space.x3

        let stack = NSStackView(views: [mark, heading, subheading, guide, hostDropdown,
                                        hintLabel, tailscaleRow, buttons])
        self.stack = stack
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.x2
        stack.setCustomSpacing(DS.Space.x4, after: mark)
        stack.setCustomSpacing(DS.Space.x1, after: heading)
        stack.setCustomSpacing(DS.Space.x6, after: subheading)
        // A hidden view is taken out of the stack along with the spacing
        // after it, so with the guide hidden the subheading's 24 is what
        // stands above the host row, as it always did.
        stack.setCustomSpacing(DS.Space.x6, after: guide)
        stack.setCustomSpacing(DS.Space.x4, after: tailscaleRow)
        // 16, not 24: the hint always reserves a second line, so when it says
        // one the gap above the buttons is already a line taller.
        stack.setCustomSpacing(DS.Space.x4, after: hintLabel)
        // The top inset clears the title bar the content runs under, then the
        // usual inset below it.
        let inset = DS.Metric.inset
        stack.edgeInsets = NSEdgeInsets(top: DS.Metric.titleBar + DS.Space.x5, left: inset,
                                        bottom: inset, right: inset)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView()
        content.addSubview(stack)
        let width = content.widthAnchor.constraint(equalToConstant: Self.width)
        NSLayoutConstraint.activate([
            width,
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            mark.widthAnchor.constraint(equalToConstant: DS.Space.x12),
            mark.heightAnchor.constraint(equalToConstant: DS.Space.x12),
            subheading.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2),
            hostDropdown.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2),
            buttons.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2),
            hintLabel.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2),
            tailscaleRow.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -inset * 2),
            // Always two lines tall. The hint is one line or two depending on
            // what it is saying, and a window that grows and shrinks by a line
            // as a probe comes back is a window that jumps under the pointer.
            hintLabel.heightAnchor.constraint(equalToConstant:
                ceil(DS.body.boundingRectForFont.height) * 2),
        ])

        window.contentView = content
        window.setContentSize(content.fittingSize)
    }

    /// Size the window to its content, keeping its top edge where it is.
    ///
    /// Only when the guide or the Tailscale line comes or goes -- never as a
    /// probe comes back -- so the window changes size at most once or twice
    /// in its life rather than under the pointer. Kept at the top because
    /// that is where the eye is: `setContentSize` keeps the bottom, and the
    /// heading would jump instead of the buttons.
    private func fitIfLayoutChanged(guide showsGuide: Bool, advice: String?) {
        if let fittedFor, fittedFor.guide == showsGuide, fittedFor.advice == advice { return }
        fittedFor = (showsGuide, advice)
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        let size = content.fittingSize
        let old = window.frame
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: old.minX, y: old.maxY - frame.height)
        window.setFrame(frame, display: window.isVisible, animate: window.isVisible)
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
        // "Paired" means one thing: this Mac holds the host's agent token.
        state.isPaired = AgentConnection.hasStoredToken(for: state.address)

        var dotState: DS.Dot.State = .idle
        var parts: [HostDropdown.Detail] = []
        // The row's title is the discovered name when there is one, so the
        // address goes on the second line; without a name the title IS the
        // address, and repeating it would say nothing.
        if state.name != nil, !state.address.isEmpty {
            parts.append(.data(state.address))
        }
        switch state.isReachable {
        case .some(true):
            parts.append(.words(state.isPaired ? "Paired" : "Not paired"))
            if let latency = state.latency {
                parts.append(.data("\(Int(latency * 1000)) ms"))
            }
            dotState = .live
        case .some(false):
            parts.append(.words("Not answering"))
            dotState = .danger
        case nil:
            parts.append(.words(state.address.isEmpty ? "Enter an address" : "Checking…"))
            dotState = state.address.isEmpty ? .idle : .working
        }
        hostDropdown.setSelection(address: state.address, name: state.name,
                                  detail: parts, dotState: dotState)
        hostDropdown.items = hostItems()
        hostDropdown.isDiscovering = browser.isRunning

        switch (state.isReachable, state.needsPairing) {
        case (.some(true), true):
            // What the person will actually be asked for: the token on
            // SolStream's own window on the PC.
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
                ? "The first connection asks for the token shown on the PC."
                : "Found \(names) on this network."
            connectButton.title = "Connect"
        }
        // A Tailscale address with Tailscale off cannot answer however long
        // it is given, and every other reason the hint might give -- the PC
        // asleep, SolStream not running -- sends somebody to the wrong
        // machine to look.
        let tailscaleOff = StreamSettings.isRemote(host: state.address)
            && state.isReachable != true && !tailscale.isConnected
        if tailscaleOff {
            hintLabel.stringValue = "That's a Tailscale address, and Tailscale is off on this Mac."
        }
        hintLabel.textColor = DS.textMuted
        connectButton.isEnabled = !state.address.isEmpty

        // "Paired" for the guide is about this Mac, not the host on show: a
        // Mac paired with one PC knows how this works.
        let steps = SetupGuide.steps(paired: TokenStore.hasAnyToken,
                                     discovered: discovered.count,
                                     reachable: state.isReachable)
        guide.isHidden = steps == nil
        if let steps { guide.show(steps) }
        refreshTailscaleAdvice(firstRun: steps != nil, tailscaleOff: tailscaleOff)
    }

    /// The Tailscale line: shown on a first run, and when the PC on show is
    /// not answering -- exactly when somebody might be away from home, or
    /// about to be -- unless this Mac is on Tailscale already.
    private func refreshTailscaleAdvice(firstRun: Bool, tailscaleOff: Bool) {
        // At most every few seconds. Turning Tailscale on is noticed sooner
        // than that when it matters: coming back from its app makes this
        // window key, which asks again (`windowDidBecomeKey`).
        if tailscaleCheckedAt.map({ Date().timeIntervalSince($0) > 3 }) ?? true {
            tailscale = .current()
            tailscaleCheckedAt = Date()
        }
        if firstRun || tailscaleOff {
            showsTailscaleAdvice = true
        } else if let reachable = state.isReachable {
            showsTailscaleAdvice = !reachable
        }
        let advice = showsTailscaleAdvice ? tailscale.advice : nil
        tailscaleRow.isHidden = advice == nil
        if let advice {
            tailscaleWords.stringValue = advice.words
            tailscaleLink.words = advice.action
            tailscaleWords.preferredMaxLayoutWidth = Self.width - DS.Metric.inset * 2
                - tailscaleLink.intrinsicContentSize.width - tailscaleRow.spacing
        }
        // The hint keeps a second line whatever it says, so with the line
        // under it the gap is already a line tall and wants no more.
        stack.setCustomSpacing(advice == nil ? DS.Space.x4 : DS.Space.x1, after: hintLabel)
        fitIfLayoutChanged(guide: !guide.isHidden, advice: advice?.words)
    }

    /// Reachability is checked by opening the port, not by pinging: what matters
    /// is whether the thing we need is listening, not whether the machine replies
    /// to ICMP.
    ///
    /// One probe per debounced keystroke: each is a connection the agent sees.
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
                if !reachable, self.preferDiscoveredHost() { return }
                if !reachable, self.preferAnotherRoute() { return }
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
                if !reachable { self.recheckLater(address) }
            }
        }
        probe = work
        DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + 0.15, execute: work)
    }

    /// Open the port, with a hard deadline: three seconds, because the first
    /// connection over Tailscale after a quiet spell has to wake the tunnel,
    /// and through a relay that took longer than 1.5 s -- the address that
    /// worked was reported as not answering. Non-blocking, because a blocking
    /// connect ignores SO_SNDTIMEO here: an address on somebody else's network
    /// that silently drops the SYN held each probe for the kernel's full
    /// connect timeout, far longer than anybody looks at this window.
    private static func canReach(host: String, port: UInt16,
                                 timeoutMs: Int32 = 3000) -> Bool {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return false }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 { return true }
        guard errno == EINPROGRESS else { return false }
        var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiting, 1, timeoutMs) == 1 else { return false }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0
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
            } else if self.preferDiscoveredHost() {
                return
            }
            self.refresh()
        }
        browser.start()
    }

    /// Swap a remembered host that is not answering for a discovered one this
    /// Mac is already paired with. Returns true when it switched.
    ///
    /// The window opens on the last host used, and addresses move: a DHCP lease
    /// renews, and the PC that was 192.168.1.21 yesterday answers discovery
    /// as DESKTOP-EXAMPLE at 192.168.1.20 today. The window then sat on the
    /// stale address saying "Checking…", and then "Not answering", while the
    /// PC it meant was in the list one click away.
    ///
    /// "Not answering" includes "has not answered yet". A discovered host has
    /// just answered — that is how it was discovered — while the remembered
    /// one is unproven, and waiting out its probe's timeout first would show
    /// the wrong host for the two seconds anybody spends looking at this.
    ///
    /// Only before anybody has chosen a host here, and only for a paired host:
    /// a choice is never overridden, and a host that would ask for a token is
    /// not an improvement on one that might yet answer.
    @discardableResult
    private func preferDiscoveredHost() -> Bool {
        guard !hostChosenHere, state.isReachable != true,
              !discovered.contains(where: { $0.connectTarget == state.address }),
              let paired = discovered.first(where: {
                  AgentConnection.hasStoredToken(for: $0.connectTarget)
              }) else { return false }
        Log.info("[connect] \(state.address) has not answered; preferring \(paired.connectTarget), "
                 + "found on the network and already paired")
        state.address = paired.connectTarget
        state.name = paired.name
        state.isReachable = nil
        state.latency = nil
        refresh()
        scheduleProbe()
        return true
    }

    /// The same PC by another road. Returns true when a search was started.
    ///
    /// A PC has more than one address -- its home-network one and its Tailscale
    /// one -- and which answers depends on where the Mac is. Away from home the
    /// remembered 192.168.1.x is somebody else's network: it refuses, or it is
    /// a different machine altogether. The window used to sit on it saying "Not
    /// answering" while the Tailscale address that works from anywhere was one
    /// click away in the list. So the other addresses this Mac is paired with
    /// are tried, quietly, and the first that answers is shown instead.
    ///
    /// The same rules as `preferDiscoveredHost`: never after a choice was made
    /// in this window, and only paired addresses, so the switch never lands on
    /// one that would ask for a token.
    private func preferAnotherRoute() -> Bool {
        guard !hostChosenHere, !searchingRoutes else { return false }
        let failed = state.address
        let candidates = Self.recentHosts.filter {
            $0 != failed && AgentConnection.hasStoredToken(for: $0)
        }
        guard !candidates.isEmpty else { return false }
        searchingRoutes = true
        // All at once, not one after another: a dead address costs its whole
        // timeout, and a `.local` name that will not resolve costs five
        // seconds before the next one is even tried. The most recently used
        // address that answers wins, so at home the home-network one is kept.
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let resultsLock = NSLock()
            var answered: [String: TimeInterval] = [:]
            let group = DispatchGroup()
            for candidate in candidates {
                group.enter()
                DispatchQueue.global(qos: .userInitiated).async {
                    let started = Date()
                    if Self.canReach(host: candidate, port: StreamPorts.agent) {
                        resultsLock.lock()
                        answered[candidate] = Date().timeIntervalSince(started)
                        resultsLock.unlock()
                    }
                    group.leave()
                }
            }
            _ = group.wait(timeout: .now() + 3.5)
            resultsLock.lock()
            let found = candidates.first { answered[$0] != nil }
                .map { (address: $0, latency: answered[$0]!) }
            resultsLock.unlock()
            DispatchQueue.main.async {
                guard let self else { return }
                self.searchingRoutes = false
                // Only if nothing moved meanwhile: a pick, or discovery winning.
                guard !self.hostChosenHere, self.state.address == failed else { return }
                guard let found else {
                    // Nothing else answered either. Say so -- the search started
                    // from a failed probe that had not refreshed the window, and
                    // returning here without one left it on "Checking…" for good
                    // -- and try the shown address again shortly, since the
                    // likeliest cause is a network that is still coming up.
                    self.refresh()
                    self.recheckLater(failed)
                    return
                }
                Log.info("[connect] \(failed) is not answering from this network; "
                         + "\(found.address) is, and is paired")
                self.state.address = found.address
                self.state.name = nil
                self.state.isReachable = true
                self.state.latency = found.latency
                Self.remember(host: found.address)
                self.refresh()
            }
        }
        return true
    }

    /// Probe the shown address again in a few seconds, if it is still the one
    /// shown and still not answering. A Mac that just woke, or a tunnel still
    /// coming up, answers a moment later; the window should notice rather than
    /// wait for somebody to reopen it.
    private func recheckLater(_ address: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.window.isVisible, self.state.address == address,
                  self.state.isReachable != true, !self.searchingRoutes else { return }
            self.scheduleProbe()
        }
    }

    // MARK: - Actions

    /// A row was committed, or an address typed into the list's last row.
    private func hostPicked(_ address: String) {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        hostChosenHere = true
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
            hintLabel.textColor = DS.danger
            return
        }
        Self.remember(host: host)
        close()
        onConnect(host)
    }

    @objc private func tailscaleTapped() {
        tailscale.act()
    }

    @objc private func quitTapped() {
        NSApp.terminate(nil)
    }

    /// Settings, where the Updates card has the button. Installing straight
    /// from a line this small would be a relaunch nobody saw coming.
    @objc private func updateNoticeTapped() {
        NotificationCenter.default.post(name: StreamSettings.openSettingsRequest, object: nil)
    }

    private func refreshUpdateNotice() {
        guard let version = MainActor.assumeIsolated({ Updater.shared.announcedVersion }) else {
            updateNotice.isHidden = true
            return
        }
        updateNotice.attributedTitle = NSAttributedString(
            string: " Update \(version) available",
            attributes: [.font: DS.caption, .foregroundColor: DS.textSecondary])
        updateNotice.setAccessibilityLabel("Update \(version) available. Opens Settings.")
        updateNotice.isHidden = false
    }

    /// Back from somewhere else -- often the Tailscale app, or the browser
    /// the download opened in. Whatever was done there, the window should
    /// say so now rather than in a few seconds.
    func windowDidBecomeKey(_ notification: Notification) {
        tailscaleCheckedAt = nil
        refresh()
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
                              detail: [.data(host.connectTarget),
                                       .words(AgentConnection.hasStoredToken(for: host.connectTarget)
                                              ? "Paired" : "Not paired")],
                              dotState: .live, kind: .discovered)
        }
        items += HostBrowser.recentsWorthShowing(Self.recentHosts,
                                                 discovered: discovered).map { address in
            HostDropdown.Item(address: address, name: nil,
                              detail: [.words("Used before"),
                                       .words(AgentConnection.hasStoredToken(for: address)
                                              ? "Paired" : "Not paired")],
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
