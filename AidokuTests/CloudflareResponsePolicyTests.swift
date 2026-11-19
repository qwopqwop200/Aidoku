import Foundation
import Testing
@testable import Aidoku

struct CloudflareResponsePolicyTests {
    private let url = URL(string: "https://example.org/api/items")!

    private func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test func challengeDetectionRequiresCloudflareSignal() {
        #expect(CloudflareResponsePolicy.isChallenge(response: response(429, ["Cf-Mitigated": "challenge"]), data: Data()))
        let html = Data("<h1 id='challenge-error-title'>Verify</h1>".utf8)
        #expect(CloudflareResponsePolicy.isChallenge(response: response(503, ["Server": "Cloudflare"]), data: html))
        #expect(!CloudflareResponsePolicy.isChallenge(response: response(503, ["Server": "nginx"]), data: html))
        #expect(!CloudflareResponsePolicy.isChallenge(
            response: response(403, ["Server": "cloudflare"]), data: Data("Forbidden".utf8)))
    }

    @Test func browserVerificationNeverReplaysMutationBody() {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("private source submission".utf8)
        request.setValue("30", forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let navigation = CloudflareResponsePolicy.browserRequest(for: request)
        #expect(navigation.httpMethod == "GET")
        #expect(navigation.httpBody == nil)
        #expect(navigation.httpBodyStream == nil)
        #expect(navigation.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(navigation.value(forHTTPHeaderField: "Content-Type") == nil)
    }

    @Test func clearanceCookiesRespectExpirySchemeHostAndPathBoundaries() throws {
        let now = Date()
        let cookie = HTTPCookie(properties: [.name: "cf_clearance", .value: "valid", .domain: ".example.org",
            .path: "/api", .secure: "TRUE", .expires: now.addingTimeInterval(60)])!
        #expect(CloudflareResponsePolicy.cookie(cookie, appliesTo: url, now: now))
        #expect(CloudflareResponsePolicy.cookie(cookie, appliesTo: URL(string: "https://sub.example.org/api/detail")!, now: now))
        for value in ["https://evil-example.org/api", "https://example.org/apian", "http://example.org/api"] {
            #expect(!CloudflareResponsePolicy.cookie(cookie, appliesTo: URL(string: value)!, now: now))
        }
        #expect(!CloudflareResponsePolicy.cookie(cookie, appliesTo: url, now: now.addingTimeInterval(120)))
        let hostOnly = try #require(HTTPCookie(properties: [
            .name: "cf_clearance", .value: "root-host-clearance", .domain: "reader.example", .path: "/"
        ]))
        #expect(CloudflareResponsePolicy.cookie(hostOnly, appliesTo: URL(string: "https://reader.example/api")!))
        #expect(!CloudflareResponsePolicy.cookie(hostOnly, appliesTo: URL(string: "https://sub.reader.example/api")!))
    }
}
