import AidokuRunner
import CoreData
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized)
struct TrackerFollowupSchedulingTests {
    @Test(arguments: [false, true]) func heldUndatedResponsePreservesNewLocalReading(completed: Bool) async throws {
        let fixture = FollowupTrackingFixture()
        try await fixture.prepare()
        await fixture.writeHistory(page: 1, completed: false, date: Date(timeIntervalSince1970: 100))
        let sync = Task { await fixture.manager.syncPageTrackerHistory(tracker: fixture.tracker, manga: fixture.manga, chapters: fixture.chapters) }
        try await waitUntil { await fixture.tracker.readStarted }
        await fixture.writeHistory(page: 20, completed: completed, date: Date(timeIntervalSince1970: 200))
        await fixture.tracker.releaseRead()
        await sync.value
        let result = await fixture.history()
        #expect(result?.progress == 20)
        #expect(result?.completed == completed)
        #expect(result?.date == Date(timeIntervalSince1970: 200))
        await fixture.close()
    }

    @Test func unchangedLocalHistoryStillAcceptsUndatedRemoteProgress() async throws {
        let fixture = FollowupTrackingFixture()
        try await fixture.prepare()
        await fixture.writeHistory(page: 1, completed: false, date: Date(timeIntervalSince1970: 100))
        let sync = Task { await fixture.manager.syncPageTrackerHistory(tracker: fixture.tracker, manga: fixture.manga, chapters: fixture.chapters) }
        try await waitUntil { await fixture.tracker.readStarted }
        await fixture.tracker.releaseRead()
        await sync.value
        #expect(await fixture.history()?.progress == 2)
        await fixture.close()
    }

    @Test(arguments: [false, true]) func unlinkRevokesSnapshotEntriesBeforeTheirTransportStarts(failing: Bool) async throws {
        let fixture = FollowupTrackingFixture()
        try await fixture.prepare()
        await fixture.tracker.setWriteFailure(failing)
        await fixture.manager.setProgress(mangaId: fixture.manga.identifier, chapters: fixture.chapters,
                                          progress: .init(completed: false, page: 5, date: nil))
        try await waitUntil { await fixture.tracker.writes.count == 1 }
        await fixture.removeLink()
        await fixture.tracker.releaseWrite()
        await fixture.manager.waitForPendingPageUpdates()
        #expect(await fixture.tracker.writes == ["one"])
        #expect(await fixture.manager.pendingPageUpdateCount == 0)
        await fixture.close()
    }

    @Test func keyedQueuePreservesNewerIntentAndLatestArrivalOrder() {
        func update(_ chapter: String, page: Int, failures: Int = 0) -> PageTrackUpdate {
            .init(trackerId: "fixture", trackId: "track", chapterId: .init(sourceKey: "fixture", mangaKey: "m", chapterKey: chapter),
                  progress: .init(completed: false, page: page, date: nil), failCount: failures)
        }
        let old = update("one", page: 9)
        let unread = update("one", page: 0)
        let second = update("two", page: 3)
        let merged = PageTrackUpdate.merging(pending: [old, second], updates: [unread])
        #expect(merged == [second, unread])
        #expect(PageTrackUpdate.reconcile(pending: merged, sent: [old, second], failed: [update("one", page: 9, failures: 1)]) == [unread])
    }

    private func waitUntil(_ condition: () async -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(4))
        while !(await condition()) {
            guard ContinuousClock.now < deadline else { throw FollowupTrackerTimeout.expired }
            try await Task.sleep(for: .milliseconds(5))
        }
    }
}

private enum FollowupTrackerTimeout: Error { case expired }
private struct FollowupHistory: Sendable {
    let progress: Int16
    let completed: Bool
    let date: Date?
}
private final class FollowupTrackingFixture: @unchecked Sendable {
    let source = "tracking-followup-" + UUID().uuidString
    let tracker = HeldFollowupTracker()
    lazy var manga = AidokuRunner.Manga(sourceKey: source, key: "manga", title: "Fixture")
    let chapters: [AidokuRunner.Chapter] = [.init(key: "one", title: "One"), .init(key: "two", title: "Two")]
    lazy var defaults = UserDefaults(suiteName: source)!
    lazy var manager = TrackerManager(defaults: defaults, trackerResolver: { [tracker] id in id == tracker.id ? tracker : nil })

