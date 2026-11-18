import CryptoKit
import Foundation

/// Actual RF/DET evidence -> signal extraction -> admission, without recognition.
/// No caller-supplied feature matrix or target geometry is accepted.
enum HostPreRecognitionFilter {
    private struct RFGrid: Decodable {
        let imageIdentity: String
        let native17Fields: [Float]
    }
    private struct Request: Decodable {
        let page: String
        let sourceSHA256: String
        let width: Int
        let height: Int
        let geometry: String
        let geometrySHA256: String
        let originals: [HostIndividualGeometry.SavedBox]
        let auxiliaryOriginals: [HostIndividualGeometry.SavedBox]
        let rfGrid: RFGrid
    }
    private struct Geometry: Decodable {
        let page: String
        let sourceSHA256: String
        let output: NativeOCRIndividualGeometryHypotheses.Output
    }
    static func run(output: URL, policyURL: URL? = nil) throws -> Int32 {
        typealias Features = NativeOCRPreRecognitionFeatures
        let hash: (Data) -> String = { SHA256.hash(data: $0).map { String(format: "%02x", $0) }.joined() }
        let policyData = try policyURL.map { try Data(contentsOf: $0) }
        let model = try policyData.map {
            try NativeOCRPreRecognitionFilter.Model(data: $0, expectedFeatureNames: Features.featureNames)
        }
        let binarySHA = hash(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0])))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let allowed: Set<String> = ["page", "sourceSHA256", "width", "height", "geometry", "geometrySHA256",
                                    "originals", "auxiliaryOriginals", "rfGrid"]
        var seen = Set<String>()
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        while let line = readLine() {
            let bytes = Data(line.utf8)
            guard bytes.count <= 64_000_000,
                  let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  Set(object.keys) == allowed else { throw HostError.message("Invalid pre-rec signal request") }
            let request = try JSONDecoder().decode(Request.self, from: bytes)
            guard request.page.count == 4, request.page.allSatisfy(\.isNumber), seen.insert(request.page).inserted,
                  request.originals.count <= 4096, request.auxiliaryOriginals.count <= 4096,
                  request.rfGrid.imageIdentity == request.sourceSHA256,
                  let rf = NativeOCRSourceSupportFeatures155.PreparedRF(width: request.width, height: request.height,
                    native17Fields: request.rfGrid.native17Fields) else {
                throw HostError.message("Invalid pre-rec RF/source identity")
            }
            let geometryBytes = try Data(contentsOf: URL(fileURLWithPath: request.geometry))
            guard hash(geometryBytes) == request.geometrySHA256 else { throw HostError.message("Pre-rec geometry hash mismatch") }
            let geometry = try JSONDecoder().decode(Geometry.self, from: geometryBytes)
            guard geometry.page == request.page, geometry.sourceSHA256 == request.sourceSHA256 else {
                throw HostError.message("Pre-rec geometry/source mismatch")
            }
            let all = request.originals + request.auxiliaryOriginals
            let sources = all.map { Features.SourceObservation(polygon: $0.polygon,
                score: $0.score, detectorSeedEvidence: $0.detectorSeedEvidence) }
            let candidateSources = try geometry.output.individuals.map { row -> Features.SourceObservation in
                guard row.provenance.count == 1, let p = row.provenance.first,
                      p.requestID == request.page, p.origin == .corrected, p.originalDetectorIndex == nil,
                      p.sourceMembers.isEmpty, all.indices.contains(p.sourceParent),
                      p.alternativeID == "raw-canonical-8d/\(p.sourceParent)", p.polygon == row.polygon,
                      row.bboxConfidence.map({ $0.isFinite && $0 >= 0.085 && $0 <= 1 }) == true else {
                    throw HostError.message("Unbound pre-rec detector evidence")
                }
                let n = request.originals.count, a = request.auxiliaryOriginals.count
                let expectedIndex = p.sourceParent < n ? n + p.sourceParent : 2 * n + a + p.sourceParent - n
                guard p.sourceIndex == expectedIndex else { throw HostError.message("Pre-rec source index mismatch") }
                return sources[p.sourceParent]
            }
            let features = try Features.extract(input: geometry.output, sourceObservations: candidateSources,
                detectorObservations: sources, rf: rf, sourceWidth: request.width, sourceHeight: request.height)
            let result = try model.map { try NativeOCRPreRecognitionFilter.apply(geometry.output, features: features, model: $0) }
            let actual = result?.output ?? geometry.output
            var document: [String: Any] = ["schema": "actual-native-pre-rec-signal-filter-v1", "page": request.page,
                "sourceSHA256": request.sourceSHA256, "inputSHA256": hash(bytes), "geometrySHA256": hash(geometryBytes),
                "binarySHA256": binarySHA, "policySHA256": policyData.map { hash($0) as Any } ?? NSNull(),
                "inputCount": geometry.output.individuals.count, "outputCount": actual.individuals.count,
                "featureNames": Features.featureNames,
                "features": features.map { $0.map { $0.isFinite ? $0 as Any : NSNull() } },
                "output": try JSONSerialization.jsonObject(with: encoder.encode(actual)),
                "recognizerCalls": 0, "RGBRead": false, "shapeFeatures": false,
                "GTAtRuntime": false, "geometryModified": false]
            if let result { document["preRecognitionFilter"] = try JSONSerialization.jsonObject(with: encoder.encode(result.report)) }
            try JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])
                .write(to: output.appendingPathComponent(request.page + ".json"), options: [.atomic])
            print("{\"page\":\"\(request.page)\",\"input\":\(geometry.output.individuals.count),\"output\":\(actual.individuals.count)}")
            fflush(stdout)
        }
        return 0
    }
}
