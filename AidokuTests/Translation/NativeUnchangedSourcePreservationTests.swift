import Foundation
import Testing
@testable import Aidoku

struct NativeUnchangedSourcePreservationTests {
    @Test func staleSerializedItemPreservesSourceWithoutChangingTranslatedNeighbor() throws {
        let unchanged: [String: Any] = ["id": "symbol", "sourceOriginalText": "♡", "text": "♡",
            "keptLettering": false, "sourceTextOnly": false, "fontSize": 40,
            "sourceBounds": [0.1, 0.2, 0.03, 0.08]]
        let changed: [String: Any] = ["id": "changed", "sourceOriginalText": "原文", "text": "번역",
            "keptLettering": false, "sourceTextOnly": false, "fontSize": 32]
        let serialized = try JSONSerialization.data(withJSONObject: [unchanged, changed])
        let stale = try #require(JSONSerialization.jsonObject(with: serialized) as? [[String: Any]])
        let normalized = NativeSourceTextPreservation.normalized(stale)
        #expect(normalized.count == 2)
        #expect(normalized[0]["keptLettering"] as? Bool == true)
        #expect(normalized[0]["sourceTextOnly"] as? Bool == true)
        #expect(normalized[0]["text"] as? String == "♡")
        #expect(normalized[0]["sourceOriginalText"] as? String == "♡")
        #expect(normalized[0]["sourceBounds"] as? [Double] == stale[0]["sourceBounds"] as? [Double])
        #expect(NSDictionary(dictionary: normalized[1]).isEqual(to: stale[1]))
        #expect(NSDictionary(dictionary: NativeSourceTextPreservation.normalized(normalized)[0])
            .isEqual(to: normalized[0]))
    }

    @Test func missingEmptyOrChangedSourceProofNeverInfersPreservation() {
        let unknown: [[String: Any]] = [
            ["text": "♡", "keptLettering": false],
            ["sourceOriginalText": "", "text": "", "keptLettering": false],
            ["sourceOriginalText": " ", "text": " ", "keptLettering": false],
            ["sourceOriginalText": "♡", "text": "♥", "keptLettering": false],
            ["sourceOriginalText": "原文", "text": "번역", "keptLettering": false]
        ]
        for (before, after) in zip(unknown, NativeSourceTextPreservation.normalized(unknown)) {
            #expect(NSDictionary(dictionary: before).isEqual(to: after))
        }
        #expect(!NativeSourceTextPreservation.matches(source: nil, translated: "♡"))
        #expect(!NativeSourceTextPreservation.matches(source: "♡", translated: nil))
        #expect(NativeSourceTextPreservation.matches(source: " ♡\n", translated: "♡"))
    }
}