    func prepare() async throws {
        let mangaId = manga.identifier
        try await CoreDataManager.shared.container.performBackgroundTask { [tracker] context in
            CoreDataManager.shared.createTrack(id: "remote", trackerId: tracker.id, mangaId: mangaId, title: "Fixture", context: context)
            try context.save()
        }
        _ = manager
    }
    func writeHistory(page: Int, completed: Bool, date: Date) async {
        let chapterId = ChapterIdentifier(sourceKey: source, mangaKey: "manga", chapterKey: "one")
        await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.setProgress(page, chapterId: chapterId, dateRead: date, completed: completed, context: context)
            try? context.save()
        }
    }
    func history() async -> FollowupHistory? {
        let chapterId = ChapterIdentifier(sourceKey: source, mangaKey: "manga", chapterKey: "one")
        return await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getHistory(chapterId: chapterId, context: context).map {
                FollowupHistory(progress: $0.progress, completed: $0.completed, date: $0.dateRead)
            }
        }
    }
    func removeLink() async {
        let mangaId = manga.identifier
        await CoreDataManager.shared.container.performBackgroundTask { [tracker] context in
            CoreDataManager.shared.removeTrack(trackerId: tracker.id, mangaId: mangaId, context: context)
            try? context.save()
        }
    }
    func close() async {
        await tracker.releaseRead()
        await tracker.releaseWrite()
        await manager.waitForPendingPageUpdates()
        await removeLink()
        await CoreDataManager.shared.container.performBackgroundTask { [source] context in
            for object in CoreDataManager.shared.getHistory(sourceKey: source, context: context) { context.delete(object) }
            try? context.save()
        }
        UserDefaults.standard.removePersistentDomain(forName: source)
    }
}
private actor HeldFollowupTracker: PageTracker {
    nonisolated let id = "held-followup"
    nonisolated let name = "Fixture"
    nonisolated let icon: UIImage? = nil
    nonisolated let isLoggedIn = true
    private(set) var readStarted = false
    private(set) var writes: [String] = []
    private var readContinuation: CheckedContinuation<Void, Never>?
    private var writeContinuation: CheckedContinuation<Void, Never>?
    private var writeFailure = false
    func setWriteFailure(_ value: Bool) { writeFailure = value }
    func getProgress(trackId: String, chapters: [AidokuRunner.Chapter]) async throws -> [String: ChapterReadProgress] {
        readStarted = true
        await withCheckedContinuation { readContinuation = $0 }
        return ["one": .init(completed: false, page: 2, date: nil)]
    }
    func setProgress(trackId: String, chapterId: ChapterIdentifier, progress: ChapterReadProgress) async throws {
        writes.append(chapterId.chapterKey)
        if writes.count == 1 { await withCheckedContinuation { writeContinuation = $0 } }
        if writeFailure { throw URLError(.notConnectedToInternet) }
    }
    func releaseRead() { readContinuation?.resume(); readContinuation = nil }
    func releaseWrite() { writeContinuation?.resume(); writeContinuation = nil }
    func getTrackerInfo() async throws -> TrackerInfo { .init(supportedStatuses: [], scoreType: .tenPoint) }
    func register(trackId: String, highestChapterRead: Float?, earliestReadDate: Date?) async throws -> String? { nil }
    func update(trackId: String, update: TrackUpdate) async throws {}
    func getState(trackId: String) async throws -> TrackState { .init() }
    func getUrl(trackId: String) async -> URL? { nil }
    func search(for manga: AidokuRunner.Manga, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func search(title: String, includeNsfw: Bool) async throws -> [TrackSearchItem] { [] }
    func logout() async throws {}
}
