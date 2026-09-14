import CoreGraphics
import Testing
@testable import Aidoku

struct ReaderOverlayPlacementIdentityTests {
    private func item(_ id: UInt64?, x: CGFloat, y: CGFloat, text: String = "대사") -> BrowserOverlayItem {
        .init(stableRegionID: id, rect: CGRect(x: x, y: y, width: 40, height: 30),
              sourceText: text, translatedText: text, confidence: 0.99)
    }

    @Test func approximateRowChainHasSameOrderForEveryPublicationPermutation() {
        let a = item(1, x: 60, y: 10), b = item(2, x: 40, y: 11.5), c = item(3, x: 20, y: 13)
        for values in [[a,b,c], [a,c,b], [b,a,c], [b,c,a], [c,a,b], [c,b,a]] {
            #expect(BrowserOverlayItemOrdering.ordered(values).map(\.stableRegionID) == [2,1,3])
        }
    }

    @Test func webPayloadExcludesAmbiguousIDsButKeepsIndependentRepeatedDialogue() {
        let values = [item(9, x: 20, y: 80, text: "중복 하나"), item(9, x: 22, y: 82, text: "중복 둘"),
                      item(10, x: 20, y: 140), item(11, x: 100, y: 140)]
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(items: values,
            imageSize: CGSize(width: 390, height: 780), sourceRect: CGRect(x: 0, y: 0, width: 390, height: 780),
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: CGSize(width: 390, height: 780))
        #expect(payload.compactMap { $0["id"] as? String } == ["10", "11"])
        #expect(payload.count == 2)
    }

    @Test func coincidentIdenticalPaintKeepsOneOwnerWithoutMergingDifferentSpeech() {
        let first = item(1, x: 20, y: 40), duplicate = item(2, x: 20, y: 40)
        let repeatedElsewhere = item(3, x: 80, y: 40)
        let differentSpeech = item(4, x: 20, y: 40, text: "다른 대사")
        for values in [[first, duplicate, repeatedElsewhere, differentSpeech],
                       [differentSpeech, repeatedElsewhere, duplicate, first]] {
            #expect(BrowserOverlayItemOrdering.ordered(values).map(\.stableRegionID) == [1,4,3])
        }
    }

    @Test func invalidGeometryDoesNotPoisonOtherwiseValidPage() {
        let invalid = BrowserOverlayItem(rect: .null, sourceText: "invalid", translatedText: nil, confidence: 1)
        let valid = item(3, x: 10, y: 10)
        #expect(BrowserOverlayItemOrdering.ordered([invalid, valid]) == [valid])
    }
}
