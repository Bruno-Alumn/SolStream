import AppKit
import DesignSystem
import InputCapture
import SolStreamLogging

/// Settings: everything about a stream that is the person's choice rather than
/// the network's.
///
/// One window for the life of the app, owned by the app delegate. Closing it
/// only orders it out, so reopening it -- from the menu, ⌘, or the popover on a
/// streamed window -- brings the same window forward rather than stacking a
/// second one. There is no Apply button: each control writes `StreamSettings`
/// as it moves, and the app delegate decides what that means for a stream that
/// is running.
final class SettingsWindow: NSObject {
    let window: NSWindow
    let pane = SettingsPane()
    private var hasBeenShown = false

    override init() {
        let size = pane.fittingSize
        // Not resizable: every row is laid out to a fixed width, and there is
        // nothing a larger window would show more of.
        window = SettingsPanelWindow(contentRect: NSRect(origin: .zero, size: size),
                                     styleMask: [.titled, .closable, .fullSizeContentView],
                                     backing: .buffered, defer: true)
        super.init()
        // Titled for the Window menu and Mission Control; the heading inside
        // says it on the page, the way the connect window does, with the
        // content running under a transparent title bar.
        window.title = "Settings"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = DS.ground
        window.isMovableByWindowBackground = true
        // Over whichever Space is in front, a full-screen stream's included.
        // An ordinary window cannot join a full-screen Space, so opening
        // Settings from the popover of a game played full screen would take
        // the person out of the game to show it.
        window.collectionBehavior = [.fullScreenAuxiliary, .moveToActiveSpace]
        window.contentView = pane
        window.setContentSize(size)
    }

