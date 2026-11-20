import Foundation
import CoreGraphics
import CoreText

/// Strokes each glyph run of a fill-colored line with an explicit outline width,
/// using the native text-matrix orientation. A refusal leaves the caller's
/// CTLineDraw fallback responsible for the entire line.
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

    /// The outline is `additionalFillStrokeWidth` wide in each run's foreground
    /// color; the caller paints the fill separately.
    static func prepare(line: CTLine, additionalFillStrokeWidth: CGFloat) -> PreparedLine? {
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
            let percent = additional * 100 / fontSize
            guard percent.isFinite else { return nil }
            // A non-positive or non-finite requested width contributes no outline.
            if percent == 0 { continue }
            guard let strokeObject = attrs[kCTForegroundColorAttributeName],
                  CFGetTypeID(strokeObject as CFTypeRef) == CGColor.typeID else { return nil }
            let stroke = strokeObject as! CGColor
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
    static func draw(prepared: PreparedLine, context: CGContext, anchor: CGPoint) -> Bool {
        guard anchor.x.isFinite, anchor.y.isFinite, Float(anchor.x).isFinite, Float(anchor.y).isFinite else { return false }
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
        context.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        context.textPosition = .zero
        context.setTextDrawingMode(.stroke)
        // Round joins: thick outlines grow no spikes at sharp glyph corners (the
        // legacy source-outline paint). Scoped to the saved glyph state.
        context.setLineJoin(.round)
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
