import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderImageCacheRecoveryTests {
    @Test(arguments: [false, true])
    func corruptBase64DiskEntryFallsBackToSource(webtoon: Bool) async throws {
        let cache = try DataCache(name: "reader-corrupt-base64-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline { $0.dataCache = cache; $0.imageCache = nil }
        let page = Page(sourceId: "cache-recovery", chapterId: UUID().uuidString, index: 0,
                        base64: RecoveryImageURLProtocol.png.base64EncodedString())
        let crop = UserDefaults.standard.bool(forKey: "Reader.cropBorders")
        let downsample = !webtoon && UserDefaults.standard.bool(forKey: "Reader.downsampleImages")
        let settings = "crop:\(crop)-downsample:\(downsample)"
            + (downsample ? "-width:\(UIScreen.main.bounds.width)" : "")
        let identity = ReaderImageContentIdentity.base64Key(try #require(page.base64), processorSettingsKey: settings)
        let request = ImageRequest(id: identity, data: { Data() })
        pipeline.cache.storeCachedData(Data("broken image".utf8), for: request)
        #expect(pipeline.cache.containsCachedImage(for: request))
        #expect(pipeline.cache.cachedImage(for: request) == nil)
        if webtoon {
            let node = ReaderWebtoonPageNode(source: nil, page: page, temporaryPageStore: ReaderTemporaryPageStore(),
                                            pillarboxLayoutState: ReaderPillarboxLayoutState(), imagePipeline: pipeline)
            await node.loadPage()
            #expect(node.image?.cgImage?.width == 1)
        } else {
            let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore(), imagePipeline: pipeline)
            view.isTranslationPreload = true
            #expect(await view.setPage(page))
            #expect(view.imageView.image?.cgImage?.width == 1)
            view.releasePageResources()
        }
        #expect(pipeline.cache.cachedImage(for: request)?.image.cgImage?.width == 1)
    }

    @Test(arguments: [false, true])
    func base64PagesWithSameChapterAndIndexDoNotReuseOtherContent(webtoon: Bool) async throws {
        let keys = ["Reader.cropBorders", "Reader.downsampleImages"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        for key in keys { UserDefaults.standard.set(false, forKey: key) }
        defer { for (key, value) in zip(keys, saved) { UserDefaults.standard.set(value, forKey: key) } }
        let pipeline = ImagePipeline { $0.dataCache = nil; $0.imageCache = Nuke.ImageCache() }
        for (source, width) in [("source-a", 2), ("source-b", 4), ("source-b", 6)] {
            let format = UIGraphicsImageRendererFormat(); format.scale = 1
            let image = UIGraphicsImageRenderer(size: CGSize(width: CGFloat(width), height: 3), format: format).image { context in
                UIColor.red.setFill(); context.fill(CGRect(x: 0, y: 0, width: CGFloat(width), height: 3))
            }
            let page = Page(sourceId: source, chapterId: "same-chapter", index: 0,
                            base64: try #require(image.pngData()).base64EncodedString())
            if webtoon {
                let node = ReaderWebtoonPageNode(source: nil, page: page, temporaryPageStore: ReaderTemporaryPageStore(),
                                                pillarboxLayoutState: ReaderPillarboxLayoutState(), imagePipeline: pipeline)
                await node.loadPage()
                #expect(node.image?.cgImage?.width == width)
            } else {
                let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore(), imagePipeline: pipeline)
                view.isTranslationPreload = true
                #expect(await view.setPage(page))
                #expect(view.imageView.image?.cgImage?.width == width)
                view.releasePageResources()
            }
        }
    }

    @Test func reloadInvalidatesProcessedAndOriginalKeys() throws {
        let cache = try DataCache(name: "reader-reload-original-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline { $0.dataCache = cache; $0.imageCache = Nuke.ImageCache() }
        let original = ImageRequest(url: URL(string: "https://cache-recovery.invalid/\(UUID())")!)
        var processed = original
        processed.processors = [ImageProcessors.Resize(size: CGSize(width: 10, height: 10))]
        let image = try #require(UIImage(data: RecoveryImageURLProtocol.png))
        pipeline.cache.storeCachedData(RecoveryImageURLProtocol.png, for: original)
        pipeline.cache.storeCachedImage(ImageContainer(image: image), for: processed)
        ReaderImageDownloadCache.removeCachedImageAndOriginal(for: processed, pipeline: pipeline)
        #expect(!pipeline.cache.containsCachedImage(for: original))
        #expect(!pipeline.cache.containsCachedImage(for: processed))
    }

    @Test func pagedReloadFetchesFreshBytesAfterProcessedDiskHit() async throws {
        let defaults = UserDefaults.standard
        let key = "Reader.downsampleImages"
        let saved = defaults.object(forKey: key)
        defaults.set(true, forKey: key)
        defer { defaults.set(saved, forKey: key) }
        let cache = try DataCache(name: "reader-reload-transport-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [RecoveryImageURLProtocol.self]
            $0.dataLoader = DataLoader(configuration: config)
            $0.dataCache = cache
            $0.dataCachePolicy = .storeOriginalData
            $0.imageCache = Nuke.ImageCache()
        }
        let url = URL(string: "https://cache-recovery.invalid/\(UUID())")!
        pipeline.cache.storeCachedData(RecoveryImageURLProtocol.png, for: ImageRequest(url: url))
        let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore(), imagePipeline: pipeline)
        view.isTranslationPreload = true
        defer { view.releasePageResources() }
        #expect(await view.setPage(Page(sourceId: "cache-recovery", chapterId: "c", index: 0, imageURL: url.absoluteString)))
        #expect(RecoveryImageURLProtocol.count(url) == 0)
        #expect(await view.reloadCurrentImage())
        #expect(RecoveryImageURLProtocol.count(url) == 1)
    }
}

private final class RecoveryImageURLProtocol: URLProtocol {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private static let lock = NSLock()
    private static var requests: [URL: Int] = [:]
    static func count(_ url: URL) -> Int { lock.lock(); defer { lock.unlock() }; return requests[url, default: 0] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.requests[url, default: 0] += 1; Self.lock.unlock()
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
