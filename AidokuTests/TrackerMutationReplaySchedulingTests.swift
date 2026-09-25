import Foundation
import XCTest
@testable import Aidoku

final class TrackerMutationReplaySchedulingTests: XCTestCase {
    func testSuccessfulExpiredMutationsAreSentOnce() async throws {
        for service in ["myanimelist", "shikimori", "bangumi"] {
            try await verify(service: service, initialStatus: 200)
        }
    }

    func testAuthenticationFailureRefreshesExactlyOnceThenRetries() async throws {
        for service in ["myanimelist", "shikimori", "bangumi"] {
            try await verify(service: service, initialStatus: 401)
        }
    }

    func testRequestIssuedForOldAccountIsRejectedBeforeTransport() async throws {
        let key = "Tracker.shikimori.oauth"
        let original = UserDefaults.standard.object(forKey: key)
        defer { restore(original, key: key) }
        XCTAssertTrue(URLProtocol.registerClass(TrackerSchedulingProtocol.self))
        defer { URLProtocol.unregisterClass(TrackerSchedulingProtocol.self) }
        TrackerSchedulingProtocol.state.reset(status: 200)
        let api = ShikimoriApi()
        await api.oauth.setTokens(.init(tokenType: "Bearer", refreshToken: "old-refresh", accessToken: "old", expiresIn: 3600))
        var request = await api.oauth.authorizedRequest(for: URL(string: "https://shikimori.io/api/v2/user_rates/42")!)
        request.httpMethod = "PATCH"
        await api.oauth.setTokens(.init(tokenType: "Bearer", refreshToken: "other-refresh", accessToken: "other", expiresIn: 3600))
        do { _ = try await api.requestData(urlRequest: request); XCTFail("Expected stale account rejection") }
        catch is CancellationError {} catch { throw error }
        XCTAssertEqual(TrackerSchedulingProtocol.state.snapshot().writes, 0)
    }

    private func verify(service: String, initialStatus: Int) async throws {
        let key = "Tracker.\(service).oauth"
        let original = UserDefaults.standard.object(forKey: key)
        defer { restore(original, key: key) }
        XCTAssertTrue(URLProtocol.registerClass(TrackerSchedulingProtocol.self))
        defer { URLProtocol.unregisterClass(TrackerSchedulingProtocol.self) }
        TrackerSchedulingProtocol.state.reset(status: initialStatus)
        let old = OAuthResponse(tokenType: "Bearer", refreshToken: "refresh", accessToken: "old", expiresIn: -1)
        if service == "myanimelist" {
            let api = MyAnimeListApi()
            await api.oauth.setTokens(old)
            try await api.updateMangaStatus(id: 42, status: .init(numChaptersRead: 5))
        } else if service == "shikimori" {
            let api = ShikimoriApi()
            await api.oauth.setTokens(old)
            try await api.update(trackId: "42", update: .init(lastReadChapter: 5))
        } else {
            let api = BangumiApi()
            await api.oauth.setTokens(old)
            let success = await api.update(subject: 42, update: .init(lastReadChapter: 5))
            XCTAssertTrue(success)
        }
        let snapshot = TrackerSchedulingProtocol.state.snapshot()
        XCTAssertEqual(snapshot.writes, initialStatus == 401 ? 2 : 1, service)
        XCTAssertEqual(snapshot.refreshes, initialStatus == 401 ? 1 : 0, service)
        XCTAssertEqual(snapshot.wrongAuthorization, 0, service)
    }

    private func restore(_ original: Any?, key: String) {
        if let original { UserDefaults.standard.set(original, forKey: key) }
        else { UserDefaults.standard.removeObject(forKey: key) }
    }
}

private final class TrackerSchedulingProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 200
        private var writes = 0
        private var refreshes = 0
        private var wrongAuthorization = 0
        func reset(status: Int) { lock.lock(); defer { lock.unlock() }; self.status = status; writes = 0; refreshes = 0; wrongAuthorization = 0 }
        func snapshot() -> (writes: Int, refreshes: Int, wrongAuthorization: Int) {
            lock.lock(); defer { lock.unlock() }; return (writes, refreshes, wrongAuthorization)
        }
        func respond(_ request: URLRequest) -> (Int, String) {
            lock.lock(); defer { lock.unlock() }
            if request.url?.path.contains("token") == true {
                refreshes += 1
                return (200, "{\"access_token\":\"new\",\"refresh_token\":\"refresh-new\",\"token_type\":\"Bearer\",\"expires_in\":3600}")
            }
            writes += 1
            if request.value(forHTTPHeaderField: "Authorization") != (writes == 1 ? "Bearer old" : "Bearer new") { wrongAuthorization += 1 }
            return (writes == 1 ? status : 200, "{}")
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool {
        ["api.myanimelist.net", "myanimelist.net", "shikimori.io", "api.bgm.tv", "bgm.tv"].contains(request.url?.host ?? "")
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let (status, body) = Self.state.respond(request)
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json"])!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
