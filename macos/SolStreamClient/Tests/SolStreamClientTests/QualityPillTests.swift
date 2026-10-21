import AppKit
import XCTest
import InputCapture
@testable import SolStreamClient

/// The stats popover carries the stream's quick settings -- sound, mouse mode,
/// quality -- and a way to the rest. Each has to be there, inside the popover's
/// edge, and do what it says when used.
final class QualityPillTests: XCTestCase {

    /// The defaults these tests write through StreamSettings and InputCapture,
    /// put back afterwards so running the tests changes nobody's settings.
    private static let touchedKeys = [
        "SolStream.volume", "SolStream.muted", "SolStream.streamsAudio",
        "SolStream.videoQuality", "SolStream.pointerMode", "SolStream.followsHostCursor",
    ]
    private var saved: [String: Any] = [:]

    override func setUp() {
        super.setUp()
        let defaults = UserDefaults.standard
        saved = [:]
        for key in Self.touchedKeys {
            if let value = defaults.object(forKey: key) { saved[key] = value }
        }
        let settings = StreamSettings.shared
        settings.volume = 0.7
        settings.isMuted = false
        settings.streamsAudio = true
        settings.videoQuality = .automatic
        settings.pointerMode = .desktop
        settings.followsHostCursor = true
        QualityPill.commandLineOverrides = []
    }

