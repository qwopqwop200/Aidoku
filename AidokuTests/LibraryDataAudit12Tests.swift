import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

/// Production-schema SQLite store for library/history data regressions.
@Suite(.serialized) @MainActor
struct LibraryDataAudit12Tests {
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
            store.addHistory(id, completed: true)
        }
        for index in 0..<700 {
            store.addHistory(.init(sourceKey: "audit12", mangaKey: "outside-\(index)", chapterKey: "1"), completed: true)
        }
        try context.save()
        context.reset()

        #expect(manager.clearHistoryExcludingLibrary(context: context))
        context.reset()
        #expect(try context.count(for: HistoryObject.fetchRequest()) == libraryCount)
        #expect(manager.hasHistory(chapterId: .init(sourceKey: "audit12", mangaKey: "library-0", chapterKey: "1"), context: context))
        #expect(!manager.hasHistory(chapterId: .init(sourceKey: "audit12", mangaKey: "outside-0", chapterKey: "1"), context: context))
    }

    /// The manga view saves an empty scanlator filter as `[]`. readCount treated
    /// that as "no scanlator matches", so the "not started" library-update skip
    /// option skipped every such series even after chapters were read.
    @Test func readCountTreatsEmptyScanlatorFilterAsUnfiltered() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        let manager = CoreDataManager.shared
        let mangaId = MangaIdentifier(sourceKey: "audit12", mangaKey: "read-count")
        for (index, scanlator) in [nil, "Group A"].enumerated() {
            let chapter = ChapterObject(context: context)
            chapter.sourceId = mangaId.sourceKey
            chapter.mangaId = mangaId.mangaKey
            chapter.id = "chapter-\(index)"
            chapter.lang = "en"
            chapter.scanlator = scanlator
            let history = HistoryObject(context: context)
            history.sourceId = mangaId.sourceKey
            history.mangaId = mangaId.mangaKey
            history.chapterId = chapter.id
            history.completed = true
            chapter.history = history
        }
        try context.save()

        let unfiltered = manager.readCount(mangaId: mangaId, lang: nil, scanlators: nil, context: context)
        #expect(unfiltered == 2)
        #expect(manager.readCount(mangaId: mangaId, lang: nil, scanlators: [], context: context) == unfiltered)
        #expect(manager.readCount(mangaId: mangaId, lang: "en", scanlators: [], context: context) == unfiltered)
        #expect(manager.readCount(mangaId: mangaId, lang: nil, scanlators: ["Group A"], context: context) == 1)
    }

    /// Pinned rows were matched by title substring only, so a pinned series could
    /// not be found by author although the same series unpinned could.
    @Test func pinnedSearchMatchesAuthorsLikeRegularRows() async {
        let model = LibraryViewModel(snapshotLoader: { _ in nil })
        let pinned = MangaInfo(id: .init(sourceKey: "audit12", mangaKey: "pinned"), title: "Alpha", author: "Kentaro Miura")
        let regular = MangaInfo(id: .init(sourceKey: "audit12", mangaKey: "regular"), title: "Beta", author: "Kentaro Miura")
        model.pinnedManga = [pinned]
        model.manga = [regular]
        await model.search(query: "miura")
        #expect(model.pinnedManga.map(\.id) == [pinned.id])
        #expect(model.manga.map(\.id) == [regular.id])
        await model.search(query: "")
        #expect(model.pinnedManga.map(\.id) == [pinned.id])
    }

    /// Backups converted every row from one materialized fetch. Batched conversion
    /// must keep all rows while faulting converted objects back out.
    @Test func backupBatchedConversionKeepsEveryRowAndFaultsObjects() throws {
        let store = try TemporaryCoreDataStore()
        defer { store.close() }
        let context = store.context
        for index in 0..<2_503 {
            let chapter = ChapterObject(context: context)
            chapter.sourceId = "audit12"
            chapter.mangaId = "backup"
            chapter.id = "chapter-\(index)"
        }
        try context.save()
        context.reset()

        let request = ChapterObject.fetchRequest()
        let converted = BackupManager.mapInBatches(request, context: context, batchSize: 500) {
            BackupChapter(chapterObject: $0)
        }
        #expect(converted.count == 2_503)
        #expect(Set(converted.map(\.id)).count == 2_503)
        let registered = context.registeredObjects.compactMap { $0 as? ChapterObject }
        let allFaults = registered.allSatisfy { $0.isFault }
        #expect(allFaults)
    }
}

private extension TemporaryCoreDataStore {
    func addHistory(_ id: ChapterIdentifier, completed: Bool) {
        let history = HistoryObject(context: context)
        history.sourceId = id.sourceKey
        history.mangaId = id.mangaKey
        history.chapterId = id.chapterKey
        history.completed = completed
    }
}
