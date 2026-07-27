import AppKit
import DesignSystem
import Metal
import CoreVideo
import QuartzCore

/// A CAMetalLayer-backed view that presents decoded frames and hosts the
/// connection status overlay.
///
/// The drawable is sized to the incoming video rather than the view, so the
/// blit is a straight 1:1 copy and the layer's `resizeAspect` gravity does the
/// scaling. That keeps the picture from being cropped or stretched when the
/// window isn't exactly the stream's size.
public final class MetalView: NSView {
    private let metalDevice: MTLDevice
    private let commandQueue: MTLCommandQueue
    private var textureCache: CVMetalTextureCache?
    private var drawableSize: CGSize = .zero

    /// The region of the decoded frame to present, in frame pixels. Nil shows
    /// the whole frame. This is what turns one decoded stream into N
    /// independent windows: each view blits a different sub-rect of the same
    /// CVPixelBuffer, so there is still only one decode.
    public var sourceRect: CGRect? {
        didSet {
            guard oldValue != sourceRect else { return }
            drawableSize = .zero   // force the drawable to be resized
        }
    }

    private let overlay = StatusOverlay()

    // Presentation runs on the main thread but frames arrive on the media
    // queue, and nextDrawable() can block. Queueing a block per frame would
    // build an unbounded backlog and stall the UI, so only the newest frame is
    // kept — for live video a late frame is worth less than a current one.
    private let pendingLock = NSLock()
    private var pendingPixelBuffer: CVPixelBuffer?
    private var presentScheduled = false
    private(set) var framesSkipped = 0

    public override init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice(),
              let queue = device.makeCommandQueue() else {
            fatalError("Metal is not supported on this system")
        }
        metalDevice = device
        commandQueue = queue

        super.init(frame: frameRect)

        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay

        if let layer = layer as? CAMetalLayer {
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = false
            layer.isOpaque = true
            layer.backgroundColor = NSColor.black.cgColor
            layer.contentsGravity = .resizeAspect
            // Say what these pixels are. A CAMetalLayer with no colorspace is
            // taken to be in the display's own space and passed through without
            // conversion, which on a P3 MacBook panel means sRGB content from
            // Windows gets shown at P3 saturation — reds that glow and skin
            // tones that sunburn. Tagging it sRGB asks the compositor to
            // convert properly for whichever display the window is on.
            layer.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        }

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        overlay.translatesAutoresizingMaskIntoConstraints = false
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: trailingAnchor),
            overlay.topAnchor.constraint(equalTo: topAnchor),
            overlay.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeBackingLayer() -> CALayer {
        CAMetalLayer()
    }

    public override var isOpaque: Bool { true }

    // MARK: - Status overlay

    /// Update the overlay. Passing `pin` shows the pairing code prominently.
    public func setStatus(_ title: String, detail: String? = nil,
                          pin: String? = nil, busy: Bool = true) {
        overlay.update(title: title, detail: detail, pin: pin, busy: busy, isError: false)
    }

    /// Show a terminal error, with a Retry button if a handler is provided.
    public func setError(_ title: String, detail: String? = nil) {
        overlay.update(title: title, detail: detail, pin: nil, busy: false, isError: true)
    }

    public var onRetry: (() -> Void)? {
        get { overlay.onRetry }
        set { overlay.onRetry = newValue }
    }

    public func hideStatus() {
        overlay.setHidden(true)
    }

    // MARK: - Presentation

    /// Present a decoded frame. Safe to call from any thread.
    public func displayFrame(_ pixelBuffer: CVPixelBuffer) {
        pendingLock.lock()
        if pendingPixelBuffer != nil { framesSkipped += 1 }
        pendingPixelBuffer = pixelBuffer
        let alreadyScheduled = presentScheduled
        presentScheduled = true
        pendingLock.unlock()

        guard !alreadyScheduled else { return }

        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.pendingLock.lock()
            let next = self.pendingPixelBuffer
            self.pendingPixelBuffer = nil
            self.presentScheduled = false
            self.pendingLock.unlock()

            if let next { self.present(next) }
        }
    }

    private func present(_ pixelBuffer: CVPixelBuffer) {
        overlay.setHidden(true)

        guard let metalLayer = layer as? CAMetalLayer, let textureCache else { return }

        let frameWidth = CVPixelBufferGetWidth(pixelBuffer)
        let frameHeight = CVPixelBufferGetHeight(pixelBuffer)
        guard frameWidth > 0, frameHeight > 0 else { return }

        // Clamp the crop to the frame; the host's window can extend past the
        // captured display, and blitting outside the texture is a hard error.
        let full = CGRect(x: 0, y: 0, width: frameWidth, height: frameHeight)
        let crop = (sourceRect ?? full).intersection(full).integral
        guard crop.width >= 1, crop.height >= 1 else { return }

        let size = CGSize(width: crop.width, height: crop.height)
        if size != drawableSize {
            drawableSize = size
            metalLayer.drawableSize = size
        }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, textureCache, pixelBuffer, nil,
            .bgra8Unorm, frameWidth, frameHeight, 0, &cvTexture
        )
        guard status == kCVReturnSuccess,
              let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture),
              let drawable = metalLayer.nextDrawable(),
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let blit = commandBuffer.makeBlitCommandEncoder()
        else { return }

        blit.copy(from: texture,
                  sourceSlice: 0, sourceLevel: 0,
                  sourceOrigin: MTLOrigin(x: Int(crop.minX), y: Int(crop.minY), z: 0),
                  sourceSize: MTLSizeMake(Int(crop.width), Int(crop.height), 1),
                  to: drawable.texture,
                  destinationSlice: 0, destinationLevel: 0,
                  destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))
        blit.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }
}

