import Foundation
import Testing
@testable import Aidoku

struct NativeWebLoginPolicyTests {
    @Test func callbackMustMatchDeclaredRedirectAndState() {
        let redirect = "aidoku://login/oauth"
        let callback = URL(string: redirect + "?code=abc&state=attempt")!
        #expect(NativeWebLoginPolicy.validatesCallback(callback, scheme: "aidoku", redirectURI: redirect, expectedState: "attempt"))
        #expect(!NativeWebLoginPolicy.validatesCallback(callback, scheme: "other", redirectURI: redirect, expectedState: "attempt"))
        #expect(!NativeWebLoginPolicy.validatesCallback(callback, scheme: "aidoku", redirectURI: "aidoku://login/other", expectedState: "attempt"))
        #expect(!NativeWebLoginPolicy.validatesCallback(callback, scheme: "aidoku", redirectURI: redirect, expectedState: "old"))
    }

    @Test func providerErrorAndAmbiguousParametersAreRejected() {
        for suffix in ["?error=access_denied&state=a", "?state=a&state=a", "?code=a#code=b", "?state=a#state=a"] {
            let callback = URL(string: "aidoku://login" + suffix)!
            #expect(!NativeWebLoginPolicy.validatesCallback(callback, scheme: "aidoku", redirectURI: nil, expectedState: "a"))
        }
    }

    @Test func fragmentCallbackPreservesEncodedState() {
        let callback = URL(string: "aidoku://login#access_token=token&state=a%26b%3Dc")!
        #expect(NativeWebLoginPolicy.validatesCallback(callback, scheme: "aidoku", redirectURI: nil, expectedState: "a&b=c"))
    }

    @Test func loginURLsRequireHTTPHostAndNoEmbeddedCredentials() {
        #expect(NativeWebLoginPolicy.isHTTPURL(URL(string: "https://source.invalid/login")!))
        #expect(NativeWebLoginPolicy.isHTTPURL(URL(string: "http://localhost:8080/login")!))
        for value in ["javascript:alert(1)", "file:///login", "https://user:password@source.invalid/login"] {
            #expect(!NativeWebLoginPolicy.isHTTPURL(URL(string: value)!))
        }
    }
}

@MainActor
struct NativeLoginAttemptTests {
    @Test func cancelRejectsLateBasicOrCookieAuthenticationSuccess() async throws {
        let owner = SettingsLoginAttempt()
        var gate: CheckedContinuation<Bool, Never>?
        var writes = 0
        let attempt = owner.begin()
        owner.authenticate(attempt: attempt, operation: {
            await withCheckedContinuation { gate = $0 }
        }, commit: { writes += 1 }, failed: { writes += 1 })
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while gate == nil {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(owner.isLoading)
        owner.cancel()
        gate?.resume(returning: true)
        try await Task.sleep(for: .milliseconds(20))
        #expect(writes == 0)
        #expect(!owner.isLoading)
    }
}
