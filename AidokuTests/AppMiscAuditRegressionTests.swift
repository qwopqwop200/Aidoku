import CoreGraphics
import Foundation
import Testing
@testable import Aidoku

struct AppMiscAuditRegressionTests {
    @Test func oauthResponseReadsServerUnixCreatedAt() throws {
        // Doorkeeper (Shikimori) sends Unix seconds; the default Date decoding read them
        // as reference-date seconds, putting expiry ~31 years in the future.
        let issued = Date().timeIntervalSince1970 - 7200
        let json = #"{"access_token":"a","expires_in":3600,"created_at":\#(Int(issued))}"#
        let response = try JSONDecoder().decode(OAuthResponse.self, from: Data(json.utf8))
        #expect(abs(response.createdAt.timeIntervalSince1970 - issued) < 1)
        #expect(response.expired)
    }

    @Test func oauthResponseToleratesStringFields() throws {
        let before = Date()
        let text = #"{"access_token":"a","created_at":"2026-01-01T00:00:00Z","asked_for_refresh":"no"}"#
        let lenient = try JSONDecoder().decode(OAuthResponse.self, from: Data(text.utf8))
        #expect(lenient.accessToken == "a")
        #expect(lenient.createdAt >= before)
        #expect(!lenient.askedForRefresh)
    }

    @MainActor
    @Test func dictionaryMediaRenderScaleCapsTallBitmapsOnly() {
        #expect(NativeDictionaryImageAttachment.renderScale(for: CGSize(width: 100, height: 100), screenScale: 3) == 3)
        let tall = CGSize(width: 390, height: 4096)
        let scale = NativeDictionaryImageAttachment.renderScale(for: tall, screenScale: 3)
        #expect(scale < 3)
        #expect(tall.width * tall.height * scale * scale <= NativeDictionaryImageAttachment.maximumRenderPixels + 1)
        #expect(NativeDictionaryImageAttachment.renderScale(for: .zero, screenScale: 2) == 2)
    }
}
