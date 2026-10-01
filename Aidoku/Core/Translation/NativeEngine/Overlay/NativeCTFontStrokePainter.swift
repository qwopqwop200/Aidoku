import Foundation
import CoreGraphics
import CoreText

/// Preserve CoreText stroke geometry using the native text-matrix orientation.
/// Only horizontal stroke-only frames qualify. A refusal leaves the caller's
/// existing CTLineDraw path responsible for the entire line.
enum NativeCTFontStrokePainter {
    fileprivate struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let color: CGColor
        let lineWidth: CGFloat
    }

    struct PreparedLine {
        fileprivate let records: [Run]
    }

    /// Split paint attributes without asking Core Text to shape the same line again.
    /// The combined mode accepts the negative stroke widths used by measured layouts.
    static func prepare(line: CTLine, includesFill: Bool = false,
                        additionalFillStrokeWidth: CGFloat = 0) -> PreparedLine? {
        var records: [Run] = []
        var glyphCount = 0
        let additional = additionalFillStrokeWidth.isFinite && additionalFillStrokeWidth > 0
            ? additionalFillStrokeWidth : 0
        // Validate all runs before touching the CGContext: no partial fallback.
        for raw in CTLineGetGlyphRuns(line) as! [CTRun] {
            guard CTRunGetTextMatrix(raw) == .identity else { return nil }
            let attrs = CTRunGetAttributes(raw) as NSDictionary
            guard let fontObject = attrs[kCTFontAttributeName],
                  CFGetTypeID(fontObject as CFTypeRef) == CTFontGetTypeID() else { return nil }
            let font = fontObject as! CTFont
            let fontSize = CTFontGetSize(font)
            guard CTFontGetMatrix(font) == .identity, fontSize.isFinite, fontSize > 0,
                  !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return nil }
            let percent = additional > 0 ? additional * 100 / fontSize
                : CGFloat((attrs[kCTStrokeWidthAttributeName] as? NSNumber)?.doubleValue ?? 0)
            guard percent.isFinite, includesFill || percent >= 0 else { return nil }
            func color(_ object: Any?) -> CGColor? {
                guard let object, CFGetTypeID(object as CFTypeRef) == CGColor.typeID else { return nil }
                return (object as! CGColor)
            }
            if percent == 0 {
                // Combined layouts keep ordinary fill-only runs; they contribute
                // no outline. Legacy stroke-only frames make those runs transparent.
                guard includesFill || color(attrs[kCTForegroundColorAttributeName])?.alpha == 0 else { return nil }
                continue
            }
            let stroke = additional > 0 ? color(attrs[kCTForegroundColorAttributeName])
                : color(attrs[kCTStrokeColorAttributeName]) ?? color(attrs[kCTForegroundColorAttributeName])
            guard let stroke else { return nil }
            let lineWidth = abs(percent) * fontSize / 100
            guard lineWidth.isFinite, lineWidth > 0 else { return nil }
            let count = CTRunGetGlyphCount(raw)
            guard count >= 0, count <= 65_536 - glyphCount else { return nil }
            glyphCount += count
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(raw, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(raw, CFRange(location: 0, length: 0), &positions)
            guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            // Inverse textMatrix(d=-1) preserves the original CTLine geometry.
            positions = positions.map { CGPoint(x: $0.x, y: -$0.y) }
            records.append(Run(font: font, glyphs: glyphs, positions: positions,
                color: stroke, lineWidth: lineWidth))
        }
        return PreparedLine(records: records)
    }

    @discardableResult
    static func draw(line: CTLine, context: CGContext, anchor: CGPoint,
                     horizontalScale: CGFloat = 1) -> Bool {
        guard let prepared = prepare(line: line) else { return false }
        return draw(prepared: prepared, context: context, anchor: anchor, horizontalScale: horizontalScale)
    }

    @discardableResult
    static func draw(prepared: PreparedLine, context: CGContext, anchor: CGPoint,
                     horizontalScale: CGFloat = 1) -> Bool {
        guard anchor.x.isFinite, anchor.y.isFinite, Float(anchor.x).isFinite, Float(anchor.y).isFinite,
              horizontalScale.isFinite, horizontalScale > 0 else { return false }
        // Quartz text state is not part of the saved graphics state. Preserve
        // it explicitly so the following CTLine fill pass keeps its orientation.
        let textMatrix = context.textMatrix
        let textPosition = context.textPosition
        context.saveGState()
        defer {
            context.restoreGState()
            context.textMatrix = textMatrix
            context.textPosition = textPosition
        }
        context.translateBy(x: CGFloat(Float(anchor.x)), y: CGFloat(Float(anchor.y)))
        context.scaleBy(x: horizontalScale, y: 1)
        context.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        context.textPosition = .zero
        context.setTextDrawingMode(.stroke)
        // CSS text outlines use miter limit 4; Quartz's default 10 extends
        // sharp inner counters. Keep this scoped to the saved glyph state.
        context.setMiterLimit(4)
        for record in prepared.records {
            context.saveGState()
            context.setStrokeColor(record.color)
            context.setLineWidth(record.lineWidth)
            CTFontDrawGlyphs(record.font, record.glyphs, record.positions, record.glyphs.count, context)
            context.restoreGState()
        }
        return true
    }
}
