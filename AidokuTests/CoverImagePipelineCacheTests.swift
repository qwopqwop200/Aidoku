import AidokuRunner
import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct CoverImagePipelineCacheTests {
    @Test func interceptedCoverIsSizedBeforeMemoryCacheAndDiskReplay() async throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let original = UIGraphicsImageRenderer(size: CGSize(width: 1200, height: 1800), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1800))
        }
        let loader = CoverCacheFixtureLoader(data: try #require(original.pngData()))
        let cache = try DataCache(name: "cover-pipeline-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline(delegate: CoverCacheFixtureDelegate()) {
            $0.dataLoader = loader
            $0.dataCache = cache
            $0.dataCachePolicy = .storeOriginalData
            $0.imageCache = Nuke.ImageCache()
        }
        let source = AidokuRunner.Source.test(runner: TestableSourceRunner(processesCovers: true))
        let request = ImageRequest(
            urlRequest: URLRequest(url: URL(string: "https://cover-cache.invalid/image")!),
            processors: CoverImageProcessing.processors(source: source, downsampleWidth: 100),
            userInfo: [.processesKey: true]
        )
        let expectedWidth = Int(100 * UIScreen.main.scale)
        let cold = try await pipeline.image(for: request)
        #expect(cold.cgImage?.width == expectedWidth)
        #expect(cold.cgImage?.height == Int(150 * UIScreen.main.scale))
        let warm = try await pipeline.image(for: request)
        #expect(warm.cgImage?.width == expectedWidth)
        #expect(loader.count == 1)
        pipeline.cache.removeAll(caches: .memory)
        let disk = try await pipeline.image(for: request)
        #expect(disk.cgImage?.width == expectedWidth)
        #expect(loader.count == 1)
        let pixels = try #require(disk.cgImage)
        #expect(pixels.width * pixels.height < 1200 * 1800)
    }

    @Test func noDisplaySizeKeepsSourcePixelsAndNoInterceptorKeepsSizing() {
        let source = AidokuRunner.Source.test(runner: TestableSourceRunner(processesCovers: true))
        #expect(CoverImageProcessing.processors(source: source, downsampleWidth: nil).count == 1)
        let plain = CoverImageProcessing.processors(source: nil, downsampleWidth: 100)
        #expect(plain.count == 1)
        #expect(plain.first is DownsampleProcessor)
    }
}

private final class CoverCacheFixtureDelegate: ImagePipeline.Delegate, @unchecked Sendable {
    func imageDecoder(for context: ImageDecodingContext, pipeline: ImagePipeline) -> (any ImageDecoding)? {
        ImageDecoders.Empty()
    }
}

private final class CoverCacheFixtureLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    let data: Data
    var count: Int { lock.lock(); defer { lock.unlock() }; return requests }
    init(data: Data) { self.data = data }
    func loadData(with request: URLRequest,
                  didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        lock.lock(); requests += 1; lock.unlock()
        didReceiveData(data, URLResponse(url: request.url!, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
        completion(nil)
        return CoverCacheFixtureCancellation()
    }
}

private struct CoverCacheFixtureCancellation: Cancellable {
    func cancel() {}
}
