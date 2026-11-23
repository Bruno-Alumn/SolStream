import CoreGraphics

/// Where on the capture display a window added to a running stream may go.
///
/// Every streamed window is a crop of one shared picture, so two host windows
/// that overlap each show the other: the crop takes whatever is at those
/// pixels. A window added later has to be given pixels nobody else is using,
/// and the ones already there have to stay out of them afterwards.
///
/// All of it is in capture-display pixels, in the host's virtual-desktop
/// coordinates, the same space `tileLayout` and `place` use. Pure, so the rules
/// can be tested without a PC.
enum TileAllocator {
    /// The smallest a window is shrunk to before there is said to be no room:
    /// the Mac window's own minimum, 320x200 points, at a Retina scale.
    static let minimumSize = CGSize(width: 640, height: 400)

    /// Pixels kept clear around every window in use. A Windows window is more
    /// than its client area: the invisible resize border and the shadow are
    /// drawn outside it, and a neighbour placed hard against it has those in
    /// its crop.
    static let gap: CGFloat = 16

    /// The most windows the host holds at once (`kMaxLocks` on the PC).
    static let maxWindows = 8

    /// A free rectangle of `wanted`'s shape, or nil when nothing fits.
    ///
    /// Full size if there is room for it anywhere; otherwise as big as it can
    /// be with the same proportions, down to `minimum`. Of equally good places,
    /// the highest, then the leftmost.
    ///
    /// - Parameters:
    ///   - canvas: the capture display.
    ///   - inUse: what the windows already there cover, frame and all.
    ///   - wanted: the size asked for, frame and all.
    static func allocate(canvas: CGRect, inUse: [CGRect], wanted: CGSize,
                         minimum: CGSize = minimumSize, gap: CGFloat = gap) -> CGRect? {
        guard canvas.width >= 1, canvas.height >= 1,
              wanted.width >= 1, wanted.height >= 1 else { return nil }
        let taken = inUse.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .map { $0.insetBy(dx: -gap, dy: -gap) }

        // A free rectangle as big as it can be has its top-left corner on the
        // canvas's edge or on the far edge of something taken, so those are the
        // only corners worth trying.
        let xs = Set([canvas.minX] + taken.map(\.maxX)).filter { $0 >= canvas.minX && $0 < canvas.maxX }
        let ys = Set([canvas.minY] + taken.map(\.maxY)).filter { $0 >= canvas.minY && $0 < canvas.maxY }
        let corners = ys.sorted().flatMap { y in xs.sorted().map { CGPoint(x: $0, y: y) } }

        var best: (scale: CGFloat, corner: CGPoint)?
        for corner in corners {
            let scale = largestScale(at: corner, wanted: wanted, canvas: canvas, taken: taken)
            // Strictly greater: the first of equals is the highest, leftmost.
            if scale > (best?.scale ?? 0) { best = (scale, corner) }
        }
        guard let best else { return nil }
        let size = CGSize(width: (wanted.width * best.scale).rounded(.down),
                          height: (wanted.height * best.scale).rounded(.down))
        guard size.width >= min(minimum.width, wanted.width),
              size.height >= min(minimum.height, wanted.height) else { return nil }
        return CGRect(origin: best.corner, size: size)
    }

    /// How much of `wanted`, at most all of it, fits with its top-left at
    /// `corner` without leaving the canvas or touching anything taken.
    private static func largestScale(at corner: CGPoint, wanted: CGSize,
                                     canvas: CGRect, taken: [CGRect]) -> CGFloat {
        var scale = min(1, (canvas.maxX - corner.x) / wanted.width,
                        (canvas.maxY - corner.y) / wanted.height)
        for rect in taken {
            // Wholly left of or above the corner: no rectangle growing right
            // and down from it can reach this one.
            if rect.maxX <= corner.x || rect.maxY <= corner.y { continue }
            // Ending before it on either axis is enough to miss it.
            let across = rect.minX > corner.x ? (rect.minX - corner.x) / wanted.width : 0
            let down = rect.minY > corner.y ? (rect.minY - corner.y) / wanted.height : 0
            scale = min(scale, max(across, down))
        }
        return max(scale, 0)
    }

    /// The most room a window covering `current` can have: a rectangle that
    /// holds all of `current`, stays on `canvas`, and keeps `gap` clear of
    /// every one of `others`. What a window may grow into, and no further.
    ///
    /// Grown out from `current` one side at a time -- left and right then up
    /// and down, and the other way round -- keeping whichever covers more. Free
    /// space beside a neighbour is a staircase with no one biggest rectangle;
    /// either answer is free all over and holds the window as it is.
    ///
    /// Never smaller than `current` on the canvas, even where `current` already
    /// reaches a neighbour (an application that would not be made small
    /// enough): that overlap is not made worse, and is not the window's to
    /// undo. With no others it is the whole canvas.
    ///
    /// - Parameters:
    ///   - current: what the window covers now, frame and all.
    ///   - others: what every other window covers, frame and all.
    static func room(around current: CGRect, others: [CGRect], canvas: CGRect,
                     gap: CGFloat = gap) -> CGRect {
        let start = current.intersection(canvas)
        guard !start.isNull, start.width > 0, start.height > 0 else { return canvas }
        let blocks = others.filter { !$0.isNull && $0.width > 0 && $0.height > 0 }
            .map { $0.insetBy(dx: -gap, dy: -gap) }
        let across = grow(vertically: grow(horizontally: start, canvas: canvas, blocks: blocks),
                          canvas: canvas, blocks: blocks)
        let down = grow(horizontally: grow(vertically: start, canvas: canvas, blocks: blocks),
                        canvas: canvas, blocks: blocks)
        return across.width * across.height >= down.width * down.height ? across : down
    }

    /// The largest size a window at `origin`, now `size` big, can be made by
    /// growing right and down. See `room(around:)`, whose size this is when
    /// nothing to the left or above is free.
    static func maxSize(for size: CGSize, origin: CGPoint, others: [CGRect], canvas: CGRect,
                        gap: CGFloat = gap) -> CGSize {
        let from = CGRect(x: origin.x, y: origin.y, width: canvas.maxX - origin.x,
                          height: canvas.maxY - origin.y)
        let room = room(around: CGRect(origin: origin, size: size), others: others,
                        canvas: from.intersection(canvas), gap: gap)
        return room.size
    }

    /// `rect` made as wide as it can be without its rows reaching a block.
    private static func grow(horizontally rect: CGRect, canvas: CGRect, blocks: [CGRect]) -> CGRect {
        var left = canvas.minX
        var right = canvas.maxX
        for block in blocks where block.minY < rect.maxY && rect.minY < block.maxY {
            if block.minX < rect.minX { left = max(left, min(block.maxX, rect.minX)) }
            if block.maxX > rect.maxX { right = min(right, max(block.minX, rect.maxX)) }
        }
        return CGRect(x: left, y: rect.minY, width: right - left, height: rect.height)
    }

    /// `rect` made as tall as it can be without its columns reaching a block.
    private static func grow(vertically rect: CGRect, canvas: CGRect, blocks: [CGRect]) -> CGRect {
        var top = canvas.minY
        var bottom = canvas.maxY
        for block in blocks where block.minX < rect.maxX && rect.minX < block.maxX {
            if block.minY < rect.minY { top = max(top, min(block.maxY, rect.minY)) }
            if block.maxY > rect.maxY { bottom = min(bottom, max(block.minY, rect.maxY)) }
        }
        return CGRect(x: rect.minX, y: top, width: rect.width, height: bottom - top)
    }

    /// Sharing area, not just an edge.
    static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY
    }
}
