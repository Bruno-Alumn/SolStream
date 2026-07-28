// make-logo.swift — draws SolStream's mark and cuts every icon both apps ship.
//
// THE MARK
//
// Two rectangles, because that is what the product is: a hairline frame is the
// host display, one solid accent rect is the application, and the accent
// straddles the frame's right edge — half on the PC, half on the Mac. There is
// no sun, no monitor, no cloud and no play triangle. It survives 16px, it needs
// no gradient, and the production art is two paths per artboard.
//
// WHY THIS IS A PROGRAM AND NOT A FOLDER OF PNGs
//
// Below 32px the mark is a REDRAW, not a scale. Scaled proportionally the
// overlap between the frame and the accent reaches two pixels and the two
// shapes fuse into one blob — at exactly the sizes that appear in the taskbar,
// the Start menu and the menu bar. So 16, 20 and 24 are separate artboards with
// whole-pixel coordinates, square corners, and the accent CLEARING the frame by
// one pixel rather than crossing it: at those sizes the crossing is implied by
// the overlap of the two bands vertically, not by contact. Hand-maintaining ten
// artboards across two platforms is how they drift; this way the small sizes
// are stated once, as numbers, next to the geometry they deviate from.
//
// Run through build.sh, which puts the results where the two builds expect them.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// ── Nocturne tokens ──────────────────────────────────────────────────────────
//
// Copied literally from the design system rather than derived. The ramps were
// chosen against contrast targets; a generated one lands somewhere plausible
// and fails in exactly the places nobody screenshots.

struct RGB {
    let r: CGFloat, g: CGFloat, b: CGFloat, a: CGFloat
    init(_ hex: UInt32, _ alpha: CGFloat = 1) {
        r = CGFloat((hex >> 16) & 0xFF) / 255
        g = CGFloat((hex >> 8) & 0xFF) / 255
        b = CGFloat(hex & 0xFF) / 255
        a = alpha
    }
    var cg: CGColor { CGColor(red: r, green: g, blue: b, alpha: a) }
}

enum Token {
    static let tile = RGB(0x232532)        // the app tile
    static let tileEdge = RGB(0x3F424D)    // its hairline
    static let frame = RGB(0x595D6C)       // the host display
    static let frameMid = RGB(0x75798C)    // brightened at 32 and 24
    static let frameSmall = RGB(0x9397AB)  // brightened again at 20 and 16
    static let accent = RGB(0x9184D9)      // the application
    static let mono = RGB(0xE9E9ED)        // template / menu bar
}

/// What ground the mark is being drawn on.
enum Ground {
    case dark        // the product's own tile
    case template    // no tile, one flat colour — a macOS template image
}

// ── Geometry ─────────────────────────────────────────────────────────────────

/// The mark as fractions of the tile. Everything at 32px and above is this,
/// scaled; nothing below it is.
enum Frac {
    static let frameX: CGFloat = 0.15, frameY: CGFloat = 0.26
    static let frameW: CGFloat = 0.45, frameH: CGFloat = 0.48
    static let accentX: CGFloat = 0.44, accentY: CGFloat = 0.38
    static let accentW: CGFloat = 0.41, accentH: CGFloat = 0.36
}

/// One hand-drawn small artboard, in whole pixels. The frame's right edge and
/// the accent's left edge are one pixel apart in every one of these — that gap
/// is the point, and it is why they are written out rather than computed.
struct SmallBoard {
    let size: Int
    let frame: (x: Int, y: Int, w: Int, h: Int)
    let accent: (x: Int, y: Int, w: Int, h: Int)
    let frameColour: RGB
}

let smallBoards: [Int: SmallBoard] = [
    24: SmallBoard(size: 24, frame: (3, 6, 9, 12), accent: (13, 7, 8, 10),
                   frameColour: Token.frameMid),
    20: SmallBoard(size: 20, frame: (3, 5, 7, 10), accent: (11, 6, 6, 8),
                   frameColour: Token.frameSmall),
    16: SmallBoard(size: 16, frame: (2, 4, 6, 8), accent: (9, 5, 5, 6),
                   frameColour: Token.frameSmall),
]

/// The frame's stroke, in pixels. Not a constant fraction: it is a hairline that
/// has to stay a hairline, so it is pinned to the artboard rather than scaled
/// off one reference size.
func strokeWidth(for size: Int) -> CGFloat {
    if size >= 128 { return CGFloat(size) / 64.0 }   // 128→2, 256→4, 1024→16
    if size >= 64 { return 1.5 }
    return 1
}

func frameColour(for size: Int) -> RGB {
    if size >= 64 { return Token.frame }
    return Token.frameMid                             // 32 and 48
}

// ── Drawing ──────────────────────────────────────────────────────────────────

func makeContext(_ size: Int) -> CGContext {
    let context = CGContext(
        data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    // Origin top-left, so the artboard numbers read the way they were drawn.
    context.translateBy(x: 0, y: CGFloat(size))
    context.scaleBy(x: 1, y: -1)
    return context
}

func roundedPath(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    radius <= 0 ? CGPath(rect: rect, transform: nil)
                : CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius,
                         transform: nil)
}

