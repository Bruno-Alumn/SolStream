import AppKit
import XCTest
import DesignSystem
import InputCapture
import MediaSession
import AgentChannel
@testable import SolStreamClient

/// The Settings window: every control there, each showing the setting as it is,
/// each writing it back -- and saying whether the stream has to restart for it.
///
/// Built off screen throughout: the pane on its own, or a window that is never
/// ordered front.
final class SettingsWindowTests: XCTestCase {
    private static let keys = [
        "SolStream.videoQuality", "SolStream.frameRate", "SolStream.streamsAudio",
        "SolStream.volume", "SolStream.muted", "SolStream.audioBuffering",
        "SolStream.syncsClipboard", "SolStream.pointerMode",
        "SolStream.gamingSensitivity", "SolStream.followsHostCursor",
    ]
    private var saved: [String: Any] = [:]
    private let settings = StreamSettings.shared

    override func setUp() {
        super.setUp()
        saved = [:]
        for key in Self.keys {
            if let value = UserDefaults.standard.object(forKey: key) { saved[key] = value }
        }
    }

    override func tearDown() {
        for key in Self.keys {
            if let value = saved[key] {
                UserDefaults.standard.set(value, forKey: key)
            } else {
                UserDefaults.standard.removeObject(forKey: key)
            }
        }
        super.tearDown()
    }

    // MARK: - Reading

    func testEveryControlShowsTheSettingsAsTheyAre() {
        settings.videoQuality = .high
        settings.frameRate = 30
        settings.streamsAudio = true
        settings.volume = 0.4
        settings.isMuted = false
        settings.audioBuffering = .steady
        settings.pointerMode = .gaming
        settings.gamingSensitivity = 2
        settings.followsHostCursor = false
        settings.syncsClipboard = false

        let pane = SettingsPane()
        XCTAssertEqual(pane.qualityPopUp.titleOfSelectedItem, "High")
        XCTAssertEqual(pane.qualityDetail.stringValue, StreamSettings.VideoQuality.high.detail)
        XCTAssertEqual(pane.frameRateControl.segmentCount, 2)
        XCTAssertEqual(pane.frameRateControl.label(forSegment: pane.frameRateControl.selectedSegment),
                       "30 fps")
        XCTAssertTrue(pane.soundSwitch.isOn)
        XCTAssertEqual(pane.volumeSlider.doubleValue, 40, accuracy: 0.01)
        XCTAssertEqual(pane.volumeValue.stringValue, "40%")
        XCTAssertTrue(pane.volumeSlider.isEnabled)
        XCTAssertEqual(pane.muteButton.accessibilityLabel(), "Mute")
        XCTAssertEqual(pane.bufferingPopUp.titleOfSelectedItem, "Smooth")
        XCTAssertEqual(pane.bufferingDetail.stringValue,
                       StreamSettings.AudioBufferingChoice.steady.detail)
        XCTAssertEqual(pane.modeControl.selectedSegment, 1)
        XCTAssertEqual(pane.sensitivitySlider.doubleValue, 1, accuracy: 0.001, "2x is log2 = 1")
        XCTAssertEqual(pane.sensitivityValue.stringValue, "2.00×")
        XCTAssertTrue(pane.sensitivitySlider.isEnabled)
        XCTAssertFalse(pane.followsCursorSwitch.isOn)
        XCTAssertTrue(pane.followsCursorSwitch.isEnabled)
        XCTAssertFalse(pane.clipboardSwitch.isOn)
    }

    /// Rows that mean nothing in the current state say so by being disabled:
    /// volume and buffering with the PC's sound off, sensitivity and giving
    /// the mouse back in desktop mode.
    func testRowsThatDoNotApplyAreDisabled() {
        settings.streamsAudio = false
        settings.isMuted = true
        settings.pointerMode = .desktop
        settings.followsHostCursor = true
        settings.syncsClipboard = true

        let pane = SettingsPane()
        XCTAssertFalse(pane.soundSwitch.isOn)
        XCTAssertFalse(pane.volumeSlider.isEnabled)
        XCTAssertFalse(pane.muteButton.isEnabled)
        XCTAssertFalse(pane.bufferingPopUp.isEnabled)
        XCTAssertEqual(pane.volumeValue.stringValue, "Muted")
        XCTAssertEqual(pane.muteButton.accessibilityLabel(), "Unmute")
        XCTAssertEqual(pane.modeControl.selectedSegment, 0)
        XCTAssertFalse(pane.sensitivitySlider.isEnabled)
        XCTAssertFalse(pane.followsCursorSwitch.isEnabled)
        XCTAssertTrue(pane.followsCursorSwitch.isOn)
        XCTAssertTrue(pane.clipboardSwitch.isOn)
    }

