import CoreData
import Foundation
import Testing
import AidokuRunner
@testable import Aidoku

@Suite(.serialized) @MainActor
struct NativeAdapterBoundarySafetyTests {
    @Test func customSourceConfigDecodesSlicesAndRejectsOversizedLengths() throws {
        let config = CustomSourceConfig.komga(.init(key: "slice-key", name: "Slice", server: "https://example.invalid"))
        let encoded = config.encode()
        let wrapped = Data([0xff, 0xff]) + encoded
        #expect(try CustomSourceConfig(from: wrapped[2...]).encode() == encoded)
        // Oversized string length must throw rather than read past the buffer.
        #expect(throws: (any Error).self) { try CustomSourceConfig(from: Data([1] + Array(repeating: UInt8(0xff), count: 9) + [0x01])) }
    }

    /// A local root that cannot be listed must not be treated as "no files" and erase stored series.
    @Test func unreadableRootCannotEraseLocalMetadata() async throws {
        let store = try TemporaryCoreDataStore(configurations: ["Cloud", "Local"])
        defer { store.close() }
        let directory = store.directory
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = store.coordinator
        let writer = LocalFileDataManager(context: context)
        try await writer.commitImport(folder: directory, mangaId: "fixture", mangaTitle: "Fixture", cover: nil,
            description: nil, archive: directory.appendingPathComponent("chapter.cbz"), chapterId: "chapter",
            chapterTitle: "Chapter", volume: nil, chapter: 1, comicInfo: nil)
        let notDirectory = directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: notDirectory)
        let manager = LocalFileManager(dataManager: writer, startsListener: false, localDirectory: notDirectory)
        await manager.scanLocalFiles()
        #expect(await writer.hasSeries(id: "fixture"))
        #expect(await writer.fetchChapters(mangaId: "fixture").map(\.key) == ["chapter"])
    }
}
