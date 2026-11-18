import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct BackupSafetyTests {
    private func context() throws -> NSManagedObjectContext {
        let files = TemporaryBackupStore()
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let model = CoreDataManager.shared.container.managedObjectModel
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: model)
        // Derived attributes require SQLite. Keep a private store until context release.
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                                           at: files.directory.appendingPathComponent("test.sqlite"))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        context.userInfo["temporary-store"] = files
        return context
    }

    private func backup() -> Backup {
        Backup(date: Date(timeIntervalSince1970: 1_700_000_000))
    }

    @Test func unselectedSectionsRemainAbsent() async {
        let backup = await BackupManager.shared.createBackup(options: .init(
            libraryEntries: false, history: false, chapters: false, tracking: false,
            readingSessions: false, vocabulary: false, updates: false, categories: false,
            settings: false, sourceLists: false, sensitiveSettings: false
        ))
        #expect(backup.library == nil)
        #expect(backup.history == nil)
        #expect(backup.manga == nil)
        #expect(backup.chapters == nil)
        #expect(backup.trackItems == nil)
        #expect(backup.readingSessions == nil)
        #expect(backup.vocabulary == nil)
        #expect(backup.updates == nil)
        #expect(backup.categories == nil)
        #expect(backup.sourceLists == nil)
        #expect(backup.settings == nil)
    }

    @Test func failedWriteReturnsFailure() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await BackupManager.shared.save(backup: backup(), url: directory) == false)
    }

    @Test func summariesAndFullRestoreReadExistingBackupFormats() throws {
        var expected = backup()
        expected.name = "서재"
        expected.automatic = true
        expected.sourceLists = ["first", "second"]
        expected.settings = ["Reader.example": .string("value")]

        let plist = PropertyListEncoder()
        plist.outputFormat = .binary
        let binary = try plist.encode(expected)
        plist.outputFormat = .xml
        let xml = try plist.encode(expected)
        let jsonEncoder = JSONEncoder()
        jsonEncoder.dateEncodingStrategy = .secondsSince1970
        let json = try jsonEncoder.encode(expected)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        for data in [binary, xml, json, Data("\n ".utf8) + json] {
            try data.write(to: url, options: .atomic)
            let info = try #require(BackupInfo.load(from: url))
            #expect(info.name == expected.name)
            #expect(info.date == expected.date)
            #expect(info.automatic)
            #expect(info.counts.sourceLists == 2)
            #expect(info.counts.settings == 1)
            #expect(info.size == Int64(data.count))
            #expect(Backup.load(from: url) == expected)
        }
        try Data("{".utf8).write(to: url, options: .atomic)
        #expect(BackupInfo.load(from: url) == nil)
        #expect(Backup.load(from: url) == nil)
    }

    @Test func cancelledQueuedBackupDoesNotEnterTheDataOperation() async {
        let manager = BackupManager()
        let started = AsyncStream<Void>.makeStream()
        let release = AsyncStream<Void>.makeStream()
        let first = Task {
            await manager.withExclusiveDataAccess {
                started.continuation.finish()
                for await _ in release.stream {}
                return true
            }
        }
        for await _ in started.stream {}
        let cancelled = Task { await manager.withExclusiveDataAccess { true } }
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        release.continuation.finish()
        #expect(!cancelledResult)
        #expect(await first.value)
        #expect(await manager.withExclusiveDataAccess { true })
    }

    @Test func cancelledBackupDoesNotReplaceAnExistingFile() async throws {
        let files = TemporaryBackupStore()
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let url = files.directory.appendingPathComponent("existing.aib")
        let original = try PropertyListEncoder().encode(backup())
        try original.write(to: url)
        var changed = backup()
        changed.name = "replacement"
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await BackupManager().save(backup: changed, url: url)
        }
        #expect(await !task.value)
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func importPublishesCompleteCopiesAndRemovalRefreshesTheList() async throws {
        let files = TemporaryBackupStore()
        let manager = BackupManager()
        let source = files.directory.appendingPathComponent("input.aib")
        let destination = files.directory.appendingPathComponent("Backups", isDirectory: true)
        try FileManager.default.createDirectory(at: files.directory, withIntermediateDirectories: true)
        let first = try PropertyListEncoder().encode(backup())
        try first.write(to: source)
        #expect(await manager.importBackup(from: source, into: destination))
        var newer = backup()
        newer.name = "second"
        let second = try PropertyListEncoder().encode(newer)
        try second.write(to: source, options: .atomic)
        #expect(await manager.importBackup(from: source, into: destination))

        let original = destination.appendingPathComponent("input.aib")
        let duplicate = destination.appendingPathComponent("input_1.aib")
        #expect(try Data(contentsOf: original) == first)
        #expect(try Data(contentsOf: duplicate) == second)
        try FileManager.default.removeItem(at: source)
        #expect(await !manager.importBackup(from: source, into: destination))
        #expect(Set(destination.contents.map(\.lastPathComponent)) == [original.lastPathComponent, duplicate.lastPathComponent])

        await confirmation(expectedCount: 1) { removed in
            let observer = NotificationCenter.default.addObserver(forName: .updateBackupList, object: nil, queue: nil) { note in
                if note.object as? URL == original { removed() }
            }
            defer { NotificationCenter.default.removeObserver(observer) }
            await manager.removeBackup(url: original)
        }
        #expect(destination.contents.map(\.lastPathComponent) == [duplicate.lastPathComponent])
    }

    @Test func settingsOnlyRestoreLeavesLibraryRowsUnloaded() throws {
        let context = try context()
        context.retainsRegisteredObjects = true
        let manga = MangaObject(context: context)
        manga.id = "book"
        let chapter = ChapterObject(context: context)
        chapter.id = "chapter"
        chapter.mangaId = manga.id
        chapter.manga = manga
        let history = HistoryObject(context: context)
        history.mangaId = manga.id
        history.chapterId = chapter.id
        chapter.history = history
        let source = SourceObject(context: context)
        source.id = "external"
        var backup = backup()
        backup.settings = ["General.example": .bool(true)]
        backup.sources = [BackupSource(source)]
        try context.save()
        context.reset()

        try BackupManager.restoreDatabase(from: backup, context: context)

        #expect(context.registeredObjects.isEmpty)
        #expect(!context.hasChanges)
    }

    @Test func repeatedCustomSourceFromBackupUpdatesOneRow() throws {
        let context = try context()
        let json = """
        [
            {"id":"custom","apiVersion":"1","config":"AQ=="},
            {"id":"custom","apiVersion":"2","config":"Ag=="}
        ]
        """
        var backup = backup()
        backup.sources = try JSONDecoder().decode([BackupSource].self, from: Data(json.utf8))
        try BackupManager.restoreDatabase(from: backup, context: context)
        try context.save()
        context.reset()

        let sources = try context.fetch(SourceObject.fetchRequest())
        #expect(sources.count == 1)
        #expect(sources.first?.apiVersion == "2")
        #expect(sources.first?.customSource as? Data == Data([2]))
    }

    @Test func restorePreservesLocalFilesAndUnselectedSections() throws {
        let context = try context()
        let manga = MangaObject(context: context)
        manga.sourceId = "local"
        manga.id = "one"
        manga.title = "Original"
        let file = LocalFileInfoObject(context: context)
        file.path = "Books/one"
        manga.fileInfo = file
        let chapter = ChapterObject(context: context)
        chapter.sourceId = "local"
        chapter.mangaId = "one"
        chapter.id = "chapter"
        chapter.manga = manga
        let history = HistoryObject(context: context)
        history.sourceId = "local"
        history.mangaId = "one"
        history.chapterId = "chapter"
        history.progress = 7
        chapter.history = history
        try context.save()
        let originalID = manga.objectID
        var item = BackupManga(mangaObject: manga)
        item.title = "Restored"
        var backup = backup()
        backup.manga = [item]
        try BackupManager.restoreDatabase(from: backup, context: context)
        try context.save()
        let restored = try #require(context.fetch(MangaObject.fetchRequest()).first)
        #expect(restored.objectID == originalID)
        #expect(restored.title == "Restored")
        #expect(restored.fileInfo?.path == "Books/one")
        #expect(chapter.manga === restored)
        #expect(chapter.history?.progress == 7)
    }

    @Test func restoreCanRollbackWithoutDeletingPersistedRows() throws {
        let context = try context()
        let history = HistoryObject(context: context)
        history.sourceId = "source"
        history.mangaId = "manga"
        history.chapterId = "chapter"
        history.progress = 9
        try context.save()
        context.reset()
        let persisted = try #require(context.fetch(HistoryObject.fetchRequest()).first)
        #expect(persisted.progress == 9)
        var backup = backup()
        backup.history = []
        try BackupManager.restoreDatabase(from: backup, context: context)
        context.rollback()
        #expect(try context.fetch(HistoryObject.fetchRequest()).count == 1)
        let restored = try #require(context.fetch(HistoryObject.fetchRequest()).first)
        #expect(restored.progress == 9)
    }

    @Test func libraryRollbackPreservesPersistedDates() throws {
        let context = try context()
        let library = LibraryMangaObject(context: context)
        let date = Date(timeIntervalSince1970: 1_234_567)
        library.dateAdded = date
        library.lastOpened = date
        library.lastRead = date
        library.lastUpdated = date
        library.lastUpdatedChapters = date
        try context.save()
        context.delete(library)
        context.rollback()
        let restored = try #require(context.fetch(LibraryMangaObject.fetchRequest()).first)
        #expect(restored.dateAdded == date)
        #expect(restored.lastOpened == date)
        #expect(restored.lastRead == date)
        #expect(restored.lastUpdated == date)
        #expect(restored.lastUpdatedChapters == date)
    }

    @Test func outOfRangeBackupIsRejectedBeforeChangingData() throws {
        let context = try context()
        let history = HistoryObject(context: context)
        history.sourceId = "source"
        history.mangaId = "manga"
        history.chapterId = "chapter"
        history.progress = 5
        history.scrollPosition = 0.75
        try context.save()
        var item = BackupHistory(historyObject: history)
        #expect(item.scrollPosition == 0.75)
        item.progress = Int.max
        var backup = backup()
        backup.history = [item]
        #expect(throws: BackupManager.BackupError.self) {
            try BackupManager.restoreDatabase(from: backup, context: context)
        }
        #expect(!context.hasChanges)
        #expect(history.progress == 5)
    }

    @Test func newerTrackerProgressDoesNotMatchTheInFlightSnapshot() {
        let original = PageTrackUpdate(trackerId: "tracker", trackId: "title",
            chapterId: .init(sourceKey: "source", mangaKey: "manga", chapterKey: "chapter"),
            progress: .init(completed: false, page: 1))
        let latest = PageTrackUpdate(trackerId: "tracker", trackId: "title",
            chapterId: original.chapterId, progress: .init(completed: false, page: 9))
        #expect(PageTrackUpdate.reconcile(pending: [latest], sent: [original], failed: []).count == 1)
        #expect(PageTrackUpdate.reconcile(pending: [original], sent: [original], failed: []).isEmpty)
    }
    @Test func groupFilterSnapshotDoesNotShareMutableChildren() throws {
        let original = GroupFilter(name: "Group", filters: [TextFilter(name: "Title", value: "before")])
        let copied = try #require(original.copy() as? GroupFilter)
        let child = try #require(original.filters.first as? TextFilter)
        child.value = "after"
        #expect((copied.filters.first as? TextFilter)?.value == "before")
    }

    @Test func unknownTotalDoesNotCountAnUnfinishedChapterAsRead() throws {
        let context = try context()
        let history = HistoryObject(context: context)
        history.sourceId = "source"
        history.mangaId = "manga"
        history.chapterId = "chapter"
        history.total = 0
        history.completed = false
        let session = ReadingSessionObject(context: context)
        session.history = history
        session.pagesRead = 1
        session.startDate = Date().addingTimeInterval(-60)
        session.endDate = Date()
        try context.save()
        #expect(CoreDataManager.shared.getChapterYearlyReadingData(context: context).isEmpty)
    }

    @Test func partialRestorePreservesUnselectedCascadeChildren() throws {
        let context = try context()
        let history = HistoryObject(context: context)
        history.sourceId = "source"
        history.mangaId = "manga"
        history.chapterId = "chapter"
        let session = ReadingSessionObject(context: context)
        session.history = history
        session.pagesRead = 1
        session.startDate = Date().addingTimeInterval(-60)
        session.endDate = Date()
        let chapter = ChapterObject(context: context)
        chapter.sourceId = "source"
        chapter.mangaId = "manga"
        chapter.id = "chapter"
        let update = MangaUpdateObject(context: context)
        update.sourceId = "source"
        update.mangaId = "manga"
        update.chapterId = "chapter"
        update.chapter = chapter
        try context.save()
        var backup = backup()
        backup.history = []
        backup.chapters = []
        try BackupManager.restoreDatabase(from: backup, context: context)
        try context.save()
        #expect(try context.fetch(ReadingSessionObject.fetchRequest()).count == 1)
        #expect(session.history?.chapterId == "chapter")
        #expect(try context.fetch(MangaUpdateObject.fetchRequest()).count == 1)
        #expect(update.chapter?.id == "chapter")
    }

    @Test func chapterRefreshPreservesDownloadedMissingAndUnlockedObjects() throws {
        let context = try context()
        let manga = MangaObject(context: context)
        manga.sourceId = "source"
        manga.id = "manga"
        manga.title = "Manga"
        let chapter = ChapterObject(context: context)
        chapter.sourceId = "source"
        chapter.mangaId = "manga"
        chapter.id = "chapter"
        chapter.manga = manga
        chapter.locked = true
        let file = LocalFileInfoObject(context: context)
        file.path = "chapter.cbz"
        chapter.fileInfo = file
        try context.save()
        let originalID = chapter.objectID
        let added = CoreDataManager.shared.setChapters([.init(key: "chapter", locked: false)],
            mangaId: manga.identifier, context: context)
        try context.save()
        #expect(added.count == 1)
        #expect(added.first?.objectID == originalID)
        #expect(chapter.fileInfo?.path == "chapter.cbz")
        _ = CoreDataManager.shared.setChapters([], mangaId: manga.identifier, context: context)
        try context.save()
        #expect(try context.fetch(ChapterObject.fetchRequest()).count == 1)
        #expect(chapter.fileInfo?.path == "chapter.cbz")
    }

    @Test func chapterRefreshPreservesDownloadOwnedByLaterMissingDuplicate() throws {
        let context = try context()
        let manga = MangaObject(context: context)
        manga.sourceId = "source"
        manga.id = "manga"
        manga.title = "Manga"
        var duplicates: [ChapterObject] = []
        for index in 0..<2 {
            let chapter = ChapterObject(context: context)
            chapter.sourceId = manga.sourceId
            chapter.mangaId = manga.id
            chapter.id = "missing"
            chapter.sourceOrder = Int16(index)
            chapter.manga = manga
            duplicates.append(chapter)
        }
        let file = LocalFileInfoObject(context: context)
        file.path = "downloaded.cbz"
        duplicates[1].fileInfo = file
        let update = MangaUpdateObject(context: context)
        update.sourceId = manga.sourceId
        update.mangaId = manga.id
        update.chapterId = "missing"
        update.chapter = duplicates[1]
        try context.save()

        let added = CoreDataManager.shared.setChapters([], mangaId: manga.identifier, context: context)
        try context.save()
        context.reset()

        let chapters = try context.fetch(ChapterObject.fetchRequest())
        #expect(added.isEmpty)
        #expect(chapters.count == 1)
        #expect(chapters.first?.fileInfo?.path == "downloaded.cbz")
        #expect(chapters.first?.mangaUpdate?.chapterId == "missing")
        #expect(try context.fetch(MangaUpdateObject.fetchRequest()).count == 1)
    }

    @Test func vocabularyRestorePreservesExistingLocalImage() throws {
        let context = try context()
        let original = VocabObject(context: context)
        original.sourceId = "source"
        original.mangaId = "manga"
        original.chapterId = "chapter"
        original.word = "word"
        original.createdDate = Date(timeIntervalSince1970: 100)
        original.localImageId = "saved-image"
        try context.save()
        var backup = backup()
        backup.vocabulary = [try #require(BackupVocabEntry(original))]
        try BackupManager.restoreDatabase(from: backup, context: context)
        try context.save()
        let restored = try #require(context.fetch(VocabObject.fetchRequest()).first)
        #expect(restored.localImageId == "saved-image")
    }

    @Test func deduplicationPreservesSessionsAndLatestProgress() throws {
        let context = try context()
        var histories: [HistoryObject] = []
        for index in 0..<2 {
            let history = HistoryObject(context: context)
            history.sourceId = "source"
            history.mangaId = "manga"
            history.chapterId = "chapter"
            history.dateRead = Date(timeIntervalSince1970: Double(index + 1))
            history.progress = Int16(index + 5)
            let session = ReadingSessionObject(context: context)
            session.history = history
            session.startDate = Date(timeIntervalSince1970: 0)
            session.endDate = Date(timeIntervalSince1970: 1)
            histories.append(history)
        }
        try context.save()
        CoreDataManager.shared.deduplicate(objectId: histories[0].objectID, context: context)
        try context.save()
        let rows = try context.fetch(HistoryObject.fetchRequest())
        #expect(rows.count == 1)
        #expect(rows.first?.progress == 6)
        #expect(try context.fetch(ReadingSessionObject.fetchRequest()).count == 2)
        #expect(rows.first?.sessions?.count == 2)
    }

    @Test func mangaDeduplicationKeepsBothCategoriesAndChapters() throws {
        let context = try context()
        var rows: [MangaObject] = []
        for index in 0..<2 {
            let manga = MangaObject(context: context)
            manga.sourceId = "source"
            manga.id = "manga"
            manga.title = "Manga"
            let library = LibraryMangaObject(context: context)
            library.manga = manga
            let category = CategoryObject(context: context)
            category.title = "category-\(index)"
            library.addToCategories(category)
            let chapter = ChapterObject(context: context)
            chapter.sourceId = "source"
            chapter.mangaId = "manga"
            chapter.id = "chapter-\(index)"
            chapter.manga = manga
            rows.append(manga)
        }
        try context.save()
        CoreDataManager.shared.deduplicate(objectId: rows[0].objectID, context: context)
        try context.save()
        let manga = try #require(context.fetch(MangaObject.fetchRequest()).first)
        #expect(try context.fetch(MangaObject.fetchRequest()).count == 1)
        #expect(try context.fetch(LibraryMangaObject.fetchRequest()).count == 1)
        #expect(manga.chapters?.count == 2)
        #expect(manga.libraryObject?.categories?.count == 2)
    }

}

private final class TemporaryBackupStore {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    deinit { try? FileManager.default.removeItem(at: directory) }
}