    /// The popover on a streamed window changes the same settings, and the mouse
    /// mode has a setter of its own; an open Settings window follows both.
    func testItFollowsChangesMadeElsewhere() {
        settings.volume = 1
        settings.isMuted = false
        settings.pointerMode = .desktop
        let pane = SettingsPane()

        settings.volume = 0.2
        XCTAssertEqual(pane.volumeSlider.doubleValue, 20, accuracy: 0.01)
        settings.isMuted = true
        XCTAssertEqual(pane.volumeValue.stringValue, "Muted")
        settings.videoQuality = .dataSaver
        XCTAssertEqual(pane.qualityPopUp.titleOfSelectedItem, "Data saver")
        InputCapture.pointerMode = .gaming
        XCTAssertEqual(pane.modeControl.selectedSegment, 1)
        XCTAssertTrue(pane.sensitivitySlider.isEnabled)
    }

    // MARK: - Writing

    func testEachControlWritesItsSettingAndSaysWhetherTheStreamRestarts() {
        settings.videoQuality = .automatic
        settings.frameRate = 60
        settings.streamsAudio = true
        settings.volume = 1
        settings.isMuted = false
        settings.audioBuffering = .automatic
        settings.pointerMode = .desktop
        settings.gamingSensitivity = 1
        settings.followsHostCursor = true
        settings.syncsClipboard = true
        let pane = SettingsPane()

        var restarts: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: StreamSettings.didChange, object: nil, queue: nil) { note in
            restarts.append(note.userInfo?[StreamSettings.restartsStreamKey] as? Bool ?? false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        func expect(restart: Bool, _ what: String, file: StaticString = #filePath, line: UInt = #line) {
            XCTAssertFalse(restarts.isEmpty, "\(what) wrote nothing", file: file, line: line)
            XCTAssertEqual(restarts.last, restart, what, file: file, line: line)
            restarts.removeAll()
        }

        choose(pane.qualityPopUp, StreamSettings.VideoQuality.allCases.firstIndex(of: .maximum)!)
        XCTAssertEqual(settings.videoQuality, .maximum)
        XCTAssertEqual(pane.qualityDetail.stringValue, StreamSettings.VideoQuality.maximum.detail)
        expect(restart: true, "quality")

        // The same choice again is not a change, and must not restart anything.
        choose(pane.qualityPopUp, StreamSettings.VideoQuality.allCases.firstIndex(of: .maximum)!)
        XCTAssertTrue(restarts.isEmpty, "re-choosing the quality restarted the stream")

        pane.frameRateControl.selectedSegment = 0
        send(pane.frameRateControl)
        XCTAssertEqual(settings.frameRate, 30)
        expect(restart: true, "frame rate")

        pane.volumeSlider.doubleValue = 25
        send(pane.volumeSlider)
        XCTAssertEqual(settings.volume, 0.25, accuracy: 0.001)
        XCTAssertEqual(pane.volumeValue.stringValue, "25%")
        expect(restart: false, "volume")

        send(pane.muteButton)
        XCTAssertTrue(settings.isMuted)
        XCTAssertEqual(pane.volumeValue.stringValue, "Muted")
        expect(restart: false, "mute")
        // Moving the volume while muted is a request to hear it.
        pane.volumeSlider.doubleValue = 60
        send(pane.volumeSlider)
        XCTAssertFalse(settings.isMuted)
        restarts.removeAll()

        choose(pane.bufferingPopUp,
               StreamSettings.AudioBufferingChoice.allCases.firstIndex(of: .lowLatency)!)
        XCTAssertEqual(settings.audioBuffering, .lowLatency)
        expect(restart: false, "buffering")

        XCTAssertTrue(pane.soundSwitch.accessibilityPerformPress())
        XCTAssertFalse(settings.streamsAudio)
        XCTAssertFalse(pane.volumeSlider.isEnabled, "volume still enabled with the sound off")
        expect(restart: true, "the PC's sound")

        XCTAssertFalse(pane.sensitivitySlider.isEnabled)
        pane.modeControl.selectedSegment = 1
        send(pane.modeControl)
        XCTAssertEqual(settings.pointerMode, .gaming)
        XCTAssertTrue(pane.sensitivitySlider.isEnabled, "gaming mode left sensitivity disabled")
        expect(restart: false, "mouse mode")

        pane.sensitivitySlider.doubleValue = -1
        send(pane.sensitivitySlider)
        XCTAssertEqual(settings.gamingSensitivity, 0.5, accuracy: 0.001)
        XCTAssertEqual(pane.sensitivityValue.stringValue, "0.50×")
        expect(restart: false, "sensitivity")

        XCTAssertTrue(pane.followsCursorSwitch.accessibilityPerformPress())
        XCTAssertFalse(settings.followsHostCursor)
        expect(restart: false, "giving the mouse back")

        XCTAssertTrue(pane.clipboardSwitch.accessibilityPerformPress())
        XCTAssertFalse(settings.syncsClipboard)
        expect(restart: false, "clipboard")
    }

    func testADisabledSwitchCannotBePressed() {
        let toggle = SolarSwitch(label: "test")
        toggle.isOn = true
        toggle.isEnabled = false
        XCTAssertFalse(toggle.accessibilityPerformPress())
        XCTAssertTrue(toggle.isOn)
        XCTAssertEqual(toggle.accessibilityValue() as? NSNumber, 1)
        XCTAssertEqual(toggle.accessibilityRole(), .checkBox)
    }

    /// A segment pressed by VoiceOver or Voice Control chooses it as a click
    /// does, and tells the target only when that is a change.
    func testSegmentsChooseLikeAClickAndNotWhenDisabled() throws {
        final class Target: NSObject {
            var chosen: [Int] = []
            @objc func chose(_ sender: SolarSegments) { chosen.append(sender.selectedSegment) }
        }
        let target = Target()
        let segments = SolarSegments(labels: ["Desktop", "Gaming"], accessibilityLabel: "Mouse mode")
        segments.target = target
        segments.action = #selector(Target.chose(_:))
        XCTAssertEqual(segments.accessibilityRole(), .radioGroup)
        let buttons = try XCTUnwrap(segments.accessibilityChildren() as? [NSAccessibilityElement])
        XCTAssertEqual(buttons.map { $0.accessibilityLabel() }, ["Desktop", "Gaming"])

        XCTAssertTrue(buttons[1].accessibilityPerformPress())
        XCTAssertEqual(segments.selectedSegment, 1)
        XCTAssertEqual(buttons[1].accessibilityValue() as? NSNumber, 1)
        XCTAssertEqual(segments.accessibilityValue() as? String, "Gaming")
        XCTAssertTrue(buttons[1].accessibilityPerformPress())
        XCTAssertEqual(target.chosen, [1], "choosing the chosen one again is not a change")

        segments.isEnabled = false
        XCTAssertFalse(buttons[0].accessibilityPerformPress())
        XCTAssertEqual(segments.selectedSegment, 1)
        XCTAssertEqual(target.chosen, [1])
    }

    /// VoiceOver reads the figures beside the sliders, not the slider's own
    /// value: sensitivity runs over a logarithm, where 0.5x is "minus 1".
    func testSlidersSayTheirValuesInTheirOwnUnits() {
        settings.pointerMode = .gaming
        settings.gamingSensitivity = 0.5
        settings.streamsAudio = true
        settings.volume = 0.8
        settings.isMuted = false
        let pane = SettingsPane()
        XCTAssertEqual(pane.sensitivitySlider.accessibilityValueDescription(), "0.50×")
        XCTAssertEqual(pane.volumeSlider.accessibilityValueDescription(), "80%")
        settings.isMuted = true
        XCTAssertEqual(pane.volumeSlider.accessibilityValueDescription(), "Muted, 80%")
    }

    // MARK: - Sensitivity's scale

    /// 1x in the middle of the track, halving as far from it as doubling.
    func testSensitivityRunsOnALogarithmicTrackWithADetentAtOne() {
        XCTAssertEqual(SettingsPane.sensitivity(forSliderPosition: 0), 1)
        XCTAssertEqual(SettingsPane.sensitivity(forSliderPosition: 0.05), 1, "no detent at 1x")
        XCTAssertEqual(SettingsPane.sensitivity(forSliderPosition: -2), 0.25)
        XCTAssertEqual(SettingsPane.sensitivity(forSliderPosition: 2), 4)
        XCTAssertEqual(SettingsPane.sensitivity(forSliderPosition: -1), 0.5)
        XCTAssertEqual(SettingsPane.sensitivity(forSliderPosition: 1), 2)
        XCTAssertEqual(SettingsPane.sliderPosition(forSensitivity: 1), 0)
        XCTAssertEqual(SettingsPane.sliderPosition(forSensitivity: 10), 2, "not clamped to 4x")
        for position in stride(from: -2.0, through: 2.0, by: 0.01) {
            let value = SettingsPane.sensitivity(forSliderPosition: position)
            XCTAssertTrue((0.25...4).contains(value))
            // Twentieths, so the figure beside the slider never shows noise.
            XCTAssertEqual(value * 20, (value * 20).rounded(), accuracy: 1e-9)
        }
    }

    // MARK: - Restarting a running stream

    func testOnlyAChangeTheStreamDoesNotHaveYetRestartsIt() {
        settings.videoQuality = .balanced
        settings.frameRate = 60
        settings.streamsAudio = true
        var request = AgentConnection.MediaRequest(display: "\\\\.\\DISPLAY9", fps: 60,
                                                   bitrate: 20_000_000, audio: true)
        request.width = 3024
        request.height = 1964
        let config = StreamConfig(width: 3024, height: 1964, frameRate: 60,
                                  bitrateKbps: 20_000, audio: true)

        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config,
                                          host: "192.168.1.20", overrides: []),
                     "Balanced at home is what the stream already has")

