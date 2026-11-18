import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

@Suite struct NativeOpaqueBackingCohortTests {
    private let bounds = CGRect(x: 0, y: 0, width: 400, height: 400)

    private func fixture(backingExpansion: CGFloat = 0) throws -> [NativeTranslationRenderer.Card] {
        try (0..<4).map { index in
            let x = CGFloat(index == 3 ? 310 : 10 + index * 70)
            let y: CGFloat = index == 3 ? 260 : 20
            let font: CGFloat = [8, 7, 7.5, 8][index]
            let payload: [String: Any] = [
                "id": "paragraph-\(index)", "text": "같은 크기로 조판할 문단",
                "x": x, "y": y, "width": 60, "height": 100,
                "fontSize": font, "lineHeight": font * 1.3,
                "paddingTop": 2, "paddingBottom": 2, "paddingLeft": 2, "paddingRight": 2,
                "sourceBounds": [Double(x + 2) / 400, Double(y + 2) / 400, 0.14, 0.24],
                "sourceFrame": [0, 0, 400, 400], "sourceFontSize": 8,
                "sourceTextOnly": false, "fontScript": "korean", "wrappingScript": "korean"
            ]
            let item = try JSONDecoder().decode(NativeTranslationLayoutItem.self,
                from: JSONSerialization.data(withJSONObject: payload))
            let style = NativeTranslationTypography.Style(fontScript: "korean", fontSize: font,
                lineHeight: font * 1.3, optimizesKoreanWrapping: false, horizontalWrapping: .keepAllWithEmergency)
            var card = NativeTranslationRenderer.Card(item: item,
                typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style),
                style: style, drawsPanel: true, background: CGColor(gray: 1, alpha: 1), usesFallbackVeil: false,
                lightSurface: true, heavyStrokeWidth: 0, finalFontSize: font)
            card.sourceBackgroundKind = "solid-text-box"
            card.sourcePlateOwnerRect = CGRect(x: x, y: y, width: 60 + backingExpansion, height: 100)
            return card
        }
    }

    private func search(_ cards: inout [NativeTranslationRenderer.Card]) throws
        -> (audit: [String: Int], changed: Set<String>, unknown: Set<String>, conditional: Set<String>) {
        let items = cards.map(\.item)
        let owners = items.map { $0.rect.insetBy(dx: 2, dy: 2) }
        var unknown: Set<String> = [], conditional: Set<String> = [], audit: [String: Int] = [:]
        let changed = try NativeTranslationRenderer.commitContourCohortsTiled(cards: &cards, items: items,
            owners: owners, surfaces: [:], bounds: bounds, sourceRect: bounds, pixels: bounds.size, pdfDeviceScale: 1,
            verifiedOriginalStyle: [], allowsStyleUnknownTrials: true, unknownSourceStyleIDs: &unknown,
            allowsVerifiedBalloonInteriorModelTrials: true, conditionalGeometryIDs: &conditional,
            recordAudit: { audit = $0 })
        return (audit, changed, unknown, conditional)
    }

    @Test(arguments: [CGFloat(0), CGFloat(25)])
    func missingContoursReachJointShapingWithoutChangingBackingOrMergingIdentities(_ backingExpansion: CGFloat) throws {
        // Expanded per-ID plates overlap, but remain separate immutable rectangles.
        // The fourth paragraph stays distant under the existing geometric relation.
        var cards = try fixture(backingExpansion: backingExpansion)
        let before = cards
        let result = try search(&cards)
        #expect(result.audit["opaqueBackingRectangularDomains"] == 4)
        #expect(result.audit["solver.groups"] == 1)
        #expect(result.audit["solver.singletonGroups"] == 1)
        #expect((result.audit["shapedCandidates"] ?? 0) > 0)
        #expect(result.audit["observedGeometryModelDomains"] == nil)
        #expect(result.audit["certificate.model-conditional-support"] == nil)
        #expect(result.conditional.isEmpty)
        #expect(result.unknown == result.changed)
        #expect(!result.changed.contains("paragraph-3"))
        #expect(result.audit["singleParagraphFlowEligible"] == nil)
        #expect(result.audit["paragraphWidthFlowEligible"] == nil)
        for index in cards.indices {
            #expect(cards[index].item.id == before[index].item.id)
            #expect(cards[index].item.text == before[index].item.text)
            #expect(cards[index].item.sourceBounds == before[index].item.sourceBounds)
            #expect(cards[index].sourcePlateRect == before[index].sourcePlateRect)
            #expect(cards[index].background == before[index].background)
            if result.changed.contains(cards[index].item.id) {
                let domain = try #require(cards[index].textPaintDomain)
                #expect(domain.rect == before[index].sourcePlateRect)
                #expect(domain.polygon.isEmpty)
                #expect(domain.rect.contains(cards[index].item.rect))
            }
        }
    }

    @Test(arguments: ["translucent", "no-panel", "veil", "rotated", "non-solid", "owner-uncovered"])
    func unavailableOpaqueBackingCannotAdmitContourMissingCards(_ reason: String) throws {
        var cards = Array(try fixture().prefix(3))
        for index in cards.indices {
            switch reason {
            case "translucent": cards[index].background = CGColor(gray: 1, alpha: 0.9)
            case "no-panel": cards[index].drawsPanel = false
            case "veil": cards[index].usesFallbackVeil = true
            case "rotated": cards[index].item.rotation = 0.1
            case "non-solid": cards[index].sourceBackgroundKind = "readability-panel"
            default: cards[index].sourcePlateOwnerRect = cards[index].item.rect.insetBy(dx: 10, dy: 10)
            }
        }
        let result = try search(&cards)
        #expect(result.audit["candidateDomains"] == 0)
        #expect(result.audit["insufficientDomainsPages"] == 1)
        #expect(result.changed.isEmpty && result.unknown.isEmpty && result.conditional.isEmpty)
    }

    @Test func detectorAngleDoesNotExcludeAlreadyUprightTextAndBacking() throws {
        var cards = try fixture()
        cards[0].item.rotation = -0.12
        cards[0].textRotation = 0
        cards[0].straightenedPanelRect = cards[0].sourcePlateRect
        let before = cards
        let result = try search(&cards)
        #expect(result.audit["opaqueBackingRectangularDomains"] == 4)
        #expect(result.audit["solver.eligibleCards"] == 4)
        #expect(cards[0].item.rotation == before[0].item.rotation)
        #expect(cards[0].effectiveTextRotation == 0)
        #expect(cards[0].sourcePlateRect == before[0].sourcePlateRect)
    }
}
