import CoreGraphics
import CoreText
import Foundation

// S10: paint placed translations over the restored page in one pass.
// Each line is shaped once per paint colour and drawn through the native glyph
// painters (stroke first, then fill), with CTLineDraw as the fallback for lines
// those painters decline (for example colour emoji). Geometry comes only from
// V2Layout (frame, font size, wrapped lines), so painted ink stays in the frame.
enum V2Painter {
    static func paint(background: CGImage, blocks: [V2Block], placed: [V2PlacedText]) -> CGImage {
        let width = background.width, height = background.height
        guard width > 0, height > 0, !placed.isEmpty,
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return background }
        context.draw(background, in: CGRect(x: 0, y: 0, width: width, height: height))
        // Top-left page coordinates from here on, matching V2Layout.
        context.translateBy(x: 0, y: CGFloat(height))
        context.scaleBy(x: 1, y: -1)
        context.setShouldAntialias(true)
        let page = CGRect(x: 0, y: 0, width: width, height: height)
        context.clip(to: page)
        let byID = Dictionary(blocks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let metrics = V2Layout.metrics()
        for item in placed {
            guard item.fontPixels.isFinite, item.fontPixels > 0, let block = byID[item.blockID] else { continue }
            draw(item, block: block, metrics: metrics, context: context, page: page)
        }
        return context.makeImage() ?? background
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

    /// Baseline origins (top-left page coordinates) for each line/glyph cell of `item`.
    /// Horizontal: one origin per line with its measured width. Vertical: one per character.
    static func origins(for item: V2PlacedText, stroke: CGFloat,
                        metrics: V2Layout.FontMetrics, font: CTFont) -> [(text: String, origin: CGPoint)] {
        let size = item.fontPixels
        let ascent = metrics.ascent * size, glyph = (metrics.ascent + metrics.descent) * size
        var result: [(String, CGPoint)] = []
        if !item.vertical {
            let lineHeight = size * V2Layout.lineHeightEm
            for (index, text) in item.lines.enumerated() {
                let width = CGFloat(CTLineGetTypographicBounds(line(text, font: font, color: nil), nil, nil, nil))
                let top = item.frame.minY + stroke + CGFloat(index) * lineHeight
                result.append((text, CGPoint(x: item.frame.midX - width / 2, y: top + (lineHeight - glyph) / 2 + ascent)))
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
                let width = CGFloat(CTLineGetTypographicBounds(line(string, font: font, color: nil), nil, nil, nil))
                result.append((string, CGPoint(x: centre - width / 2, y: y + (cell - glyph) / 2 + ascent)))
                y += cell
            }
        }
        return result
    }

    private static func line(_ text: String, font: CTFont, color: CGColor?) -> CTLine {
        var attributes: [NSAttributedString.Key: Any] = [NSAttributedString.Key(kCTFontAttributeName as String): font]
        if let color { attributes[NSAttributedString.Key(kCTForegroundColorAttributeName as String)] = color }
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    private static func draw(_ item: V2PlacedText, block: V2Block, metrics: V2Layout.FontMetrics,
                             context: CGContext, page: CGRect) {
        let font = V2Layout.font(size: item.fontPixels)
        let (fill, strokeColor) = paints(for: block)
        let stroke = V2Layout.strokeWidth(for: block, fontPixels: item.fontPixels)
        let runs = origins(for: item, stroke: stroke, metrics: metrics, font: font)
        context.saveGState()
        // Never paint outside the page (layout already clamps frames to it).
        context.clip(to: item.frame.insetBy(dx: -2, dy: -2).intersection(page))
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
            let shaped = line(run.text, font: font, color: fill)
            if let prepared = NativeCTFontHorizontalFillPainter.prepare(line: shaped) {
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
