import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct TranslationDiskEvictionFailureTests {
    @Test func failedFileDeletionKeepsDiskAccountingAndRetriesSameVictim() async throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent("eviction-failure-" + UUID().uuidString)
        let directory = root.appendingPathComponent("browser-app/translation-cache-v1")
        defer {
            try? files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            try? files.removeItem(at: root)
        }
        let cache = try TranslationCache(configuration: .init(memoryEnabled: false, maxSizeMiB: 1), storageRootURL: root)
        let config = RemoteTranslationConfiguration.openAI(model: "local-eviction-regression")
        let endpoint = try config.validatedEndpoint()
        let keys = (0..<3).map { index in
            TranslationCacheKey(configuration: config, endpoint: endpoint,
                request: RemoteTranslationRequest(sourceLanguage: "ja", targetLanguage: "ko", sourceText: "page-\(index)"))
        }
        let values = keys.enumerated().map { index, key in
            key.segments.map { RemoteTranslatedSegment(id: $0.id, text: String(repeating: "\(index)", count: 400_000)) }
        }
        await cache.insert(values[0], for: keys[0])
        await cache.insert(values[1], for: keys[1])
        let before = await cache.statistics()
        #expect(before.diskEntries == 2)
        #expect(before.pendingDiskWrites == 0)
        let originalFiles = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let originalBytes = try Dictionary(uniqueKeysWithValues: originalFiles.map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
        #expect(originalBytes.count == 2)

        // Exercise the real filesystem failure, not a mock returning a chosen error.
        // Verify this runtime enforces the directory permission before claiming coverage.
        let permissionProbe = directory.appendingPathComponent("permission-probe")
        try Data([1]).write(to: permissionProbe)
        try files.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)
        var deletionDenied = false
        do { try files.removeItem(at: permissionProbe) } catch { deletionDenied = true }
        try #require(deletionDenied, "This runtime must enforce directory unlink permissions for the regression")

        // 3 x400,000-byte translations cannot fit in1MiB: insertion must evict the first record.
        await cache.insert(values[2], for: keys[2])
        let failed = await cache.statistics()
        #expect(failed.lastPersistenceFailure != nil)
        #expect(failed.pendingDiskWrites == 1)
        #expect(failed.diskEntries == before.diskEntries)
        #expect(failed.diskBytes == before.diskBytes)
        for (name, bytes) in originalBytes {
            #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes)
        }

        // After repair the same victim is removed; no orphan record escapes the budget.
        try files.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        try files.removeItem(at: permissionProbe)
        try await cache.flush()
        let recovered = await cache.statistics()
        #expect(recovered.pendingDiskWrites == 0)
        #expect(recovered.lastPersistenceFailure == nil)
        #expect(recovered.diskEntries == 2)
        #expect(recovered.diskBytes <= 1_048_576)
        let actualFiles = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let actualBytes = try actualFiles.reduce(0) { try $0 + Data(contentsOf: $1).count }
        #expect(actualFiles.count == recovered.diskEntries)
        #expect(actualBytes == recovered.diskBytes)
        #expect(try await cache.value(for: keys[0]) == nil)
        #expect(try await cache.value(for: keys[1])?.translations == values[1])
        #expect(try await cache.value(for: keys[2])?.translations == values[2])

        // Reopening the real directory must agree with in-process accounting and results.
        let reopened = try TranslationCache(configuration: .init(memoryEnabled: false, maxSizeMiB: 1), storageRootURL: root)
        #expect(await reopened.statistics().diskBytes == recovered.diskBytes)
        #expect(try await reopened.value(for: keys[0]) == nil)
        #expect(try await reopened.value(for: keys[1])?.translations == values[1])
        #expect(try await reopened.value(for: keys[2])?.translations == values[2])

        // An externally removed LRU file is a successful eviction, not a storage
        // failure. This preserves the pre-existing already-absent-file contract.
        let survivingOriginalFiles = originalFiles.filter { files.fileExists(atPath: $0.path) }
        try #require(survivingOriginalFiles.count == 1)
        try files.removeItem(at: survivingOriginalFiles[0])
        await cache.insert(values[0], for: keys[0])
        let missingRecovered = await cache.statistics()
        #expect(missingRecovered.lastPersistenceFailure == nil)
        #expect(missingRecovered.pendingDiskWrites == 0)
        #expect(missingRecovered.diskEntries == 2)
        #expect(try await cache.value(for: keys[1]) == nil)
        #expect(try await cache.value(for: keys[0])?.translations == values[0])
        #expect(try await cache.value(for: keys[2])?.translations == values[2])
        let finalFiles = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
        let finalBytes = try finalFiles.reduce(0) { try $0 + Data(contentsOf: $1).count }
        #expect(finalFiles.count == missingRecovered.diskEntries)
        #expect(finalBytes == missingRecovered.diskBytes)
    }
}
