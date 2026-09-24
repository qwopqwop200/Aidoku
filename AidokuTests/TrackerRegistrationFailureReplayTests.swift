import Foundation
import XCTest
@testable import Aidoku

/// Actual tracker/API calls through URLSession.shared, intercepted locally.
/// No real credentials, tracker writes, or Core Data changes. Run centrally.
final class TrackerRegistrationFailureReplayTests: XCTestCase {
    func testRegistrationReplayPreservesSuccessAndRejectsFailures() async throws {
        let keys = ["Tracker.bangumi.oauth", "Tracker.shikimori.oauth", "Tracker.shikimori.user_id"]
        let saved = keys.map { UserDefaults.standard.object(forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { UserDefaults.standard.set(value, forKey: key) }
                else { UserDefaults.standard.removeObject(forKey: key) }
            }
            URLProtocol.unregisterClass(RegistrationFailureReplay.self)
        }
        XCTAssertTrue(URLProtocol.registerClass(RegistrationFailureReplay.self))
        let bangumi = BangumiTracker()
        let shikimori = ShikimoriTracker()
        let dummy = OAuthResponse(tokenType: "Bearer", accessToken: RegistrationFailureReplay.fixtureToken, expiresIn: 3600)
        await bangumi.oauthClient.setTokens(dummy)
        await shikimori.oauthClient.setTokens(dummy)
        UserDefaults.standard.removeObject(forKey: "Tracker.shikimori.user_id")

        for scenario in RegistrationFailureReplay.Scenario.allCases {
            RegistrationFailureReplay.state.reset(scenario)
            var failed = false
            do {
                let id = try await bangumi.register(trackId: "42", highestChapterRead: 5, earliestReadDate: nil)
                XCTAssertNil(id, "Bangumi preserves its original subject ID")
            } catch {
                failed = true
                XCTAssertTrue(error is BangumiTrackerError)
            }
            // Bangumi's existing write contract validates HTTP status only;
            // an opaque successful response body must remain accepted.
            XCTAssertEqual(failed, scenario == .httpFailure || scenario == .transportFailure)
            let writes = RegistrationFailureReplay.state.snapshot().filter { $0.method == "POST" }
            XCTAssertEqual(writes.count, 1)
            let write = try XCTUnwrap(writes.first)
            XCTAssertEqual(write.path, "/v0/users/-/collections/42")
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: write.body) as? [String: Int])
            XCTAssertEqual(body, ["type": 1, "ep_status": 5])
        }

        for scenario in RegistrationFailureReplay.Scenario.allCases {
            RegistrationFailureReplay.state.reset(scenario)
            var failed = false
            do {
                let id = try await shikimori.register(trackId: "42", highestChapterRead: 5, earliestReadDate: nil)
                XCTAssertEqual(id, "987", "Shikimori must return rate ID, never manga ID")
            } catch {
                failed = true
                XCTAssertTrue(error is URLError)
            }
            XCTAssertEqual(failed, scenario != .success)
            let writes = RegistrationFailureReplay.state.snapshot().filter { $0.method == "POST" }
            XCTAssertEqual(writes.count, 1)
            let write = try XCTUnwrap(writes.first)
            XCTAssertEqual(write.path, "/api/v2/user_rates")
            XCTAssertEqual(write.query, [
                "user_rate[user_id]": "77", "user_rate[target_id]": "42",
                "user_rate[target_type]": "Manga", "user_rate[status]": "watching",
                "user_rate[chapters]": "5.0"
            ])
            XCTAssertTrue(write.body.isEmpty)
        }
    }
}

private final class RegistrationFailureReplay: URLProtocol {
    static let fixtureToken = "round2-registration-replay-no-real-token"
    enum Scenario: CaseIterable { case success, httpFailure, invalidJSON, transportFailure }
    struct Recorded: Sendable {
        let method: String
        let path: String
        let query: [String: String]
        let body: Data
    }
    final class State: @unchecked Sendable {
        private let lock = NSLock()
        private var scenario = Scenario.success
        private var records: [Recorded] = []
        func reset(_ value: Scenario) { lock.lock(); defer { lock.unlock() }; scenario = value; records = [] }
        func append(_ record: Recorded) -> Scenario {
            lock.lock(); defer { lock.unlock() }; records.append(record); return scenario
        }
        func snapshot() -> [Recorded] { lock.lock(); defer { lock.unlock() }; return records }
    }
    static let state = State()
    override class func canInit(with request: URLRequest) -> Bool {
        ["api.bgm.tv", "shikimori.io"].contains(request.url?.host ?? "") &&
            request.value(forHTTPHeaderField: "Authorization") == "Bearer " + fixtureToken
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
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.reduce(into: [String: String]()) {
            $0[$1.name] = $1.value
        } ?? [:]
        let scenario = Self.state.append(.init(method: request.httpMethod ?? "GET", path: url.path, query: query, body: body))
        var status = 200
        let payload: String
        if request.httpMethod == "POST" {
            if scenario == .transportFailure {
                client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return
            }
            if scenario == .httpFailure { status = 503 }
            if scenario == .invalidJSON { payload = "not-json" }
            else if url.host == "shikimori.io" {
                payload = #"{"id":987,"target_id":42,"target_type":"Manga","status":"watching","chapters":5,"volumes":0,"score":0,"created_at":"2026-01-01","updated_at":"2026-01-01"}"#
            } else { payload = "{}" }
        } else if url.path == "/v0/me" {
            payload = #"{"id":77,"username":"round2-fixture"}"#
        } else if url.path == "/api/users/whoami" {
            payload = #"{"id":77}"#
        } else if url.path == "/v0/users/round2-fixture/collections/42" {
            status = 404; payload = "{}" // valid JSON, absent collection
        } else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
            headerFields: ["Content-Type": "application/json", "Cache-Control": "no-store"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
