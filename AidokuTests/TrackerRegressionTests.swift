import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// All provider traffic is intercepted locally; tracker token defaults are restored.
@Suite(.serialized)
struct TrackerRegressionTests {
    // MARK: OAuth credentials

    @Test func oauthResponseReadsServerUnixCreatedAt() throws {
        // Doorkeeper (Shikimori) sends Unix seconds; the default Date decoding read them
        // as reference-date seconds, putting expiry ~31 years in the future.
        let issued = Date().timeIntervalSince1970 - 7200
        let json = #"{"access_token":"a","expires_in":3600,"created_at":\#(Int(issued))}"#
        let response = try JSONDecoder().decode(OAuthResponse.self, from: Data(json.utf8))
        #expect(abs(response.createdAt.timeIntervalSince1970 - issued) < 1)
        #expect(response.expired)
    }

    @Test func persistedOAuthTokenKeepsOriginalExpiration() throws {
        let original = OAuthResponse(accessToken: "test", expiresIn: 60, createdAt: Date(timeIntervalSince1970: 100))
        let restored = try JSONDecoder().decode(OAuthResponse.self, from: JSONEncoder().encode(original))
        #expect(restored.createdAt == original.createdAt)
        #expect(restored.expired)
    }

    @Test func clearingOAuthTokensClearsInMemoryAuthorization() async {
        let id = "test-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "Tracker.\(id).oauth") }
        let client = OAuthClient(id: id, clientId: "test", baseUrl: "https://example.invalid")
        await client.setTokens(OAuthResponse(accessToken: "old-account"))
        await client.setTokens(nil)
        let request = await client.authorizedRequest(for: URL(string: "https://example.invalid")!)
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer ")
    }

    @Test func lateRefreshCannotRestoreLoggedOutCredentials() async throws {
        let id = "test-oauth-" + UUID().uuidString
        defer {
            for suffix in ["oauth", "token", "user_id"] {
                UserDefaults.standard.removeObject(forKey: "Tracker.\(id).\(suffix)")
            }
        }
        let client = OAuthClient(id: id, clientId: "fixture", baseUrl: "https://fixture.invalid")
        await client.setTokens(.init(tokenType: "Bearer", refreshToken: "refresh-old", accessToken: "old", expiresIn: 3600))
        let oldRequest = await client.authorizedRequest(for: URL(string: "https://fixture.invalid/data")!)
        let barrier = OAuthRefreshBarrier()
        let task = Task { await client.refreshTokens(for: oldRequest) { await barrier.run($0) } }
        try await RegressionTestWait.until { await barrier.started }
        await client.setTokens(nil)
        await barrier.release(.init(tokenType: "Bearer", refreshToken: "refresh-new", accessToken: "new", expiresIn: 3600))
        #expect(await task.value == nil)
        #expect(await client.tokens == nil)
    }

    // MARK: Remote writes

