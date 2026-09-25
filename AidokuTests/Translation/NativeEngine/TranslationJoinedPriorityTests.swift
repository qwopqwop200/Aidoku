import Foundation
import Testing
@testable import Aidoku

struct TranslationJoinedPriorityTests {
    @Test(arguments: [false, true])
    func joinedForegroundPriorityAppliesOnlyWhileItsConsumerIsAlive(cancelJoined: Bool) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("joined-priority-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 1)
        let marker = JoinedPriorityMarker()
        let blocker = Task { try await limiter.withPermit { await marker.start(); try await Task.sleep(for: .seconds(30)) } }
        defer { blocker.cancel() }
        try await waitUntil { await marker.started }
        let client = JoinedPriorityClient()
        let service = TranslationService(client: client, cache: try TranslationCache(storageRootURL: root), providerRequestLimiter: limiter)
        let configuration = RemoteTranslationConfiguration.openAI(model: "joined-priority-fixture")
        let earlier = Task { try await service.translate(request("other", id: "other-id"), configuration: configuration, priority: .prefetch) }
        defer { earlier.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 1 }
        let shared = Task { try await service.translate(request("shared", id: "old-id"), configuration: configuration, priority: .metadata(.tag)) }
        defer { shared.cancel() }
        try await waitUntil { await limiter.queuedRequestCount == 2 }
        let foreground = Task { try await service.translate(request("shared", id: "visible-id"), configuration: configuration, priority: .foreground) }
        defer { foreground.cancel() }
        try await waitUntil { await service.inFlightConsumerCount == 3 }
        if cancelJoined {
            foreground.cancel()
            await #expect(throws: CancellationError.self) { try await foreground.value }
            try await waitUntil { await service.inFlightConsumerCount == 2 }
        }
        blocker.cancel()
        _ = try? await blocker.value
        let result = try await shared.value
        #expect(result.translations.map(\.id) == ["old-id"])
        #expect(result.translations.map(\.text) == ["translated shared"])
        _ = try await earlier.value
        if !cancelJoined { #expect(try await foreground.value.translations.map(\.id) == ["visible-id"]) }
        #expect(await client.calls == (cancelJoined ? ["other", "shared"] : ["shared", "other"]))
        #expect(await client.calls.count == 2, "Joined consumers must share one actual provider operation")
    }

    private func request(_ text: String, id: String) -> RemoteTranslationRequest {
        .init(sourceLanguage: "en", targetLanguage: "ko", segments: [.init(id: id, text: text)])
    }

    private func waitUntil(_ predicate: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !(await predicate()) {
            guard ContinuousClock.now < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private actor JoinedPriorityMarker {
    private(set) var started = false
    func start() { started = true }
}

private actor JoinedPriorityClient: RemoteTranslating {
    private(set) var calls: [String] = []
    func translate(_ request: RemoteTranslationRequest,
                   configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        calls.append(request.segments[0].text)
        return .init(translations: request.segments.map { .init(id: $0.id, text: "translated " + $0.text) },
                     source: .network, providerRequestID: nil)
    }
}
