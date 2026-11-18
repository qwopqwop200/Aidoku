import AidokuRunner
import Foundation
import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderPrefetchDataReuseTests {
    enum HandoffScenario: CaseIterable { case unchanged, changedCredential, changedCookie, changedContext, changedSource, changedProcessors, evicted, newWork, discarded, cancelledWarm }

    @Test(arguments: HandoffScenario.allCases)
    func signedResolverRunsOncePerWorkAndResolvesFreshOnInvalidation(_ scenario: HandoffScenario) async throws {
        let defaults = UserDefaults.standard
        let keys = ["Reader.cropBorders", "Reader.downsampleImages"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        for key in keys { defaults.set(false, forKey: key) }
        let fixture = ReaderRequestFixture(holdFirstTransfer: scenario == .cancelledWarm)
        let cache = PrefetchCountingDataCache()
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PrefetchReuseURLProtocol.self]
            configuration.urlCache = nil
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCache = cache
            $0.dataCachePolicy = .storeOriginalData
            $0.imageCache = ImageCache()
        }
        let sourceKey = "fixture." + UUID().uuidString
        let runner = EHentaiSourceRunner(sourceKey: sourceKey, fetch: { try await fixture.fetch($0) },
                                         preference: { fixture.preference($0) })
        let source = AidokuRunner.Source(key: sourceKey, name: "Fixture", version: 1, contentRating: .safe, runner: runner)
        let installation = ReaderRequestFixture.Installation(source)
        let loader = ReaderTranslationImageLoader(pipeline: pipeline, sourceLookup: { _ in await installation.source })
        let handoff = ReaderTranslationImageRequestHandoff()
        let viewer = "https://e-hentai.org/s/key/123-1"
        var page = Page(sourceId: sourceKey, chapterId: "fixture", index: 1, imageURL: viewer,
                        context: ["mode": "mpv", "gid": "123", "imgkey": "key", "mpvkey": "scope", "page": "1"])
        let originalPage = page
        let warming = Task { try await loader.prefetchData(originalPage, handoff: handoff) }
        defer { warming.cancel() }
        try await fixture.transport.waitForResolution()
        try await loader.promote(handoff)
        await fixture.transport.resume()
        if scenario == .cancelledWarm {
            let deadline = ContinuousClock.now + .seconds(5)
            while PrefetchReuseURLProtocol.count(fixture.signedURL(1)) == 0 {
                if ContinuousClock.now >= deadline { throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(2))
            }
            warming.cancel()
            do {
                try await warming.value
                Issue.record("Cancelled prefetch completed successfully")
            } catch ImagePipeline.Error.cancelled { }
            catch is CancellationError { }
        } else {
            try await warming.value
        }

        let cookie = try #require(HTTPCookie(properties: [.domain: "prefetch-reuse.invalid", .path: "/",
                                                          .name: sourceKey, .value: "changed"]))
        defer { if scenario == .changedCookie { HTTPCookieStorage.shared.deleteCookie(cookie) } }
        switch scenario {
        case .changedCredential: fixture.changeAccount()
        case .changedCookie: HTTPCookieStorage.shared.setCookie(cookie)
        case .changedContext: page.context?["page"] = "2"
        case .changedSource:
            await installation.replace(with: AidokuRunner.Source(key: sourceKey, name: "Replacement", version: 2,
                                                                 contentRating: .safe, runner: runner))
        case .changedProcessors: defaults.set(true, forKey: "Reader.cropBorders")
        case .evicted: cache.removeAll()
        case .discarded: handoff.discard()
        case .newWork, .unchanged, .cancelledWarm: break
        }
        let activeWork = scenario == .newWork ? ReaderTranslationImageRequestHandoff() : handoff
        let image = try await loader.load(page, handoff: activeWork)
        let resolutions = await fixture.transport.count
        #expect(resolutions == (scenario == .unchanged ? 1 : 2))
        #expect(PrefetchReuseURLProtocol.count(fixture.signedURL(1)) == 1)
        #expect(PrefetchReuseURLProtocol.count(fixture.signedURL(2)) == (scenario == .unchanged ? 0 : 1))
        // Even the same work must resolve again once its warmed request was consumed.
        let fresh = try await loader.load(page, handoff: activeWork)
        #expect(await fixture.transport.count == resolutions + 1)
        let pixels = try #require(image.pngData())
        #expect(pixels == fresh.pngData())
        if scenario == .changedContext || scenario == .changedCredential {
            #expect(pixels != UIImage(data: PrefetchReuseURLProtocol.png)?.pngData())
        }
    }

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

    @Test(arguments: [false, true])
    func diskHitWarmingDoesNotReadBytesAndEvictedDemandStillLoadsOnce(processed: Bool) async throws {
        let defaults = UserDefaults.standard
        let keys = ["Reader.cropBorders", "Reader.downsampleImages"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defer { for (key, value) in zip(keys, saved) { defaults.set(value, forKey: key) } }
        defaults.set(processed, forKey: "Reader.cropBorders")
        defaults.set(false, forKey: "Reader.downsampleImages")
        let cache = PrefetchCountingDataCache()
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [PrefetchReuseURLProtocol.self]
            configuration.urlCache = nil
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.dataCache = cache
            $0.dataCachePolicy = .storeOriginalData
            $0.imageCache = ImageCache()
        }
        let loader = ReaderTranslationImageLoader(pipeline: pipeline)
        let url = URL(string: "https://prefetch-reuse.invalid/" + UUID().uuidString)!
        let page = Page(sourceId: "", chapterId: "reuse", index: 0, imageURL: url.absoluteString)
        var original = await ReaderPageView.imageRequest(url: url, sourceKey: page.sourceId)
        #expect(original.processors.isEmpty == !processed)
        original.processors = []
        original.thumbnail = nil
        pipeline.cache.storeCachedData(PrefetchReuseURLProtocol.png, for: original)
        try await loader.prefetchData(page, priority: .high)
        #expect(cache.readCount == 0, "A warm disk entry needs only a presence check, not a full compressed-data read")
        #expect(PrefetchReuseURLProtocol.count(url) == 0)
        cache.removeAll()
        #expect(try await loader.load(page).size.width == 1)
        #expect(PrefetchReuseURLProtocol.count(url) == 1, "Eviction after warming must fall back to the normal download")
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
    static let png = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    private static let alternatePNG = Data(base64Encoded:
        "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4X6AAAAQBAZAAEMEGAAAAAElFTkSuQmCC")!
    static func count(_ url: URL) -> Int { lock.withLock { counts[url, default: 0] } }
    override class func canInit(with request: URLRequest) -> Bool { ["http", "https"].contains(request.url?.scheme ?? "") }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url, url.host == "prefetch-reuse.invalid" else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        Self.lock.withLock { Self.counts[url, default: 0] += 1 }
        if URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "wait", value: "1")) == true { return }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                       headerFields: ["Content-Type": "image/png"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let changed = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.contains(URLQueryItem(name: "page", value: "changed")) == true
        client?.urlProtocol(self, didLoad: changed ? Self.alternatePNG : Self.png)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class PrefetchCountingDataCache: DataCaching, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: Data] = [:]
    private var reads = 0
    var readCount: Int { lock.withLock { reads } }
    func cachedData(for key: String) -> Data? {
        lock.withLock { reads += 1; return values[key] }
    }
    func containsData(for key: String) -> Bool { lock.withLock { values[key] != nil } }
    func storeData(_ data: Data, for key: String) { lock.withLock { values[key] = data } }
    func removeData(for key: String) { _ = lock.withLock { values.removeValue(forKey: key) } }
    func removeAll() { lock.withLock { values.removeAll() } }
}