/// The "connecting / pairing / failed" card drawn over the video surface.
private final class StatusOverlay: NSView {
    private let card = NSView()
    private let spinner = NSProgressIndicator()
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let pinLabel = NSTextField(labelWithString: "")
    private let retryButton = NSButton(title: "Try Again", target: nil, action: nil)

    var onRetry: (() -> Void)?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true

        // The card always sits over video, so it holds the dark ramp regardless of
        // the system appearance — a light card over someone's application would be
        // the brightest thing on screen, which is the opposite of the intent.
        card.wantsLayer = true
        card.layer?.backgroundColor = NSColor(srgbRed: 0x16 / 255, green: 0x18 / 255,
                                              blue: 0x26 / 255, alpha: 0.95).cgColor
        card.layer?.cornerRadius = 14
        card.layer?.cornerCurve = .continuous
        card.layer?.borderWidth = 1
        card.layer?.borderColor = NSColor(srgbRed: 0x3F / 255, green: 0x42 / 255,
                                          blue: 0x4D / 255, alpha: 1).cgColor
        card.translatesAutoresizingMaskIntoConstraints = false
        addSubview(card)

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isIndeterminate = true
        spinner.appearance = NSAppearance(named: .darkAqua)
        spinner.startAnimation(nil)

        titleLabel.font = DS.section
        titleLabel.textColor = DS.textPrimary
        titleLabel.alignment = .center
        titleLabel.lineBreakMode = .byTruncatingTail

        detailLabel.font = DS.secondary
        detailLabel.textColor = DS.textMuted
        detailLabel.alignment = .center
        detailLabel.maximumNumberOfLines = 3
        detailLabel.lineBreakMode = .byWordWrapping

        // The PIN is the hero of that screen: the confusion is never the digits,
        // it is not knowing where they go, so they are large and the instruction
        // sits directly under them.
        pinLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 46, weight: .medium)
        pinLabel.textColor = DS.accentBright
        pinLabel.alignment = .center
        pinLabel.isHidden = true

        retryButton.bezelStyle = .rounded
        retryButton.appearance = NSAppearance(named: .darkAqua)
        retryButton.target = self
        retryButton.action = #selector(retryTapped)
        retryButton.isHidden = true

        let stack = NSStackView(views: [spinner, pinLabel, titleLabel, detailLabel, retryButton])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        card.addSubview(stack)

        NSLayoutConstraint.activate([
            card.centerXAnchor.constraint(equalTo: centerXAnchor),
            card.centerYAnchor.constraint(equalTo: centerYAnchor),
            card.widthAnchor.constraint(greaterThanOrEqualTo: stack.widthAnchor, constant: 48),
            card.widthAnchor.constraint(lessThanOrEqualToConstant: 460),

            stack.centerXAnchor.constraint(equalTo: card.centerXAnchor),
            stack.topAnchor.constraint(equalTo: card.topAnchor, constant: 22),
            stack.bottomAnchor.constraint(equalTo: card.bottomAnchor, constant: -22),
            stack.leadingAnchor.constraint(greaterThanOrEqualTo: card.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(lessThanOrEqualTo: card.trailingAnchor, constant: -24),
            titleLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
            detailLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 380),
        ])
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Let clicks through to the video view except on the card itself.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !isHidden else { return nil }
        let inCard = card.frame.contains(convert(point, from: superview))
        return inCard ? super.hitTest(point) : nil
    }

    func update(title: String, detail: String?, pin: String?, busy: Bool, isError: Bool) {
        titleLabel.stringValue = title
        titleLabel.textColor = isError
            ? NSColor(calibratedRed: 1.0, green: 0.45, blue: 0.42, alpha: 1.0)
            : .white

        detailLabel.stringValue = detail ?? ""
        detailLabel.isHidden = (detail ?? "").isEmpty

        if let pin, !pin.isEmpty {
            pinLabel.stringValue = pin.map(String.init).joined(separator: " ")
            pinLabel.isHidden = false
        } else {
            pinLabel.isHidden = true
        }

        spinner.isHidden = !busy
        if busy { spinner.startAnimation(nil) } else { spinner.stopAnimation(nil) }

        retryButton.isHidden = !(isError && onRetry != nil)

        setHidden(false)
    }

    func setHidden(_ hidden: Bool) {
        guard isHidden != hidden else { return }
        isHidden = hidden
        if hidden { spinner.stopAnimation(nil) }
    }

    @objc private func retryTapped() {
        onRetry?()
    }
}
