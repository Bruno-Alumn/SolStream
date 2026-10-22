import Foundation
import AgentChannel

/// Which open window, if any, is an installed application's own.
///
/// The host knows an installed application by its Start Menu name alone --
/// its windows carry a title, a class and a process id, but not the program
/// they belong to -- and those names are short: "Mail", "Photos", "Word".
/// Taking any window whose title merely contained the name attached to a
/// Gmail tab for Mail and to Notepad++ for Notepad, and the application asked
/// for could not be opened at all while the other window was up.
///
/// So the title is read the way Windows applications write it: the
/// document, then a separator, then the application -- "Untitled - Notepad",
/// "Page — Mozilla Firefox", "Chat | Microsoft Teams" -- or the application
/// alone, "Spotify Premium", "Telegram (3)". The part after the last separator
/// is the application's own, and a name found anywhere else in the title is
/// what the window is showing, not what it is: "Steam tips - Google Chrome".
enum LaunchMatch {
    /// Hyphen, en dash, em dash and bar, each with a space either side, so
    /// "Notepad++" and "Wi-Fi" are not split.
    private static let separators = [" - ", " – ", " — ", " | "]

    /// Whether the title says the window is the application's.
    static func isConfident(title: String, name: String) -> Bool {
        let title = normalised(title)
        let name = normalised(name)
        guard !name.isEmpty else { return false }
        // The application's own part is its name, give or take a word.
        if names(ownPart(of: title), name) { return true }
        // Or the name comes first, exactly, ahead of the rest: "Steam - News".
        return separators.contains { title.hasPrefix(name + $0) }
    }

    /// Whether the application's own part of the title has the name in it as
    /// words of their own: not inside another word, "Gmail" for Mail, and not
    /// run into another name, "Notepad++" for Notepad. Less than sure -- see
    /// `existing` for when it is enough.
    static func mentions(title: String, name: String) -> Bool {
        let part = ownPart(of: normalised(title))
        let name = normalised(name)
        guard !name.isEmpty else { return false }
        var from = part.startIndex
        while let range = part.range(of: name, range: from..<part.endIndex) {
            let before = range.lowerBound == part.startIndex
                ? nil : part[part.index(before: range.lowerBound)]
            let after = range.upperBound == part.endIndex ? nil : part[range.upperBound]
            if isBoundary(before) && isBoundary(after) { return true }
            from = part.index(after: range.lowerBound)
        }
        return false
    }

    /// Before launching: a window that is surely the application's, or else
    /// the one window that mentions it, if only one does. Nil, and then it is
    /// launched: launching what was already open costs a wait, and attaching
    /// to the wrong window streams the wrong application.
    static func existing(_ name: String, in windows: [RemoteWindow]) -> RemoteWindow? {
        if let sure = windows.first(where: { isConfident(title: $0.title, name: name) }) {
            return sure
        }
        let loose = windows.filter { mentions(title: $0.title, name: name) }
        return loose.count == 1 ? loose[0] : nil
    }

    /// After a launch the host could not tie to a window of its own.
    ///
    /// A window from a process that was not running before the launch is the
    /// likeliest to be it, and there a mention of the name will do, since
    /// something did just start. `knownPIDs` are the processes with windows
    /// before the launch; empty means that list never came, and nothing can be
    /// called new. Failing that, what `existing` would take.
    static func afterLaunch(_ name: String, in windows: [RemoteWindow],
                            knownPIDs: Set<Int>) -> RemoteWindow? {
        let fresh = knownPIDs.isEmpty ? [] : windows.filter { !knownPIDs.contains($0.pid) }
        return fresh.first { isConfident(title: $0.title, name: name) }
            ?? fresh.first { mentions(title: $0.title, name: name) }
            ?? existing(name, in: windows)
    }

    // MARK: - Reading a title

    /// Lower case, trimmed, and without the zero-width spaces some
    /// applications hide in their names.
    private static func normalised(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{200B}", with: "")
            .trimmingCharacters(in: .whitespaces).lowercased()
    }

    /// What follows the last separator, or the whole title if there is none.
    private static func ownPart(of title: String) -> String {
        let last = separators.compactMap { title.range(of: $0, options: .backwards) }
            .max { $0.upperBound < $1.upperBound }
        return last.map { String(title[$0.upperBound...]) } ?? title
    }

    /// The name, or the name with one word more on either side -- "Spotify
    /// Free", "Mozilla Firefox" -- and either way perhaps with a count of what
    /// is waiting, "Telegram (3)".
    private static func names(_ part: String, _ name: String) -> Bool {
        let part = withoutCount(part)
        if part == name { return true }
        if part.hasPrefix(name + " ") { return isOneWord(part.dropFirst(name.count + 1)) }
        if part.hasSuffix(" " + name) { return isOneWord(part.dropLast(name.count + 1)) }
        return false
    }

    private static func withoutCount(_ part: String) -> String {
        part.replacingOccurrences(of: #"^\(\d+\)\s*|\s*\(\d+\)$"#, with: "",
                                  options: .regularExpression)
    }

    private static func isOneWord(_ text: Substring) -> Bool {
        !text.isEmpty && !text.contains { $0.isWhitespace }
    }

    private static func isBoundary(_ character: Character?) -> Bool {
        guard let character else { return true }
        return character.isWhitespace || "()[]{}|-–—:;,.!?\"'·".contains(character)
    }
}
