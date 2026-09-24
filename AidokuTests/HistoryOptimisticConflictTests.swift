import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct HistoryOptimisticConflictTests {
    private func fixture(_ body: (NSManagedObjectContext, NSManagedObjectContext, MangaIdentifier, ChapterIdentifier) throws -> Void) throws {
        let manager = CoreDataManager.shared
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: manager.container.managedObjectModel)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
            at: directory.appendingPathComponent("history.sqlite"))
        defer { try? coordinator.remove(store) }
        func context() -> NSManagedObjectContext {
            let value = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
            value.persistentStoreCoordinator = coordinator
            return value
        }
        let first = context(), second = context()
        let manga = AidokuRunner.Manga(sourceKey: "conflict-fixture", key: UUID().uuidString, title: "Original")
        let chapter = AidokuRunner.Chapter(key: "chapter")
        manager.addToLibrary(manga: manga, chapters: [chapter], context: first)
        try first.save()
        try body(first, second, manga.identifier,
            ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key))
    }

    @Test func completionRetryPreservesConcurrentOpenedDateAndChapterData() throws {
        try fixture { writer, competing, manga, chapter in
            let manager = CoreDataManager.shared
            let opened = Date(timeIntervalSince1970: 1_800_000_000)
            let read = Date(timeIntervalSince1970: 1_799_000_000)
            var attempts = 0
            let saved = try HistoryManager.saveMutationWithRetry(context: writer) {
                attempts += 1
                let changed = manager.setCompleted(chapterIds: [chapter], date: read, context: writer)
                manager.setRead(mangaId: manga, date: read, context: writer)
                if attempts == 1 {
                    let other = try #require(manager.getLibraryManga(mangaId: manga, context: competing))
                    other.lastOpened = opened
                    try competing.save() // Real optimistic conflict with writer's stale library row.
                }
                return changed
            }
            #expect(saved)
            #expect(attempts == 2)
            writer.reset()
            let library = try #require(manager.getLibraryManga(mangaId: manga, context: writer))
            let history = try #require(manager.getHistory(chapterId: chapter, context: writer))
            #expect(library.lastOpened == opened)
            #expect(library.lastRead == read)
            #expect(history.completed)
            #expect(history.dateRead == read)
            #expect(history.chapter?.id == chapter.chapterKey)
        }
    }

    @Test func progressRetryRetainsConcurrentCompletionAndUnrelatedFields() throws {
        try fixture { writer, competing, manga, chapter in
            let manager = CoreDataManager.shared
            manager.setProgress(1, chapterId: chapter, totalPages: 9, context: writer)
            try writer.save()
            var attempts = 0
            try HistoryManager.saveMutationWithRetry(context: writer) {
                attempts += 1
                manager.setRead(mangaId: manga, context: writer)
                manager.setProgress(3, chapterId: chapter, totalPages: 9, scrollPosition: 0.5, context: writer)
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
        }
    }

    @Test func persistentConflictsStopAfterThreeAttemptsWithoutPartialHistory() throws {
        try fixture { writer, competing, manga, chapter in
            let manager = CoreDataManager.shared
            var attempts = 0
            do {
                try HistoryManager.saveMutationWithRetry(context: writer) {
                    attempts += 1
                    manager.setCompleted(chapterIds: [chapter], context: writer)
                    manager.setRead(mangaId: manga, context: writer)
                    competing.reset()
                    let other = try #require(manager.getLibraryManga(mangaId: manga, context: competing))
                    other.lastOpened = Date(timeIntervalSince1970: Double(1_800_000_000 + attempts))
                    try competing.save()
                    return true
                }
                Issue.record("Repeated real conflicts must fail")
            } catch { }
            #expect(attempts == 3)
            writer.reset()
            #expect(manager.getHistory(chapterId: chapter, context: writer) == nil)
        }
    }

    @Test func validationFailureDoesNotRetryOrCommitPartialChanges() throws {
        try fixture { writer, _, manga, chapter in
            var attempts = 0
            do {
                try HistoryManager.saveMutationWithRetry(context: writer) {
                    attempts += 1
                    CoreDataManager.shared.setRead(mangaId: manga, context: writer)
                    CoreDataManager.shared.setCompleted(chapterIds: [chapter], context: writer)
                    CategoryObject(context: writer).title = nil
                    return true
                }
                Issue.record("Mandatory-property validation must fail")
            } catch { }
            #expect(attempts == 1)
            writer.reset()
            #expect(CoreDataManager.shared.getHistory(chapterId: chapter, context: writer) == nil)
        }
    }
}
