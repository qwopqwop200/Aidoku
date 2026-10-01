import Foundation
import CoreText
/// Experimental eligibility follows WebKit FontCascade::isCJKIdeograph ranges.
/// No font name or fixture ID selects this policy; mixed scripts and font runs
/// are refused until their original cascade and rotated advances are resolved.
enum NativeVerticalIdeographOpticalTracking {
    static let marker = NSAttributedString.Key("AidokuUniformIdeographOpticalTracking")
    static func isIdeograph(_ c: UInt32) -> Bool {
        let ranges: [ClosedRange<UInt32>] = [0x4E00...0x9FFF,0x3400...0x4DBF,0x2E80...0x2EFF,0x2F00...0x2FDF,
            0x31C0...0x31EF,0xF900...0xFAFF,0x20000...0x2A6DF,0x2A700...0x2B73F,0x2B740...0x2B81F,
            0x2B820...0x2CEAF,0x2CEB0...0x2EBEF,0x2EBF0...0x2EE5F,0x2F800...0x2FA1F,
            0x30000...0x3134F,0x31350...0x323AF]
        return ranges.contains { $0.contains(c) }
    }
    static func apply(to text: NSMutableAttributedString) {
        guard text.length > 0, text.length <= 65_536,
              text.string.unicodeScalars.allSatisfy({isIdeograph($0.value)}) else { return }
        let runs = CTLineGetGlyphRuns(CTLineCreateWithAttributedString(text)) as! [CTRun]
        guard runs.count == 1, let run = runs.first else { return }
        let attributes = CTRunGetAttributes(run) as NSDictionary
        guard let font = attributes[kCTFontAttributeName] else { return }
        let native = font as! CTFont, count = CTRunGetGlyphCount(run)
        guard count == text.string.unicodeScalars.count else { return }
        let automatic = CTFontCreateCopyWithAttributes(native, CTFontGetSize(native), nil,
            CTFontDescriptorCreateWithAttributes([kCTFontOpticalSizeAttribute:"auto",kCTFontOrientationAttribute:CTFontOrientation.horizontal.rawValue] as CFDictionary))
        let disabled = CTFontCreateCopyWithAttributes(native, CTFontGetSize(native), nil,
            CTFontDescriptorCreateWithAttributes([kCTFontOpticalSizeAttribute:"none",kCTFontOrientationAttribute:CTFontOrientation.horizontal.rawValue] as CFDictionary))
        var glyphs = [CGGlyph](repeating:0,count:count), withOptical = [CGSize](repeating:.zero,count:count), withoutOptical = withOptical
        CTRunGetGlyphs(run,CFRange(location:0,length:0),&glyphs)
        guard !glyphs.contains(0) else { return }
        CTFontGetAdvancesForGlyphs(automatic,.vertical,&glyphs,&withOptical,count)
        CTFontGetAdvancesForGlyphs(disabled,.vertical,&glyphs,&withoutOptical,count)
        let differences = zip(withOptical,withoutOptical).map {$0.width-$1.width}
        guard let delta = differences.first, delta.isFinite, delta != 0,
              differences.allSatisfy({Float($0).bitPattern == Float(delta).bitPattern}),
              let tracking = (text.attribute(NSAttributedString.Key(kCTTrackingAttributeName as String),at:0,effectiveRange:nil) as? NSNumber)?.doubleValue else { return }
        let full = NSRange(location:0,length:text.length)
        text.addAttribute(NSAttributedString.Key(kCTTrackingAttributeName as String),value:CGFloat(tracking)+delta,range:full)
        text.addAttribute(marker,value:true,range:full)
    }
    /// In an all-ideograph uniform-tracker line, trailing whitespace consists
    /// solely of positive terminal tracking. Core Text excludes it while
    /// centering the line, whereas CSS centers the complete tracked advance.
    static func paintCenterShift(frame: CTFrame, attributed: NSAttributedString) -> CGFloat {
        guard attributed.length > 0, attributed.attribute(marker,at:0,effectiveRange:nil) as? Bool == true else { return 0 }
        let lines = CTFrameGetLines(frame) as! [CTLine]
        let widths = lines.map {CTLineGetTrailingWhitespaceWidth($0)}
        guard let first = widths.first, first.isFinite, first >= 0,
              widths.allSatisfy({Float($0).bitPattern == Float(first).bitPattern}) else {return 0}
        return -first/2
    }
}
