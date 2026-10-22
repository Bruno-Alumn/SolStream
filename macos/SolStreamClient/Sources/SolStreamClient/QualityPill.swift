import AppKit
import DesignSystem
import InputCapture
import SolStreamLogging

/// A dot and an fps count, living in the streamed window's title bar.
///
/// It is always there and it never moves, which is the point: quality
/// information that appears only when something is wrong teaches you to dread it,
/// and one that jumps around draws the eye away from the application. Click it for
/// the detail. Nothing about quality is ever pushed at you.
///
/// Drawn as a Solar chip — `raised`, radius 6, 20 high — with the number in mono,
/// because it is a live number and must not reflow as it changes.
final class QualityPill: DS.Box {

    struct Stats {
        var fps: Int = 0
        var latencyMs: Int?
        var bitrateMbps: Double?
        var droppedFrames: UInt64 = 0
        var totalFrames: UInt64 = 0
        var audioActive: Bool = false
        /// The host answered a request for compressed sound with PCM, which
        /// one that predates the choice does; see StreamSession.
        var hostIgnoresSoundQuality: Bool = false
        /// The host answered a request for the streamed apps' sound with the
        /// whole PC's, as one on Windows 10 does; see StreamSession.
        var hostSendsWholePC: Bool = false
        var hostDisplay: String = ""
        /// The host reports its cursor going away -- declared on its pushes,
        /// or learned from seeing it hide and show one -- so in gaming mode the
        /// mouse follows the game; see `InputCapture.CapturePolicy`. Until then
        /// a click takes the mouse and only ⌃⌥ gives it back, and the popover
        /// must not promise more.
        var hostReportsCursor: Bool = false
    }

    /// What a command-line flag fixed for this run (`--bitrate`, `--no-audio`,
    /// `--sound-quality`), which the popover's controls cannot change. Process-wide because the
    /// flags are: set once by the app delegate after reading them.
    static var commandLineOverrides: Set<StreamSettings.Override> = []

    private let dot = DS.Dot(state: .idle)
    private let label = NSTextField(labelWithString: "—")
    private var popover: NSPopover?

    var stats = Stats() {
        didSet { refresh() }
    }

    /// Whether the application's own title bar is left out of the picture, or
    /// nil when the host found none drawn inside the window, and the popover
    /// has no row for it: a title bar Windows draws is outside the picture
    /// already.
    var hidesTitleBar: Bool?
    /// The choice, made in the popover.
    var onTitleBarChosen: ((Bool) -> Void)?

