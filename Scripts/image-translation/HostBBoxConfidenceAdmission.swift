import Foundation
import CoreGraphics
import CryptoKit
import ImageIO

/// Apply the SAME production admission to saved emitted geometry and genuine
/// source probability maps. No GT, detector, recognizer, RF, or provider calls.
enum HostBBoxConfidenceAdmission {
    struct Request: Decodable {
        let page: String
        let geometry: String
        let geometrySHA256: String
        let source: String
        let sourceSHA256: String
        let width: Int
        let height: Int
        let probability: String
        let probabilitySHA256: String
        let mapWidth: Int
        let mapHeight: Int
    }
    struct Geometry: Decodable {
        let page: String
        let sourceSHA256: String
        let output: NativeOCRIndividualGeometryHypotheses.Output
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    struct DeduplicationRequest: Decodable {
        let page: String
        let geometry: String
        let geometrySHA256: String
        let sourceSHA256: String
    }
    /// Replays the exact production selector; GT is never accepted as input.
    static func deduplicate(output: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let binaryHash = digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]), options: .mappedIfSafe))
        while let line = readLine() {
            let request = try JSONDecoder().decode(DeduplicationRequest.self, from: Data(line.utf8))
            guard request.page.count == 4, request.page.allSatisfy(\.isNumber) else {
                throw HostError.message("Invalid geometry deduplication page")
            }
            let geometry = try Data(contentsOf: URL(fileURLWithPath: request.geometry), options: .mappedIfSafe)
            guard digest(geometry) == request.geometrySHA256 else {
                throw HostError.message("Geometry deduplication input digest mismatch")
            }
            let saved = try JSONDecoder().decode(Geometry.self, from: geometry)
            guard saved.page == request.page, saved.sourceSHA256 == request.sourceSHA256 else {
                throw HostError.message("Geometry deduplication source binding mismatch")
            }
            let result = try NativeOCRGeometryDeduplication.configured(saved.output)
            guard result.report.enabled else { throw HostError.message("Geometry deduplication not enabled") }
            let data: [String: Any] = ["schema": "native-saved-geometry-deduplication-v1", "page": request.page,
                "nativeBinarySHA256": binaryHash, "sourceSHA256": request.sourceSHA256,
                "geometryInputSHA256": request.geometrySHA256,
                "output": try JSONSerialization.jsonObject(with: encoder.encode(result.output)),
                "geometryDeduplication": try JSONSerialization.jsonObject(with: encoder.encode(result.report)),
                "detectorCalls": 0, "recognizerCalls": 0, "providerCalls": 0, "GTAtInference": false]
            try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(
                to: output.appendingPathComponent(request.page + ".json"), options: .atomic)
        }
        return 0
    }
    static func run(output: URL) throws -> Int32 {
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let binaryHash = digest(try Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[0]), options: .mappedIfSafe))
        while let line = readLine() {
            let bytes = Data(line.utf8)
            let request = try JSONDecoder().decode(Request.self, from: bytes)
            guard request.page.count == 4, request.page.allSatisfy(\.isNumber),
                  request.width > 0, request.height > 0,
                  request.mapWidth > 0, request.mapHeight > 0,
                  request.mapWidth <= 2_000, request.mapHeight <= 2_000 else {
                throw HostError.message("Invalid bbox-confidence source geometry")
            }
            let source = try Data(contentsOf: URL(fileURLWithPath: request.source), options: .mappedIfSafe)
            let geometry = try Data(contentsOf: URL(fileURLWithPath: request.geometry), options: .mappedIfSafe)
            let probability = try Data(contentsOf: URL(fileURLWithPath: request.probability), options: .mappedIfSafe)
            guard digest(source) == request.sourceSHA256, digest(geometry) == request.geometrySHA256,
                  digest(probability) == request.probabilitySHA256,
                  probability.count == request.mapWidth*request.mapHeight*4 else {
                throw HostError.message("BBox-confidence input digest mismatch")
            }
            guard let image = CGImageSourceCreateWithData(source as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(image, 0, nil) as? [CFString: Any],
                  (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue == request.width,
                  (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue == request.height else {
                throw HostError.message("BBox-confidence original frame dimensions mismatch")
            }
            let saved = try JSONDecoder().decode(Geometry.self, from: geometry)
            guard saved.page == request.page, saved.sourceSHA256 == request.sourceSHA256 else {
                throw HostError.message("BBox-confidence source binding mismatch")
            }
            let values = probability.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
            let sample = NativeMainEnsembleOCRProbability.Sample(sourceWidth: request.width, sourceHeight: request.height,
                resizedWidth: request.mapWidth, resizedHeight: request.mapHeight,
                region: CGRect(x: 0, y: 0, width: request.mapWidth, height: request.mapHeight),
                width: request.mapWidth, height: request.mapHeight, values: values)
            let result = try NativeOCRBBoxConfidenceAdmission.apply(saved.output, probability: sample,
                sourceWidth: request.width, sourceHeight: request.height, enabled: true)
            guard result.report.applied else { throw HostError.message("BBox-confidence admission not applied") }
            let data: [String: Any] = ["schema": "native-saved-bbox-confidence-admission-v1", "page": request.page,
                "nativeBinarySHA256": binaryHash,
                "sourceSHA256": request.sourceSHA256, "geometryInputSHA256": request.geometrySHA256,
                "probabilitySHA256": request.probabilitySHA256,
                "requestSHA256": digest(bytes),
                "output": try JSONSerialization.jsonObject(with: encoder.encode(result.output)),
                "bboxConfidenceAdmission": try JSONSerialization.jsonObject(with: encoder.encode(result.report)),
                "detectorCalls": 0, "recognizerCalls": 0, "providerCalls": 0, "GTAtInference": false]
            try JSONSerialization.data(withJSONObject: data, options: [.sortedKeys]).write(
                to: output.appendingPathComponent(request.page + ".json"), options: .atomic)
        }
        return 0
    }
}
