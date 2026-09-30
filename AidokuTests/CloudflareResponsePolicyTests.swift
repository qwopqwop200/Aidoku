import Foundation
import Testing
@testable import Aidoku

struct CloudflareResponsePolicyTests {
    private let url = URL(string: "https://example.org/api/items")!

    private func response(_ status: Int, _ headers: [String: String]) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: status, httpVersion: nil, headerFields: headers)!
    }

    @Test func authoritativeChallengeHeaderDoesNotRequireLegacyStatusOrServer() {
        #expect(CloudflareResponsePolicy.isChallenge(
            response: response(429, ["Cf-Mitigated": "challenge"]), data: Data()))
        #expect(!CloudflareResponsePolicy.isChallenge(
            response: response(403, ["Server": "cloudflare", "Cf-Mitigated": "other"]), data: Data()))
    }

    @Test func ordinaryCloudflareForbiddenIsNotAChallenge() {
        #expect(!CloudflareResponsePolicy.isChallenge(
            response: response(403, ["Server": "cloudflare"]), data: Data("Forbidden".utf8)))
        #expect(!CloudflareResponsePolicy.isChallenge(
            response: response(200, ["Server": "cloudflare"]), data: Data("challenge-error-title".utf8)))
    }

    @Test func legacyChallengeRequiresCloudflareAndChallengeMarkup() {
        let html = Data("<h1 id='challenge-error-title'>Verify</h1>".utf8)
        #expect(CloudflareResponsePolicy.isChallenge(response: response(503, ["Server": "Cloudflare"]), data: html))
        #expect(!CloudflareResponsePolicy.isChallenge(response: response(503, ["Server": "nginx"]), data: html))
        #expect(CloudflareResponsePolicy.isChallenge(response: response(403, ["Server": "cloudflare"]),
            data: Data("<script>window._cf_chl_opt={};</script><script src='/cdn-cgi/challenge-platform/a'></script>".utf8)))
    }

    @Test func cachedNativeRetryIsRestrictedToSafeBodylessReads() {
        var request = URLRequest(url: url)
        #expect(CloudflareResponsePolicy.mayRetryCachedClearance(request))
        request.httpMethod = "HEAD"
        #expect(CloudflareResponsePolicy.mayRetryCachedClearance(request))
        for method in ["POST", "PUT", "PATCH", "DELETE"] {
            request.httpMethod = method
            #expect(!CloudflareResponsePolicy.mayRetryCachedClearance(request))
        }
        request.httpMethod = "GET"
        request.httpBody = Data("payload".utf8)
        #expect(!CloudflareResponsePolicy.mayRetryCachedClearance(request))
    }

    @Test func replacingClearancePreservesOriginalMutationAndUnrelatedCookies() {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("exact original body".utf8)
        request.setValue("session=abc; cf_clearance=old; custom=x; cf_clearance=older", forHTTPHeaderField: "Cookie")
        request.setValue("Bearer example", forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("source-user-agent", forHTTPHeaderField: "User-Agent")
        let cookie = HTTPCookie(properties: [.name: "cf_clearance", .value: "new", .domain: "example.org", .path: "/"])!
        let updated = CloudflareResponsePolicy.request(request, applying: cookie)
        #expect(updated.httpMethod == request.httpMethod)
        #expect(updated.httpBody == request.httpBody)
        #expect(updated.url == request.url)
        #expect(updated.value(forHTTPHeaderField: "Cookie") == "session=abc; custom=x; cf_clearance=new")
        for header in ["Authorization", "Content-Type", "User-Agent"] {
            #expect(updated.value(forHTTPHeaderField: header) == request.value(forHTTPHeaderField: header))
        }
        #expect(request.value(forHTTPHeaderField: "Cookie")?.contains("old") == true)
    }

    @Test func browserVerificationNeverReplaysMutationBody() {
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = Data("private source submission".utf8)
        request.setValue("30", forHTTPHeaderField: "Content-Length")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer token", forHTTPHeaderField: "Authorization")
        let navigation = CloudflareResponsePolicy.browserRequest(for: request)
        #expect(navigation.httpMethod == "GET")
        #expect(navigation.httpBody == nil)
        #expect(navigation.httpBodyStream == nil)
        #expect(navigation.value(forHTTPHeaderField: "Content-Length") == nil)
        #expect(navigation.value(forHTTPHeaderField: "Content-Type") == nil)
        #expect(navigation.value(forHTTPHeaderField: "Authorization") == "Bearer token")
        #expect(request.httpMethod == "POST")
        #expect(request.httpBody != nil)
    }
    @Test func clearanceCookiesRespectExpirySchemeHostAndPathBoundaries() {
        let now = Date()
        let cookie = HTTPCookie(properties: [.name: "cf_clearance", .value: "valid", .domain: ".example.org",
            .path: "/api", .secure: "TRUE", .expires: now.addingTimeInterval(60)])!
        #expect(CloudflareResponsePolicy.cookie(cookie, appliesTo: url, now: now))
        for value in ["https://evil-example.org/api", "https://example.org/apian", "http://example.org/api"] {
            #expect(!CloudflareResponsePolicy.cookie(cookie, appliesTo: URL(string: value)!, now: now))
        }
        #expect(!CloudflareResponsePolicy.cookie(cookie, appliesTo: url, now: now.addingTimeInterval(120)))
        #expect(CloudflareResponsePolicy.cookie(cookie, appliesTo: URL(string: "https://sub.example.org/api/detail")!, now: now))
    }

}
