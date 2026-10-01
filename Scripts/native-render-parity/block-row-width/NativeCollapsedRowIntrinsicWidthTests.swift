import CoreGraphics
import CoreText
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCollapsedRowIntrinsicWidthTests {
    struct Example: Sendable { let text: String; let spacing: Float; let expected: CGFloat }
    static let examples: [Example] = [
        Example(text: "가야 할", spacing: -0.075, expected: 17.5625),
        Example(text: "가야 할", spacing: -0.075, expected: 17.5625),
        Example(text: "가야 할", spacing: 0, expected: 17.875),
        Example(text: "가야 할 ", spacing: -0.075, expected: 17.578125),
        Example(text: "가야 할 ", spacing: -0.075, expected: 17.578125),
        Example(text: "가야 할 ", spacing: 0, expected: 17.875),
        Example(text: "수영복을", spacing: -0.075, expected: 21.328125),
        Example(text: "수영복을", spacing: -0.075, expected: 21.328125),
        Example(text: "수영복을", spacing: 0, expected: 21.625),
        Example(text: "입은 채로는", spacing: -0.075, expected: 28.234375),
        Example(text: "입은 채로는", spacing: -0.075, expected: 28.234375),
        Example(text: "입은 채로는", spacing: 0, expected: 28.6875),
        Example(text: "상황이", spacing: -0.075, expected: 16),
        Example(text: "상황이", spacing: -0.075, expected: 16),
        Example(text: "상황이", spacing: 0, expected: 16.21875),
        Example(text: "될지도 모르", spacing: -0.075, expected: 28.234375),
        Example(text: "될지도 모르", spacing: -0.075, expected: 28.234375),
        Example(text: "될지도 모르", spacing: 0, expected: 28.6875),
        Example(text: "가야", spacing: -0.075, expected: 10.671875),
        Example(text: "가야", spacing: -0.075, expected: 10.671875),
        Example(text: "가야", spacing: 0, expected: 10.8125),
        Example(text: "할", spacing: -0.075, expected: 5.34375),
        Example(text: "할", spacing: -0.075, expected: 5.34375),
        Example(text: "할", spacing: 0, expected: 5.40625),
        Example(text: "AV", spacing: -0.075, expected: 7.5625),
        Example(text: "AV", spacing: -0.075, expected: 7.5625),
        Example(text: "AV", spacing: 0, expected: 7.71875),
        Example(text: "To", spacing: -0.075, expected: 6.953125),
        Example(text: "To", spacing: -0.075, expected: 6.953125),
        Example(text: "To", spacing: 0, expected: 7.109375),
        Example(text: "AV To ", spacing: -0.075, expected: 16.09375),
        Example(text: "AV To ", spacing: -0.075, expected: 16.09375),
        Example(text: "AV To ", spacing: 0, expected: 16.46875),
        Example(text: "가야 AV ", spacing: -0.075, expected: 19.796875),
        Example(text: "가야 AV ", spacing: -0.075, expected: 19.796875),
        Example(text: "가야 AV ", spacing: 0, expected: 20.171875)
    ]
    private static func natural(_ text: String) -> [Float]? {
        let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, 6.25, nil)
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font])
        let line = CTLineCreateWithAttributedString(attributed)
        let runs = CTLineGetGlyphRuns(line) as! [CTRun]
        var result: [Float] = []
        for run in runs {
            var advances = [CGSize](repeating: .zero, count: CTRunGetGlyphCount(run))
            CTRunGetAdvances(run, CFRange(location: 0, length: 0), &advances)
            result += advances.map { Float($0.width) }
        }
        return result
    }
    @Test(arguments: examples)
    func collapsedIntrinsicMatchesCapturedWebKitMaxContent(example: Example) throws {
        let raw = try #require(NativeCollapsedRowIntrinsicWidth.width(text: example.text,
            letterSpacing: example.spacing, measureNaturalGlyphAdvances: Self.natural))
        #expect(ceil(Double(raw) * 64) / 64 == Double(example.expected))
    }
    @Test func actualTrailingSpaceKeepsIntrinsicRoundingSeparateFromTrimmedText() throws {
        let plain = try #require(NativeCollapsedRowIntrinsicWidth.width(text: "가야 할",
            letterSpacing: -0.075, measureNaturalGlyphAdvances: Self.natural))
        let trailing = try #require(NativeCollapsedRowIntrinsicWidth.width(text: "가야 할 ",
            letterSpacing: -0.075, measureNaturalGlyphAdvances: Self.natural))
        #expect(plain == 17.5625)
        #expect(trailing == 17.562501907348633)
        #expect(ceil(Double(trailing) * 64) / 64 == 17.578125)
        let disabled = try #require(NativeCollapsedRowIntrinsicWidth.width(text: "가야 할 ",
            letterSpacing: -0.075, extendsWordsIntoFollowingSpace: false,
            measureNaturalGlyphAdvances: Self.natural))
        #expect(disabled == plain)
    }
    @Test func naturalCallbackKeepsFontKerningBeforeAddingCSSSpacing() throws {
        let raw = try #require(NativeCollapsedRowIntrinsicWidth.width(text: "AV",
            letterSpacing: -0.075, measureNaturalGlyphAdvances: Self.natural))
        #expect(raw == 7.5625)
        let font = CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString, 6.25, nil)
        let unkerned = NSAttributedString(string: "AV", attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTKernAttributeName as String): 0])
        let width = CTLineGetTypographicBounds(CTLineCreateWithAttributedString(unkerned), nil, nil, nil)
        #expect(width == 8.075)
        #expect(width > Double(raw) + 0.15)
    }
    @Test func malformedShapingDeclinesAndRepeatedWordsReuseOneNaturalProbe() throws {
        #expect(NativeCollapsedRowIntrinsicWidth.width(text: "abc", letterSpacing: .nan,
            measureNaturalGlyphAdvances: { _ in [] }) == nil)
        #expect(NativeCollapsedRowIntrinsicWidth.width(text: "abc", letterSpacing: 0,
            measureNaturalGlyphAdvances: { _ in [1] }) == nil)
        #expect(NativeCollapsedRowIntrinsicWidth.width(text: "abc", letterSpacing: 0,
            measureNaturalGlyphAdvances: { text in Array(repeating: -.infinity, count: text.count) }) == nil)
        var probes: [String: Int] = [:]
        let text = "  " + Array(repeating: "가야", count: 100).joined(separator: " ") + "  \t"
        let raw = try #require(NativeCollapsedRowIntrinsicWidth.width(text: text, letterSpacing: -0.075) { fragment in
            probes[fragment, default: 0] += 1
            return Self.natural(fragment)
        })
        #expect(raw.isFinite && probes.count == 2 && probes.values.allSatisfy { $0 == 1 })
        #expect(probes["가야 "] == 1 && probes[" "] == 1)
        #expect(NativeCollapsedRowIntrinsicWidth.width(text: " \t\n", letterSpacing: 0,
            measureNaturalGlyphAdvances: { _ in fatalError("Blank content requires no font probe") }) == 0)
    }
}
