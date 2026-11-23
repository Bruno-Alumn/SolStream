import Foundation
import CoreGraphics
import AgentChannel

/// What becomes of a window a streamed application opens on the PC, as the
/// host's `windowOpened` names it. Pure, for the tests; `AppDelegate`
/// carries it out and `OwnedWindow` shows the dialogs.
///
/// Two kinds come: a window the streamed one owns -- a dialog, Save As, a
/// colour picker -- and one that came to the front just after this Mac's
/// click into a streamed window, a sign-in page in the browser, say.
enum Follow {

    enum Decision: Equatable {
        /// Left alone, for the reason given.
        case ignore(String)
        /// Shown over the window it belongs to, as a crop of the picture
        /// where it already is on the capture display: nothing on the PC
        /// moves, and it has no tile of its own.
        case mirror
        /// Added to the stream as a window of its own, on a free tile, as
        /// one chosen from the picker would be. The reason, for the log.
        case tile(String)
    }

    /// What to do with `opened`, on a stream showing the windows `streamed`
    /// (the PC's ids of the Mac's stream windows) and the dialogs `mirrored`,
    /// whose capture display is `display` in the PC's virtual-desktop pixels.
    static func decide(_ opened: OpenedWindow, streamed: Set<UInt64>, mirrored: Set<UInt64>,
                       display: CGRect) -> Decision {
        guard opened.width >= 1, opened.height >= 1 else {
            return .ignore("it has no size")
        }
        // Never mirrored, even one hanging past its window: a Mac window over
        // it would take the keyboard and the foreground, which ends a menu on
        // the PC. What lies over its window is in that window's picture.
        guard !opened.popup else {
            return .ignore("it is a menu, tooltip or tool window")
        }
        if streamed.contains(opened.id) || mirrored.contains(opened.id) {
            return .ignore("it is shown here already")
        }
        guard opened.id != opened.parent, streamed.contains(opened.parent) else {
            return .ignore("window \(opened.parent), which it goes with, is not streamed here")
        }
        guard opened.owned else {
            return .tile("the Mac's input opened it")
        }
        guard onCaptureDisplay(frame(of: opened), display: display) else {
            return .tile("its dialog is not on the capture display")
        }
        return .mirror
    }

    /// Whether a dialog shown over its window takes the Mac's keyboard as it
    /// opens: only from its own window, while SolStream is the app in front.
    /// Opened while the keyboard is in another stream window, or another Mac
    /// app, it is only put in front.
    static func mirrorTakesKeyboard(appActive: Bool, parentHasKeyboard: Bool) -> Bool {
        appActive && parentHasKeyboard
    }

    /// Whether a window added to the stream is made key and SolStream brought
    /// forward. Not for one the PC opened by itself while the user is in
    /// another Mac app: that one is only put in front, behind the app in use.
    static func showActivates(quietly: Bool, appActive: Bool) -> Bool {
        !quietly || appActive
    }

    /// Its client area, in the PC's virtual-desktop pixels.
    static func frame(of opened: OpenedWindow) -> CGRect {
        CGRect(x: opened.x, y: opened.y, width: opened.width, height: opened.height)
    }

    /// How far past the display's edge a window may hang, in pixels, and still
    /// be taken as on it: a dialog laid out against the edge can round over it.
    static let edgeSlack: CGFloat = 2

    /// `rect` is all on the capture display, so its crop of the picture shows
    /// the whole of it. One partly off would show black where it hangs over;
    /// that one is given a tile instead, which brings all of it on.
    static func onCaptureDisplay(_ rect: CGRect, display: CGRect) -> Bool {
        guard rect.width >= 1, rect.height >= 1, display.width >= 1, display.height >= 1 else {
            return false
        }
        return display.insetBy(dx: -edgeSlack, dy: -edgeSlack).contains(rect)
    }

    /// The part of `rect` the picture holds: what is on `display`. Nil when
    /// none of it is.
    static func shown(_ rect: CGRect, on display: CGRect) -> CGRect? {
        let visible = rect.intersection(display)
        guard !visible.isNull, visible.width >= 1, visible.height >= 1 else { return nil }
        return visible
    }

    /// Where a dialog showing `rect` of the capture display goes on the Mac,
    /// as a content rectangle in screen points: over the window it belongs
    /// to, at the same offset from it as on the PC.
    ///
    /// - Parameters:
    ///   - parentPicture: what the parent's picture shows, in the PC's pixels.
    ///   - parentContent: the parent's content view on the Mac's screen, in
    ///     points, y up. The picture is fitted into it keeping its shape --
    ///     the view draws with `.resizeAspect` -- so in full screen, where the
    ///     two differ, it sits centred with bars beside it, and the scale is
    ///     the picture's, not the view's.
    static func childFrame(of rect: CGRect, parentPicture: CGRect,
                           parentContent: CGRect) -> CGRect? {
        guard parentPicture.width >= 1, parentPicture.height >= 1,
              parentContent.width >= 1, parentContent.height >= 1,
              rect.width >= 1, rect.height >= 1 else { return nil }
        let scale = min(parentContent.width / parentPicture.width,
                        parentContent.height / parentPicture.height)
        let drawnWidth = parentPicture.width * scale
        let drawnHeight = parentPicture.height * scale
        let drawnLeft = parentContent.midX - drawnWidth / 2
        let drawnTop = parentContent.midY + drawnHeight / 2
        let width = (rect.width * scale).rounded()
        let height = (rect.height * scale).rounded()
        let left = (drawnLeft + (rect.minX - parentPicture.minX) * scale).rounded()
        let top = (drawnTop - (rect.minY - parentPicture.minY) * scale).rounded()
        return CGRect(x: left, y: top - height, width: width, height: height)
    }

    /// The Mac window's title: the dialog's own, or the window it belongs
    /// to's when it has none -- a picker, a pop-up with no caption.
    static func title(_ opened: OpenedWindow, parentTitle: String) -> String {
        let own = opened.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return own.isEmpty ? parentTitle : opened.title
    }

    /// For the log: `"Save As" (window 263412)`.
    static func describe(_ opened: OpenedWindow) -> String {
        "\"\(opened.title)\" (window \(opened.id), \(opened.owned ? "owned by" : "opened over") "
            + "window \(opened.parent))"
    }
}
