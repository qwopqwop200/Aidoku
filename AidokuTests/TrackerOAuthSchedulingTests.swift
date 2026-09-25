import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct TrackerOAuthSchedulingTests {
    @Test func concurrentRefreshPublishesBeforeAllConsumersResume() async throws {
        let client = makeClient()
        let id = await client.id
        defer { clean(id) }
        await client.setTokens(oldTokens)
        let barrier = OAuthRefreshBarrier()
        let tasks = (0..<20).map { _ in
            Task {
                let response = await client.refreshTokens(replacingAuthorization: "Bearer old") { await barrier.run() }
                let request = await client.authorizedRequest(for: URL(string: "https://fixture.invalid/data")!)
                return (response?.accessToken, request.value(forHTTPHeaderField: "Authorization"))
            }
        }
        try await waitUntil { await barrier.started == 1 }
        for _ in 0..<30 { await Task.yield() }
        await barrier.release(newTokens)
        for task in tasks {
            let result = await task.value
            #expect(result.0 == "new")
            #expect(result.1 == "Bearer new")
        }
        #expect(await barrier.started == 1)
    }

    @Test func cancellationOfOneConsumerDoesNotCancelSharedRefresh() async throws {
        let client = makeClient()
        let id = await client.id
        defer { clean(id) }
        await client.setTokens(oldTokens)
        let barrier = OAuthRefreshBarrier()
        let first = Task { await client.refreshTokens(replacingAuthorization: "Bearer old") { await barrier.run() } }
        try await waitUntil { await barrier.started == 1 }
        let second = Task { await client.refreshTokens(replacingAuthorization: "Bearer old") { await barrier.run() } }
        first.cancel()
        await barrier.release(newTokens)
        #expect(await first.value == nil)
        #expect(await second.value?.accessToken == "new")
        #expect(await barrier.started == 1)
    }

    @Test func lateRefreshCannotRestoreLoggedOutCredentials() async throws {
        let client = makeClient()
        let id = await client.id
        defer { clean(id) }
        await client.setTokens(oldTokens)
        let barrier = OAuthRefreshBarrier()
        let task = Task { await client.refreshTokens(replacingAuthorization: "Bearer old") { await barrier.run() } }
        try await waitUntil { await barrier.started == 1 }
        await client.setTokens(nil)
        await barrier.release(newTokens)
        #expect(await task.value == nil)
        #expect(await client.tokens == nil)
    }

    @Test func lateLoginCannotReplaceNewerAccount() async {
        let client = makeClient()
        let id = await client.id
        defer { clean(id) }
        let oldLogin = await client.beginAuthentication()
        await client.setTokens(newTokens)
        #expect(await client.commitAuthentication(oldTokens, generation: oldLogin) == nil)
        #expect(await client.tokens?.accessToken == "new")
    }

    @Test func accountMarkerSurvivesRequestCopiesWithoutBecomingAHeader() async throws {
        let client = makeClient()
        let id = await client.id
        defer { clean(id) }
        await client.setTokens(oldTokens)
        let issued = await client.accountGeneration
        var request = await client.authorizedRequest(for: URL(string: "https://fixture.invalid/data")!)
        request.httpMethod = "PATCH"
        request.httpBody = Data("payload".utf8)
        let mutable = try #require((request as NSURLRequest).mutableCopy() as? NSMutableURLRequest)
        mutable.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request = mutable as URLRequest
        #expect(OAuthClient.generation(for: request) == issued)
        #expect(request.allHTTPHeaderFields?.keys.contains(where: { $0.contains("Generation") }) == false)
        await client.setTokens(newTokens)
        #expect(OAuthClient.generation(for: request) != (await client.accountGeneration))
    }

    @Test func oldAccountMetadataCannotReturnAfterLogoutOrNewLogin() async {
        let client = makeClient()
        let id = await client.id
        defer { clean(id) }
        await client.setTokens(oldTokens)
        let issued = await client.accountGeneration
        #expect(await client.cacheUserID("old-user", generation: issued) == "old-user")
        await client.setTokens(newTokens)
        #expect(await client.cachedUserID() == nil)
        #expect(await client.cacheUserID("late-old-user", generation: issued) == nil)
        #expect(await client.cachedUserID() == nil)
    }

    private var oldTokens: OAuthResponse { .init(tokenType: "Bearer", refreshToken: "refresh-old", accessToken: "old", expiresIn: 3600) }
    private var newTokens: OAuthResponse { .init(tokenType: "Bearer", refreshToken: "refresh-new", accessToken: "new", expiresIn: 3600) }
    private func makeClient() -> OAuthClient { OAuthClient(id: "test-oauth-" + UUID().uuidString, clientId: "fixture", baseUrl: "https://fixture.invalid") }
    private func clean(_ id: String) {
        UserDefaults.standard.removeObject(forKey: "Tracker.\(id).oauth")
        UserDefaults.standard.removeObject(forKey: "Tracker.\(id).token")
        UserDefaults.standard.removeObject(forKey: "Tracker.\(id).user_id")
    }
    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw OAuthSchedulingTimeout.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum OAuthSchedulingTimeout: Error { case expired }
private actor OAuthRefreshBarrier {
    private(set) var started = 0
    private var continuation: CheckedContinuation<OAuthResponse?, Never>?
    func run() async -> OAuthResponse? {
        started += 1
        return await withCheckedContinuation { continuation = $0 }
    }
    func release(_ value: OAuthResponse) { continuation?.resume(returning: value); continuation = nil }
}
