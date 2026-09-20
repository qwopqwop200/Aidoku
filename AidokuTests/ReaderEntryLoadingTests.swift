import AidokuRunner
import CoreData
import Foundation
import Nuke
import Testing
@testable import Aidoku

@MainActor
struct ReaderEntryLoadingTests {
    @Test func historyMetadataPreservesIdentityAndMissingRecordsAcrossBatches() throws {
        try withDatabase { context in
            var ids: [ChapterIdentifier] = []
            for index in 0..<205 {
                // Reuse manga/chapter keys across sources to catch cross-source matches.
                let source = "source-\(index % 2)"
                let mangaKey = "manga-\(index / 2)"
                let manga = MangaObject(context: context)
                manga.load(from: AidokuRunner.Manga(sourceKey: source, key: mangaKey, title: "title-\(index)"))
                let id = ChapterIdentifier(sourceKey: source, mangaKey: mangaKey, chapterKey: "chapter")
                let chapter = ChapterObject(context: context)
                chapter.load(from: AidokuRunner.Chapter(key: id.chapterKey, title: "chapter-\(index)"), mangaId: id.mangaIdentifier)
                ids.append(id)
            }
            try context.save()
            context.reset()
            let missing = ChapterIdentifier(sourceKey: "missing", mangaKey: "manga-0", chapterKey: "chapter")
            let missingChapter = ChapterIdentifier(sourceKey: "source-0", mangaKey: "manga-0", chapterKey: "missing")
            let batch = HistoryMetadataBatch.load(chapterIds: ids + ids + [missing, missingChapter], context: context)
            #expect(batch.manga.count == 205)
            #expect(batch.chapters.count == 205)
            #expect(batch.manga[missing.mangaIdentifier] == nil)
            #expect(batch.chapters[missingChapter] == nil)
            for (index, id) in ids.enumerated() {
                #expect(batch.manga[id.mangaIdentifier]?.title == "title-\(index)")
                #expect(batch.chapters[id]?.title == "chapter-\(index)")
                #expect(batch.manga[id.mangaIdentifier]?.chapters == nil)
            }
            #expect(HistoryMetadataBatch.load(chapterIds: [], context: context).manga.isEmpty)
        }
    }

    @Test func historyMetadataSQLiteBeforeAfter() throws {
        try withDatabase { context in
            var ids: [ChapterIdentifier] = []
            for index in 0..<100 {
                let mangaId = MangaIdentifier(sourceKey: "benchmark", mangaKey: "manga-\(index / 5)")
                if index % 5 == 0 {
                    let manga = MangaObject(context: context)
                    manga.load(from: AidokuRunner.Manga(sourceKey: mangaId.sourceKey, key: mangaId.mangaKey, title: mangaId.mangaKey))
                }
                let chapter = ChapterObject(context: context)
                chapter.load(from: AidokuRunner.Chapter(key: "chapter-\(index)"), mangaId: mangaId)
                ids.append(ChapterIdentifier(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: "chapter-\(index)"))
            }
            try context.save()
            var oldTimes: [Double] = []
            var newTimes: [Double] = []
            for _ in 0..<5 {
                context.reset()
                let oldStart = ProcessInfo.processInfo.systemUptime
                var old = HistoryMetadataBatch()
                for id in ids {
                    let mangaRequest = MangaObject.fetchRequest()
                    mangaRequest.fetchLimit = 1
                    mangaRequest.predicate = NSPredicate(format: "sourceId == %@ AND id == %@", id.sourceKey, id.mangaKey)
                    old.manga[id.mangaIdentifier] = try context.fetch(mangaRequest).first?.toNewManga()
                    let chapterRequest = ChapterObject.fetchRequest()
                    chapterRequest.fetchLimit = 1
                    chapterRequest.predicate = NSPredicate(
                        format: "id == %@ AND mangaId == %@ AND sourceId == %@", id.chapterKey, id.mangaKey, id.sourceKey
                    )
                    old.chapters[id] = try context.fetch(chapterRequest).first?.toNewChapter()
                }
                oldTimes.append((ProcessInfo.processInfo.systemUptime - oldStart) * 1_000)
                context.reset()
                let newStart = ProcessInfo.processInfo.systemUptime
                let batch = HistoryMetadataBatch.load(chapterIds: ids, context: context)
                newTimes.append((ProcessInfo.processInfo.systemUptime - newStart) * 1_000)
                #expect(batch.manga == old.manga)
                #expect(batch.chapters == old.chapters)
            }
            print("HISTORY_METADATA_SQLITE_100 old_ms=\(oldTimes) new_ms=\(newTimes)")
        }
    }

    @Test func historyDiskMetadataFillsMissingRowsWithoutReplacingDatabaseValues() throws {
        try withDatabase { context in
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: directory) }
            let cache = HistoryMetadataCache(directory: directory)
            let id = ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: "one")
            let cached = AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "Cached")
            cache.store(manga: cached, chapters: [.init(key: "one", title: "Cached chapter")], generation: cache.generation)
            let reopened = HistoryMetadataCache(directory: directory)
            let fromDisk = HistoryMetadataBatch.load(chapterIds: [id], context: context, cache: reopened)
            #expect(fromDisk.manga[id.mangaIdentifier]?.title == "Cached")
            #expect(fromDisk.chapters[id]?.title == "Cached chapter")
            let manga = MangaObject(context: context)
            manga.load(from: .init(sourceKey: id.sourceKey, key: id.mangaKey, title: "Database"))
            let chapter = ChapterObject(context: context)
            chapter.load(from: .init(key: "one", title: "Database chapter"), mangaId: id.mangaIdentifier)
            try context.save()
            context.reset()
            let fromDatabase = HistoryMetadataBatch.load(chapterIds: [id], context: context, cache: reopened)
            #expect(fromDatabase.manga[id.mangaIdentifier]?.title == "Database")
            #expect(fromDatabase.chapters[id]?.title == "Database chapter")
        }
    }

    @Test func visiblePagesStartFirstWithoutExpandingTheWindow() {
        #expect(ReaderPageLoadOrder.indices(in: 8...14, pageCount: 100, currentPage: 10, visible: [10, 11]) == [10, 11, 9, 12, 8, 13, 14])
        #expect(ReaderPageLoadOrder.indices(in: -2...3, pageCount: 2, currentPage: 1, visible: []) == [1, 2])
        #expect(ReaderPageLoadOrder.indices(in: 8...10, pageCount: 7, currentPage: 8, visible: []).isEmpty)
        #expect(ReaderPageLoadOrder.indices(in: 1...10, pageCount: 0, currentPage: 1, visible: []).isEmpty)
    }

    @Test func coverRequestIsAvailableWithoutWaitingForViewTask() {
        let url = "https://example.invalid/cover.jpg"
        #expect(SourceImageView(imageUrl: url).resolvedImageRequest?.url?.absoluteString == url)
        let file = "file:///tmp/cover.jpg"
        #expect(SourceImageView(imageUrl: file).resolvedImageRequest?.url?.absoluteString == file)
    }

    private func withDatabase(_ body: (NSManagedObjectContext) throws -> Void) throws {
        // Reuse the immutable model, but keep all fixture rows in a separate
        // coordinator/store. Loading another model duplicates class registration.
        let model = CoreDataManager.shared.container.managedObjectModel
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(
            ofType: NSSQLiteStoreType, configurationName: "Cloud", at: root.appendingPathComponent("test.sqlite")
        )
        defer { try? coordinator.remove(store) }
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        try body(context)
    }
}
