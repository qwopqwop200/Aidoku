import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct MyAnimeListTrackerRegressionTests {
    @Test(arguments: [true, false])
    func searchGetsAllResultMetadataInOneRequest(includeNsfw: Bool) async throws {
        let fixture = await Fixture()
        defer { fixture.clean() }
        let results = try await fixture.tracker.search(title: "two titles", includeNsfw: includeNsfw)

        #expect(results.map(\.id) == ["20", "10"])
        let first = try #require(results.first)
        #expect(first.title == "First")
        #expect(first.coverUrl == "https://fixture.invalid/cover")
        #expect(first.description == "Summary")
        #expect(first.status == .completed)
        #expect(first.type == .manhwa)
        #expect(first.tracked)
        #expect(results.last?.tracked == false)

        let requests = MangaListReplay.recorded.requests
        #expect(requests.count == 1)
        let url = try #require(requests.first?.url)
        #expect(url.path == "/v2/manga")
        #expect(url.queryParameters?["q"] == "two titles")
        #expect(url.queryParameters?["nsfw"] == String(includeNsfw))
        let fields = Set((url.queryParameters?["fields"] ?? "").split(separator: ",").map(String.init))
        #expect(fields == ["id", "title", "main_picture", "synopsis", "status", "media_type", "my_list_status"])
    }

    @Test func registerWritesOnlyAfterConfirmedMissingListStatus() async throws {
        let fixture = await Fixture()
        defer { fixture.clean() }
        // 1 is missing, 2 already has progress. 3–5 fail during the status read.
        for id in 1...5 {
            do {
                _ = try await fixture.tracker.register(trackId: String(id), highestChapterRead: 1, earliestReadDate: nil)
                #expect(id <= 2)
            } catch {
                #expect(id >= 3)
            }
        }
        let requests = MangaListReplay.recorded.requests
        #expect(requests.filter { $0.httpMethod == "GET" }.count == 5)
        #expect(requests.filter { $0.httpMethod == "PATCH" }.compactMap { $0.url?.path } == ["/v2/manga/1/my_list_status"])
    }

    @Test func cancelledRegistrationDoesNotStartARequest() async throws {
        let fixture = await Fixture()
        defer { fixture.clean() }
        let registration = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await fixture.tracker.register(trackId: "1", highestChapterRead: 1, earliestReadDate: nil)
        }
        await #expect(throws: CancellationError.self) { try await registration.value }
        #expect(MangaListReplay.recorded.requests.isEmpty)
    }

    private struct Fixture {
        let tracker: MyAnimeListTracker
        let session: URLSession
        let id = "mal-regression-" + UUID().uuidString

        init() async {
            MangaListReplay.recorded.reset()
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [MangaListReplay.self]
            session = URLSession(configuration: config)
            let oauth = OAuthClient(id: id, clientId: "fixture", baseUrl: "https://fixture.invalid")
            await oauth.setTokens(.init(accessToken: "fixture", expiresIn: 3600))
            tracker = MyAnimeListTracker(api: MyAnimeListApi(oauth: oauth, session: session))
        }

        func clean() {
            session.invalidateAndCancel()
            UserDefaults.standard.removeObject(forKey: "Tracker.\(id).oauth")
        }
    }
}

private final class MangaListReplay: URLProtocol {
    final class Log: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [URLRequest] = []
        var requests: [URLRequest] { lock.withLock { entries } }
        func append(_ request: URLRequest) { lock.withLock { entries.append(request) } }
        func reset() { lock.withLock { entries.removeAll() } }
    }
    static let recorded = Log()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.recorded.append(request)
        guard let url = request.url else { return }
        let body: String
        var status = 200
        switch (request.httpMethod, url.path) {
            case ("GET", "/v2/manga"):
                body = #"""
                {"data":[{"node":{"id":20,"title":"First","main_picture":{"large":"https://fixture.invalid/cover"},
                "synopsis":"Summary","status":"finished","media_type":"manhwa","my_list_status":{"status":"reading"}}},
                {"node":{"id":10,"title":"Second"}}]}
                """#
            case ("GET", "/v2/manga/1"): body = #"{"id":1}"#
            case ("GET", "/v2/manga/2"): body = #"{"id":2,"my_list_status":{"num_chapters_read":25}}"#
            case ("GET", "/v2/manga/3"):
                status = 503
                body = "{}"
            case ("GET", "/v2/manga/4"): body = "invalid"
            case ("GET", "/v2/manga/5"):
                client?.urlProtocol(self, didFailWithError: URLError(.cancelled))
                return
            case ("PATCH", _): body = "{}"
            default:
                status = 404
                body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
