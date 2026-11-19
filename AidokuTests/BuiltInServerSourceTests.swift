import Foundation
import Testing
import AidokuRunner
@testable import Aidoku

/// Self-hosted server sources (Komga, Kavita, Suwayomi).
struct BuiltInServerSourceTests {
    /// Response bodies from self-hosted servers are capped instead of buffered without limit.
    @Test func komgaOversizeBodyFailsAsNetworkError() async throws {
        let session = StreamedBodyProtocol.session()
        defer { session.invalidateAndCancel() }
        let data = try await KomgaHelper.limitedBody(for: StreamedBodyProtocol.request(bytes: 3000), session: session, maximum: 4096)
        #expect(data.count == 3000)
        await #expect(throws: SourceError.networkError) {
            try await KomgaHelper.limitedBody(for: StreamedBodyProtocol.request(bytes: 64 * 1024), session: session, maximum: 4096)
        }
    }

    @Test func suwayomiOversizeBodyIsRejected() async throws {
        let session = StreamedBodyProtocol.session()
        defer { session.invalidateAndCancel() }
        let (data, _) = try await NativeSourceNetwork.limitedData(for: StreamedBodyProtocol.request(bytes: 4096), session: session, maximum: 4096)
        #expect(data.count == 4096)
        do {
            _ = try await NativeSourceNetwork.limitedData(for: StreamedBodyProtocol.request(bytes: 4097), session: session, maximum: 4096)
            Issue.record("Expected an oversize body to be rejected")
        } catch let error as URLError {
            #expect(error.code == .dataLengthExceedsMaximum)
        }
    }

    @Test(arguments: [Int.min, Int.max])
    func komgaExtremeReleaseYearThrowsInsteadOfCrashing(year: Int) {
        #expect(throws: EncodingError.self) {
            try JSONEncoder().encode(KomgaSearchCondition.releaseDate(year, exclude: false))
        }
    }
}

/// Serves `bytes` bytes (taken from the last path component) in 1 KiB chunks with no
/// Content-Length, so only the streamed byte count can enforce the limit.
private final class StreamedBodyProtocol: URLProtocol, @unchecked Sendable {
    static func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForResource = 5
        config.protocolClasses = [StreamedBodyProtocol.self]
        return URLSession(configuration: config)
    }

    static func request(bytes: Int) -> URLRequest {
        URLRequest(url: URL(string: "https://\(UUID().uuidString).invalid/body/\(bytes)")!)
    }

    override class func canInit(with request: URLRequest) -> Bool { request.url?.host?.hasSuffix(".invalid") == true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let url = request.url, let total = Int(url.lastPathComponent),
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        var remaining = total
        while remaining > 0 {
            let count = min(1024, remaining)
            client?.urlProtocol(self, didLoad: Data(repeating: 0x20, count: count))
            remaining -= count
        }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}