    init() {
        super.init(fill: DS.raised, radius: DS.Metric.chipRadius)

        label.font = DS.mono
        label.textColor = DS.textSecondary
        label.alignment = .center
        setAccessibilityElement(true)
        setAccessibilityRole(.button)
        setAccessibilityLabel("Stream quality")

        for child in [dot, label] as [NSView] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            // Fixed, so "9" to "120" never nudges the title bar.
            widthAnchor.constraint(equalToConstant: 56),
            heightAnchor.constraint(equalToConstant: DS.Metric.chipHeight),
            dot.leadingAnchor.constraint(equalTo: leadingAnchor, constant: DS.Space.x2),
            dot.centerYAnchor.constraint(equalTo: centerYAnchor),
            label.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: DS.Space.x1),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -DS.Space.x2),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func refresh() {
        label.stringValue = stats.fps > 0 ? "\(stats.fps)" : "—"
        showAccessibilityValue()
        // Frames arriving is green, whatever the rate; nothing arriving is the
        // idle grey. Not amber below some threshold: capture is change-driven,
        // so a still application streams at 15 fps and is perfectly healthy —
        // an amber dot there cried wolf on every dialog. A stream that really
        // is in trouble says so in the status card, in words.
        dot.state = stats.fps > 0 ? .live : .idle
        refreshDetail()
    }

    private func showAccessibilityValue() {
        let rate = stats.fps > 0 ? "\(stats.fps) frames per second" : "no frames"
        // Mute is remembered across launches, so a silent stream may be one
        // muted days ago; said here, it is heard without opening the popover.
        setAccessibilityValue(StreamSettings.shared.isMuted ? rate + ", sound muted" : rate)
    }

    override func mouseDown(with event: NSEvent) {
        togglePopover()
    }

    private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        let content = NSViewController()
        content.view = buildDetail()

        let popover = NSPopover()
        popover.contentViewController = content
        popover.behavior = .transient
        popover.appearance = NSAppearance(named: .darkAqua)
        self.popover = popover
        popover.show(relativeTo: bounds, of: self, preferredEdge: .maxY)
    }

    // MARK: - The popover

    static let detailWidth: CGFloat = 320
    private static let contentWidth = detailWidth - DS.Space.x5 * 2
    /// Every control in the settings rows is this wide, so their left edges
    /// make one column whatever each holds: a toggle, a slider, a menu.
    private static let controlWidth: CGFloat = 168
    /// The settings rows' height, taller than any of their controls, so the
    /// rows sit at one rhythm rather than each at its control's own height.
    private static let settingRowHeight: CGFloat = 26

    func buildDetail() -> NSView {
        func metric(_ caption: String) -> (column: NSView, value: NSTextField) {
            // Headline size with monospaced digits: the figure is the point of
            // the popover, and it must not reflow as it changes.
            let big = DS.label("—", font: .monospacedDigitSystemFont(ofSize: 15, weight: .semibold))
            let small = DS.label(caption, font: DS.caption, colour: DS.textMuted)
            let column = NSStackView(views: [big, small])
            column.orientation = .vertical
            column.alignment = .leading
            column.spacing = 2
            return (column, big)
        }

        let fps = metric("fps"), latency = metric("latency"), bandwidth = metric("bandwidth")
        fpsValue = fps.value
        latencyValue = latency.value
        bandwidthValue = bandwidth.value
        let row = NSStackView(views: [fps.column, latency.column, bandwidth.column])
        row.orientation = .horizontal
        row.distribution = .fillEqually
        row.spacing = DS.Space.x5

        let dropped = NSTextField(labelWithString: "")
        droppedLabel = dropped

        // A label is measured in fractions of a point, and laid out on a 1x
        // screen its frame can round down by that fraction -- enough for the
        // last letters to give way to an ellipsis ("playi…"). Asking for the
        // width rounded up costs nothing. The names on the left ask a step
        // harder, so a value too long for the row is the one that truncates.
        func fitted(_ label: NSTextField, keepsWhole: Bool = false) -> NSTextField {
            let priority: NSLayoutConstraint.Priority = keepsWhole ? .defaultHigh + 2 : .defaultHigh + 1
            let width = label.widthAnchor.constraint(
                greaterThanOrEqualToConstant: ceil(label.intrinsicContentSize.width))
            width.priority = priority
            width.isActive = true
            label.setContentCompressionResistancePriority(priority, for: .horizontal)
            return label
        }

        func line(_ caption: String, _ value: String, isData: Bool = false) -> (view: NSView, value: NSTextField) {
            let left = fitted(DS.label(caption, font: DS.body, colour: DS.textMuted), keepsWhole: true)
            let right = fitted(DS.label(value, font: isData ? DS.mono : DS.body, colour: DS.textSecondary))
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [left, spacer, right])
            stack.orientation = .horizontal
            return (stack, right)
        }

        // The same shape as `line`, the name muted on the left, with a control
        // in place of the value.
        func setting(_ caption: String, _ control: NSView) -> NSStackView {
            control.translatesAutoresizingMaskIntoConstraints = false
            control.widthAnchor.constraint(equalToConstant: Self.controlWidth).isActive = true
            let left = fitted(DS.label(caption, font: DS.body, colour: DS.textMuted), keepsWhole: true)
            let spacer = NSView()
            spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
            let stack = NSStackView(views: [left, spacer, control])
            stack.orientation = .horizontal
            stack.heightAnchor.constraint(equalToConstant: Self.settingRowHeight).isActive = true
            return stack
        }

        func note(_ text: String) -> NSTextField {
            let note = DS.label(text, font: DS.caption, colour: DS.textMuted)
            note.lineBreakMode = .byWordWrapping
            note.maximumNumberOfLines = 3
            note.preferredMaxLayoutWidth = Self.contentWidth
            return note
        }

        let settings = StreamSettings.shared

        let hostDisplay = line("Host display", Self.hostDisplayText(stats), isData: true)
        hostDisplayValue = hostDisplay.value

        // Sound: volume and mute, which the audio side applies as they move,
        // so they belong here on the window rather than only in Settings. What
        // the stream is doing with sound is the note under them rather than a
        // line of its own above, so the popover names it once.
        let mute = NSButton(image: NSImage(), target: self, action: #selector(muteToggled(_:)))
        mute.isBordered = false
        mute.imagePosition = .imageOnly
        mute.imageScaling = .scaleNone
        mute.symbolConfiguration = .init(pointSize: 13, weight: .medium)
        // Fixed, so the slider beside it does not shift as the icon changes
        // between the slashed speaker and one with three waves.
        mute.widthAnchor.constraint(equalToConstant: 22).isActive = true
        mute.setContentHuggingPriority(.required, for: .horizontal)
        let volume = NSSlider(value: Double(settings.volume) * 100, minValue: 0, maxValue: 100,
                              target: self, action: #selector(volumeMoved(_:)))
        volume.isContinuous = true
        volume.setAccessibilityLabel("Volume")
        let soundControls = NSStackView(views: [mute, volume])
        soundControls.orientation = .horizontal
        soundControls.spacing = DS.Space.x1
        let soundNote = note("")
        muteButton = mute
        volumeSlider = volume
        self.soundControls = soundControls
        self.soundNote = soundNote

        // The sound's quality sits under its volume, and its note under the
        // volume's, so everything about the sound is one group. Named in full:
        // "Quality" in a popover that has the video's as well could be either.
        let soundQuality = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in StreamSettings.SoundQuality.allCases {
            soundQuality.addItem(withTitle: choice.title)
            soundQuality.lastItem?.representedObject = choice.rawValue
            soundQuality.lastItem?.toolTip = choice.detail
        }
        soundQuality.selectItem(withTitle: settings.soundQuality.title)
        soundQuality.target = self
        soundQuality.action = #selector(soundQualityChosen(_:))
        soundQuality.setAccessibilityLabel("Sound quality")
        let soundQualityNote = note("")
        soundQualityMenu = soundQuality
        self.soundQualityNote = soundQualityNote

        // The mouse mode lives here, beside the numbers it affects, rather than
        // in a menu: it is a per-moment choice -- a game now, a spreadsheet in
        // a minute -- and this is the one control on the streamed window.
        // The same drawn control as Settings, so the choice looks one way
        // wherever it is made.
        let modes = SolarSegments(labels: ["Desktop", "Gaming"], accessibilityLabel: "Mouse mode")
        modes.target = self
        modes.action = #selector(pointerModeChosen(_:))
        modes.selectedSegment = settings.pointerMode == .gaming ? 1 : 0
        let mouseHint = note(Self.pointerHint(settings.pointerMode, followsGame: followsGame))
        self.mouseHint = mouseHint

        // Quality is here as well as in Settings because the place you notice
        // the picture is soft, or the connection struggling, is this window.
        // A bitrate fixed by `--bitrate` wins over it, so the menu stands down
        // rather than offer a choice that would change nothing.
        let pinned = Self.commandLineOverrides.contains(.bitrate)
        let quality = NSPopUpButton(frame: .zero, pullsDown: false)
        for choice in StreamSettings.VideoQuality.allCases {
            quality.addItem(withTitle: choice.title)
            quality.lastItem?.representedObject = choice.rawValue
            quality.lastItem?.toolTip = choice.detail
        }
        quality.selectItem(withTitle: settings.videoQuality.title)
        quality.target = self
        quality.action = #selector(qualityChosen(_:))
        quality.isEnabled = !pinned
        quality.setAccessibilityLabel("Video quality")
        let qualityNote = note(Self.qualityNote(settings.videoQuality, pinned: pinned))
        self.qualityNote = qualityNote

        // Named as Settings names its section: "Quality" alone, under Sound,
        // read as if it might be the sound's too.
        let soundRow = setting("Sound", soundControls)
        let soundQualityRow = setting("Sound quality", soundQuality)
        let mouseRow = setting("Mouse", modes)
        let videoRow = setting("Video", quality)

        // The application's own minimise, maximise and close, for one drawn
        // inside its window, where the picture would otherwise show them. Only
        // then: a title bar Windows draws is outside the picture already. Off
        // until chosen, so nobody loses a strip they never asked to lose. No
        // note under it, which would take the popover past a laptop's comfort;
        // "Title bar, Show, Hide" says it, and the tooltip says the rest.
        var titleBarRow: NSView?
        if let hidesTitleBar {
            let choice = SolarSegments(labels: ["Show", "Hide"], accessibilityLabel: "Title bar")
            choice.target = self
            choice.action = #selector(titleBarChosen(_:))
            choice.selectedSegment = hidesTitleBar ? 1 : 0
            choice.toolTip = "Hide leaves the app's own minimise, maximise and close out of the "
                + "picture, with whatever shares their strip. Kept for this app."
            titleBarRow = setting("Title bar", choice)
        }
        let footer = DS.hairlineView()
        let settingsLink = LinkButton(title: "All settings", target: self,
                                      action: #selector(openSettings(_:)))

        let stack = NSStackView(views: [
            row,
            dropped,
            DS.hairlineView(),
            hostDisplay.view,
            DS.hairlineView(),
            soundRow,
            soundQualityRow,
            soundNote,
            soundQualityNote,
            mouseRow,
            mouseHint,
            videoRow,
            qualityNote,
            footer,
            settingsLink,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = DS.Space.x3
        // With the mouse: both are about how the window behaves, not the stream.
        if let titleBarRow, let at = stack.arrangedSubviews.firstIndex(of: videoRow) {
            stack.insertArrangedSubview(titleBarRow, at: at)
        }
        stack.setCustomSpacing(DS.Space.x2, after: row)
        // A note sits under its own row, closer to it than to the next one.
        // The sound's two rows are one group, with their two notes under both.
        for (settingRow, itsNote) in [(soundQualityRow, soundQualityNote), (mouseRow, mouseHint),
                                      (videoRow, qualityNote)] {
            stack.setCustomSpacing(DS.Space.x1, after: settingRow)
            stack.setCustomSpacing(DS.Space.x4, after: itsNote)
        }
        stack.setCustomSpacing(DS.Space.x2, after: soundRow)
        stack.setCustomSpacing(2, after: soundNote)
        stack.setCustomSpacing(DS.Space.x3, after: footer)
        stack.edgeInsets = NSEdgeInsets(top: DS.Space.x5, left: DS.Space.x5,
                                        bottom: DS.Space.x4, right: DS.Space.x5)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let container = NSView(frame: NSRect(x: 0, y: 0, width: Self.detailWidth, height: 400))
        container.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            stack.topAnchor.constraint(equalTo: container.topAnchor),
            stack.bottomAnchor.constraint(lessThanOrEqualTo: container.bottomAnchor),
        ])
        // Everything full width but the link, which is only as wide as its
        // words so that it is clickable only where it reads as clickable.
        for view in stack.arrangedSubviews where view !== settingsLink {
            view.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -DS.Space.x5 * 2).isActive = true
        }
        detailStack = stack
        showFigures()
        showSound()
        refitDetail()
        return container
    }

    /// As tall as what the popover holds, measured, rather than a fixed guess
    /// that either clipped the last rows or left a band of empty popover.
    /// Measured again when a note changes with the choice above it, since a
    /// note one line longer would otherwise push the link out of sight.
    private func refitDetail() {
        guard let stack = detailStack, let container = stack.superview else { return }
        container.layoutSubtreeIfNeeded()
        let size = NSSize(width: Self.detailWidth, height: ceil(stack.fittingSize.height))
        guard size != container.frame.size else { return }
        container.setFrameSize(size)
        if let popover, popover.isShown { popover.contentSize = size }
    }

    /// The popover's figures and notes, kept current while it is open. It
    /// holds controls whose effect shows in those figures -- a new quality
    /// restarts the stream underneath it -- and a bandwidth frozen at the
    /// moment it opened would say the change had done nothing.
    private func refreshDetail() {
        guard detailStack != nil else { return }
        showFigures()
        let hint = Self.pointerHint(StreamSettings.shared.pointerMode, followsGame: followsGame)
        // Either note growing a line moves the link, so both are asked.
        let soundMoved = showSound(movingSlider: false)
        let hintMoved = Self.show(hint, in: mouseHint)
        if soundMoved || hintMoved { refitDetail() }
    }

    /// Fixed widths and monospaced digits, so none of these reflow anything.
    private func showFigures() {
        fpsValue?.stringValue = stats.fps > 0 ? "\(stats.fps)" : "—"
        latencyValue?.stringValue = stats.latencyMs.map { "\($0) ms" } ?? "—"
        // "Mbps", as the quality notes spell it, since the two are compared.
        bandwidthValue?.stringValue = stats.bitrateMbps.map { String(format: "%.0f Mbps", $0) } ?? "—"
        droppedLabel?.attributedStringValue = DS.detail([
            ("\(stats.droppedFrames) dropped of \(Self.compact(stats.totalFrames))", isData: true),
        ])
        hostDisplayValue?.stringValue = Self.hostDisplayText(stats)
    }

    private weak var detailStack: NSStackView?
    private weak var fpsValue: NSTextField?
    private weak var latencyValue: NSTextField?
    private weak var bandwidthValue: NSTextField?
    private weak var droppedLabel: NSTextField?
    private weak var hostDisplayValue: NSTextField?
    private weak var soundControls: NSStackView?
    private weak var soundNote: NSTextField?
    private weak var soundQualityMenu: NSPopUpButton?
    private weak var soundQualityNote: NSTextField?
    private weak var mouseHint: NSTextField?
    private weak var qualityNote: NSTextField?
    private weak var muteButton: NSButton?
    private weak var volumeSlider: NSSlider?

    /// Whether gaming mode is following the game's own cursor: the setting,
    /// and a host that has been seen reporting it. The setting alone does
    /// nothing with a PC host too old to say "hidden" -- there a game's pause
    /// menu leaves the mouse captured until ⌃⌥ -- so the menus are promised
    /// only once this window has seen the host keep that promise.
    private var followsGame: Bool {
        StreamSettings.shared.followsHostCursor && stats.hostReportsCursor
    }

    @objc private func pointerModeChosen(_ sender: SolarSegments) {
        let mode: InputCapture.PointerMode = sender.selectedSegment == 1 ? .gaming : .desktop
        StreamSettings.shared.pointerMode = mode
        mouseHint?.stringValue = Self.pointerHint(mode, followsGame: followsGame)
        refitDetail()
    }

    @objc private func titleBarChosen(_ sender: SolarSegments) {
        let hides = sender.selectedSegment == 1
        guard hides != hidesTitleBar else { return }
        hidesTitleBar = hides
        onTitleBarChosen?(hides)
    }

    @objc private func volumeMoved(_ sender: NSSlider) {
        let settings = StreamSettings.shared
        settings.volume = Float(sender.doubleValue / 100)
        // Reaching for the volume means wanting to hear it; a slider that moved
        // while nothing changed would look broken.
        if settings.isMuted { settings.isMuted = false }
        if showSound(movingSlider: false) { refitDetail() }
        showAccessibilityValue()
    }

    @objc private func muteToggled(_ sender: NSButton) {
        let settings = StreamSettings.shared
        settings.isMuted.toggle()
        // Unmuting into a volume of zero would change nothing you can hear, and
        // look as if the button had not worked, so it brings back half.
        if !settings.isMuted, settings.volume == 0 { settings.volume = 0.5 }
        if showSound() { refitDetail() }
        showAccessibilityValue()
    }

    /// The speaker, the slider and the note under them, from the settings and
    /// from what the stream is sending.
    ///
    /// The amber goes to whichever part is in charge: the slider's fill while
    /// sound plays at that level, the slashed speaker while muted. A muted
    /// stream is the one state here you can forget you chose -- it is kept
    /// across launches -- so it is the one that has to be findable, and the
    /// note says it in words as well; the slider greys to say its level is
    /// kept, not playing. `movingSlider` is false while the slider itself is
    /// being dragged -- writing back a value rounded through `Float` mid-drag
    /// would fight the hand.
    ///
    /// - Returns: whether the note's words changed, and with them perhaps
    ///   the popover's height.
    @discardableResult
    private func showSound(movingSlider: Bool = true) -> Bool {
        let settings = StreamSettings.shared
        let muted = settings.isMuted
        // Nothing to turn up when nothing is sent. Dimmed as a group as well
        // as disabled: the slider's own disabled look keeps a bright knob that
        // still reads as something to drag.
        let off = Self.soundOff(audioActive: stats.audioActive) != nil
        if let muteButton {
            muteButton.image = muted
                ? NSImage(systemSymbolName: "speaker.slash.fill", accessibilityDescription: nil)
                : NSImage(systemSymbolName: "speaker.wave.3.fill",
                          variableValue: Double(settings.volume), accessibilityDescription: nil)
            muteButton.contentTintColor = muted ? DS.accentInk : DS.textSecondary
            muteButton.setAccessibilityLabel(muted ? "Unmute" : "Mute")
            muteButton.isEnabled = !off
        }
        if let volumeSlider {
            if movingSlider { volumeSlider.doubleValue = Double(settings.volume) * 100 }
            volumeSlider.isEnabled = !off
            volumeSlider.trackFillColor = muted || off ? DS.textFaint : DS.accent
            volumeSlider.needsDisplay = true
        }
        soundControls?.alphaValue = off ? 0.5 : 1

        // With no sound sent there is nothing to encode, so the quality stands
        // down with the volume, and its note -- which promises a restart that
        // would not happen -- goes. A flag fixes it for the run, as --bitrate
        // fixes the video's.
        let pinned = Self.commandLineOverrides.contains(.soundQuality)
        soundQualityMenu?.isEnabled = !off && !pinned
        let qualityText = Self.soundQualityNote(settings.soundQuality, pinned: pinned,
                                                ignored: stats.hostIgnoresSoundQuality)
        let qualityMoved = Self.show(qualityText, in: soundQualityNote)
        let wasHidden = soundQualityNote?.isHidden ?? true
        soundQualityNote?.isHidden = off
        let soundMoved = Self.show(Self.soundNote(audioActive: stats.audioActive, muted: muted,
                                                  wholePC: stats.hostSendsWholePC),
                                   in: soundNote)
        return soundMoved || qualityMoved || wasHidden != off
    }

    @objc private func soundQualityChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let choice = StreamSettings.SoundQuality(rawValue: raw) else { return }
        // Choosing the one already chosen must not restart the picture.
        guard choice != StreamSettings.shared.soundQuality else { return }
        StreamSettings.shared.soundQuality = choice
        if showSound() { refitDetail() }
    }

    @objc private func qualityChosen(_ sender: NSPopUpButton) {
        guard let raw = sender.selectedItem?.representedObject as? String,
              let choice = StreamSettings.VideoQuality(rawValue: raw) else { return }
        qualityNote?.stringValue = Self.qualityNote(choice, pinned: false)
        refitDetail()
        // Choosing the one already chosen must not restart the picture.
        guard choice != StreamSettings.shared.videoQuality else { return }
        StreamSettings.shared.videoQuality = choice
    }

    @objc private func openSettings(_ sender: Any?) {
        popover?.performClose(nil)
        NotificationCenter.default.post(name: StreamSettings.openSettingsRequest, object: self)
    }

    /// `text` into `label`, saying whether that changed it.
    private static func show(_ text: String, in label: NSTextField?) -> Bool {
        guard let label, label.stringValue != text else { return false }
        label.stringValue = text
        return true
    }

    private enum SoundOff { case byFlag, inSettings }

    /// Why the PC is sending no sound, when it is by choice. With sound turned
    /// off the PC sends none, and "nothing playing" would send you looking at
    /// the PC for the cause. `.audio` among the overrides is `--no-audio`, the
    /// one flag that sets it.
    private static func soundOff(audioActive: Bool) -> SoundOff? {
        guard !audioActive else { return nil }
        if commandLineOverrides.contains(.audio) { return .byFlag }
        if !StreamSettings.shared.streamsAudio { return .inSettings }
        return nil
    }

    /// - Parameter wholePC: the host sends all its sound though only the
    ///   streamed apps' was asked for, which Settings says is what you get.
    private static func soundNote(audioActive: Bool, muted: Bool, wholePC: Bool) -> String {
        switch soundOff(audioActive: audioActive) {
        case .byFlag: return "Off for this run, by --no-audio."
        case .inSettings: return "Off in Settings, so the PC sends none."
        case nil: break
        }
        if muted { return audioActive ? "Muted on this Mac. The PC is still playing." : "Muted on this Mac." }
        if wholePC {
            return audioActive
                ? "Playing all the PC's sound: the streamed apps' alone needs Windows 11."
                : "Nothing playing. The PC sends all its sound: the streamed apps' alone needs Windows 11."
        }
        return audioActive ? "Playing from the PC." : "Nothing playing on the PC right now."
    }

    /// One wording for both places the mode is chosen; see SettingsPane.
    private static func pointerHint(_ mode: InputCapture.PointerMode, followsGame: Bool) -> String {
        SettingsPane.modeDetail(mode, followsCursor: followsGame)
    }

    /// The sound's quality, said as the video's is: what it costs, and that
    /// choosing it restarts the stream. A host that ignored it is said to
    /// have, because otherwise the menu would claim 64 kbps of a stream that
    /// is still sending 1.5 Mbps.
    private static func soundQualityNote(_ quality: StreamSettings.SoundQuality, pinned: Bool,
                                         ignored: Bool) -> String {
        if pinned { return "Set by --sound-quality for this run." }
        if ignored { return "SolStream on the PC predates this, so it sends uncompressed sound." }
        return "\(quality.rate). Changing it restarts the picture briefly."
    }

    /// What the quality means, and that choosing it is not free: the PC's
    /// encoder is set when the stream opens, so a new quality opens it again.
    private static func qualityNote(_ quality: StreamSettings.VideoQuality, pinned: Bool) -> String {
        pinned ? "Set by --bitrate for this run."
            : "\(quality.detail) Changing it restarts the picture briefly."
    }

    private static func hostDisplayText(_ stats: Stats) -> String {
        stats.hostDisplay.isEmpty ? "—" : stats.hostDisplay
    }

    private static func compact(_ value: UInt64) -> String {
        switch value {
        case 1_000_000...: return String(format: "%.1f M", Double(value) / 1_000_000)
        case 1_000...: return String(format: "%.0f k", Double(value) / 1_000)
        default: return "\(value)"
        }
    }
}

