import CoreML
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Real bundled model checks; opt in through AidokuFull or this focused suite.
@Suite(.serialized)
struct NativeOCRMangaTests {
    @Test @MainActor func bundledMangaPipelineRecognizesJapaneseText() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 384, height: 128), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 384, height: 128))
            ("今日はいい天気です" as NSString).draw(at: CGPoint(x: 24, y: 40), withAttributes: [
                .font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black
            ])
        }
        let pipeline = NativeCoreMLOCRPipeline()
        do {
            let result = try await pipeline.recognize(image: #require(image.cgImage), requestID: "manga-japanese", confidenceThreshold: 0.75)
            #expect(result.lines.map(\.text).joined().contains("天気"))
            #expect(result.diagnostics.detection.inputShape[3] <= 960)
            #expect(result.diagnostics.detectionModel == NativeCoreMLDetector.modelResourceName)
            #expect(result.diagnostics.recognitionModel == NativeCoreMLRecognizer.modelResourceName)
            await pipeline.purgeResources()
        } catch {
            await pipeline.purgeResources()
            throw error
        }
    }

    @Test func bundledMangaRecognizerAcceptsDynamicNativeABI() throws {
        let profile = NativeCoreMLOCRModelProfile.profile(for: .manga)
        let url = try #require(Bundle.main.url(forResource: profile.recognizerResourceName, withExtension: "mlmodelc"))
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        let model = try MLModel(contentsOf: url, configuration: configuration)
        for (batch, width) in [(1, 32), (1, 37), (4, 640), (1, 1_184)] {
            let input = try MLMultiArray(shape: [batch, 3, 48, width].map(NSNumber.init(value:)), dataType: .float32)
            input.dataPointer.initializeMemory(as: UInt8.self, repeating: 0, count: input.count * MemoryLayout<Float>.stride)
            let output = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["x": input]))
            let indices = try #require(output.featureValue(for: "ctc_indices")?.multiArrayValue)
            let scores = try #require(output.featureValue(for: "ctc_scores")?.multiArrayValue)
            #expect(indices.shape.map(\.intValue) == [batch, (width + 3) / 8])
            #expect(scores.shape == indices.shape)
            #expect(indices.dataType == .int32)
            #expect(scores.dataType == .float32)
        }
    }
}
