import Foundation
import Testing
@testable import Aidoku

/// Bundled detector precision contracts through the production pipeline.
@Suite(.serialized)
struct OCRDetectorPrecisionDeviceTests {

    /// Every bundled fp16 detector tier must load with the production
    /// configuration and return float32 output through the production pipeline.
    @Test func bundledFloat16DetectorsRunThroughProductionPipeline() async throws {
        guard #available(iOS 18.0, *) else { return }
        let width = 800, height = 1_100
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        // Dark horizontal strokes resembling a text line.
        for row in 500..<530 { for column in 200..<600 where column % 40 < 28 {
            let offset = row * width * 4 + column * 4
            bytes[offset] = 0; bytes[offset + 1] = 0; bytes[offset + 2] = 0
        } }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytesPerRow: width * 4, bytes: bytes))
        for tier in IPhoneOCRModelTier.allCases {
            let profile = NativeCoreMLOCRModelProfile.profile(for: tier)
            let detector = NativeCoreMLDetector(modelResourceName: profile.detectorResourceName,
                                                maximumSide: IPhoneOCRSettings.defaultDetectorMaximumSide)
            let result = try await detector.detect(frame: frame, requestID: "fp16-\(tier.rawValue)",
                                                   configuration: profile.postprocessConfiguration)
            #expect(result.width == width && result.height == height)
            print("OCR_PRECISION_TIER \(tier.rawValue) boxes=\(result.boxes.count) ms=\(result.diagnostics.totalMilliseconds)")
            await detector.purgeResources()
        }
    }

}
