import AidokuRunner
import CoreData
import Foundation
import SwiftUI
import Testing
import UserNotifications
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LibraryFollowupWorkTests {
    @Test func refreshMetadataRetainsNoCompletedChapterArrays() {
        let chapters = (0..<1_000).map { AidokuRunner.Chapter(key: "chapter-\($0)") }
        var responses: [AidokuRunner.Manga] = []
        for index in 0..<100 {
            var response = AidokuRunner.Manga(sourceKey: "refresh-fixture", key: "manga-\(index)", title: "Title \(index)")
            response.chapters = chapters
            responses.append(response)
        }
        let retained = responses.map(MangaManager.compactRefreshMetadata)
        #expect(responses.reduce(0) { $0 + ($1.chapters?.count ?? 0) } == 100_000)
        #expect(retained.reduce(0) { $0 + ($1.chapters?.count ?? 0) } == 0)
        #expect(retained.map(\.identifier) == responses.map(\.identifier))
        #expect(retained.map(\.title) == responses.map(\.title))
        #expect(responses.allSatisfy { $0.chapters?.count == 1_000 })
    }

    @Test func chapterRefreshReplaysCleanlyAndPreservesHistoryAcrossBatches() throws {
        let context = try updateContext()
        let store = CoreDataManager.shared
        let manga = store.createManga(.init(sourceKey: "s", key: "title", title: "Library title"), context: context)
        let id = manga.identifier
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
        var chapters = (0..<502).map {
            AidokuRunner.Chapter(key: String($0), title: "Chapter \($0)", chapterNumber: Float($0), locked: $0 == 0)
        }
        chapters.append(chapters[500])
        let added = store.setChapters(chapters, mangaId: id, context: context)
        #expect(added.map(\.id) == (0..<502).map(String.init))
        #expect(added.first?.history === first)
        #expect(added.last?.history === last)
        #expect(foreign.chapter == nil)
        try context.save()
        context.reset()
        #expect(store.setChapters(chapters, mangaId: id, context: context).isEmpty)
        context.processPendingChanges()
        #expect(!context.hasChanges)

        chapters[0].locked = false
        chapters[1].title = nil
        chapters[1].chapterNumber = nil
        chapters[1].language = "ja"
        chapters[1].scanlators = ["A", "B"]
        chapters.swapAt(2, 3)
        let unlocked = store.setChapters(chapters, mangaId: id, context: context)
        #expect(unlocked.map(\.id) == ["0"])
        context.processPendingChanges()
        #expect(Set(context.updatedObjects.compactMap { ($0 as? ChapterObject)?.id }) == ["0", "1", "2", "3"])
        try context.save()
        context.reset()
        let stored = store.getChapters(mangaId: id, context: context)
        #expect(stored.map(\.id) == Array(chapters.dropLast()).map(\.key))
        #expect(stored[1].title == nil && stored[1].chapter == nil)
        #expect(stored[1].lang == "ja" && stored[1].scanlator == "A, B")
        #expect(store.setChapters(chapters, mangaId: id, context: context).isEmpty)
        context.processPendingChanges()
        #expect(!context.hasChanges)
    }

    @Test func newUpdatesRespectBothFiltersAndCountOnlyNewRecords() throws {
        let store = CoreDataManager.shared
        let context = try updateContext()
        let manga = store.createManga(.init(sourceKey: "updates", key: "title", title: "First"), context: context)
        func chapter(_ key: String, _ language: String, _ scanlator: String?) -> ChapterObject {
            let object = ChapterObject(context: context)
            object.manga = manga
            object.sourceId = manga.sourceId
            object.mangaId = manga.id
            object.id = key
            object.lang = language
            object.scanlator = scanlator
            return object
        }
        let joint = chapter("joint", "ja", "Group A, Group B")
        let wrongTeam = chapter("wrong-team", "ja", "Group C")
        let wrongLanguage = chapter("wrong-language", "en", "Group B")
        let unnamed = chapter("unnamed", "ja", nil)
        let chapters = [joint, wrongTeam, wrongLanguage, unnamed, joint]
        func insert(_ language: String?, _ scanlators: [String]) throws -> Int {
            try store.createMangaUpdates(mangaId: manga.identifier, chapters: chapters, language: language, scanlators: scanlators, context: context)
        }
        #expect(try insert("ja", ["Group B", ""]) == 2)
        #expect(Set(store.getUpdates(context: context).compactMap(\.chapterId)) == ["joint", "unnamed"])
        #expect(try insert(nil, ["Group B"]) == 1)
        try context.save()
        #expect(try insert("ja", []) == 1)
        #expect(try insert(nil, []) == 0)
        #expect(store.getUpdates(context: context).count == 4)
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

        var saveFailed = false
        do {
            try await writer.perform(for: ids[0], in: container) { context in
                let invalid = MangaUpdateObject(context: context)
                invalid.sourceId = nil
                try context.save()
            }
        } catch {
            saveFailed = true
        }
        #expect(saveFailed)

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

    @Test func feedPagesResolveRestoredRowsAndCountOrphansInTheOffset() throws {
        let store = CoreDataManager.shared
        let context = try updateContext()
        let first = store.createManga(.init(sourceKey: "s1", key: "same", title: "First"), context: context)
        let second = store.createManga(.init(sourceKey: "s2", key: "same", title: "Second"), context: context)
        func add(_ source: String, _ chapter: String, _ date: Double) -> MangaUpdateObject {
            let row = MangaUpdateObject(context: context)
            row.sourceId = source
            row.mangaId = "same"
            row.chapterId = chapter
            row.date = Date(timeIntervalSince1970: date)
            return row
        }
        _ = add("missing", "orphan", 5)
        let linked = add(first.sourceId, "new", 4)
        let chapter = ChapterObject(context: context)
        chapter.id = "new"
        chapter.mangaId = first.id
        chapter.sourceId = first.sourceId
        chapter.title = "New chapter"
        chapter.manga = first
        linked.chapter = chapter
        _ = add(second.sourceId, "new", 3)
        _ = add(first.sourceId, "older", 2)
        try context.save()
        context.reset()

        let page = MangaUpdatesView.loadPage(limit: 3, offset: 0, context: context)
        #expect(page.fetched == 3)
        #expect(page.updates.map(\.manga.title) == ["First", "Second"])
        #expect(page.updates.map(\.chapter?.title) == ["New chapter", nil])
        let next = MangaUpdatesView.loadPage(limit: 3, offset: page.fetched, context: context)
        #expect(next.updates.map(\.id.chapterKey) == ["older"])
    }

    @Test func automaticRefreshRechecksIntervalActivityAndRetryDate() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        func action(_ interval: String, _ lastUpdated: Date, active: Bool, retry: Date = .distantPast) -> LibraryAutomaticRefresh {
            .action(interval: interval, lastUpdated: lastUpdated, retryAfter: retry, now: now, canStart: active)
        }
        let yesterday = now.addingTimeInterval(-86_400)
        #expect(action("daily", yesterday, active: true) == .start)
        #expect(action("daily", yesterday, active: false) == .schedule(now))
        #expect(action("daily", now, active: true) == .schedule(now.addingTimeInterval(86_400)))
        #expect(action("weekly", yesterday, active: true) == .schedule(yesterday.addingTimeInterval(604_800)))
        #expect(action("12hours", yesterday, active: true, retry: now.addingTimeInterval(300)) == .schedule(now.addingTimeInterval(300)))
        #expect(action("never", yesterday, active: true) == .disabled)
        #expect(action("unknown", yesterday, active: false) == .disabled)
    }

    @Test func committedNotificationsFinishAfterCancellationAndRecheckActivity() async throws {
        let probe = NotificationProbe()
        let manager = NotificationManager(client: .init(
            canDeliver: { probe.background },
            authorization: { await probe.status() },
            requestPermission: { false },
            submit: { request in
                try Task.checkCancellation()
                await probe.record(request.content.title)
            }
        ))
        let summaries = ["One", "Two"].map {
            NotificationManager.NewChaptersSummary(mangaIdentifier: .init(sourceKey: "source", mangaKey: $0), mangaTitle: $0, chapterCount: 1)
        }
        await Task {
            withUnsafeCurrentTask { $0?.cancel() }
            await manager.notifyNewChapters(summaries)
        }.value
        #expect(probe.sent == ["One", "Two"])
        #expect(probe.lookups == 1)
        let gate = UpdatesTurnGate()
        probe.gate = gate
        let pending = Task { await manager.notifyNewChapters(summaries) }
        try await waitUntil { gate.started }
        probe.background = false
        gate.release()
        await pending.value
        await manager.notifyNewChapters(summaries)
        #expect(probe.sent == ["One", "Two"])
        #expect(probe.lookups == 2)
    }

    @Test func concurrentPermissionRequestsShareOneStatusLookupAndPrompt() async throws {
        let probe = NotificationProbe()
        let gate = UpdatesTurnGate()
        probe.gate = gate
        probe.permission = .notDetermined
        let manager = NotificationManager(client: .init(
            canDeliver: { true },
            authorization: { await probe.status() },
            requestPermission: { await probe.grant() },
            submit: { _ in }
        ))
        let first = Task { await manager.requestAuthorization() }
        try await waitUntil { gate.started }
        let joined = await manager.joinPermissionRequest(releasing: gate)
        #expect(await first.value)
        #expect(joined)
        #expect(probe.lookups == 1)
        #expect(probe.prompts == 1)
    }

    @Test func expiredDeliveryCancelsOnlyItsWorkerAndFinishesOnce() async throws {
        let completions = BackgroundRefreshCompletions()
        let delivery = LibraryBackgroundRefresh { completions.record($0) }
        let gate = UpdatesTurnGate()
        let worker = try #require(delivery.start {
            await gate.wait()
            return true
        })
        try await waitUntil { gate.started }
        #expect(delivery.start { false } == nil)
        let other = LibraryBackgroundRefresh { completions.record($0) }
        let independent = try #require(other.start { true })

        delivery.expire()
        delivery.expire()
        #expect(worker.isCancelled)
        gate.release()
        await worker.value
        await independent.value
        other.expire()
        #expect(!independent.isCancelled)
        #expect(completions.values.sorted { !$0 && $1 } == [false, true])
    }

    @Test func deliveryExpiredBeforeStartCannotLaunchRefresh() {
        let completions = BackgroundRefreshCompletions()
        let delivery = LibraryBackgroundRefresh { completions.record($0) }
        delivery.expire()
        #expect(delivery.start { true } == nil)
        #expect(completions.values == [false])
    }

    private func updateContext() throws -> NSManagedObjectContext {
        let coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: nil, at: URL(fileURLWithPath: "/dev/null"))
        let context = NSManagedObjectContext(concurrencyType: .mainQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }

    @Test func viewedNotificationDuringPaginationUpdatesOnlyTheMatchingPublishedRows() async throws {
        let owner = MangaUpdatesOperationQueue()
        let gate = UpdatesTurnGate()
        func item(_ source: String) -> MangaUpdatesView.Item {
            let manga = AidokuRunner.Manga(sourceKey: source, key: "same", title: source)
            let info = MangaUpdatesView.UpdateInfo(
                chapterIdentifier: .init(sourceKey: source, mangaKey: manga.key, chapterKey: "same"),
                date: .distantPast, manga: manga, chapter: nil, viewed: false
            )
            return .init(mangaId: manga.identifier, updates: [info])
        }
        let snapshot = MangaUpdatesView.UpdateSection(day: 0, items: [item("a"), item("b")])
        var entries: [MangaUpdatesView.UpdateSection] = []
        let binding = Binding(get: { entries }, set: { entries = $0 })
        let page = Task {
            await owner.run {
                await gate.wait()
                entries = [snapshot]
            }
        }
        try await waitUntil { gate.started }
        var entered = false
        let notification = Task {
            entered = true
            await owner.markViewed([snapshot.items[0].updates[0].id], in: binding)
        }
        try await waitUntil { entered }
        #expect(entries.isEmpty)
        gate.release()
        await page.value
        await notification.value
        #expect(entries.first?.items.flatMap { $0.updates.map(\.viewed) } == [true, false])
    }

    @Test func updatesDeletionRecoveryAndPaginationShareOneOperationOwner() async throws {
        let owner = MangaUpdatesOperationQueue()
        let gate = UpdatesTurnGate()
        var order: [String] = []
        var active = 0
        var maximumActive = 0
        let page = Task {
            await owner.run {
                active += 1; maximumActive = max(maximumActive, active)
                order.append("page-start")
                await gate.wait()
                order.append("page-end")
                active -= 1
            }
        }
        try await waitUntil { gate.started }
        var entered = 0
        let failedDelete = Task {
            entered += 1
            await owner.run {
                active += 1; maximumActive = max(maximumActive, active)
                order.append("delete-failed")
                await Task.yield() // recovery belongs to this same owned turn
                order.append("recovery-end")
                active -= 1
            }
        }
        try await waitUntil { entered == 1 }
        let nextPage = Task {
            entered += 1
            await owner.run {
                active += 1; maximumActive = max(maximumActive, active)
                order.append("next-page")
                active -= 1
            }
        }
        try await waitUntil { entered == 2 }
        #expect(order == ["page-start"])
        gate.release()
        await page.value
        await failedDelete.value
        await nextPage.value
        #expect(order == ["page-start", "page-end", "delete-failed", "recovery-end", "next-page"])
        #expect(maximumActive == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FixtureTimeout()
    }
    private struct FixtureTimeout: Error {}
}

@MainActor
private final class UpdatesTurnGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}

private final class BackgroundRefreshCompletions: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [Bool] = []
    var values: [Bool] { lock.withLock { recorded } }
    func record(_ value: Bool) { lock.withLock { recorded.append(value) } }
}

@MainActor
private final class NotificationProbe {
    var background = true
    var gate: UpdatesTurnGate?
    var permission = UNAuthorizationStatus.authorized
    var sent: [String] = []
    var lookups = 0
    var prompts = 0
    func record(_ title: String) { sent.append(title) }
    func status() async -> UNAuthorizationStatus {
        lookups += 1
        await gate?.wait()
        return permission
    }
    func grant() -> Bool {
        prompts += 1
        return true
    }
}

private extension NotificationManager {
    func joinPermissionRequest(releasing gate: UpdatesTurnGate) async -> Bool {
        Task { await gate.release() }
        return await requestAuthorization()
    }
}
