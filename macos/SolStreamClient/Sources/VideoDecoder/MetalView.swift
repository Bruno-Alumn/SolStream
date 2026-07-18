import AppKit
import Metal
import MetalKit
import CoreVideo

/// An NSView backed by CAMetalLayer that renders decoded video frames.
///
/// The view uses a Metal texture cache (CVMetalTextureCache) to efficiently
/// map CVPixelBuffers (from VideoToolbox) into Metal textures without
/// copying the pixel data.
final class MetalView: NSView {
    private var metalDevice: MTLDevice?
    private var metalLayer: CAMetalLayer?
    private var textureCache: CVMetalTextureCache?
    private var currentDrawable: CAMetalDrawable?
    private var displayLink: CVDisplayLink?

    // Current frame texture
    private var frameTexture: MTLTexture?
    private let commandQueue: MTLCommandQueue?

    override init(frame frameRect: NSRect) {
        // Create the Metal device.
        guard let device = MTLCreateSystemDefaultDevice() else {
            fatalError("Metal is not supported on this system")
        }
        self.metalDevice = device
        self.commandQueue = device.makeCommandQueue()

        super.init(frame: frameRect)
        self.wantsLayer = true

        // Setup CAMetalLayer.
        if let layer = self.layer as? CAMetalLayer {
            self.metalLayer = layer
            layer.device = device
            layer.pixelFormat = .bgra8Unorm
            layer.framebufferOnly = true
            layer.drawsAsynchronously = true

            // Fixed size — the stream window sets this.
            let scale = self.window?.backingScaleFactor ?? 2.0
            layer.contentsScale = scale
            layer.drawableSize = CGSize(
                width: frameRect.width * scale,
                height: frameRect.height * scale
            )
        }

        // Create the Metal texture cache for CVPixelBuffer → MTLTexture.
        CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            device,
            nil,
            &textureCache
        )
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func makeBackingLayer() -> CALayer {
        return CAMetalLayer()
    }

    // MARK: - Frame display

    /// Display a decoded video frame. Called from the decoder callback.
    /// Must be called on the main thread.
    func displayFrame(_ pixelBuffer: CVPixelBuffer) {
        guard let textureCache,
              let metalLayer,
              let drawable = metalLayer.nextDrawable()
        else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        // Create a Metal texture from the pixel buffer.
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

        // Blit the frame texture onto the drawable.
        guard let commandBuffer = commandQueue?.makeCommandBuffer(),
              let blitEncoder = commandBuffer.makeBlitCommandEncoder()
        else { return }

        let region = MTLRegionMake2D(0, 0, width, height)

        // Use a simple render pass to copy the source to the drawable.
        // For production, use a proper shader with color space conversion.
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

    // MARK: - Resizing

    override func viewDidEndLiveResize() {
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
