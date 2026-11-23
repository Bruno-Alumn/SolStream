import AppKit
import DesignSystem
import SolStreamLogging
import VideoDecoder
import InputCapture
import AgentChannel

/// A dialog a streamed application opened over its window on the PC -- Save
/// As, a message box, a colour picker -- shown on the Mac as a child window of
/// the `AppWindow` it belongs to, at the same offset from it.
///
/// A mirror, not a stream window of its own. It shows the part of the picture
/// where the dialog already is on the capture display and asks the PC for
/// nothing: no `place`, no `lock`, no `topmost`, so it claims none of the
/// host's eight slots and nothing on the PC moves. Pointer input is absolute
/// on the capture canvas, so a click on it lands on the dialog as it would on
/// the parent's picture. It follows the dialog by asking where it is every
/// half second, and goes when the PC says it has closed -- by the host's
/// `closed` push, or by that poll.
///
/// It has no close button: there is no asking the PC to close a window it is
/// not streaming, and the dialog closes with its own buttons, or Escape. Nor
/// can it be dragged on its own: the PC's dialog would stay where it is.
final class OwnedWindow: NSObject, NSWindowDelegate {
    let remoteWindowID: UInt64
    private(set) var window: NSWindow?
    private var metalView: MetalView?
    private var inputCapture: InputCapture?

    private var session: StreamSession
    private let agent: AgentConnection
    private let display: RemoteDisplay
    private weak var parent: AppWindow?
    /// The dialog's client area, in the PC's virtual-desktop pixels, as last
    /// heard.
    private(set) var frame: CGRect

    private var pollTimer: Timer?
    private var pollInFlight = false
    private(set) var isClosing = false

    /// Gone: the owner lets go of it. Deferred to the next turn, as an
    /// `AppWindow`'s is.
    var onClose: (() -> Void)?
    /// This window took the keyboard or gave it up; see `AppWindow`.
    var onKeyboardChange: (() -> Void)?

    deinit {
        pollTimer?.invalidate()
    }

    init(session: StreamSession, agent: AgentConnection, opened: OpenedWindow,
         display: RemoteDisplay, parent: AppWindow) {
        self.session = session
        self.agent = agent
        self.display = display
        self.parent = parent
        remoteWindowID = opened.id
        frame = Follow.frame(of: opened)
        super.init()
        build(title: Follow.title(opened, parentTitle: parent.window?.title ?? ""))
    }

    private var displayRect: CGRect { AppDelegate.displayRect(display) }

    private func build(title: String) {
        // Sized for real by `reposition`, once it is a child of the parent.
        let content = NSRect(x: 0, y: 0, width: 200, height: 120)
        let window = NSWindow(contentRect: content, styleMask: [.titled],
                              backing: .buffered, defer: false)
        window.title = title
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.backgroundColor = DS.ground
        window.appearance = NSAppearance(named: .darkAqua)
        window.isMovable = false
        window.acceptsMouseMovedEvents = true
        // Beside its parent in a full-screen Space, not a Space of its own.
        window.collectionBehavior = [.fullScreenAuxiliary]
        for button in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton] {
            window.standardWindowButton(button)?.isHidden = true
        }
        window.delegate = self

        let view = MetalView(frame: content)
        // Over a picture already coming: nothing to say, and the card a fresh
        // view starts with would flash.
        view.hideStatus()
        window.contentView = view
        metalView = view

        let capture = InputCapture()
        capture.attach(to: view)
        capture.sendsScanCodes = session.hostTakesScanCodes
        capture.sendsKeyCharacters = session.hostTakesKeyCharacters
        capture.hostName = session.host
        capture.onInput = { [weak self] packet in self?.session.sendInput(packet) }
        capture.acceptsInput = { [weak self] in self?.session.acceptsInput ?? false }
        inputCapture = capture
        view.onMouseDown = { [weak capture] event in capture?.handleViewPress(event) }
        view.onInsertText = { [weak capture] text in capture?.sendText(text) }
        capture.inputMethodHandles = { [weak view] event in view?.handToInputMethod(event) ?? false }
        capture.inputMethodComposing = { [weak view] in view?.hasMarkedText() ?? false }
        window.initialFirstResponder = view
        window.makeFirstResponder(view)

