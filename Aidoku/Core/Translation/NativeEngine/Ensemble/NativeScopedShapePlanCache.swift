import CoreText
import CoreGraphics
import Foundation

/// One serial page transaction. No static state, placement, owner admission, or raster cache.
/// Cached attributed strings are immutable copies; CTLine and value arrays are immutable.
final class NativeScopedShapePlanCache {
    struct Key: Hashable {
        let owner: [UInt16]
        let utf16: [UInt16] // String equality would equate canonically equivalent spellings.
        let font: CTFont
        let color: CGColor
        let numbers: [UInt64]

        init(owner: String, text: String, font: CTFont, size: CGFloat, pitch: CGFloat,
             width: CGFloat, maximumWidth: CGFloat, color: CGColor) {
            self.owner = Array(owner.utf16)
            utf16 = Array(text.utf16)
            self.font = font
            self.color = color
            numbers = [size, pitch, width, maximumWidth].map { Double($0).bitPattern }
        }
        static func == (a: Self, b: Self) -> Bool {
            a.owner == b.owner && a.utf16 == b.utf16 && a.numbers == b.numbers
                && CFEqual(a.font, b.font) && CFEqual(a.color, b.color)
        }
        func hash(into hasher: inout Hasher) {
            hasher.combine(owner); hasher.combine(utf16); hasher.combine(numbers)
            hasher.combine(CFHash(font)); hasher.combine(CFHash(color))
        }
    }

    /// Intrinsic CTLine metrics have no width dependence. The enclosing exact plan
    /// key fixes owner, font, pitch and color; attributed equality fixes every run attribute.
    /// This temporary table is released after one proposal set is constructed.
    final class Measurements {
        private struct LineKey: Hashable {
            let utf16: [UInt16]
            let attributes: NSAttributedString
            init(_ value: NSAttributedString) {
                utf16 = Array(value.string.utf16)
                attributes = value.copy() as! NSAttributedString
            }
        }
        private var lines: [LineKey: CTLine] = [:]
        private var units = 0
        private(set) var hits = 0
        private(set) var misses = 0
        private(set) var peak = 0
        let enabled: Bool
        init(enabled: Bool) { self.enabled = enabled }
        func line(_ attributed: NSAttributedString) -> CTLine {
            let key = enabled ? LineKey(attributed) : nil
            if let key, let found = lines[key] { hits += 1; return found }
            misses += 1
            let result = CTLineCreateWithAttributedString(attributed)
            // Over-budget measurements are still computed and returned, never skipped.
            if enabled, attributed.length <= 2048, lines.count < 256,
               units + attributed.length <= 32768 {
                lines[key!] = result
                units += attributed.length
                peak = max(peak, lines.count)
            }
            return result
        }
    }

    private var plans: [Key: [NativeWholeWordWrap.Proposal]] = [:]
    private var retainedUnits = 0
    private var retainedRows = 0
    private var retainedGlyphs = 0
    private(set) var planHits = 0
    private(set) var planMisses = 0
    private(set) var lineHits = 0
    private(set) var lineMisses = 0
    private(set) var linePeak = 0
    private(set) var bypassed = 0
    let enabled: Bool
    init(enabled: Bool = true) { self.enabled = enabled }

    func proposals(key: Key, make: (Measurements) throws -> [NativeWholeWordWrap.Proposal]) rethrows
        -> [NativeWholeWordWrap.Proposal] {
        if enabled, let proposals = plans[key] { planHits += 1; return proposals }
        planMisses += 1
        let measurements = Measurements(enabled: enabled)
        defer {
            lineHits += measurements.hits; lineMisses += measurements.misses
            linePeak = max(linePeak, measurements.peak)
        }
        let made = try make(measurements)
        // A parent Result holds an NSMutableAttributedString behind an immutable
        // declaration. Seal that reference before exposing or retaining the plan.
        let result = enabled ? made.map { proposal -> NativeWholeWordWrap.Proposal in
            let r = proposal.result
            let sealed = NativeWholeWordWrap.Result(text:r.text,
                attributedText:r.attributedText.copy() as! NSAttributedString,rows:r.rows,
                graphemeRanges:r.graphemeRanges,unresolvedGlyphRanges:r.unresolvedGlyphRanges,
                fallbackRanges:r.fallbackRanges,completeOwnership:r.completeOwnership,
                requiredWidth:r.requiredWidth,bodyHeight:r.bodyHeight,
                requestedFontName:r.requestedFontName,requestedFontSize:r.requestedFontSize,
                appliedTracking:r.appliedTracking)
            return .init(width:proposal.width,result:sealed,singleLetterRows:proposal.singleLetterRows,
                         overflowRows:proposal.overflowRows)
        } : made
        let rows = result.reduce(0) { $0 + $1.result.rows.count }
        let units = result.reduce(0) { $0 + $1.result.attributedText.length } + key.utf16.count
        let glyphs = result.reduce(0) { sum, proposal in
            sum + proposal.result.rows.reduce(0) { total, row in
                total + (CTLineGetGlyphRuns(row.line) as! [CTRun]).reduce(0) { $0 + CTRunGetGlyphCount($1) }
            }
        }
        if enabled, key.utf16.count <= 2048, key.owner.count <= 256,
           plans.count < 32, retainedUnits + units <= 65536,
           retainedRows + rows <= 2048, retainedGlyphs + glyphs <= 32768 {
            plans[key] = result
            retainedUnits += units; retainedRows += rows; retainedGlyphs += glyphs
        } else { bypassed += 1 }
        return result
    }

    var audit: [String: Any] {
        ["enabled": enabled, "planHits": planHits, "planMisses": planMisses,
         "lineHits": lineHits, "lineMisses": lineMisses, "temporaryLinePeak": linePeak,
         "planEntries": plans.count, "retainedUTF16Units": retainedUnits,
         "retainedRows": retainedRows, "retainedGlyphs": retainedGlyphs, "uncachedResults": bypassed,
         "limits": ["entries": 32, "utf16Units": 65536, "rows": 2048, "glyphs": 32768,
                    "temporaryLines": 256, "temporaryUTF16Units": 32768],
         "memoryAuthority": "bounded retained objects/units; CoreText opaque allocation bytes are not a hard byte bound"]
    }
}
