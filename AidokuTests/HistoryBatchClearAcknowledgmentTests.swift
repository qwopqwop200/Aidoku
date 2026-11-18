import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct HistoryBatchClearAcknowledgmentTests {
    private func fixture(_ body: (URL, NSManagedObjectModel, ChapterIdentifier, ChapterIdentifier) async throws -> Void) async throws {
        let manager = CoreDataManager.shared
        let model = manager.container.managedObjectModel
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("history.sqlite")
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url)
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        let kept = ChapterIdentifier(sourceKey: "batch-clear-fixture", mangaKey: "kept", chapterKey: "1")
        let removed = ChapterIdentifier(sourceKey: "batch-clear-fixture", mangaKey: "outside", chapterKey: "2")
        manager.addToLibrary(manga: AidokuRunner.Manga(sourceKey: kept.sourceKey, key: kept.mangaKey, title: "Kept"),
            chapters: [.init(key: kept.chapterKey)], context: context)
        manager.setProgress(3, chapterId: kept, totalPages: 9, context: context)
        manager.setProgress(4, chapterId: removed, totalPages: 10, context: context)
        try context.save()
        context.reset()
        try coordinator.remove(store)
        try await body(url, model, kept, removed)
    }

    private func open(_ url: URL, model: NSManagedObjectModel, readOnly: Bool) throws -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        _ = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: url,
            options: [NSReadOnlyPersistentStoreOption: readOnly])
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    private func close(_ context: NSManagedObjectContext) throws {
        context.reset()
        let coordinator = try #require(context.persistentStoreCoordinator)
        for store in coordinator.persistentStores { try coordinator.remove(store) }
    }

    @Test func failedSQLiteBatchDeleteKeepsVisibleHistoryAndRetryClearsIt() async throws {
        try await fixture { url, model, kept, removed in
            let manager = CoreDataManager.shared
            let readOnly = try open(url, model: model, readOnly: true)
            let viewModel = HistoryView.ViewModel()
            let section = HistorySection(daysAgo: 0, entries: [
                .init(chapterId: kept, date: Date(timeIntervalSince1970: 100), currentPage: 3, totalPages: 9),
                .init(chapterId: removed, date: Date(timeIntervalSince1970: 101), currentPage: 4, totalPages: 10)
            ])
            viewModel.filteredHistory = [0: section]
            viewModel.loadingState = .complete
            var acknowledged = true
            await viewModel.clearHistory {
                acknowledged = manager.clearHistory(context: readOnly)
                return acknowledged
            }
            #expect(!acknowledged)
            #expect(viewModel.filteredHistory == [0: section])
            #expect(viewModel.loadingState == .complete)
            #expect(try readOnly.count(for: HistoryObject.fetchRequest()) == 2)
            try close(readOnly)

            let writable = try open(url, model: model, readOnly: false)
            #expect(try writable.count(for: HistoryObject.fetchRequest()) == 2)
            await viewModel.clearHistory { manager.clearHistory(context: writable) }
            #expect(viewModel.filteredHistory.isEmpty)
            #expect(viewModel.loadingState == .idle)
            // Batch deletion is durable without a subsequent context.save().
            try close(writable)
            let reopened = try open(url, model: model, readOnly: false)
            defer { try? close(reopened) }
            #expect(try reopened.count(for: HistoryObject.fetchRequest()) == 0)
            #expect(manager.hasLibraryManga(mangaId: kept.mangaIdentifier, context: reopened))
        }
    }

    @Test func excludingLibraryAcknowledgesFailureAndPreservesLibraryHistoryOnSuccess() async throws {
        try await fixture { url, model, kept, removed in
            let manager = CoreDataManager.shared
            let readOnly = try open(url, model: model, readOnly: true)
            #expect(!manager.clearHistoryExcludingLibrary(context: readOnly))
            try close(readOnly)
            let writable = try open(url, model: model, readOnly: false)
            #expect(try writable.count(for: HistoryObject.fetchRequest()) == 2)
            #expect(manager.clearHistoryExcludingLibrary(context: writable))
            try close(writable)
            let reopened = try open(url, model: model, readOnly: false)
            defer { try? close(reopened) }
            #expect(manager.hasHistory(chapterId: kept, context: reopened))
            #expect(!manager.hasHistory(chapterId: removed, context: reopened))
            #expect(manager.getProgress(chapterId: kept, context: reopened).progress == 3)
        }
    }

    @Test func removingChaptersClearsDuplicateRowsAndTheirSessionsOnlyForTheSelectedIdentities() async throws {
        try await fixture { url, model, kept, removed in
            let manager = CoreDataManager.shared
            let context = try open(url, model: model, readOnly: false)
            defer { try? close(context) }
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
    }
}
