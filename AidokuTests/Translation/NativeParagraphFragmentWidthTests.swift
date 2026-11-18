import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

struct NativeParagraphFragmentWidthTests {
    @Test func repeatedWidthsMatchDirectShapingAcrossFontsAndCapacityLimits() {
        let widths = EnsembleCandidate04Next.FragmentWidths()
        let text = ["AV office", "e\u{301}", "é", "\u{037E}", ";", "\u{0344}", "\u{0308}\u{0301}", "가나다…", "אבג", "👩🏾‍💻", "한 글", ""]
        let long = String(repeating: "한", count: 200)
        let overflow = (0..<270).map { "offset \($0)" }
        let faces = [("AppleSDGothicNeo-Medium", 13), ("Helvetica", 23), ("Helvetica", 29),
                     ("AppleSDGothicNeo-Medium", 13)]
        for (name, size) in faces {
            let font = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
            widths.bind(font)
            let attributes = [NSAttributedString.Key(kCTFontAttributeName as String): font]
            let values = text + text.reversed() + overflow + [long, long] + text
            for value in values {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: value, attributes: attributes))
                let expected = max(CGFloat(CTLineGetTypographicBounds(line, nil, nil, nil)),
                    CTLineGetBoundsWithOptions(line, [.useGlyphPathBounds]).width)
                #expect(widths.measure(value) == expected)
            }
        }
    }
}
