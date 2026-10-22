import Foundation
import AgentChannel

/// Which open window, if any, is an installed application's own.
///
/// The host knows an installed application by its Start Menu name alone, and
/// those are short: "Mail", "Photos", "Word". Taking any window whose title
/// merely contained the name attached to a Gmail tab for Mail and to
/// Notepad++ for Notepad, and the application asked for could not be opened
/// at all while the other window was up. A title counts only when it is the
/// name, or has the name set apart the way Windows applications title their
/// windows: "Untitled - Notepad", "Inbox — Mail", "Steam - News".
enum LaunchMatch {
    static func isConfident(title: String, name: String) -> Bool {
        let title = title.trimmingCharacters(in: .whitespaces).lowercased()
        let name = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !name.isEmpty else { return false }
        return title == name
            || title.hasSuffix(" - " + name)
            || title.hasSuffix(" — " + name)
            || title.hasPrefix(name + " - ")
    }

    /// Before launching: a window that is surely the application's, or nil,
    /// and then it is launched. Launching what was already open costs a wait;
    /// attaching to the wrong window streams the wrong application.
    static func existing(_ name: String, in windows: [RemoteWindow]) -> RemoteWindow? {
        windows.first { isConfident(title: $0.title, name: name) }
    }

    /// After a launch the host could not tie to a window of its own.
    ///
    /// A window from a process that was not running before the launch is the
    /// likeliest to be it, and there a title that merely contains the name
    /// will do, since something did just start. `knownPIDs` are the processes
    /// with windows before the launch; empty means that list never came, and
    /// nothing can be called new.
    static func afterLaunch(_ name: String, in windows: [RemoteWindow],
                            knownPIDs: Set<Int>) -> RemoteWindow? {
        let fresh = knownPIDs.isEmpty ? [] : windows.filter { !knownPIDs.contains($0.pid) }
        return fresh.first { isConfident(title: $0.title, name: name) }
            ?? fresh.first { $0.title.localizedCaseInsensitiveContains(name) }
            ?? existing(name, in: windows)
    }
}
