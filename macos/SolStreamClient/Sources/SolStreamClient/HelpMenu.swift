import AppKit

/// The Help menu: where to read how SolStream works, what to do when it does
/// not, where the PC's half is, and where to say something is wrong. Before
/// it, the Windows download was offered only while no PC was paired, so a
/// second PC or a reinstall had no way to it from the app.
///
/// No key equivalents: ⌘? from a streamed window is the PC's Ctrl+?, and the
/// menu bar's own Help search is there for the keyboard.
enum HelpMenu {
    struct Link: Equatable {
        let title: String
        let url: URL
    }

    static let repository = URL(string: "https://github.com/Bruno-Alumn/SolStream")!

    /// In menu order; nil is a separator.
    static let links: [Link?] = [
        Link(title: "SolStream Help", url: readme(anchor: "using-solstream")),
        Link(title: "Troubleshooting", url: readme(anchor: "troubleshooting")),
        nil,
        Link(title: "Get SolStream for Windows", url: SetupGuide.windowsDownload),
        Link(title: "Report an Issue", url: repository.appendingPathComponent("issues/new")),
    ]

    /// A README heading on the repository's page, which GitHub anchors by its
    /// words in lower case with hyphens for spaces.
    static func readme(anchor: String) -> URL {
        URL(string: repository.absoluteString + "#" + anchor)!
    }

    /// The menu, each item opening its link through `action` on `target`,
    /// with the URL as the item's represented object.
    static func make(target: AnyObject, action: Selector) -> NSMenu {
        let menu = NSMenu(title: "Help")
        for link in links {
            guard let link else {
                menu.addItem(.separator())
                continue
            }
            let item = menu.addItem(withTitle: link.title, action: action, keyEquivalent: "")
            item.target = target
            item.representedObject = link.url
        }
        return menu
    }
}
