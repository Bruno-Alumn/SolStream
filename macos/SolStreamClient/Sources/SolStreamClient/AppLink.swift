import Foundation
import AgentChannel

/// One application on one PC, asked for from outside the picker: by a
/// launcher in the Dock or Spotlight, or as the one open when SolStream last
/// quit.
///
/// Said by name rather than by window, because windows do not outlive the
/// application that opened them: the Start Menu name and its shortcut's path
/// are what still mean the same thing tomorrow. A stream attached to a window
/// that no installed application owns -- something started from a folder --
/// is kept by the window's title instead, and can only be found again while
/// that window is open.
struct AppLink: Codable, Equatable {
    /// As it was typed or picked in the connect window: the same string the
    /// pairing token is filed under.
    var host: String
    /// The Start Menu name, or the window's title when there is no app.
    var name: String
    /// The shortcut the host launches it by; nil for a window alone.
    var path: String?

    init(host: String, name: String, path: String? = nil) {
        self.host = host
        self.name = name
        self.path = path
    }

    init(host: String, app: RemoteApp) {
        self.init(host: host, name: app.name, path: app.path)
    }

    /// What to open on a PC listing `windows` and `apps`, or nil when it has
    /// neither the application nor its window any more.
    ///
    /// The application first, by its shortcut and then by its name -- the
    /// shortcut moves when an installer is rerun, the name when an update
    /// renames it, and seldom both at once. Launching goes through the same
    /// check as the picker, so an application already open is attached to,
    /// not started twice. Failing an application, a window by its exact title.
    func choice(windows: [RemoteWindow], apps: [RemoteApp]) -> AppPicker.Choice? {
        if let path, let app = apps.first(where: { $0.path.caseInsensitiveCompare(path) == .orderedSame }) {
            return .launch(app)
        }
        if let app = apps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            return .launch(app)
        }
        if path == nil, let window = windows.first(where: { $0.title == name }) {
            return .running(window)
        }
        return nil
    }

    /// The link for what `choice` opened: the application, or for an open
    /// window, the installed application whose window it surely is.
    ///
    /// Only a sure match (`LaunchMatch.isConfident`), and the longest name of
    /// those: "Untitled - Notepad" is Notepad's, and a window titled
    /// "Microsoft Teams" is Teams' whether or not an app called "Teams" is
    /// also installed.
    static func of(_ choice: AppPicker.Choice, host: String, apps: [RemoteApp]) -> AppLink {
        switch choice {
        case .launch(let app):
            return AppLink(host: host, app: app)
        case .running(let window):
            let owner = apps.filter { LaunchMatch.isConfident(title: window.title, name: $0.name) }
                .max { $0.name.count < $1.name.count }
            return owner.map { AppLink(host: host, app: $0) }
                ?? AppLink(host: host, name: window.title)
        }
    }

    /// Whether this is the same application on the same PC as `other`.
    /// `sameApp`, or the same name on the same PC: a launcher made before an
    /// installer moved the app's shortcut has the old path, and is still the
    /// app on screen -- opening it again closed the stream to reopen it.
    func likelySameApp(as other: AppLink) -> Bool {
        sameApp(as: other) || (Self.sameHost(host, other.host)
                               && name.caseInsensitiveCompare(other.name) == .orderedSame)
    }

    func sameApp(as other: AppLink) -> Bool {
        guard Self.sameHost(host, other.host) else { return false }
        if let path, let otherPath = other.path {
            return path.caseInsensitiveCompare(otherPath) == .orderedSame
        }
        return name.caseInsensitiveCompare(other.name) == .orderedSame
    }

    /// Host names are not case-sensitive, and a trailing dot is the same name.
    static func sameHost(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return false }
        return hostKey(a) == hostKey(b)
    }

    /// A host name as `sameHost` compares it: lower case, no trailing dot.
    static func hostKey(_ host: String) -> String {
        host.trimmingCharacters(in: CharacterSet(charactersIn: ". ")).lowercased()
    }

    // MARK: - Files

    /// The file a launcher hands to SolStream, and the extension it carries.
    static let fileExtension = "solstream"

    /// Written by a launcher's maker and read back here. JSON with a version,
    /// so that a launcher made today still opens after the format grows.
    func encoded() throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(File(version: 1, link: self))
    }

    /// Nil for anything that is not a link file this version understands:
    /// `open` can hand SolStream any file at all.
    static func decode(_ data: Data) -> AppLink? {
        guard let file = try? JSONDecoder().decode(File.self, from: data),
              file.version == 1,
              !file.link.host.trimmingCharacters(in: .whitespaces).isEmpty,
              !file.link.name.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        return file.link
    }

    private struct File: Codable {
        let version: Int
        let link: AppLink
    }

    // MARK: - The last one open

    private static let lastKey = "SolStream.lastApp"

    /// What was on screen when SolStream last quit, if anything was.
    static func last(in defaults: UserDefaults = .standard) -> AppLink? {
        defaults.data(forKey: lastKey).flatMap(decode)
    }

    static func setLast(_ link: AppLink?, in defaults: UserDefaults = .standard) {
        if let link, let data = try? link.encoded() {
            defaults.set(data, forKey: lastKey)
        } else {
            defaults.removeObject(forKey: lastKey)
        }
    }
}
