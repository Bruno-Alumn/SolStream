import AppKit
import Network
import DesignSystem
import SolStreamLogging
import MediaSession
import AgentChannel

/// "Which PC?"
///
/// Reachability and pairing state are shown on the host row itself rather than
/// behind a dialog, so connecting is one step and a problem is legible before you
/// press anything. The dot is the only coloured thing on the row: green is
/// reachable, a pulsing blue is still checking, coral is not answering. The
/// primary button relabels — `Pair & Connect` rather than a second button — so
/// there is never more than one way forward.
final class ConnectWindow: NSObject, NSWindowDelegate {
    private static let lastHostKey = "SolStream.lastHost"
    private static let recentHostsKey = "SolStream.recentHosts"
    private static let width: CGFloat = 440
    static var contentWidth: CGFloat { width }

    /// What we know about a host before connecting to it.
    private struct HostState {
        var address: String
        var name: String?
        /// Whether the agent's port answered. Nil while unknown.
        var isReachable: Bool?
        /// Not answering because the PC turned the connection away: it is on,
        /// and nothing is listening -- SolStream is not running, most often
        /// because nobody is signed in to Windows. Silence instead is a PC
        /// asleep, off, or out of reach.
        var isRefused = false
        /// The address itself is the trouble: see `Reach`.
        var addressProblem: Reach?
        var isPaired: Bool
        var latency: TimeInterval?
        /// What this Mac's Tailscale was when the PC was last asked, for the
        /// answer on its way or the one in `isReachable`: the whole reading,
        /// tailnet address and all, not only whether it was on. Nil until it
        /// is asked.
        var askedUnderTailscale: TailscaleStatus?

        var needsPairing: Bool { !isPaired }
    }

    private let window: NSWindow
    private let hostDropdown = HostDropdown()
    private let hintLabel = NSTextField(wrappingLabelWithString: "")
    private lazy var hintVoice = MainActor.assumeIsolated { DS.Announcer() }
    private let connectButton: DS.Button
    private let quitButton: DS.Button
    /// Sends the PC a wake-on-LAN packet; shown while it is silent and this
    /// Mac knows how to wake it. See `WakeOnLAN`.
    let wakeButton: DS.Button
    /// When Wake was pressed for the PC shown, for what the hint says while
    /// it may still be waking.
    private var wokeAt: Date?
    /// The last Wake could not send its packet at all.
    private var wakeFailed = false
    /// "Update 1.1.0 available", in the corner the buttons leave free. Not an
    /// alert and not the accent: the one thing this window is for is the PC,
    /// and the update waits in Settings until somebody wants it.
    private let updateNotice = NSButton(title: "", target: nil, action: nil)
    /// Settings, from the first window, rather than only from a menu.
    let settingsButton = NSButton(title: "", target: nil, action: nil)
    private var updateObserver: NSObjectProtocol?
    /// Escape quits from here; see `installEscapeToQuit`.
    private var escapeMonitor: Any?
    private var becameKeyAt = Date.distantPast

    /// The first-run steps, between the subheading and the host row they end
    /// at. See `SetupGuide`.
    private let guide = SetupGuideView(width: ConnectWindow.width - DS.Metric.inset * 2)
    /// "Away from home? Tailscale…" and the one thing to do about it, under
    /// the hint. See `refreshTailscaleAdvice`.
    private let tailscaleRow = NSStackView()
    private let tailscaleWords = NSTextField(wrappingLabelWithString: "")
    private let tailscaleLink = LinkButton(title: "Get Tailscale", font: DS.caption,
                                           target: nil, action: nil)
    private var tailscale: TailscaleStatus
    /// When `tailscale` was read. Nil has the next refresh read it again.
    private var tailscaleCheckedAt: Date?
    /// This Mac's network, watched while the window is up; see
    /// `networkChanged`.
    private var pathMonitor: NWPathMonitor?
    /// Whether the Tailscale line's words are up. Remembered rather than
    /// worked out afresh each time, because "Checking…" says nothing either
    /// way and the words should neither appear nor go while a probe is out.
    private var showsTailscaleAdvice = false
    /// The hint says the network can't be searched: the line under it offers
    /// the Local Network settings, in Tailscale's place -- nothing on the
    /// network can be found, Tailscale's PCs or any other, until it is allowed.
    private var showsLocalNetworkLink = false
    /// The search failed on a network this Mac is on: Local Network access is
    /// off, not merely no network.
    private var localNetworkDenied = false
    /// What the window was last sized for: which of the two optional parts
    /// had room, and what the Tailscale line says, since its two wordings
    /// can wrap differently. The window is re-fitted when this changes and at
    /// no other time.
    private var fittedFor: (guide: Bool, advice: String?)?
    private var stack: NSStackView!

    private let browser = HostBrowser()
    /// Discovery's questions can't go out: see `HostBrowser.onCannotAsk`.
    private var cannotAskNetwork = false
    private var discovered: [DiscoveredHost] = []
    private var state: HostState
    private var probe: DispatchWorkItem?
    /// Which probe is the latest. Cancelling one that is already connecting
    /// does not stop it, and its answer -- given before Tailscale came up,
    /// say -- would otherwise land after the fresh probe was asked for. The
    /// same goes for a recheck an older probe asked for (`recheckLater`).
    private var probeGeneration = 0
    /// Set once a host is picked or typed in this window. Until then the host on
    /// show is only what was remembered from last time, and discovery is allowed
    /// to replace it with a better one; after it, nothing replaces a choice.
    private var hostChosenHere = false
    /// Set while the other paired addresses are being tried, so a second
    /// failed probe does not start a second search.
    private var searchingRoutes = false

