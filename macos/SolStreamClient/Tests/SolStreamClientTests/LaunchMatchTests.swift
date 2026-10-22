import XCTest
@testable import AgentChannel
@testable import SolStreamClient

/// An installed application picked to launch is attached to an open window
/// only when the window is surely its own, or is the only one that could be.
final class LaunchMatchTests: XCTestCase {
    private func window(_ title: String, pid: Int = 100, id: UInt64 = 1) -> RemoteWindow {
        RemoteWindow(id: id, pid: pid, title: title, className: "Window",
                     x: 0, y: 0, width: 800, height: 600,
                     isOccluded: false, occludedBy: nil, captionInset: 31)
    }

    func testTheWaysAnApplicationTitlesItsOwnWindow() {
        let own: [(title: String, name: String)] = [
            ("Calculator", "Calculator"),
            ("calculator", "Calculator"),
            ("Untitled - Notepad", "Notepad"),
            ("Inbox — Mail", "Mail"),
            ("Inbox – Mail", "Mail"),
            ("Steam - News", "Steam"),
            ("Spotify Premium", "Spotify"),
            ("Spotify Free", "Spotify"),
            ("Page — Mozilla Firefox", "Firefox"),
            ("Chat | Microsoft Teams", "Microsoft Teams"),
            ("Chat | Microsoft Teams", "Teams"),
            ("Telegram (3)", "Telegram"),
            ("(12) Telegram", "Telegram"),
            ("Inbox - Gmail - Google Chrome", "Chrome"),
            ("New tab - Profile 1 - Microsoft\u{200B} Edge", "Microsoft Edge"),
        ]
        for (title, name) in own {
            XCTAssertTrue(LaunchMatch.isConfident(title: title, name: name), "\(name): \(title)")
        }
    }

    /// The decoys: another application's window that has the name in its
    /// title, inside a word, run into another name, or in what it shows.
    func testATitleThatMerelyContainsTheNameIsNotTheApplication() {
        let decoys: [(title: String, name: String)] = [
            ("Inbox - someone@example.com - Gmail - Google Chrome", "Mail"),
            ("new 1 - Notepad++", "Notepad"),
            ("Document - WordPad", "Word"),
            ("Discord tips - Microsoft Edge", "Discord"),
            ("Steam tips - Google Chrome", "Steam"),
            ("Anything", ""),
        ]
        for (title, name) in decoys {
            XCTAssertFalse(LaunchMatch.isConfident(title: title, name: name), "\(name): \(title)")
            XCTAssertFalse(LaunchMatch.mentions(title: title, name: name), "\(name): \(title)")
        }
        // More than a word besides the name: a mention, not a sure match.
        XCTAssertFalse(LaunchMatch.isConfident(title: "Photos backup and more", name: "Photos"))
        XCTAssertFalse(LaunchMatch.isConfident(title: "Spotify Premium Family Plan", name: "Spotify"))
    }

    func testAMentionIsTheNameAsWordsOfTheirOwnInTheApplicationsPart() {
        XCTAssertTrue(LaunchMatch.mentions(title: "Chat | Microsoft Teams (work or school)",
                                           name: "Microsoft Teams"))
        XCTAssertTrue(LaunchMatch.mentions(title: "Sign in to Steam", name: "Steam"))
        XCTAssertFalse(LaunchMatch.mentions(title: "Notepad++ portable", name: "Notepad"))
    }

    func testBeforeLaunchingOnlyASureWindowIsAttached() {
        let windows = [window("new 1 - Notepad++", id: 1), window("Untitled - Notepad", id: 2)]
        XCTAssertEqual(LaunchMatch.existing("Notepad", in: windows)?.id, 2)
        XCTAssertNil(LaunchMatch.existing("Notepad", in: [window("new 1 - Notepad++")]),
                     "launched instead")
        XCTAssertNil(LaunchMatch.existing("Mail", in: [
            window("Inbox - someone@example.com - Gmail - Google Chrome")]))
        XCTAssertNil(LaunchMatch.existing("Word", in: [window("Document - WordPad")]))
    }

    func testBeforeLaunchingTheOnlyWindowThatMentionsTheNameIsAttached() {
        let teams = window("Chat | Microsoft Teams (work or school)", id: 1)
        let other = window("Untitled - Notepad", id: 2)
        XCTAssertEqual(LaunchMatch.existing("Microsoft Teams", in: [teams, other])?.id, 1)

        let second = window("Meeting | Microsoft Teams (work or school)", id: 3)
        XCTAssertNil(LaunchMatch.existing("Microsoft Teams", in: [teams, second, other]),
                     "two could be it: launched instead")
    }

    func testAfterALaunchANewProcessIsPreferred() {
        let windows = [window("Steam - News", pid: 10, id: 1),
                       window("Sign in to Steam", pid: 20, id: 2)]
        XCTAssertEqual(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [10])?.id, 2,
                       "the process that just started, though its title is loose")
        XCTAssertEqual(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [10, 20])?.id, 1,
                       "nothing new: the sure title")
        XCTAssertEqual(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [])?.id, 1,
                       "no list from before: nothing can be called new")
    }

    func testAfterALaunchWithNothingNewOrSureTheOnlyMentionIsTaken() {
        let windows = [window("Sign in to Steam", pid: 20, id: 2),
                       window("Steam tips - Google Chrome", pid: 10, id: 1)]
        XCTAssertEqual(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [10, 20])?.id, 2)
    }

    func testAfterALaunchANewProcessStillNeedsTheName() {
        let windows = [window("Steam tips - Google Chrome", pid: 10, id: 1),
                       window("Downloads", pid: 30, id: 3)]
        XCTAssertNil(LaunchMatch.afterLaunch("Steam", in: windows, knownPIDs: [10]))
    }
}
