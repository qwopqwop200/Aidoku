import AidokuRunner
import XCTest
import SwiftUI
@testable import Aidoku

final class TrackerSerializationRegressionTests: XCTestCase {
    @MainActor
    func testTrackerPickerRejectsUnrepresentableRowsWithoutChangingNormalRows() {
        for type in [NumberType.int, .float] {
            let normal = TrackerSettingOptionViewCoordinator(total: 24, numberType: type)
            XCTAssertEqual(normal.pickerView(normal.pickerView, numberOfRowsInComponent: 0), type == .int ? 25 : 241)
            XCTAssertEqual(normal.selectionRow(for: 12.75), type == .int ? 12 : 127)
            XCTAssertEqual(normal.selectionRow(for: nil), 0)
            for count in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -1] {
                XCTAssertNil(normal.selectionRow(for: count))
            }
            XCTAssertNil(normal.selectionRow(for: 25))
            let overflow = TrackerSettingOptionViewCoordinator(total: Int.max, numberType: type)
            XCTAssertEqual(overflow.pickerView(overflow.pickerView, numberOfRowsInComponent: 0), 0)
            XCTAssertNil(overflow.selectionRow(for: 0))
            for total in [Float.nan, .infinity, Float(Int.max), -1] {
                _ = TrackerSettingOptionView("audit", total: .constant(total), numberType: type)
            }
        }
    }

    func testKavitaZeroBasedPageRejectsOnlyOverflow() throws {
        XCTAssertThrowsError(try KavitaApi.zeroBasedPage(Int.min))
        for page in [Int.min + 1, -1, 0, 1, 12, Int.max] {
            XCTAssertEqual(try KavitaApi.zeroBasedPage(page), page - 1)
        }
    }

    func testSuwayomiRemotePageOverflowIsSkippedAndValidProgressPreserved() async throws {
        XCTAssertTrue(URLProtocol.registerClass(TrackingAuditURLProtocol.self))
        defer { URLProtocol.unregisterClass(TrackingAuditURLProtocol.self) }
        let source = "audit-suwayomi-" + UUID().uuidString
        defer { UserDefaults.standard.removeObject(forKey: "\(source).server") }
        UserDefaults.standard.set("https://tracker-audit.invalid/suwayomi/", forKey: "\(source).server")
        let result = try await SuwayomiApi().getSeriesReadProgress(sourceKey: source, seriesId: "1")
        XCTAssertNil(result["1"])
        XCTAssertEqual(result["2"]?.page, 13)
        XCTAssertEqual(result["2"]?.completed, false)
        XCTAssertEqual(result["3"]?.page, 20)
        XCTAssertEqual(result["3"]?.completed, true)
    }

    func testUntrustedTrackingNumbersDoNotTrap() async {
        for value in [Float.nan, .infinity, -.infinity, .greatestFiniteMagnitude, -.greatestFiniteMagnitude] {
            XCTAssertNil(TrackerManager.wholeTrackingNumber(value))
            await TrackerManager.shared.setCompleted(
                mangaId: .init(sourceKey: "audit-invalid-metadata", mangaKey: UUID().uuidString),
                chapter: .init(key: "invalid", volumeNumber: value)
            )
        }
    }

    func testTrackingNumberFloorPreservesNormalMetadata() {
        for value: Float in [-123.75, -1, 0, 0.5, 1, 123.75, 100000] {
            XCTAssertEqual(TrackerManager.wholeTrackingNumber(value), Int(floor(value)))
        }
    }

    func testKomgaRemoteNumbersAndOutgoingNormalPayloadReplay() async throws {
        XCTAssertTrue(URLProtocol.registerClass(TrackingAuditURLProtocol.self))
        defer { URLProtocol.unregisterClass(TrackingAuditURLProtocol.self) }
        let source = "audit-komga-" + UUID().uuidString
        let keys = ["server", "login.username", "login.password", "useChapters"]
        defer { keys.forEach { UserDefaults.standard.removeObject(forKey: "\(source).\($0)") } }
        UserDefaults.standard.set("fixture", forKey: "\(source).login.username")
        UserDefaults.standard.set("fixture", forKey: "\(source).login.password")
        UserDefaults.standard.set(true, forKey: "\(source).useChapters")
        let api = KomgaApi()
        UserDefaults.standard.set("https://tracker-audit.invalid/extreme/", forKey: "\(source).server")
        let extreme = try await api.getState(sourceKey: source, seriesId: "1")
        XCTAssertNil(extreme?.totalChapters)
        UserDefaults.standard.set(false, forKey: "\(source).useChapters")
        let extremeVolumes = try await api.getState(sourceKey: source, seriesId: "1")
        XCTAssertNil(extremeVolumes?.lastReadVolume)
        XCTAssertNil(extremeVolumes?.totalVolumes)
        UserDefaults.standard.set(true, forKey: "\(source).useChapters")
        UserDefaults.standard.set("https://tracker-audit.invalid/normal/", forKey: "\(source).server")
        let normal = try await api.getState(sourceKey: source, seriesId: "1")
        XCTAssertEqual(normal?.lastReadChapter, 12.75)
        XCTAssertEqual(normal?.totalChapters, 24)
        // The replay server rejects any changed successful-path body bytes.
        try await api.update(sourceKey: source, seriesId: "1", update: .init(lastReadChapter: 12.75))
    }

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

private final class TrackingAuditURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "tracker-audit.invalid"
    }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let url = request.url else { return }
        let data: Data
        var status = 200
        if url.path.contains("suwayomi") {
            data = Data("""
                {"data":{"chapters":{"nodes":[
                {"id":1,"isRead":true,"lastPageRead":\(Int.max),"lastReadAt":"2026-01-01T00:00:00Z","pageCount":20},
                {"id":2,"isRead":false,"lastPageRead":12,"lastReadAt":"2026-01-01T00:00:00Z","pageCount":20},
                {"id":3,"isRead":true,"lastPageRead":12,"lastReadAt":"2026-01-01T00:00:00Z","pageCount":20}
                ]}}}
                """.utf8)
        } else if request.httpMethod == "PUT" {
            var body = request.httpBody
            if body == nil, let stream = request.httpBodyStream {
                stream.open()
                defer { stream.close() }
                var bytes = Data()
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    if count <= 0 { break }
                    bytes.append(contentsOf: buffer.prefix(count))
                }
                body = bytes
            }
            if body != Data(#"{"lastBookNumberSortRead":12}"#.utf8) { status = 422 }
            data = Data()
        } else {
            let payload = url.path.contains("extreme")
                ? #"{"lastReadContinuousNumberSort":1e30,"maxNumberSort":1e30}"#
                : #"{"lastReadContinuousNumberSort":12.75,"maxNumberSort":24.75}"#
            data = Data(payload.utf8)
        }
        let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: nil,
                                       headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}