    /// A successful write with an expired token must not be replayed; a 401 refreshes once and retries once.
    @Test(arguments: [200, 401])
    func trackerMutationIsSentOnceAndAuthFailureRetriesOnce(initialStatus: Int) async throws {
        for service in ["myanimelist", "shikimori", "bangumi"] {
            let key = "Tracker.\(service).oauth"
            let original = UserDefaults.standard.object(forKey: key)
            defer {
                if let original { UserDefaults.standard.set(original, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            #expect(URLProtocol.registerClass(TrackerMutationReplay.self))
            defer { URLProtocol.unregisterClass(TrackerMutationReplay.self) }
            TrackerMutationReplay.state.reset(status: initialStatus)
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
                #expect(await api.update(subject: 42, update: .init(lastReadChapter: 5)))
            }
            let snapshot = TrackerMutationReplay.state.snapshot()
            #expect(snapshot.writes == (initialStatus == 401 ? 2 : 1), "\(service)")
            #expect(snapshot.refreshes == (initialStatus == 401 ? 1 : 0), "\(service)")
            #expect(snapshot.wrongAuthorization == 0, "\(service)")
        }
    }

    /// Registration must not overwrite existing remote progress, nor write after a failed status read.
    @Test func myAnimeListRegisterWritesOnlyAfterConfirmedMissingListStatus() async throws {
        MALRegistrationReplay.recorded.reset()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MALRegistrationReplay.self]
        let session = URLSession(configuration: configuration)
        let clientId = "mal-regression-" + UUID().uuidString
        defer {
            session.invalidateAndCancel()
            UserDefaults.standard.removeObject(forKey: "Tracker.\(clientId).oauth")
        }
        let oauth = OAuthClient(id: clientId, clientId: "fixture", baseUrl: "https://fixture.invalid")
        await oauth.setTokens(.init(accessToken: "fixture", expiresIn: 3600))
        let tracker = MyAnimeListTracker(api: MyAnimeListApi(oauth: oauth, session: session))
        // 1 is missing, 2 already has progress, 3 fails during the status read.
        for trackId in 1...3 {
            do {
                _ = try await tracker.register(trackId: String(trackId), highestChapterRead: 1, earliestReadDate: nil)
                #expect(trackId <= 2)
            } catch {
                #expect(trackId == 3)
            }
        }
        let requests = MALRegistrationReplay.recorded.requests
        #expect(requests.filter { $0.httpMethod == "GET" }.count == 3)
        #expect(requests.filter { $0.httpMethod == "PATCH" }.compactMap { $0.url?.path } == ["/v2/manga/1/my_list_status"])
    }

    @Test func mangaBakaFinishDateDoesNotOverwriteStartDate() throws {
        let entry = MangaBakaLibraryEntry(startDate: "2025-01-02", finishDate: "2026-03-04")
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        #expect(object["start_date"] as? String == "2025-01-02")
        #expect(object["finish_date"] as? String == "2026-03-04")
    }

    @Test func untrustedTrackingNumbersDoNotTrap() async {
        for value in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            #expect(TrackerManager.wholeTrackingNumber(value) == nil)
            await TrackerManager.shared.setCompleted(
                mangaId: .init(sourceKey: "audit-invalid-metadata", mangaKey: UUID().uuidString),
                chapter: .init(key: "invalid", volumeNumber: value)
            )
        }
        #expect(TrackerManager.wholeTrackingNumber(123.75) == 123)
    }

    // MARK: Page tracker history sync

    /// An undated remote response that arrives after newer local reading must not overwrite it.
    @Test(arguments: [false, true])
    func heldUndatedResponsePreservesNewLocalReading(completed: Bool) async throws {
        let fixture = PageTrackingFixture()
        try await fixture.prepare()
        await fixture.writeHistory(page: 1, completed: false, date: Date(timeIntervalSince1970: 100))
        let sync = Task {
            await fixture.manager.syncPageTrackerHistory(tracker: fixture.tracker, manga: fixture.manga, chapters: fixture.chapters)
        }
        try await RegressionTestWait.until { await fixture.tracker.readStarted }
        await fixture.writeHistory(page: 20, completed: completed, date: Date(timeIntervalSince1970: 200))
        await fixture.tracker.releaseRead()
        await sync.value
        let result = await fixture.history()
        #expect(result?.progress == 20)
        #expect(result?.completed == completed)
        #expect(result?.date == Date(timeIntervalSince1970: 200))
        await fixture.close()
    }
}

private actor OAuthRefreshBarrier {
    private(set) var started = false
    private var continuation: CheckedContinuation<OAuthResponse?, Never>?
    func run(_ refreshToken: String) async -> OAuthResponse? {
        started = true
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: OAuthResponse) { continuation?.resume(returning: value); continuation = nil }
}

