import Foundation
import Testing
@testable import Aidoku

/// Regression contract for the proposed failure-only admission breaker.
/// STAGED ONLY: requires the root-integrated admission guard in TranslationService.
@Suite(.serialized)
struct CachePersistenceAdmissionTests {
    @Test func failedStorageStopsNewRequestsButPreservesCompletedResultsAndRecovers() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("admission-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try TranslationCache(configuration: .init(maxSizeMiB: 1), storageRootURL: root)
        let client = PersistenceAdmissionClient()
        let service = TranslationService(client: client, cache: cache,
            providerRequestLimiter: TranslationProviderRequestLimiter(maximumConcurrentRequests: 1))
        let config = RemoteTranslationConfiguration.openAI(model: "admission-probe")
        let directory = root.appendingPathComponent("browser-app/translation-cache-v1")
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        var completed: [(RemoteTranslationRequest, RemoteTranslationBatchResult)] = []
        var blockedRequest: RemoteTranslationRequest?
        for index in 0..<64 {
            let request = Self.request(index)
            do {
                let value = try await service.translate(request, configuration: config)
                completed.append((request, value))
            } catch TranslationCacheError.persistenceFailure {
                blockedRequest = request
                break
            }
        }
        let blocked = try #require(blockedRequest)
        #expect(!completed.isEmpty)
        #expect(completed.count < 64)
        let countAtBlock = await client.calls
        #expect(countAtBlock == completed.count)
        // Repeated requests cannot accumulate additional successful provider answers.
        for _ in 0..<3 {
            await #expect(throws: TranslationCacheError.persistenceFailure) {
                _ = try await service.translate(blocked, configuration: config)
            }
        }
        #expect(await client.calls == countAtBlock)
        // Includes the earliest result after the bounded memory tier has evicted it.
        for (request, result) in completed {
            let cached = try await service.translate(request, configuration: config)
            #expect(cached.translations == result.translations)
        }
        #expect(await client.calls == countAtBlock)
        let cancelled = Task { () throws -> RemoteTranslationBatchResult in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await service.translate(blocked, configuration: config)
        }
        await #expect(throws: CancellationError.self) { _ = try await cancelled.value }
        #expect(await client.calls == countAtBlock)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Admission itself retries persistence; no explicit flush is required.
        let resumed = try await service.translate(blocked, configuration: config)
        #expect(resumed.translations.map(\.text) == [String(repeating: "x", count: 32_768)])
        #expect(await client.calls == countAtBlock + 1)
        #expect(await cache.statistics().pendingDiskWrites == 0)
    }

    @Test func healthyStorageAndDisabledDiskKeepNormalResults() async throws {
        for diskEnabled in [true, false] {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("healthy-" + UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: root) }
            let cache = try TranslationCache(configuration: .init(diskEnabled: diskEnabled, maxSizeMiB: 1), storageRootURL: root)
            let client = PersistenceAdmissionClient()
            let service = TranslationService(client: client, cache: cache)
            let config = RemoteTranslationConfiguration.openAI(model: "admission-probe")
            for index in 0..<64 {
                let value = try await service.translate(Self.request(index), configuration: config)
                #expect(value.translations.map(\.text) == [String(repeating: "x", count: 32_768)])
            }
            #expect(await client.calls == 64)
            let actualRequests = await client.requests
            let expectedRequests = (0..<64).map { Self.request($0).canonicalizedForTranslationSemantics().request }
            #expect(actualRequests == expectedRequests)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            let actualPayloads = try encoder.encode(actualRequests)
            let expectedPayloads = try encoder.encode(expectedRequests)
            #expect(actualPayloads == expectedPayloads)
            #expect(await cache.statistics().pendingDiskWrites == 0)
        }
    }

    private static func request(_ index: Int) -> RemoteTranslationRequest {
        .init(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "source-\(index)")
    }
}

private actor PersistenceAdmissionClient: RemoteTranslating {
    private(set) var calls = 0
    private(set) var requests: [RemoteTranslationRequest] = []
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        try Task.checkCancellation()
        calls += 1
        requests.append(request)
        return .init(translations: request.segments.map { .init(id: $0.id, text: String(repeating: "x", count: 32_768)) },
            source: .network, providerRequestID: nil)
    }
}
