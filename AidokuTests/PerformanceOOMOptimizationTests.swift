import AidokuRunner
import CoreML
import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct PerformanceOOMOptimizationTests {
    @Test func processorFailureReleasesSourceHandle() async throws {
        let runner = TestableSourceRunner(failsProcessing: true)
        let source = AidokuRunner.Source.test(runner: runner)
        let request = ImageRequest(urlRequest: URLRequest(url: URL(string: "https://test.invalid/page")!))
        let container = ImageContainer(image: .mangaPlaceholder)
        do {
            _ = try await PageInterceptorProcessor(source: source, pageContext: nil).processAsync(container,
                context: .init(request: request, response: .init(container: container, request: request), isCompleted: true))
            Issue.record("Expected cancellation from source")
        } catch is CancellationError { }
        #expect(await runner.storage.liveCount() == 0)
    }

    @Test func imageBudgetOverflowCannotWrapIntoSmallAdmission() {
        #expect(TranslationImageWorkBudget.requiredHeadroom(decodedBytes: .max) == .max)
        #expect(TranslationImageWorkBudget.requiredHeadroom(decodedBytes: 96_000_000) >= 1_280 * 1_024 * 1_024)
    }

    @Test func cancelledMemoryWaitNeverDecodes() async throws {
        let budget = TranslationImageWorkBudget(availableMemory: { 0 })
        let work = Task {
            try await budget.withPermit { Issue.record("Must not decode without headroom"); return 1 }
        }
        await Task.yield()
        work.cancel()
        do { _ = try await work.value; Issue.record("Expected cancellation") }
        catch is CancellationError { }
    }

    @Test @MainActor func downsamplePreservesAlphaAndDoesNotUpscale() throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 400, height: 200), format: format).image { context in
            UIColor.red.withAlphaComponent(0.5).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 400, height: 200))
        }
        let output = try #require(DownsampleProcessor(width: 40).process(source))
        #expect(output.size == CGSize(width: 40, height: 20))
        #expect(output.cgImage?.alphaInfo != CGImageAlphaInfo.none)
        #expect(DownsampleProcessor(width: 800).process(source) === source)
        #expect(TranslationImageWorkBudget.decodedBytes(in: try #require(source.pngData())) == 400 * 200 * 4)
    }

    @Test func imageRepresentationIsNotPersistedAndInvalidatesOnReplacement() throws {
        var request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", segments: [])
        request.imageJPEG = Data([1, 2, 3])
        request.prepareImageRepresentation()
        #expect(request.preparedImageDataURL == "data:image/jpeg;base64,AQID")
        let encoded = try JSONEncoder().encode(request)
        #expect(!String(decoding: encoded, as: UTF8.self).contains("preparedImageDataURL"))
        let decoded = try JSONDecoder().decode(RemoteTranslationRequest.self, from: encoded)
        #expect(decoded.imageJPEG == request.imageJPEG)
        #expect(decoded == request)
        #expect(Set([decoded, request]).count == 1)
        request.imageJPEG = Data([4])
        #expect(request.preparedImageDataURL == nil)
    }

    @Test func boundedDetectorPreservesNonAlignedHighContrastSampling() async throws {
        guard #available(iOS 18.0, *) else { return }
        let width = 1281, height = 64
        var bytes = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height {
            for x in 0..<width {
                for channel in 0..<3 { bytes[(y * width + x) * 4 + channel] = x.isMultiple(of: 2) ? 0 : 255 }
            }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytes: bytes))
        let canvas = try #require(NativeCoreMLDetectionCanvas(inputShape: [1, 3, height, 1312]))
        let reference = try await NativeCoreMLDetectionPreprocessor.prepare(frame: frame, canvas: canvas, useBoundedMemory: false)
        let bounded = try await NativeCoreMLDetectionPreprocessor.prepare(frame: frame, canvas: canvas)
        let expected = await reference.values(), actual = await bounded.values()
        let error = zip(expected, actual).reduce(Float(0)) { max($0, abs($1.0 - $1.1)) }
        #expect(error < 0.001)
    }

    @Test func boundedDetectorInputMatchesMLTensorResize() async throws {
        guard #available(iOS 18.0, *) else { return }
        // Deliberately non-aligned dimensions and row padding exercise the
        // half-pixel convention and ensure padding is not sampled as artwork.
        let width = 257, height = 389, stride = 257 * 4 + 16
        var bytes = [UInt8](repeating: 0, count: stride * height)
        for y in 0..<height {
            for x in 0..<width {
                for c in 0..<4 { bytes[y * stride + x * 4 + c] = UInt8((x * 7 + y * 3 + c * 47) % 256) }
            }
        }
        let frame = try #require(NativeOCRRGBAFrame(width: width, height: height, bytesPerRow: stride, bytes: bytes))
        let canvas = try #require(NativeCoreMLDetectionCanvas(inputShape: [1, 3, 192, 128]))
        let dimensions = try #require(NativeCoreMLDetectionPreprocessor.resizeDimensions(sourceWidth: width,
            sourceHeight: height, maximumSide: 192))
        let reference = try await NativeCoreMLDetectionPreprocessor.prepare(frame: frame, canvas: canvas, useBoundedMemory: false)
        let bounded = try await NativeCoreMLDetectionPreprocessor.prepareBounded(frame: frame, canvas: canvas, dimensions: dimensions)
        let expected = await reference.values(), actual = await bounded.values()
        #expect(expected.count == actual.count)
        let error = zip(expected, actual).map { abs($0 - $1) }.max() ?? .infinity
        print("BOUNDED_DETECTOR_MAX_ERROR=\(error)")
        // Core ML's device resize backend and the CPU sampler round fractional
        // coordinates differently. Use the same bound as the real-page corpus.
        #expect(error < 0.001)
        // Independent double-precision bilinear reference for the patterned
        // source above; keep the CPU sampler itself under the tighter bound.
        let anchors: [(Int, Int, [Float])] = [
            (0, 0, [-0.4214161101, -1.1241875657, -1.7161410675]),
            (63, 95, [-1.6737975212, 2.0772687981, 1.4710866013]),
            (127, 191, [1.8025275066, 1.1493976497, 0.5473393246])
        ]
        for (x, y, channels) in anchors {
            for channel in 0..<3 {
                #expect(abs(actual[channel * 192 * 128 + y * 128 + x] - channels[channel]) < 0.0001)
            }
        }
    }

    @Test func bufferedTouchesPreserveEvictionOrder() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = ReaderTranslationDiskCache(directory: root)
        for name in ["a", "b", "c"] {
            try await cache.store(Data(name.utf8), for: name, kind: .ocr, generation: 0)
        }
        _ = try await cache.data(for: "a", kind: .ocr)
        _ = try await cache.data(for: "b", kind: .ocr)
        try await cache.flushAccesses()
        let reopened = ReaderTranslationDiskCache(directory: root)
        #expect(try await reopened.data(for: "a", kind: .ocr) == Data("a".utf8))
        try await cache.clear()
        try await cache.flushAccesses()
        #expect(try await cache.statistics().entries == 0)
    }
}
