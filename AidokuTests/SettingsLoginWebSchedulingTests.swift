import Foundation
import SwiftUI
import Testing
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct SettingsLoginWebSchedulingTests {
    private func response(_ value: String) -> (Data, URLResponse) {
        (Data(value.utf8), HTTPURLResponse(url: URL(string: "https://settings.invalid/token")!,
                                         statusCode: 200, httpVersion: nil, headerFields: nil)!)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !predicate() {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(1))
        }
    }

    @Test func tokenExchangeOwnsBusyLifetimeAndRejectsSupersededResponse() async throws {
        let owner = SettingsLoginAttempt()
        var oldReply: CheckedContinuation<(Data, URLResponse), Never>?
        var writes: [String] = []
        var errors = 0
        let old = owner.begin()
        owner.exchange(attempt: old, operation: {
            await withCheckedContinuation { oldReply = $0 }
        }, commit: { writes.append($0) }, failed: { errors += 1 })
        try await waitUntil { oldReply != nil }
        #expect(owner.isLoading)
        let latest = owner.begin()
        owner.exchange(attempt: latest, operation: { response("latest") },
                       commit: { writes.append($0) }, failed: { errors += 1 })
        try await waitUntil { writes == ["latest"] }
        #expect(!owner.isLoading)
        oldReply?.resume(returning: response("obsolete"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(writes == ["latest"])
        #expect(errors == 0)
    }

    @Test func logoutRejectsCancellationInsensitiveExchangeCompletion() async throws {
        let owner = SettingsLoginAttempt()
        var reply: CheckedContinuation<(Data, URLResponse), Never>?
        var writes = 0
        var errors = 0
        let attempt = owner.begin()
        owner.exchange(attempt: attempt, operation: {
            await withCheckedContinuation { reply = $0 }
        }, commit: { _ in writes += 1 }, failed: { errors += 1 })
        try await waitUntil { reply != nil }
        owner.cancel()
        #expect(!owner.isLoading)
        reply?.resume(returning: response("stale"))
        try await Task.sleep(for: .milliseconds(20))
        #expect(writes == 0 && errors == 0)
    }

    @Test func productionExchangeCancelsItsURLSessionTransfer() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SettingsTokenURLProtocol.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let url = URL(string: "https://settings-token.invalid/\(UUID().uuidString)")!
        let owner = SettingsLoginAttempt()
        var writes = 0
        owner.exchange(URLRequest(url: url), attempt: owner.begin(), session: session,
                       commit: { _ in writes += 1 }, failed: { writes += 1 })
        try await waitUntil { SettingsTokenURLProtocol.started(url) }
        #expect(owner.isLoading)
        owner.cancel()
        try await waitUntil { SettingsTokenURLProtocol.stopped(url) }
        #expect(!owner.isLoading && writes == 0)
    }

    @Test func cookieBurstCoalescesAndDismantleRejectsPendingExtraction() async throws {
        var cookies: [String: String] = [:]
        var storage: [String: String] = [:]
        var cookieWrites = 0
        var storageWrites = 0
        let parent = Aidoku.WebView(URL(string: "https://settings.invalid")!, localStorageKeys: ["session"],
                             cookies: Binding(get: { cookies }, set: { cookies = $0; cookieWrites += 1 }),
                             localStorage: Binding(get: { storage }, set: { storage = $0; storageWrites += 1 }))
        var calls = 0
        var pending: [CheckedContinuation<Aidoku.WebView.Coordinator.Snapshot, Never>] = []
        let coordinator = Aidoku.WebView.Coordinator(parent: parent, extract: { _, _, _ in
            calls += 1
            return await withCheckedContinuation { pending.append($0) }
        })
        let webView = WKWebView()
        coordinator.startObserving(webView)
        coordinator.requestRefresh()
        try await waitUntil { pending.count == 1 }
        for _ in 0..<100 { coordinator.requestRefresh() }
        #expect(calls == 1)
        pending[0].resume(returning: (["session": "obsolete"], ["session": "obsolete"]))
        try await waitUntil { pending.count == 2 }
        #expect(cookieWrites == 0 && storageWrites == 0)
        pending[1].resume(returning: (["session": "latest"], ["session": "latest"]))
        try await waitUntil { cookieWrites == 1 }
        #expect(calls == 2 && storageWrites == 1)
        coordinator.requestRefresh()
        try await waitUntil { pending.count == 3 }
        Aidoku.WebView.dismantleUIView(webView, coordinator: coordinator)
        pending[2].resume(returning: (["session": "after-close"], [:]))
        try await Task.sleep(for: .milliseconds(20))
        #expect(cookies == ["session": "latest"] && storage == ["session": "latest"])
        #expect(cookieWrites == 1 && storageWrites == 1)
    }

    @Test func refreshBurstDrainsOneOperationThenRunsOnlyLatestAndStopsOnExit() async throws {
        let owner = SettingsRefreshScheduler()
        var gate: CheckedContinuation<Int, Never>?
        var starts = 0
        var commits: [Int] = []
        owner.request(operation: {
            starts += 1
            return await withCheckedContinuation { gate = $0 }
        }, commit: { commits.append($0) })
        try await waitUntil { gate != nil }
        for index in 0..<100 {
            owner.request(operation: { starts += 1; return index }, commit: { commits.append($0) })
        }
        #expect(starts == 1)
        gate?.resume(returning: -1)
        try await waitUntil { commits == [99] }
        #expect(starts == 2)
        var exitGate: CheckedContinuation<Int, Never>?
        owner.request(operation: {
            await withCheckedContinuation { exitGate = $0 }
        }, commit: { commits.append($0) })
        try await waitUntil { exitGate != nil }
        owner.cancel()
        exitGate?.resume(returning: -2)
        try await Task.sleep(for: .milliseconds(20))
        #expect(commits == [99])
    }

    private final class NavigationRecorder: WKWebView {
        var loads: [URL] = []
        override func load(_ request: URLRequest) -> WKNavigation? {
            if let url = request.url { loads.append(url) }
            return nil
        }
    }

    @Test func navigationPreparationIsSupersededAndCanBeCancelled() async throws {
        let webView = NavigationRecorder()
        var first: CheckedContinuation<Void, Never>?
        let urlA = URL(string: "https://settings.invalid/a")!
        let urlB = URL(string: "https://settings.invalid/b")!
        webView.loadSourceRequest(URLRequest(url: urlA), configure: { _ in
            await withCheckedContinuation { first = $0 }
        })
        try await waitUntil { first != nil }
        webView.loadSourceRequest(URLRequest(url: urlB), configure: { _ in })
        try await waitUntil { webView.loads == [urlB] }
        first?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(webView.loads == [urlB])
        var last: CheckedContinuation<Void, Never>?
        webView.loadSourceRequest(URLRequest(url: urlA), configure: { _ in
            await withCheckedContinuation { last = $0 }
        })
        try await waitUntil { last != nil }
        webView.cancelSourceRequest()
        last?.resume()
        try await Task.sleep(for: .milliseconds(20))
        #expect(webView.loads == [urlB])
    }
}


private final class SettingsTokenURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var starts: Set<URL> = []
    private static var stops: Set<URL> = []
    static func started(_ url: URL) -> Bool { lock.withLock { starts.contains(url) } }
    static func stopped(_ url: URL) -> Bool { lock.withLock { stops.contains(url) } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "settings-token.invalid" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if let url = request.url { _ = Self.lock.withLock { Self.starts.insert(url) } }
    }
    override func stopLoading() {
        if let url = request.url { _ = Self.lock.withLock { Self.stops.insert(url) } }
    }
}
