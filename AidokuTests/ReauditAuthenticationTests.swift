import Foundation
import Testing
@testable import Aidoku

struct ReauditAuthenticationTests {
    @Test func callbackMustPreserveRegisteredPathSpelling() {
        let redirectsAndAliases = [
            ("aidoku://login/oauth", "aidoku://login/oauth/"),
            ("aidoku://login/a%2Fb", "aidoku://login/a/b"),
            ("aidoku://login/%61uth", "aidoku://login/auth")
        ]
        for (redirect, alias) in redirectsAndAliases {
            let exact = URL(string: redirect + "?code=c&state=s")!
            let different = URL(string: alias + "?code=c&state=s")!
            #expect(NativeWebLoginPolicy.validatesCallback(exact, scheme: "aidoku", redirectURI: redirect, expectedState: "s"))
            #expect(!NativeWebLoginPolicy.validatesCallback(different, scheme: "aidoku", redirectURI: redirect, expectedState: "s"))
        }
    }

    @Test func cookiePathMatchingUsesEncodedRequestPathAndPreservesTrailingSlash() throws {
        func cookie(path: String) throws -> HTTPCookie {
            try #require(HTTPCookie(properties: [
                .name: "session", .value: "fixture", .domain: "reader.example", .path: path
            ]))
        }
        let trailingSlash = URL(string: "https://reader.example/api/")!
        #expect(SourceLoginBrowserPolicy.cookies([try cookie(path: "/api/")], for: trailingSlash).count == 1)

        let encodedSeparator = URL(string: "https://reader.example/api%2Faccount")!
        #expect(SourceLoginBrowserPolicy.cookies([try cookie(path: "/api/account")], for: encodedSeparator).isEmpty)
        #expect(SourceLoginBrowserPolicy.cookies([try cookie(path: "/api%2Faccount")], for: encodedSeparator).count == 1)
    }
}
