import Foundation
import CoreGraphics
import CoreText

/// Preserve CoreText stroke geometry using the native text-matrix orientation.
/// Only horizontal stroke-only frames qualify. A refusal leaves the caller's
/// existing CTLineDraw path responsible for the entire line.
enum NativeCTFontStrokePainter {
    private struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let color: CGColor
        let lineWidth: CGFloat
    }

    @discardableResult
    static func draw(line: CTLine, context: CGContext, anchor: CGPoint,
                     horizontalScale: CGFloat = 1) -> Bool {
        guard anchor.x.isFinite, anchor.y.isFinite, Float(anchor.x).isFinite, Float(anchor.y).isFinite, horizontalScale.isFinite,
              horizontalScale > 0 else { return false }
        var records: [Run] = []
        // Validate all runs before touching the CGContext: no partial fallback.
        for raw in CTLineGetGlyphRuns(line) as! [CTRun] {
            guard CTRunGetTextMatrix(raw) == .identity else { return false }
            let attrs = CTRunGetAttributes(raw) as NSDictionary
            guard let fontObject = attrs[kCTFontAttributeName],
                  CFGetTypeID(fontObject as CFTypeRef) == CTFontGetTypeID() else { return false }
            let font = fontObject as! CTFont
            guard CTFontGetMatrix(font) == .identity,
                  !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return false }
            let percent = CGFloat((attrs[kCTStrokeWidthAttributeName] as? NSNumber)?.doubleValue ?? 0)
            guard percent.isFinite, percent >= 0 else { return false }
            func color(_ object: Any?) -> CGColor? {
                guard let object, CFGetTypeID(object as CFTypeRef) == CGColor.typeID else { return nil }
                return (object as! CGColor)
            }
            if percent == 0 {
                // Existing horizontal stroke-frame construction makes unstroked
                // runs transparent. Decline any other zero-width paint mode.
                guard let fill = color(attrs[kCTForegroundColorAttributeName]), fill.alpha == 0 else { return false }
                continue
            }
            guard let stroke = color(attrs[kCTStrokeColorAttributeName]) ?? color(attrs[kCTForegroundColorAttributeName]) else { return false }
            let lineWidth = percent * CTFontGetSize(font) / 100
            guard lineWidth.isFinite, lineWidth > 0 else { return false }
            let count = CTRunGetGlyphCount(raw)
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(raw, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(raw, CFRange(location: 0, length: 0), &positions)
            guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
            // Inverse textMatrix(d=-1) preserves the original CTLine geometry.
            positions = positions.map { CGPoint(x: $0.x, y: -$0.y) }
            records.append(Run(font: font, glyphs: glyphs, positions: positions,
                color: stroke, lineWidth: lineWidth))
        }
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
        for record in records {
            context.saveGState()
            context.setStrokeColor(record.color)
            context.setLineWidth(record.lineWidth)
            CTFontDrawGlyphs(record.font, record.glyphs, record.positions, record.glyphs.count, context)
            context.restoreGState()
        }
        return true
    }
}
