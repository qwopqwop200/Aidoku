import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct HistoryIngestionSchedulingTests {
    @Test func notificationsWaitingOnPaginationCreateOnlyOneSuccessorAtATime() async throws {
        let gate = HistoryIngestionGate()
        let model = HistoryView.ViewModel(historyPageLoader: { limit, offset in await gate.load(limit, offset) },
                                          observesNotifications: false)
        let page = Task { await model.loadMore() }
        try await waitUntil { gate.requests.count == 1 }
        var entered = 0
        let first = Task { entered += 1; await model.fetchNew(count: 1) }
        let second = Task { entered += 1; await model.fetchNew(count: 1) }
        try await waitUntil { entered == 2 }
        gate.finish(0, key: "existing")
        try await waitUntil { gate.requests.count == 2 }
        #expect(gate.activeCount == 1)
        gate.finish(1, key: "first")
        try await waitUntil { gate.requests.count == 3 }
        #expect(gate.activeCount == 1)
        gate.finish(2, key: "second")
        await page.value
        await first.value
        await second.value
        let keys = model.filteredHistory.values.flatMap(\.entries).map(\.chapterId.mangaKey)
        #expect(Set(keys) == ["existing", "first", "second"])
        #expect(keys.count == 3)
        #expect(gate.maximumActive == 1)
        #expect(gate.requests.map(\.limit) == [100, 1, 1])
    }

    @Test func latestSearchIsUsedWhenSuspendedHistoryLoadCommits() async throws {
        let gate = HistoryIngestionGate()
        let model = HistoryView.ViewModel(historyPageLoader: { limit, offset in await gate.load(limit, offset) },
                                          observesNotifications: false)
        let task = Task { await model.loadMore() }
        try await waitUntil { gate.requests.count == 1 }
        await model.search(query: "different", delay: false)
        try await waitUntil { model.searchQuery == "different" }
        gate.finish(0, key: "existing")
        await task.value
        #expect(model.filteredHistory.values.flatMap(\.entries).isEmpty)
        await model.search(query: "existing", delay: false)
        try await waitUntil { !model.filteredHistory.values.flatMap(\.entries).isEmpty }
        #expect(model.filteredHistory.values.flatMap(\.entries).map(\.chapterId.mangaKey) == ["existing"])
    }

    @Test func acknowledgedClearAfterQueuedWorkLeavesNoResurrectedRows() async throws {
        let gate = HistoryIngestionGate()
        let model = HistoryView.ViewModel(historyPageLoader: { limit, offset in await gate.load(limit, offset) },
                                          observesNotifications: false)
        let task = Task { await model.loadMore() }
        try await waitUntil { gate.requests.count == 1 }
        var deletionStarted = false
        let clear = Task { await model.clearHistory { deletionStarted = true; return true } }
        await Task.yield()
        #expect(!deletionStarted)
        gate.finish(0, key: "existing")
        await task.value
        await clear.value
        #expect(deletionStarted)
        #expect(model.filteredHistory.isEmpty)
        #expect(model.loadingState == .idle)
    }

    @Test func deletionDuringNewHistoryReadRetriesInsteadOfDroppingTheNewEvent() async throws {
        let gate = HistoryIngestionGate()
        let model = HistoryView.ViewModel(historyPageLoader: { limit, offset in await gate.load(limit, offset) },
                                          observesNotifications: false)
        let page = Task { await model.loadMore() }
        try await waitUntil { gate.requests.count == 1 }
        gate.finish(0, key: "removed")
        await page.value
        let update = Task { await model.fetchNew(count: 1) }
        try await waitUntil { gate.requests.count == 2 }
        let deleted = ChapterIdentifier(sourceKey: "history-ingestion", mangaKey: "removed", chapterKey: "chapter")
        model.removeStoredHistory(chapterId: deleted)
        gate.finish(1, key: "new")
        try await waitUntil { gate.requests.count == 3 }
        #expect(model.filteredHistory.values.flatMap(\.entries).isEmpty)
        gate.finish(2, key: "new")
        await update.value
        #expect(model.filteredHistory.values.flatMap(\.entries).map(\.chapterId.mangaKey) == ["new"])
        #expect(gate.maximumActive == 1)
        #expect(gate.requests.map(\.limit) == [100, 1, 1])
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
private final class HistoryIngestionGate {
    var requests: [(limit: Int, offset: Int)] = []
    private var waiters: [Int: CheckedContinuation<HistoryView.ViewModel.HistoryBatch, Never>] = [:]
    private(set) var maximumActive = 0
    var activeCount: Int { waiters.count }

    func load(_ limit: Int, _ offset: Int) async -> HistoryView.ViewModel.HistoryBatch {
        let index = requests.count
        requests.append((limit, offset))
        return await withCheckedContinuation { continuation in
            waiters[index] = continuation
            maximumActive = max(maximumActive, waiters.count)
        }
    }

    func finish(_ index: Int, key: String) {
        let chapter = ChapterIdentifier(sourceKey: "history-ingestion", mangaKey: key, chapterKey: "chapter")
        let manga = AidokuRunner.Manga(sourceKey: chapter.sourceKey, key: key, title: key)
        let metadata = HistoryMetadataBatch(manga: [chapter.mangaIdentifier: manga],
                                           chapters: [chapter: .init(key: chapter.chapterKey)])
        let row = HistoryView.ViewModel.HistoryInfo(chapterId: chapter, dateRead: Date().addingTimeInterval(-60),
                                                   progress: 1, total: 10, completed: false)
        waiters.removeValue(forKey: index)?.resume(returning: .init(history: [row], metadata: metadata))
    }
}