/// Draw one artboard.
///
/// `tileRadius` is the platform's business, not the mark's: macOS masks icons
/// into a squircle and wants 22.4%, Windows masks nothing and takes square
/// corners, and the artwork inside is identical either way.
func drawMark(size: Int, ground: Ground, tileRadius: CGFloat) -> CGImage {
    let context = makeContext(size)
    let side = CGFloat(size)

    if ground == .dark {
        context.setFillColor(Token.tile.cg)
        context.addPath(roundedPath(CGRect(x: 0, y: 0, width: side, height: side),
                                    tileRadius))
        context.fillPath()
        // The tile's own hairline, inset by half its width so it lands inside
        // the artboard rather than straddling its edge and losing half of itself.
        if size >= 32 {
            let hair: CGFloat = size >= 128 ? CGFloat(size) / 128.0 : 1
            context.setStrokeColor(Token.tileEdge.cg)
            context.setLineWidth(hair)
            context.addPath(roundedPath(
                CGRect(x: 0, y: 0, width: side, height: side).insetBy(dx: hair / 2,
                                                                     dy: hair / 2),
                max(0, tileRadius - hair / 2)))
            context.strokePath()
        }
    }

    let frameInk = ground == .template ? Token.mono
                                       : (smallBoards[size]?.frameColour ?? frameColour(for: size))
    let accentInk = ground == .template ? Token.mono : Token.accent

    if let board = smallBoards[size] {
        // Hand-drawn: whole pixels, square corners, and the one-pixel gap.
        context.setStrokeColor(frameInk.cg)
        context.setLineWidth(1)
        context.stroke(CGRect(x: CGFloat(board.frame.x) + 0.5,
                              y: CGFloat(board.frame.y) + 0.5,
                              width: CGFloat(board.frame.w) - 1,
                              height: CGFloat(board.frame.h) - 1))
        context.setFillColor(accentInk.cg)
        context.fill(CGRect(x: CGFloat(board.accent.x), y: CGFloat(board.accent.y),
                            width: CGFloat(board.accent.w),
                            height: CGFloat(board.accent.h)))
    } else {
        // Snap to whole pixels at every size small enough for the grid to show.
        //
        // The fractions land on quarter-pixels at 32 and 48, and Core Graphics
        // does exactly what it is asked: it anti-aliases a one-pixel hairline
        // across two columns at half strength each. The mark then arrives in the
        // taskbar visibly softer than the 24 beside it, which reads as a
        // low-resolution icon rather than a small one. Above 128 nobody can see
        // the difference and the fractions stay exact.
        let snapRects = size <= 128
        let snapStroke = size <= 48
        func snap(_ value: CGFloat) -> CGFloat { snapRects ? (value).rounded() : value }

        var stroke = strokeWidth(for: size)
        if snapStroke { stroke = max(1, stroke.rounded()) }
        var frameRadius = size >= 32 ? side * 0.055 : 0
        var accentRadius = size >= 32 ? side * 0.047 : 0
        if snapRects {
            frameRadius = frameRadius.rounded()
            accentRadius = accentRadius.rounded()
        }

        // Inset by half the stroke: box-shadow's `inset` in the design draws the
        // line INSIDE the box, and a centred stroke would put half of it outside
        // and change the mark's bounding box. With an odd stroke on a snapped
        // rect that inset is exactly the half-pixel a crisp hairline wants.
        let frame = CGRect(x: snap(side * Frac.frameX), y: snap(side * Frac.frameY),
                           width: snap(side * Frac.frameW),
                           height: snap(side * Frac.frameH))
            .insetBy(dx: stroke / 2, dy: stroke / 2)
        context.setStrokeColor(frameInk.cg)
        context.setLineWidth(stroke)
        context.addPath(roundedPath(frame, max(0, frameRadius - stroke / 2)))
        context.strokePath()

        context.setFillColor(accentInk.cg)
        context.addPath(roundedPath(
            CGRect(x: snap(side * Frac.accentX), y: snap(side * Frac.accentY),
                   width: snap(side * Frac.accentW), height: snap(side * Frac.accentH)),
            accentRadius))
        context.fillPath()
    }

    return context.makeImage()!
}

// ── Output ───────────────────────────────────────────────────────────────────

