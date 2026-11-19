import CoreGraphics
import CoreText
import Foundation

// S10: paint placed translations over the restored page in one pass.
// Each line is shaped once per paint colour and drawn through the native glyph
// painters (stroke first, then fill), with CTLineDraw as the fallback for lines
// those painters decline (for example colour emoji). Geometry comes only from
// V2Layout (frame, font size, wrapped lines), so painted ink stays in the frame.
//
// Cost: the background is copied into the output bitmap once (a row copy when
// its pixel format already matches, else one CGContext.draw); fonts are created
// once per size; each line is shaped once for measuring and filling. Every item
// draws only inside its own clip, so items whose clips share no device pixel
// rasterize concurrently into the same bitmap (overlapping items stay together,
// in order). Each pixel is still written by the same items in the same order,
// so the output equals painting them one after another.
enum V2Painter {
    static func paint(background: CGImage, blocks: [V2Block], placed: [V2PlacedText]) -> CGImage {
        let width = background.width, height = background.height
        guard width > 0, height > 0, !placed.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return background }
        if !copyPixels(of: background, into: context) {
            context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        configure(context, height: height, page: page)
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let metrics = V2Layout.metrics()
        var fonts: [CGFloat: CTFont] = [:]
        let jobs: [Job] = placed.compactMap { item in
            guard item.fontPixels.isFinite, item.fontPixels > 0, let block = byID[item.blockID] else { return nil }
            let font = fonts[item.fontPixels] ?? V2Layout.font(size: item.fontPixels)
            fonts[item.fontPixels] = font
            return Job(item: item, block: block, font: font, clip: item.frame.insetBy(dx: -2, dy: -2).intersection(page))
        }
        let groups = independentGroups(jobs.map(\.clip))
        // Further views of the same bitmap, each in the same state as `context`.
        let tiles = groups.count > 1 ? groups.indices.compactMap { _ in
            CGContext(data: context.data, width: width, height: height, bitsPerComponent: 8,
                      bytesPerRow: context.bytesPerRow, space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        } : []
        if context.data != nil, tiles.count == groups.count, groups.count > 1 {
            let views = Tiles(contexts: tiles)
            DispatchQueue.concurrentPerform(iterations: groups.count) { group in
                let tile = views.contexts[group]
                configure(tile, height: height, page: page)
                for index in groups[group] { draw(jobs[index], metrics: metrics, context: tile, page: page) }
            }
        } else {
            for job in jobs { draw(job, metrics: metrics, context: context, page: page) }
        }
        return context.makeImage() ?? background
    }

    private struct Job: @unchecked Sendable {
        let item: V2PlacedText
        let block: V2Block
        let font: CTFont
        let clip: CGRect
    }

    /// Each context is used by exactly one concurrent iteration.
    private struct Tiles: @unchecked Sendable {
        let contexts: [CGContext]
    }

    /// Top-left page coordinates, antialiased, clipped to the page (matches V2Layout).
    private static func configure(_ context: CGContext, height: Int, page: CGRect) {
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        context.clip(to: page)
    }

    /// Partitions item indices into groups whose clips can share no device pixel
    /// (each clip widened to whole pixels plus a one-pixel guard); clips that do
    /// overlap, directly or through a chain, stay in one group in paint order.
    /// Any null, empty or non-finite clip keeps every item in a single group.
    static func independentGroups(_ clips: [CGRect]) -> [[Int]] {
        guard !clips.isEmpty else { return [] }
        var cells: [CGRect] = []
        for clip in clips {
            guard !clip.isNull, !clip.isEmpty, clip.minX.isFinite, clip.minY.isFinite,
                  clip.maxX.isFinite, clip.maxY.isFinite else { return [Array(clips.indices)] }
            cells.append(CGRect(x: floor(clip.minX) - 1, y: floor(clip.minY) - 1,
                                width: ceil(clip.maxX) - floor(clip.minX) + 2,
                                height: ceil(clip.maxY) - floor(clip.minY) + 2))
        }
        var parent = Array(clips.indices)
        func root(_ index: Int) -> Int {
            var index = index
            while parent[index] != index { parent[index] = parent[parent[index]]; index = parent[index] }
            return index
        }
        for index in cells.indices {
            for other in cells.indices where other > index {
                let overlap = cells[index].intersection(cells[other])
                if !overlap.isNull, overlap.width > 0, overlap.height > 0 { parent[root(other)] = root(index) }
            }
        }
        var groups: [Int: [Int]] = [:]
        var order: [Int] = []
        for index in clips.indices {
            let key = root(index)
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(index)
        }
        return order.map { groups[$0]! }
    }

    /// Copies a same-format background (sRGB RGBA8 premultipliedLast, as
    /// produced by V2PageRaster) straight into the fresh, zeroed bitmap. Drawing
    /// such an image source-over onto transparent black at identity scale yields
    /// exactly its bytes, so this is the same result without a compositing pass.
    static func copyPixels(of image: CGImage, into context: CGContext) -> Bool {
        let order = image.bitmapInfo.intersection(.byteOrderMask)
        guard image.width == context.width, image.height == context.height,
              image.bitsPerComponent == 8, image.bitsPerPixel == 32, image.alphaInfo == .premultipliedLast,
              order.rawValue == CGImageByteOrderInfo.orderDefault.rawValue
                || order.rawValue == CGImageByteOrderInfo.order32Big.rawValue,
              !image.bitmapInfo.contains(.floatComponents), image.decode == nil, !image.isMask,
              let imageSpace = image.colorSpace, let contextSpace = context.colorSpace,
              CFEqual(imageSpace, contextSpace),
              context.bitsPerPixel == 32, context.bitsPerComponent == 8, context.alphaInfo == .premultipliedLast,
              let destination = context.data, let data = image.dataProvider?.data
        else { return false }
        let rowBytes = image.width * 4, sourceStride = image.bytesPerRow, destinationStride = context.bytesPerRow
        guard sourceStride >= rowBytes, destinationStride >= rowBytes,
              CFDataGetLength(data) >= (image.height - 1) * sourceStride + rowBytes,
              let source = CFDataGetBytePtr(data) else { return false }
        if sourceStride == destinationStride {
            destination.copyMemory(from: source, byteCount: (image.height - 1) * sourceStride + rowBytes)
        } else {
            for row in 0..<image.height {
                (destination + row * destinationStride).copyMemory(from: source + row * sourceStride, byteCount: rowBytes)
            }
        }
        return true
    }

    static func color(_ rgb: V2RGB) -> CGColor {
        CGColor(srgbRed: CGFloat(rgb.r) / 255, green: CGFloat(rgb.g) / 255, blue: CGFloat(rgb.b) / 255, alpha: 1)
    }

    /// Fill and optional stroke colours; without a style, black text with a white outline.
    static func paints(for block: V2Block) -> (fill: CGColor, stroke: CGColor?) {
        guard let style = block.style else {
            return (CGColor(srgbRed: 0, green: 0, blue: 0, alpha: 1), CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
        }
        return (color(style.textColor), style.strokeColor.map(color))
    }

    /// Baseline origins (top-left page coordinates) for each line/glyph cell of `item`,
    /// with each measured line (shaped with `color`) for drawing. Horizontal: one origin
    /// per line with its measured width. Vertical: one per character.
    /// Colour does not change shaping or typographic width.
    private static func runs(for item: V2PlacedText, stroke: CGFloat, metrics: V2Layout.FontMetrics, font: CTFont,
                             color: CGColor) -> [(text: String, origin: CGPoint, line: CTLine)] {
        let size = item.fontPixels
        let ascent = metrics.ascent * size, glyph = (metrics.ascent + metrics.descent) * size
        var result: [(String, CGPoint, CTLine)] = []
        if !item.vertical {
            let lineHeight = size * V2Layout.lineHeightEm
            for (index, text) in item.lines.enumerated() {
                let shaped = line(text, font: font, color: color)
                let width = CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil))
                let top = item.frame.minY + stroke + CGFloat(index) * lineHeight
                result.append((text, CGPoint(x: item.frame.midX - width / 2, y: top + (lineHeight - glyph) / 2 + ascent),
                               shaped))
            }
            return result
        }
        let columnWidth = size * V2Layout.lineHeightEm, cell = size * V2Layout.verticalAdvanceEm
        for (column, text) in item.lines.enumerated() {
            let centre = item.frame.maxX - stroke - (CGFloat(column) + 0.5) * columnWidth
            var y = item.frame.minY + stroke
            for character in text {
                if character == " " { y += cell / 2; continue }
                let string = String(character)
                let shaped = line(string, font: font, color: color)
                let width = CGFloat(CTLineGetTypographicBounds(shaped, nil, nil, nil))
                result.append((string, CGPoint(x: centre - width / 2, y: y + (cell - glyph) / 2 + ascent), shaped))
                y += cell
            }
        }
        return result
    }

