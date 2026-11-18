import AidokuRunner
import ImageIO
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
            UIColor.blue.withAlphaComponent(0.6).setFill()
            context.fill(CGRect(x: 31, y: 47, width: 591, height: 917))
        }
        let loader = CoverCacheFixtureLoader(data: try #require(original.pngData()))
        let cache = try DataCache(name: "cover-pipeline-" + UUID().uuidString)
        defer { cache.removeAll() }
        let memoryCache = Nuke.ImageCache()
        let pipeline = ImagePipeline(delegate: CoverCacheFixtureDelegate()) {
            $0.dataLoader = loader
            $0.dataCache = cache
            $0.dataCachePolicy = .storeOriginalData
            $0.imageCache = memoryCache
        }
        let source = AidokuRunner.Source.test(runner: TestableSourceRunner(processesCovers: true))
        let request = ImageRequest(
            urlRequest: URLRequest(url: URL(string: "https://cover-cache.invalid/image")!),
            processors: CoverImageProcessing.processors(source: source, downsampleWidth: 100),
            userInfo: [.processesKey: true]
        )
        let expectedWidth = Int(100 * UIScreen.main.scale)
        let decoded = try #require(UIImage(data: loader.data))
        let expected = try #require(DownsampleProcessor(width: 100).process(decoded)?.pngData())
        let cold = try await pipeline.image(for: request)
        #expect(cold.cgImage?.width == expectedWidth)
        #expect(cold.cgImage?.height == Int(150 * UIScreen.main.scale))
        #expect(cold.pngData() == expected)
        let entry = try #require(pipeline.cache[request])
        let bitmap = try #require(entry.image.cgImage)
        #expect(entry.data == nil)
        #expect(memoryCache.totalCost == bitmap.bytesPerRow * bitmap.height)
        let warm = try await pipeline.image(for: request)
        #expect(warm.cgImage?.width == expectedWidth)
        #expect(warm === cold)
        var displayed: UIImage?
        let warmTask = CoverImageProcessing.load(request, pipeline: pipeline) { result, cached in
            #expect(cached)
            displayed = try? result.get().image
        }
        #expect(warmTask == nil)
        #expect(displayed === cold)

        var otherScale = request
        otherScale.scale = 2
        #expect(pipeline.cache[otherScale] == nil)
        var narrower = request
        narrower.processors = CoverImageProcessing.processors(source: source, downsampleWidth: 50)
        #expect(pipeline.cache[narrower] == nil)
        pipeline.cache[narrower] = ImageContainer(image: cold, isPreview: true)
        let resized: ImageResponse = try await withCheckedThrowingContinuation { continuation in
            let task = CoverImageProcessing.load(narrower, pipeline: pipeline) { result, cached in
                #expect(cached)
                continuation.resume(with: result)
            }
            #expect(task != nil)
        }
        #expect(resized.image.cgImage?.width == expectedWidth / 2)
        #expect(loader.count == 1)
        cache.flush()
        pipeline.cache.removeAll(caches: .memory)
        var originalRequest = request
        originalRequest.processors = []
        #expect(pipeline.cache.cachedData(for: originalRequest) == loader.data)
        let disk: UIImage = try await withCheckedThrowingContinuation { continuation in
            let task = CoverImageProcessing.load(request, pipeline: pipeline) { result, cached in
                #expect(cached)
                continuation.resume(with: result.map(\.image))
            }
            #expect(task != nil)
        }
        #expect(disk.cgImage?.width == expectedWidth)
        #expect(disk.pngData() == expected)
        #expect(loader.count == 1)
        let pixels = try #require(disk.cgImage)
        #expect(pixels.width * pixels.height < 1200 * 1800)
    }

    @Test(arguments: [AssetType.gif, .png])
    func typedCoverKeepsAllAnimationFramesAfterInterception(type: AssetType) throws {
        let bytes = NSMutableData()
        let destination = try #require(CGImageDestinationCreateWithData(bytes, type.rawValue as CFString, 2, nil))
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        for color in [UIColor.red, .blue] {
            let frame = UIGraphicsImageRenderer(size: CGSize(width: 2, height: 2), format: format).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 2, height: 2))
            }
            CGImageDestinationAddImage(destination, try #require(frame.cgImage), nil)
        }
        #expect(CGImageDestinationFinalize(destination))
        let container = try ImageDecoders.Empty(assetType: type).decode(bytes as Data)
        let request = ImageRequest(urlRequest: .init(url: URL(string: "https://cover-cache.invalid/animated")!), userInfo: [.processesKey: true])
        let context = ImageProcessingContext(request: request, response: .init(container: container, request: request), isCompleted: true)
        let source = AidokuRunner.Source.test(runner: TestableSourceRunner(processesCovers: true))
        let result = try CoverInterceptorProcessor(source: source).process(container, context: context)
        #expect(result.type == type)
        let retained = try #require(result.data)
        #expect(retained == bytes as Data)
        let frames = try #require(CGImageSourceCreateWithData(retained as CFData, nil))
        #expect(CGImageSourceGetCount(frames) == 2)
        #expect(result.image.cgImage?.width == 2)
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
