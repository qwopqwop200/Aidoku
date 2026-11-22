import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

/// Reading-history data correctness: no lost, duplicated, or wrongly deleted records.
@Suite(.serialized) @MainActor
struct HistoryDataTests {
    /// Concurrent change notifications during pagination must not duplicate rows or grow the offset.
    @Test func historyChangesDuringPaginationDoNotDuplicateRows() async throws {
        let fixture = try TemporaryCoreDataStore(configurations: ["Cloud", "Local"])
        defer { fixture.close() }
        let existing = try fixture.insertHistory("existing", secondsAgo: 300)
        let initial = fixture.readHistory([existing])
        let gate = HistoryPageGate()
        let model = HistoryView.ViewModel(historyPageLoader: { _, _ in await gate.wait() },
            historyIdentityLoader: { ids in await fixture.readHistory(ids) }, observesNotifications: false)
        let page = Task { await model.loadMore() }
        try await RegressionTestWait.until { gate.started }
        let a = try fixture.insertHistory("A", secondsAgo: 200)
        let b = try fixture.insertHistory("B", secondsAgo: 100)
        var entered = 0
        let first = Task { entered += 1; await model.receiveHistoryChange(chapterIds: [a]) }
        let second = Task { entered += 1; await model.receiveHistoryChange(chapterIds: [b]) }
        try await RegressionTestWait.until { entered == 2 }
        gate.release(initial)
        await page.value
        await first.value
        await second.value
        #expect(Set(model.loadedHistoryIdentifiers) == [existing, a, b])
        #expect(model.loadedHistoryIdentifiers.count == 3)
        #expect(model.paginationOffset == 3)
        await model.receiveHistoryChange(chapterIds: [a, a, b])
        #expect(model.loadedHistoryIdentifiers.count == 3)
        #expect(model.paginationOffset == 3)
    }

    @Test func removingChaptersDeletesDuplicateRowsAndSessionsOnlyForTheSelectedIdentities() throws {
        let fixture = try TemporaryCoreDataStore()
        defer { fixture.close() }
        let context = fixture.context
        let manager = CoreDataManager.shared
        let kept = ChapterIdentifier(sourceKey: "batch-clear-fixture", mangaKey: "kept", chapterKey: "1")
        let removed = ChapterIdentifier(sourceKey: "batch-clear-fixture", mangaKey: "outside", chapterKey: "2")
        manager.setProgress(3, chapterId: kept, totalPages: 9, context: context)
        manager.setProgress(4, chapterId: removed, totalPages: 10, context: context)
        let duplicate = HistoryObject(context: context)
        duplicate.sourceId = removed.sourceKey
        duplicate.mangaId = removed.mangaKey
        duplicate.chapterId = removed.chapterKey
        let session = ReadingSessionObject(context: context)
        session.startDate = Date()
        session.endDate = Date()
        session.history = duplicate
        let otherManga = ChapterIdentifier(sourceKey: removed.sourceKey, mangaKey: kept.mangaKey, chapterKey: removed.chapterKey)
        let otherSource = ChapterIdentifier(sourceKey: UUID().uuidString, mangaKey: removed.mangaKey, chapterKey: removed.chapterKey)
        manager.setProgress(1, chapterId: otherManga, context: context)
        manager.setProgress(2, chapterId: otherSource, context: context)
        try context.save()
        context.reset()

        try manager.removeHistory(chapterIds: [removed], context: context)
        try context.save()
        context.reset()
        #expect(!manager.hasHistory(chapterId: removed, context: context))
        #expect(try context.count(for: ReadingSessionObject.fetchRequest()) == 0)
        #expect(manager.hasHistory(chapterId: kept, context: context))
        #expect(manager.hasHistory(chapterId: otherManga, context: context))
        #expect(manager.hasHistory(chapterId: otherSource, context: context))
    }

