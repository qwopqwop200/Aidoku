import Foundation
import Testing
@testable import Aidoku

struct NativeWebLoginPolicyTests {
    @Test func callbackMustMatchDeclaredRedirectAndState() {
        let redirect = "aidoku://login/oauth?tenant=sourceA"
        func valid(_ value: String, scheme: String = "aidoku", state: String = "s") -> Bool {
            NativeWebLoginPolicy.validatesCallback(URL(string: value)!, scheme: scheme, redirectURI: redirect, expectedState: state)
        }
        #expect(valid("aidoku://login/oauth?tenant=sourceA&code=c&state=s"))
        #expect(!valid("aidoku://login/oauth?tenant=sourceA&code=c&state=s", scheme: "other"))
        #expect(!valid("aidoku://login/oauth?tenant=sourceA&code=c&state=s", state: "old"))
        #expect(!valid("aidoku://login/oauth?tenant=sourceB&code=c&state=s"))
        #expect(!valid("aidoku://login/oauth?tenant=sourceA&tenant=sourceA&code=c&state=s"))
    }

    @Test func providerErrorAndAmbiguousParametersAreRejected() {
        for suffix in ["?error=access_denied&state=a", "?state=a&state=a", "?code=a#code=b", "?state=a#state=a"] {
            let callback = URL(string: "aidoku://login" + suffix)!
            #expect(!NativeWebLoginPolicy.validatesCallback(callback, scheme: "aidoku", redirectURI: nil, expectedState: "a"))
        }
    }

    @Test func loginURLsRequireHTTPHostAndNoEmbeddedCredentials() {
        #expect(NativeWebLoginPolicy.isHTTPURL(URL(string: "https://source.invalid/login")!))
        for value in ["javascript:alert(1)", "file:///login", "https://user:password@source.invalid/login"] {
            #expect(!NativeWebLoginPolicy.isHTTPURL(URL(string: value)!))
        }
    }
}

@MainActor
struct SettingsLoginAttemptTests {
    /// A token exchange that completes after logout must not store credentials.
    @Test func logoutRejectsLateTokenExchangeCompletion() async throws {
        let owner = SettingsLoginAttempt()
        var reply: CheckedContinuation<(Data, URLResponse), Never>?
        var writes = 0
        var errors = 0
        owner.exchange(attempt: owner.begin(), operation: {
            await withCheckedContinuation { reply = $0 }
        }, commit: { _ in writes += 1 }, failed: { errors += 1 })
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while reply == nil {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            await Task.yield()
        }
        owner.cancel()
        #expect(!owner.isLoading)
        reply?.resume(returning: (Data("stale".utf8), HTTPURLResponse(url: URL(string: "https://settings.invalid/token")!,
                                                                      statusCode: 200, httpVersion: nil, headerFields: nil)!))
        try await Task.sleep(for: .milliseconds(20))
        #expect(writes == 0 && errors == 0)
    }
}
