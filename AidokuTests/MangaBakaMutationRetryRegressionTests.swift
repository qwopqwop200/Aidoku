import Foundation
import XCTest
@testable import Aidoku

/// All provider traffic is intercepted; token defaults are restored byte-for-byte.
final class MangaBakaMutationRetryRegressionTests: XCTestCase {
    func testSuccessfulExpiredTokenMutationIsNotRepeated() async throws {
        try await verify(expired: true, initialStatus: 200, expectedWrites: 1, expectedRefreshes: 0)
    }
    func testNormalMutationPayloadIsUnchanged() async throws {
        try await verify(expired: false, initialStatus: 200, expectedWrites: 1, expectedRefreshes: 0)
    }
    func testAuthenticationFailureStillRefreshesAndRetries() async throws {
        try await verify(expired: false, initialStatus: 401, expectedWrites: 2, expectedRefreshes: 1)
    }
    private func verify(expired: Bool, initialStatus: Int, expectedWrites: Int, expectedRefreshes: Int) async throws {
        let key = "Tracker.mangabaka.oauth"
        let original = UserDefaults.standard.object(forKey: key)
        defer {
            if let original { UserDefaults.standard.set(original, forKey: key) }
            else { UserDefaults.standard.removeObject(forKey: key) }
        }
        XCTAssertTrue(URLProtocol.registerClass(MangaBakaMutationReplay.self))
        defer { URLProtocol.unregisterClass(MangaBakaMutationReplay.self) }
        MangaBakaMutationReplay.state.reset(initialStatus: initialStatus)
        let api = MangaBakaApi()
        await api.oauth.setTokens(.init(tokenType: "Bearer", refreshToken: "round2-refresh-fixture",
            accessToken: "round2-access-fixture", expiresIn: expired ? -1 : 3600))
        try await api.updateLibraryEntry(seriesId: 42, create: true, data: .init(progressChapter: 5))
        let result = MangaBakaMutationReplay.state.snapshot()
        XCTAssertEqual(result.writes, expectedWrites)
        XCTAssertEqual(result.refreshes, expectedRefreshes)
        XCTAssertEqual(result.invalidRequests, 0)
    }
}

private final class MangaBakaMutationReplay: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var initialStatus = 200
        private var writes = 0
        private var refreshes = 0
        private var invalidRequests = 0
        func reset(initialStatus: Int) {
            lock.lock(); defer { lock.unlock() }
            self.initialStatus = initialStatus; writes = 0; refreshes = 0; invalidRequests = 0
        }
        func snapshot() -> (writes: Int, refreshes: Int, invalidRequests: Int) {
            lock.lock(); defer { lock.unlock() }
            return (writes, refreshes, invalidRequests)
        }
        func handle(_ request: URLRequest, body: Data) -> (Int, String) {
            lock.lock(); defer { lock.unlock() }
            if request.url?.standardized.path == "/auth/oauth2/token" {
                refreshes += 1
                let payload = String(decoding: body, as: UTF8.self)
                if request.httpMethod != "POST" || !payload.contains("refresh_token=round2-refresh-fixture") { invalidRequests += 1 }
                return (200, "{\"token_type\":\"Bearer\",\"access_token\":\"round2-refreshed-fixture\",\"refresh_token\":\"round2-refresh-fixture\",\"expires_in\":3600}")
            }
            writes += 1
            let expectedAuthorization = writes == 1 ? "Bearer round2-access-fixture" : "Bearer round2-refreshed-fixture"
            if request.httpMethod != "POST" || request.url?.standardized.path != "/v1/my/library/42" ||
                body != Data("{\"progress_chapter\":5}".utf8) ||
                request.value(forHTTPHeaderField: "Authorization") != expectedAuthorization {
                invalidRequests += 1
                return (422, "{}")
            }
            if writes == 1 { return (initialStatus, "{}") }
            // Successful first POST must never be replayed. A rejected auth request may retry once.
            return (initialStatus == 401 && writes == 2 ? 200 : 409, "{}")
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "api.mangabaka.org" || request.url?.host == "mangabaka.org"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer.prefix(count))
            }
        }
        let (status, text) = Self.state.handle(request, body: body)
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
