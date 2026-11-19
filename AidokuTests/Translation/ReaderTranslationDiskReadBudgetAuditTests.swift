import Foundation
import Testing
@testable import Aidoku

struct ReaderTranslationDiskReadBudgetAuditTests {

    @Test
    func readRemovesCorruptCompressedPayload() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("DiskReadBudgetAudit-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cache = ReaderTranslationDiskCache(directory: directory)
        let generation = await cache.currentGeneration()
        try await cache.store(Data("ATZ2invalid".utf8), for: "broken", kind: .layout, generation: generation)
        #expect(try await cache.data(for: "broken", kind: .layout) == nil)
        #expect(try await cache.contains("broken", kind: .layout) == false)
    }
}
