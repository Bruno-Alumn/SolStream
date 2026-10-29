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
        "SolStream.videoQuality", "SolStream.frameRate", "SolStream.videoCodec",
        "SolStream.streamsAudio",
        "SolStream.soundQuality", "SolStream.soundSource",
        "SolStream.volume", "SolStream.muted", "SolStream.audioBuffering",
        "SolStream.syncsClipboard", "SolStream.pointerMode",
        "SolStream.gamingSensitivity", "SolStream.followsHostCursor",
    ]
    private var saved: [String: Any] = [:]
    private let settings = StreamSettings.shared
    /// The Updates card's own defaults, so nothing it shows or remembers is
    /// the real app's. Kept in a temporary folder by path: a named suite
    /// leaves its plist in ~/Library/Preferences after every run.
    private let updaterFolder = FileManager.default.temporaryDirectory
        .appendingPathComponent("solstream-settings-defaults-\(UUID().uuidString)", isDirectory: true)
    private var updaterSuite: String { updaterFolder.appendingPathComponent("defaults").path }

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
        UserDefaults().removePersistentDomain(forName: updaterSuite)
        try? FileManager.default.removeItem(at: updaterFolder)
        super.tearDown()
    }

    /// An updater that never checks anything: no stub, no network, no bundle
    /// to replace -- its state is set by hand. Every way it has out of the
    /// test runner fails the test instead, so a later change that gives it
    /// something to install cannot quit the runner or open Finder.
    @MainActor
    private func makeUpdater() -> Updater {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubProtocol.self]
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("solstream-settings-updates-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: updaterFolder, withIntermediateDirectories: true)
        let updater = Updater(defaults: UserDefaults(suiteName: updaterSuite)!, configuration: configuration,
                              environment: ["SOLSTREAM_PRETEND_VERSION": "1.0.0"],
                              installTarget: nil, publicKey: UpdateSignature.productionKey,
                              downloadsFolder: scratch.appendingPathComponent("update-cache"),
                              revealFolder: scratch.appendingPathComponent("Revealed"))
        updater.relaunch = { _ in XCTFail("a test tried to relaunch") }
        updater.terminate = { XCTFail("a test tried to quit") }
        updater.showInFinder = { _ in XCTFail("a test tried to open Finder") }
        return updater
    }

    // MARK: - Reading

    @MainActor
    func testEveryControlShowsTheSettingsAsTheyAre() {
        settings.videoQuality = .high
        settings.frameRate = 30
        settings.videoCodec = .h264
        settings.streamsAudio = true
        settings.soundSource = .wholePC
        settings.soundQuality = .standard
        settings.volume = 0.4
        settings.isMuted = false
        settings.audioBuffering = .steady
        settings.pointerMode = .gaming
        settings.gamingSensitivity = 2
        settings.followsHostCursor = false
        settings.syncsClipboard = false

        let pane = SettingsPane(updater: makeUpdater())
        XCTAssertEqual(pane.qualityPopUp.titleOfSelectedItem, "High")
        XCTAssertEqual(pane.qualityDetail.stringValue, StreamSettings.VideoQuality.high.detail)
        XCTAssertEqual(pane.frameRateControl.segmentCount, 2)
        XCTAssertEqual(pane.frameRateControl.label(forSegment: pane.frameRateControl.selectedSegment),
                       "30 fps")
        XCTAssertEqual(pane.codecPopUp.itemTitles, ["Automatic", "H.264", "HEVC"])
        XCTAssertEqual(pane.codecPopUp.titleOfSelectedItem, "H.264")
        XCTAssertEqual(pane.codecPopUp.toolTip, StreamSettings.VideoCodecChoice.h264.detail)
        XCTAssertTrue(pane.soundSwitch.isOn)
        XCTAssertEqual(pane.soundSourceControl.segmentCount, 2)
        XCTAssertEqual(pane.soundSourceControl.label(forSegment: pane.soundSourceControl.selectedSegment),
                       "Whole PC")
        XCTAssertEqual(pane.soundSourceDetail.stringValue, StreamSettings.SoundSource.wholePC.detail)
        XCTAssertTrue(pane.soundSourceControl.isEnabled)
        XCTAssertEqual(pane.soundQualityPopUp.itemTitles,
                       ["Data saver", "Standard", "High", "Lossless"], "least to most, as the video's")
        XCTAssertEqual(pane.soundQualityPopUp.titleOfSelectedItem, "Standard")
        XCTAssertEqual(pane.soundQualityDetail.stringValue, StreamSettings.SoundQuality.standard.detail)
        XCTAssertTrue(pane.soundQualityPopUp.isEnabled)
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
    /// sound quality, volume and buffering with the PC's sound off,
    /// sensitivity and giving the mouse back in desktop mode.
    @MainActor
    func testRowsThatDoNotApplyAreDisabled() {
        settings.streamsAudio = false
        settings.isMuted = true
        settings.pointerMode = .desktop
        settings.followsHostCursor = true
        settings.syncsClipboard = true

        let pane = SettingsPane(updater: makeUpdater())
        XCTAssertFalse(pane.soundSwitch.isOn)
        XCTAssertFalse(pane.soundSourceControl.isEnabled)
        XCTAssertFalse(pane.soundQualityPopUp.isEnabled)
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
    @MainActor
    func testItFollowsChangesMadeElsewhere() {
        settings.volume = 1
        settings.isMuted = false
        settings.pointerMode = .desktop
        let pane = SettingsPane(updater: makeUpdater())

        settings.volume = 0.2
        XCTAssertEqual(pane.volumeSlider.doubleValue, 20, accuracy: 0.01)
        settings.isMuted = true
        XCTAssertEqual(pane.volumeValue.stringValue, "Muted")
        settings.videoQuality = .dataSaver
        XCTAssertEqual(pane.qualityPopUp.titleOfSelectedItem, "Data saver")
        settings.soundQuality = .lossless
        XCTAssertEqual(pane.soundQualityPopUp.titleOfSelectedItem, "Lossless")
        settings.soundSource = .wholePC
        XCTAssertEqual(pane.soundSourceControl.selectedSegment, 1)
        InputCapture.pointerMode = .gaming
        XCTAssertEqual(pane.modeControl.selectedSegment, 1)
        XCTAssertTrue(pane.sensitivitySlider.isEnabled)
    }

    // MARK: - Writing

    @MainActor
    func testEachControlWritesItsSettingAndSaysWhetherTheStreamRestarts() {
        settings.videoQuality = .automatic
        settings.frameRate = 60
        settings.videoCodec = .automatic
        settings.streamsAudio = true
        settings.soundSource = .streamedApps
        settings.soundQuality = .high
        settings.volume = 1
        settings.isMuted = false
        settings.audioBuffering = .automatic
        settings.pointerMode = .desktop
        settings.gamingSensitivity = 1
        settings.followsHostCursor = true
        settings.syncsClipboard = true
        let pane = SettingsPane(updater: makeUpdater())

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

        // The host's encoder is chosen when the session opens.
        choose(pane.codecPopUp, StreamSettings.VideoCodecChoice.allCases.firstIndex(of: .hevc)!)
        XCTAssertEqual(settings.videoCodec, .hevc)
        XCTAssertEqual(pane.codecPopUp.toolTip, StreamSettings.VideoCodecChoice.hevc.detail)
        expect(restart: true, "video codec")
        choose(pane.codecPopUp, StreamSettings.VideoCodecChoice.allCases.firstIndex(of: .hevc)!)
        XCTAssertTrue(restarts.isEmpty, "re-choosing the codec restarted the stream")

        pane.soundSourceControl.selectedSegment = 1
        send(pane.soundSourceControl)
        XCTAssertEqual(settings.soundSource, .wholePC)
        XCTAssertEqual(pane.soundSourceDetail.stringValue, StreamSettings.SoundSource.wholePC.detail)
        expect(restart: true, "sound source")
        send(pane.soundSourceControl)
        XCTAssertTrue(restarts.isEmpty, "re-choosing the sound source restarted the stream")

        choose(pane.soundQualityPopUp, StreamSettings.SoundQuality.allCases.firstIndex(of: .dataSaver)!)
        XCTAssertEqual(settings.soundQuality, .dataSaver)
        XCTAssertEqual(pane.soundQualityDetail.stringValue, StreamSettings.SoundQuality.dataSaver.detail)
        expect(restart: true, "sound quality")
        choose(pane.soundQualityPopUp, StreamSettings.SoundQuality.allCases.firstIndex(of: .dataSaver)!)
        XCTAssertTrue(restarts.isEmpty, "re-choosing the sound quality restarted the stream")

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
        XCTAssertFalse(pane.soundQualityPopUp.isEnabled, "quality still enabled with the sound off")
        XCTAssertFalse(pane.soundSourceControl.isEnabled, "source still enabled with the sound off")
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
    @MainActor
    func testSlidersSayTheirValuesInTheirOwnUnits() {
        settings.pointerMode = .gaming
        settings.gamingSensitivity = 0.5
        settings.streamsAudio = true
        settings.volume = 0.8
        settings.isMuted = false
        let pane = SettingsPane(updater: makeUpdater())
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
        // H.264 alone: what a config made without a codec already has.
        settings.videoCodec = .h264
        settings.streamsAudio = true
        settings.soundQuality = .high
        settings.soundSource = .streamedApps
        var request = AgentConnection.MediaRequest(display: "\\\\.\\DISPLAY9", fps: 60,
                                                   bitrate: 20_000_000, audio: true,
                                                   audioEncoding: .opus(bitrate: 256_000,
                                                                        frameMilliseconds: 10))
        request.width = 3024
        request.height = 1964
        request.audioSource = .apps
        let config = StreamConfig(width: 3024, height: 1964, frameRate: 60,
                                  bitrateKbps: 20_000, audio: true,
                                  audioEncoding: .opus(bitrate: 256_000, frameMilliseconds: 10),
                                  audioSource: .apps)

        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config,
                                          host: "192.168.1.20", overrides: []),
                     "Balanced and High at home are what the stream already has")

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

    /// The sound's quality restarts the stream like the picture's does --
    /// but only while there is sound for the host to encode.
    func testSoundQualityRestartsTheStreamOnlyWhileThereIsSound() {
        settings.videoQuality = .balanced
        settings.frameRate = 60
        // H.264 alone: what a config made without a codec already has.
        settings.videoCodec = .h264
        settings.streamsAudio = true
        settings.soundQuality = .high
        settings.soundSource = .streamedApps
        let high = StreamSettings.SoundQuality.high.encoding
        let request = AgentConnection.MediaRequest(display: "\\\\.\\DISPLAY9", fps: 60,
                                                   bitrate: 20_000_000, audio: true,
                                                   audioEncoding: high, audioSource: .apps)
        let config = StreamConfig(frameRate: 60, bitrateKbps: 20_000, audio: true,
                                  audioEncoding: high, audioSource: .apps)
        let home = "192.168.1.20"
        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config,
                                          host: home, overrides: []))

        settings.soundQuality = .dataSaver
        let saver = AppDelegate.applying(settings, to: request, config: config,
                                         host: home, overrides: [])
        XCTAssertEqual(saver?.request.audioEncoding, .opus(bitrate: 64_000, frameMilliseconds: 20))
        XCTAssertEqual(saver?.config.audioEncoding, .opus(bitrate: 64_000, frameMilliseconds: 20))
        XCTAssertEqual(saver?.request.fps, 60, "nothing else moved")

        settings.soundQuality = .lossless
        XCTAssertEqual(AppDelegate.applying(settings, to: request, config: config,
                                            host: home, overrides: [])?.request.audioEncoding,
                       .pcm)

        // --sound-quality on the command line wins over the window.
        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config,
                                          host: home, overrides: [.soundQuality]))

        // With the sound off there is nothing to encode, so a new quality is
        // no reason to blank the picture...
        var silent = config
        silent.audio = false
        var silentRequest = request
        silentRequest.audio = false
        settings.streamsAudio = false
        settings.soundQuality = .standard
        XCTAssertNil(AppDelegate.applying(settings, to: silentRequest, config: silent,
                                          host: home, overrides: []))
        // ...and turning it back on brings the quality chosen meanwhile.
        settings.streamsAudio = true
        let back = AppDelegate.applying(settings, to: silentRequest, config: silent,
                                        host: home, overrides: [])
        XCTAssertEqual(back?.request.audio, true)
        XCTAssertEqual(back?.request.audioEncoding, .opus(bitrate: 128_000, frameMilliseconds: 10))
    }

    /// Whose sound it is restarts the stream too, while there is sound, and
    /// what --sound-from set stays set.
    func testTheSoundSourceRestartsTheStreamOnlyWhileThereIsSound() {
        settings.videoQuality = .balanced
        settings.frameRate = 60
        // H.264 alone: what a config made without a codec already has.
        settings.videoCodec = .h264
        settings.streamsAudio = true
        settings.soundQuality = .high
        settings.soundSource = .streamedApps
        let high = StreamSettings.SoundQuality.high.encoding
        let request = AgentConnection.MediaRequest(fps: 60, bitrate: 20_000_000, audio: true,
                                                   audioEncoding: high, audioSource: .apps)
        let config = StreamConfig(frameRate: 60, bitrateKbps: 20_000, audio: true,
                                  audioEncoding: high, audioSource: .apps)
        let home = "192.168.1.20"
        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config,
                                          host: home, overrides: []))

        settings.soundSource = .wholePC
        let whole = AppDelegate.applying(settings, to: request, config: config,
                                         host: home, overrides: [])
        XCTAssertEqual(whole?.request.audioSource, .system)
        XCTAssertEqual(whole?.config.audioSource, .system)
        XCTAssertEqual(whole?.request.audioEncoding, high, "nothing else moved")
        XCTAssertNil(AppDelegate.applying(settings, to: request, config: config,
                                          host: home, overrides: [.soundSource]))

        var silent = config
        silent.audio = false
        var silentRequest = request
        silentRequest.audio = false
        settings.streamsAudio = false
        XCTAssertNil(AppDelegate.applying(settings, to: silentRequest, config: silent,
                                          host: home, overrides: []),
                     "with the sound off, whose sound it is restarted the picture")
    }

    // MARK: - The window

    @MainActor
    func testTheWindowIsOneFixedSizeWindowCalledSettings() {
        let settingsWindow = SettingsWindow(updater: makeUpdater())
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

    /// On a screen too short for it, the pane scrolls rather than run under
    /// the Dock, starting at its heading; on one tall enough it is whole
    /// again, with no scroll view left behind.
    @MainActor
    func testAScreenTooShortForThePaneScrollsIt() throws {
        let settingsWindow = SettingsWindow(updater: makeUpdater())
        let window = settingsWindow.window
        let pane = settingsWindow.pane
        let size = pane.fittingSize

        settingsWindow.fit(height: size.height + 100)
        XCTAssertTrue(window.contentView === pane, "a tall enough screen got a scroll view")

        settingsWindow.fit(height: 600)
        let scroll = try XCTUnwrap(window.contentView as? NSScrollView)
        XCTAssertTrue(scroll.documentView === pane)
        XCTAssertEqual(scroll.frame.height, 600, accuracy: 0.5, "taller than the screen")
        XCTAssertEqual(pane.frame.size.height, size.height, accuracy: 0.5, "the pane was squashed")
        XCTAssertEqual(scroll.contentView.bounds.maxY, pane.frame.maxY, accuracy: 0.5,
                       "opened somewhere other than its heading")
        XCTAssertFalse(scroll.drawsBackground)

        settingsWindow.fit(height: size.height)
        XCTAssertTrue(window.contentView === pane)
        XCTAssertNil(scroll.documentView)
        XCTAssertEqual(pane.frame.height, size.height, accuracy: 0.5)
    }

    /// ⌘W closes it with Caps Lock on, and on a layout whose W key types
    /// another letter; ⌥⌘W and ⌘Q are left alone.
    @MainActor
    func testCommandWClosesItOnAnyLayout() throws {
        let window = SettingsWindow(updater: makeUpdater()).window
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
    @MainActor
    func testThePaneFitsAndIsPhotographed() throws {
        settings.videoQuality = .automatic
        settings.frameRate = 60
        settings.streamsAudio = true
        settings.soundQuality = .high
        settings.volume = 0.8
        settings.isMuted = false
        settings.audioBuffering = .automatic
        settings.pointerMode = .gaming
        settings.gamingSensitivity = 1
        settings.followsHostCursor = true
        settings.syncsClipboard = true
        let updater = makeUpdater()
        updater.state = .upToDate
        try photograph("solstream-settings.png", theme: .darkAqua, updater: updater)
        try photograph("solstream-settings-light.png", theme: .aqua, updater: updater)

        settings.streamsAudio = false
        settings.isMuted = true
        settings.pointerMode = .desktop
        try photograph("solstream-settings-disabled.png", theme: .darkAqua, updater: updater)
    }

    // MARK: - Updates

    /// The card says what the updater is doing, offers the one action that
    /// fits, and never moves while it does.
    @MainActor
    func testTheUpdatesCardFollowsTheUpdater() throws {
        let updater = makeUpdater()
        let pane = SettingsPane(updater: updater)
        pane.layoutSubtreeIfNeeded()
        let height = pane.fittingSize.height
        XCTAssertEqual(pane.versionLabel.stringValue, "Version 1.0.0")
        XCTAssertEqual(pane.updateStatus.stringValue, "Not checked yet.")
        XCTAssertFalse(pane.checkButton.isHidden)
        XCTAssertTrue(pane.checkButton.isEnabled)
        XCTAssertTrue(pane.installButton.isHidden)
        XCTAssertTrue(pane.automaticUpdatesSwitch.isOn, "on unless turned off")

        func expect(_ state: Updater.State, status: String, action: String?, enabled: Bool = true,
                    file: StaticString = #filePath, line: UInt = #line) {
            updater.state = state
            XCTAssertEqual(pane.updateStatus.stringValue, status, file: file, line: line)
            if let action {
                XCTAssertFalse(pane.installButton.isHidden, file: file, line: line)
                XCTAssertTrue(pane.checkButton.isHidden, file: file, line: line)
                XCTAssertEqual(pane.installButton.title, action, file: file, line: line)
                XCTAssertEqual(pane.installButton.isEnabled, enabled, file: file, line: line)
            } else {
                XCTAssertTrue(pane.installButton.isHidden, file: file, line: line)
                XCTAssertFalse(pane.checkButton.isHidden, file: file, line: line)
                XCTAssertEqual(pane.checkButton.isEnabled, enabled, file: file, line: line)
            }
            XCTAssertEqual(pane.fittingSize.height, height, "the card moved", file: file, line: line)
            XCTAssertTrue(statusFitsItsTwoLines(pane), "\(state) needs a third line",
                          file: file, line: line)
        }
        expect(.checking, status: "Checking…", action: nil, enabled: false)
        expect(.upToDate, status: "Up to date.", action: nil)
        expect(.available("1.1.0"), status: "Update 1.1.0 is available.", action: "Download")
        expect(.downloading("1.1.0", 0.34), status: "Downloading 1.1.0… 34%", action: nil, enabled: false)
        expect(.ready("1.1.0"), status: "Update 1.1.0 is ready to install.", action: "Install and relaunch")
        XCTAssertEqual(pane.installButton.style, .primary)
        updater.isStreaming = true
        XCTAssertEqual(pane.installButton.title, "Install after stream", "followed the stream opening")
        expect(.waitingForStream("1.1.0"), status: "Update 1.1.0 installs when the stream closes.",
               action: "Don't install")
        XCTAssertEqual(pane.installButton.style, .secondary)
        updater.isStreaming = false
        expect(.installing("1.1.0"), status: "Installing 1.1.0…", action: "Install and relaunch",
               enabled: false)
        expect(.manualInstall("1.1.0", reason: "SolStream can't replace itself here."),
               status: "SolStream can't replace itself here.", action: "Show download")
        expect(.failed("The update's signature didn't verify."),
               status: "The update's signature didn't verify.", action: nil)

        // Every reason a failure can give fits beside the button -- by a
        // measure that does say no to one that does not.
        updater.state = .failed(String(repeating: "A reason far too long ", count: 4))
        XCTAssertFalse(statusFitsItsTwoLines(pane))
        let reasons: [UpdateError] = [
            .transport(.offline), .transport(.timedOut), .transport(.refusedAddress("x")),
            .transport(.cannotWrite), .tooLarge, .http(503), .rateLimited,
            .malformedRelease, .missingAsset("x"), .badSignature, .malformedSums, .notInSums("x"),
            .checksumMismatch, .install(.wrongIdentifier(nil)), .install(.wrongVersion(nil)),
            .install(.signatureRejected("")), .install(.notAnApp), .install(.moveFailed("")),
            .install(.checksumMismatch), .install(.notNewer("10.10.10")), .transport(.cancelled),
        ]
        for reason in reasons {
            expect(.failed(reason.reason), status: reason.reason, action: nil)
        }
        let notWritable = UpdateError.install(.notWritable(URL(fileURLWithPath: "/Applications"))).reason
        expect(.manualInstall("10.10.10", reason: notWritable), status: notWritable, action: "Show download")
        updater.isStreaming = true
        expect(.ready("10.10.10"), status: "Update 10.10.10 is ready to install.",
               action: "Install after stream")
        // Nothing downloads during a stream, so no button offers to. This
        // updater has no bundle to install into, so nothing downloads after
        // it either, and the status does not say it will.
        expect(.available("10.10.10"), status: "Update 10.10.10 is available.", action: nil)
        expect(.waitingForStream("10.10.10"), status: "Update 10.10.10 installs when the stream closes.",
               action: "Don't install")
        expect(.installed("10.10.10"),
               status: "Update 10.10.10 is installed. Restarts after the stream.",
               action: nil, enabled: false)
        updater.isStreaming = false
        expect(.available("10.10.10"), status: "Update 10.10.10 is available.", action: "Download")

        XCTAssertTrue(pane.automaticUpdatesSwitch.accessibilityPerformPress())
        XCTAssertFalse(updater.checksAutomatically)
        XCTAssertTrue(pane.automaticUpdatesSwitch.accessibilityPerformPress())
        XCTAssertTrue(updater.checksAutomatically)
        XCTAssertEqual(pane.automaticUpdatesSwitch.accessibilityLabel(), "Check for updates automatically")
        XCTAssertEqual(pane.versionLabel.accessibilityLabel(), "SolStream version 1.0.0")
    }

    /// The card with an update ready, in both themes, for whoever changes it
    /// next; and a failure, whose words are the longest it shows.
    @MainActor
    func testTheUpdatesCardIsPhotographed() throws {
        let updater = makeUpdater()
        updater.state = .ready("1.1.0")
        try photograph("solstream-settings-updates.png", theme: .darkAqua, updater: updater,
                       cropToUpdates: true)
        try photograph("solstream-settings-updates-light.png", theme: .aqua, updater: updater,
                       cropToUpdates: true)
        updater.state = .failed("The new copy couldn't be moved into place.")
        try photograph("solstream-settings-updates-failed.png", theme: .darkAqua, updater: updater,
                       cropToUpdates: true)
    }

    @MainActor
    private func photograph(_ name: String, theme: NSAppearance.Name, updater: Updater,
                            cropToUpdates: Bool = false,
                            file: StaticString = #filePath, line: UInt = #line) throws {
        let appearance = try XCTUnwrap(NSAppearance(named: theme))
        let pane = SettingsPane(updater: updater)
        pane.appearance = appearance
        let size = pane.fittingSize
        // 1440x900, the smallest 13-inch MacBook, leaves about 800 points
        // between the menu bar and a Dock at its usual size. A shorter screen
        // gets a scroll view (`SettingsWindow.fit`); this keeps that rare.
        XCTAssertLessThanOrEqual(size.height, 770, "too tall for a 13-inch MacBook",
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
            pane.qualityPopUp, pane.qualityDetail, pane.frameRateControl,
            pane.codecPopUp, pane.soundSwitch,
            pane.soundSourceControl, pane.soundSourceDetail,
            pane.soundQualityPopUp, pane.soundQualityDetail,
            pane.muteButton, pane.volumeSlider, pane.volumeValue, pane.bufferingPopUp,
            pane.bufferingDetail, pane.modeControl, pane.modeDetail, pane.sensitivitySlider,
            pane.sensitivityValue, pane.followsCursorSwitch, pane.clipboardSwitch, pane.footnote,
            pane.versionLabel, pane.updateStatus, pane.automaticUpdatesSwitch,
            pane.installButton.isHidden ? pane.checkButton : pane.installButton,
        ]
        let frames = controls.map { $0.convert($0.bounds, to: pane) }
        for (control, frame) in zip(controls, frames) {
            XCTAssertFalse(frame.isEmpty, "\(type(of: control)) has no size", file: file, line: line)
            XCTAssertTrue(pane.bounds.insetBy(dx: DS.Metric.inset - 1, dy: 0).contains(frame),
                          "\(type(of: control)) \((control as? NSTextField)?.stringValue ?? "") "
                              + "is cut off or outside the inset: \(frame)",
                          file: file, line: line)
        }
        for (index, a) in frames.enumerated() {
            for b in frames[(index + 1)...]
            where a.insetBy(dx: 1, dy: 1).intersects(b.insetBy(dx: 1, dy: 1)) {
                XCTFail("controls overlap: \(a) and \(b)", file: file, line: line)
            }
        }

        // The status sits beside its button and within its two lines.
        let status = pane.updateStatus.convert(pane.updateStatus.bounds, to: pane)
        let action = pane.installButton.isHidden ? pane.checkButton : pane.installButton
        XCTAssertLessThan(status.maxX, action.convert(action.bounds, to: pane).minX,
                          "the update status runs under its button", file: file, line: line)
        XCTAssertTrue(statusFitsItsTwoLines(pane), "the update status needs a third line",
                      file: file, line: line)

        // The whole pane, or the Updates heading and card with an inset of
        // ground around them.
        var region = backdrop.bounds
        if cropToUpdates, let section = pane.updatesSection {
            region = section.convert(section.bounds, to: backdrop)
                .insetBy(dx: -DS.Space.x4, dy: -DS.Space.x4).intersection(backdrop.bounds)
        }
        let scale: CGFloat = 2
        let rep = try XCTUnwrap(NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(region.width * scale),
            pixelsHigh: Int(region.height * scale), bitsPerSample: 8, samplesPerPixel: 4,
            hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB,
            bytesPerRow: 0, bitsPerPixel: 0))
        rep.size = region.size
        backdrop.cacheDisplay(in: region, to: rep)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
    }

    // MARK: - Helpers

    /// Whether the update status, measured with no limit on its lines, needs
    /// no more than the two its row has room for beside the button. The label
    /// itself is limited to two, so asking it would always say yes.
    @MainActor
    private func statusFitsItsTwoLines(_ pane: SettingsPane) -> Bool {
        let probe = NSTextField(wrappingLabelWithString: pane.updateStatus.stringValue)
        probe.font = pane.updateStatus.font
        let width = pane.updateStatus.preferredMaxLayoutWidth
        let needed = probe.cell?.cellSize(forBounds: NSRect(x: 0, y: 0, width: width, height: 10_000))
            .height ?? .infinity
        return needed <= ceil(DS.body.boundingRectForFont.height) * 2 + 2
    }

    private func choose(_ popUp: NSPopUpButton, _ index: Int) {
        popUp.selectItem(at: index)
        send(popUp)
    }

    private func send(_ control: NSControl) {
        XCTAssertNotNil(control.action, "\(type(of: control)) has no action")
        control.sendAction(control.action, to: control.target)
    }
}