private final class ReaderRequestFixture: @unchecked Sendable {
    let transport = Transport()
    private let id = UUID().uuidString.replacingOccurrences(of: "509", with: "50a")
    private let lock = NSLock()
    private var account = "first"
    private var resolvedURLs: [Int: URL] = [:]
    private let holdFirstTransfer: Bool

    init(holdFirstTransfer: Bool) { self.holdFirstTransfer = holdFirstTransfer }

    actor Installation {
        private(set) var source: AidokuRunner.Source
        init(_ source: AidokuRunner.Source) { self.source = source }
        func replace(with source: AidokuRunner.Source) { self.source = source }
    }

    func changeAccount() { lock.withLock { account = "second" } }
    func preference(_ key: String) -> String? { key == "ipb_member_id" ? lock.withLock { account } : nil }
    func signedURL(_ signature: Int) -> URL {
        lock.withLock { resolvedURLs[signature] ?? URL(string: "https://prefetch-reuse.invalid/\(id)?signature=\(signature)")! }
    }

    func fetch(_ request: URLRequest) async throws -> (Data, URLResponse) {
        #expect(request.httpMethod == "POST")
        let ordinal = await transport.resolve()
        let payload = try #require(request.httpBody)
        let body = try #require(try JSONSerialization.jsonObject(with: payload) as? [String: Any])
        let changed = body["page"] as? Int == 2 || request.value(forHTTPHeaderField: "Cookie")?.contains("ipb_member_id=second") == true
        var components = URLComponents(string: "https://prefetch-reuse.invalid/\(id)")!
        components.queryItems = [URLQueryItem(name: "signature", value: String(ordinal))]
        if changed { components.queryItems?.append(URLQueryItem(name: "page", value: "changed")) }
        if holdFirstTransfer, ordinal == 1 { components.queryItems?.append(URLQueryItem(name: "wait", value: "1")) }
        let url = try #require(components.url)
        lock.withLock { resolvedURLs[ordinal] = url }
        let data = try JSONSerialization.data(withJSONObject: ["i": url.absoluteString])
        return (data, HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    actor Transport {
        private(set) var count = 0
        private var blocked: CheckedContinuation<Void, Never>?
        private var released = false

        func waitForResolution() async throws {
            let deadline = ContinuousClock.now + .seconds(5)
            while blocked == nil {
                if ContinuousClock.now >= deadline { resume(); throw URLError(.timedOut) }
                try await Task.sleep(for: .milliseconds(2))
            }
        }
        func resume() { released = true; blocked?.resume(); blocked = nil }
        func resolve() async -> Int {
            count += 1
            let ordinal = count
            if ordinal == 1, !released {
                await withCheckedContinuation { blocked = $0 }
            }
            return ordinal
        }
    }
}
