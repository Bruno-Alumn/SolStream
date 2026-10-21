import Foundation
import AudioRenderer
import InputCapture
import MediaSession

/// Everything the person can choose about a stream, remembered across launches.
///
/// One place, so the Settings window, the popover on the streamed window and
/// the code that opens a stream all read the same values. Each change posts
/// `didChange` with `restartsStream` saying whether it can be applied to a
/// running stream as it is (volume, buffering, mouse, clipboard) or needs the
/// media session opened again (quality, frame rate, sound on or off), because
/// the host's encoder and audio capture are fixed when the session opens.
///
/// The mouse settings live in InputCapture, which owns the behaviour; they are
/// mirrored here so every setting has one address.
final class StreamSettings {
    static let shared = StreamSettings()

    static let didChange = Notification.Name("SolStream.streamSettingsChanged")
    /// In `didChange`'s userInfo: true when the change needs a new media session.
    static let restartsStreamKey = "restartsStream"
    /// Posted by anything that wants the Settings window shown -- the popover
    /// on a streamed window -- so only the app delegate needs to own it.
    static let openSettingsRequest = Notification.Name("SolStream.openSettings")

    private let defaults = UserDefaults.standard

    // MARK: - Video

    /// How many bits a second the PC may spend on the picture.
    enum VideoQuality: String, CaseIterable {
        case automatic, dataSaver, balanced, high, maximum

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .dataSaver: return "Data saver"
            case .balanced: return "Balanced"
            case .high: return "High"
            case .maximum: return "Maximum"
            }
        }

        /// One line saying what it is for, shown under the choice.
        var detail: String {
            switch self {
            case .automatic: return "20 Mbps on your home network, 12 Mbps over Tailscale."
            case .dataSaver: return "8 Mbps. Slow or metered connections; softer text."
            case .balanced: return "20 Mbps. Good Wi-Fi."
            case .high: return "35 Mbps. Fast Wi-Fi or a wired network."
            case .maximum: return "50 Mbps. Wired, both ends. Sharpest text and motion."
            }
        }

        /// The encoder's target, in kbit/s.
        ///
        /// Automatic decides by the path, not by measurement: a Tailscale
        /// address may be a relay on the far side of the internet, and the
        /// picture that survives a lossy remote path is a smaller one, so it
        /// starts lower there. A person on a fast remote path can pick higher.
        func bitrateKbps(remote: Bool) -> Int {
            switch self {
            case .automatic: return remote ? 12_000 : 20_000
            case .dataSaver: return 8_000
            case .balanced: return 20_000
            case .high: return 35_000
            case .maximum: return 50_000
            }
        }
    }

    var videoQuality: VideoQuality {
        get { defaults.string(forKey: Key.quality).flatMap(VideoQuality.init(rawValue:)) ?? .automatic }
        set { set(newValue.rawValue, Key.quality, restarts: true) }
    }

    /// 30 or 60. The capture display refreshes at 60 Hz, so more is not offered.
    static let frameRates = [30, 60]

    var frameRate: Int {
        get {
            let stored = defaults.integer(forKey: Key.frameRate)
            return Self.frameRates.contains(stored) ? stored : 60
        }
        set { set(Self.frameRates.contains(newValue) ? newValue : 60, Key.frameRate, restarts: true) }
    }

    // MARK: - Sound

    /// Whether the PC sends its sound at all. Off saves 1.5 Mbit/s and the
    /// PC's audio capture; volume and mute are the gentler controls.
    var streamsAudio: Bool {
        get { defaults.object(forKey: Key.audio) as? Bool ?? true }
        set { set(newValue, Key.audio, restarts: true) }
    }

    /// 0...1.
    var volume: Float {
        get { min(max(defaults.object(forKey: Key.volume) as? Float ?? 1, 0), 1) }
        set { set(min(max(newValue, 0), 1), Key.volume, restarts: false) }
    }

    var isMuted: Bool {
        get { defaults.bool(forKey: Key.muted) }
        set { set(newValue, Key.muted, restarts: false) }
    }

    enum AudioBufferingChoice: String, CaseIterable {
        case automatic, lowLatency, steady

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .lowLatency: return "Low latency"
            case .steady: return "Smooth"
            }
        }

        var detail: String {
            switch self {
            case .automatic: return "Low latency on your home network, smooth over Tailscale."
            case .lowLatency: return "Least delay. Wired or strong Wi-Fi."
            case .steady: return "A little more delay, no crackle on busy Wi-Fi or the internet."
            }
        }

        func resolved(remote: Bool) -> AudioRenderer.Buffering {
            switch self {
            case .automatic: return remote ? .steady : .lowLatency
            case .lowLatency: return .lowLatency
            case .steady: return .steady
            }
        }
    }

    var audioBuffering: AudioBufferingChoice {
        get { defaults.string(forKey: Key.buffering).flatMap(AudioBufferingChoice.init(rawValue:)) ?? .automatic }
        set { set(newValue.rawValue, Key.buffering, restarts: false) }
    }

    // MARK: - Mouse (owned by InputCapture)

    var pointerMode: InputCapture.PointerMode {
        get { InputCapture.pointerMode }
        set { InputCapture.pointerMode = newValue; announce(restarts: false) }
    }

    var gamingSensitivity: Double {
        get { InputCapture.gamingSensitivity }
        set { InputCapture.gamingSensitivity = newValue; announce(restarts: false) }
    }

    var followsHostCursor: Bool {
        get { InputCapture.followsHostCursor }
        set { InputCapture.followsHostCursor = newValue; announce(restarts: false) }
    }

    // MARK: - General

    /// Copy and paste between the Mac and the PC while a stream is open.
    var syncsClipboard: Bool {
        get { defaults.object(forKey: Key.clipboard) as? Bool ?? true }
        set { set(newValue, Key.clipboard, restarts: false) }
    }

    // MARK: - Applying

    /// Whether `host` is reached over Tailscale -- an address in
    /// 100.64.0.0/10 or a MagicDNS `*.ts.net` name -- and so possibly over the
    /// internet, for the Automatic choices.
    static func isRemote(host: String) -> Bool {
        let name = host.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        if name.hasSuffix(".ts.net") { return true }
        let parts = name.split(separator: ".").compactMap { Int($0) }
        guard parts.count == 4 else { return false }
        return parts[0] == 100 && (64...127).contains(parts[1])
    }

    /// `base` with the chosen frame rate, bitrate and sound applied.
    ///
    /// `overrides` names fields a command-line flag already set (`--bitrate`,
    /// `--fps`, `--no-audio`), which win: the test harness and anyone
    /// debugging from a terminal must get exactly what they typed.
    func apply(to base: StreamConfig, host: String,
               overrides: Set<Override> = []) -> StreamConfig {
        var config = base
        if !overrides.contains(.frameRate) { config.frameRate = frameRate }
        if !overrides.contains(.bitrate) {
            config.bitrateKbps = videoQuality.bitrateKbps(remote: Self.isRemote(host: host))
        }
        if !overrides.contains(.audio) { config.audio = streamsAudio }
        return config
    }

    enum Override: Hashable { case frameRate, bitrate, audio }

    // MARK: - Storage

    private enum Key {
        static let quality = "SolStream.videoQuality"
        static let frameRate = "SolStream.frameRate"
        static let audio = "SolStream.streamsAudio"
        static let volume = "SolStream.volume"
        static let muted = "SolStream.muted"
        static let buffering = "SolStream.audioBuffering"
        static let clipboard = "SolStream.syncsClipboard"
    }

    private func set(_ value: Any, _ key: String, restarts: Bool) {
        defaults.set(value, forKey: key)
        announce(restarts: restarts)
    }

    private func announce(restarts: Bool) {
        NotificationCenter.default.post(name: Self.didChange, object: self,
                                        userInfo: [Self.restartsStreamKey: restarts])
    }
}
