import CoreML
import CryptoKit
import Testing
import UIKit
@testable import Aidoku

/// Diagnostic A/B of immutable source crops. Changes only right-side zero padding;
/// production sampling pixels, model, compute unit, dictionary and CTC decoding match.
@Suite(.serialized)
@MainActor
struct NativeOCRFragmentDiagnosticTests {
    @Test func fragmentedGlyphsCompareExactAndPaddedModelInputs() async throws {
        let fixtureSHA256 = [
            "SevenDefectReplay/lobe-8.png": "19786bce77dc7805d747fd49df2757cc7fceebcec10bc64a5ac2108d9bfa4bbc",
            "SevenDefectReplay/panel-1.png": "54240f0368cb48928217ff640722942f16ba00b68a6de56d36a1e8a8eaf47c94",
            "SevenDefectReplay/case-4.png": "df195181d3e43d467667ab910d2eb3e9f1ee0212a014e241f065474cf561a70e"
        ]
        // Check immutable original bytes before loading any model or sampling crops.
        for (path, expected) in fixtureSHA256 {
            let data = try Data(contentsOf: URL.documentsDirectory.appendingPathComponent(path))
            let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            try #require(digest == expected, "Original source fixture changed: \(path)")
        }
        let modelURL = try #require(Bundle.main.url(forResource: NativeCoreMLRecognizer.modelResourceName, withExtension: "mlmodelc"))
        let dictionaryURL = try #require(Bundle.main.url(forResource: NativeCoreMLRecognizer.dictionaryResourceName, withExtension: "txt"))
        let dictionary = try NativeCoreMLRecognizer.loadDictionary(from: dictionaryURL,
            expectedCharacterCount: NativeCoreMLRecognizer.expectedDictionaryCharacterCount)
        let configuration = MLModelConfiguration()
#if targetEnvironment(simulator)
        configuration.computeUnits = .cpuOnly
#else
        configuration.computeUnits = .all
#endif
        configuration.optimizationHints.reshapeFrequency = .frequent
        configuration.optimizationHints.specializationStrategy = .fastPrediction
        let model = try MLModel(contentsOf: modelURL, configuration: configuration)
        let crops: [(String, String, [CGPoint])] = [
            ("lobe-joined-short-column", "SevenDefectReplay/lobe-8.png",
             [CGPoint(x: 1951, y: 1898), CGPoint(x: 2020, y: 1898), CGPoint(x: 2020, y: 2024), CGPoint(x: 1951, y: 2024)]),
            ("panel-confused-kana-column", "SevenDefectReplay/panel-1.png",
             [CGPoint(x: 461, y: 1903), CGPoint(x: 539, y: 1901), CGPoint(x: 542, y: 2098), CGPoint(x: 464, y: 2100)]),
            ("panel-long-dash", "SevenDefectReplay/panel-1.png",
             [CGPoint(x: 308, y: 2020), CGPoint(x: 377, y: 2020), CGPoint(x: 377, y: 2143), CGPoint(x: 308, y: 2143)]),
            ("slanted-reaction", "SevenDefectReplay/case-4.png",
             [CGPoint(x: 231, y: 1958), CGPoint(x: 607, y: 1924), CGPoint(x: 668, y: 2623), CGPoint(x: 292, y: 2657)]),
            ("slanted-punctuation", "SevenDefectReplay/case-4.png",
             [CGPoint(x: 356, y: 2567), CGPoint(x: 583, y: 2532), CGPoint(x: 611, y: 2711), CGPoint(x: 383, y: 2747)])
        ]
        var rows: [[String: Any]] = []
        for (name, path, polygon) in crops {
            let image = try #require(UIImage(contentsOfFile: URL.documentsDirectory.appendingPathComponent(path).path)?.cgImage)
            let frame = try #require(await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: image))
            let plan = try #require(NativeCoreMLRecognitionPreprocessor.plan(polygon: polygon,
                dynamicWidth: true, maximumWidth: 1600))
            let tensor = try #require(NativeCoreMLRecognitionPreprocessor.prepare(frame: frame, plan: plan))
            let legacyWidth = max(160, ((tensor.resizedWidth + 31) / 32) * 32)
            var modes = [("exact", tensor.bucket.width), ("right-zero-padding", legacyWidth)]
            if name == "panel-confused-kana-column" || name == "slanted-punctuation" {
                modes.append(("right-zero-padding-192", 192))
            }
            for (mode, width) in modes {
                let input = try MLMultiArray(shape: [1, 3, 48, width].map(NSNumber.init(value:)), dataType: .float32)
                let destination = input.dataPointer.assumingMemoryBound(to: Float.self)
                destination.initialize(repeating: 0, count: input.count)
                for channel in 0..<3 {
                    for y in 0..<48 {
                        for x in 0..<tensor.resizedWidth {
                            destination[(channel * 48 + y) * width + x] = tensor.values[(channel * 48 + y) * tensor.bucket.width + x]
                        }
                    }
                }
                let output = try await model.prediction(from: MLDictionaryFeatureProvider(dictionary: [NativeCoreMLRecognizer.inputFeatureName: input]))
                let indices = try #require(output.featureValue(for: NativeCoreMLRecognizer.indexOutputFeatureName)?.multiArrayValue)
                let scores = try #require(output.featureValue(for: NativeCoreMLRecognizer.scoreOutputFeatureName)?.multiArrayValue)
                let expectedSteps = (width + 3) / 8
                try #require(indices.shape.map(\.intValue) == [1, expectedSteps])
                try #require(scores.shape.map(\.intValue) == [1, expectedSteps])
                let compact = try MLMultiArray(shape: [2, expectedSteps].map(NSNumber.init(value:)), dataType: .float32)
                for step in 0..<expectedSteps {
                    compact[[0, NSNumber(value: step)]] = indices[[0, NSNumber(value: step)]]
                    compact[[1, NSNumber(value: step)]] = scores[[0, NSNumber(value: step)]]
                }
                let decoded = try NativeCoreMLCTCDecoder.decode(output: compact, dictionary: dictionary,
                    expectedShape: [2, expectedSteps])
                rows.append(["crop": name, "mode": mode, "width": width, "resizedWidth": tensor.resizedWidth,
                    "sourcePath": path, "sourceSHA256": fixtureSHA256[path] ?? "",
                    "modelResource": NativeCoreMLRecognizer.modelResourceName,
                    "computeUnits": String(describing: configuration.computeUnits),
                    "timeSteps": expectedSteps, "text": decoded.text, "confidence": decoded.confidence,
                    "polygon": polygon.map { [$0.x, $0.y] }])
            }
        }
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL.documentsDirectory.appendingPathComponent("native-ocr-fragment-diagnostic.json"))
        #expect(rows.count == 12)
    }
}
