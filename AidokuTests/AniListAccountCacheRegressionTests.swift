import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct AniListAccountCacheRegressionTests {
    @Test func scoreFormatCacheFollowsAccountAndReusesSameAccountResponse() async throws {
        let fixture = Fixture()
        defer { fixture.clean() }
        await fixture.oauth.setTokens(.init(accessToken: "account-a"))
        #expect(await fixture.api.getStoreType() == "POINT_100")
        #expect(await fixture.api.getStoreType() == "POINT_100")
        #expect(AniListCacheProtocol.state.requestCount == 1)
        await fixture.oauth.setTokens(.init(accessToken: "account-b"))
        #expect(await fixture.api.getStoreType() == "POINT_3")
        #expect(await fixture.api.getStoreType() == "POINT_3")
        #expect(AniListCacheProtocol.state.requestCount == 2)
    }

    @Test func oldAccountResponseCannotReplaceNewAccountCache() async throws {
        let fixture = Fixture(holdFirst: true)
        defer { fixture.clean() }
        await fixture.oauth.setTokens(.init(accessToken: "account-a"))
        let old = Task { await fixture.api.getStoreType() }
        defer { old.cancel(); AniListCacheProtocol.state.release() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while AniListCacheProtocol.state.requestCount == 0 {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
        await fixture.oauth.setTokens(.init(accessToken: "account-b"))
        #expect(await fixture.api.getStoreType() == "POINT_3")
        AniListCacheProtocol.state.release()
        #expect(await old.value == "POINT_10")
        #expect(await fixture.api.getStoreType() == "POINT_3")
        #expect(AniListCacheProtocol.state.requestCount == 2)
    }

    private struct Fixture {
        let id = "anilist-cache-test-" + UUID().uuidString
        let oauth: OAuthClient
        let session: URLSession
        let api: AniListApi
        init(holdFirst: Bool = false) {
            AniListCacheProtocol.state.reset(holdFirst: holdFirst)
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AniListCacheProtocol.self]
            session = URLSession(configuration: configuration)
            oauth = OAuthClient(id: id, clientId: "fixture", baseUrl: "https://fixture.invalid")
            api = AniListApi(oauth: oauth, session: session)
        }
        func clean() {
            AniListCacheProtocol.state.release()
            session.invalidateAndCancel()
            for suffix in ["oauth", "token", "user_id"] {
                UserDefaults.standard.removeObject(forKey: "Tracker.\(id).\(suffix)")
            }
        }
    }
}

private final class AniListCacheProtocol: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        private var holdFirst = false
        private var held: (() -> Void)?
        var requestCount: Int { lock.lock(); defer { lock.unlock() }; return count }
        func reset(holdFirst: Bool) { lock.lock(); defer { lock.unlock() }; count = 0; self.holdFirst = holdFirst; held = nil }
        func schedule(_ response: @escaping () -> Void) {
            lock.lock()
            count += 1
            let shouldHold = holdFirst && count == 1
            if shouldHold { held = response }
            lock.unlock()
            if !shouldHold { response() }
        }
        func release() {
            lock.lock()
            let response = held
            held = nil
            lock.unlock()
            response?()
        }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "graphql.anilist.co" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.schedule { [self] in
            guard let url = request.url else { return }
            let format = request.value(forHTTPHeaderField: "Authorization") == "Bearer account-a" ? "POINT_100" : "POINT_3"
            let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil,
                                           headerFields: ["Content-Type": "application/json"])!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data("{\"data\":{\"Viewer\":{\"mediaListOptions\":{\"scoreFormat\":\"\(format)\"}}}}".utf8))
            client?.urlProtocolDidFinishLoading(self)
        }
    }
    override func stopLoading() {}
}
