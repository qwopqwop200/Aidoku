import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Real-model input contracts kept outside the routine fast plan.
@Suite(.serialized)
struct NativeOCRResolutionContractTests {
    @Test func bundledDetectorsAccept1184PixelInputs() async throws {
        let width = 2_368, height = 64
        let frame = try #require(NativeOCRRGBAFrame(
            width: width, height: height, bytes: [UInt8](repeating: 255, count: width * height * 4)
        ))
        for tier in IPhoneOCRModelTier.allCases {
            let pipeline = NativeCoreMLOCRPipeline(modelTier: tier)
            let result: NativeCoreMLOCRResult
            do {
                result = try await pipeline.recognize(
                    frame: frame, requestID: "1184-\(tier.rawValue)", confidenceThreshold: 0.75
                )
            } catch {
                await pipeline.purgeResources()
                throw error
            }
            await pipeline.purgeResources()
            #expect(result.width == width && result.height == height)
            #expect(result.diagnostics.detection.inputShape == [1, 3, 32, 1_184])
            #expect(result.diagnostics.detection.outputShape == [1, 1, 32, 1_184])
            #expect(result.diagnostics.detection.resizedWidth == 1_184)
            #expect(result.diagnostics.detection.resizedHeight == 32)
        }
    }

    @Test @MainActor func bundledRecognizersAcceptMaximumReaderWidth() async throws {
        let width = 1_184, height = 48
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            ("HELLO WORLD SAMPLE TEXT 123 HELLO WORLD SAMPLE TEXT 123" as NSString).draw(at: CGPoint(x: 4, y: 4), withAttributes: [
                .font: UIFont.systemFont(ofSize: 32), .foregroundColor: UIColor.black
            ])
        }
        let pixels = try #require(image.cgImage)
        let frame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: pixels))
        let region = NativeCoreMLRecognitionRegion(sourceIndex: 0, polygon: [
            CGPoint(x: 0, y: 0), CGPoint(x: width, y: 0), CGPoint(x: width, y: height), CGPoint(x: 0, y: height)
        ])
        for tier in IPhoneOCRModelTier.allCases {
            let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
            let recognizer = NativeCoreMLRecognizer(modelResourceName: profile.recognizerResourceName,
                dictionaryResourceName: profile.dictionaryResourceName,
                expectedDictionaryCharacterCount: profile.expectedDictionaryCharacterCount,
                idleLongWidthPreparationEnabled: false, recognitionCacheCapacity: 0)
            do {
                let result = try await recognizer.recognize(frame: frame, regions: [region])
                #expect(result.diagnostics.modelFunctionSequence == ["rec1184b1"])
                #expect(result.diagnostics.predictedRegions == 1)
                #expect(result.diagnostics.inputShape == [1, 3, 48, 1_184])
                #expect(result.diagnostics.outputShape == [2, 148])
                #expect(result.regions.count == 1)
                #expect(result.regions.first?.text.isEmpty == false)
                await recognizer.purgeResources()
            } catch {
                await recognizer.purgeResources()
                throw error
            }
        }
    }
}
