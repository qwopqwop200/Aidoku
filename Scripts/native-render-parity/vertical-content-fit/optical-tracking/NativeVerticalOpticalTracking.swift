import Foundation
import CoreText
/// Core Text derives a vertical-orientation run font which suppresses its
/// optical tracker. Measure that tracker with public descriptor orientation
/// and direct vertical glyph advances; retain the shaped vertical font/glyphs.
/// Staged policy until the typography owner publishes its bounded call.
enum NativeVerticalOpticalTracking {
    static func apply(to text: NSMutableAttributedString) {
        guard text.length > 0, text.length <= 65_536 else { return }
        let full = NSRange(location: 0, length: text.length)
        text.enumerateAttribute(NSAttributedString.Key(kCTKernAttributeName as String), in: full) { value, range, _ in
            text.addAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), value: value ?? 0, range: range)
        }
        text.addAttribute(NSAttributedString.Key(kCTKernAttributeName as String), value: 0, range: full)
        let line = CTLineCreateWithAttributedString(text)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var updates: [(NSRange, CGFloat)] = []
        for run in runs {
            let attrs = CTRunGetAttributes(run) as NSDictionary
            guard let font = attrs[kCTFontAttributeName] else { continue }
            let native = font as! CTFont
            let automatic = CTFontCreateCopyWithAttributes(native, CTFontGetSize(native), nil,
                CTFontDescriptorCreateWithAttributes([kCTFontOpticalSizeAttribute: "auto", kCTFontOrientationAttribute: CTFontOrientation.horizontal.rawValue] as CFDictionary))
            let disabled = CTFontCreateCopyWithAttributes(native, CTFontGetSize(native), nil,
                CTFontDescriptorCreateWithAttributes([kCTFontOpticalSizeAttribute: "none", kCTFontOrientationAttribute: CTFontOrientation.horizontal.rawValue] as CFDictionary))
            let count = CTRunGetGlyphCount(run), range = CTRunGetStringRange(run)
            guard count > 0, count <= 65_536 else { continue }
            var glyphs = [CGGlyph](repeating: 0, count: count)
            var indices = [CFIndex](repeating: 0, count: count)
            var withOptical = [CGSize](repeating: .zero, count: count)
            var withoutOptical = withOptical
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            CTRunGetStringIndices(run, CFRange(location: 0, length: 0), &indices)
            CTFontGetAdvancesForGlyphs(automatic, .vertical, &glyphs, &withOptical, count)
            CTFontGetAdvancesForGlyphs(disabled, .vertical, &glyphs, &withoutOptical, count)
            var deltas: [CFIndex: CGFloat] = [:]
            for i in indices.indices where glyphs[i] != 0 {
                deltas[indices[i], default: 0] += withOptical[i].width - withoutOptical[i].width
            }
            let sorted = Array(Set(indices)).sorted()
            for (ordinal, index) in sorted.enumerated() {
                let end = ordinal + 1 < sorted.count ? sorted[ordinal + 1] : range.location + range.length
                guard index >= 0, end > index, end <= text.length else { continue }
                let delta = deltas[index] ?? 0
                guard delta.isFinite, delta != 0 else { continue }
                let kern = (text.attribute(NSAttributedString.Key(kCTTrackingAttributeName as String), at: index,
                    effectiveRange: nil) as? NSNumber)?.doubleValue ?? 0
                updates.append((NSRange(location: index, length: end-index), CGFloat(kern) + delta))
            }
        }
        for (range, kern) in updates {
            text.addAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String), value: kern, range: range)
        }
    }
}
