import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderPrefetchDataReuseTests {
    @Test(arguments: [false, true])
    func prefetchOnlyDownloadsWhenTheDiskPolicyCanRetainItsOriginalBytes(encodedOnly: Bool) async throws {
        let cache = try DataCache(name: "prefetch-policy-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PrefetchReuseURLProtocol.self]
            configuration.urlCache = nil
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCache = cache
            $0.dataCachePolicy = encodedOnly ? .storeEncodedImages : .storeOriginalData
            $0.imageCache = ImageCache()
        }
        let loader = ReaderTranslationImageLoader(pipeline: pipeline)
        let url = URL(string: "https://prefetch-reuse.invalid/" + UUID().uuidString)!
        let page = Page(sourceId: "", chapterId: "reuse", index: 0, imageURL: url.absoluteString)
        let request = await ReaderPageView.imageRequest(url: url, sourceKey: page.sourceId)
        try await loader.prefetchData(page)
        #expect(PrefetchReuseURLProtocol.count(url) == (encodedOnly ? 0 : 1))
        #expect(pipeline.cache.cachedImage(for: request, caches: .memory) == nil)
        let image = try await loader.load(page)
        #expect(image.size.width == 1)
        #expect(image.size.height == 1)
        #expect(PrefetchReuseURLProtocol.count(url) == 1,
                "Data warming followed by OCR loading must never download the same page twice")
    }

    @Test func noDiskCacheSkipsNetworkWarmingAndDemandStillLoadsOnce() async throws {
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PrefetchReuseURLProtocol.self]
            configuration.urlCache = nil
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCache = nil
            $0.imageCache = ImageCache()
        }
        let loader = ReaderTranslationImageLoader(pipeline: pipeline)
        let url = URL(string: "https://prefetch-reuse.invalid/" + UUID().uuidString)!
        let page = Page(sourceId: "", chapterId: "reuse", index: 0, imageURL: url.absoluteString)
        try await loader.prefetchData(page)
        #expect(PrefetchReuseURLProtocol.count(url) == 0)
        #expect(try await loader.load(page).size.width == 1)
        #expect(PrefetchReuseURLProtocol.count(url) == 1)
    }
}

private final class PrefetchReuseURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var counts: [URL: Int] = [:]
    private static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    static func count(_ url: URL) -> Int { lock.withLock { counts[url, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "prefetch-reuse.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.withLock { Self.counts[url, default: 0] += 1 }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
