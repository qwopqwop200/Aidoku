import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit
@testable import Aidoku

/// Library, category and chapter-refresh data correctness. Stores are isolated SQLite
/// fixtures unless a test explicitly cleans up uniquely keyed rows in the app store.
@Suite(.serialized) @MainActor
struct LibraryDataTests {
    // MARK: History and counts

    /// A per-manga OR predicate exceeded SQLite's expression depth for libraries
    /// over roughly 500 entries, so "clear history excluding library" failed.
    @Test func clearHistoryExcludingLibraryHandlesLargeLibraries() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let manager = CoreDataManager.shared
        let libraryCount = 1_200
        for index in 0..<libraryCount {
            let id = ChapterIdentifier(sourceKey: "audit12", mangaKey: "library-\(index)", chapterKey: "1")
            manager.addToLibrary(manga: AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "\(index)"),
                chapters: [.init(key: id.chapterKey)], context: context)
            store.addHistory(id)
        }
        for index in 0..<700 {
            store.addHistory(.init(sourceKey: "audit12", mangaKey: "outside-\(index)", chapterKey: "1"))
        }
        try context.save()
        context.reset()

        #expect(manager.clearHistoryExcludingLibrary(context: context))
        context.reset()
        #expect(try context.count(for: HistoryObject.fetchRequest()) == libraryCount)
        #expect(manager.hasHistory(chapterId: .init(sourceKey: "audit12", mangaKey: "library-0", chapterKey: "1"), context: context))
        #expect(!manager.hasHistory(chapterId: .init(sourceKey: "audit12", mangaKey: "outside-0", chapterKey: "1"), context: context))
    }

    /// The manga view saves an empty scanlator filter as `[]`; readCount must treat it as unfiltered.
    @Test func readCountTreatsEmptyScanlatorFilterAsUnfiltered() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let manager = CoreDataManager.shared
        let mangaId = MangaIdentifier(sourceKey: "audit12", mangaKey: "read-count")
        for (index, scanlator) in [nil, "Group A"].enumerated() {
            store.addChapter(id: mangaId, index: index, language: "en", scanlator: scanlator, history: 2, locked: false)
        }
        try context.save()

        let unfiltered = manager.readCount(mangaId: mangaId, lang: nil, scanlators: nil, context: context)
        #expect(unfiltered == 2)
        #expect(manager.readCount(mangaId: mangaId, lang: "en", scanlators: [], context: context) == unfiltered)
        #expect(manager.readCount(mangaId: mangaId, lang: nil, scanlators: ["Group A"], context: context) == 1)
    }

    /// Batched unread counts must match the scalar query, including nil/empty scanlator
    /// filters, null history, and pending unsaved changes.
    @Test(arguments: [false, true])
    func groupedUnreadCountsMatchScalarQuery(twoStores: Bool) throws {
        let fixture = try TemporaryCoreDataStore(configurations: twoStores ? ["Cloud", "Local"] : [nil])
        defer { fixture.close() }
        let context = fixture.context
        var ids: [MangaIdentifier] = []
        let scanlators: [[String]?] = [nil, [], [""], ["A"], ["A, B"]]
        for language in [nil, "en"] as [String?] {
            for scanlator in scanlators {
                let id = fixture.addManga(index: ids.count, language: language, scanlators: scanlator)
                ids.append(id)
                var index = 0
                for lang in ["en", "fr"] {
                    for group in [nil, "", "A", "A, B"] as [String?] {
                        for history in 0..<4 {
                            fixture.addChapter(id: id, index: index, language: lang, scanlator: group, history: history, locked: index % 3 == 0)
                            index += 1
                        }
                    }
                }
            }
        }
        // More than 128 IDs sharing one group, and an identical key in another source.
        for index in 100..<231 { ids.append(fixture.addManga(index: index, language: nil, scanlators: nil)) }
        ids.append(.init(sourceKey: "other-source", mangaKey: ids[0].mangaKey))
        try context.save()
        func compare() {
            #expect(CoreDataManager.shared.unreadCounts(mangaIds: ids, context: context) == scalarUnread(ids, context: context))
        }
        compare()
        fixture.addChapter(id: ids[0], index: 1000, language: "en", scanlator: nil, history: 0, locked: false)
        compare() // pending insertion
        context.rollback()
        let completed = try #require(CoreDataManager.shared.getChapters(mangaId: ids[0], context: context)
            .first(where: { $0.history?.completed == true }))
        completed.history?.completed = false
        compare() // pending relationship-target change
    }

    /// Backups convert rows in batches; every row must survive.
    @Test func backupBatchedConversionKeepsEveryRow() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        for index in 0..<1_203 {
            let chapter = ChapterObject(context: context)
            chapter.sourceId = "audit12"
            chapter.mangaId = "backup"
            chapter.id = "chapter-\(index)"
        }
        try context.save()
        context.reset()
        let converted = BackupManager.mapInBatches(ChapterObject.fetchRequest(), context: context, batchSize: 500) {
            BackupChapter(chapterObject: $0)
        }
        #expect(converted.count == 1_203)
        #expect(Set(converted.map(\.id)).count == 1_203)
    }

    // MARK: Categories

    @Test func movingFilterGroupPreservesRegularCategoriesAndGroupData() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let manager = CoreDataManager.shared
        let categoryA = try manager.createCategory(title: "A", context: context)
        let categoryB = try manager.createCategory(title: "B", context: context)
        let groupA = try manager.createCategory(title: "Group A", group: true, context: context)
        _ = try manager.createCategory(title: "Group B", group: true, context: context)
        let payload = Data("filter payload".utf8)
        groupA.data = payload as NSData
        try context.save()
        let groupID = groupA.objectID
        manager.moveCategory(title: "Group A", toPosition: 1, context: context)
        try context.save()
        #expect(manager.getCategoryTitles(context: context) == ["A", "B"])
        #expect(categoryA.sort == 0 && categoryB.sort == 1)
        #expect(manager.getCategories(groupsOnly: true, context: context).compactMap(\.title) == ["Group B", "Group A"])
        context.reset()
        let reloaded = try #require(context.existingObject(with: groupID) as? CategoryObject)
        #expect(reloaded.data as? Data == payload)
    }

    /// Backup import permits `Int16.max` sort values; appending must not overflow or reorder.
    @Test func appendingAfterMaximumRestoredSortPreservesOrderAndPayload() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let manager = CoreDataManager.shared
        let a = try manager.createCategory(title: "A", context: context)
        let b = try manager.createCategory(title: "B", context: context)
        let group = try manager.createCategory(title: "Group", group: true, context: context)
        a.sort = 7
        b.sort = Int16.max
        group.sort = 9
        group.data = Data("group-payload".utf8) as NSData
        try context.save()
        let groupID = group.objectID
        _ = try manager.createCategory(title: "C", context: context)
        try context.save()
        context.reset()
        #expect(manager.getCategoryTitles(context: context) == ["A", "B", "C"])
        let restoredGroup = try #require(context.existingObject(with: groupID) as? CategoryObject)
        #expect(restoredGroup.sort == 9)
        #expect(restoredGroup.data as? Data == Data("group-payload".utf8))
    }

    @Test(arguments: [-1, 1000])
    func staleCategoryMenuRowDoesNotChangeSelectionOrCrash(row: Int) async throws {
        let saved = AppSettings.library.currentCategory.get()
        defer { AppSettings.library.currentCategory.set(saved) }
        let controller = LibraryViewController()
        controller.viewModel.categories = ["Audit category"]
        controller.viewModel.filterGroups = []
        controller.viewModel.currentCategory = "Unchanged audit selection"
        controller.optionSelected(IndexPath(row: row, section: 1))
        controller.optionSelected(IndexPath(row: row, section: 2))
        try await Task.sleep(for: .milliseconds(100))
        #expect(controller.viewModel.currentCategory == "Unchanged audit selection")
    }

    /// Leaving a locked category must not reveal its rows before the new category loads.
    @Test func leavingLockedCategoryKeepsItsRowsHiddenUntilTheNewCategoryLoads() async throws {
        let oldCategory = AppSettings.library.currentCategory.get()
        let oldLock = AppSettings.library.lockLibrary.get()
        let oldLockedCategories = AppSettings.library.lockedCategories.get()
        defer {
            AppSettings.library.currentCategory.set(oldCategory)
            AppSettings.library.lockLibrary.set(oldLock)
            AppSettings.library.lockedCategories.set(oldLockedCategories)
        }
        AppSettings.library.lockLibrary.set(true)
        AppSettings.library.lockedCategories.set(["private"])
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.categories = ["private", "public"]
        model.currentCategory = "private"
        let controller = LibraryViewController(viewModel: model)
        let secret = MangaInfo(id: .init(sourceKey: "snapshot-fixture", mangaKey: "secret"), title: "secret")
        let visible = MangaInfo(id: .init(sourceKey: "snapshot-fixture", mangaKey: "visible"), title: "visible")
        let first = Task { await model.loadLibrary() }
        try await RegressionTestWait.until { gate.requests.count == 1 }
        gate.finish(0, rows: [secret])
        await first.value

        controller.lock()
        #expect(controller.dataSource.snapshot().itemIdentifiers.isEmpty)
        controller.optionSelected(IndexPath(item: 1, section: 1))
        try await RegressionTestWait.until { gate.requests.count == 2 }
        #expect(gate.requests[1].category == "public")
        controller.updateDataSource()
        #expect(controller.dataSource.snapshot().itemIdentifiers.isEmpty)

        gate.finish(1, rows: [visible])
        try await RegressionTestWait.until { controller.dataSource.snapshot().itemIdentifiers == [visible] }
    }

    // MARK: Library records

    @Test func undoRestoresTrackerOffsetAndLibraryDates() async throws {
        let mangaId = MangaIdentifier(sourceKey: "audit-undo", mangaKey: UUID().uuidString)
        let date = Date(timeIntervalSince1970: 1_700_000_000)
        let manga = Aidoku.Manga(sourceId: mangaId.sourceKey, id: mangaId.mangaKey, title: "Undo fixture",
            lastOpened: date, lastUpdated: date, lastUpdatedChapters: date,
            lastRead: date, dateAdded: date)
        defer {
            let context = CoreDataManager.shared.context
            CoreDataManager.shared.removeTracks(mangaId: mangaId, context: context)
            CoreDataManager.shared.removeManga(mangaId: mangaId, context: context)
            try? context.save()
        }
        let track = TrackItem(id: "fixture-track", trackerId: "fixture-tracker", mangaId: mangaId,
            title: "Original track", chapterOffset: -7)
        await MangaManager.shared.restoreToLibrary(manga: manga, chapters: [], trackItems: [track], categories: [])
        let restored = await CoreDataManager.shared.container.performBackgroundTask { context in
            let tracker = CoreDataManager.shared.getTrack(trackerId: "fixture-tracker", mangaId: mangaId, context: context)
            let library = CoreDataManager.shared.getLibraryManga(mangaId: mangaId, context: context)
            return (tracker?.chapterOffset, tracker?.title, library?.dateAdded, library?.lastOpened)
        }
        #expect(restored.0 == -7)
        #expect(restored.1 == "Original track")
        #expect(restored.2 == date)
        #expect(restored.3 == date)
    }

    @Test(arguments: [false, true], [false, true])
    func migratingToSameDestinationPreservesLibraryHistoryDownloadsAndSettings(copy: Bool, forceRemove: Bool) async throws {
        let id = MangaIdentifier(sourceKey: "migration-identity-fixture", mangaKey: UUID().uuidString)
        let key = "Reader.readingMode.\(id)"
        let context = CoreDataManager.shared.context
        let manga = MangaObject(context: context)
        manga.sourceId = id.sourceKey
        manga.id = id.mangaKey
        manga.title = "Original"
        let library = LibraryMangaObject(context: context)
        library.manga = manga
        let chapter = ChapterObject(context: context)
        chapter.sourceId = id.sourceKey
        chapter.mangaId = id.mangaKey
        chapter.id = "chapter"
        chapter.manga = manga
        let file = LocalFileInfoObject(context: context)
        file.path = "migration-fixture.cbz"
        chapter.fileInfo = file
        let history = HistoryObject(context: context)
        history.sourceId = id.sourceKey
        history.mangaId = id.mangaKey
        history.chapterId = chapter.id
        history.progress = 7
        history.total = 20
        chapter.history = history
        try context.save()
        UserDefaults.standard.set("rtl", forKey: key)
        defer {
            UserDefaults.standard.removeObject(forKey: key)
            for object in [manga, library, chapter, file, history] as [NSManagedObject] where !object.isDeleted {
                context.delete(object)
            }
            try? context.save()
        }

        let original = AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "Original")
        let replacement = AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "Replacement")
        let result = await MangaManager.migrate(copy: copy, forceRemoveFromLibrary: forceRemove,
            from: original, to: replacement, withChapters: [])
        context.refreshAllObjects()

        #expect(result == nil)
        let stored = try #require(CoreDataManager.shared.getManga(mangaId: id, context: context))
        #expect(stored.libraryObject != nil)
        let chapters = CoreDataManager.shared.getChapters(mangaId: id, context: context)
        let retained = try #require(chapters.first)
        #expect(chapters.count == 1)
        #expect(retained.fileInfo?.path == "migration-fixture.cbz")
        #expect(retained.history?.progress == 7)
        #expect(UserDefaults.standard.string(forKey: key) == "rtl")
    }

    @Test func unencodableCoverDoesNotReplacePersistedCover() async throws {
        let id = MangaIdentifier(sourceKey: "cover-persistence-fixture", mangaKey: UUID().uuidString)
        let context = CoreDataManager.shared.context
        let manga = MangaObject(context: context)
        manga.sourceId = id.sourceKey
        manga.id = id.mangaKey
        manga.title = "Cover fixture"
        manga.cover = "https://example.invalid/original.png"
        try context.save()
        defer {
            context.delete(manga)
            try? context.save()
        }
        let result = await MangaManager.shared.setCover(
            manga: AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: manga.title),
            cover: UIImage()
        )
        context.refresh(manga, mergeChanges: false)
        #expect(result == nil)
        #expect(manga.cover == "https://example.invalid/original.png")
        #expect(!EditedKeys(rawValue: manga.editedKeys).contains(.cover))
    }

    // MARK: Chapter refresh

    /// Refresh must link existing history (including across fetch batches), ignore duplicate
    /// source rows, and be idempotent when replayed.
    @Test func chapterRefreshPreservesHistoryAcrossBatchesAndReplaysCleanly() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let manager = CoreDataManager.shared
        let id = manager.createManga(.init(sourceKey: "s", key: "title", title: "Library title"), context: context).identifier
        func history(_ key: String, source: String) -> HistoryObject {
            let row = HistoryObject(context: context)
            row.sourceId = source
            row.mangaId = id.mangaKey
            row.chapterId = key
            return row
        }
        let first = history("0", source: id.sourceKey)
        let foreign = history("501", source: "other")
        try context.save()
        let last = history("501", source: id.sourceKey)
        var chapters = (0..<502).map { AidokuRunner.Chapter(key: String($0), title: "Chapter \($0)", chapterNumber: Float($0)) }
        chapters.append(chapters[500])
        let added = manager.setChapters(chapters, mangaId: id, context: context)
        #expect(added.map(\.id) == (0..<502).map(String.init))
        #expect(added.first?.history === first)
        #expect(added.last?.history === last)
        #expect(foreign.chapter == nil)
        try context.save()
        context.reset()
        #expect(manager.setChapters(chapters, mangaId: id, context: context).isEmpty)
        context.processPendingChanges()
        #expect(!context.hasChanges)
    }

    @Test func concurrentRefreshesInsertEachChapterOnceAndPropagateSaveErrors() async throws {
        let store = CoreDataManager.shared
        let container = NSPersistentContainer(name: "writers", managedObjectModel: store.container.managedObjectModel)
        try container.persistentStoreCoordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: "Cloud",
            at: URL(fileURLWithPath: "/dev/null"))
        let writer = MangaUpdateWriter()
        let ids = ["s1", "s2"].map { MangaIdentifier(sourceKey: $0, mangaKey: "same") }
        try await container.performBackgroundTask { context in
            for id in ids {
                store.createManga(.init(sourceKey: id.sourceKey, key: id.mangaKey, title: "First"), context: context)
            }
            try context.save()
        }

        await #expect(throws: (any Error).self) {
            try await writer.perform(for: ids[0], in: container) { context in
                let invalid = MangaUpdateObject(context: context)
                invalid.sourceId = nil
                try context.save()
            }
        }

        let counts = try await withThrowingTaskGroup(of: Int.self) { group in
            for index in 0..<24 {
                let id = ids[index % ids.count]
                group.addTask {
                    try await writer.perform(for: id, in: container) { context in
                        let chapters = store.setChapters([.init(key: "same")], mangaId: id, context: context)
                        let count = try store.createMangaUpdates(mangaId: id, chapters: chapters, language: nil, scanlators: [], context: context)
                        try context.save()
                        return count
                    }
                }
            }
            return try await group.reduce(0, +)
        }
        #expect(counts == ids.count)
        let saved = await container.performBackgroundTask { context in
            (store.getUpdates(context: context).map(\.identifier), store.getChapters(context: context).map(\.identifier))
        }
        let expected = Set(ids.map { ChapterIdentifier(sourceKey: $0.sourceKey, mangaKey: $0.mangaKey, chapterKey: "same") })
        #expect(saved.0.count == 2 && Set(saved.0) == expected)
        #expect(saved.1.count == 2 && Set(saved.1) == expected)
    }

    private func scalarUnread(_ ids: [MangaIdentifier], context: NSManagedObjectContext) -> [MangaIdentifier: Int] {
        var result: [MangaIdentifier: Int] = [:]
        for id in ids {
            let filters = CoreDataManager.shared.getMangaChapterFilters(mangaId: id, context: context)
            result[id] = CoreDataManager.shared.unreadCount(mangaId: id, lang: filters.language, scanlators: filters.scanlators, context: context)
        }
        return result
    }
}

