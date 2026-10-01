import CoreGraphics
import CoreText
import Foundation

/// Fill upright horizontal runs using global user-space glyph positions.
/// WebKit's horizontal drawGlyphs transports its FloatPoint through the inverse
/// text matrix; translating the CGContext to a local line anchor first changes
/// PDF rounding after a fractional device-scale/crop transform.
enum NativeCTFontHorizontalFillPainter {
    fileprivate struct Run {
        let font: CTFont
        let glyphs: [CGGlyph]
        let positions: [CGPoint]
        let color: CGColor
    }
    struct PreparedLine {
        fileprivate let records: [Run]
    }

    static func prepare(line: CTLine, horizontalScale: CGFloat = 1) -> PreparedLine? {
        // Nonuniform/condensed layer transforms need their own global-space
        // transport proof. Preserve the existing renderer for those lines.
        guard horizontalScale == 1 else { return nil }
        var records: [Run] = []
        var glyphCount = 0
        for raw in CTLineGetGlyphRuns(line) as! [CTRun] {
            guard CTRunGetTextMatrix(raw) == .identity else { return nil }
            let attributes = CTRunGetAttributes(raw) as NSDictionary
            guard let object = attributes[kCTFontAttributeName],
                  CFGetTypeID(object as CFTypeRef) == CTFontGetTypeID() else { return nil }
            let font = object as! CTFont
            guard CTFontGetMatrix(font) == .identity,
                  CTFontGetSize(font).isFinite, CTFontGetSize(font) > 0,
                  !CTFontGetSymbolicTraits(font).contains(.traitColorGlyphs) else { return nil }
            let percent = CGFloat((attributes[kCTStrokeWidthAttributeName] as? NSNumber)?.doubleValue ?? 0)
            guard percent == 0 else { return nil }
            guard let color = attributes[kCTForegroundColorAttributeName],
                  CFGetTypeID(color as CFTypeRef) == CGColor.typeID else { return nil }
            let count = CTRunGetGlyphCount(raw)
            guard count >= 0, count <= 65_536 - glyphCount else { return nil }
            glyphCount += count
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var positions = [CGPoint](repeating: .zero, count: count)
            CTRunGetGlyphs(raw, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetPositions(raw, CFRange(location: 0, length: 0), &positions)
            guard positions.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            records.append(.init(font: font, glyphs: glyphs, positions: positions, color: color as! CGColor))
        }
        return PreparedLine(records: records)
    }

    @discardableResult
    static func draw(prepared: PreparedLine, context: CGContext, anchor: CGPoint) -> Bool {
        guard anchor.x.isFinite, anchor.y.isFinite,
              Float(anchor.x).isFinite, Float(anchor.y).isFinite else { return false }
        let point = CGPoint(x: CGFloat(Float(anchor.x)), y: CGFloat(Float(anchor.y)))
        let records = prepared.records.map { record in
            Run(font: record.font, glyphs: record.glyphs,
                positions: record.positions.map { CGPoint(x: point.x + $0.x, y: $0.y - point.y) }, color: record.color)
        }
        guard records.allSatisfy({ $0.positions.allSatisfy { $0.x.isFinite && $0.y.isFinite } }) else { return false }
        let matrix = context.textMatrix, position = context.textPosition
        context.saveGState()
        defer {
            context.restoreGState()
            context.textMatrix = matrix
            context.textPosition = position
        }
        // The parent CTM retains device/crop precision. Do not translate it to
        // the line origin: the absolute FloatPoint belongs to glyph positions.
        context.textMatrix = CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: 0)
        context.textPosition = .zero
        context.setTextDrawingMode(.fill)
        for record in records {
            context.saveGState()
            context.setFillColor(record.color)
            CTFontDrawGlyphs(record.font, record.glyphs, record.positions, record.glyphs.count, context)
            context.restoreGState()
        }
        return true
    }
}