        settings.frameRate = 30
        settings.videoQuality = .high
        settings.streamsAudio = false
        let fresh = AppDelegate.applying(settings, to: request, config: config,
                                         host: "192.168.1.20", overrides: [])
        XCTAssertEqual(fresh?.request.fps, 30)
        XCTAssertEqual(fresh?.request.bitrate, 35_000_000, "the request is in bits a second")
        XCTAssertEqual(fresh?.request.audio, false)
        XCTAssertEqual(fresh?.config.bitrateKbps, 35_000)
        // Everything the settings do not own is carried over untouched.
        XCTAssertEqual(fresh?.request.display, "\\\\.\\DISPLAY9")
        XCTAssertEqual(fresh?.request.width, 3024)
        XCTAssertEqual(fresh?.config.height, 1964)

        // What the command line set stays set.
        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config,
                                          host: "192.168.1.20",
                                          overrides: [.frameRate, .bitrate, .audio]))
        let partly = AppDelegate.applying(settings, to: request, config: config,
                                          host: "192.168.1.20", overrides: [.bitrate])
        XCTAssertEqual(partly?.request.bitrate, 20_000_000)
        XCTAssertEqual(partly?.request.fps, 30)

        // Automatic over Tailscale starts lower than at home.
        settings.frameRate = 60
        settings.streamsAudio = true
        settings.videoQuality = .automatic
        XCTAssertEqual(AppDelegate.applying(settings, to: request, config: config,
                                            host: "100.101.102.103", overrides: [])?
                        .request.bitrate, 12_000_000)
    }

    // MARK: - The window

    func testTheWindowIsOneFixedSizeWindowCalledSettings() {
        let settingsWindow = SettingsWindow()
        let window = settingsWindow.window
        XCTAssertEqual(window.title, "Settings")
        XCTAssertFalse(window.styleMask.contains(.resizable))
        XCTAssertTrue(window.contentView === settingsWindow.pane)
        XCTAssertFalse(window.isReleasedWhenClosed, "closing it would lose the one instance")
        XCTAssertFalse(window.isVisible)
        // Opened from the popover of a full-screen stream, it joins that
        // Space rather than switching away from the game to show itself.
        XCTAssertTrue(window.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(window.collectionBehavior.contains(.moveToActiveSpace))
    }

    /// ⌘W closes it with Caps Lock on, and on a layout whose W key types
    /// another letter; ⌥⌘W and ⌘Q are left alone.
    func testCommandWClosesItOnAnyLayout() throws {
        let window = SettingsWindow().window
        func key(_ characters: String, keyCode: UInt16,
                 _ modifiers: NSEvent.ModifierFlags) throws -> NSEvent {
            try XCTUnwrap(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: modifiers,
                                           timestamp: 0, windowNumber: 0, context: nil,
                                           characters: characters,
                                           charactersIgnoringModifiers: characters,
                                           isARepeat: false, keyCode: keyCode))
        }
        XCTAssertTrue(window.performKeyEquivalent(with: try key("w", keyCode: 13, .command)))
        XCTAssertTrue(window.performKeyEquivalent(with: try key("W", keyCode: 13, [.command, .capsLock])))
        XCTAssertTrue(window.performKeyEquivalent(with: try key("ц", keyCode: 13, .command)),
                      "Cyrillic: the W key types ц")
        XCTAssertFalse(window.performKeyEquivalent(with: try key("w", keyCode: 13, [.command, .option])))
        XCTAssertFalse(window.performKeyEquivalent(with: try key("q", keyCode: 12, .command)))
    }

    // MARK: - The picture

    /// Laid out, nothing cut off or overlapping, small enough for a 13-inch
    /// MacBook -- and photographed for whoever changes it next: both themes,
    /// and the dark one again with the rows that do not apply disabled.
    func testThePaneFitsAndIsPhotographed() throws {
        settings.videoQuality = .automatic
        settings.frameRate = 60
        settings.streamsAudio = true
        settings.volume = 0.8
        settings.isMuted = false
        settings.audioBuffering = .automatic
        settings.pointerMode = .gaming
        settings.gamingSensitivity = 1
        settings.followsHostCursor = true
        settings.syncsClipboard = true
        try photograph("solstream-settings.png", theme: .darkAqua)
        try photograph("solstream-settings-light.png", theme: .aqua)

        settings.streamsAudio = false
        settings.isMuted = true
        settings.pointerMode = .desktop
        try photograph("solstream-settings-disabled.png", theme: .darkAqua)
    }

    private func photograph(_ name: String, theme: NSAppearance.Name,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let appearance = try XCTUnwrap(NSAppearance(named: theme))
        let pane = SettingsPane()
        pane.appearance = appearance
        let size = pane.fittingSize
        XCTAssertLessThanOrEqual(size.height, 720, "too tall for a 13-inch MacBook",
                                 file: file, line: line)
        XCTAssertLessThanOrEqual(size.width, 820, file: file, line: line)

        let backdrop = NSView(frame: NSRect(origin: .zero, size: size))
        backdrop.appearance = appearance
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = DS.resolved(DS.ground, in: appearance)
        pane.frame = backdrop.bounds
        backdrop.addSubview(pane)
        backdrop.layoutSubtreeIfNeeded()

        let controls: [NSView] = [
            pane.qualityPopUp, pane.qualityDetail, pane.frameRateControl, pane.soundSwitch,
            pane.muteButton, pane.volumeSlider, pane.volumeValue, pane.bufferingPopUp,
            pane.bufferingDetail, pane.modeControl, pane.modeDetail, pane.sensitivitySlider,
            pane.sensitivityValue, pane.followsCursorSwitch, pane.clipboardSwitch, pane.footnote,
        ]
        let frames = controls.map { $0.convert($0.bounds, to: pane) }
        for (control, frame) in zip(controls, frames) {
            XCTAssertFalse(frame.isEmpty, "\(type(of: control)) has no size", file: file, line: line)
            XCTAssertTrue(pane.bounds.insetBy(dx: DS.Metric.inset - 1, dy: 0).contains(frame),
                          "\(type(of: control)) is cut off or outside the inset",
                          file: file, line: line)
        }
        for (index, a) in frames.enumerated() {
            for b in frames[(index + 1)...]
            where a.insetBy(dx: 1, dy: 1).intersects(b.insetBy(dx: 1, dy: 1)) {
                XCTFail("controls overlap: \(a) and \(b)", file: file, line: line)
            }
        }

        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale),
            pixelsHigh: Int(size.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = size
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: - Helpers

    private func choose(_ popUp: NSPopUpButton, _ index: Int) {
        popUp.selectItem(at: index)
        send(popUp)
    }

    private func send(_ control: NSControl) {
        XCTAssertNotNil(control.action, "\(type(of: control)) has no action")
        control.sendAction(control.action, to: control.target)
    }
}
