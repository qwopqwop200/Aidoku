import CryptoKit
import Foundation

/// Replays admission on authenticated native merged owners without new inference.
/// RF measurements come from the native audit; detector aggregates are joined
/// anew from the exact accepted input packets, never supplied feature matrices.
enum HostPostMergeSignalFilter {
    /// Decode original output numbers directly as binary64 rather than through
    /// NSNumber's JSON parser, preserving retained coordinates and confidences.
    private indirect enum Value: Codable {
        case object([String: Value]), array([Value]), string(String)
        case integer(Int), number(Double), boolean(Bool), null
        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if container.decodeNil() { self = .null }
            else if let value = try? container.decode(Bool.self) { self = .boolean(value) }
            else if let value = try? container.decode(Int.self) { self = .integer(value) }
            else if let value = try? container.decode(Double.self) { self = .number(value) }
            else if let value = try? container.decode(String.self) { self = .string(value) }
            else if let value = try? container.decode([Value].self) { self = .array(value) }
            else { self = .object(try container.decode([String: Value].self)) }
        }
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            switch self {
            case .object(let value): try container.encode(value)
            case .array(let value): try container.encode(value)
            case .string(let value): try container.encode(value)
            case .integer(let value): try container.encode(value)
            case .number(let value): try container.encode(value)
            case .boolean(let value): try container.encode(value)
            case .null: try container.encodeNil()
            }
        }
    }
    private struct Request: Decodable {
        let page: String
        let sourceSHA256: String
        let nativeInput: String
        let nativeInputSHA256: String
        let nativeResult: String
        let nativeResultSHA256: String
    }
    private struct Requests: Decodable { let pages: [Request] }
    private struct Input: Decodable {
        let stage: String
        let value: InputValue
    }
    private struct InputValue: Decodable {
        let width: Int
        let height: Int
        let lines: [Line]
    }
    private struct Line: Decodable {
        let score: Double
        let acceptedSource: Signals?
    }
    private struct Signals: Decodable { let detectorSignals: [Double]? }
    private struct Region: Decodable {
        let id: String
        let body: [Int]
        let readings: [Int]
        let confidence: Double
        let has_untracked_inputs: Bool
    }
    private struct Audit: Decodable {
        let id: String
        let body: [Int]
        let readings: [Int]
        let features: [Double]?
        let keep: Bool
    }
    private struct Page: Decodable {
        let page: String
        let regions: [Region]
        let finalFilter: [Audit]
    }
    static func run(requestURL: URL, output: URL, policyURL: URL?) throws -> Int32 {
        typealias Filter = NativePostMergeSignalFilter
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let requestData = try Data(contentsOf: requestURL)
        let request = try JSONDecoder().decode(Requests.self, from: requestData)
        guard request.pages.count <= 100_000,
              Set(request.pages.map(\.page)).count == request.pages.count else { throw HostError.message("Invalid merged replay pages") }
        let policyData = try policyURL.map { try Data(contentsOf: $0) }
        let policy: Filter.Policy?
        if let policyData {
            guard let object = try JSONSerialization.jsonObject(with: policyData) as? [String: Any],
                  Set(object.keys) == ["version", "featureNames", "rules"] else { throw HostError.message("Invalid merged signal policy keys") }
            let candidate = try JSONDecoder().decode(Filter.Policy.self, from: policyData)
            guard candidate.isValid else { throw HostError.message("Invalid merged signal policy") }
            policy = candidate
        } else { policy = Filter.defaultPolicy }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let canonicalPolicyData = try policy.map { try encoder.encode($0) }
        let binarySHA256 = hash(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])))
        var cache: [String: (String, [Page], [Value])] = [:]
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for item in request.pages {
            guard item.page.count == 4, item.page.allSatisfy(\.isNumber),
                  item.sourceSHA256.count == 64, item.sourceSHA256.allSatisfy(\.isHexDigit) else {
                throw HostError.message("Invalid merged source identity")
            }
            if cache[item.nativeResult] == nil {
                let data = try Data(contentsOf: URL(fileURLWithPath: item.nativeResult))
                guard hash(data) == item.nativeResultSHA256 else {
                    throw HostError.message("Merged native result hash mismatch")
                }
                let objects = try JSONDecoder().decode([Value].self, from: data)
                cache[item.nativeResult] = (hash(data), try JSONDecoder().decode([Page].self, from: data), objects)
            }
            let saved = cache[item.nativeResult]!
            guard saved.0 == item.nativeResultSHA256,
                  saved.1.filter({ $0.page == item.page }).count == 1,
                  let ordinal = saved.1.firstIndex(where: { $0.page == item.page }) else {
                throw HostError.message("Unbound merged native result")
            }
            let page = saved.1[ordinal]
            let data = try Data(contentsOf: URL(fileURLWithPath: item.nativeInput))
            guard hash(data) == item.nativeInputSHA256 else { throw HostError.message("Merged input hash mismatch") }
            let input = try JSONDecoder().decode(Input.self, from: data)
            guard input.stage == "native-ocr", input.value.width > 0, input.value.height > 0,
                  Set(page.regions.map(\.id)).count == page.regions.count,
                  Set(page.finalFilter.map(\.id)).count == page.finalFilter.count else {
                throw HostError.message("Invalid merged native packets")
            }
            let audit = Dictionary(uniqueKeysWithValues: page.finalFilter.map { ($0.id, $0) })
            var values: [[Double]?] = []
            var decisions: [Filter.Decision] = []
            for region in page.regions {
                guard let row = audit[region.id], row.keep,
                      row.body == region.body, row.readings == region.readings,
                      !region.body.isEmpty, Set(region.body).count == region.body.count,
                      region.body.allSatisfy(input.value.lines.indices.contains),
                      region.readings.allSatisfy(input.value.lines.indices.contains) else {
                    throw HostError.message("Merged membership/audit mismatch")
                }
                let body = region.body.sorted()
                let confidence = body.map { input.value.lines[$0].score }
                if let prefix = row.features {
                    let expected = [region.confidence, confidence.min()!, confidence.reduce(0, +) / Double(body.count), confidence.max()!]
                    guard prefix.count == 92, zip(prefix.prefix(4), expected).allSatisfy({ abs($0 - $1) <= 1e-12 }) else {
                        throw HostError.message("Merged REC evidence mismatch")
                    }
                }
                let detector = NativePostLLMContentReclassifier.detectorFeatures(
                    bodySignals: body.map { input.value.lines[$0].acceptedSource?.detectorSignals })
                let vector = region.has_untracked_inputs ? nil : Filter.extract(features: row.features, detectorFeatures: detector)
                values.append(vector)
                decisions.append(Filter.decide(vector, policy: policy))
            }
            let kept = decisions.indices.filter { decisions[$0].keep }
            guard case .object(var object) = saved.2[ordinal],
                  case .array(let rawRegions)? = object["regions"], rawRegions.count == page.regions.count else {
                throw HostError.message("Invalid merged owner serialization")
            }
            object["regions"] = .array(kept.map { rawRegions[$0] })
            let keptIDs = Set(kept.map { page.regions[$0].id })
            if case .array(let ids)? = object["preLLMInputIDs"] {
                object["preLLMInputIDs"] = .array(ids.filter {
                    if case .string(let id) = $0 { return keptIDs.contains(id) }
                    return false
                })
            }
            let metadata: [String: Any] = [
                "schema": "actual-native-postmerge107-admission-v1", "sourceSHA256": item.sourceSHA256,
                "requestSHA256": hash(requestData), "binarySHA256": binarySHA256,
                "nativeInputSHA256": hash(data), "nativeResultSHA256": saved.0,
                "policySHA256": (policyData ?? canonicalPolicyData).map { hash($0) as Any } ?? NSNull(),
                "canonicalPolicySHA256": canonicalPolicyData.map { hash($0) as Any } ?? NSNull(),
                "policySource": policyURL == nil ? "compiled-default" : "explicit-policy",
                "featureNames": Filter.featureNames,
                "features": values.map { row -> Any in row.map { $0 as Any } ?? NSNull() },
                "decisions": try JSONSerialization.jsonObject(with: encoder.encode(decisions)),
                "keptIndices": kept, "inputCount": page.regions.count, "outputCount": kept.count,
                "GTAtRuntime": false, "newModelCalls": 0, "pixelTexture": false,
                "absoluteShapeFeatures": false, "textContentFeatures": false, "geometryModified": false
            ]
            object["postMergeSignalFilter"] = try JSONDecoder().decode(Value.self,
                from: JSONSerialization.data(withJSONObject: metadata))
            try encoder.encode(Value.object(object))
                .write(to: output.appendingPathComponent(item.page + ".json"), options: [.atomic])
            print("{\"page\":\"\(item.page)\",\"input\":\(page.regions.count),\"output\":\(kept.count)}")
        }
        return 0
    }
}
