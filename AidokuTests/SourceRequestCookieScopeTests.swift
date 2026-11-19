import Foundation
import Testing
@testable import Aidoku

/// Secure cookies (e.g. Cloudflare clearance) must never be attached to plain-HTTP source requests.
struct SourceRequestCookieScopeTests {
    private func storage() throws -> HTTPCookieStorage {
        try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
    }

    private func cookie(_ name: String, domain: String = "reader.example", path: String = "/", secure: Bool = false) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "value-" + name, .domain: domain, .path: path,
            .expires: Date().addingTimeInterval(3600)
        ]
        if secure { properties[.secure] = "TRUE" }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func eligibleHTTPSCookiesKeepExactHistoricalHeaderAndCacheScope() throws {
        let storage = try storage()
        storage.setCookie(try cookie("clearance", domain: ".reader.example", secure: true))
        storage.setCookie(try cookie("session", path: "/pages", secure: true))
        let url = try #require(URL(string: "https://reader.example/pages/1.png"))
        let before = HTTPCookie.requestHeaderFields(with: storage.allCookies(for: url) ?? [])
        let after = HTTPCookie.requestHeaderFields(with: storage.requestCookies(for: url) ?? [])
        #expect(before == after)
        #expect(storage.requestCookies(for: url)?.count == 2)
        let http = try #require(URL(string: "http://reader.example/pages/1.png"))
        #expect(storage.requestCookies(for: http)?.isEmpty != false)
        #expect(storage.allCookies(for: http)?.count == 2) // broad cache clearing preserved
    }
}