/// A button that reads as a link: words in `textSecondary` and a chevron in
/// `textMuted`, both brightening to `text` under the pointer, and the pointing
/// hand. For the way out of the popover, which should not look like one more
/// setting in it, nor spend the amber that marks the choices above it.
///
/// The chevron is what says "go" before the pointer arrives: the words alone
/// look like the values above them. Not "⌘,", which a menu would show --
/// in the streamed window ⌘, goes to the PC as Ctrl+comma.
///
/// The connect window uses it too, for the ways out to a web page or another
/// app: "Get it for Windows", "Get Tailscale". Those sit beside captions, so
/// the font can be the caption's rather than the body's.
final class LinkButton: NSButton {
    /// What the link says. Settable, for a link whose destination changes
    /// with what it is offering -- "Get Tailscale" or "Open Tailscale".
    var words: String {
        didSet { paint(); invalidateIntrinsicContentSize() }
    }
    private let wordsFont: NSFont
    private var hovering = false { didSet { paint() } }
    private var tracking: NSTrackingArea?

    init(title: String, font: NSFont = DS.body, target: AnyObject?, action: Selector?) {
        words = title
        wordsFont = font
        super.init(frame: .zero)
        self.target = target
        self.action = action
        isBordered = false
        // Momentary-change shows the alternate title and image while pressed;
        // without an alternate image the chevron would vanish under the click.
        setButtonType(.momentaryChange)
        let chevron = NSImage(systemSymbolName: "chevron.right", accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 9, weight: .semibold))
        image = chevron
        alternateImage = chevron
        imagePosition = .imageTrailing
        imageHugsTitle = true
        translatesAutoresizingMaskIntoConstraints = false
        setContentHuggingPriority(.required, for: .horizontal)
        paint()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private func paint() {
        func styled(_ colour: NSColor) -> NSAttributedString {
            NSAttributedString(string: words, attributes: [.font: wordsFont, .foregroundColor: colour])
        }
        attributedTitle = styled(hovering ? DS.text : DS.textSecondary)
        attributedAlternateTitle = styled(DS.textMuted)
        contentTintColor = hovering ? DS.text : DS.textMuted
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
        addTrackingArea(area)
        tracking = area
    }

    override func mouseEntered(with event: NSEvent) { hovering = true }
    override func mouseExited(with event: NSEvent) { hovering = false }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .pointingHand)
    }

    // A borderless button draws its title 2pt in from its edge; a label draws
    // its text 2pt out. Insetting the alignment rect by those 2pt puts the
    // link's first letter on the same line as the labels' above it.
    override var alignmentRectInsets: NSEdgeInsets {
        NSEdgeInsets(top: 0, left: 2, bottom: 0, right: 2)
    }
}
