import CoreGraphics
import CoreText
import Foundation

/// Shared defaults in the same logical units as the shaped font. Source colour
/// never changes spacing; matching faces/sizes/effects receive matching rules.
enum NativeTextSpacing {
    @TaskLocal private static var resolvedEffectOverride:Bool?
    @TaskLocal private static var inkCapacityOverride:Bool?

    static var usesResolvedEffectExtent:Bool {
        resolvedEffectOverride ?? (ProcessInfo.processInfo.environment["AIDOKU_RESOLVED_EFFECT_EXTENT"] != "0")
    }

    static func useInkCapacity(raw:[String:Any]?) -> Bool {
        raw?["renderConservativeCapacity"] as? Bool != true &&
            (inkCapacityOverride ?? (ProcessInfo.processInfo.environment["AIDOKU_INK_CAPACITY_CENTERING"] != "0"))
    }

    /// Scoped to this synchronous render transaction; never mutates process
    /// environment and never leaks a legacy counterfactual into another page.
    static func withLegacyCapacity<Value>(_ operation:()throws->Value)rethrows->Value {
        try $resolvedEffectOverride.withValue(false) {
            try $inkCapacityOverride.withValue(false,operation:operation)
        }
    }

    static let version = 4
    static let rowBreathingEm: CGFloat = 0.04
    static let maximumTrackingReduction: CGFloat = 0.03

    static func lineHeight(fontSize: CGFloat) -> CGFloat { fontSize * 1.2 }

    static func rowGap(fontSize: CGFloat, outwardExtent: CGFloat) -> CGFloat {
        2 * max(0, outwardExtent) + fontSize * rowBreathingEm
    }

    /// Use 0.1em bands so small metric differences do not produce arbitrary
    /// leading for the same style. Tall fallback glyphs can still raise the floor.
    static func baselineStep(fontSize: CGFloat, bodyHeight: CGFloat, leading: CGFloat,
                             outwardExtent: CGFloat, minimumLineHeight: CGFloat = 0) -> CGFloat {
        let required = max(lineHeight(fontSize: fontSize), minimumLineHeight,
            bodyHeight + max(leading, rowGap(fontSize: fontSize, outwardExtent: outwardExtent)))
        let unit = fontSize * 0.1
        return max(required, ceil(required / unit - 1e-9) * unit)
    }