private final class TrackerMutationReplay: URLProtocol {
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var status = 200
        private var writes = 0
        private var refreshes = 0
        private var wrongAuthorization = 0
        func reset(status: Int) { lock.withLock { self.status = status; writes = 0; refreshes = 0; wrongAuthorization = 0 } }
        func snapshot() -> (writes: Int, refreshes: Int, wrongAuthorization: Int) { lock.withLock { (writes, refreshes, wrongAuthorization) } }
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

private final class MALRegistrationReplay: URLProtocol {
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
        var status = 200
        let body: String
        switch (request.httpMethod, url.path) {
            case ("GET", "/v2/manga/1"): body = #"{"id":1}"#
            case ("GET", "/v2/manga/2"): body = #"{"id":2,"my_list_status":{"num_chapters_read":25}}"#
            case ("PATCH", _): body = "{}"
            default:
                status = 503
                body = "{}"
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private struct PageTrackingHistory: Sendable {
    let progress: Int16
    let completed: Bool
    let date: Date?
}

private final class PageTrackingFixture: @unchecked Sendable {
    let source = "tracking-followup-" + UUID().uuidString
    let tracker = HeldPageTracker()
    lazy var manga = AidokuRunner.Manga(sourceKey: source, key: "manga", title: "Fixture")
    let chapters: [AidokuRunner.Chapter] = [.init(key: "one", title: "One"), .init(key: "two", title: "Two")]
    lazy var defaults = UserDefaults(suiteName: source)!
    lazy var manager = TrackerManager(defaults: defaults, trackerResolver: { [tracker] id in id == tracker.id ? tracker : nil })

    func prepare() async throws {
        let mangaId = manga.identifier
        try await CoreDataManager.shared.container.performBackgroundTask { [tracker] context in
            CoreDataManager.shared.createTrack(id: "remote", trackerId: tracker.id, mangaId: mangaId, title: "Fixture", context: context)
            try context.save()
        }
        _ = manager
    }
    func writeHistory(page: Int, completed: Bool, date: Date) async {
        let chapterId = ChapterIdentifier(sourceKey: source, mangaKey: "manga", chapterKey: "one")
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.setProgress(page, chapterId: chapterId, dateRead: date, completed: completed, context: context)
            try? context.save()
        }
    }
    func history() async -> PageTrackingHistory? {
        let chapterId = ChapterIdentifier(sourceKey: source, mangaKey: "manga", chapterKey: "one")
        return await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getHistory(chapterId: chapterId, context: context).map {
                PageTrackingHistory(progress: $0.progress, completed: $0.completed, date: $0.dateRead)
            }
        }
    }
    func close() async {
        await tracker.releaseRead()
        await manager.waitForPendingPageUpdates()
        let mangaId = manga.identifier
        await CoreDataManager.shared.container.performBackgroundTask { [tracker, source] context in
            CoreDataManager.shared.removeTrack(trackerId: tracker.id, mangaId: mangaId, context: context)
            for object in CoreDataManager.shared.getHistory(sourceKey: source, context: context) { context.delete(object) }
            try? context.save()
        }
        UserDefaults.standard.removePersistentDomain(forName: source)
    }
}

private actor HeldPageTracker: PageTracker {
    nonisolated let id = "held-followup"
    nonisolated let name = "Fixture"
    nonisolated let icon: UIImage? = nil
    nonisolated let isLoggedIn = true
    private var readCount = 0
    var readStarted: Bool { readCount > 0 }
    private var readContinuation: CheckedContinuation<Void, Never>?
    func getProgress(trackId: String, chapters: [AidokuRunner.Chapter]) async throws -> [String: ChapterReadProgress] {
        readCount += 1
        if readCount == 1 { await withCheckedContinuation { readContinuation = $0 } }
        return ["one": .init(completed: false, page: 2, date: nil)]
    }
    func setProgress(trackId: String, chapterId: ChapterIdentifier, progress: ChapterReadProgress) async throws {}
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
    func getTrackerInfo() async throws -> TrackerInfo { .init(supportedStatuses: [], scoreType: .tenPoint) }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? { nil }
    func update(trackId: String, update: TrackUpdate) async throws {}
    func getState(trackId: String) async throws -> TrackState { .init() }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func logout() async throws {}
}
