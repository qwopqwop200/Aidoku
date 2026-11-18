import CoreGraphics
import Testing
@testable import Aidoku

struct NativeSourceOwnerRecoveryTests {
    private func item(_ id: String, source: String = "同じ言葉", target: String = "같은 말",
                      confidence: Double = 0.9, rect: CGRect = CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.3)) -> [String: Any] {
        ["id": id, "sourceOriginalText": source, "text": target, "sourceConfidence": confidence,
         "sourcePolygon": [[Double(rect.minX), Double(rect.minY)], [Double(rect.maxX), Double(rect.minY)],
            [Double(rect.maxX), Double(rect.maxY)], [Double(rect.minX), Double(rect.maxY)]]]
    }

    private func ids(_ items: [[String: Any]]) -> [String] { items.compactMap { $0["id"] as? String } }

    @Test func overlappingDuplicatePrefersHigherConfidenceAndRetainsBothMaskOwners() throws {
        let low = item("low", source: "同じ 言葉\n", target: "같은\t말", confidence: 0.8)
        let high = item("high", confidence: 0.98,
            rect: CGRect(x: 0.11, y: 0.1, width: 0.2, height: 0.3))
        let result = NativeSourceOwnerRecovery.partitionExactDuplicateTargets([low, high])
        #expect(ids(result.displayItems) == ["high"])
        #expect(ids(result.sourceItems) == ["low", "high"])
        for (original, retained) in zip([low, high], result.sourceItems) {
            #expect(retained["sourcePolygon"] as? [[Double]] == original["sourcePolygon"] as? [[Double]])
            #expect(retained["sourceOriginalText"] as? String == original["sourceOriginalText"] as? String)
            #expect(retained["text"] as? String == original["text"] as? String)
        }
        let audit = try #require(result.audit.first)
        #expect(result.audit.count == 1)
        #expect(audit["id"] as? String == "low")
        #expect(audit["representativeID"] as? String == "high")
        #expect(audit["sourceOwnersRetained"] as? Bool == true)
    }

    @Test func disjointSameWordsRemainSeparateDisplayOwners() {
        let items = [item("first"), item("second", rect: CGRect(x: 0.6, y: 0.1, width: 0.2, height: 0.3))]
        let result = NativeSourceOwnerRecovery.partitionExactDuplicateTargets(items)
        #expect(ids(result.displayItems) == ["first", "second"])
        #expect(ids(result.sourceItems) == ["first", "second"])
        #expect(result.audit.isEmpty)
    }

    @Test func overlappingSourceWithConflictingTargetRemainsSeparate() {
        let items = [item("first"), item("second", target: "다른 번역")]
        let result = NativeSourceOwnerRecovery.partitionExactDuplicateTargets(items)
        #expect(ids(result.displayItems) == ["first", "second"])
        #expect(ids(result.sourceItems) == ["first", "second"])
        #expect(result.audit.isEmpty)
    }

    @Test func nearbyPartialDistinctSourceRemainsSeparate() {
        // Strong geometric overlap and the same target must not erase a partial source read.
        let items = [item("whole"), item("partial", source: "同じ",
            rect: CGRect(x: 0.11, y: 0.1, width: 0.2, height: 0.3))]
        let result = NativeSourceOwnerRecovery.partitionExactDuplicateTargets(items)
        #expect(ids(result.displayItems) == ["whole", "partial"])
        #expect(ids(result.sourceItems) == ["whole", "partial"])
        #expect(result.audit.isEmpty)
    }
}
