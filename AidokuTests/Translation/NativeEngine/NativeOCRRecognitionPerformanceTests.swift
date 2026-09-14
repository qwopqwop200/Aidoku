import CoreGraphics
import CryptoKit
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct NativeOCRRecognitionPerformanceTests {
    /// A repeatable real-model workload. Crop caching is disabled so warm runs
    /// still measure recognition, rather than reuse of the preceding result.
    @Test @MainActor func bundledMediumDenseRecognition() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 1_000, height: 1_000), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1_000, height: 1_000))
            for index in 0..<24 {
                ("HELLO WORLD SAMPLE TEXT 123" as NSString).draw(
                    at: CGPoint(x: 8, y: index * 40),
                    withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black]
                )
            }
        }
        let pixels = try #require(image.cgImage)
        let frame = try #require(NativeOCRCGImageAdapter.makeRGBAFrame(from: pixels))
        let regions = (0..<24).map { index in
            let width = [200, 400, 800][index % 3]
            let y = index * 40
            return NativeCoreMLRecognitionRegion(sourceIndex: index, polygon: [
                CGPoint(x: 0, y: y), CGPoint(x: width, y: y),
                CGPoint(x: width, y: y + 32), CGPoint(x: 0, y: y + 32)
            ])
        }
        let recognizer = NativeCoreMLRecognizer(recognitionCacheCapacity: 0, maximumRecognitionWidth: 1_600)
        var reference: [NativeCoreMLRecognizedRegion]?
        for run in 0..<4 {
            let result = try await recognizer.recognize(frame: frame, regions: regions)
            #expect(result.regions.count == regions.count)
            #expect(result.regions.map(\.sourceIndex) == Array(0..<24))
            #expect(result.diagnostics.cacheHitRegions == 0)
            if let reference { #expect(result.regions == reference) } else { reference = result.regions }
            let digest = SHA256.hash(data: Data(result.regions.map(\.text).joined(separator: "\n").utf8))
                .map { String(format: "%02x", $0) }.joined()
            let diagnostic = result.diagnostics
            print("OCR_BENCH run=\(run) total_ms=\(diagnostic.totalMilliseconds) prep_ms=\(diagnostic.preprocessingMilliseconds) "
                  + "prediction_ms=\(diagnostic.predictionMilliseconds) digest=\(digest)")
        }
        await recognizer.purgeResources()
    }
}
