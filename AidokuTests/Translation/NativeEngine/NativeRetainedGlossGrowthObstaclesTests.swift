import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeRetainedGlossGrowthObstaclesTests {
    private func item(id: String, text: String, rect: CGRect, font: CGFloat, kept: Bool = false) throws -> NativeTranslationLayoutItem {
        let value: [String: Any] = ["id": id, "text": text, "x": rect.minX, "y": rect.minY,
            "width": rect.width, "height": rect.height, "fontSize": font, "lineHeight": font * 1.193359375,
            "paddingTop": 6, "paddingRight": 6, "paddingBottom": 6, "paddingLeft": 6,
            "fontScript": "korean", "wrappingScript": "korean", "sourceBounds": [0, 0, 1, 1],
            "sourceFrame": [0, 93.0875, 430, 613.825], "sourceFontSize": 166.61536710506493,
            "sourceColorEligible": true, "keptLettering": kept]
        let data = try JSONSerialization.data(withJSONObject: value)
        return try JSONDecoder().decode(NativeTranslationLayoutItem.self, from: data)
    }
    private func card(_ item: NativeTranslationLayoutItem) -> NativeTranslationRenderer.Card {
        let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: item.fontSize,
            lineHeight: item.lineHeight, optimizesKoreanWrapping: false, balancesHorizontalLines: true,
            horizontalWrapping: .keepAllWithEmergency)
        return .init(item: item, typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style),
            style: style, drawsPanel: false, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: item.fontSize)
    }
    private func fixture(shift: CGFloat = 0, kept: Bool = false, multipleMoves: Bool = false)
    throws -> (NativeTranslationRenderer.Card, NativeTranslationLayoutItem, NativeTranslationEffectGloss.Refinement) {
        let title = card(try item(id: "retained-title", text: "태연하게 대단한 일을",
            rect: CGRect(x: -23.16200048828125, y: 159.8375, width: 430, height: 581.03125), font: 11.75, kept: kept))
        let body = try item(id: "body", text: "나 이번 테스트", rect: CGRect(x: 110, y: 175, width: 72, height: 90), font: 18.75)
        let placement = NativeTranslationGlossPlacement.Placement(cost: 0, size: 14, width: 119,
            lineHeight: 16.70703125, moves: multipleMoves
                ? [CGPoint(x: -23.16200048828125 + shift, y: 66.759375), CGPoint(x: 101.83799951171875, y: 66.759375)]
                : [CGPoint(x: -23.16200048828125 + shift, y: 66.759375)],
            edge: 0, rank: 3, side: "", gap: 0, texture: false, ink: nil, angle: nil, center: nil, block: nil)
        let retained = NativeTranslationEffectGloss.RetainedTypography(sourceStyle: title.style, horizontalPadding: 12, verticalPadding: 12)
        let note = NativeTranslationEffectGloss.Note(id: title.item.id, text: title.item.text, placement: placement,
            origin: CGPoint(x: 6, y: 99.078125), fill: [33,24,22], outline: [255,255,255], strokeWidth: 1.96,
            title: true, members: [title.item.id], unit: [], anchor: 0, rawAngle: 0, retainedTypography: retained)
        return (title, body, .init(notes: [note], hiddenIDs: [title.item.id], removedLayerIDs: [title.item.id]))
    }
    private func context(items: [NativeTranslationLayoutItem]) -> NativeTypographyPostPolish.Context {
        let size = CGSize(width: 430, height: 800)
        let layout = NativeTranslationLayout(imageSize: size, sourceRect: CGRect(origin: .zero, size: size), viewport: size, items: items)
        let settings = IPhoneOverlaySettings(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1,
            textPlacement: .replace, subtitlePosition: .bottom, subtitleMaxLines: 3, subtitleContextSentences: 0)
        return NativeTypographyPostPolish.rendererGrowthSession(layout: layout, restoration: .init(), settings: settings, sourceImage: nil).context
    }

    @Test func retainedTitleUsesTheSameMeasuredTextAsItsDisplayedNote() throws {
        let (title, body, gloss) = try fixture()
        let values = NativeTranslationRenderer.retainedGlossGrowthObstacles(cards: [title], gloss: gloss)
        let obstacles = try #require(values[title.item.id])
        #expect(obstacles.count == 1 && obstacles[0].maxX < 100 && obstacles[0].height == 34)
        let c = context(items: [title.item, body]), candidate = c.candidate(body)
        #expect(!c.clear(candidate, others: [title.item]))
        c.growth.displayedGlossObstacles = values
        #expect(c.clear(candidate, others: [title.item]))
        #expect(c.placementObstacles(title.item) == obstacles)
        #expect(title.item.sourceBounds == [0,0,1,1] && title.item.width == 430)
    }

    @Test func actualDisplayedTitleStillBlocksOverlappingCaption() throws {
        let (title, body, gloss) = try fixture(shift: 125)
        let c = context(items: [title.item, body])
        c.growth.displayedGlossObstacles = NativeTranslationRenderer.retainedGlossGrowthObstacles(cards: [title], gloss: gloss)
        let candidate = c.candidate(body)
        #expect(!c.clear(candidate, others: [title.item]))
        #expect(c.placementObstacles(title.item).contains { $0.intersects(candidate.inkFrame) })
    }

    @Test func keptSourceAndUnreplacedParentsRetainTheirExistingProtection() throws {
        let (kept, body, gloss) = try fixture(kept: true)
        #expect(NativeTranslationRenderer.retainedGlossGrowthObstacles(cards: [kept], gloss: gloss).isEmpty)
        let c = context(items: [kept.item, body])
        c.growth.displayedGlossObstacles = [kept.item.id: [CGRect(x: 0, y: 0, width: 1, height: 1)]]
        #expect(!c.clear(c.candidate(body), others: [kept.item]))
        #expect(c.placementObstacles(kept.item) == [kept.item.rect])
        let (title, _, original) = try fixture()
        var visible = original; visible.hiddenIDs = []; visible.removedLayerIDs = []
        #expect(NativeTranslationRenderer.retainedGlossGrowthObstacles(cards: [title], gloss: visible).isEmpty)
        var removed = original; removed.hiddenIDs = []
        #expect(!NativeTranslationRenderer.retainedGlossGrowthObstacles(cards: [title], gloss: removed).isEmpty)
    }

    @Test func multiplePlacementsKeepConservativeSourceObstacles() throws {
        let (title, body, gloss) = try fixture(multipleMoves: true)
        #expect(gloss.notes.first?.placement.moves.count == 2)
        let values = NativeTranslationRenderer.retainedGlossGrowthObstacles(cards: [title], gloss: gloss)
        #expect(values.isEmpty)
        let c = context(items: [title.item, body])
        c.growth.displayedGlossObstacles = values
        #expect(!c.clear(c.candidate(body), others: [title.item]))
        #expect(c.placementObstacles(title.item) == [title.item.rect])
    }
}
