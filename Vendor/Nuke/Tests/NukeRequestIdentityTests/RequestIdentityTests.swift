import Foundation
import Testing
@testable import Nuke

struct RequestIdentityTests {
    private let url = URL(string: "https://fixture.invalid/image")!
    private func request(_ token: String) -> ImageRequest {
        var request = URLRequest(url: url)
        request.setValue(token, forHTTPHeaderField: "Authorization")
        return ImageRequest(urlRequest: request)
    }

    @Test func plainGETPreservesURLKeyAndHeadersArePrivate() {
        #expect(ImageRequest(urlRequest: URLRequest(url: url)).imageID == url.absoluteString)
        #expect(request("fixture-A").imageID != request("fixture-B").imageID)
        #expect(request("fixture-A").imageID?.contains("fixture-A") == false)
    }

    @Test func headerCaseAndInsertionOrderAreCanonical() {
        var a = URLRequest(url: url), b = URLRequest(url: url)
        a.setValue("A", forHTTPHeaderField: "AUTHORIZATION")
        a.setValue("B", forHTTPHeaderField: "Referer")
        b.setValue("B", forHTTPHeaderField: "referer")
        b.setValue("A", forHTTPHeaderField: "authorization")
        #expect(ImageRequest(urlRequest: a).imageID == ImageRequest(urlRequest: b).imageID)
    }

    @Test func methodBodyAndStreamAreIsolated() {
        var a = URLRequest(url: url)
        let get = ImageRequest(urlRequest: a)
        a.httpMethod = "POST"
        let post = ImageRequest(urlRequest: a)
        #expect(get.imageID != post.imageID)
        a.httpBody = Data("A".utf8)
        let first = ImageRequest(urlRequest: a)
        a.httpBody = Data("B".utf8)
        #expect(first.imageID != ImageRequest(urlRequest: a).imageID)
        a.httpBodyStream = InputStream(data: Data("stream".utf8))
        let stream = ImageRequest(urlRequest: a)
        #expect(stream.imageID != ImageRequest(urlRequest: a).imageID)
        let copied = stream
        #expect(copied.imageID == stream.imageID)
    }

    @Test func legacyUnscopedDiskEntriesAreNotReused() throws {
        let cache = try DataCache(name: "identity-legacy-" + UUID().uuidString)
        defer { cache.removeAll() }
        let pipeline = ImagePipeline { $0.dataCache = cache }
        cache.storeData(Data("old-authenticated-pixels".utf8), for: url.absoluteString)
        let request = ImageRequest(urlRequest: URLRequest(url: url))
        #expect(pipeline.cache.cachedData(for: request) == nil)
        #expect(pipeline.cache.makeDataCacheKey(for: request).hasPrefix("aidoku-image-data-v2-"))
        #expect(pipeline.cache.makeDataCacheKey(for: request) == pipeline.cache.makeDataCacheKey(for: ImageRequest(url: url)))
    }

    @Test func warmDiskDoesNotReturnAnotherAuthorizationBody() async throws {
        let cache = try DataCache(name: "identity-test-" + UUID().uuidString)
        defer { cache.removeAll() }
        let loader = IdentityLoader()
        let pipeline = ImagePipeline { $0.dataLoader = loader; $0.dataCache = cache; $0.dataCachePolicy = .storeOriginalData }
        #expect(try await pipeline.data(for: request("A")).0 == Data("A".utf8))
        #expect(try await pipeline.data(for: request("B")).0 == Data("B".utf8))
        #expect(try await pipeline.data(for: request("A")).0 == Data("A".utf8))
        #expect(loader.count == 2)
        #expect(pipeline.cache.makeImageCacheKey(for: request("A")) != pipeline.cache.makeImageCacheKey(for: request("B")))
    }

    @Test(arguments: [false, true])
    func concurrentDifferentRequestsStayIsolated(customID: Bool) async throws {
        let loader = IdentityLoader()
        let pipeline = ImagePipeline { $0.dataLoader = loader; $0.imageCache = nil }
        var a = request("A"), b = request("B")
        if customID { a.imageID = "custom-A"; b.imageID = "custom-B" }
        let requestA = a, requestB = b
        async let first = pipeline.data(for: requestA).0
        async let second = pipeline.data(for: requestB).0
        let values = try await (first, second)
        #expect(values.0 == Data("A".utf8))
        #expect(values.1 == Data("B".utf8))
        #expect(loader.count == 2)
    }

    @Test func matchingRequestsShareTransportAndOneCancellationDoesNotKillOther() async throws {
        let loader = IdentityLoader()
        let pipeline = ImagePipeline { $0.dataLoader = loader; $0.imageCache = nil }
        let a = request("A")
        let first = Task { try await pipeline.data(for: a).0 }
        let second = Task { try await pipeline.data(for: a).0 }
        while loader.count == 0 { try await Task.sleep(for: .milliseconds(1)) }
        try await Task.sleep(for: .milliseconds(20))
        first.cancel()
        #expect(try await second.value == Data("A".utf8))
        #expect(loader.count == 1)
        _ = try? await first.value
    }
}

private final class IdentityLoader: DataLoading, @unchecked Sendable {
    private let lock = NSLock()
    private var requests = 0
    var count: Int { lock.withLock { requests } }
    func loadData(with request: URLRequest, didReceiveData: @escaping @Sendable (Data, URLResponse) -> Void,
                  completion: @escaping @Sendable (Error?) -> Void) -> any Cancellable {
        lock.withLock { requests += 1 }
        let task = Task {
            do { try await Task.sleep(for: .milliseconds(150)) }
            catch { completion(error); return }
            let data = Data((request.value(forHTTPHeaderField: "Authorization") ?? "none").utf8)
            didReceiveData(data, URLResponse(url: request.url!, mimeType: "image/png", expectedContentLength: data.count, textEncodingName: nil))
            completion(nil)
        }
        return IdentityCancellation(task: task)
    }
}
private struct IdentityCancellation: Cancellable {
    let task: Task<Void, Never>
    func cancel() { task.cancel() }
}