    private let onConnect: (String) -> Void
    /// Whether this Mac is on Tailscale, and whether a host answers on the
    /// agent's port: the real readings, except in tests.
    private let readTailscale: () -> TailscaleStatus
    /// What opening the agent's port found.
    /// What a probe found. Not answering is told apart from a name that
    /// leads nowhere -- a typo sent people to check a PC that was fine -- and
    /// from a name that leads only to IPv6, which the PC doesn't listen on.
    enum Reach: Equatable { case open, refused, silent, unknownName, ipv6Only }

    private let reach: (String) -> Reach
    /// Where the hosts used before are kept: the app's own defaults, except
    /// in tests, which each keep theirs apart -- the standard defaults of a
    /// test run are shared by every test run on the Mac at the time.
    private let defaults: UserDefaults

    init(onConnect: @escaping (String) -> Void,
         readTailscale: @escaping () -> TailscaleStatus = TailscaleStatus.current,
         reach: ((String) -> Bool)? = nil,
         defaults: UserDefaults = .standard) {
        self.onConnect = onConnect
        self.readTailscale = readTailscale
        self.reach = reach.map { reach in { reach($0) ? .open : .silent } }
            ?? { Self.canReach(host: $0, port: StreamPorts.agent) }
        self.defaults = defaults
        let shown = Self.lastHost(in: defaults) ?? Self.recentHosts(in: defaults).first ?? ""
        self.state = HostState(address: shown, name: nil, isReachable: nil, isPaired: false,
                               latency: nil)
        // Read now: there must be a reading before the window is built, and
        // the first refresh can take this one as it is.
        self.tailscale = readTailscale()
        self.tailscaleCheckedAt = Date()

        connectButton = DS.Button(title: "Connect", style: .primary, target: nil, action: nil)
        quitButton = DS.Button(title: "Quit", target: nil, action: nil)
        wakeButton = DS.Button(title: "Wake PC", target: nil, action: nil)

        // 440 wide and exactly as tall as its content. It used to be a fixed
        // 420x280 with the content pinned to the top, which left a band of empty
        // ground under the buttons on every launch. The title bar is transparent
        // and the content runs under it, so the window reads as one surface with
        // the traffic lights sitting on it.
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
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
        // A window replaced while showing is never closed first.
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        pathMonitor?.cancel()
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
        hostDropdown.onForget = { [weak self] address in
            guard let self else { return }
            Self.forget(host: address, in: self.defaults)
            // Forgetting the PC on show moves the window on to another --
            // left on it, Connect would put it straight back.
            if TokenStore.sameHost(address, self.state.address) {
                let next = self.discovered.first?.connectTarget ?? self.recentHosts.first ?? ""
                self.hostPicked(next)
            } else {
                self.refresh()
            }
        }

        hostDropdown.onForgetPairing = { [weak self] item in self?.askToForgetPairing(item) }

        // Supporting text, so `textMuted` rather than secondary: the subheading
        // above is the sentence to read, this is the footnote to the row.
        hintLabel.font = DS.body
        hintLabel.textColor = DS.textMuted
        hintLabel.maximumNumberOfLines = 2

        // A caption and a link, both quiet: this is advice for later, not the
        // way forward, which stays the one blue button.
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
        // Hidden words keep their room; see `refreshTailscaleAdvice`.
        tailscaleRow.detachesHiddenViews = false

        connectButton.target = self
        connectButton.action = #selector(connectTapped)
        connectButton.keyEquivalent = "\r"
        quitButton.target = self
        quitButton.action = #selector(quitTapped)
        wakeButton.target = self
        wakeButton.action = #selector(wakeTapped)
        wakeButton.isHidden = true

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

        // A gear at the leading end, quiet like the update notice beside it:
        // a way to Settings before connecting, where the codec, sound and
        // mouse are chosen, without hunting for the menu.
        settingsButton.target = self
        settingsButton.action = #selector(settingsTapped)
        settingsButton.isBordered = false
        settingsButton.image = NSImage(systemSymbolName: "gearshape",
                                       accessibilityDescription: "Settings")
        settingsButton.symbolConfiguration = .init(pointSize: 17, weight: .regular)
        settingsButton.imagePosition = .imageOnly
        settingsButton.contentTintColor = DS.textSecondary
        settingsButton.toolTip = "Settings (⌘,)"
        settingsButton.setAccessibilityLabel("Settings")
        settingsButton.setContentHuggingPriority(.required, for: .horizontal)

        // Both buttons trailing, the primary last, the way every Mac dialog puts
        // them: the eye ends where the way forward is. Settings, and the update
        // notice when there is one, take the leading end of the same line, so
        // they cost the window no height.
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let buttons = NSStackView(views: [settingsButton, updateNotice, spacer, wakeButton,
                                          quitButton, connectButton])
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
        installEscapeToQuit()
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startDiscovery()
        watchNetwork()
        scheduleProbe()
    }

    /// On screen or in the Dock, as opposed to closed or handed off to the
    /// picker.
    var isOpen: Bool { window.isVisible || window.isMiniaturized }

