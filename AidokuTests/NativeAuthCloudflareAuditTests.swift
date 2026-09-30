import Foundation
import Testing
@testable import Aidoku

struct NativeAuthCloudflareAuditTests {
    @Test func declaredRedirectQueryCannotChangeOrBecomeAmbiguous() {
        let redirect = "aidoku://login/oauth?tenant=sourceA"
        #expect(NativeWebLoginPolicy.validatesCallback(URL(string: "aidoku://login/oauth?tenant=sourceA&code=c&state=s")!,
            scheme: "aidoku", redirectURI: redirect, expectedState: "s"))
        #expect(!NativeWebLoginPolicy.validatesCallback(URL(string: "aidoku://login/oauth?tenant=sourceB&code=c&state=s")!,
            scheme: "aidoku", redirectURI: redirect, expectedState: "s"))
        #expect(!NativeWebLoginPolicy.validatesCallback(URL(string: "aidoku://login/oauth?tenant=sourceA&tenant=sourceA&code=c&state=s")!,
            scheme: "aidoku", redirectURI: redirect, expectedState: "s"))
        #expect(!NativeWebLoginPolicy.validatesCallback(URL(string: "aidoku://login/oauth?code=c&state=s#tenant=sourceA")!,
            scheme: "aidoku", redirectURI: redirect, expectedState: "s"))
        #expect(!NativeWebLoginPolicy.validatesCallback(URL(string: "aidoku://login/oauth?tenant=sourceA&code=c&state=s#tenant=sourceA")!,
            scheme: "aidoku", redirectURI: redirect, expectedState: "s"))
    }
    @Test func hostOnlyClearanceCannotFinishAnotherSubdomainsChallenge() throws {
        let cookie = try #require(HTTPCookie(properties: [
            .name: "cf_clearance", .value: "root-host-clearance", .domain: "reader.example", .path: "/"
        ]))
        let root = try #require(URL(string: "https://reader.example/api"))
        let subdomain = try #require(URL(string: "https://sub.reader.example/api"))
        #expect(CloudflareResponsePolicy.cookie(cookie, appliesTo: root))
        #expect(!CloudflareResponsePolicy.cookie(cookie, appliesTo: subdomain))
    }
}
