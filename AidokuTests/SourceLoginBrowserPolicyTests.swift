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
        #expect(SourceLoginBrowserPolicy.cookieValues(cookies, for: url) == ["session": "api"])
    }

    @Test func genericLoginExportKeepsSourceAPICookiesWithoutTreatingLoginPathAsRequestPath() throws {
        let login = try #require(URL(string: "https://reader.example/oidc/login"))
        let cookies = try [cookie("api", path: "/api"), cookie("foreign", domain: "idp.example", path: "/api")]
        #expect(SourceLoginBrowserPolicy.cookieValues(cookies, for: login).isEmpty)
        #expect(SourceLoginBrowserPolicy.cookieValues(cookies, for: login, includePath: false) == ["session": "api"])
    }

    @Test func hostOnlyCookieDoesNotEscapeToSubdomainAndSecureCookieNeedsHTTPS() throws {
        let cookies = try [cookie("host"), cookie("domain", domain: ".reader.example", secure: true)]
        let https = try #require(URL(string: "https://sub.reader.example/"))
        let http = try #require(URL(string: "http://sub.reader.example/"))
        #expect(SourceLoginBrowserPolicy.cookies(cookies, for: https).map(\.value) == ["domain"])
        #expect(SourceLoginBrowserPolicy.cookies(cookies, for: http).isEmpty)
        let unrelated = try #require(URL(string: "https://notreader.example/"))
        #expect(SourceLoginBrowserPolicy.cookies(cookies, for: unrelated).isEmpty)
    }

    @Test func localStorageRequiresTheSourceOriginIncludingPortAndScheme() throws {
        let source = try #require(URL(string: "https://reader.example/login"))
        #expect(SourceLoginBrowserPolicy.sameOrigin(URL(string: "https://reader.example:443/callback"), source))
        for value in ["http://reader.example/login", "https://reader.example:8443/login", "https://idp.example/login"] {
            #expect(!SourceLoginBrowserPolicy.sameOrigin(URL(string: value), source))
        }
        #expect(!SourceLoginBrowserPolicy.sameOrigin(nil, source))
    }

    @Test func oidcCallbackRejectsOtherAppRoutesAndURLDecorations() throws {
        #expect(SourceLoginBrowserPolicy.isOIDCCallback(try #require(URL(string: "aidoku://oidc-auth"))))
        for value in ["aidoku://shikimori-auth", "aidoku://oidc-auth/evil", "aidoku://oidc-auth?token=other",
                      "aidoku://user@oidc-auth", "aidoku://oidc-auth:123", "https://oidc-auth", "aidoku://oidc-auth#extra"] {
            #expect(!SourceLoginBrowserPolicy.isOIDCCallback(try #require(URL(string: value))))
        }
    }
}