    /// Forward again, for a window that is already open: `show` would start
    /// a second discovery over the first.
    func bringToFront() {
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Open the host list, for `--test-dropdown`.
    func openDropdownForTesting() -> NSWindow? {
        hostDropdown.openForTesting()
        return hostDropdown.listWindow
    }

    /// Ask the PC on show, as `show()` does, without showing the window.
    func probeForTesting() {
        scheduleProbe()
    }

    func close() {
        tearDown()
        window.orderOut(nil)
    }

    /// Stop everything that would go on refreshing a window nobody sees.
    private func tearDown() {
        removeEscapeToQuit()
        browser.stop()
        stopWatchingNetwork()
        stopProbing()
    }

    /// Cancelling the probe does not stop one already connecting, and its
    /// answer, or a recheck already asked for, would otherwise go on
    /// refreshing a window that is gone -- and could probe the PC again
    /// just as the picker connects to it.
    private func stopProbing() {
        probe?.cancel()
        probeGeneration += 1
    }

    // MARK: - State

    /// Everything the row and the button say is derived from one state, so they
    /// can never disagree with each other.
    private func refresh() {
        // First, before anything below reads it: the hint and the Tailscale
        // line used to be decided from the last reading and then refreshed,
        // so coming back from turning Tailscale on still said it was off.
        readTailscaleIfDue()
        let askedUnderAnotherTailscale = forgetAnswerFromAnotherTailscale()
        // "Paired" means one thing: this Mac holds the host's agent token.
        state.isPaired = AgentConnection.hasStoredToken(
            for: state.address, named: state.name.map { HostBrowser.baseName(of: $0) ?? $0 })

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
            parts.append(.words(state.addressProblem == .unknownName ? "Name not found"
                : state.addressProblem == .ipv6Only ? "IPv6 only"
                : state.isRefused ? "SolStream not running" : "Not answering"))
            dotState = .danger
        case nil:
            parts.append(.words(state.address.isEmpty ? "Enter an address" : "Checking…"))
            dotState = state.address.isEmpty ? .idle : .working
        }
        hostDropdown.setSelection(address: state.address, name: state.name,
                                  detail: parts, dotState: dotState)
        hostDropdown.items = hostItems()
        hostDropdown.isDiscovering = browser.isRunning

        wakeButton.isHidden = !(state.isReachable == false && !state.isRefused && canWake)
        if state.isReachable == true {
            wokeAt = nil
            wakeFailed = false
        }

        switch (state.isReachable, state.needsPairing) {
        case (.some(true), true):
            // What the person will actually be asked for: the token on
            // SolStream's own window on the PC.
            hintLabel.stringValue = ConnectHint.pairingNeeded
            connectButton.title = "Pair & Connect"
        case (.some(true), false):
            hintLabel.stringValue = ConnectHint.paired
            connectButton.title = "Connect"
        case (.some(false), _):
            hintLabel.stringValue = offlineHint()
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
            hintLabel.stringValue = !discovered.isEmpty
                ? ConnectHint.found(names)
                : cannotAskNetwork ? ConnectHint.cannotSearch : ConnectHint.firstConnection
            connectButton.title = "Connect"
        }
        // A Tailscale address with Tailscale off cannot answer however long
        // it is given, and every other reason the hint might give -- the PC
        // asleep, SolStream not running -- sends somebody to the wrong
        // machine to look.
        let tailscaleOff = StreamSettings.isRemote(host: state.address)
            && state.isReachable != true && !tailscale.isConnected
        if tailscaleOff {
            // A MagicDNS name is certainly Tailscale's. A 100.64/10 address
            // only probably is: phone hotspots' carrier NAT and other VPNs
            // hand out the same range, so it is said as an if.
            let certain = state.address.lowercased()
                .trimmingCharacters(in: CharacterSet(charactersIn: ".")).hasSuffix(".ts.net")
            hintLabel.stringValue = certain ? ConnectHint.tailscaleOff : ConnectHint.maybeTailscale
        }
        hintLabel.textColor = DS.textMuted
        showsLocalNetworkLink = Self.offersLocalNetworkSettings(
            denied: localNetworkDenied, discovered: discovered.count,
            address: state.address, reachable: state.isReachable)
        // The whole of it on hover, should a long PC name still push a hint
        // past its two lines.
        hintLabel.toolTip = hintLabel.stringValue
        // Said to VoiceOver when it changes, in the window in front: the
        // probe's answer -- asleep, needs pairing, Tailscale off -- was only
        // ever drawn.
        // Not while the PC on show has yet to answer -- what the line says
        // then is a placeholder -- and only once it has stayed put a moment.
        MainActor.assumeIsolated {
            if window.isKeyWindow, state.address.isEmpty || state.isReachable != nil {
                hintVoice.sayWhenSettled(hintLabel.stringValue)
            } else {
                hintVoice.hush()
            }
        }
        connectButton.isEnabled = !state.address.isEmpty

        // "Paired" for the guide is about this Mac, not the host on show: a
        // Mac paired with one PC knows how this works.
        let steps = SetupGuide.steps(paired: TokenStore.hasAnyToken,
                                     discovered: discovered.count,
                                     reachable: state.isReachable,
                                     cannotSearch: showsLocalNetworkLink)
        guide.isHidden = steps == nil
        if let steps { guide.show(steps) }
        refreshTailscaleAdvice(firstRun: steps != nil, tailscaleOff: tailscaleOff)

        // Tailscale came up, went down or changed tailnet since the PC was
        // asked: ask it again now, rather than at the next recheck, which a
        // PC that answered never gets. An answer still on its way is
        // dropped (`probeGeneration`).
        if askedUnderAnotherTailscale, state.isReachable != true {
            scheduleProbe()
        }
    }