    override func tearDown() {
        let defaults = UserDefaults.standard
        for key in Self.touchedKeys {
            if let value = saved[key] {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
        QualityPill.commandLineOverrides = []
        super.tearDown()
    }

    func testThePopoverOffersItsControlsAndFitsThem() throws {
        let detail = detail()

        XCTAssertEqual(detail.bounds.width, QualityPill.detailWidth)
        // A popover hangs from a title bar; past this it starts to cover the
        // application it describes on a laptop screen.
        XCTAssertLessThanOrEqual(detail.bounds.height, 460, "the popover has grown too tall")

        let toggles = Self.all(SolarSegments.self, in: detail)
        XCTAssertEqual(toggles.count, 1, "no mouse-mode toggle in the popover")
        XCTAssertEqual(toggles.first?.segmentCount, 2)

        let sliders = Self.all(NSSlider.self, in: detail)
        XCTAssertEqual(sliders.count, 1, "no volume slider in the popover")
        XCTAssertEqual(sliders.first?.doubleValue ?? 0, 70, accuracy: 0.01)
        XCTAssertEqual(sliders.first?.isContinuous, true, "the volume must follow the drag")

        let menus = Self.all(NSPopUpButton.self, in: detail)
        XCTAssertEqual(menus.count, 1, "no quality menu in the popover")
        XCTAssertEqual(menus.first?.numberOfItems, StreamSettings.VideoQuality.allCases.count)
        XCTAssertEqual(menus.first?.titleOfSelectedItem, StreamSettings.VideoQuality.automatic.title)

        let mute = try XCTUnwrap(Self.muteButton(in: detail), "no mute button in the popover")
        let link = try XCTUnwrap(Self.settingsLink(in: detail), "no way to Settings in the popover")

        Self.assertInside(detail, toggles + sliders + menus + [mute, link])

        // The settings rows' controls share one column.
        let columns = [toggles.first, sliders.first?.superview, menus.first].compactMap { $0 }
        let lefts = columns.map { $0.convert($0.bounds, to: detail).minX }
        XCTAssertEqual(Set(lefts.map { $0.rounded() }).count, 1, "the controls do not line up: \(lefts)")

        try Self.writePicture(of: detail, named: "solstream-quality-popover.png")
    }

    func testMovingTheVolumeSetsItAndUnmutes() throws {
        StreamSettings.shared.isMuted = true
        let detail = detail()
        let slider = try XCTUnwrap(Self.all(NSSlider.self, in: detail).first)
        let mute = try XCTUnwrap(Self.muteButton(in: detail))
        XCTAssertEqual(mute.accessibilityLabel(), "Unmute")
        try Self.writePicture(of: detail, named: "solstream-quality-popover-muted.png")

        slider.doubleValue = 35
        slider.sendAction(slider.action, to: slider.target)

        XCTAssertEqual(StreamSettings.shared.volume, 0.35, accuracy: 0.001)
        XCTAssertFalse(StreamSettings.shared.isMuted, "dragging the volume left it muted")
        XCTAssertEqual(mute.accessibilityLabel(), "Mute")
    }

    func testTheMuteButtonMutesAndNeverUnmutesIntoSilence() throws {
        StreamSettings.shared.volume = 0
        let detail = detail()
        let slider = try XCTUnwrap(Self.all(NSSlider.self, in: detail).first)
        let mute = try XCTUnwrap(Self.muteButton(in: detail))

        mute.sendAction(mute.action, to: mute.target)
        XCTAssertTrue(StreamSettings.shared.isMuted)
        XCTAssertEqual(mute.accessibilityLabel(), "Unmute")

        mute.sendAction(mute.action, to: mute.target)
        XCTAssertFalse(StreamSettings.shared.isMuted)
        XCTAssertEqual(StreamSettings.shared.volume, 0.5, "unmuted at zero volume, so still silent")
        XCTAssertEqual(slider.doubleValue, 50, accuracy: 0.01)
    }

    func testWithSoundOffTheSoundControlsStandDown() throws {
        StreamSettings.shared.streamsAudio = false
        let detail = detail(audioActive: false)
        XCTAssertEqual(Self.all(NSSlider.self, in: detail).first?.isEnabled, false)
        XCTAssertEqual(Self.muteButton(in: detail)?.isEnabled, false)
        XCTAssertTrue(Self.words(in: detail).contains("Off in Settings, so the PC sends none."),
                      "with sound off the popover still blames the PC for the silence")

        // --no-audio wins over Settings, and is the reason given.
        StreamSettings.shared.streamsAudio = true
        QualityPill.commandLineOverrides = [.audio]
        let flagged = self.detail(audioActive: false)
        XCTAssertEqual(Self.all(NSSlider.self, in: flagged).first?.isEnabled, false)
        XCTAssertTrue(Self.words(in: flagged).contains("Off for this run, by --no-audio."))
    }

    func testMutedIsSaidInWordsAndFollowsTheControls() throws {
        StreamSettings.shared.isMuted = true
        let detail = detail()
        // Mute is remembered across launches: the stream may be playing to a
        // Mac that was told to be quiet yesterday.
        XCTAssertTrue(Self.words(in: detail).contains("Muted on this Mac. The PC is still playing."),
                      "a muted stream reads as playing")
        XCTAssertFalse(Self.words(in: detail).contains("Audio"),
                       "the sound is named twice, once as Audio and once as Sound")

        let slider = try XCTUnwrap(Self.all(NSSlider.self, in: detail).first)
        slider.doubleValue = 40
        slider.sendAction(slider.action, to: slider.target)
        XCTAssertTrue(Self.words(in: detail).contains("Playing from the PC."))
        XCTAssertEqual(pills.last?.accessibilityValue() as? String, "60 frames per second")

        let mute = try XCTUnwrap(Self.muteButton(in: detail))
        mute.sendAction(mute.action, to: mute.target)
        XCTAssertTrue(Self.words(in: detail).contains("Muted on this Mac. The PC is still playing."))
        Self.assertInside(detail, [try XCTUnwrap(Self.settingsLink(in: detail))])
    }

    func testTheMouseToggleSwitchesTheModeAndSaysHowToGetTheMouseBack() throws {
        let detail = detail()
        let toggle = try XCTUnwrap(Self.all(SolarSegments.self, in: detail).first)
        XCTAssertEqual(toggle.selectedSegment, 0)

        var restarts: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: StreamSettings.didChange, object: nil, queue: nil
        ) { note in
            restarts.append(note.userInfo?[StreamSettings.restartsStreamKey] as? Bool ?? true)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        toggle.choose(1)
        XCTAssertEqual(InputCapture.pointerMode, .gaming)
        XCTAssertEqual(restarts, [false], "the mouse mode applies to the running stream, once")
        XCTAssertTrue(Self.words(in: detail).contains { $0.hasPrefix("Click in the window to capture the mouse") },
                      "the gaming hint is missing or still describes desktop mode")
        Self.assertInside(detail, [try XCTUnwrap(Self.settingsLink(in: detail))])
        XCTAssertLessThanOrEqual(detail.bounds.height, 460)

        toggle.choose(0)
        XCTAssertEqual(InputCapture.pointerMode, .desktop)
        XCTAssertTrue(Self.words(in: detail).contains { $0.hasPrefix("The PC's pointer goes exactly") })
    }

    func testTheGamingHintPromisesTheMenusOnlyOnceTheHostReportsItsCursor() throws {
        StreamSettings.shared.pointerMode = .gaming
        let detail = detail()
        let pill = try XCTUnwrap(pills.last)
        // A host that has not said "hidden" and then shown a cursor -- one
        // older than the report -- keeps the mouse captured through a pause
        // menu, so the menus are not promised.
        XCTAssertTrue(Self.words(in: detail).contains { $0.hasPrefix("Click in the window") })
        XCTAssertFalse(Self.words(in: detail).contains { $0.contains("menus") })

        pill.stats.hostReportsCursor = true
        let following = Self.words(in: detail).first { $0.contains("gives it back in its menus") }
        XCTAssertNotNil(following, "the hint did not follow what the host has shown it can do")
        Self.assertInside(detail, [try XCTUnwrap(Self.settingsLink(in: detail))])
        try Self.writePicture(of: detail, named: "solstream-quality-popover-gaming.png")

        // Turned off in Settings, it is clicks and ⌃⌥ again, whatever the host can do.
        StreamSettings.shared.followsHostCursor = false
        let unchanged = pill.stats
        pill.stats = unchanged  // the next once-a-second sample
        XCTAssertTrue(Self.words(in: detail).contains { $0.hasPrefix("Click in the window") })
    }

    func testAnOpenPopoverKeepsItsFiguresCurrent() throws {
        let detail = detail()
        let pill = try XCTUnwrap(pills.last)
        XCTAssertTrue(Self.words(in: detail).contains("18 Mbps"))

        // As after choosing High: the stream restarts under the open popover.
        var stats = pill.stats
        stats.fps = 30
        stats.bitrateMbps = 34.6
        stats.latencyMs = 14
        stats.audioActive = false
        pill.stats = stats

        let words = Self.words(in: detail)
        XCTAssertTrue(words.contains("35 Mbps"), "the bandwidth is still the one it opened with: \(words)")
        XCTAssertTrue(words.contains("30"))
        XCTAssertTrue(words.contains("14 ms"))
        XCTAssertTrue(words.contains("Nothing playing on the PC right now."))
    }

    func testABitrateFromTheCommandLineHoldsTheQualityMenu() throws {
        QualityPill.commandLineOverrides = [.bitrate]
        let detail = detail()
        let menu = try XCTUnwrap(Self.all(NSPopUpButton.self, in: detail).first)
        XCTAssertFalse(menu.isEnabled, "a choice that --bitrate overrides is still offered")
        XCTAssertTrue(Self.words(in: detail).contains("Set by --bitrate for this run."))
    }

    func testChoosingAQualityStoresItOnceAndSaysWhatItMeans() throws {
        let detail = detail()
        let menu = try XCTUnwrap(Self.all(NSPopUpButton.self, in: detail).first)

        var restarts: [Bool] = []
        let observer = NotificationCenter.default.addObserver(
            forName: StreamSettings.didChange, object: nil, queue: nil
        ) { note in
            restarts.append(note.userInfo?[StreamSettings.restartsStreamKey] as? Bool ?? false)
        }
        defer { NotificationCenter.default.removeObserver(observer) }

        menu.selectItem(withTitle: StreamSettings.VideoQuality.high.title)
        menu.sendAction(menu.action, to: menu.target)
        XCTAssertEqual(StreamSettings.shared.videoQuality, .high)
        XCTAssertEqual(restarts, [true], "a new quality must ask for the stream to restart")

        let notes = Self.all(NSTextField.self, in: detail).map(\.stringValue)
        XCTAssertTrue(notes.contains { $0.hasPrefix(StreamSettings.VideoQuality.high.detail) },
                      "the note under the menu still describes the old quality")

        // Choosing it again is not a change, and must not blink the picture.
        menu.sendAction(menu.action, to: menu.target)
        XCTAssertEqual(restarts, [true])
    }

    func testTheSettingsLinkAsksForTheSettingsWindow() throws {
        let detail = detail()
        let link = try XCTUnwrap(Self.settingsLink(in: detail))
        let asked = expectation(forNotification: StreamSettings.openSettingsRequest, object: nil)
        link.sendAction(link.action, to: link.target)
        wait(for: [asked], timeout: 1)
    }

    // MARK: - Helpers

    /// The pills behind each test's popovers. The controls' target is the
    /// pill and AppKit holds targets weakly, so something else has to.
    private var pills: [QualityPill] = []

    private func detail(audioActive: Bool = true) -> NSView {
        let pill = QualityPill()
        var stats = QualityPill.Stats()
        stats.fps = 60
        stats.latencyMs = 9
        stats.bitrateMbps = 18
        stats.droppedFrames = 3
        stats.totalFrames = 48_210
        stats.audioActive = audioActive
        stats.hostDisplay = "DISPLAY7 · 2560×1440"
        pill.stats = stats
        pills.append(pill)
        let detail = pill.buildDetail()
        detail.appearance = NSAppearance(named: .darkAqua)
        return detail
    }

    private static func muteButton(in view: NSView) -> NSButton? {
        all(NSButton.self, in: view).first {
            !($0 is NSPopUpButton) && ["Mute", "Unmute"].contains($0.accessibilityLabel() ?? "")
        }
    }

    private static func settingsLink(in view: NSView) -> NSButton? {
        all(NSButton.self, in: view).first { $0.title == "All settings" }
    }

    private static func words(in view: NSView) -> [String] {
        all(NSTextField.self, in: view).map(\.stringValue)
    }

    /// Each of `controls` has a size and lies wholly inside the popover.
    private static func assertInside(_ detail: NSView, _ controls: [NSView],
                                     file: StaticString = #filePath, line: UInt = #line) {
        detail.layoutSubtreeIfNeeded()
        for control in controls {
            let frame = control.convert(control.bounds, to: detail)
            XCTAssertFalse(frame.isEmpty, "\(type(of: control)) has no size", file: file, line: line)
            XCTAssertTrue(detail.bounds.contains(frame),
                          "\(type(of: control)) is cut off by the popover's edge", file: file, line: line)
        }
    }

    /// A picture to look at, for whoever changes this layout next, on the dark
    /// ground the real popover has.
    private static func writePicture(of detail: NSView, named name: String) throws {
        let backdrop = NSView(frame: detail.bounds)
        backdrop.appearance = NSAppearance(named: .darkAqua)
        backdrop.wantsLayer = true
        backdrop.layer?.backgroundColor = NSColor(white: 0.16, alpha: 1).cgColor
        backdrop.addSubview(detail)
        backdrop.layoutSubtreeIfNeeded()
        guard let rep = backdrop.bitmapImageRepForCachingDisplay(in: backdrop.bounds) else { return }
        backdrop.cacheDisplay(in: backdrop.bounds, to: rep)
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(name)
        try rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    private static func all<T: NSView>(_ type: T.Type, in view: NSView) -> [T] {
        view.subviews.flatMap { ($0 as? T).map { [$0] } ?? [] + all(type, in: $0) }
    }
}
