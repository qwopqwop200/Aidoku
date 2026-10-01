import Foundation
import CoreGraphics
import CoreText

/// Draw an upright vertical line at a caller-owned top-left page anchor.
/// The caller derives the CSS baseline and inline alignment. This adapter
/// preserves the selected run font, glyphs, and Core Text's vertical positions.
/// Stroke and sideways runs retain the caller's existing native frame path.
enum NativeCTFontVerticalPainter {
    fileprivate struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let color: CGColor
    }

    struct PreparedLine {
        fileprivate let records: [Run]
    }

    /// Preflight every line in a frame before any paint, so a fallback frame
    /// draw cannot duplicate earlier accepted lines after a later refusal.
    static func prepare(line: CTLine) -> PreparedLine? {
        let vertical = CGAffineTransform(a: 0, b: 1, c: -1, d: 0, tx: 0, ty: 0)
        var records: [Run] = []
        var glyphCount = 0
        // Validate the complete line before touching any graphics or text state.
        for raw in CTLineGetGlyphRuns(line) as! [CTRun] {
            guard CTRunGetTextMatrix(raw) == vertical else { return nil }
            let attributes = CTRunGetAttributes(raw) as NSDictionary
            guard let object = attributes[kCTFontAttributeName],
                  CFGetTypeID(object as CFTypeRef) == CTFontGetTypeID() else { return nil }
            let font = object as! CTFont
            guard CTFontGetMatrix(font) == .identity,
                  CTFontGetSize(font).isFinite, CTFontGetSize(font) > 0,
                  !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return nil }
            let count = CTRunGetGlyphCount(raw)
            guard count >= 0, count <= 65_536 - glyphCount else { return nil }
            glyphCount += count
            func color(_ object: Any?) -> CGColor? {
                guard let object, CFGetTypeID(object as CFTypeRef) == CGColor.typeID else { return nil }
                return (object as! CGColor)
            }
            // Public glyph stroke transport is a separate unresolved contract.
            // Decline the entire stroke pass before any output is changed.
            let percent = CGFloat((attributes[kCTStrokeWidthAttributeName] as? NSNumber)?.doubleValue ?? 0)
            guard percent == 0 else { return nil }
            let paint = color(attributes[kCTForegroundColorAttributeName])
            guard let paint else { return nil }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(raw, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(raw, CFRange(location: 0, length: 0), &positions)
            guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            records.append(.init(font: font, glyphs: glyphs, positions: positions, color: paint))
        }
        return PreparedLine(records: records)
    }

    static func supports(line: CTLine) -> Bool {
        prepare(line: line) != nil
    }

    @discardableResult
    static func draw(line: CTLine, context: CGContext, anchor: CGPoint) -> Bool {
        guard let prepared = prepare(line: line) else { return false }
        return draw(prepared: prepared, context: context, anchor: anchor)
    }

    @discardableResult
    static func draw(prepared: PreparedLine, context: CGContext, anchor: CGPoint) -> Bool {
        guard anchor.x.isFinite, anchor.y.isFinite,
              Float(anchor.x).isFinite, Float(anchor.y).isFinite else { return false }
        let matrix = context.textMatrix
        let position = context.textPosition
        context.saveGState()
        defer {
            context.restoreGState()
            // Quartz does not restore these text-state properties with gstate.
            context.textMatrix = matrix
            context.textPosition = position
        }
        context.translateBy(x: CGFloat(Float(anchor.x)), y: CGFloat(Float(anchor.y)))
        context.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        context.textPosition = .zero
        for record in prepared.records {
            context.saveGState()
            context.setTextDrawingMode(.fill)
            context.setFillColor(record.color)
            // Vertical run positions already include vertical translations.
            // Inverting their Y as for horizontal strokes moves glyphs twice.
            CTFontDrawGlyphs(record.font, record.glyphs, record.positions, record.glyphs.count, context)
            context.restoreGState()
        }
        return true
    }
}
