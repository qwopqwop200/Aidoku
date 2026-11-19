import Foundation
import Testing
@testable import Aidoku

struct SourceResponseBodyTests {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 5
        config.protocolClasses = [BodyProtocol.self]
        return URLSession(configuration: config)
    }

    private func request(_ path: String) -> URLRequest {
        var request = URLRequest(url: URL(string: "https://\(UUID().uuidString).invalid/\(path)")!)
        request.setValue("fixture-token", forHTTPHeaderField: "Authorization")
        return request
    }

    @Test func acceptsBodyAtExactLimit() async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = request("exact")
        let (data, response) = try await SourceResponseBody.read(request, session: session) { _ in .limited(8192) }
        #expect(data == Data(repeating: 1, count: 4096) + Data(repeating: 2, count: 4096))
        let http = try #require(response as? HTTPURLResponse)
        #expect(http.statusCode == 200)
        #expect(http.value(forHTTPHeaderField: "X-Request-Auth") == "fixture-token")
    }

    @Test(arguments: ["declared", "chunked"])
    func stopsOversizeBodiesWithoutWaitingForEndOfResponse(path: String) async throws {
        let session = session()
        defer { session.invalidateAndCancel() }
        let request = request(path)
        do {
            _ = try await SourceResponseBody.read(request, session: session) { _ in .limited(8192) }
            Issue.record("Expected size rejection")
        } catch let error as SourceResponseBody.TooLarge {
            let http = try #require(error.response as? HTTPURLResponse)
            #expect(http.value(forHTTPHeaderField: "X-Request-Auth") == "fixture-token")
        }
        try await waitUntil { BodyProtocol.observation.stopped(request.url!) }
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while !condition() {
            guard Date() < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
    }
}

private final class BodyProtocol: URLProtocol, @unchecked Sendable {
    final class Observation: @unchecked Sendable {
        private let lock = NSLock()
        private var stops = Set<URL>()
        func stop(_ url: URL) { _ = lock.withLock { stops.insert(url) } }
        func stopped(_ url: URL) -> Bool { lock.withLock { stops.contains(url) } }
    }
    static let observation = Observation()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let path = url.lastPathComponent
        var headers = ["X-Request-Auth": request.value(forHTTPHeaderField: "Authorization") ?? "",
                       "Content-Type": "application/json"]
        if path == "declared" { headers["Content-Length"] = "1073741824" }
        let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: headers)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if path == "exact" || path == "chunked" {
            client?.urlProtocol(self, didLoad: Data(repeating: 1, count: 4096))
            client?.urlProtocol(self, didLoad: Data(repeating: 2, count: path == "chunked" ? 131072 : 4096))
        }
        if path == "declared" { client?.urlProtocol(self, didLoad: Data(repeating: 0, count: 131072)) }
        if path == "exact" { client?.urlProtocolDidFinishLoading(self) }
    }
    override func stopLoading() { if let url = request.url { Self.observation.stop(url) } }
}
