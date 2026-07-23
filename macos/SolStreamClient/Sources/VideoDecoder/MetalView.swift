import AppKit
import Metal
import MetalKit
import CoreVideo

/// An NSView backed by CAMetalLayer that renders decoded video frames.
public final class MetalView: NSView {
    private var metalDevice: MTLDevice?
    private var metalLayer: CAMetalLayer?
    private var textureCache: CVMetalTextureCache?
    private var commandQueue: MTLCommandQueue?
    private var statusText: String = "Connecting..."
    private var statusField: NSTextField?

    public override init(frame frameRect: NSRect) {
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this system")
        }
        self.metalDevice = device
        self.commandQueue = device.makeCommandQueue()

        super.init(frame: frameRect)
        self.wantsLayer = true

        if let layer = self.layer as? CAMetalLayer {
            self.metalLayer = layer
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.drawsAsynchronously = true

            let scale = self.window?.backingScaleFactor ?? 2.0
            layer.contentsScale = scale
            layer.drawableSize = CGSize(
                width: frameRect.width * scale,
                height: frameRect.height * scale
            )
        }

        CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )

        // Status text label — shown until first frame arrives.
        let field = NSTextField(labelWithString: statusText)
        field.alignment = .center
        field.textColor = .secondaryLabelColor
        field.font = NSFont.systemFont(ofSize: 18, weight: .medium)
        field.frame = CGRect(x: 0, y: frameRect.midY - 16, width: frameRect.width, height: 32)
        field.autoresizingMask = [.width, .maxXMargin]
        addSubview(field)
        statusField = field
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    public override func makeBackingLayer() -> CALayer {
        return CAMetalLayer()
    }

    /// Update the status text shown before frames arrive.
    public func setStatus(_ text: String) {
        statusText = text
        DispatchQueue.main.async { [weak self] in
            self?.statusField?.stringValue = text
        }
    }

    /// Display a decoded video frame. Called from the decoder callback.
    /// Must be called on the main thread.
    public func displayFrame(_ pixelBuffer: CVPixelBuffer) {
        // Remove status overlay once we have a frame.
        if statusField != nil {
            statusField?.removeFromSuperview()
            statusField = nil
        }

        guard let textureCache,
              let metalLayer,
              let drawable = metalLayer.nextDrawable()
        else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var metalTexture: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            .bgra8Unorm,
            width, height,
            0,
            &metalTexture
        )

        guard let metalTexture,
              let texture = CVMetalTextureGetTexture(metalTexture)
        else { return }

        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else { return }

        blitEncoder.copy(from: texture,
                         sourceSlice: 0,
                         sourceLevel: 0,
                         sourceOrigin: MTLOrigin(x: 0, y: 0, z: 0),
                         sourceSize: MTLSizeMake(width, height, 1),
                         to: drawable.texture,
                         destinationSlice: 0,
                         destinationLevel: 0,
                         destinationOrigin: MTLOrigin(x: 0, y: 0, z: 0))

        blitEncoder.endEncoding()
        commandBuffer.present(drawable)
        commandBuffer.commit()
    }

    public override func viewDidEndLiveResize() {
        super.viewDidEndLiveResize()
        guard let metalLayer, let window else { return }
        let scale = window.backingScaleFactor
        metalLayer.contentsScale = scale
        metalLayer.drawableSize = CGSize(
            width: bounds.width * scale,
            height: bounds.height * scale
        )
    }
}
