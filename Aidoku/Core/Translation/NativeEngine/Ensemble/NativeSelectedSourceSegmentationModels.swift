import CryptoKit
import Foundation

/// Selected exported HGB probabilities with authenticated operational resources.
private struct NativeSegmentationFrozenPixelClassifier: NativeSelectedSourceSegmentationProducer.PixelClassifier {
    let model: NativeFrozenSourceModel
    private let preparedPositiveBatch: NativeFrozenSourceModel.PreparedPositiveBatch?
    var featureCount: Int { model.featureCount }
    init(directory: URL, id: String, expectedSourceSHA256: String, expectedFeatures: Int) throws {
        let index = directory.appendingPathComponent("registry-index.json")
        let registryURL = FileManager.default.fileExists(atPath: index.path) ? index : directory.appendingPathComponent("registry.json")
        let data = try Data(contentsOf: registryURL)
        guard let registry = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              registry["schema"] as? Int == 1, registry["sourceOnly"] as? Bool == true,
              registry["GTAtInference"] as? Bool == false,
              let sources = registry["sourceArtifacts"] as? [String: String], sources[id] == expectedSourceSHA256,
              let heads = registry["heads"] as? [String: [String: Any]], let entry = heads[id],
              entry["sourceModelSHA256"] as? String == expectedSourceSHA256,
              entry["featureCount"] as? Int == expectedFeatures, let relative = entry["asset"] as? String,
              !relative.hasPrefix("/"), !relative.split(separator: "/").contains(".."),
              let expected = entry["sha256"] as? String else { throw NativeSourceSegmentationObservations.Failure.artifactMismatch }
        let nested = directory.appendingPathComponent(relative)
        let path = FileManager.default.fileExists(atPath: nested.path) ? nested : directory.appendingPathComponent(nested.lastPathComponent)
        let encoded = try Data(contentsOf: path)
        let actual = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else { throw NativeSourceSegmentationObservations.Failure.artifactMismatch }
        let decoded = try NativeFrozenSourceModel(data: encoded)
        guard decoded.featureCount == expectedFeatures, decoded.classes == [0, 1], decoded.link == "sigmoid" else {
            throw NativeSourceSegmentationObservations.Failure.artifactMismatch
        }
        model = decoded
        preparedPositiveBatch = decoded.preparedPositiveProbabilities()
    }
    func probabilities(_ features: NativePixelRFFeatures.Matrix) throws -> [Double] {
        guard features.featureCount == featureCount, features.values.count == features.pixelCount * featureCount else {
            throw NativeSelectedSourceSegmentationProducer.Failure.invalidInput
        }
        if let preparedPositiveBatch {
            return try preparedPositiveBatch(features.values, features.pixelCount, nil)
        }
        var result = [Double](); result.reserveCapacity(features.pixelCount)
        var vector = [Double](repeating: 0, count: featureCount)
        for row in 0..<features.pixelCount {
            for c in 0..<featureCount { vector[c] = Double(features.values[row * featureCount + c]) }
            let probabilities = try model.predictProbability(vector)
            guard probabilities.count == 2 else { throw NativeSelectedSourceSegmentationProducer.Failure.invalidModelOutput }
            result.append(probabilities[1])
        }
        return result
    }
}

extension NativeSelectedSourceSegmentationProducer.Models {
    static func loadAccepted(bundle: Bundle = .main, sourceDirectory: URL? = nil,
                             numericDirectory: URL? = nil) throws -> Self {
        let source = try NativeSourceSegmentationObservations.Models(assetDirectory: sourceDirectory, bundle: bundle)
        let numeric: URL
        if let numericDirectory { numeric = numericDirectory }
        else {
            var candidates: [URL] = []
            if let resources = bundle.resourceURL {
                candidates += [resources.appendingPathComponent("Translation/SourceModels"),
                    resources.appendingPathComponent("SourceModels"),
                    resources.appendingPathComponent("Resources/Translation/SourceModels"), resources]
            }
            #if os(macOS)
            // Generated host sources have a different #filePath hierarchy.
            // Resolve existing operational assets through the launcher root;
            // registry/source/model hashes still authenticate every head.
            if let root = ProcessInfo.processInfo.environment["AIDOKU_PIPELINE_ROOT"], !root.isEmpty {
                candidates.append(URL(fileURLWithPath: root, isDirectory: true)
                    .appendingPathComponent("Aidoku/Resources/Translation/SourceModels"))
            }
            var repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            for _ in 0..<5 { repository.deleteLastPathComponent() }
            candidates.append(repository.appendingPathComponent("Aidoku/Resources/Translation/SourceModels"))
            #endif
            guard let directory = candidates.first(where: {
                FileManager.default.fileExists(atPath: $0.appendingPathComponent("registry-index.json").path) ||
                    FileManager.default.fileExists(atPath: $0.appendingPathComponent("registry.json").path)
            }) else { throw NativeSourceSegmentationObservations.Failure.missingAcceptedAssets }
            numeric = directory
        }
        return try .init(observations: source,
            context83: NativeSegmentationFrozenPixelClassifier(directory: numeric, id: "segmentation/context83",
                expectedSourceSHA256: NativeSegmentationFinalPolicy.jointModelSHA256, expectedFeatures: 83),
            style78: NativeSelectedSourceSegmentationProducer.connectedWeakEnabled ? nil : NativeSegmentationFrozenPixelClassifier(directory: numeric, id: "segmentation/style78",
                expectedSourceSHA256: NativeSegmentationFinalPolicy.auxiliaryModelSHA256, expectedFeatures: 78))
    }
}

extension NativeSelectedSourceSegmentationProducer {
    convenience init(bundle: Bundle = .main, sourceDirectory: URL? = nil, numericDirectory: URL? = nil) throws {
        try self.init(models: .loadAccepted(bundle: bundle, sourceDirectory: sourceDirectory, numericDirectory: numericDirectory),
            operations: NativeSegmentationOpenCVOperations())
    }
}
