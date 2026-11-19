import Foundation
import Testing
@testable import Aidoku

struct SourceLoginBrowserPolicyTests {
    private func cookie(_ value: String, domain: String = "reader.example", path: String = "/", secure: Bool = false,
                        expires: Date? = nil) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [.name: "session", .value: value, .domain: domain, .path: path]
        if secure { properties[.secure] = "TRUE" }
        if let expires { properties[.expires] = expires }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func cookieScopeRejectsForeignHostSiblingPathAndExpiredCredentials() throws {
        let now = Date()
        let cookies = try [
            cookie("root"), cookie("api", path: "/api"), cookie("sibling", path: "/api2"),
            cookie("provider", domain: "idp.example"), cookie("expired", expires: now.addingTimeInterval(-60))
        ]
        let url = try #require(URL(string: "https://reader.example/api/account"))
        #expect(SourceLoginBrowserPolicy.cookies(cookies, for: url, now: now).map(\.value) == ["api", "root"])
    }

    @Test func hostOnlyCookieDoesNotEscapeToSubdomainAndSecureCookieNeedsHTTPS() throws {
        let cookies = try [cookie("host"), cookie("domain", domain: ".reader.example", secure: true)]
        let https = try #require(URL(string: "https://sub.reader.example/"))
        let http = try #require(URL(string: "http://sub.reader.example/"))
        #expect(SourceLoginBrowserPolicy.cookies(cookies, for: https).map(\.value) == ["domain"])
        #expect(SourceLoginBrowserPolicy.cookies(cookies, for: http).isEmpty)
    }

    @Test func localStorageRequiresTheSourceOrigin() throws {
        let source = try #require(URL(string: "https://reader.example/login"))
        #expect(SourceLoginBrowserPolicy.sameOrigin(URL(string: "https://reader.example:443/callback"), source))
        #expect(!SourceLoginBrowserPolicy.sameOrigin(URL(string: "https://idp.example/login"), source))
        #expect(!SourceLoginBrowserPolicy.sameOrigin(URL(string: "http://reader.example/login"), source))
    }
}
