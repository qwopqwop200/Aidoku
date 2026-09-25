import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DownloadSchedulingContinuityTests {
    @Test func cancellingFutureChapterDoesNotRestartOrJoinActiveLookup() async throws {
        let source = "download-continuity-" + UUID().uuidString
        let cache = DownloadCache()
        defer { cache.directory(sourceKey: source).removeItem() }
        let manga = AidokuRunner.Manga(sourceKey: source, key: "book", title: "Fixture")
        let first = Download.from(manga: manga, chapter: .init(key: "active"))
        let second = Download.from(manga: manga, chapter: .init(key: "future"))
        let gate = DownloadSchedulingGate()
        let observer = DownloadSchedulingDelegate()
        let worker = DownloadTask(id: source, cache: cache, downloads: [first, second], sourceLookup: { _ in
            await gate.wait()
            return nil
        }, delegate: observer)
        await worker.resume()
        try await wait { await gate.entries == 1 }
        let cancellation = Task { await worker.cancel(chapter: second.chapterIdentifier) }
        // The old path joins the held lookup, so this bounded check fails without
        // blocking the suite; releasing below always unwinds either version.
        var cancelledBeforeRelease = false
        for _ in 0..<100 {
            if await observer.cancelled.contains(second.chapterIdentifier) { cancelledBeforeRelease = true; break }
            try await Task.sleep(for: .milliseconds(2))
        }
        #expect(cancelledBeforeRelease)
        #expect(await worker.running)
        #expect(await gate.entries == 1)
        await gate.open()
        await cancellation.value
        try await wait { await observer.finished }
        #expect(await gate.entries == 1, "Queue editing must perform exactly one active source lookup, without a restart")
        #expect(await observer.failed == [first.chapterIdentifier])
        #expect(await observer.cancelled == [second.chapterIdentifier])
    }

    @Test func futureBatchCleanupCannotDeleteReenqueuedChapterDuringCallback() async throws {
        let source = "download-cancel-batch-" + UUID().uuidString
        let cache = DownloadCache()
        defer { cache.directory(sourceKey: source).removeItem() }
        let activeManga = AidokuRunner.Manga(sourceKey: source, key: "active-book", title: "Active")
        let futureManga = AidokuRunner.Manga(sourceKey: source, key: "future-book", title: "Future")
        let first = Download.from(manga: activeManga, chapter: .init(key: "A"))
        let second = Download.from(manga: futureManga, chapter: .init(key: "B"))
        let third = Download.from(manga: futureManga, chapter: .init(key: "C"))
        let secondDirectory = cache.tmpDirectory(for: second.chapterIdentifier)
        let thirdDirectory = cache.tmpDirectory(for: third.chapterIdentifier)
        secondDirectory.createDirectory(); thirdDirectory.createDirectory()
        let gate = DownloadSchedulingGate()
        let observer = DownloadSchedulingDelegate(cancellationGate: gate)
        let worker = DownloadTask(id: source, cache: cache, downloads: [first, second, third], delegate: observer)
        let cancellation = Task { await worker.cancel(manga: futureManga.identifier) }
        try await wait { await gate.entries == 1 }
        #expect(!secondDirectory.exists)
        #expect(!thirdDirectory.exists, "All old filesystem cleanup must precede the first delegate await")
        await worker.add(download: third)
        thirdDirectory.createDirectory()
        let sentinel = thirdDirectory.appendingPathComponent("replacement.txt")
        try Data("replacement generation".utf8).write(to: sentinel)
        await gate.open()
        await cancellation.value
        #expect(try Data(contentsOf: sentinel) == Data("replacement generation".utf8))
        #expect(await observer.cancelled == [second.chapterIdentifier], "Do not emit an obsolete terminal event for re-enqueued C")
        await worker.cancel()
    }

    @Test func twentySnapshotConsumersShareOneScan() async throws {
        let gate = DownloadSchedulingGate()
        let expected = fixture("one")
        let manager = DownloadManager(snapshotLoader: {
            await gate.wait()
            return [expected]
        })
        let consumers = (0..<20).map { _ in Task { await manager.getAllDownloadedManga() } }
        try await wait { await gate.entries == 1 }
        // Let all consumers reach the shared pending task before releasing IO.
        for _ in 0..<50 { await Task.yield() }
        #expect(await gate.entries == 1)
        await gate.open()
        for consumer in consumers { #expect(await consumer.value == [expected]) }
        #expect(await manager.getAllDownloadedManga() == [expected])
        #expect(await gate.entries == 1, "20 consumers plus a warm-cache read must execute one scan")
    }

    @Test func invalidationDuringScanCannotPublishOldSnapshot() async throws {
        let gate = DownloadSchedulingGate()
        let old = fixture("deleted")
        let new = fixture("remaining")
        let manager = DownloadManager(snapshotLoader: {
            let entry = await gate.wait()
            return [entry == 1 ? old : new]
        })
        let first = Task { await manager.getAllDownloadedManga() }
        try await wait { await gate.entries == 1 }
        await manager.invalidateDownloadedMangaCache()
        let second = Task { await manager.getAllDownloadedManga() }
        await gate.open()
        #expect(await first.value == [new])
        #expect(await second.value == [new])
        #expect(await manager.getAllDownloadedManga() == [new])
        #expect(await gate.entries == 2, "One obsolete scan and exactly one shared replacement")
    }

    @Test func refreshBurstRunsOneTrailingPassAndRejectsStalePresentation() async throws {
        let coordinator = DownloadRefreshCoordinator()
        let gate = DownloadSchedulingGate()
        var calls = 0
        var committed: [Int] = []
        let operation: @MainActor (UInt64) async -> Void = { revision in
            calls += 1
            let current = calls
            if current == 1 { await gate.wait() }
            if coordinator.isCurrent(revision) { committed.append(current) }
        }
        let first = Task { await coordinator.refresh(operation) }
        try await wait { await gate.entries == 1 }
        var entered = 0
        let more = (0..<10).map { _ in Task {
            entered += 1
            await coordinator.refresh(operation)
        } }
        try await wait { entered == 10 }
        await gate.open()
        await first.value
        for task in more { await task.value }
        #expect(calls == 2)
        #expect(committed == [2])
        await coordinator.refresh(operation)
        #expect(calls == 3, "A request after completion must not be lost")
        #expect(committed == [2, 3])
    }

    private func fixture(_ id: String) -> DownloadedMangaInfo {
        .init(sourceId: "snapshot-fixture", mangaId: id, totalSize: 10, chapterCount: 1, isInLibrary: false)
    }

    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<400 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}

private actor DownloadSchedulingGate {
    var entries = 0
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    @discardableResult func wait() async -> Int {
        entries += 1
        let entry = entries
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
        return entry
    }
    func open() {
        isOpen = true
        let pending = waiters; waiters.removeAll()
        pending.forEach { $0.resume() }
    }
}

private actor DownloadSchedulingDelegate: DownloadTaskDelegate {
    var cancelled: [ChapterIdentifier] = []
    var failed: [ChapterIdentifier] = []
    var finished = false
    private let cancellationGate: DownloadSchedulingGate?
    init(cancellationGate: DownloadSchedulingGate? = nil) { self.cancellationGate = cancellationGate }
    func taskCancelled(task: DownloadTask) async {}
    func taskPaused(task: DownloadTask) async {}
    func taskFinished(task: DownloadTask) async { finished = true }
    func downloadProgressChanged(download: Download) async {}
    func downloadFinished(download: Download) async {}
    func downloadFailed(download: Download) async { failed.append(download.chapterIdentifier) }
    func downloadCancelled(download: Download) async {
        cancelled.append(download.chapterIdentifier)
        if cancelled.count == 1 { await cancellationGate?.wait() }
    }
}