func pngData(_ image: CGImage) -> Data {
    let out = NSMutableData()
    let destination = CGImageDestinationCreateWithData(out, UTType.png.identifier as CFString,
                                                       1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return out as Data
}

func write(_ data: Data, to path: String) {
    try! data.write(to: URL(fileURLWithPath: path))
}

/// A Windows .ico, assembled by hand.
///
/// It is a directory of images rather than an image: a six-byte header, one
/// sixteen-byte entry per size, then the payloads. Every entry here is a PNG,
/// which Windows has accepted at any size since Vista — the alternative is a
/// bottom-up BGRA DIB plus a separate 1-bit AND mask per size, for a format
/// nothing this ships to still needs.
func icoData(_ images: [(size: Int, png: Data)]) -> Data {
    var out = Data()
    out.append(contentsOf: [0, 0, 1, 0])                                   // reserved, type=icon
    out.append(contentsOf: withUnsafeBytes(of: UInt16(images.count).littleEndian, Array.init))

    var offset = 6 + 16 * images.count
    for image in images {
        // 0 means 256 in a single byte, which is the format's own convention.
        let dimension = UInt8(image.size >= 256 ? 0 : image.size)
        out.append(contentsOf: [dimension, dimension, 0, 0])               // w, h, palette, reserved
        out.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian, Array.init))   // planes
        out.append(contentsOf: withUnsafeBytes(of: UInt16(32).littleEndian, Array.init))  // bpp
        out.append(contentsOf: withUnsafeBytes(of: UInt32(image.png.count).littleEndian, Array.init))
        out.append(contentsOf: withUnsafeBytes(of: UInt32(offset).littleEndian, Array.init))
        offset += image.png.count
    }
    for image in images { out.append(image.png) }
    return out
}

// ── Cut everything ───────────────────────────────────────────────────────────

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "out"
let fm = FileManager.default
try? fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

// macOS: squircle at 22.4%, drawn per size. 16 and 32 are their own artboards
// rather than downsamples of 1024 — which is what the .icns format is for.
let iconset = "\(outDir)/AppIcon.iconset"
try? fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, size) in [("icon_16x16", 16), ("icon_16x16@2x", 32),
                     ("icon_32x32", 32), ("icon_32x32@2x", 64),
                     ("icon_128x128", 128), ("icon_128x128@2x", 256),
                     ("icon_256x256", 256), ("icon_256x256@2x", 512),
                     ("icon_512x512", 512), ("icon_512x512@2x", 1024)] {
    let image = drawMark(size: size, ground: .dark, tileRadius: CGFloat(size) * 0.224)
    write(pngData(image), to: "\(iconset)/\(name).png")
}

// Windows: square corners, because the platform masks nothing — the tile is the
// shape it will actually be seen as. Same art otherwise.
var icoEntries: [(size: Int, png: Data)] = []
for size in [16, 20, 24, 32, 48, 256] {
    let image = drawMark(size: size, ground: .dark, tileRadius: 0)
    let png = pngData(image)
    icoEntries.append((size, png))
    write(png, to: "\(outDir)/windows-\(size).png")
}
write(icoData(icoEntries), to: "\(outDir)/SolStream.ico")

// Menu bar and tray: one flat colour, no tile, for the system to tint. The
// "connected" variant is the same art — the accent is already solid, so what
// changes for a monochrome tray is that the frame drops away, leaving the
// application on its own.
for size in [16, 20, 32, 40] {
    write(pngData(drawMark(size: size, ground: .template, tileRadius: 0)),
          to: "\(outDir)/template-\(size).png")
}

// A review sheet, so a change to the geometry can be looked at rather than
// argued about.
write(pngData(drawMark(size: 512, ground: .dark, tileRadius: 512 * 0.224)),
      to: "\(outDir)/preview-512.png")

/// The small artboards at 8x with interpolation off, on their own pixel grid.
///
/// These are the ones drawn by hand, so they are the ones worth looking at, and
/// at their real size a wrong pixel is invisible. Nearest-neighbour: a smoothed
/// enlargement of a 16px icon shows what the resampler thinks rather than what
/// was drawn, which is the opposite of the point.
func contactSheet(_ sizes: [Int], zoom: Int) -> CGImage {
    let gap = 16
    let width = sizes.reduce(0) { $0 + $1 * zoom + gap } + gap
    let height = (sizes.max() ?? 0) * zoom + gap * 2
    let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                            bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.setFillColor(RGB(0x161826).cg)
    context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: CGFloat(height)))
    context.interpolationQuality = .none

    var x = gap
    for size in sizes {
        let image = drawMark(size: size, ground: .dark, tileRadius: 0)
        let box = CGRect(x: CGFloat(x), y: CGFloat(gap), width: CGFloat(size * zoom),
                         height: CGFloat(size * zoom))
        context.draw(image, in: box)
        // One line per source pixel, so the whole-pixel coordinates the small
        // artboards are specified in can be counted off the sheet.
        context.setStrokeColor(RGB(0xE9E9ED, 0.12).cg)
        context.setLineWidth(1)
        for step in 0...size {
            let offset = CGFloat(step * zoom)
            context.move(to: CGPoint(x: box.minX + offset, y: box.minY))
            context.addLine(to: CGPoint(x: box.minX + offset, y: box.maxY))
            context.move(to: CGPoint(x: box.minX, y: box.minY + offset))
            context.addLine(to: CGPoint(x: box.maxX, y: box.minY + offset))
        }
        context.strokePath()
        x += size * zoom + gap
    }
    return context.makeImage()!
}

write(pngData(contactSheet([16, 20, 24, 32, 48], zoom: 10)), to: "\(outDir)/preview-small.png")

print("wrote \(outDir)/SolStream.ico, \(outDir)/AppIcon.iconset and previews")
