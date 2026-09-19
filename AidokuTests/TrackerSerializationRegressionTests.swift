import XCTest
@testable import Aidoku

final class TrackerSerializationRegressionTests: XCTestCase {
    func testPersistedOAuthTokenKeepsOriginalExpiration() throws {
        let original = OAuthResponse(accessToken: "test", expiresIn: 60, createdAt: Date(timeIntervalSince1970: 100))
        let restored = try JSONDecoder().decode(OAuthResponse.self, from: JSONEncoder().encode(original))
        XCTAssertEqual(restored.createdAt, original.createdAt)
        XCTAssertTrue(restored.expired)
    }

    func testServerOAuthResponseWithoutLocalTimestampStillDecodes() throws {
        let before = Date()
        let response = try JSONDecoder().decode(OAuthResponse.self, from: Data(#"{"access_token":"test","expires_in":3600}"#.utf8))
        XCTAssertGreaterThanOrEqual(response.createdAt, before)
        XCTAssertFalse(response.expired)
    }

    func testMangaBakaFinishDateDoesNotOverwriteStartDate() throws {
        let entry = MangaBakaLibraryEntry(startDate: "2025-01-02", finishDate: "2026-03-04")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(object["start_date"] as? String, "2025-01-02")
        XCTAssertEqual(object["finish_date"] as? String, "2026-03-04")
    }

    func testClearingMangaBakaFinishDatePreservesStartDate() throws {
        let entry = MangaBakaLibraryEntry(startDate: "2025-01-02", finishDate: "1970-01-01T00:00:00.000Z")
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        XCTAssertEqual(object["start_date"] as? String, "2025-01-02")
        XCTAssertTrue(object["finish_date"] is NSNull)
    }

    func testClearingOAuthTokensClearsInMemoryAuthorization() async {
        // Use a unique client to avoid touching the user's tracker settings.
        let id = "test-" + UUID().uuidString
        let client = OAuthClient(id: id, clientId: "test", baseUrl: "https://example.invalid")
        await client.setTokens(OAuthResponse(accessToken: "old-account"))
        await client.setTokens(nil)
        let request = await client.authorizedRequest(for: URL(string: "https://example.invalid")!)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer ")
        UserDefaults.standard.removeObject(forKey: "Tracker.\(id).oauth")
    }
}
