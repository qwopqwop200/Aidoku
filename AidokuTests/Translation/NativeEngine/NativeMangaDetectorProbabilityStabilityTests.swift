import Testing
import UIKit
@testable import Aidoku

@Suite @MainActor
struct NativeMangaDetectorProbabilityStabilityTests {
    @Test func mangaProbabilityIsFiniteAcrossTheWholeReaderPage() async throws {
        let original = try #require(ReaderTranslationPersistentPipelineTests.image().cgImage)
        let frame = try #require(await NativeOCRCGImageAdapter.makeRGBAFrameOffMain(from: original))
        let detector = NativeCoreMLDetector(modelResourceName: "PP-OCRv6-Manga-DetShapes")
        let capture = NativeOCRRFPrimaryEnsemble.MapCapture()
        let result = try await detector.detect(
            frame: frame, requestID: "finite-manga-probabilities", configuration: .manga,
            recognitionScopes: nil, probabilityObserver: capture.observer(forwarding: nil),
            cancellationCheck: { try Task.checkCancellation() }
        )
        let sample = try #require(capture.take())
        #expect(sample.region == CGRect(x: 0, y: 0, width: 600, height: 800))
        #expect(sample.values.count == 480_000)
        #expect(sample.values.allSatisfy { $0.isFinite && (0...1).contains($0) })
        #expect(sample.values.contains { $0 > 0.85 })
        #expect(sample.values.contains { $0 < 0.1 })
        #expect(result.diagnostics.computeUnits == "cpuAndGPU")
#if targetEnvironment(simulator)
        #expect(sample.producer?.computeUnits == "cpuAndGPU|MLTensor=cpuAndGPU|reshape=frequent|specialization=fastPrediction")
#endif
    }
}
