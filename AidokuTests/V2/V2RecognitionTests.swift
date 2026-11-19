import CoreGraphics
@preconcurrency import CoreML
import Foundation
import Testing
@testable import Aidoku

struct V2RecognitionTests {
    @Test func planMatchesLegacyPublisherWidthAndRotation() throws {
        // A tall vertical column rotates; its width follows the 48-px height rule capped at 640.
        let tall = try #require(V2Recognition.plan([CGPoint(x: 10, y: 10), CGPoint(x: 60, y: 10),
                                                   CGPoint(x: 60, y: 410), CGPoint(x: 10, y: 410)]))
        #expect(tall.rotatedCounterClockwise)
        #expect(tall.bucket.width == 384)
        let long = try #require(V2Recognition.plan([CGPoint(x: 0, y: 0), CGPoint(x: 1200, y: 0),
                                                   CGPoint(x: 1200, y: 40), CGPoint(x: 0, y: 40)]))
        #expect(!long.rotatedCounterClockwise)
        #expect(long.bucket.width == 640)
        #expect(V2Recognition.plan([CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0), CGPoint(x: 0, y: 0)]) == nil)
    }

    @Test func packsCompactTopKRowsInLegacyLayout() throws {
        let steps = 3
        func array(_ shape: [Int], _ type: MLMultiArrayDataType, _ value: (Int) -> Double) throws -> MLMultiArray {
            let result = try MLMultiArray(shape: shape.map { NSNumber(value: $0) }, dataType: type)
            for index in 0..<result.count { result[index] = NSNumber(value: value(index)) }
            return result
        }
        let provider = try MLDictionaryFeatureProvider(dictionary: [
            "ctc_indices": MLFeatureValue(multiArray: try array([1, steps], .int32) { Double($0 + 1) }),
            "ctc_scores": MLFeatureValue(multiArray: try array([1, steps], .float32) { Double($0) / 4 }),
            "ctc_topk_indices": MLFeatureValue(multiArray: try array([1, steps, 4], .int32) { Double($0) }),
            "ctc_topk_scores": MLFeatureValue(multiArray: try array([1, steps, 4], .float32) { Double($0) / 16 }),
        ])
        let compact = try V2Recognition.pack(provider, timeSteps: steps)
        #expect(compact.shape.map { $0.intValue } == [10, steps])
        #expect(compact[[0, 2]].intValue == 3)
        #expect(compact[[1, 1]].doubleValue == 0.25)
        // Rank 1 of step 2 lives at topk flat index 2 * 4 + 1 = 9.
        #expect(compact[[4, 2]].intValue == 9)
        #expect(compact[[5, 2]].doubleValue == Double(9) / 16)
    }

    @Test func parsesJSONLineDictionary() throws {
        let data = Data("\u{feff}\"a\"\n\" \"\n\"\\\"\"\n".utf8)
        #expect(try V2RecognitionEngine.parseDictionary(data) == ["a", " ", "\""])
    }
}
