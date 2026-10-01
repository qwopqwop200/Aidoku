import Foundation
import Testing
@testable import Aidoku

struct NativeTranslationCacheIdentityAuditTests {
    private func equivalentKeys(_ kind: String) throws -> (TranslationCacheKey, TranslationCacheKey) {
        let config = RemoteTranslationConfiguration.openAI(model: "identity-audit")
        let endpoint = try config.validatedEndpoint()
        func key(_ text: String, _ zero: Double) -> TranslationCacheKey {
            TranslationCacheKey(configuration: config, endpoint: endpoint,
                request: .init(sourceLanguage: "ja", targetLanguage: "ko",
                    segments: [.init(id: "caller", text: text, bounds: [zero, 0, 0.5, 0.5])]))
        }
        return kind == "unicode" ? (key("caf\u{00e9}", 0), key("cafe\u{0301}", 0))
            : (key("source", 0), key("source", -Double.zero))
    }

    private func answers(_ text: String) -> [RemoteTranslatedSegment] {
        [.init(id: "segment-0", text: text)]
    }

    private func directory(_ root: URL) -> URL {
        root.appendingPathComponent("browser-app/translation-cache-v1")
    }

    private func records(_ root: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory(root), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "json" }
    }

    @Test(arguments: ["unicode", "signedZero"])
    func equalKeyReplacementKeepsOnePersistentRecordAcrossRelaunch(_ kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let (first, equal) = try equivalentKeys(kind)
        #expect(first == equal)
        let cache = try TranslationCache(configuration: .init(memoryEnabled: false), storageRootURL: root)
        await cache.insert(answers("이전 답변"), for: first)
        await cache.insert(answers("새 답변"), for: equal)
        #expect(try records(root).count == 1)
        #expect(await cache.statistics().diskEntries == 1)
        let reopened = try TranslationCache(configuration: .init(memoryEnabled: false), storageRootURL: root)
        #expect(try await reopened.value(for: first)?.translations == answers("새 답변"))
        #expect(try await reopened.value(for: equal)?.translations == answers("새 답변"))
        let file = try #require(records(root).first)
        let persistedBytes = try Data(contentsOf: file).count
        #expect(await reopened.statistics().diskBytes == persistedBytes)
    }

    @Test(arguments: ["unicode", "signedZero"])
    func legacyDuplicateEqualKeysKeepNewestRecordAndExactDiskCharge(_ kind: String) async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let other = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: other)
        }
        let (first, equal) = try equivalentKeys(kind)
        let configuration = TranslationCacheConfiguration(memoryEnabled: false)
        let cache = try TranslationCache(configuration: configuration, storageRootURL: root)
        let second = try TranslationCache(configuration: configuration, storageRootURL: other)
        await cache.insert(answers("이전 답변"), for: first)
        await second.insert(answers("최신 답변"), for: equal)
        let oldFile = try #require(records(root).first)
        let newFile = try #require(records(other).first)
        #expect(oldFile.lastPathComponent != newFile.lastPathComponent)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1)], ofItemAtPath: oldFile.path)
        let destination = directory(root).appendingPathComponent(newFile.lastPathComponent)
        try FileManager.default.copyItem(at: newFile, to: destination)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 2)], ofItemAtPath: destination.path)

        let reopened = try TranslationCache(configuration: configuration, storageRootURL: root)
        #expect(try records(root).count == 1)
        #expect(try await reopened.value(for: first)?.translations == answers("최신 답변"))
        #expect(await reopened.statistics().diskEntries == 1)
        let persistedBytes = try Data(contentsOf: destination).count
        #expect(await reopened.statistics().diskBytes == persistedBytes)
        let restartedAgain = try TranslationCache(configuration: configuration, storageRootURL: root)
        #expect(try await restartedAgain.value(for: equal)?.translations == answers("최신 답변"))
    }
}
