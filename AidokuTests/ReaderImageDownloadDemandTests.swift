import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderImageDownloadDemandTests {
    @Test func actualReaderNetworkLoadTracksPromotionDemotionAndCompletion() async throws {
        let (view, pipeline, admission, url) = makeReader()
        _ = pipeline
        view.imageLoadPriority = .low
        let load = Task { await view.setPage(Page(sourceId: "demand", chapterId: "c", index: 0, imageURL: url.absoluteString)) }
        defer { load.cancel(); view.releasePageResources() }
        try await wait { DemandImageURLProtocol.started(url) }
        #expect(await admission.snapshot.readerDemands == 0)
        view.imageLoadPriority = .high
        try await wait { await admission.snapshot.readerDemands == 1 }
        #expect(await admission.snapshot.limit == 2)
        view.imageLoadPriority = .low
        try await wait { await admission.snapshot.readerDemands == 0 }
        view.imageLoadPriority = .high
        try await wait { await admission.snapshot.readerDemands == 1 }
        DemandImageURLProtocol.complete(url)
        #expect(await load.value)
        #expect(view.imageView.image != nil)
        try await wait { await admission.snapshot.readerDemands == 0 }
        #expect(await admission.snapshot.limit == 5)
    }

    @Test func cancellingActualReaderNetworkLoadReleasesDemand() async throws {
        let (view, _, admission, url) = makeReader()
        view.imageLoadPriority = .high
        let load = Task { await view.setPage(Page(sourceId: "demand", chapterId: "c", index: 0, imageURL: url.absoluteString)) }
        defer { load.cancel(); view.releasePageResources() }
        try await wait { DemandImageURLProtocol.started(url) }
        #expect(await admission.snapshot.readerDemands == 1)
        load.cancel()
        #expect(await load.value == false)
        try await wait { await admission.snapshot.readerDemands == 0 }
        try await wait { DemandImageURLProtocol.stopped(url) }
    }

    @Test func readerNetworkStartsBeforeGraceAndCancellationReleasesUnearnedDemand() async throws {
        // The two-second start deadline is shorter than grace: awaiting grace in
        // ReaderImageDownloadDemand.start would prevent URLProtocol from starting.
        let (view, _, admission, url) = makeReader(demandGraceNanoseconds: 30_000_000_000)
        view.imageLoadPriority = .high
        let load = Task { await view.setPage(Page(sourceId: "demand", chapterId: "c", index: 0, imageURL: url.absoluteString)) }
        defer { load.cancel(); view.releasePageResources() }
        try await wait { DemandImageURLProtocol.started(url) }
        #expect(await admission.snapshot.readerDemands == 1)
        #expect(await admission.snapshot.pendingReaderDemands == 1)
        #expect(await admission.snapshot.eligibleReaderDemands == 0)
        #expect(await admission.snapshot.limit == 5)
        load.cancel()
        #expect(await load.value == false)
        try await wait { await admission.snapshot.readerDemands == 0 }
        #expect(await admission.snapshot.pendingReaderDemands == 0)
        #expect(await admission.snapshot.eligibleReaderDemands == 0)
        #expect(await admission.snapshot.limit == 5)
        try await wait { DemandImageURLProtocol.stopped(url) }
    }

    @Test func cachedReaderImageNeverStartsNetworkOrRetainsDemand() async throws {
        let (view, pipeline, admission, url) = makeReader()
        let request = await ReaderPageView.imageRequest(url: url)
        let image = try #require(UIImage(data: DemandImageURLProtocol.png))
        pipeline.cache.storeCachedImage(ImageContainer(image: image), for: request, caches: [.memory])
        view.imageLoadPriority = .high
        #expect(await view.setPage(Page(sourceId: "demand", chapterId: "c", index: 0, imageURL: url.absoluteString)))
        #expect(!DemandImageURLProtocol.started(url))
        #expect(await admission.snapshot.readerDemands == 0)
        view.releasePageResources()
    }

    @Test(arguments: [false, true])
    func translationDataNetworkDemandIsForegroundOnly(foreground: Bool) async throws {
        let cache = try DataCache(name: "reader-demand-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DemandImageURLProtocol.self]
            $0.dataLoader = DataLoader(configuration: config)
            $0.dataCache = cache
            $0.dataCachePolicy = .storeOriginalData
            $0.imageCache = nil
        }
        // A long grace proves real data transport does not wait for eligibility.
        let admission = BulkDownloadAdmission(demandGraceNanoseconds: 30_000_000_000)
        let loader = ReaderTranslationImageLoader(pipeline: pipeline, downloadAdmission: admission)
        let url = URL(string: "https://reader-image-demand.invalid/\(UUID())")!
        let page = Page(sourceId: "demand", chapterId: "c", index: 0, imageURL: url.absoluteString)
        let load = Task { try await loader.prefetchData(page, priority: foreground ? .high : .veryLow) }
        defer { load.cancel() }
        try await wait { DemandImageURLProtocol.started(url) }
        #expect(await admission.snapshot.readerDemands == (foreground ? 1 : 0))
        #expect(await admission.snapshot.limit == 5)
        load.cancel()
        _ = try? await load.value
        try await wait { await admission.snapshot.readerDemands == 0 }
        try await wait { DemandImageURLProtocol.stopped(url) }
    }

    @Test func originalDiskBytesAvoidDemandEvenWithProcessorKey() async throws {
        let cache = try DataCache(name: "reader-original-demand-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline { $0.dataCache = cache; $0.imageCache = nil; $0.dataCachePolicy = .storeOriginalData }
        let url = URL(string: "https://reader-image-demand.invalid/\(UUID())")!
        let original = ImageRequest(url: url)
        pipeline.cache.storeCachedData(DemandImageURLProtocol.png, for: original)
        var processed = original
        processed.processors = [ImageProcessors.Resize(size: CGSize(width: 10, height: 10))]
        #expect(!ReaderImageDownloadCache.needsNetwork(request: processed, pipeline: pipeline))
        processed.options.insert(.disableDiskCacheReads)
        #expect(ReaderImageDownloadCache.needsNetwork(request: processed, pipeline: pipeline))
    }

    private func makeReader(demandGraceNanoseconds: UInt64 = 0) -> (ReaderPageView, ImagePipeline, BulkDownloadAdmission, URL) {
        let pipeline = ImagePipeline {
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [DemandImageURLProtocol.self]
            $0.dataLoader = DataLoader(configuration: config)
            $0.imageCache = Nuke.ImageCache()
            $0.dataCache = nil
        }
        let admission = BulkDownloadAdmission(demandGraceNanoseconds: demandGraceNanoseconds)
        let view = ReaderPageView(temporaryPageStore: ReaderTemporaryPageStore(), imagePipeline: pipeline, downloadAdmission: admission)
        view.isTranslationPreload = true
        return (view, pipeline, admission, URL(string: "https://reader-image-demand.invalid/\(UUID())")!)
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await predicate())
    }
}

private final class DemandImageURLProtocol: URLProtocol {
    static let png = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private static let lock = NSLock()
    private static var pending: [URL: DemandImageURLProtocol] = [:]
    private static var starts = Set<URL>()
    private static var stops = Set<URL>()
    static func started(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return starts.contains(url) }
    static func stopped(_ url: URL) -> Bool { lock.lock(); defer { lock.unlock() }; return stops.contains(url) }
    static func complete(_ url: URL) {
        lock.lock(); let entry = pending.removeValue(forKey: url); lock.unlock()
        guard let entry else { return }
        entry.client?.urlProtocol(entry, didReceive: HTTPURLResponse(url: url, statusCode: 200,
            httpVersion: nil, headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        entry.client?.urlProtocol(entry, didLoad: png)
        entry.client?.urlProtocolDidFinishLoading(entry)
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.starts.insert(url); Self.pending[url] = self; Self.lock.unlock()
    }
    override func stopLoading() {
        guard let url = request.url else { return }
        Self.lock.lock(); Self.stops.insert(url); Self.pending[url] = nil; Self.lock.unlock()
    }
}
