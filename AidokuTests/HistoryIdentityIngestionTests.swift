import AidokuRunner
import CoreData
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct HistoryIdentityIngestionTests {
    @Test func persistedBurstUsesEventIdentitiesAndRepeatedEventsDoNotGrowOffset() async throws {
        let fixture = try TemporaryCoreDataStore(configurations: ["Cloud", "Local"])
        defer { fixture.close() }
        let existing = try fixture.insert("existing", secondsAgo: 300)
        let initial = fixture.read([existing])
        let gate = HistoryIdentityGate()
        let model = HistoryView.ViewModel(historyPageLoader: { _, _ in await gate.wait() },
            historyIdentityLoader: { ids in await fixture.read(ids) }, observesNotifications: false)
        let page = Task { await model.loadMore() }
        try await RegressionTestWait.until { gate.started }
        let a = try fixture.insert("A", secondsAgo: 200)
        let b = try fixture.insert("B", secondsAgo: 100)
        // Both notification records are already persisted. A count1 query would
        // incorrectly return B for both callers; use the actual SQLite query.
        let newest = CoreDataManager.shared.getRecentHistory(limit: 1, offset: 0, context: fixture.context)
        #expect(newest.first?.mangaId == "B")
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
        let row = try #require(CoreDataManager.shared.getHistory(chapterId: a, context: fixture.context))
        row.dateRead = Date().addingTimeInterval(-3 * 86_400)
        try fixture.context.save()
        await model.receiveHistoryChange(chapterIds: [a])
        #expect(model.loadedHistoryIdentifiers.filter { $0 == a }.count == 1)
        #expect(model.paginationOffset == 3)
        #expect(model.filteredHistory.values.flatMap(\.entries).contains { $0.chapterId == a })
        #expect(fixture.coordinator.persistentStores.count == 2)
    }
}

private extension TemporaryCoreDataStore {
    func insert(_ key: String, secondsAgo: TimeInterval) throws -> ChapterIdentifier {
        let id = ChapterIdentifier(sourceKey: "identity-event-fixture", mangaKey: key, chapterKey: "chapter")
        let manager = CoreDataManager.shared
        manager.addToLibrary(manga: AidokuRunner.Manga(sourceKey: id.sourceKey, key: key, title: key),
                             chapters: [.init(key: id.chapterKey)], context: context)
        manager.setProgress(1, chapterId: id, totalPages: 10, context: context)
        manager.getHistory(chapterId: id, context: context)?.dateRead = Date().addingTimeInterval(-secondsAgo)
        try context.save()
        return id
    }

    func read(_ ids: [ChapterIdentifier]) -> HistoryView.ViewModel.HistoryBatch {
        HistoryView.ViewModel.readIdentityHistoryBatch(chapterIds: ids, context: context)
    }
}

@MainActor
private final class HistoryIdentityGate {
    private(set) var started = false
    private var waiter: CheckedContinuation<HistoryView.ViewModel.HistoryBatch, Never>?
    func wait() async -> HistoryView.ViewModel.HistoryBatch {
        started = true
        return await withCheckedContinuation { waiter = $0 }
    }
    func release(_ batch: HistoryView.ViewModel.HistoryBatch) { waiter?.resume(returning: batch); waiter = nil }
}
