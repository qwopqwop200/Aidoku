import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeDisplayCleanupGeometryTests {
    private func card(id: String, text: String, rect: CGRect, rotation: Double = 0,
                      sourceVertical: Bool = false, wrappingScript: String = "word") throws -> NativeTranslationRenderer.Card {
        let value: [String: Any] = ["id": id, "text": text, "sourceBounds": [0.15, 0.15, 0.15, 0.7],
            "sourceFrame": [0, 0, 100, 100], "x": rect.minX, "y": rect.minY,
            "width": rect.width, "height": rect.height, "rotation": rotation,
            "fontSize": 8, "lineHeight": 9.6, "fontScript": "korean", "wrappingScript": wrappingScript,
            "sourceVertical": sourceVertical, "allowsAutomaticFontRecovery": true]
        let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
            from: JSONSerialization.data(withJSONObject: value))
        let style = NativeTranslationTypography.Style(fontSize: 8)
        let typography = NativeTranslationTypography.layout(text: text, in: rect.size, style: style)
        return .init(item: item, typography: typography, style: style, drawsPanel: false,
            background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
            lightSurface: true, heavyStrokeWidth: 0, finalFontSize: 8)
    }
    private var settings: IPhoneOverlaySettings {
        .init(visible: true, mode: .translateOnly, colorMode: .white, opacity: 1, textPlacement: .replace,
            subtitlePosition: .bottom, subtitleMaxLines: 2, subtitleContextSentences: 0)
    }

    @Test func displayGroupUsesCleanupFrameForFallbackSourceGlyphWithoutChangingOCRFrame() throws {
        var originals = try [card(id: "a", text: "I", rect: CGRect(x: 100, y: 100, width: 60, height: 140),
                                  rotation: 0.01, sourceVertical: true),
                             card(id: "b", text: "I", rect: CGRect(x: 150, y: 100, width: 60, height: 140),
                                  rotation: 0.01, sourceVertical: true)]
        for i in originals.indices {
            originals[i].rotatesSourcePanels = true
            originals[i].sourcePanels = [.init(rect: originals[i].item.rect, background: [240, 240, 240], coverage: [])]
        }
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 100, height: 100),
            sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100),
            viewport: CGSize(width: 400, height: 400), items: originals.map(\.item))
        var legacy = originals
        NativeTranslationRenderer.applyDisplayGroups(cards: &legacy, gloss: .init(), layout: layout, settings: settings)
        #expect(legacy.allSatisfy { $0.displayGroup == nil })
        var normalized = originals
        for i in normalized.indices { normalized[i].cleanupSourceFrame = CGRect(x: 20, y: 30, width: 200, height: 200) }
        NativeTranslationRenderer.applyDisplayGroups(cards: &normalized, gloss: .init(), layout: layout, settings: settings)
        #expect(normalized.allSatisfy { $0.displayGroup != nil && $0.finalFontSize > 8 })
        #expect(normalized.map { $0.item.sourceFrame } == originals.map { $0.item.sourceFrame })
        #expect(normalized.map { $0.sourcePanels[0].rect } == originals.map { $0.sourcePanels[0].rect })
    }

    @Test func stackSurfaceSamplingFollowsOffsetCleanupFrameAndPreservesOriginalDescriptors() throws {
        let baseFrame = CGRect(x: 0, y: 0, width: 100, height: 100), offset = CGSize(width: 200, height: 120)
        var stacked = try card(id: "stack", text: "가나다", rect: CGRect(x: 40, y: 30, width: 20, height: 40), wrappingScript: "korean")
        stacked.item.typesettingText = "가\n나\n다"
        stacked.typography = NativeTranslationTypography.layout(text: "가\n나\n다", in: stacked.item.contentRect.size, style: stacked.style)
        var obstacle = try card(id: "obstacle", text: "X", rect: baseFrame)
        obstacle.sourcePanels = [.init(rect: baseFrame, background: [255, 255, 255], coverage: [])]
        var pixels = NativeRestorationPixels(width: 100, height: 100)
        pixels.rgba = Array(repeating: [UInt8](arrayLiteral: 60, 90, 120, 255), count: pixels.count).flatMap { $0 }
        let image = try #require(pixels.image())
        let layout = NativeTranslationLayout(imageSize: baseFrame.size, sourceRect: baseFrame,
            viewport: CGSize(width: 400, height: 400), items: [stacked.item, obstacle.item])
        var baseline = [stacked, obstacle]
        NativeTranslationRenderer.repairKoreanStacks(cards: &baseline, gloss: .init(), layout: layout,
            restoration: .init(), source: image, settings: settings)
        let reference = try #require(baseline[0].stackRepairDeclined?["rejected"] as? [String: Any])
        let colour = try #require(reference["ref"] as? [Double])
        var shifted = [stacked, obstacle]
        for i in shifted.indices {
            shifted[i].item.x += offset.width; shifted[i].item.y += offset.height
            for j in shifted[i].sourcePanels.indices {
                shifted[i].sourcePanels[j].rect = shifted[i].sourcePanels[j].rect.offsetBy(dx: offset.width, dy: offset.height)
            }
        }
        var restoration = NativeTranslationRestoration.Result()
        restoration.cleanupGeometry = .init(frame: baseFrame.offsetBy(dx: offset.width, dy: offset.height), clip: baseFrame.offsetBy(dx: offset.width, dy: offset.height))
        NativeTranslationRenderer.repairKoreanStacks(cards: &shifted, gloss: .init(), layout: layout,
            restoration: restoration, source: image, settings: settings)
        let shiftedReference = try #require(shifted[0].stackRepairDeclined?["rejected"] as? [String: Any])
        #expect(shiftedReference["ref"] as? [Double] == colour)
        #expect(shifted[0].item.sourceFrame == stacked.item.sourceFrame)
        #expect(shifted[0].item.sourceBounds == stacked.item.sourceBounds)
    }
    @Test func freshStackRowsDiscardPackingWrapperAndRecordActualBlockDisplay() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var stacked = try card(id: "stack", text: "가나다", rect: CGRect(x: 40, y: 30, width: 20, height: 40), wrappingScript: "korean")
        stacked.item.typesettingText = "가\n나\n다"
        stacked.item.typesettingQuoteMode = 3
        stacked.item.typesettingPreservedBlockWrapper = true
        stacked.item.typesettingBlockDisplay = false
        stacked.style.usesBlockWordLayout = true
        stacked.style.blockWordLayoutUsesTopPadding = true
        stacked.typography = NativeTranslationTypography.layout(text: "가\n나\n다", in: stacked.item.contentRect.size, style: stacked.style)
        var pixels = NativeRestorationPixels(width: 100, height: 100)
        pixels.rgba = Array(repeating: [UInt8](arrayLiteral: 240, 240, 240, 255), count: pixels.count).flatMap { $0 }
        let image = try #require(pixels.image())
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [stacked.item])
        var cards = [stacked]
        NativeTranslationRenderer.repairKoreanStacks(cards: &cards, gloss: .init(), layout: layout,
            restoration: .init(), source: image, settings: settings)
        #expect(cards[0].stackRepair != nil && cards[0].typography.lineCount == 1)
        #expect(cards[0].item.typesettingPreservedBlockWrapper == nil)
        #expect(cards[0].item.typesettingBlockDisplay == true)
        #expect(cards[0].item.typesettingQuoteMode == nil && !cards[0].style.usesBlockWordLayout)
        #expect(cards[0].style.blockWordLayoutUsesTopPadding && cards[0].style.usesPreformattedBlockRows)
        #expect(cards[0].item.sourceFrame == stacked.item.sourceFrame && cards[0].item.sourceBounds == stacked.item.sourceBounds)
    }

    @Test func acceptedPreformattedStackIncludesBlockRowBoxesAndPreservesASCIISpaces() throws {
        let frame = CGRect(x: 0, y: 0, width: 100, height: 100)
        var stacked = try card(id: "stack", text: "가나다  가", rect: CGRect(x: 40, y: 10, width: 20, height: 80), wrappingScript: "korean")
        stacked.item.typesettingText = "가\n나\n다  가"
        stacked.item.typesettingQuoteMode = 3
        stacked.item.typesettingPreservedBlockWrapper = true
        stacked.item.lineHeight = 24; stacked.style.lineHeight = 24
        stacked.typography = NativeTranslationTypography.layout(text: "가\n나\n다  가", in: stacked.item.contentRect.size, style: stacked.style)
        var pixels = NativeRestorationPixels(width: 100, height: 100)
        pixels.rgba = Array(repeating: [UInt8](arrayLiteral: 240, 240, 240, 255), count: pixels.count).flatMap { $0 }
        let image = try #require(pixels.image())
        let layout = NativeTranslationLayout(imageSize: frame.size, sourceRect: frame, viewport: frame.size, items: [stacked.item])
        var cards = [stacked]
        NativeTranslationRenderer.repairKoreanStacks(cards: &cards, gloss: .init(), layout: layout,
            restoration: .init(), source: image, settings: settings)
        var repaired = cards[0]
        #expect(repaired.stackRepair != nil)
        // Remeasure and Range must recover the current child provenance from
        // the item even when an earlier style copy lacks the new flag.
        repaired.style.usesPreformattedBlockRows = false
        repaired.typography = NativeTranslationRenderer.remeasureTypography(repaired)
        #expect(repaired.item.typesettingPreformattedRows == true && repaired.item.typesettingQuoteMode == nil)
        #expect(repaired.item.typesettingPreservedBlockWrapper == nil)
        #expect(repaired.typography.shapedText == repaired.item.typesettingText)
        #expect(repaired.typography.shapedText.contains("  "))
        let whole = try #require(NativeTranslationRenderer.cardWholeRangeRect(repaired))
        let text = NativeTranslationTypography.captionLineMetrics(layout: repaired.typography)
            .map(\.rect).reduce(CGRect.null) { $0.union($1) }
        #expect(whole.height >= floor(repaired.style.lineHeight) * CGFloat(repaired.typography.lineCount))
        #expect(whole.height > text.height)
        #expect(repaired.item.sourceFrame == stacked.item.sourceFrame && repaired.item.sourceBounds == stacked.item.sourceBounds)
    }

}
