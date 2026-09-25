import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LibrarySnapshotSchedulingTests {
    @Test func categoryChangeNeverPublishesAnObsoleteSnapshot() async throws {
        let oldCategory = AppSettings.library.currentCategory.get()
        defer { AppSettings.library.currentCategory.set(oldCategory) }
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.categories = ["A", "B"]
        model.currentCategory = "A"
        model.manga = [Self.row("displayed")]
        let first = Task { await model.loadLibrary() }
        try await waitUntil { gate.requests.count == 1 }
        model.currentCategory = "B"
        var entered = false
        let second = Task { entered = true; await model.loadLibrary() }
        try await waitUntil { entered }
        gate.finish(0, rows: [Self.row("obsolete-A")])
        try await waitUntil { gate.requests.count == 2 }
        #expect(model.manga.map(\.id.mangaKey) == ["displayed"])
        #expect(gate.requests.map(\.category) == ["A", "B"])
        gate.finish(1, rows: [Self.row("current-B")])
        await first.value
        await second.value
        #expect(model.manga.map(\.id.mangaKey) == ["current-B"])
        #expect(gate.maximumActive == 1)
    }

    @Test func notificationBurstHasOneActiveLoadAndOneLatestFollowup() async throws {
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        let first = Task { await model.loadLibrary() }
        try await waitUntil { gate.requests.count == 1 }
        var entered = 0
        let callers = (0..<100).map { _ in Task { entered += 1; await model.loadLibrary() } }
        try await waitUntil { entered == 100 }
        gate.finish(0, rows: [Self.row("old")])
        try await waitUntil { gate.requests.count == 2 }
        gate.finish(1, rows: [Self.row("latest")])
        await first.value
        for caller in callers { await caller.value }
        #expect(gate.requests.count == 2)
        #expect(gate.maximumActive == 1)
        #expect(model.manga.map(\.id.mangaKey) == ["latest"])
    }

    @Test func latestSearchAppliesToTheCompletedSnapshot() async throws {
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        let load = Task { await model.loadLibrary() }
        try await waitUntil { gate.requests.count == 1 }
        await model.search(query: "match")
        gate.finish(0, rows: [Self.row("match"), Self.row("other")])
        await load.value
        #expect(model.manga.map(\.id.mangaKey) == ["match"])
    }

    @Test func sortChangeInvalidatesAnInFlightSnapshot() async throws {
        let oldOption = AppSettings.library.sortOption.get()
        let oldAscending = AppSettings.library.sortAscending.get()
        defer {
            AppSettings.library.sortOption.set(oldOption)
            AppSettings.library.sortAscending.set(oldAscending)
        }
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.sortMethod = .alphabetical
        model.sortAscending = false
        let first = Task { await model.loadLibrary() }
        try await waitUntil { gate.requests.count == 1 }
        let sort = Task { await model.setSort(method: .unreadChapters, ascending: true) }
        try await waitUntil { model.sortMethod == .unreadChapters }
        gate.finish(0, rows: [Self.row("obsolete-order")])
        try await waitUntil { gate.requests.count == 2 }
        #expect(model.manga.isEmpty)
        #expect(gate.requests[1].sortMethod == .unreadChapters)
        #expect(gate.requests[1].sortAscending)
        gate.finish(1, rows: [Self.row("latest-order")])
        await first.value
        await sort.value
        #expect(model.manga.map(\.id.mangaKey) == ["latest-order"])
    }

    @Test(arguments: [false, true])
    func incrementalReadOrOpenInvalidatesPendingSnapshot(read: Bool) async throws {
        let saved = AppSettings.library.filtersData.get()
        defer { AppSettings.library.filtersData.set(saved) }
        let gate = LibrarySnapshotGate()
        let model = LibraryViewModel(snapshotLoader: { await gate.load($0) })
        model.filters = []
        model.pinType = .none
        model.sortMethod = read ? .lastRead : .lastOpened
        model.sortAscending = false
        let a = Self.row("A"), b = Self.row("B")
        model.manga = [a, b]
        let load = Task { await model.loadLibrary() }
        try await waitUntil { gate.requests.count == 1 }
        if read { await model.mangaRead(mangaId: b.id) }
        else { await model.mangaOpened(mangaId: b.id) }
        #expect(model.manga.map(\.id) == [b.id, a.id])
        gate.finish(0, rows: [a, b])
        try await waitUntil { gate.requests.count == 2 }
        #expect(model.manga.map(\.id) == [b.id, a.id])
        gate.finish(1, rows: [b, a])
        await load.value
        #expect(model.manga.map(\.id) == [b.id, a.id])
        #expect(gate.requests.count == 2)
        #expect(gate.maximumActive == 1)
    }

    @Test func visibleAndHiddenSearchRowsKeepIncrementalBadges() async {
        let model = LibraryViewModel()
        model.sortMethod = .alphabetical
        model.sortAscending = false
        let a = Self.row("alpha"), b = Self.row("bravo")
        model.manga = [a, b]
        await model.search(query: "alpha")
        model.applyDownloadCounts([a.id: 3, b.id: 5])
        #expect(model.manga.map(\.downloads) == [3])
        await model.search(query: "bravo")
        #expect(model.manga.map(\.downloads) == [5])
        await model.search(query: "")
        #expect(model.manga.map(\.id) == [a.id, b.id])
        #expect(model.manga.map(\.downloads) == [3, 5])
    }

    private static func row(_ key: String) -> MangaInfo {
        MangaInfo(id: .init(sourceKey: "snapshot-fixture", mangaKey: key), title: key)
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
private final class LibrarySnapshotGate {
    var requests: [LibraryViewModel.LoadRequest] = []
    private var waiters: [Int: CheckedContinuation<LibraryViewModel.Snapshot?, Never>] = [:]
    private(set) var maximumActive = 0

    func load(_ request: LibraryViewModel.LoadRequest) async -> LibraryViewModel.Snapshot? {
        let index = requests.count
        requests.append(request)
        return await withCheckedContinuation { continuation in
            waiters[index] = continuation
            maximumActive = max(maximumActive, waiters.count)
        }
    }

    func finish(_ index: Int, rows: [MangaInfo]) {
        waiters.removeValue(forKey: index)?.resume(returning: .init(manga: rows))
    }
}