    /// A retried save after an optimistic-locking conflict must keep the concurrent writer's changes.
    @Test func progressRetryRetainsConcurrentCompletionAndSession() throws {
        let fixture = try TemporaryCoreDataStore()
        defer { fixture.close() }
        let manager = CoreDataManager.shared
        let writer = fixture.context
        let competing = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        competing.persistentStoreCoordinator = fixture.coordinator
        let manga = AidokuRunner.Manga(sourceKey: "conflict-fixture", key: UUID().uuidString, title: "Original")
        manager.addToLibrary(manga: manga, chapters: [.init(key: "chapter")], context: writer)
        let chapter = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "chapter")
        manager.setProgress(1, chapterId: chapter, totalPages: 9, context: writer)
        try writer.save()
        let session = HistoryManager.ReadingSessionData(startDate: Date(timeIntervalSince1970: 100),
                                                       endDate: Date(timeIntervalSince1970: 120), pagesRead: 2)
        var attempts = 0
        try HistoryManager.saveMutationWithRetry(context: writer) {
            attempts += 1
            manager.setRead(mangaId: manga.identifier, context: writer)
            let history = manager.setProgress(3, chapterId: chapter, totalPages: 9, scrollPosition: 0.5, context: writer)
            manager.createSession(history: history, data: session, context: writer)
            if attempts == 1 {
                manager.setCompleted(chapterIds: [chapter], context: competing)
                try competing.save()
            }
            return true
        }
        #expect(attempts == 2)
        writer.reset()
        let history = try #require(manager.getHistory(chapterId: chapter, context: writer))
        #expect(history.completed)
        #expect(history.progress == 3 && history.total == 9)
        #expect(history.scrollPosition?.doubleValue == 0.5)
        #expect(try writer.count(for: ReadingSessionObject.fetchRequest()) == 1)
    }

    /// Batched completion must reuse existing rows, link new rows to chapters and not duplicate repeated IDs.
    @Test func setCompletedReusesAndLinksHistoryAcrossBatches() throws {
        let fixture = try TemporaryCoreDataStore()
        defer { fixture.close() }
        let context = fixture.context
        let manager = CoreDataManager.shared
        let manga = AidokuRunner.Manga(sourceKey: "complete-fixture", key: "manga", title: "Title")
        manager.addToLibrary(manga: manga, chapters: (0..<600).map { .init(key: "\($0)") }, context: context)
        let ids = (0..<601).map { ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: "\($0)") }
        manager.setProgress(2, chapterId: ids[0], context: context)
        try context.save()
        #expect(manager.setCompleted(chapterIds: ids + [ids[1]], context: context))
        try context.save()
        context.reset()
        #expect(try context.count(for: HistoryObject.fetchRequest()) == 601)
        let first = try #require(manager.getHistory(chapterId: ids[0], context: context))
        #expect(first.completed && first.progress == 2 && first.chapter != nil)
        #expect(manager.getHistory(chapterId: ids[599], context: context)?.chapter != nil)
        #expect(manager.getHistory(chapterId: ids[600], context: context)?.completed == true)
        #expect(manager.getHistory(chapterId: ids[600], context: context)?.chapter == nil)
    }

    // MARK: Metadata cache (persisted on disk)

    @Test func metadataCacheRestoresOnlyTheRequestedChapterAfterReopen() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryMetadataCache(directory: root)
        var manga = AidokuRunner.Manga(sourceKey: "source-a", key: "manga", title: "Stored title", cover: "https://example.invalid/cover")
        manga.chapters = (0..<1000).map { .init(key: "other-\($0)") }
        let chapter = AidokuRunner.Chapter(key: "one", title: "Chapter 1")
        cache.store(manga: manga, chapters: [chapter], generation: cache.generation)
        let id = ChapterIdentifier(sourceKey: "source-a", mangaKey: "manga", chapterKey: "one")
        let reopened = HistoryMetadataCache(directory: root)
        let result = reopened.load(chapterIds: [id])
        #expect(result.manga[id.mangaIdentifier]?.title == manga.title)
        #expect(result.manga[id.mangaIdentifier]?.cover == manga.cover)
        #expect(result.manga[id.mangaIdentifier]?.chapters == nil)
        #expect(result.chapters[id] == chapter)
        #expect(reopened.load(chapterIds: [.init(sourceKey: "source-b", mangaKey: "manga", chapterKey: "one")]).manga.isEmpty)
    }

    @Test func metadataCacheBoundsDiskSizeAndTreatsCorruptFilesAsMisses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let cache = HistoryMetadataCache(directory: root, maxBytes: 1800)
        let ids = (0..<20).map { ChapterIdentifier(sourceKey: "s", mangaKey: "m\($0)", chapterKey: "one") }
        for id in ids {
            cache.store(manga: .init(sourceKey: id.sourceKey, key: id.mangaKey, title: String(repeating: "title", count: 30)),
                        chapters: [.init(key: "one")], generation: cache.generation)
        }
        let file = root.appendingPathComponent("metadata.json")
        #expect(try Data(contentsOf: file).count <= 1800)
        try Data("{bad json".utf8).write(to: file)
        #expect(cache.load(chapterIds: ids).chapters.isEmpty)
        try Data(repeating: 32, count: 1801).write(to: file)
        #expect(cache.load(chapterIds: ids).chapters.isEmpty)
    }
}

private extension TemporaryCoreDataStore {
    func insertHistory(_ key: String, secondsAgo: TimeInterval) throws -> ChapterIdentifier {
        let id = ChapterIdentifier(sourceKey: "identity-event-fixture", mangaKey: key, chapterKey: "chapter")
        let manager = CoreDataManager.shared
        manager.addToLibrary(manga: AidokuRunner.Manga(sourceKey: id.sourceKey, key: key, title: key),
                             chapters: [.init(key: id.chapterKey)], context: context)
        manager.setProgress(1, chapterId: id, totalPages: 10, context: context)
        manager.getHistory(chapterId: id, context: context)?.dateRead = Date().addingTimeInterval(-secondsAgo)
        try context.save()
        return id
    }

    func readHistory(_ ids: [ChapterIdentifier]) -> HistoryView.ViewModel.HistoryBatch {
        HistoryView.ViewModel.readIdentityHistoryBatch(chapterIds: ids, context: context)
    }
}

@MainActor
private final class HistoryPageGate {
    private(set) var started = false
    private var waiter: CheckedContinuation<HistoryView.ViewModel.HistoryBatch, Never>?
    func wait() async -> HistoryView.ViewModel.HistoryBatch {
        started = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func release(_ batch: HistoryView.ViewModel.HistoryBatch) { waiter?.resume(returning: batch); waiter = nil }
}
