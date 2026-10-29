import Foundation
import AudioRenderer
import InputCapture
import MediaSession
import VideoDecoder

/// Everything the person can choose about a stream, remembered across launches.
///
/// One place, so the Settings window, the popover on the streamed window and
/// the code that opens a stream all read the same values. Each change posts
/// `didChange` with `restartsStream` saying whether it can be applied to a
/// running stream as it is (volume, buffering, mouse, clipboard) or needs the
/// media session opened again (quality, frame rate, codec, sound on or off,
/// sound quality and source), because the host's encoders and audio capture are fixed
/// when the session opens.
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
    enum VideoQuality: String, SettingChoice {
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

    /// What the PC encodes the picture in.
    ///
    /// HEVC carries the same picture in fewer bits than H.264 -- sharper text
    /// at a given quality, or the same text over a slower network -- and both
    /// ends do it in hardware on a recent GPU and any Apple silicon Mac. A PC
    /// without a hardware HEVC encoder, or a host that predates the choice,
    /// sends H.264 whatever is chosen here.
    enum VideoCodecChoice: String, SettingChoice {
        case automatic, h264, hevc

        var title: String {
            switch self {
            case .automatic: return "Automatic"
            case .h264: return "H.264"
            case .hevc: return "HEVC"
            }
        }

        var detail: String {
            switch self {
            case .automatic: return "HEVC when this Mac and the PC both do it in hardware."
            case .h264: return "Works with every PC. Uses more data for the same picture."
            case .hevc: return "Sharper for the same data. H.264 if the PC cannot."
            }
        }

        /// What to offer the host, most wanted first. H.264 is always in the
        /// list, last, because it is what a PC without HEVC can fall back to.
        /// Automatic offers HEVC only where this Mac decodes it in hardware;
        /// HEVC chosen by name is offered even where it would be decoded in
        /// software.
        func codecs(hardwareHEVC: Bool) -> [VideoCodec] {
            switch self {
            case .automatic: return hardwareHEVC ? [.hevc, .h264] : [.h264]
            case .h264: return [.h264]
            case .hevc: return [.hevc, .h264]
            }
        }
    }

    /// H.264 until chosen otherwise: every stream before HEVC was H.264, and
    /// an update should not change what someone already has. HEVC's encode
    /// also took longer in its first measurements, which a longer run should
    /// settle before it becomes anyone's default.
    var videoCodec: VideoCodecChoice {
        get { defaults.string(forKey: Key.videoCodec).flatMap(VideoCodecChoice.init(rawValue:)) ?? .h264 }
        set { set(newValue.rawValue, Key.videoCodec, restarts: true) }
    }

    // MARK: - Sound

    /// Whether the PC sends its sound at all. Off saves the sound's share of
    /// the network and the PC's audio capture; volume and mute are the gentler
    /// controls.
    var streamsAudio: Bool {
        get { defaults.object(forKey: Key.audio) as? Bool ?? true }
        set { set(newValue, Key.audio, restarts: true) }
    }

    /// How the PC encodes its sound. Least to most, as the video's are.
    ///
    /// Opus, which the PC compiles in and AudioToolbox decodes, is all but
    /// transparent at 256 kbit/s and still good at 64; it costs 7.5 ms more
    /// delay than PCM at 10 ms a packet, and 17.5 ms at Data saver's 20.
    /// Lossless is the PCM every host sent before, and the only one a host
    /// that predates the choice can send.
    enum SoundQuality: String, SettingChoice {
        case dataSaver, standard, high, lossless

        var title: String {
            switch self {
            case .dataSaver: return "Data saver"
            case .standard: return "Standard"
            case .high: return "High"
            case .lossless: return "Lossless"
            }
        }

        /// What it costs, spelt as the video's figures are.
        var rate: String {
            switch self {
            case .dataSaver: return "64 kbps"
            case .standard: return "128 kbps"
            case .high: return "256 kbps"
            case .lossless: return "1.5 Mbps"
            }
        }

        /// One line saying what it is for, shown under the choice.
        var detail: String {
            switch self {
            case .dataSaver: return "\(rate). Slow or metered networks; a little more delay."
            case .standard: return "\(rate). Hard to tell from High, for half the data."
            case .high: return "\(rate). Sounds as it does on the PC."
            case .lossless: return "\(rate), uncompressed. Wired networks; least delay."
            }
        }

        /// What the host is asked for.
        ///
        /// Data saver's packets are 20 ms rather than 10 because every packet
        /// carries 68 bytes of headers: at 64 kbit/s and 10 ms they would be
        /// nearly half the stream, and halving the packets is worth more there
        /// than the 10 ms it adds.
        var encoding: AudioEncoding {
            switch self {
            case .dataSaver: return .opus(bitrate: 64_000, frameMilliseconds: 20)
            case .standard: return .opus(bitrate: 128_000, frameMilliseconds: 10)
            case .high: return .opus(bitrate: 256_000, frameMilliseconds: 10)
            case .lossless: return .pcm
            }
        }
    }

    var soundQuality: SoundQuality {
        get { defaults.string(forKey: Key.soundQuality).flatMap(SoundQuality.init(rawValue:)) ?? .high }
        set { set(newValue.rawValue, Key.soundQuality, restarts: true) }
    }

    /// Whose sound the PC sends: the streamed apps' alone, so a notification
    /// or a song elsewhere on the PC stays there, or everything it plays.
    enum SoundSource: String, SettingChoice {
        case streamedApps, wholePC

        /// On the segmented control, so short.
        var title: String {
            switch self {
            case .streamedApps: return "Streamed apps"
            case .wholePC: return "Whole PC"
            }
        }

        var detail: String {
            switch self {
            case .streamedApps: return "Only the streamed apps, not the rest of the PC."
            case .wholePC: return "Everything the PC plays, notifications included."
            }
        }

        var audioSource: AudioSource {
            switch self {
            case .streamedApps: return .apps
            case .wholePC: return .system
            }
        }
    }

    var soundSource: SoundSource {
        get { defaults.string(forKey: Key.soundSource).flatMap(SoundSource.init(rawValue:)) ?? .streamedApps }
        set { set(newValue.rawValue, Key.soundSource, restarts: true) }
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

    /// The volume from a slider running 0 to 100. Reaching for the volume
    /// means wanting to hear it; a slider that moved while nothing changed
    /// would look broken, so it unmutes.
    func setVolume(fromSlider position: Double) {
        volume = Float(position / 100)
        if isMuted { isMuted = false }
    }

    /// Unmuting into a volume of zero would change nothing you can hear, and
    /// look as if the button had not worked, so it brings back half.
    func toggleMute() {
        isMuted.toggle()
        if !isMuted, volume == 0 { volume = 0.5 }
    }

    enum AudioBufferingChoice: String, SettingChoice {
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

    // MARK: - Windows

    /// Whether the title bar `program` draws inside its own window -- the strip
    /// with its minimise, maximise and close, in Chrome, Discord or Explorer --
    /// is left out of the picture. Off for every program until the person
    /// chooses it in the popover, then remembered for that program. Windows
    /// file names ignore case, so this does too.
    func hidesTitleBar(of program: String) -> Bool {
        hiddenTitleBars.contains(program.lowercased())
    }

    func setHidesTitleBar(_ hides: Bool, of program: String) {
        var programs = hiddenTitleBars
        if hides {
            programs.insert(program.lowercased())
        } else {
            programs.remove(program.lowercased())
        }
        set(programs.sorted(), Key.hiddenTitleBars, restarts: false)
    }

    private var hiddenTitleBars: Set<String> {
        Set(defaults.stringArray(forKey: Key.hiddenTitleBars) ?? [])
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

    /// `base` with the chosen frame rate, bitrate, codec and sound applied.
    ///
    /// `overrides` names fields a command-line flag already set (`--bitrate`,
    /// `--fps`, `--video-codec`, `--no-audio`, `--sound-quality`,
    /// `--sound-from`), which win: the
    /// test harness and anyone debugging from a terminal must get exactly what
    /// they typed.
    func apply(to base: StreamConfig, host: String,
               overrides: Set<Override> = [],
               hardwareHEVC: Bool = VideoDecoder.decodesInHardware(.hevc)) -> StreamConfig {
        var config = base
        if !overrides.contains(.frameRate) { config.frameRate = frameRate }
        if !overrides.contains(.bitrate) {
            config.bitrateKbps = videoQuality.bitrateKbps(remote: Self.isRemote(host: host))
        }
        if !overrides.contains(.videoCodec) {
            config.videoCodecs = videoCodec.codecs(hardwareHEVC: hardwareHEVC)
        }
        if !overrides.contains(.audio) { config.audio = streamsAudio }
        if !overrides.contains(.soundQuality) { config.audioEncoding = soundQuality.encoding }
        if !overrides.contains(.soundSource) { config.audioSource = soundSource.audioSource }
        return config
    }

    enum Override: Hashable { case frameRate, bitrate, videoCodec, audio, soundQuality, soundSource }

    // MARK: - Storage

    private enum Key {
        static let quality = "SolStream.videoQuality"
        static let frameRate = "SolStream.frameRate"
        static let videoCodec = "SolStream.videoCodec"
        static let audio = "SolStream.streamsAudio"
        static let volume = "SolStream.volume"
        static let muted = "SolStream.muted"
        static let buffering = "SolStream.audioBuffering"
        static let soundQuality = "SolStream.soundQuality"
        static let soundSource = "SolStream.soundSource"
        static let clipboard = "SolStream.syncsClipboard"
        static let hiddenTitleBars = "SolStream.hiddenTitleBars"
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

/// One of a setting's choices, as the menus and segments that offer it show it.
protocol SettingChoice: CaseIterable, Equatable {
    var title: String { get }
    /// One line saying what it is for.
    var detail: String { get }
}
