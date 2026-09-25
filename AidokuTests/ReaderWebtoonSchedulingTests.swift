import AidokuRunner
import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderWebtoonSchedulingTests {
    @Test func leavingPreloadRangeDoesNotStartLateSourceRequest() async throws {
        let runner = SuspendedWebtoonRequestRunner()
        let source = AidokuRunner.Source(url: nil, key: "webtoon-scheduling", name: "Test", version: 1,
                                         languages: ["multi"], contentRating: .safe, runner: runner)
        let pipeline = ImagePipeline {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [WebtoonSchedulingURLProtocol.self]
            $0.dataLoader = DataLoader(configuration: configuration)
            $0.imageCache = nil
            $0.dataCache = nil
        }
        let url = URL(string: "https://webtoon-scheduling.invalid/\(UUID().uuidString)")!
        let node = ReaderWebtoonPageNode(source: source,
            page: Page(sourceId: source.key, chapterId: "chapter", index: 0, imageURL: url.absoluteString),
            temporaryPageStore: ReaderTemporaryPageStore(), pillarboxLayoutState: ReaderPillarboxLayoutState(),
            imagePipeline: pipeline)
        node.didEnterPreloadState()
        for _ in 0..<200 {
            if await runner.isWaiting { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(await runner.isWaiting)
        node.didExitPreloadState()
        await runner.release()
        // Give a wrongly enqueued request ample time to reach the local protocol.
        try await Task.sleep(for: .milliseconds(150))
        #expect(WebtoonSchedulingURLProtocol.count(url) == 0)
        #expect(node.image == nil)

        // Returning must still enqueue a fresh request and display the image.
        node.didEnterPreloadState()
        for _ in 0..<200 {
            if node.image != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(WebtoonSchedulingURLProtocol.count(url) == 1)
        #expect(node.image != nil)
        node.didExitPreloadState()
    }
}

private actor SuspendedWebtoonRequestRunner: AidokuRunner.Runner {
    nonisolated let features = AidokuRunner.SourceFeatures(providesImageRequests: true)
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    var isWaiting: Bool { continuation != nil }

    func release() {
        released = true
        continuation?.resume()
        continuation = nil
    }

    func getImageRequest(url: String, context: PageContext?) async throws -> URLRequest {
        if !released { await withCheckedContinuation { continuation = $0 } }
        var request = URLRequest(url: URL(string: url)!)
        request.setValue("WebtoonSchedulingTest", forHTTPHeaderField: "User-Agent")
        return request
    }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga {
        manga
    }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] { [] }
}

private final class WebtoonSchedulingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var counts: [URL: Int] = [:]
    static func count(_ url: URL) -> Int {
        lock.lock()
        defer { lock.unlock() }
        return counts[url, default: 0]
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        Self.lock.lock()
        Self.counts[url, default: 0] += 1
        Self.lock.unlock()
        let data = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": "image/png"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