    /// Whether this Mac is on Tailscale, asked at most every few seconds.
    /// Turning Tailscale on is noticed sooner than that when it matters:
    /// coming back from its app makes this window key, which asks again
    /// (`windowDidBecomeKey`), so does a change to the network
    /// (`networkChanged`), and every probe asks afresh (`scheduleProbe`).
    private func readTailscaleIfDue() {
        guard tailscaleCheckedAt.map({ Date().timeIntervalSince($0) > 3 }) ?? true else { return }
        tailscale = readTailscale()
        tailscaleCheckedAt = Date()
    }

    /// Whether the PC on show was asked under another Tailscale than this
    /// Mac's now: on and now off, off and now on, or on another tailnet.
    ///
    /// A Tailscale address answered, or did not, through the Tailscale there
    /// was then, and its answer is forgotten. Kept, that went on saying "Not
    /// answering" -- now with "Check the PC is awake" -- after Tailscale came
    /// up, until the next probe; or "Reachable" after it went down, with no
    /// probe to come. Until the PC is asked again, it is "Checking…". So too
    /// after switching to another tailnet from Tailscale's menu, which
    /// leaves it on throughout: the old tailnet's PC is not on the new one.
    ///
    /// Measured against the Tailscale the probe was sent under, not against
    /// the reading before this one: that could be a few seconds old, and a
    /// fresh answer through a tunnel that had just come up was taken for
    /// one from before it, thrown away, and asked for again.
    @discardableResult
    private func forgetAnswerFromAnotherTailscale() -> Bool {
        guard let asked = state.askedUnderTailscale, asked != tailscale else { return false }
        if StreamSettings.isRemote(host: state.address) {
            state.isReachable = nil
            state.latency = nil
        }
        return true
    }