    private static func line(_ text: String, font: CTFont, color: CGColor) -> CTLine {
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func draw(_ job: Job, metrics: V2Layout.FontMetrics, context: CGContext, page: CGRect) {
        let item = job.item, block = job.block, font = job.font
        let (fill, strokeColor) = paints(for: block)
        let stroke = V2Layout.strokeWidth(for: block, fontPixels: item.fontPixels)
        let runs = runs(for: item, stroke: stroke, metrics: metrics, font: font, color: fill)
        context.saveGState()
        // Never paint outside the page (layout already clamps frames to it).
        context.clip(to: job.clip)
        if stroke > 0, let strokeColor {
            for run in runs {
                let shaped = line(run.text, font: font, color: strokeColor)
                if let prepared = NativeCTFontStrokePainter.prepare(line: shaped, includesFill: true,
                                                                    additionalFillStrokeWidth: stroke * 2) {
                    NativeCTFontStrokePainter.draw(prepared: prepared, context: context, anchor: run.origin)
                } else {
                    fallback(run.text, font: font, attributes: [
                        NSAttributedString.Key(kCTForegroundColorAttributeName as String): strokeColor,
                        NSAttributedString.Key(kCTStrokeColorAttributeName as String): strokeColor,
                        NSAttributedString.Key(kCTStrokeWidthAttributeName as String): stroke * 200 / item.fontPixels
                    ], origin: run.origin, context: context)
                }
            }
        }
        for run in runs {
            if let prepared = NativeCTFontHorizontalFillPainter.prepare(line: run.line) {
                NativeCTFontHorizontalFillPainter.draw(prepared: prepared, context: context, anchor: run.origin)
            } else {
                fallback(run.text, font: font, attributes: [
                    NSAttributedString.Key(kCTForegroundColorAttributeName as String): fill
                ], origin: run.origin, context: context)
            }
        }
        context.restoreGState()
    }

    private static func fallback(_ text: String, font: CTFont, attributes: [NSAttributedString.Key: Any],
                                 origin: CGPoint, context: CGContext) {
        var attributes = attributes
        attributes[NSAttributedString.Key(kCTFontAttributeName as String)] = font
        let shaped = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
        let matrix = context.textMatrix, position = context.textPosition
        context.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        context.textPosition = origin
        CTLineDraw(shaped, context)
        context.textMatrix = matrix
        context.textPosition = position
    }
}