    func show() {
        // Read again rather than trusted: the observers keep it current, but a
        // window that has been closed for an hour should not depend on that.
        pane.refresh()
        if !hasBeenShown {
            window.center()
            hasBeenShown = true
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Escape and ⌘W close it, as they close any Mac settings window. ⌘W has to be
/// caught here because the Window menu's Close is on ⌃⌘W -- bare ⌘ belongs to
/// the streamed application -- and nothing is streamed in this one.
private final class SettingsPanelWindow: NSWindow {
    override func cancelOperation(_ sender: Any?) {
        performClose(sender)
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Only the keys a shortcut is made of: Caps Lock, fn and the numeric
        // pad ride along in the flags without making it a different one.
        let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
        if modifiers == .command, Self.isW(event) {
            performClose(nil)
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    /// W on any layout: the letter where the layout types Latin ones, and
    /// otherwise the key W sits on in a US layout (kVK_ANSI_W), as menu
    /// shortcuts are matched on a Cyrillic or Greek layout.
    private static func isW(_ event: NSEvent) -> Bool {
        guard let key = event.charactersIgnoringModifiers?.lowercased(), !key.isEmpty else {
            return false
        }
        if key.unicodeScalars.allSatisfy(\.isASCII) { return key == "w" }
        return event.keyCode == 13
    }
}

/// The window's content, built on its own so that tests can lay it out and
/// photograph it without a window ever reaching the screen.
///
/// Two columns of cards: what you see and hear on the left, what your hands do
/// and the clipboard on the right. In one column the same rows stand some 850
/// points tall, more than a 13-inch MacBook shows under its menu bar.
final class SettingsPane: NSView {
    static let columnWidth: CGFloat = 344
    /// Two columns, the gutter between them and the window's inset either side.
    static var width: CGFloat { DS.Metric.inset * 2 + columnWidth * 2 + DS.Space.x6 }
    /// The width of everything inside a card.
    static var innerWidth: CGFloat { columnWidth - DS.Metric.cardInset * 2 }
    /// Both pop-ups the same width, so they line up down the column.
    private static let popUpWidth: CGFloat = 148
    private static let sliderValueWidth: CGFloat = 52

    private let settings = StreamSettings.shared

    // Video
    let qualityPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let qualityDetail = SettingsPane.caption("")
    let frameRateControl = SolarSegments(labels: StreamSettings.frameRates.map { "\($0) fps" },
                                         accessibilityLabel: "Frame rate")
    // Sound
    let soundSwitch = SolarSwitch(label: "Play the PC's sound")
    let muteButton = NSButton(image: NSImage(), target: nil, action: nil)
    let volumeSlider = NSSlider(value: 100, minValue: 0, maxValue: 100, target: nil, action: nil)
    let volumeValue = DS.label("", font: DS.mono, colour: DS.textSecondary)
    let bufferingPopUp = NSPopUpButton(frame: .zero, pullsDown: false)
    let bufferingDetail = SettingsPane.caption("")
    // Mouse
    let modeControl = SolarSegments(labels: ["Desktop", "Gaming"], accessibilityLabel: "Mouse mode")
    let modeDetail = SettingsPane.caption("")
    let sensitivitySlider = NSSlider(value: 0, minValue: -2, maxValue: 2, target: nil, action: nil)
    let sensitivityValue = DS.label("", font: DS.mono, colour: DS.textSecondary)
    let followsCursorSwitch = SolarSwitch(label: "Give the mouse back when the game shows its cursor")
    // General
    let clipboardSwitch = SolarSwitch(label: "Sync the clipboard")
    let footnote = SettingsPane.caption(
        "Quality, frame rate and the PC's sound apply by restarting the picture for a moment.")

    /// The words on the rows that only mean something with sound on, and with
    /// the mouse in gaming mode. Dimmed with their controls when they do not.
    private var soundDependentLabels: [Words] = []
    private var gamingDependentLabels: [Words] = []

    /// Set while this pane is the one writing, so its own change does not come
    /// back through `didChange` and set the control under the pointer again.
    private var isWriting = false
    private var observers: [NSObjectProtocol] = []

    init() {
        super.init(frame: .zero)
        build()
        refresh()

        // The popover on a streamed window changes the same settings, and the
        // mouse mode has a setter of its own in InputCapture; both are heard.
        let center = NotificationCenter.default
        for name in [StreamSettings.didChange, InputCapture.pointerModeChanged] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) {
                [weak self] _ in
                guard let self, !self.isWriting else { return }
                self.refresh()
            })
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    // MARK: - Reading

    /// Every control from the settings as they are now.
    func refresh() {
        let quality = settings.videoQuality
        qualityPopUp.selectItem(at: StreamSettings.VideoQuality.allCases.firstIndex(of: quality) ?? 0)
        qualityDetail.stringValue = quality.detail
        frameRateControl.selectedSegment = StreamSettings.frameRates.firstIndex(of: settings.frameRate)
            ?? StreamSettings.frameRates.count - 1

        let streamsAudio = settings.streamsAudio
        soundSwitch.isOn = streamsAudio
        let buffering = settings.audioBuffering
        bufferingPopUp.selectItem(at: StreamSettings.AudioBufferingChoice.allCases.firstIndex(of: buffering) ?? 0)
        bufferingDetail.stringValue = buffering.detail
        for control in [muteButton, volumeSlider, bufferingPopUp] as [NSControl] {
            control.isEnabled = streamsAudio
        }
        // After the enabling, which decides whether the speaker keeps its amber.
        showVolume(movingSlider: true)
        Self.dim(soundDependentLabels, !streamsAudio)

        let mode = settings.pointerMode
        let gaming = mode == .gaming
        modeControl.selectedSegment = gaming ? 1 : 0
        modeDetail.stringValue = Self.modeDetail(mode)
        sensitivitySlider.doubleValue = Self.sliderPosition(forSensitivity: settings.gamingSensitivity)
        showSensitivity(settings.gamingSensitivity)
        followsCursorSwitch.isOn = settings.followsHostCursor
        sensitivitySlider.isEnabled = gaming
        followsCursorSwitch.isEnabled = gaming
        Self.dim(gamingDependentLabels, !gaming)

        clipboardSwitch.isOn = settings.syncsClipboard
    }

    /// The speaker, the slider and the figure beside it.
    ///
    /// The same rule as the popover's: the amber goes to whichever part is in
    /// charge -- the slider's fill while sound plays at that level, the slashed
    /// speaker while muted, which is the one state here you can forget you
    /// chose -- and to neither while the row does not apply, where AppKit's
    /// fading would turn it brown; the slash still says muted. `movingSlider`
    /// is false while the slider itself is being dragged, so a value rounded
    /// through `Float` is not written back under the hand.
    private func showVolume(movingSlider: Bool) {
        let muted = settings.isMuted
        let volume = settings.volume
        let applies = volumeSlider.isEnabled
        muteButton.image = muted
            ? NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
            : NSImage(systemSymbolName: "speaker.wave.3.fill", variableValue: Double(volume),
                      accessibilityDescription: nil)
        muteButton.contentTintColor = muted && applies ? DS.accentInk : DS.textSecondary
        muteButton.setAccessibilityLabel(muted ? "Unmute" : "Mute")
        if movingSlider { volumeSlider.doubleValue = Double(volume) * 100 }
        volumeSlider.trackFillColor = muted || !applies ? DS.textFaint : DS.accent
        volumeSlider.needsDisplay = true
        let percent = "\(Int((volume * 100).rounded()))%"
        // A word, so in the body face: mono is for the figure it replaces.
        volumeValue.stringValue = muted ? "Muted" : percent
        volumeValue.font = muted ? DS.body : DS.mono
        volumeSlider.setAccessibilityValueDescription(muted ? "Muted, \(percent)" : percent)
    }

    /// The figure beside the sensitivity slider, and what VoiceOver says for
    /// it: the slider runs over the logarithm, and "minus 1" means nothing.
    private func showSensitivity(_ sensitivity: Double) {
        let text = Self.format(sensitivity: sensitivity)
        sensitivityValue.stringValue = text
        sensitivitySlider.setAccessibilityValueDescription(text)
    }

    // MARK: - Writing

    private func write(_ change: () -> Void) {
        isWriting = true
        change()
        isWriting = false
    }

    @objc private func qualityChosen(_ sender: NSPopUpButton) {
        let all = StreamSettings.VideoQuality.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        let quality = all[sender.indexOfSelectedItem]
        qualityDetail.stringValue = quality.detail
        // Choosing the one already chosen must not restart the picture.
        guard quality != settings.videoQuality else { return }
        Log.info("[settings] video quality: \(quality.title)")
        write { settings.videoQuality = quality }
    }

    @objc private func frameRateChosen(_ sender: SolarSegments) {
        guard StreamSettings.frameRates.indices.contains(sender.selectedSegment) else { return }
        let rate = StreamSettings.frameRates[sender.selectedSegment]
        guard rate != settings.frameRate else { return }
        Log.info("[settings] frame rate: \(rate)")
        write { settings.frameRate = rate }
    }

    @objc private func soundToggled(_ sender: SolarSwitch) {
        guard sender.isOn != settings.streamsAudio else { return }
        Log.info("[settings] the PC's sound: \(sender.isOn ? "on" : "off")")
        write { settings.streamsAudio = sender.isOn }
        refresh()
    }

    @objc private func volumeMoved(_ sender: NSSlider) {
        write {
            settings.volume = Float(sender.doubleValue / 100)
            // Reaching for the volume means wanting to hear it; a slider that
            // moved while nothing changed would look broken.
            if settings.isMuted { settings.isMuted = false }
        }
        showVolume(movingSlider: false)
        if NSApp.currentEvent?.type == .leftMouseUp {
            Log.info("[settings] volume: \(Int((settings.volume * 100).rounded()))%")
        }
    }

    @objc private func muteToggled(_ sender: NSButton) {
        write {
            settings.isMuted.toggle()
            // Unmuting into a volume of zero would change nothing you can hear
            // and look as if the button had not worked, so it brings back half.
            if !settings.isMuted, settings.volume == 0 { settings.volume = 0.5 }
        }
        Log.info("[settings] sound \(settings.isMuted ? "muted" : "unmuted")")
        showVolume(movingSlider: true)
    }

    @objc private func bufferingChosen(_ sender: NSPopUpButton) {
        let all = StreamSettings.AudioBufferingChoice.allCases
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        let buffering = all[sender.indexOfSelectedItem]
        bufferingDetail.stringValue = buffering.detail
        guard buffering != settings.audioBuffering else { return }
        Log.info("[settings] audio buffering: \(buffering.title)")
        write { settings.audioBuffering = buffering }
    }

    @objc private func modeChosen(_ sender: SolarSegments) {
        let mode: InputCapture.PointerMode = sender.selectedSegment == 1 ? .gaming : .desktop
        guard mode != settings.pointerMode else { return }
        // InputCapture logs the change itself.
        write { settings.pointerMode = mode }
        refresh()
    }

    @objc private func sensitivityMoved(_ sender: NSSlider) {
        let sensitivity = Self.sensitivity(forSliderPosition: sender.doubleValue)
        // The detent: inside it the knob sits on 1x rather than a hair beside
        // it, which a logarithmic slider otherwise makes nearly impossible.
        if sensitivity == 1 { sender.doubleValue = 0 }
        showSensitivity(sensitivity)
        if sensitivity != settings.gamingSensitivity {
            write { settings.gamingSensitivity = sensitivity }
        }
        if NSApp.currentEvent?.type == .leftMouseUp {
            Log.info("[settings] gaming sensitivity: \(Self.format(sensitivity: sensitivity))")
        }
    }

    @objc private func followsCursorToggled(_ sender: SolarSwitch) {
        guard sender.isOn != settings.followsHostCursor else { return }
        Log.info("[settings] give the mouse back at the game's cursor: \(sender.isOn ? "on" : "off")")
        write { settings.followsHostCursor = sender.isOn }
        modeDetail.stringValue = Self.modeDetail(settings.pointerMode)
    }

    @objc private func clipboardToggled(_ sender: SolarSwitch) {
        guard sender.isOn != settings.syncsClipboard else { return }
        Log.info("[settings] clipboard sync: \(sender.isOn ? "on" : "off")")
        write { settings.syncsClipboard = sender.isOn }
    }

    // MARK: - Values

    /// Sensitivity runs 0.25x to 4x, and the slider runs over its logarithm, so
    /// that 1x -- the Mac's own feel -- is in the middle and halving it is as
    /// far as doubling it. Linear, 1x sat a fifth of the way along and the
    /// whole slow half was squeezed into the first twentieth of the track.
    static func sliderPosition(forSensitivity sensitivity: Double) -> Double {
        log2(min(max(sensitivity, 0.25), 4))
    }

    /// The inverse, in twentieths, with a detent at 1x.
    static func sensitivity(forSliderPosition position: Double) -> Double {
        if abs(position) < 0.08 { return 1 }
        let raw = pow(2, min(max(position, -2), 2))
        return min(max((raw * 20).rounded() / 20, 0.25), 4)
    }

    static func format(sensitivity: Double) -> String {
        String(format: "%.2f×", sensitivity)
    }

    static func modeDetail(_ mode: InputCapture.PointerMode,
                           followsCursor: Bool = InputCapture.followsHostCursor) -> String {
        switch mode {
        case .desktop:
            return "The PC's pointer goes exactly where yours is. Best for ordinary apps."
        case .gaming where followsCursor:
            return "The game has the mouse while it hides its pointer, and gives it back in its menus or on ⌃⌥."
        case .gaming:
            return "Click in the window to capture the mouse for games. ⌃⌥ releases it."
        }
    }

    // MARK: - Building

    private func build() {
        // ── Video ────────────────────────────────────────────────────────────
        for quality in StreamSettings.VideoQuality.allCases {
            qualityPopUp.addItem(withTitle: quality.title)
        }
        Self.configure(popUp: qualityPopUp, label: "Video quality")
        qualityPopUp.target = self
        qualityPopUp.action = #selector(qualityChosen(_:))
        Self.reserveHeight(qualityDetail, for: StreamSettings.VideoQuality.allCases.map(\.detail))

        frameRateControl.target = self
        frameRateControl.action = #selector(frameRateChosen(_:))

        let video = section("Video", rows: [
            row("Quality", trailing: qualityPopUp, below: [qualityDetail]),
            row("Frame rate", trailing: frameRateControl, below: [
                Self.caption("60 is smoother. 30 can look sharper on a slow network, and is easier on the PC."),
            ]),
        ])

        // ── Sound ────────────────────────────────────────────────────────────
        soundSwitch.target = self
        soundSwitch.action = #selector(soundToggled(_:))

        muteButton.target = self
        muteButton.action = #selector(muteToggled(_:))
        muteButton.isBordered = false
        muteButton.imagePosition = .imageOnly
        muteButton.imageScaling = .scaleNone
        muteButton.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        // Fixed, so the slider beside it does not shift as the icon changes
        // between the slashed speaker and one with three waves.
        muteButton.widthAnchor.constraint(equalToConstant: 22).isActive = true
        muteButton.setContentHuggingPriority(.required, for: .horizontal)

        volumeSlider.target = self
        volumeSlider.action = #selector(volumeMoved(_:))
        volumeSlider.isContinuous = true
        volumeSlider.setAccessibilityLabel("Volume")
        volumeSlider.setContentHuggingPriority(.defaultLow, for: .horizontal)
        volumeValue.alignment = .right
        volumeValue.widthAnchor.constraint(equalToConstant: Self.sliderValueWidth).isActive = true
        let volumeLine = Self.line([muteButton, volumeSlider], spacing: DS.Space.x2)

        for choice in StreamSettings.AudioBufferingChoice.allCases {
            bufferingPopUp.addItem(withTitle: choice.title)
        }
        Self.configure(popUp: bufferingPopUp, label: "Sound buffering")
        bufferingPopUp.target = self
        bufferingPopUp.action = #selector(bufferingChosen(_:))
        Self.reserveHeight(bufferingDetail,
                           for: StreamSettings.AudioBufferingChoice.allCases.map(\.detail))

        let volumeRow = row("Volume", trailing: volumeValue, below: [volumeLine])
        let bufferingRow = row("Buffering", trailing: bufferingPopUp, below: [bufferingDetail])
        soundDependentLabels = volumeRow.labels + bufferingRow.labels
            + [Words(label: volumeValue, colour: DS.textSecondary)]
        let sound = section("Sound", rows: [
            row("Play the PC's sound", trailing: soundSwitch, below: [
                Self.caption("Off saves about 1.5 Mbps when you don't need it."),
            ]),
            volumeRow,
            bufferingRow,
        ])

        // ── Mouse ────────────────────────────────────────────────────────────
        modeControl.target = self
        modeControl.action = #selector(modeChosen(_:))
        Self.reserveHeight(modeDetail, for: [Self.modeDetail(.desktop),
                                             Self.modeDetail(.gaming, followsCursor: true),
                                             Self.modeDetail(.gaming, followsCursor: false)])

        sensitivitySlider.target = self
        sensitivitySlider.action = #selector(sensitivityMoved(_:))
        sensitivitySlider.isContinuous = true
        // 0.25x, 0.5x, 1x, 2x, 4x: on a logarithmic track, evenly spaced.
        sensitivitySlider.numberOfTickMarks = 5
        sensitivitySlider.tickMarkPosition = .below
        sensitivitySlider.allowsTickMarkValuesOnly = false
        sensitivitySlider.trackFillColor = DS.accent
        sensitivitySlider.setAccessibilityLabel("Gaming sensitivity")
        sensitivityValue.alignment = .right
        sensitivityValue.widthAnchor.constraint(equalToConstant: Self.sliderValueWidth).isActive = true

        followsCursorSwitch.target = self
        followsCursorSwitch.action = #selector(followsCursorToggled(_:))

        let sensitivityRow = row("Gaming sensitivity", trailing: sensitivityValue, below: [
            sensitivitySlider,
            Self.caption("How far the PC's pointer moves for yours while the mouse is captured."),
        ])
        let followsRow = row("Give the mouse back when the game shows its cursor",
                             trailing: followsCursorSwitch, below: [
            Self.caption("A pause menu or an inventory gets your pointer back without ⌃⌥, once "
                         + "SolStream on the PC is up to date. Turn it off if a game keeps a "
                         + "pointer on screen while you play."),
        ])
        gamingDependentLabels = sensitivityRow.labels + followsRow.labels
            + [Words(label: sensitivityValue, colour: DS.textSecondary)]
        let mouse = section("Mouse", rows: [
            row("Mode", trailing: modeControl, below: [modeDetail]),
            sensitivityRow,
            followsRow,
        ])

        // ── General ──────────────────────────────────────────────────────────
        clipboardSwitch.target = self
        clipboardSwitch.action = #selector(clipboardToggled(_:))
        let general = section("General", rows: [
            row("Sync the clipboard", trailing: clipboardSwitch, below: [
                Self.caption("Copy on one, paste on the other while a stream is open. "
                             + "Anything a password manager marks private stays on the Mac."),
            ]),
        ])

        // ── The page ─────────────────────────────────────────────────────────
        let heading = DS.label("Settings", font: DS.title)
        let subheading = DS.label("Kept on this Mac, for every PC you stream from.",
                                  font: DS.body, colour: DS.textSecondary)

        let left = Self.column([video, sound])
        let right = Self.column([mouse, general])
        let columns = Self.line([left, right], spacing: DS.Space.x6)
        columns.alignment = .top

        // Said once, at the foot, rather than on each of the three rows: the
        // restart is brief, and three warnings would make it sound like more.
        let restartGlyph = NSImageView(image: NSImage(systemSymbolName: "arrow.clockwise",
                                                      accessibilityDescription: nil) ?? NSImage())
        restartGlyph.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        restartGlyph.contentTintColor = DS.textMuted
        restartGlyph.setContentHuggingPriority(.required, for: .horizontal)
        footnote.preferredMaxLayoutWidth = Self.columnWidth * 2
        let foot = Self.line([restartGlyph, footnote], spacing: DS.Space.x2)
        foot.alignment = .firstBaseline

        let page = NSStackView(views: [heading, subheading, columns, foot])
        page.orientation = .vertical
        page.alignment = .leading
        page.spacing = DS.Space.x6
        page.setCustomSpacing(DS.Space.x1, after: heading)
        page.setCustomSpacing(DS.Space.x5, after: columns)
        // The top inset clears the title bar the content runs under.
        let inset = DS.Metric.inset
        page.edgeInsets = NSEdgeInsets(top: DS.Metric.titleBar + DS.Space.x3, left: inset,
                                       bottom: inset, right: inset)
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page)
        NSLayoutConstraint.activate([
            // Said outright: a leading-aligned stack's trailing inset is only a
            // minimum, and measuring it left the right-hand column hard against
            // the window's edge.
            widthAnchor.constraint(equalToConstant: Self.width),
            page.leadingAnchor.constraint(equalTo: leadingAnchor),
            page.trailingAnchor.constraint(equalTo: trailingAnchor),
            page.topAnchor.constraint(equalTo: topAnchor),
            page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    /// A setting: its name and control on one line, then whatever explains or
    /// adjusts it underneath, at the card's full inner width.
    private struct Row {
        let view: NSView
        /// Its words, dimmed with its controls when the row does not apply.
        let labels: [Words]
    }

    /// A label and the colour it has when its row applies.
    private struct Words {
        let label: NSTextField
        let colour: NSColor
    }

    private func row(_ title: String, trailing: NSView, below: [NSView] = []) -> Row {
        // Wrapping, so the one long name -- giving the mouse back -- takes a
        // second line beside its switch rather than being cut off.
        let name = NSTextField(wrappingLabelWithString: title)
        name.font = DS.body
        name.textColor = DS.text
        name.isSelectable = false
        name.preferredMaxLayoutWidth = Self.innerWidth - trailing.fittingSize.width - DS.Space.x4
        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        trailing.setContentHuggingPriority(.required, for: .horizontal)
        let top = Self.line([name, spacer, trailing], spacing: DS.Space.x4)

        let stack = Self.vertical([top] + below, spacing: DS.Space.x2)
        // A caption straight under the name belongs to it, so it sits closer
        // than a slider does.
        if below.first is NSTextField { stack.setCustomSpacing(DS.Space.x1, after: top) }
        for (view, next) in zip(below, below.dropFirst()) where next is NSTextField {
            stack.setCustomSpacing(DS.Space.x1, after: view)
        }
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.x3, left: DS.Metric.cardInset,
                                        bottom: DS.Space.x3, right: DS.Metric.cardInset)
        for view in stack.arrangedSubviews {
            view.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
        }
        let words = ([name] + below.compactMap { $0 as? NSTextField }).map {
            Words(label: $0, colour: $0.textColor ?? DS.text)
        }
        return Row(view: stack, labels: words)
    }

    /// A heading over a card of rows, with an inset hairline between rows.
    private func section(_ title: String, rows: [Row]) -> NSView {
        let card = DS.card()
        let stack = Self.vertical([], spacing: 0)
        stack.alignment = .centerX
        for (index, row) in rows.enumerated() {
            if index > 0 {
                let rule = DS.hairlineView()
                stack.addArrangedSubview(rule)
                rule.widthAnchor.constraint(equalToConstant: Self.innerWidth).isActive = true
            }
            stack.addArrangedSubview(row.view)
        }
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)
        NSLayoutConstraint.activate([
            card.widthAnchor.constraint(equalToConstant: Self.columnWidth),
            stack.leadingAnchor.constraint(equalTo: card.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: card.trailingAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor),
        ])

        let header = DS.label(title, font: DS.headline)
        return Self.vertical([header, card], spacing: DS.Space.x2)
    }

    private static func column(_ sections: [NSView]) -> NSStackView {
        vertical(sections, spacing: DS.Space.x6)
    }

    /// A column that is exactly as tall as what it holds.
    ///
    /// NSStackView hugs its content at a low priority by default, and the
    /// row of two columns stretches the shorter one at another: which of the
    /// two won varied from one layout to the next, and when the stretch won it
    /// opened a gap of a line or so under whichever row took up the slack.
    private static func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.setHuggingPriority(.defaultHigh, for: .vertical)
        return stack
    }

    private static func line(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    /// Supporting text under a row: `caption` in `textMuted`, wrapping.
    private static func caption(_ text: String) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = DS.caption
        label.textColor = DS.textMuted
        label.isSelectable = false
        label.preferredMaxLayoutWidth = innerWidth
        return label
    }

    /// Tall enough for the longest thing a caption will ever say, so a choice
    /// whose explanation wraps does not grow the card -- and move every row
    /// below it -- under the pointer.
    private static func reserveHeight(_ label: NSTextField, for texts: [String]) {
        let original = label.stringValue
        let bounds = NSRect(x: 0, y: 0, width: innerWidth, height: 1_000)
        let tallest = texts.map { text -> CGFloat in
            label.stringValue = text
            return label.cell?.cellSize(forBounds: bounds).height ?? 0
        }.max() ?? 0
        label.stringValue = original
        label.heightAnchor.constraint(equalToConstant: ceil(tallest)).isActive = true
    }

    private static func configure(popUp: NSPopUpButton, label: String) {
        popUp.font = DS.body
        popUp.setAccessibilityLabel(label)
        popUp.widthAnchor.constraint(equalToConstant: popUpWidth).isActive = true
    }

    /// `textFaint` is for disabled labels and nothing else, which is what
    /// these are while their row does not apply.
    private static func dim(_ words: [Words], _ dimmed: Bool) {
        for word in words {
            word.label.textColor = dimmed ? DS.textFaint : word.colour
        }
    }
}

/// One choice of two or three, in Solar's colours: the chosen segment is the
/// primary button's `accent` with `onAccent` ink, in both themes, and the rest
/// sit on `raised`.
///
/// NSSegmentedControl takes its fill from `selectedSegmentBezelColor` but
/// picks the ink by itself -- dark on the dark theme's amber, white on the
/// light theme's, at about 2:1 -- and on macOS 26 a view AppKit hosts inside
/// it does the drawing, which a custom cell cannot reach. So the light theme's
/// one readable amber was a deeper one than every switch beside it. This is
/// drawn from the tokens instead, as `SolarSwitch` is, with the same disabled
/// rule: the chosen segment keeps `accentTint`, so it still says which.
final class SolarSegments: NSControl {
    /// The height of AppKit's regular controls, so it lines up with the
    /// pop-ups in the rows around it.
    static let height: CGFloat = 24
    private static let radius: CGFloat = 6
    /// A label on a fill reads thinner than the same weight on the ground,
    /// so the chosen one is a step heavier, as on the primary button.
    private static let chosenFont = NSFont.systemFont(ofSize: 13, weight: .medium)

    private let labels: [String]
    private var elements: [SegmentElement] = []

    var selectedSegment: Int {
        didSet {
            guard selectedSegment != oldValue else { return }
            needsDisplay = true
            NSAccessibility.post(element: self, notification: .valueChanged)
        }
    }

    /// The segment under a held button, drawn pressed while the pointer stays on it.
    private var pressed: Int? {
        didSet { if pressed != oldValue { needsDisplay = true } }
    }

    var segmentCount: Int { labels.count }

    func label(forSegment segment: Int) -> String? {
        labels.indices.contains(segment) ? labels[segment] : nil
    }

    init(labels: [String], accessibilityLabel: String) {
        self.labels = labels
        selectedSegment = 0
        super.init(frame: NSRect(x: 0, y: 0, width: 120, height: Self.height))
        translatesAutoresizingMaskIntoConstraints = false
        // Below required, so a caller that gives it a fixed width -- the
        // popover sizes its controls to one column -- gets the segments
        // spread evenly over it.
        setContentHuggingPriority(.defaultHigh, for: .horizontal)
        setContentHuggingPriority(.defaultHigh, for: .vertical)
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.radioGroup)
        setAccessibilityLabel(accessibilityLabel)
        elements = labels.indices.map { SegmentElement(owner: self, index: $0) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var isEnabled: Bool {
        didSet { needsDisplay = true }
    }

    /// Every segment as wide as the widest label needs, so a row of them
    /// reads as one evenly divided control whatever the words.
    override var intrinsicContentSize: NSSize {
        let widest = labels.map { ($0 as NSString).size(withAttributes: [.font: Self.chosenFont]).width }
            .max() ?? 0
        return NSSize(width: (ceil(widest) + DS.Space.x3 * 2) * CGFloat(max(labels.count, 1)),
                      height: Self.height)
    }

    func frame(ofSegment segment: Int) -> NSRect {
        let width = bounds.width / CGFloat(max(labels.count, 1))
        return NSRect(x: bounds.minX + width * CGFloat(segment), y: bounds.minY,
                      width: width, height: bounds.height)
    }

    private func segment(at point: NSPoint) -> Int? {
        guard bounds.contains(point) else { return nil }
        return labels.indices.first { frame(ofSegment: $0).contains(point) }
    }

    /// Choose `segment` as a click would, telling the target only when it
    /// changes the choice.
    @discardableResult
    func choose(_ segment: Int) -> Bool {
        guard isEnabled, labels.indices.contains(segment) else { return false }
        guard segment != selectedSegment else { return true }
        selectedSegment = segment
        sendAction(action, to: target)
        return true
    }

    // MARK: Mouse and keyboard

    // A press on it is a choice, not a request to move a window that is
    // movable by its background.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = segment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseDragged(with event: NSEvent) {
        guard isEnabled else { return }
        pressed = segment(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseUp(with event: NSEvent) {
        defer { pressed = nil }
        guard let pressed, segment(at: convert(event.locationInWindow, from: nil)) == pressed else {
            return
        }
        choose(pressed)
    }

    // Tab reaches it only with Full Keyboard Access on, as it does AppKit's
    // segmented control; the arrows then move the choice.
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
        switch event.specialKey {
        case .leftArrow? where isEnabled: choose(max(selectedSegment - 1, 0))
        case .rightArrow? where isEnabled: choose(min(selectedSegment + 1, labels.count - 1))
        default: super.keyDown(with: event)
        }
    }

    // MARK: Accessibility

    override func accessibilityChildren() -> [Any]? { elements }
    override func accessibilityValue() -> Any? { label(forSegment: selectedSegment) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: Self.radius - 0.5, yRadius: Self.radius - 0.5)
        DS.raised.setFill()
        track.fill()
        DS.hairline.setStroke()
        track.lineWidth = 1
        track.stroke()

        for index in labels.indices {
            let frame = frame(ofSegment: index)
            let chosen = index == selectedSegment
            if chosen || index == pressed {
                let fill: NSColor
                switch (chosen, isEnabled) {
                case (true, false): fill = DS.accentTint
                case (true, true): fill = index == pressed ? DS.accentPressed : DS.accent
                default: fill = DS.hairline
                }
                fill.setFill()
                NSBezierPath(roundedRect: frame, xRadius: Self.radius, yRadius: Self.radius).fill()
            }
            let ink = !isEnabled ? DS.textFaint : (chosen ? DS.onAccent : DS.text)
            let label = NSAttributedString(string: labels[index], attributes: [
                .font: chosen ? Self.chosenFont : DS.body,
                .foregroundColor: ink,
            ])
            let size = label.size()
            label.draw(at: NSPoint(x: frame.midX - size.width / 2,
                                   y: frame.midY - size.height / 2))
        }
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: Self.radius, yRadius: Self.radius).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}

/// One segment as VoiceOver and Voice Control see it: a radio button in the
/// group, pressable by name.
private final class SegmentElement: NSAccessibilityElement {
    private weak var owner: SolarSegments?
    private let index: Int

    init(owner: SolarSegments, index: Int) {
        self.owner = owner
        self.index = index
        super.init()
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel(owner.label(forSegment: index))
    }

    override func accessibilityParent() -> Any? { owner }
    override func accessibilityValue() -> Any? { NSNumber(value: owner?.selectedSegment == index) }
    override func isAccessibilityEnabled() -> Bool { owner?.isEnabled ?? false }

    override func accessibilityFrame() -> NSRect {
        guard let owner else { return .zero }
        return NSAccessibility.screenRect(fromView: owner, rect: owner.frame(ofSegment: index))
    }

    override func accessibilityPerformPress() -> Bool {
        owner?.choose(index) ?? false
    }
}

/// An on/off switch in Solar's colours.
///
/// NSSwitch draws "on" in the system accent -- blue on most Macs -- and offers
/// no way to say otherwise, which put blue switches beside amber segmented
/// controls. This is the same control drawn from the tokens: amber with dark
/// ink when on, graphite when off. Disabled, it gives the full amber up, as a
/// disabled primary button does, rather than fading it to a muddy brown --
/// but one that is on keeps `accentTint`, so a setting that is on and does
/// not apply right now does not read as off.
final class SolarSwitch: NSView {
    static let size = NSSize(width: 32, height: 18)

    var isOn = false {
        didSet { if isOn != oldValue { needsDisplay = true } }
    }

    var isEnabled = true {
        didSet { if isEnabled != oldValue { needsDisplay = true } }
    }

    weak var target: AnyObject?
    var action: Selector?

    init(label: String) {
        super.init(frame: NSRect(origin: .zero, size: Self.size))
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        setContentCompressionResistancePriority(.required, for: .horizontal)
        focusRingType = .default
        setAccessibilityElement(true)
        setAccessibilityRole(.checkBox)
        setAccessibilitySubrole(.switch)
        setAccessibilityLabel(label)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override var intrinsicContentSize: NSSize { Self.size }

    // A drag that starts on the switch is a press, not a request to move a
    // window that is movable by its background.
    override var mouseDownCanMoveWindow: Bool { false }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func mouseDown(with event: NSEvent) {
        guard isEnabled else { return }
        toggle()
    }

    // Tab reaches it only with Full Keyboard Access on, as it does a checkbox;
    // otherwise a click would leave a focus ring behind.
    override var acceptsFirstResponder: Bool { isEnabled && NSApp.isFullKeyboardAccessEnabled }
    override var canBecomeKeyView: Bool { acceptsFirstResponder }

    override func keyDown(with event: NSEvent) {
        guard isEnabled, event.charactersIgnoringModifiers == " " else {
            super.keyDown(with: event)
            return
        }
        toggle()
    }

    override func accessibilityValue() -> Any? { NSNumber(value: isOn) }
    override func isAccessibilityEnabled() -> Bool { isEnabled }

    override func accessibilityPerformPress() -> Bool {
        guard isEnabled else { return false }
        toggle()
        return true
    }

    private func toggle() {
        isOn.toggle()
        NSAccessibility.post(element: self, notification: .valueChanged)
        if let action { NSApp.sendAction(action, to: target, from: self) }
    }

    override func draw(_ dirtyRect: NSRect) {
        let radius = bounds.height / 2
        let track = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                 xRadius: radius - 0.5, yRadius: radius - 0.5)
        let gap: CGFloat = 2
        let knobSize = bounds.height - gap * 2
        let knob = NSBezierPath(ovalIn: NSRect(
            x: isOn ? bounds.maxX - gap - knobSize : bounds.minX + gap,
            y: bounds.minY + gap, width: knobSize, height: knobSize))

        if isOn && isEnabled {
            DS.accent.setFill()
            track.fill()
            DS.onAccent.setFill()
            knob.fill()
            return
        }
        (isOn ? DS.accentTint : DS.raised).setFill()
        track.fill()
        (isEnabled ? DS.edge : DS.hairline).setStroke()
        track.lineWidth = 1
        track.stroke()
        (isEnabled ? DS.textSecondary : DS.textFaint).setFill()
        knob.fill()
    }

    override func drawFocusRingMask() {
        NSBezierPath(roundedRect: bounds, xRadius: bounds.height / 2,
                     yRadius: bounds.height / 2).fill()
    }

    override var focusRingMaskBounds: NSRect { bounds }
}
