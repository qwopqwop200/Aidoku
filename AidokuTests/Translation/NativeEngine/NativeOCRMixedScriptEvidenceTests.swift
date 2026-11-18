import Foundation
import Testing
import UIKit
@testable import Aidoku

struct NativeOCRMixedScriptEvidenceTests {
    @Test func tentativeEvidenceSurvivesDiskWithoutReplacingSource() throws {
        let rect = CGRect(x: 0.4, y: 0.2, width: 0.04, height: 0.12)
        let evidence = ReaderTranslationSourceOCRAlternative(originalText: "えJ…N", exactReading: "そこ・つ",
            paddedReading: "そこ・・つ", rect: rect, primaryConfidence: 0.55, exactConfidence: 0.5, paddedConfidence: 0.3)
        var original = ReaderTranslationRegion(id: "right", rect: rect, source: "んっえJ…N", sourceOrientation: .vertical)
        original.sourceOCRAlternatives = [evidence]
        let data = try JSONEncoder().encode(ReaderTranslationStoredRegion(original))
        let restored = try JSONDecoder().decode(ReaderTranslationStoredRegion.self, from: data).region
        #expect(restored.source == original.source)
        #expect(restored.rect == original.rect)
        #expect(restored.sourceOCRAlternatives == [evidence])
        var old = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        old.removeValue(forKey: "sourceOCRAlternatives")
        let legacy = try JSONDecoder().decode(ReaderTranslationStoredRegion.self,
            from: JSONSerialization.data(withJSONObject: old)).region
        #expect(legacy.sourceOCRAlternatives.isEmpty)
        #expect(legacy.source == original.source)
    }

    @Test(arguments: [false, true])
    func storedAlternativeIsNotSentUnderMandatoryPageContract(withImage: Bool) throws {
        let suite = "MixedScriptEvidence.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.includePageImage = withImage
        settings.sourceLanguage = "ja"
        settings.targetLanguage = "ko"
        settings.filterSFXWithLLM = true
        let rect = CGRect(x: 0.4, y: 0.2, width: 0.04, height: 0.12)
        var right = ReaderTranslationRegion(id: "right", rect: rect, source: "んっえJ…N", sourceOrientation: .vertical)
        right.sourceOCRAlternatives = [.init(originalText: "えJ…N", exactReading: "そこ・つ", paddedReading: "そこ・・つ",
            rect: rect, primaryConfidence: 0.55, exactConfidence: 0.5, paddedConfidence: 0.3)]
        let left = ReaderTranslationRegion(id: "left", rect: CGRect(x: 0.2, y: 0.2, width: 0.05, height: 0.15),
            source: "こんにちは", sourceOrientation: .vertical)
        let plans = ReaderTranslationService.plans(regions: [right, left], settings: settings)
        let segments = plans.flatMap { $0.request.segments }
        #expect(segments.map(\.text) == [right.source, left.source])
        #expect(segments.map(\.id) == [right.id, left.id])
        let encoded = try JSONEncoder().encode(plans[0].request)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("ocr_alternative"))
        #expect(!String(decoding: encoded, as: UTF8.self).contains("context"))
    }
}
