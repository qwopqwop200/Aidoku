import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct V2TranslationLengthCapTests {
    private func block(_ id: Int, source: String, translation: String?,
                       bounds: CGRect = CGRect(x: 100, y: 100, width: 300, height: 300)) -> V2Block {
        V2Block(
            id: id, lines: [], bounds: bounds, polygon: [], vertical: false, readingOrder: id, sourceText: source,
            balloon: nil, role: .dialogue, translation: translation,
            style: V2Style(fontPixels: 30, bold: false, textColor: V2RGB(r: 0, g: 0, b: 0),
                           strokeColor: V2RGB(r: 255, g: 255, b: 255), strokeWidth: 2)
        )
    }

    @Test func normalTranslationsAreReturnedUnchanged() {
        let cases: [(String, String)] = [
            ("ありがとう", "고마워"),
            ("お前は誰だ!?", "넌 누구냐!?"),
            ("", String(repeating: "가", count: 256)),
            (String(repeating: "あ", count: 40), String(repeating: "나", count: 320)),
            ("ドン", "쿵👨‍👩‍👧‍👦e\u{301}")
        ]
        for (source, translation) in cases {
            #expect(V2TranslationLengthCap.capped(translation, sourceText: source) == translation)
        }
    }

    @Test func runawayTranslationIsTruncatedToTheLimit() {
        let source = "なんだと"
        let runaway = String(repeating: "반복되는 쓰레기 텍스트 ", count: 20_000)
        #expect(runaway.utf8.count > 200_000)
        let capped = V2TranslationLengthCap.capped(runaway, sourceText: source)
        #expect(capped.count == 256)
        #expect(runaway.hasPrefix(capped))
    }

    @Test func truncationNeverSplitsAGraphemeCluster() {
        let unit = "👨‍👩‍👧‍👦e\u{301}🇰🇷"
        let runaway = String(repeating: unit, count: 500)
        let capped = V2TranslationLengthCap.capped(runaway, sourceText: "")
        #expect(capped.count == 256)
        #expect(runaway.hasPrefix(capped))
        let expected = String(repeating: unit, count: 85) + "👨‍👩‍👧‍👦"
        #expect(capped == expected)
    }

    @Test func layoutBoundsUncappedTextFromCachesOrReplay() {
        let page = CGSize(width: 1000, height: 1400)
        let runaway = String(repeating: "반복 ", count: 50_000)
        let capped = V2TranslationLengthCap.capped(runaway, sourceText: "えっ")
        let fromRunaway = V2Layout.place([block(0, source: "えっ", translation: runaway)], pageSize: page)
        let fromCapped = V2Layout.place([block(0, source: "えっ", translation: capped)], pageSize: page)
        #expect(fromRunaway == fromCapped)
        #expect(fromRunaway.count == 1)
        #expect(fromRunaway[0].lines.joined().count <= 256)
    }
}