    static func pitch(text: String, font: CTFont, fontSize: CGFloat, outwardExtent: CGFloat) -> CGFloat {
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: text,
            attributes: [.init(kCTFontAttributeName as String): font]))
        var ascent: CGFloat = 0, descent: CGFloat = 0
        _ = CTLineGetTypographicBounds(line, &ascent, &descent, nil)
        var ink = CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds])
        // A common visible-ink band preserves same-face leading without paying
        // for the font's unused ascent/descent box on every translated row.
        let reference=CTLineCreateWithAttributedString(NSAttributedString(string:"Hgj한글",
            attributes:[.init(kCTFontAttributeName as String):font]))
        let common=CTLineGetBoundsWithOptions(reference,[.useGlyphPathBounds])
        if !common.isEmpty && !common.isNull {ink=ink.isNull ? common:ink.union(common)}
        let top = ink.isEmpty || ink.isNull ? ascent : max(0,ink.maxY)
        let bottom = ink.isEmpty || ink.isNull ? descent : max(0,-ink.minY)
        return baselineStep(fontSize: fontSize, bodyHeight: top + bottom, leading: CTFontGetLeading(font),
            outwardExtent: outwardExtent)
    }

    /// Breathing room is separate from the ink's outward painted effects.
    static func padding(fontSize: CGFloat) -> CGFloat { max(1, min(8, fontSize * 0.12)) }

    static func contentRect(_ box: CGRect, fontSize: CGFloat, outwardExtent: CGFloat) -> CGRect? {
        guard fontSize.isFinite, fontSize > 0, outwardExtent.isFinite, outwardExtent >= 0,
              !box.isNull, !box.isInfinite, box.width > 0, box.height > 0 else { return nil }
        let inset = padding(fontSize: fontSize) + outwardExtent
        guard box.width > 2 * inset, box.height > 2 * inset else { return nil }
        return box.insetBy(dx: inset, dy: inset)
    }

    /// Relative Quartz ink bounds. Keep Core Text's baseline/mark/fallback
    /// alignment within each line; translate the whole block only.
    static func frameInkBounds(_ frame: CTFrame) -> CGRect {
        let lines = CTFrameGetLines(frame) as! [CTLine]
        var origins = [CGPoint](repeating: .zero, count: lines.count), ink = CGRect.null
        if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
        for i in lines.indices {
            let b = CTLineGetImageBounds(lines[i], nil).union(CTLineGetBoundsWithOptions(lines[i], [.useGlyphPathBounds]))
            if !b.isNull, !b.isEmpty { ink = ink.union(b.offsetBy(dx: origins[i].x, dy: origins[i].y)) }
        }
        return ink
    }

    static func outwardExtent(raw: [String: Any]?, fontSize: CGFloat) -> CGFloat {
        let requested = (raw?["ensembleStrokeRatio"] as? NSNumber)?.doubleValue ?? 0.20
        // An explicit paint ratio is also the shape reservation. The default
        // remains .20; an observed/requested narrower BW guard is not silently
        // inflated only in measurement while final paint uses the supplied value.
        let resolved = usesResolvedEffectExtent && raw?["renderConservativeCapacity"] as? Bool != true
        let ratio = requested.isFinite && requested>0 ? (resolved ? requested:max(0.20, requested)) : 0.20
        let mandatory = max(2, fontSize * CGFloat(ratio))
        guard let raw, let style = raw["sourceAppearance"] as? [String: Any],
              let outline = style["outline"] as? [String: Any], outline["present"] as? Bool == true,
              let sourceSize = (raw["sourceFontSize"] as? NSNumber)?.doubleValue,
              sourceSize.isFinite, sourceSize > 0 else { return mandatory }
        let widths = (outline["observedLayers"] as? [[String: Any]])?.compactMap {
            ($0["widthPx"] as? NSNumber)?.doubleValue
        } ?? []
        let width = widths.isEmpty ? (outline["widthPx"] as? NSNumber)?.doubleValue ?? 0 : widths.reduce(0, +)
        guard width.isFinite, width >= 0 else { return mandatory }
        return mandatory + CGFloat(width / sourceSize) * fontSize
    }

    /// Operates on actual frame ink, after Core Text has chosen its rows.
    /// It never buys a fit by dropping text or changing the original row ranges.
    static func frame(text: NSAttributedString, path: CGPath, width: CGFloat, fontSize: CGFloat,
                      attributes: CFDictionary?, alignInk: Bool = false) -> (value: CTFrame, tracking: CGFloat) {
        func make(_ text: NSAttributedString) -> CTFrame {
            let setter = CTFramesetterCreateWithAttributedString(text)
            let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), path, attributes)
            guard alignInk, CTFrameGetVisibleStringRange(frame).length == text.length else { return frame }
            let ink = frameInkBounds(frame)
            var box = CGRect.zero
            guard path.isRect(&box), !ink.isNull, !ink.isEmpty, ink.height <= box.height else { return frame }
            // Frame origins are relative to its path. Align visible ink, not
            // the font's unused ascent/leading box, retaining all row ranges.
            let shifted = box.offsetBy(dx: 0, dy: box.height / 2 - ink.midY)
            return CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0),
                CGPath(rect: shifted, transform: nil), attributes)
        }
        let original = make(text)
        let rows = CTFrameGetLines(original) as! [CTLine]
        func overflow(_ frame: CTFrame) -> CGFloat {
            let lines = CTFrameGetLines(frame) as! [CTLine]
            var origins = [CGPoint](repeating: .zero, count: lines.count)
            if !lines.isEmpty { CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins) }
            return lines.enumerated().map { index, row in
                let ink = CTLineGetBoundsWithOptions(row, [.useGlyphPathBounds])
                guard !ink.isEmpty, !ink.isNull else { return CGFloat.zero }
                return max(0, -origins[index].x - ink.minX, origins[index].x + ink.maxX - width)
            }.max() ?? 0
        }
        let excess = overflow(original)
        let gaps = rows.map { max(0, CTLineGetStringRange($0).length - 1) }.max() ?? 0
        guard text.length > 0, text.attribute(.init(kCTKernAttributeName as String), at: 0, effectiveRange: nil) == nil,
              excess > 0.01, gaps > 0, fontSize > 0,
              excess <= fontSize * maximumTrackingReduction * CGFloat(gaps) else { return (original, 0) }
        let ranges = rows.map { CTLineGetStringRange($0) }
        for fraction: CGFloat in [0.01, 0.02, maximumTrackingReduction] {
            let candidate = NSMutableAttributedString(attributedString: text)
            candidate.addAttribute(.init(kCTKernAttributeName as String), value: -fontSize * fraction,
                range: NSRange(location: 0, length: text.length))
            let frame = make(candidate), lines = CTFrameGetLines(frame) as! [CTLine]
            guard CTFrameGetVisibleStringRange(frame).length == text.length, lines.count == ranges.count,
                  zip(lines, ranges).allSatisfy({ line, range in
                      let actual = CTLineGetStringRange(line)
                      return actual.location == range.location && actual.length == range.length
                  }), overflow(frame) <= 0.01 else { continue }
            return (frame, -fontSize * fraction)
        }
        return (original, 0)
    }

    static func defaults(_ items: [[String: Any]]) -> [[String: Any]] {
        items.map { item in
            guard let size = (item["fontSize"] as? NSNumber)?.doubleValue, size.isFinite, size > 0 else { return item }
            var result = item
            result["lineHeight"] = Double(lineHeight(fontSize: CGFloat(size)))
            result["spacingPolicyVersion"] = version
            return result
        }
    }
}