        self.window = window
        session.attach(view)
        applyCrop()
    }

    /// Put it over its parent and give it the keyboard, as the dialog has it
    /// on the PC -- only when its parent has the Mac's keyboard: a dialog the
    /// app opened by itself does not take the keyboard from another stream
    /// window, or the Mac from whatever the user is doing.
    func show() {
        guard let window, let parentWindow = parent?.window else { return }
        parentWindow.addChildWindow(window, ordered: .above)
        reposition()
        if Follow.mirrorTakesKeyboard(appActive: NSApp.isActive,
                                      parentHasKeyboard: parent?.hasKeyboard == true) {
            window.makeKeyAndOrderFront(nil)
        } else {
            window.orderFront(nil)
        }
        startPolling()
    }

    func close() {
        window?.close()
    }

    /// The PC said the dialog has gone.
    func hostWindowClosed(noticedBy route: String) {
        guard !isClosing else { return }
        Log.info("[follow] \"\(window?.title ?? "")\" (window \(remoteWindowID)) closed on the PC "
                 + "(\(route))")
        close()
    }

    // MARK: - Where it is

    /// The crop: the dialog's client area on the capture display, in the
    /// encoded picture's pixels.
    private func applyCrop() {
        guard let shown = Follow.shown(frame, on: displayRect) else { return }
        let displaySize = CGSize(width: display.width, height: display.height)
        let crop = AppWindow.canvasRect(CGRect(x: shown.minX - CGFloat(display.x),
                                               y: shown.minY - CGFloat(display.y),
                                               width: shown.width, height: shown.height),
                                        display: displaySize, canvas: session.canvasSize)
        metalView?.sourceRect = crop
        inputCapture?.displayPixelsPerCanvasPixel = displaySize.width > 0
            && session.canvasSize.width > 0 ? displaySize.width / session.canvasSize.width : 1
        inputCapture?.sourceRect = crop
        inputCapture?.canvasSize = session.canvasSize
    }

    /// Over the parent's picture where the dialog is over the parent's window
    /// on the PC. Again whenever either of them moves or changes size.
    func reposition() {
        guard !isClosing, let window, let parent,
              let parentContent = parent.contentOnScreen,
              let shown = Follow.shown(frame, on: displayRect),
              let content = Follow.childFrame(of: shown, parentPicture: parent.shownPicture,
                                              parentContent: parentContent) else { return }
        let target = window.frameRect(forContentRect: content)
        guard target != window.frame else { return }
        window.setFrame(target, display: true)
    }

    /// The dialog is now `fresh` on the PC.
    private func moved(to fresh: CGRect) {
        guard fresh != frame, fresh.width >= 1, fresh.height >= 1 else { return }
        frame = fresh
        applyCrop()
        reposition()
    }

    /// Every half second, and one at a time: where the dialog is, and whether
    /// it is still there. The host's `closed` push is the quick way it goes;
    /// this is the one that still works after a reconnect, when the host has
    /// forgotten what it told the last connection about. Not while a launch
    /// is out, which would hold the answer back until it is answered.
    private func startPolling() {
        let timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, !self.isClosing, !self.pollInFlight,
                  !self.agent.isLaunching else { return }
            self.pollInFlight = true
            self.agent.windowStatus(id: self.remoteWindowID) { [weak self] status in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.pollInFlight = false
                    // A dropped connection answers nil: not a reason to close.
                    guard let status else { return }
                    if !status.isAlive || !status.isVisible || status.isMinimized {
                        self.hostWindowClosed(noticedBy: "poll")
                    } else if let fresh = status.frame {
                        self.moved(to: fresh)
                    }
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    // MARK: - The parent's stream

    /// See `AppWindow.rebind`.
    func rebind(to fresh: StreamSession) {
        guard !isClosing, let metalView else { return }
        session.detach(metalView)
        session = fresh
        fresh.attach(metalView)
        inputCapture?.sendsScanCodes = fresh.hostTakesScanCodes
        inputCapture?.sendsKeyCharacters = fresh.hostTakesKeyCharacters
        applyCrop()
    }

    func inputBecameLive() {
        inputCapture?.inputBecameLive()
    }

    func hostCursorChanged(_ cursor: NSCursor) {
        metalView?.remoteCursor = cursor
    }

    var isKey: Bool { window?.isKeyWindow == true }

    // MARK: - NSWindowDelegate

    func windowDidBecomeKey(_ notification: Notification) {
        inputCapture?.enableCapture()
        // The keyboard goes to the dialog on the PC as well, and the click
        // that made this key waits for it; see `AppWindow.windowDidBecomeKey`.
        let request = inputCapture?.focusRequested()
        agent.focus(windowID: remoteWindowID) { [weak self] in
            guard let request else { return }
            self?.inputCapture?.focusSettled(request)
        }
        onKeyboardChange?()
    }

    func windowDidResignKey(_ notification: Notification) {
        metalView?.dropComposition()
        inputCapture?.disableCapture()
        onKeyboardChange?()
    }

    func windowWillClose(_ notification: Notification) {
        isClosing = true
        pollTimer?.invalidate()
        pollTimer = nil
        if let metalView {
            session.detach(metalView)
        }
        inputCapture?.disableCapture()
        // The keyboard back to the window it came from, which on the PC has
        // it again now the dialog has gone.
        let hadKeyboard = window?.isKeyWindow == true
        if let window, let parentWindow = window.parent {
            parentWindow.removeChildWindow(window)
            // Not to a parent closing too: it would ask the PC to focus a
            // window it is about to let go of.
            if hadKeyboard, parentWindow.isVisible, parent?.isGoing != true {
                parentWindow.makeKey()
            }
        }
        window?.delegate = nil
        let notify = onClose
        onClose = nil
        DispatchQueue.main.async { notify?() }
    }
}
