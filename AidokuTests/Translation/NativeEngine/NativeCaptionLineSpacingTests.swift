import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeCaptionLineSpacingTests {
    private func fractionalPaddingItem() throws -> NativeTranslationLayoutItem {
        let descriptor: [String: Any] = ["id": "declared-padding", "text": Array(repeating: "가나다", count: 7).joined(separator: "\n"),
            "x": 20, "y": 30, "width": 40, "height": 64,
            "fontSize": 7.02906976744186, "lineHeight": 8, "fontScript": "korean",
            "sourceVertical": true, "balancedColumn": true, "allowsAutomaticFontRecovery": false,
            "paddingTop": 3.87, "paddingRight": 2, "paddingBottom": 3.87, "paddingLeft": 2,
            "sourceBounds": [0.2, 0.3, 0.4, 0.5], "sourceFrame": [0, 0, 100, 100]]
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: descriptor))
    }

    @Test func currentPaddingDeclarationSurvivesMeasurementAndExplicitWritesReplaceIt() throws {
        let original = try fractionalPaddingItem()
        let replayed = try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: JSONEncoder().encode(original))
        #expect(replayed == original, "Prepared raw layout replay must retain its CSS values")
        let first = NativeTypographyPostPolish.usedLayoutItem(original)
        let second = NativeTranslationRenderer.usedLayoutItem(first)
        #expect(second == first, "Both physical box conversions must be idempotent")
        #expect(second.paddingTop == 3.859375 && second.cssPaddingTop == 3.87)
        #expect(second.paddingBottom == 3.859375 && second.cssPaddingBottom == 3.87)
        var overwritten = second
        let assigned = overwritten.paddingTop
        overwritten.paddingTop = assigned
        #expect(overwritten.cssPaddingTop == assigned, "An explicit write of the same used value is a new CSS declaration")
        #expect(overwritten.cssPaddingBottom == 3.87 && second.cssPaddingTop == 3.87)
        overwritten.paddingBottom = 0
        let normalized = NativeTranslationRenderer.usedLayoutItem(overwritten)
        #expect(normalized.cssPaddingTop == assigned && normalized.cssPaddingBottom == 0)
    }

    @Test func measuredCaptionStackAddsDeclaredFractionalPadding() throws {
        let original = try fractionalPaddingItem()
        let item = NativeTranslationRenderer.usedLayoutItem(original)
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize,
            tracking: -item.fontSize * 0.012, lineHeight: item.lineHeight,
            optimizesKoreanWrapping: false, alignsToTop: true)
        let typography = NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style)
        let card = NativeTranslationRenderer.Card(item: item, typography: typography, style: style,
            drawsPanel: false, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: item.fontSize)
        let first = try #require(NativeTranslationRenderer.cardPageLineRects(card).first)
        let candidate = try #require(NativeTranslationRenderer.reshapeCaptionLineSpacing(card,
            pitch: 9.375, firstTop: first.minY))
        let stack = try #require(NativeTranslationRenderer.cardWholeRangeRect(candidate))
        #expect(stack.height == 64)
        #expect(candidate.item.height == 71.734375, "Frozen CSS adds 64 + 3.87 + 3.87 before LayoutUnit conversion")
        #expect(candidate.item.height != 71.71875, "Adding the used padding prematurely loses one LayoutUnit")
        #expect(NativeTranslationRenderer.cardPageLineRects(candidate).first?.minY == first.minY)
    }

    @Test(arguments: [(3, 32.0), (5, 50.0)])
    func actualReshapeUsesMeasuredStackInsteadOfFractionalPitchTimesRows(example: (Int, Double)) throws {
        let text = Array(repeating: "가나다", count: example.0).joined(separator: "\n")
        let descriptor: [String: Any] = ["id": "leading", "text": text,
            "x": 20, "y": 30, "width": 40, "height": example.0 * 8 + 4,
            "fontSize": 7.02906976744186, "lineHeight": 8, "fontScript": "korean",
            "sourceVertical": true, "balancedColumn": true, "allowsAutomaticFontRecovery": false,
            "paddingTop": 2, "paddingRight": 2, "paddingBottom": 2, "paddingLeft": 2,
            "sourceBounds": [0.2, 0.3, 0.4, 0.5], "sourceFrame": [0, 0, 100, 100]]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: descriptor))
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize,
            tracking: -item.fontSize * 0.012, lineHeight: item.lineHeight,
            optimizesKoreanWrapping: false, alignsToTop: true)
        let shaped = NativeTranslationTypography.layout(text: text, in: item.contentRect.size, style: style)
        var card = NativeTranslationRenderer.Card(item: item, typography: shaped, style: style,
            drawsPanel: false, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: item.fontSize)
        card.sourceColumnAuthoredTop = 30.013
        let first = try #require(NativeTranslationRenderer.cardPageLineRects(card).first)
        let candidate = try #require(NativeTranslationRenderer.reshapeCaptionLineSpacing(card,
            pitch: 9.375, firstTop: first.minY))
        #expect(Double(candidate.item.height) == example.1)
        #expect(candidate.typography.lineCount == example.0 && candidate.style.lineHeight == 9.375)
        #expect(NativeTranslationRenderer.cardPageLineRects(candidate).first?.minY == first.minY)
        let declaredTop = try #require(candidate.sourceColumnAuthoredTop)
        #expect(declaredTop != candidate.item.y)
        #expect(Double(declaredTop - candidate.item.y) > 0 && Double(declaredTop - candidate.item.y) < 1.0 / 64)
        #expect(candidate.item.sourceFrame == item.sourceFrame && candidate.item.sourceBounds == item.sourceBounds)
    }
}
