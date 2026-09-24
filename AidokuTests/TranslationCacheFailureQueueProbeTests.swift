import Foundation
import Testing
@testable import Aidoku

/// Baseline diagnostic, intentionally asserts the observed unbounded retry contract.
/// Do not keep these expectations as regression acceptance after a bounded redesign.
@Suite(.serialized)
struct TranslationCacheFailureQueueProbeTests {
    @Test func persistentDiskFailureRetainsResultsOutsideMemoryBudget() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("failure-queue-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = try TranslationCache(configuration: .init(maxSizeMiB: 1), storageRootURL: root)
        let directory = root.appendingPathComponent("browser-app/translation-cache-v1")
        try FileManager.default.removeItem(at: directory)
        try Data("blocked-directory".utf8).write(to: directory)
        var keys: [TranslationCacheKey] = []
        let config = RemoteTranslationConfiguration.openAI(model: "local-queue-probe")
        for index in 0..<64 {
            let request = RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "source-\(index)")
            let key = TranslationCacheKey(configuration: config, endpoint: try config.validatedEndpoint(), request: request)
            keys.append(key)
            let value = key.segments.map { RemoteTranslatedSegment(id: $0.id, text: String(repeating: "x", count: 32_768)) }
            await cache.insert(value, for: key)
        }
        let failed = await cache.statistics()
        #expect(failed.pendingDiskWrites == 64)
        #expect(failed.memoryBytes <= 1_048_576)
        #expect(failed.memoryEntries < 64)
        #expect(failed.lastPersistenceFailure != nil)
        // Pending results remain observable even after normal memory-tier eviction.
        let first = try await cache.value(for: keys[0])
        #expect(first?.translations.first?.text.utf8.count == 32_768)
        try FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try await cache.flush()
        let restored = await cache.statistics()
        #expect(restored.pendingDiskWrites == 0)
        #expect(restored.diskBytes <= 1_048_576)
        print("FAILURE_QUEUE pending=\(failed.pendingDiskWrites) logicalTranslationBytes=2097152 memoryChargedBytes=\(failed.memoryBytes) recoveredPending=\(restored.pendingDiskWrites)")
    }
}
