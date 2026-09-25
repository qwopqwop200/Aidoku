import CoreData
import Foundation
import Testing
@testable import Aidoku

/// Separate production-schema SQLite store. The oracle is the unchanged scalar
/// unreadCount, including nil/empty scanlator and history-null semantics.
@Suite(.serialized) @MainActor
struct LibraryUnreadBatchRegressionTests {
    @Test(arguments: [false, true])
    func groupedCountsMatchScalarAcrossFiltersAndPendingChanges(twoStores: Bool) throws {
        let fixture = try R2UnreadStore(twoStores: twoStores)
        defer { fixture.close() }
        let context = fixture.context
        var ids: [MangaIdentifier] = []
        let scanlators: [[String]?] = [nil, [], [""], ["A"], ["A", ""], ["A, B"]]
        for language in [nil, "en", "fr"] as [String?] {
            for scanlator in scanlators {
                let id = fixture.addManga(index: ids.count, language: language, scanlators: scanlator)
                ids.append(id)
                var index = 0
                for lang in ["en", "fr"] {
                    for group in [nil, "", "A", "A, B"] as [String?] {
                        for history in 0..<4 {
                            for locked in [false, true] {
                                fixture.addChapter(id: id, index: index, language: lang, scanlator: group, history: history, locked: locked)
                                index += 1
                            }
                        }
                    }
                }
            }
        }
        // Exercise >128 IDs sharing one group and zero counts/identical keys in another source.
        for index in 100..<231 { ids.append(fixture.addManga(index: index, language: nil, scanlators: nil)) }
        ids.append(.init(sourceKey: "other-source", mangaKey: ids[0].mangaKey))
        try context.save()
        func compare() {
            let expected = scalar(ids, context: context)
            let actual = CoreDataManager.shared.unreadCounts(mangaIds: ids, context: context)
            #expect(actual == expected)
        }
        compare()
        fixture.addChapter(id: ids[0], index: 1000, language: "en", scanlator: nil, history: 0, locked: false)
        #expect(context.hasChanges)
        compare() // grouped dictionary fetch must not hide pending insertions
        context.rollback()
        let existing = try #require(CoreDataManager.shared.getChapters(mangaId: ids[0], context: context).first)
        context.delete(existing)
        compare() // pending deletion
        context.rollback()
        let completed = try #require(CoreDataManager.shared.getChapters(mangaId: ids[0], context: context).first(where: { $0.history?.completed == true }))
        completed.history?.completed = false
        compare() // pending relationship-target change
    }

    @Test func productionTwoStoreConfigurationExecutesBoundedGroupedQueries() throws {
        let fixture = try R2UnreadStore(twoStores: true)
        defer { fixture.close() }
        let ids = (0..<257).map { fixture.addManga(index: $0, language: nil, scanlators: nil) }
        for id in ids {
            fixture.addChapter(id: id, index: 0, language: "en", scanlator: nil, history: 0, locked: false)
        }
        try fixture.context.save()
        var grouped = 0
        var scalarQueries = 0
        let counts = CoreDataManager.shared.unreadCounts(mangaIds: ids, context: fixture.context) { isGrouped in
            if isGrouped { grouped += 1 } else { scalarQueries += 1 }
        }
        #expect(counts == scalar(ids, context: fixture.context))
        #expect(grouped == 3 && scalarQueries == 0)
        fixture.addChapter(id: ids[0], index: 1, language: "en", scanlator: nil, history: 0, locked: false)
        grouped = 0; scalarQueries = 0
        let pending = CoreDataManager.shared.unreadCounts(mangaIds: ids, context: fixture.context) { isGrouped in
            if isGrouped { grouped += 1 } else { scalarQueries += 1 }
        }
        #expect(pending == scalar(ids, context: fixture.context))
        #expect(grouped == 0 && scalarQueries == 257)
        print("TWO_STORE_UNREAD persistedGrouped=3 persistedScalar=0 pendingGrouped=0 pendingScalar=257 manga=257")
    }

    @Test func boundedPairedSQLiteTimingRetainsExactCounts() throws {
        let fixture = try R2UnreadStore(twoStores: true)
        defer { fixture.close() }
        var ids: [MangaIdentifier] = []
        for index in 0..<120 {
            let id = fixture.addManga(index: index, language: nil, scanlators: nil)
            ids.append(id)
            for chapter in 0..<12 { fixture.addChapter(id: id, index: chapter, language: "en", scanlator: "A", history: chapter % 4, locked: chapter % 5 == 0) }
        }
        try fixture.context.save()
        var rows: [[String: Any]] = []
        for iteration in 0..<6 {
            var expected: [MangaIdentifier: Int] = [:]
            var actual: [MangaIdentifier: Int] = [:]
            var scalarMS: Double = 0
            var batchMS: Double = 0
            var groupedQueries = 0
            var scalarQueries = 0
            func measureScalar() {
                let start = ProcessInfo.processInfo.systemUptime
                expected = scalar(ids, context: fixture.context)
                scalarMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            }
            func measureBatch() {
                let start = ProcessInfo.processInfo.systemUptime
                actual = CoreDataManager.shared.unreadCounts(mangaIds: ids, context: fixture.context) { grouped in
                    if grouped { groupedQueries += 1 } else { scalarQueries += 1 }
                }
                batchMS = (ProcessInfo.processInfo.systemUptime - start) * 1000
            }
            if iteration.isMultiple(of: 2) { measureScalar(); measureBatch() } else { measureBatch(); measureScalar() }
            #expect(actual == expected)
            #expect(groupedQueries == 1 && scalarQueries == 0)
            rows.append(["iteration": iteration, "phase": iteration == 0 ? "warmup" : "measured",
                "scalarFirst": iteration.isMultiple(of: 2), "scalarMS": scalarMS, "batchMS": batchMS,
                "groupedQueries": groupedQueries, "scalarQueries": scalarQueries, "counts": ids.map { actual[$0] ?? -1 }])
        }
        let directory = URL.documentsDirectory.appendingPathComponent("Round2UnreadBatch")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let scope = "Separate production-schema Cloud+Local SQLite; 6 paired synchronous calls; "
            + "alternating scalar/batch order; process-warm storage; not UI latency, not cold disk or peak-memory measurement"
        let evidence: [String: Any] = ["manga": 120, "chaptersPerManga": 12, "scope": scope, "rows": rows]
        try JSONSerialization.data(withJSONObject: evidence, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("paired-counts.json"), options: .atomic)
    }

    private func scalar(_ ids: [MangaIdentifier], context: NSManagedObjectContext) -> [MangaIdentifier: Int] {
        var result: [MangaIdentifier: Int] = [:]
        for id in ids {
            let filters = CoreDataManager.shared.getMangaChapterFilters(mangaId: id, context: context)
            result[id] = CoreDataManager.shared.unreadCount(mangaId: id, lang: filters.language, scanlators: filters.scanlators, context: context)
        }
        return result
    }
}

@MainActor private final class R2UnreadStore {
    let directory: URL
    let coordinator: NSPersistentStoreCoordinator
    let context: NSManagedObjectContext
    init(twoStores: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("round2-unread-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        if twoStores {
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: "Cloud",
                at: directory.appendingPathComponent("cloud.sqlite"))
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: "Local",
                at: directory.appendingPathComponent("local.sqlite"))
        } else {
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil,
                at: directory.appendingPathComponent("fixture.sqlite"))
        }
        context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
    }
    func close() {
        context.reset()
        for store in coordinator.persistentStores { try? coordinator.remove(store) }
        try? FileManager.default.removeItem(at: directory)
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
