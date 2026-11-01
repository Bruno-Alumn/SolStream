// make-icons.swift — cuts every icon both apps ship from the one logo image.
//
// The source is `source.png`: the blue tile on a white page. The tile is cut out
// of the page by flood-filling the white from the corners, so the logo's own
// white shape inside the tile is never touched, and the pixels along the tile's
// edge, which are blue blended into white, get back the transparency they were
// blended from. Everything else is drawn from that one cut-out.
//
// Run through build.sh, which puts the results where the two builds expect them.

import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

let arguments = CommandLine.arguments
guard arguments.count == 3 else {
    FileHandle.standardError.write("usage: make-icons <source.png> <out-dir>\n".data(using: .utf8)!)
    exit(2)
}
let sourceURL = URL(fileURLWithPath: arguments[1])
let outURL = URL(fileURLWithPath: arguments[2], isDirectory: true)
try FileManager.default.createDirectory(at: outURL, withIntermediateDirectories: true)

let sRGB = CGColorSpace(name: CGColorSpace.sRGB)!

func fail(_ message: String) -> Never {
    FileHandle.standardError.write((message + "\n").data(using: .utf8)!)
    exit(1)
}

// ── The source, as straight RGBA bytes ──────────────────────────────────────

guard let source = CGImageSourceCreateWithURL(sourceURL as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
    fail("could not read \(sourceURL.path)")
}
let width = image.width, height = image.height
var pixels = [UInt8](repeating: 0, count: width * height * 4)
pixels.withUnsafeMutableBytes { raw in
    let context = CGContext(data: raw.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
}

// ── The page, found from its corners ────────────────────────────────────────
//
// Near-white and reachable from a corner without crossing the tile. The logo's
// white shape sits inside the tile, so it is never reached.

func isPage(_ i: Int) -> Bool {
    min(pixels[i * 4], pixels[i * 4 + 1], pixels[i * 4 + 2]) > 232
}
var page = [Bool](repeating: false, count: width * height)
var stack: [Int] = [0, width - 1, (height - 1) * width, height * width - 1]
while let i = stack.popLast() {
    if page[i] || !isPage(i) { continue }
    page[i] = true
    let x = i % width, y = i / width
    if x > 0 { stack.append(i - 1) }
    if x < width - 1 { stack.append(i + 1) }
    if y > 0 { stack.append(i - width) }
    if y < height - 1 { stack.append(i + width) }
}

// ── The tile, with its edge given back its transparency ─────────────────────
//
// An edge pixel is the tile's blue mixed into white. Red tells how much: the
// page's red is 255 and the tile's, at its edge, is close to `edgeRed`. Pixels
// within a few of the page get that as alpha, and their colour unmixed from
// white; deeper ones are the tile itself.

let edgeRed: Double = 10
var minX = width, minY = height, maxX = 0, maxY = 0
var cut = [UInt8](repeating: 0, count: width * height * 4)
for y in 0..<height {
    for x in 0..<width {
        let i = y * width + x
        if page[i] { continue }
        minX = min(minX, x); maxX = max(maxX, x)
        minY = min(minY, y); maxY = max(maxY, y)
        var nearPage = false
        for dy in -3...3 where !nearPage {
            for dx in -3...3 {
                let nx = x + dx, ny = y + dy
                if nx >= 0, nx < width, ny >= 0, ny < height, page[ny * width + nx] {
                    nearPage = true
                    break
                }
            }
        }
        var alpha = 1.0
        var rgb = (Double(pixels[i * 4]), Double(pixels[i * 4 + 1]), Double(pixels[i * 4 + 2]))
        if nearPage {
            alpha = max(0, min(1, (255 - rgb.0) / (255 - edgeRed)))
            if alpha > 0.01 {
                rgb = ((rgb.0 - (1 - alpha) * 255) / alpha,
                       (rgb.1 - (1 - alpha) * 255) / alpha,
                       (rgb.2 - (1 - alpha) * 255) / alpha)
            }
        }
        // Premultiplied, which is what the context below is told it is.
        func channel(_ v: Double) -> UInt8 { UInt8(max(0, min(255, (v * alpha).rounded()))) }
        cut[i * 4] = channel(rgb.0)
        cut[i * 4 + 1] = channel(rgb.1)
        cut[i * 4 + 2] = channel(rgb.2)
        cut[i * 4 + 3] = UInt8((alpha * 255).rounded())
    }
}

// Square about the tile's centre, so a tile a pixel taller than it is wide is
// not stretched.
let side = max(maxX - minX, maxY - minY) + 1
let centreX = (minX + maxX + 1) / 2, centreY = (minY + maxY + 1) / 2
let cropRect = CGRect(x: centreX - side / 2, y: centreY - side / 2, width: side, height: side)

let cutImage: CGImage = cut.withUnsafeMutableBytes { raw in
    let context = CGContext(data: raw.baseAddress, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: width * 4, space: sRGB,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    return context.makeImage()!
}
// CGImage's crop counts rows from the top, as the buffer does.
guard let tile = cutImage.cropping(to: cropRect) else { fail("could not crop the tile") }
print("tile \(side)x\(side) at \(Int(cropRect.minX)),\(Int(cropRect.minY))")

// ── Drawing at any size ─────────────────────────────────────────────────────

func context(_ size: Int) -> CGContext {
    let c = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8,
                      bytesPerRow: 0, space: sRGB,
                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    c.interpolationQuality = .high
    return c
}

/// The tile at `size`, halved step by step on the way down: one draw from
/// about 1,200 pixels to 16 skips most of the source and leaves the thin
/// lines inside the logo ragged.
func scaled(_ image: CGImage, to size: Int) -> CGImage {
    var current = image
    while current.width / 2 >= size * 2 {
        let half = current.width / 2
        let c = context(half)
        c.draw(current, in: CGRect(x: 0, y: 0, width: half, height: half))
        current = c.makeImage()!
    }
    let c = context(size)
    c.draw(current, in: CGRect(x: 0, y: 0, width: size, height: size))
    return c.makeImage()!
}

/// The tile placed in a square canvas, inset by `inset` of the canvas on every
/// side, with an optional shadow below it.
func icon(_ size: Int, inset: Double, shadow: Bool) -> CGImage {
    let margin = (Double(size) * inset).rounded()
    let tileSide = max(1, size - 2 * Int(margin))
    let art = scaled(tile, to: tileSide)
    let c = context(size)
    if shadow {
        c.setShadow(offset: CGSize(width: 0, height: -Double(size) * 0.01),
                    blur: Double(size) * 0.02,
                    color: CGColor(gray: 0, alpha: 0.30))
    }
    c.draw(art, in: CGRect(x: margin, y: margin, width: Double(tileSide), height: Double(tileSide)))
    return c.makeImage()!
}

func pngData(_ image: CGImage) -> Data {
    let data = NSMutableData()
    let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    CGImageDestinationFinalize(destination)
    return data as Data
}

func write(_ image: CGImage, _ name: String) throws {
    try pngData(image).write(to: outURL.appendingPathComponent(name))
}

// ── macOS: the .iconset that iconutil packs ─────────────────────────────────
//
// Apple's grid: the tile is 824 of 1,024, centred, with a soft shadow, so the
// icon sits at the same size as every other app in the Dock.

let iconset = outURL.appendingPathComponent("AppIcon.iconset", isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = points * scale
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try pngData(icon(pixels, inset: 100.0 / 1024, shadow: pixels >= 64))
            .write(to: iconset.appendingPathComponent(name))
    }
}

// ── Windows: a .ico of PNG entries ──────────────────────────────────────────
//
// Windows masks nothing and draws icons edge to edge, so the tile fills the
// square but for a hair. The sizes are the ones Windows asks for at 100% to
// 200% scaling; the lockup in the host window asks for 38 to 76.

let icoSizes = [16, 20, 24, 32, 38, 40, 48, 57, 64, 76, 96, 128, 256]
var entries: [(Int, Data)] = []
for size in icoSizes {
    entries.append((size, pngData(icon(size, inset: size < 32 ? 0 : 0.02, shadow: false))))
}
var ico = Data()
func le16(_ v: Int) { ico.append(UInt8(v & 0xFF)); ico.append(UInt8((v >> 8) & 0xFF)) }
func le32(_ v: Int) { le16(v & 0xFFFF); le16((v >> 16) & 0xFFFF) }
le16(0); le16(1); le16(entries.count)
var offset = 6 + 16 * entries.count
for (size, data) in entries {
    ico.append(UInt8(size >= 256 ? 0 : size))
    ico.append(UInt8(size >= 256 ? 0 : size))
    ico.append(0); ico.append(0)
    le16(1); le16(32)
    le32(data.count); le32(offset)
    offset += data.count
}
for (_, data) in entries { ico.append(data) }
try ico.write(to: outURL.appendingPathComponent("SolStream.ico"))

// ── For the README and for looking at ───────────────────────────────────────

try write(icon(512, inset: 0, shadow: false), "icon.png")
try write(icon(512, inset: 100.0 / 1024, shadow: true), "preview-512.png")
let strip = context(16 + 24 + 32 + 48 + 64 + 128 + 7 * 16)
var x = 8.0
for size in [16, 24, 32, 48, 64, 128] {
    strip.draw(icon(size, inset: size < 32 ? 0 : 0.02, shadow: false),
               in: CGRect(x: x, y: 8, width: Double(size), height: Double(size)))
    x += Double(size) + 16
}
try write(strip.makeImage()!, "preview-sizes.png")
print("wrote \(outURL.path)")
