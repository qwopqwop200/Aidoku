@testable import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct FollowupDiscoveryTests {
    @Test func recoverySharesResultDespiteFirstConsumerCancellationAndStopsRetryLoop() async throws {
        let coordinator = CoverRecoveryCoordinator()
        let gate = FollowupGate()
        let old = URL(string: "https://fixture.invalid/old")!
        let fresh = URL(string: "https://fixture.invalid/new")!
        let key = MangaIdentifier(sourceKey: "fixture", mangaKey: "book")
        let operation: @Sendable () async -> URL? = { await gate.wait(); return fresh }
        let first = Task { await coordinator.recover(identifier: key, failedURL: old, operation: operation) }
        try await wait { await gate.count == 1 }
        let second = Task { await coordinator.recover(identifier: key, failedURL: old, operation: operation) }
        first.cancel()
        await gate.open()
        #expect(await first.value == fresh)
        #expect(await second.value == fresh)
        #expect(await gate.count == 1)
        #expect(await coordinator.recover(identifier: key, failedURL: fresh, operation: operation) == nil)
        #expect(await gate.count == 1)
    }

    @Test func failedRecoveryCanRetryAfterCooldownAndCacheIsBounded() async {
        let clock = FollowupClock()
        let coordinator = CoverRecoveryCoordinator(capacity: 1, now: { clock.now })
        let calls = FollowupCounter()
        let a = MangaIdentifier(sourceKey: "fixture", mangaKey: "a")
        let b = MangaIdentifier(sourceKey: "fixture", mangaKey: "b")
        let operation: @Sendable () async -> URL? = { calls.increment(); return nil }
        _ = await coordinator.recover(identifier: a, failedURL: nil, operation: operation)
        _ = await coordinator.recover(identifier: a, failedURL: nil, operation: operation)
        #expect(calls.value == 1)
        clock.advance(6)
        _ = await coordinator.recover(identifier: a, failedURL: nil, operation: operation)
        #expect(calls.value == 2)
        _ = await coordinator.recover(identifier: b, failedURL: nil, operation: operation)
        _ = await coordinator.recover(identifier: a, failedURL: nil, operation: operation)
        #expect(calls.value == 4, "capacity1 evicts older failed-entry bookkeeping")
    }

    @Test func obsoleteHomeCleanupCannotRemoveNewSubscriberOrMisroutePartial() async throws {
        let publisher = SinglePublisher<Home>()
        let firstGate = FollowupGate(), secondGate = FollowupGate()
        let firstEvents = FollowupCounter(), secondEvents = FollowupCounter()
        let empty = Home(components: [])
        let first = Task {
            try await SourceHomeSubscription.load(publisher: publisher, receive: { _ in firstEvents.increment() }) {
                await firstGate.wait()
                await publisher.send(empty, to: PartialResultSubscription.id)
                return empty
            }
        }
        try await wait { await firstGate.count == 1 }
        let second = Task {
            try await SourceHomeSubscription.load(publisher: publisher, receive: { _ in secondEvents.increment() }) {
                await secondGate.wait()
                await publisher.send(empty, to: PartialResultSubscription.id)
                return empty
            }
        }
        try await wait { await secondGate.count == 1 }
        await firstGate.open()
        _ = try await first.value
        #expect(secondEvents.value == 0, "old invocation must not send to replacement subscriber")
        #expect(await publisher.subscriptionID != nil)
        await secondGate.open()
        _ = try await second.value
        #expect(secondEvents.value == 1)
        #expect(firstEvents.value == 0)
        #expect(await publisher.subscriptionID == nil)
    }

    @Test func failedHomeRemovesItsSubscription() async {
        let publisher = SinglePublisher<Home>()
        do {
            _ = try await SourceHomeSubscription.load(publisher: publisher, receive: { _ in }) {
                throw URLError(.cancelled)
            }
            Issue.record("Expected source error")
        } catch { }
        #expect(await publisher.subscriptionID == nil)
    }

    @Test func revokedMigrationRowStopsSourceFallbackAndRejectsLateMatch() async throws {
        let first = FollowupRunner()
        let next = FollowupRunner()
        let demand = MigrationRowDemand()
        let manga = AidokuRunner.Manga(sourceKey: "fixture", key: "book", title: "Book")
        let sources = [source(first), source(next)]
        let task = Task { await MigrationMatchSearch.firstMatch(for: manga, sources: sources, isNeeded: { demand.isActive }) }
        try await wait { await first.gate.count == 1 }
        demand.revoke()
        await first.gate.open()
        #expect(await task.value == nil)
        // swiftlint:disable:next empty_count
        #expect(await next.gate.count == 0) // Scalar invocation count, not a collection.
        #expect(!demand.isActive)
    }

    @Test func dismissedSearchDoesNotWalkAnotherEmptyPage() async throws {
        let gate = FollowupGate()
        let model = SourceSearchViewModel(getPage: { _, _, _ in
            await gate.wait()
            return .init(entries: [], hasNextPage: true)
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "fixture", filters: [])
        try await wait { await gate.count == 1 }
        let pending = model.cancelPendingRequests()
        await gate.open()
        await pending?.value
        #expect(await gate.count == 1)
        #expect(model.entries.isEmpty)
        #expect(!model.loadingInitial)
    }

    private func source(_ runner: FollowupRunner) -> AidokuRunner.Source {
        .init(key: UUID().uuidString, name: "Fixture", version: 1, contentRating: .safe, runner: runner)
    }
    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await predicate())
    }
}

private actor FollowupGate {
    var count = 0
    private var opened = false
    private var waiting: [CheckedContinuation<Void, Never>] = []
    func wait() async { count += 1; if !opened { await withCheckedContinuation { waiting.append($0) } } }
    func open() { opened = true; let pending = waiting; waiting = []; pending.forEach { $0.resume() } }
}
private final class FollowupCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
private final class FollowupClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value = Date(timeIntervalSince1970: 100)
    var now: Date { lock.lock(); defer { lock.unlock() }; return value }
    func advance(_ seconds: TimeInterval) { lock.lock(); value.addTimeInterval(seconds); lock.unlock() }
}
private actor FollowupRunner: AidokuRunner.Runner {
    nonisolated let features = SourceFeatures()
    let gate = FollowupGate()
    func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        await gate.wait()
        return .init(entries: [.init(sourceKey: "fixture", key: "late", title: "Late")], hasNextPage: false)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga { manga }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] { [] }
}