    /// The Tailscale line: its words shown on a first run, and when the PC on
    /// show is not answering -- exactly when somebody might be away from
    /// home, or about to be -- unless this Mac is on Tailscale already.
    ///
    /// Its room is kept whenever this Mac is not on Tailscale, words or no
    /// words. The line used to come and go with the words, and so with each
    /// probe, which moved Quit and Connect a line and more under the pointer
    /// a few seconds after the window opened, and back when the PC answered.
    private func refreshTailscaleAdvice(firstRun: Bool, tailscaleOff: Bool) {
        if firstRun || tailscaleOff {
            showsTailscaleAdvice = true
        } else if let reachable = state.isReachable {
            showsTailscaleAdvice = !reachable
        }
        let advice = showsLocalNetworkLink ? nil : tailscale.advice
        if showsLocalNetworkLink {
            tailscaleRow.isHidden = false
            tailscaleWords.isHidden = true
            tailscaleLink.isHidden = false
            tailscaleLink.words = ConnectHint.localNetworkAction
            stack.setCustomSpacing(DS.Space.x1, after: hintLabel)
            fitIfLayoutChanged(guide: !guide.isHidden, advice: ConnectHint.localNetworkAction)
            return
        }
        tailscaleRow.isHidden = advice == nil
        tailscaleWords.isHidden = !showsTailscaleAdvice
        // No link at all where the advice is a command to run.
        tailscaleLink.isHidden = !showsTailscaleAdvice || advice?.action == nil
        if let advice {
            tailscaleWords.stringValue = advice.words
            tailscaleLink.words = advice.action ?? ""
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
        probeGeneration += 1
        let generation = probeGeneration
        let address = state.address
        guard !address.isEmpty else {
            state.isReachable = nil
            state.askedUnderTailscale = nil
            refresh()
            return
        }
        // Read now, not a few seconds ago: the answer is kept or forgotten
        // by what this Mac's Tailscale was when it was asked
        // (`forgetAnswerFromAnotherTailscale`). The last answer goes by the
        // same rule here, or a refresh before this one is back would show
        // it beside the hint for the Tailscale there is now.
        tailscaleCheckedAt = nil
        readTailscaleIfDue()
        forgetAnswerFromAnotherTailscale()
        state.askedUnderTailscale = tailscale
        let reach = self.reach
        let work = DispatchWorkItem { [weak self] in
            let started = Date()
            let answer = reach(address)
            let reachable = answer == .open
            let elapsed = Date().timeIntervalSince(started)
            DispatchQueue.main.async {
                guard let self, self.probeGeneration == generation,
                      self.state.address == address else { return }
                self.state.isReachable = reachable
                self.state.isRefused = answer == .refused
                self.state.addressProblem =
                    answer == .unknownName || answer == .ipv6Only ? answer : nil
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
                if reachable { self.remember(host: address) }
                self.refresh()
                if !reachable { self.recheckLater(address, generation: generation) }
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
    ///
    /// Turned away outright -- a reset, which Windows sends for a port nothing
    /// listens on when its firewall lets the knock through -- is told apart
    /// from no answer at all: one is a PC that is on, the other may be asleep.
    private static func canReach(host: String, port: UInt16,
                                 timeoutMs: Int32 = 3000) -> Reach {
        var hints = addrinfo(ai_flags: 0, ai_family: AF_UNSPEC, ai_socktype: SOCK_STREAM,
                             ai_protocol: 0, ai_addrlen: 0, ai_canonname: nil,
                             ai_addr: nil, ai_next: nil)
        var info: UnsafeMutablePointer<addrinfo>?
        let looked = getaddrinfo(host, String(port), &hints, &info)
        guard looked == 0, let head = info else {
            // Only a name the resolver says is no name at all. A .local name
            // whose PC is asleep fails to resolve too, as does any name while
            // the Mac's network is still coming up -- those are "not
            // answering", not a misspelling.
            let local = host.lowercased().hasSuffix(".local") || host.lowercased().hasSuffix(".local.")
            return looked == EAI_NONAME && !local ? .unknownName : .silent
        }
        // The IPv4 address when there is one: the PC listens on IPv4 only, and
        // macOS puts a .local name's link-local IPv6 address first, so a working
        // PC was probed where it is not listening and shown as not answering.
        // One lookup, so a name that does not resolve costs one timeout.
        var first: UnsafeMutablePointer<addrinfo>?
        var entry: UnsafeMutablePointer<addrinfo>? = head
        while let candidate = entry {
            if candidate.pointee.ai_family == AF_INET {
                first = candidate
                break
            }
            entry = candidate.pointee.ai_next
        }
        defer { freeaddrinfo(info) }
        // Only IPv6: the PC listens on IPv4 alone, so knocking is no use, and
        // "not answering" would send someone to check a PC that is fine.
        guard let first else { return .ipv6Only }

        let fd = socket(first.pointee.ai_family, first.pointee.ai_socktype, first.pointee.ai_protocol)
        guard fd >= 0 else { return .silent }
        defer { Darwin.close(fd) }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        if connect(fd, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0 { return .open }
        guard errno == EINPROGRESS else { return errno == ECONNREFUSED ? .refused : .silent }
        var waiting = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&waiting, 1, timeoutMs) == 1 else { return .silent }
        var failure: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &failure, &length)
        return failure == 0 ? .open : failure == ECONNREFUSED ? .refused : .silent
    }

    // MARK: - Discovery

    private func startDiscovery() {
        browser.onChange = { [weak self] hosts in
            // An answer queued before the window closed (`tearDown` stops the
            // browser): Connect has the PC now, and probing it again here would
            // race the picker.
            guard let self, self.browser.isRunning else { return }
            self.discovered = hosts

            self.cannotAskNetwork = false
            // Offer the one obvious choice rather than making them open the list,
            // but never overwrite a host already chosen. Obvious means one this
            // Mac is paired with, or the only PC answering: anything on the
            // network can answer, and the first name alphabetically was picked
            // for anyone who answered as "AAA-PC".
            if self.state.address.isEmpty,
               let first = hosts.first(where: Self.isPaired)
                ?? (hosts.count == 1 ? hosts.first : nil) {
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
        browser.onCanAsk = { [weak self] canAsk in
            guard let self, self.browser.isRunning else { return }
            self.cannotAskNetwork = !canAsk
            self.localNetworkDenied = !canAsk && self.browser.askingDenied
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
    /// Only before anybody has chosen a host here, and only for a paired host:
    /// a choice is never overridden, and a host that would ask for a token is
    /// not an improvement on one that might yet answer.
    ///
    /// Only once the remembered one has been asked and failed, though, not
    /// while it may yet answer: with two paired PCs on one network, whichever
    /// answered discovery first replaced the last one used -- and was then
    /// remembered as the last one used.
    @discardableResult
    private func preferDiscoveredHost() -> Bool {
        guard !hostChosenHere, state.isReachable == false,
              !discovered.contains(where: { $0.connectTarget == state.address }),
              let paired = discovered.first(where: Self.isPaired) else { return false }
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
        let candidates = recentHosts.filter {
            $0 != failed && AgentConnection.hasStoredToken(for: $0)
        }
        guard !candidates.isEmpty else { return false }
        searchingRoutes = true
        // The probe that failed. The search answers for it, and asks for its
        // recheck, only while it is the latest (`probeGeneration`).
        let generation = probeGeneration
        let reach = self.reach
        let askedUnderTailscale = state.askedUnderTailscale
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
                    if reach(candidate) == .open {
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
                // Only if nothing moved meanwhile: a pick, discovery winning, a
                // newer probe, or the window closing. Closed by Connect, the
                // window took the answer all the same, remembered the other
                // address as the one last used, and could probe the PC again.
                guard self.probeGeneration == generation, !self.hostChosenHere,
                      self.state.address == failed else { return }
                guard let found else {
                    // Nothing else answered either. Say so -- the search started
                    // from a failed probe that had not refreshed the window, and
                    // returning here without one left it on "Checking…" for good
                    // -- and try the shown address again shortly, since the
                    // likeliest cause is a network that is still coming up.
                    self.refresh()
                    self.recheckLater(failed, generation: generation)
                    return
                }
                Log.info("[connect] \(failed) is not answering from this network; "
                         + "\(found.address) is, and is paired")
                self.state.address = found.address
                self.state.name = nil
                self.state.isReachable = true
                self.state.latency = found.latency
                self.state.askedUnderTailscale = askedUnderTailscale
                self.remember(host: found.address)
                self.refresh()
            }
        }
        return true
    }

    /// Probe the shown address again in a few seconds, if it is still the one
    /// shown and still not answering. A Mac that just woke, or a tunnel still
    /// coming up, answers a moment later; the window should notice rather than
    /// wait for somebody to reopen it.
    ///
    /// Only if no probe was asked for since the one that failed, given as
    /// its `generation`: that one has the next recheck. Every failed probe
    /// asks for one, so a probe asked for in between -- Tailscale going on
    /// or off, say -- started a second round of rechecks beside the first,
    /// and each change added another to the connections the agent saw for
    /// as long as the window was up. The failed probe's own generation, not
    /// the latest when this is asked: the refresh before it can ask for a
    /// probe, which was then rechecked when the failed one's five seconds
    /// were up rather than its own.
    private func recheckLater(_ address: String, generation: Int) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self, self.probeGeneration == generation,
                  self.isOpen, self.state.address == address,
                  self.state.isReachable != true, !self.searchingRoutes else { return }
            self.scheduleProbe()
        }
    }

    // MARK: - Actions

    /// A row was committed, or an address typed into the list's last row.
    private func hostPicked(_ address: String) {
        let typed = address.trimmingCharacters(in: .whitespacesAndNewlines)
        hostChosenHere = true
        guard typed != state.address else {
            // The same PC picked again: ask it again, rather than leave a
            // route search this choice overrides to drop its own recheck.
            if state.isReachable != true { scheduleProbe() }
            return
        }
        state.address = typed
        state.name = discovered.first { $0.connectTarget == typed }?.name
        state.isReachable = nil
        state.isRefused = false
        state.addressProblem = nil
        wokeAt = nil
        wakeFailed = false
        state.latency = nil
        refresh()
        scheduleProbe()
    }

    @objc private func connectTapped() {
        let host = state.address.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else {
            hintLabel.stringValue = ConnectHint.enterAddress
            hintLabel.toolTip = hintLabel.stringValue
            hintLabel.textColor = DS.danger
            MainActor.assumeIsolated { hintVoice.reset(); _ = hintVoice.say(ConnectHint.enterAddress, priority: .high) }
            return
        }
        // Not a name that was found to lead nowhere: a typo would push a good
        // host out of the five kept. A PC that is merely slow to answer its
        // probe -- through a relay, or still waking -- is kept.
        if state.addressProblem == nil { remember(host: host) }
        close()
        onConnect(host)
    }

    /// Whether to offer the Local Network settings: the search is denied,
    /// nothing has been found, and the PC on show is not one reached another
    /// way -- answering, or by Tailscale, which needs no local network. From
    /// the state, not from the hint, which changes with each probe while the
    /// denial does not.
    static func offersLocalNetworkSettings(denied: Bool, discovered: Int, address: String,
                                           reachable: Bool?) -> Bool {
        denied && discovered == 0 && reachable != true
            && (address.isEmpty || !StreamSettings.isRemote(host: address))
    }

    @objc private func tailscaleTapped() {
        if showsLocalNetworkLink {
            NSWorkspace.shared.open(ConnectHint.localNetworkSettings)
            return
        }
        tailscale.act()
    }

    /// Escape here is the way out of SolStream, as Escape in the app picker is
    /// the way back to here. This window is only up when nothing is streaming,
    /// so it never ends a stream.
    ///
    /// Not the Quit button's key equivalent. Escape held down to leave the
    /// picker -- or to close the PC list or Settings -- brings this window
    /// forward, and the key's next repeat would then quit. So only a fresh
    /// press counts, only in this window (an open PC list is a window of its
    /// own and closes itself), and only once this window has been in front a
    /// moment.
    private func installEscapeToQuit() {
        guard escapeMonitor == nil else { return }
        escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            // Plain Escape only, as the Quit button's key equivalent was:
            // Command, Control or Option with it is somebody else's shortcut.
            guard let self, event.keyCode == 53, event.window === self.window,
                  self.window.attachedSheet == nil,
                  event.modifierFlags.intersection([.command, .control, .option]).isEmpty
            else { return event }
            guard !event.isARepeat, Date().timeIntervalSince(self.becameKeyAt) > 0.5 else {
                return nil
            }
            self.quitTapped()
            return nil
        }
    }

    private func removeEscapeToQuit() {
        if let escapeMonitor { NSEvent.removeMonitor(escapeMonitor) }
        escapeMonitor = nil
    }

    /// Whether this Mac has learned how to wake the PC shown.
    private var canWake: Bool {
        !state.address.isEmpty && !WakeOnLAN.targets(for: state.address, in: defaults).isEmpty
    }

    /// What the hint says about a PC that is not answering.
    private func offlineHint() -> String {
        // Said as what is likely, not as fact: the address may be another
        // machine's on this network, and Windows' firewall drops a knock on
        // a port nothing listens on more often than it refuses one -- so a
        // PC waiting at the sign-in screen usually looks the same as one
        // asleep.
        if state.addressProblem == .unknownName {
            return ConnectHint.unknownName(state.address)
        }
        if state.addressProblem == .ipv6Only { return ConnectHint.ipv6Only }
        if state.isRefused { return ConnectHint.refused }
        if wakeFailed { return ConnectHint.wakeFailed }
        if let wokeAt {
            return Date().timeIntervalSince(wokeAt) < Self.wakeWait
                ? ConnectHint.waking : ConnectHint.stillNotAnswering
        }
        return canWake ? ConnectHint.asleep : ConnectHint.notAnswering
    }

    /// How long a PC is given to wake before the hint says it has not.
    static let wakeWait: TimeInterval = 60

    @objc private func wakeTapped() {
        let targets = WakeOnLAN.targets(for: state.address, in: defaults)
        wakeFailed = !WakeOnLAN.wake(targets)
        wokeAt = wakeFailed ? nil : Date()
        refresh()
        // The window rechecks a silent PC every few seconds already; this
        // only brings the hint round when the wait is up -- on the window
        // still up, not one Connect has put away.
        let woke = wokeAt
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.wakeWait + 0.5) { [weak self] in
            guard let self, self.window.isVisible, self.wokeAt == woke else { return }
            self.refresh()
        }
    }

    @objc private func settingsTapped() {
        NotificationCenter.default.post(name: StreamSettings.openSettingsRequest, object: nil)
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
        becameKeyAt = Date()
        tailscaleCheckedAt = nil
        refresh()
    }

    /// Tailscale coming up or going down is a tunnel coming or going, which
    /// changes this Mac's network -- and nothing else tells this window.
    /// Switched from its menu-bar item, Tailscale leaves the window key, and
    /// a tunnel that drops by itself touches nothing at all. A PC that had
    /// answered through it stayed "Reachable and paired" until Connect
    /// failed.
    ///
    /// Watched on a queue of its own, and answered on the main thread
    /// (`pathChanged`).
    private func watchNetwork() {
        guard pathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        monitor.pathUpdateHandler = { [weak self, weak monitor] _ in
            DispatchQueue.main.async {
                guard let monitor else { return }
                self?.pathChanged(from: monitor)
            }
        }
        monitor.start(queue: DispatchQueue(label: "SolStream.connect.network"))
        pathMonitor = monitor
    }

    private func stopWatchingNetwork() {
        pathMonitor?.cancel()
        pathMonitor = nil
    }

    /// A change `monitor` saw, taken only while it is still the window's.
    /// Cancelling it does not take back a change already on its way to the
    /// main thread, which would refresh the window after it closed and
    /// could probe the PC.
    func pathChanged(from monitor: NWPathMonitor) {
        guard pathMonitor === monitor else { return }
        networkChanged()
    }

    /// The network changed: Tailscale is read again now, not once the last
    /// reading is a few seconds old, and the window says what that changes.
    func networkChanged() {
        tailscaleCheckedAt = nil
        refresh()
    }

    func windowWillClose(_ notification: Notification) {
        tearDown()
        if NSApp.windows.allSatisfy({ !$0.isVisible || $0 === window }) {
            NSApp.terminate(nil)
        }
    }

    /// Whether this Mac is paired with a PC found on the network: a token for
    /// its address, or for the PC by that name at another -- its router gave
    /// it a new address, or it answers on Ethernet and Wi-Fi both. Proved
    /// when connecting, never taken on the name's word.
    static func isPaired(_ host: DiscoveredHost) -> Bool {
        AgentConnection.hasStoredToken(for: host.connectTarget,
                                       named: HostBrowser.baseName(of: host.name) ?? host.name)
    }

    /// Forget Pairing on a row: asked over this window, then done for that PC
    /// alone -- every address it was paired at under its name -- and its
    /// Dock launchers too when ticked, as Forget Paired PCs offers.
    private func askToForgetPairing(_ item: HostDropdown.Item) {
        let name = item.name.map { HostBrowser.baseName(of: $0) ?? $0 }
        let hosts = PairingForget.hosts(address: item.address, name: name)
        let alert = NSAlert()
        alert.messageText = Self.forgetPairingQuestion(name ?? item.address)
        alert.informativeText = Self.forgetPairingDetail
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        let launchers = PairingForget.launcherCount(for: hosts)
        let removeLaunchers = NSButton(
            checkboxWithTitle: launchers == 1 ? "Also remove its Dock launcher"
                                              : "Also remove its \(launchers) Dock launchers",
            target: nil, action: nil)
        if launchers > 0 { alert.accessoryView = removeLaunchers }
        alert.beginSheetModal(for: window) { [weak self] response in
            guard response == .alertFirstButtonReturn else { return }
            PairingForget.forget(hosts: hosts, removingLaunchers: removeLaunchers.state == .on)
            self?.refresh()
        }
    }

    static func forgetPairingQuestion(_ pc: String) -> String {
        "Forget the pairing with \(pc)?"
    }

    static let forgetPairingDetail = """
        SolStream will forget this PC's pairing token. To connect again, enter \
        the token shown on SolStream's own window on that PC, under "Pairing \
        token". Other PCs stay paired.
        """

    /// Rows for the list: what is on the network now, then what was used before.
    /// Two kinds, so exactly one divider falls between them.
    private func hostItems() -> [HostDropdown.Item] {
        var items = discovered.map { host in
            HostDropdown.Item(address: host.connectTarget, name: host.name,
                              detail: [.data(host.connectTarget),
                                       .words(Self.isPaired(host) ? "Paired" : "Not paired")],
                              dotState: .live, kind: .discovered, paired: Self.isPaired(host))
        }
        items += HostBrowser.recentsWorthShowing(recentHosts,
                                                 discovered: discovered).map { address in
            let paired = AgentConnection.hasStoredToken(for: address)
            return HostDropdown.Item(address: address, name: nil,
                                     detail: [.words("Used before"),
                                              .words(paired ? "Paired" : "Not paired")],
                                     dotState: .idle, kind: .recent, paired: paired)
        }
        return items
    }

    // MARK: - Recents

    /// Forget the hosts used before and the last one, as Forget Paired PCs
    /// does: kept, a PC just forgotten stayed listed as used before, and the
    /// window opened on it.
    static func forgetRecents(in defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: recentHostsKey)
        defaults.removeObject(forKey: lastHostKey)
    }

    /// Take one address off the hosts used before -- a mistyped one, or a
    /// PC's old address -- and off "last used" if it is that. Its pairing
    /// token stays: Forget Paired PCs is for that. An address forgotten is
    /// also no longer tried as another route to a paired PC whose usual one
    /// fails (`preferAnotherRoute`), which only looks among these.
    static func forget(host: String, in defaults: UserDefaults = .standard) {
        let kept = recentHosts(in: defaults).filter { !TokenStore.sameHost($0, host) }
        defaults.set(kept, forKey: recentHostsKey)
        if let last = lastHost(in: defaults), TokenStore.sameHost(last, host) {
            defaults.removeObject(forKey: lastHostKey)
        }
    }

    /// What was typed, as an address to dial: brackets round an IPv6 address
    /// taken off, and a port taken off another -- the PC's port is fixed, and
    /// "192.168.1.5:47630" otherwise went to the name lookup whole and failed.
    static func dialable(_ typed: String) -> String {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("["), let close = text.firstIndex(of: "]") {
            return String(text[text.index(after: text.startIndex)..<close])
        }
        let colons = text.filter { $0 == ":" }.count
        if colons == 1, let colon = text.firstIndex(of: ":"),
           text[text.index(after: colon)...].allSatisfy({ $0.isASCII && $0.isNumber }) {
            return String(text[..<colon])
        }
        return text
    }

    private static func lastHost(in defaults: UserDefaults) -> String? {
        defaults.string(forKey: lastHostKey)
    }

    private static func recentHosts(in defaults: UserDefaults) -> [String] {
        // No default. This used to seed one developer's Tailscale address into
        // every install's recents list, where it showed up as a host the user
        // had supposedly connected to before.
        defaults.stringArray(forKey: recentHostsKey) ?? []
    }

    private var recentHosts: [String] { Self.recentHosts(in: defaults) }

    private func remember(host: String) {
        let hosts = [host] + recentHosts.filter { !TokenStore.sameHost($0, host) }
        defaults.set(Self.kept(hosts, limit: 5), forKey: Self.recentHostsKey)
        defaults.set(host, forKey: Self.lastHostKey)
    }

    /// The most recent `limit` of `hosts` -- but never at the cost of a
    /// Tailscale address while a home-network one could go instead. Every
    /// probe that answers is remembered, so a few DHCP renewals at home used to
    /// push out the one address that reaches the PC from anywhere, and with it
    /// the route the window finds by itself away from home.
    static func kept(_ hosts: [String], limit: Int) -> [String] {
        var kept = Array(hosts.prefix(limit))
        for dropped in hosts.dropFirst(limit) where StreamSettings.isRemote(host: dropped) {
            guard let local = kept.lastIndex(where: { !StreamSettings.isRemote(host: $0) }),
                  local > 0 else { break }
            kept.remove(at: local)
            kept.append(dropped)
        }
        return kept
    }
}

/// What the connect window's hint says. Each has two lines of the window's
/// width at most -- the label is held at two lines so the window does not jump
/// as a probe comes back -- and the ones that said how to get past a problem
/// were the ones cut off in the middle: ConnectHintTests measures them all.
enum ConnectHint {
    static let pairingNeeded = "Pairing needed — SolStream on the PC shows a token to type in."
    static let paired = "Reachable and paired. Connecting is one step."
    static func found(_ names: String) -> String { "Found \(names) on this network." }
    static let cannotSearch = "Can't search the network. Check this Mac is online and SolStream "
        + "has Local Network access, or type the PC's address."
    /// Where Local Network access is given, and the link that opens it.
    static let localNetworkSettings = URL(
        string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")!
    static let localNetworkAction = "Open Local Network Settings"
    static let firstConnection = "The first connection asks for the token shown on the PC."
    static let tailscaleOff = "That's a Tailscale address, and Tailscale is off on this Mac."
    static let maybeTailscale = "If that's a Tailscale address, turn Tailscale on on this Mac."
    static func unknownName(_ address: String) -> String {
        "Couldn't find \(address). Check the spelling and that this Mac is online, "
            + "or use the PC's address."
    }
    static let ipv6Only = "SolStream on the PC listens on IPv4 only. Use its IPv4 address, "
        + "or its Tailscale one starting 100."
    static let refused = "Something is at this address, but SolStream isn't answering. "
        + "If it's your PC, sign in to Windows or open SolStream."
    static let wakeFailed = "Couldn't send the wake signal from this Mac. Check it's on a network."
    static let waking = "Waking the PC… This can take up to a minute."
    static let stillNotAnswering = "Still not answering. If the PC is awake, sign in to Windows; "
        + "if not, Wake-on-LAN may be off, or it's on another network."
    static let asleep = "Not answering. The PC may be asleep, or nobody is signed in to Windows."
    static let notAnswering = "Not answering. Check the PC is awake and signed in, "
        + "and SolStream is running there."
    static let enterAddress = "Enter a hostname or IP address."

    /// Every hint, with `address` and `names` where they go in.
    static func all(address: String, names: String) -> [String] {
        [pairingNeeded, paired, found(names), cannotSearch, firstConnection, tailscaleOff,
         maybeTailscale, unknownName(address), ipv6Only, refused, wakeFailed, waking,
         stillNotAnswering, asleep, notAnswering, enterAddress]
    }

    /// How wide the hint is: the window less its margins.
    static var width: CGFloat { ConnectWindow.contentWidth - DS.Metric.inset * 2 }
}