private extension TemporaryCoreDataStore {
    func addHistory(_ id: ChapterIdentifier) {
        let history = HistoryObject(context: context)
        history.sourceId = id.sourceKey
        history.mangaId = id.mangaKey
        history.chapterId = id.chapterKey
        history.completed = true
    }

    func addManga(index: Int, language: String?, scanlators: [String]?) -> MangaIdentifier {
        let id = MangaIdentifier(sourceKey: "round2-unread", mangaKey: "manga-\(index)")
        let manga = MangaObject(context: context)
        manga.sourceId = id.sourceKey; manga.id = id.mangaKey; manga.title = id.mangaKey
        manga.langFilter = language; manga.scanlatorFilter = scanlators
        return id
    }

    func addChapter(id: MangaIdentifier, index: Int, language: String, scanlator: String?, history: Int, locked: Bool) {
        let chapter = ChapterObject(context: context)
        chapter.sourceId = id.sourceKey; chapter.mangaId = id.mangaKey; chapter.id = "chapter-\(index)"
        chapter.lang = language; chapter.scanlator = scanlator; chapter.locked = locked
        if history > 0 {
            let value = HistoryObject(context: context)
            value.sourceId = id.sourceKey; value.mangaId = id.mangaKey; value.chapterId = chapter.id
            value.completed = history == 2
            if history == 3 { value.setPrimitiveValue(nil, forKey: "completed") }
            chapter.history = value
        }
    }
}

@MainActor
private final class LibrarySnapshotGate {
    var requests: [LibraryViewModel.LoadRequest] = []
    private var waiters: [Int: CheckedContinuation<LibraryViewModel.Snapshot?, Never>] = [:]

    func load(_ request: LibraryViewModel.LoadRequest) async -> LibraryViewModel.Snapshot? {
        let index = requests.count
        requests.append(request)
        return await withCheckedContinuation { waiters[index] = $0 }
    }

    func finish(_ index: Int, rows: [MangaInfo]) {
        waiters.removeValue(forKey: index)?.resume(returning: .init(manga: rows))
    }
}
