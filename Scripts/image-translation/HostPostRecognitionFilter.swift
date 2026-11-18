import CoreGraphics
import CryptoKit
import Foundation

/// Combines authenticated native RF/DET measurements with actual accepted REC
/// confidence. Text is retained for downstream use, never used as a feature.
enum HostPostRecognitionFilter {
    private struct Request: Decodable {
        let page: String
        let sourceSHA256: String
        let preRecCache: String
        let preRecCacheSHA256: String
        let recognition: String
        let recognitionSHA256: String
        let recognitionRequest: String
        let recognitionRequestSHA256: String
    }
    private struct Cache: Decodable {
        let schema: String
        let page: String
        let sourceSHA256: String
        let inputCount: Int
        let outputCount: Int
        let featureNames: [String]
        let features: [[Double?]]
        let output: NativeOCRIndividualGeometryHypotheses.Output
        let preRecognitionFilter: NativeOCRPreRecognitionFilter.Report
        let GTAtRuntime: Bool
        let RGBRead: Bool
        let shapeFeatures: Bool
        let recognizerCalls: Int
    }
    private struct Read: Codable {
        let sourceIndex: Int
        let text: String
        let confidence: Double
    }
    private struct Recognition: Decodable {
        let page: String
        let sourceSHA256: String
        let requestSHA256: String
        let confidenceThreshold: Double
        let requested: Int
        let skippedInvalid: Int
        let accepted: [Read]
    }
    static func run(output: URL, policyURL: URL? = nil, deduplicate: Bool = false) throws -> Int32 {
        typealias G = NativeOCRIndividualGeometryHypotheses
        typealias Features = NativeOCRPostRecognitionFeatures
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let policyData = try policyURL.map { try Data(contentsOf: $0) }
        let model = try policyData.map { try NativeOCRPreRecognitionFilter.Model(data: $0,
            expectedFeatureNames: Features.featureNames, stage: .afterRecognition) }
        let binarySHA = hash(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let allowed: Set<String> = ["page", "sourceSHA256", "preRecCache", "preRecCacheSHA256",
                                    "recognition", "recognitionSHA256", "recognitionRequest", "recognitionRequestSHA256"]
        var seen = Set<String>()
        while let line = readLine() {
            let bytes = Data(line.utf8)
            guard bytes.count <= 2_000_000,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == allowed else { throw HostError.message("Invalid post-rec signal request") }
            let request = try JSONDecoder().decode(Request.self, from: bytes)
            guard request.page.count == 4, request.page.allSatisfy(\.isNumber), seen.insert(request.page).inserted else {
                throw HostError.message("Invalid post-rec page identity")
            }
            let cacheBytes = try Data(contentsOf: URL(fileURLWithPath: request.preRecCache))
            let recBytes = try Data(contentsOf: URL(fileURLWithPath: request.recognition))
            let recRequestBytes = try Data(contentsOf: URL(fileURLWithPath: request.recognitionRequest))
            guard hash(cacheBytes) == request.preRecCacheSHA256,
                  hash(recBytes) == request.recognitionSHA256,
                  hash(recRequestBytes) == request.recognitionRequestSHA256 else {
                throw HostError.message("Post-rec evidence hash mismatch")
            }
            let decoder = JSONDecoder()
            let cache = try decoder.decode(Cache.self, from: cacheBytes)
            let rec = try decoder.decode(Recognition.self, from: recBytes)
            let spec = try decoder.decode(HostMangaDetectorSearch.MissingReadRequest.self, from: recRequestBytes)
            let pages = spec.pages.filter { $0.id == request.page }
            guard pages.count == 1, let page = pages.first,
                  cache.schema == "actual-native-pre-rec-signal-filter-v1",
                  cache.page == request.page, rec.page == request.page,
                  cache.sourceSHA256 == request.sourceSHA256, rec.sourceSHA256 == request.sourceSHA256,
                  page.sourceSHA256 == request.sourceSHA256, rec.requestSHA256 == request.recognitionRequestSHA256,
                  cache.featureNames == NativeOCRPreRecognitionFeatures.featureNames,
                  !cache.GTAtRuntime, !cache.RGBRead, !cache.shapeFeatures, cache.recognizerCalls == 0,
                  cache.features.count == cache.inputCount,
                  cache.features.allSatisfy({ $0.count == cache.featureNames.count }),
                  cache.outputCount == cache.output.individuals.count,
                  cache.preRecognitionFilter.keptIndices.count == cache.outputCount,
                  cache.preRecognitionFilter.inputCount == cache.inputCount,
                  page.boxes.count == cache.outputCount, rec.requested == cache.outputCount, rec.skippedInvalid == 0,
                  Set(page.boxes.map(\.sourceIndex)) == Set(cache.output.individuals.indices),
                  Set(rec.accepted.map(\.sourceIndex)).count == rec.accepted.count,
                  rec.confidenceThreshold == (spec.confidenceThreshold ?? 0) else {
                throw HostError.message("Unbound post-rec source measurements")
            }
            let boxes = Dictionary(uniqueKeysWithValues: page.boxes.map { ($0.sourceIndex, $0) })
            for box in page.boxes {
                let row = cache.output.individuals[box.sourceIndex]
                guard box.samplingPolygon == nil,
                      box.polygon.map({ [Double($0.x), Double($0.y)] }) == row.polygon.map({ [$0.x, $0.y] }) else {
                    throw HostError.message("Recognition used a different candidate polygon")
                }
            }
            let accepted = rec.accepted.sorted { $0.sourceIndex < $1.sourceIndex }
            guard accepted.allSatisfy({ boxes[$0.sourceIndex] != nil && !$0.text.isEmpty
                && $0.confidence.isFinite && (0...1).contains($0.confidence)
                && $0.confidence >= rec.confidenceThreshold }) else {
                throw HostError.message("Invalid accepted post-rec evidence")
            }
            let ordinals = accepted.map(\.sourceIndex)
            let input = G.selecting(cache.output, indices: ordinals)
            let source165 = try ordinals.map { index -> [Double] in
                let original = cache.preRecognitionFilter.keptIndices[index]
                guard cache.features.indices.contains(original) else { throw HostError.message("Invalid source165 row") }
                return cache.features[original].map { $0 ?? .nan }
            }
            let confidence = accepted.map(\.confidence)
            let features = try Features.extract(input: input, source165: source165, recognitionConfidences: confidence)
            let result = try model.map { try NativeOCRPreRecognitionFilter.apply(input, features: features, model: $0) }
            let numericOutput = result?.output ?? input
            let numericKept = result?.report.keptIndices ?? Array(input.individuals.indices)
            let duplicateResult: NativeOCRPostRecognitionDeduplication.Result?
            if deduplicate {
                duplicateResult = try NativeOCRPostRecognitionDeduplication.apply(
                    numericOutput, source166: numericKept.map { features[$0] })
            } else { duplicateResult = nil }
            let actual = duplicateResult?.output ?? numericOutput
            let kept = duplicateResult.map { d in d.report.keptIndices.map { numericKept[$0] } } ?? numericKept
            var document: [String: Any] = ["schema": "actual-native-post-rec-joint-filter-v1", "page": request.page,
                "sourceSHA256": request.sourceSHA256, "inputSHA256": hash(bytes), "binarySHA256": binarySHA,
                "preRecCacheSHA256": hash(cacheBytes), "recognitionSHA256": hash(recBytes),
                "policySHA256": policyData.map { hash($0) as Any } ?? NSNull(),
                "inputCount": input.individuals.count, "outputCount": actual.individuals.count,
                "afterNumericCount": numericOutput.individuals.count, "deduplicationApplied": deduplicate,
                "featureNames": Features.featureNames,
                "features": features.map { $0.map { $0.isFinite ? $0 as Any : NSNull() } },
                "originalPreRecIndices": ordinals, "recognitionConfidence": confidence,
                "keptOriginalPreRecIndices": kept.map { ordinals[$0] },
                "recognized": try JSONSerialization.jsonObject(with: encoder.encode(kept.map { accepted[$0] })),
                "output": try JSONSerialization.jsonObject(with: encoder.encode(actual)),
                "recognitionThreshold": rec.confidenceThreshold,
                "newRecognizerCalls": 0, "RGBRead": false, "absoluteShapeFeatures": false,
                "textContentUsedForFiltering": false, "GTAtRuntime": false, "geometryModified": false]
            if let result { document["postRecognitionFilter"] = try JSONSerialization.jsonObject(with: encoder.encode(result.report)) }
            if let duplicateResult {
                document["postRecognitionDeduplication"] = try JSONSerialization.jsonObject(with: encoder.encode(duplicateResult.report))
            }
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: output.appendingPathComponent(request.page + ".json"), options: [.atomic])
            print("{\"page\":\"\(request.page)\",\"input\":\(input.individuals.count),\"output\":\(actual.individuals.count)}")
            fflush(stdout)
        }
        return 0
    }
}
