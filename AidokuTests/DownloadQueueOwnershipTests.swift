import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DownloadQueueOwnershipTests {
    @Test func enqueueWhileRetiredWorkerAwaitsTerminalCallbackRunsExactlyOnce() async throws {
        let wifiOnly = AppSettings.downloads.downloadOnlyOnWifi.get()
        AppSettings.downloads.downloadOnlyOnWifi.set(false)
        defer { AppSettings.downloads.downloadOnlyOnWifi.set(wifiOnly); QueueOwnershipProxy.releaseAll() }
        let key = "queue-drain-" + UUID().uuidString
        let cache = DownloadCache()
        defer { cache.directory(sourceKey: key).removeItem() }
        let terminal = QueueOwnershipGate()
        let events = QueueOwnershipEvents()
        let queue = DownloadQueue(cache: cache, workerFactory: { id, cache, downloads, delegate in
            DownloadTask(id: id, cache: cache, downloads: downloads, sourceLookup: { _ in
                await events.lookup()
                return nil
            }, delegate: QueueOwnershipProxy(target: delegate, terminal: terminal, events: events))
        })
        // Workers hold delegates weakly: the registry below owns each proxy.
        let manga = AidokuRunner.Manga(sourceKey: key, key: "book", title: "Fixture")
        _ = await queue.add(chapters: [.init(key: "A")], manga: manga)
        try await wait { await terminal.entries == 1 }
        #expect(await queue.queue[key] == nil)
        _ = await queue.add(chapters: [.init(key: "B")], manga: manga)
        #expect(await queue.queue[key]?.map(\.chapterIdentifier.chapterKey) == ["B"])
        #expect(await events.lookups == 1)
        await terminal.open()
        try await wait { await events.failed.count == 2 }
        try await wait { await queue.queue.isEmpty }
        #expect(await events.lookups == 2, "A and B must each execute once, with no revived old-worker duplicate")
        #expect(await events.failed.map(\.chapterKey) == ["A", "B"])
        await queue.cancelAll()
        QueueOwnershipProxy.releaseAll()
    }

    @Test(arguments: [false, true])
    func enqueueDuringCancelAllWaitsForCleanupAndSurvives(sameSource: Bool) async throws {
        let wifiOnly = AppSettings.downloads.downloadOnlyOnWifi.get()
        AppSettings.downloads.downloadOnlyOnWifi.set(false)
        defer { AppSettings.downloads.downloadOnlyOnWifi.set(wifiOnly) }
        let firstKey = "queue-cancel-old-" + UUID().uuidString
        let nextKey = sameSource ? firstKey : "queue-cancel-new-" + UUID().uuidString
        let cache = DownloadCache()
        defer { cache.directory(sourceKey: firstKey).removeItem(); cache.directory(sourceKey: nextKey).removeItem() }
        let lookup = QueueOwnershipGate()
        let events = QueueOwnershipEvents()
        let queue = DownloadQueue(cache: cache, workerFactory: { id, cache, downloads, delegate in
            DownloadTask(id: id, cache: cache, downloads: downloads, sourceLookup: { _ in
                await events.lookup()
                if id == firstKey { await lookup.wait() }
                return nil
            }, delegate: delegate)
        })
        let old = AidokuRunner.Manga(sourceKey: firstKey, key: "book", title: "Old")
        let new = AidokuRunner.Manga(sourceKey: nextKey, key: "book", title: "New")
        _ = await queue.add(chapters: [.init(key: "A")], manga: old)
        try await wait { await lookup.entries == 1 }
        let cancel = Task { await queue.cancelAll() }
        try await wait { await queue.isCancellingAll }
        let added = Task { await queue.add(chapters: [.init(key: "B")], manga: new, autoStart: false) }
        for _ in 0..<30 { await Task.yield() }
        #expect(await queue.queue[nextKey]?.contains(where: { $0.chapterIdentifier.chapterKey == "B" }) != true)
        await lookup.open()
        await cancel.value
        let entries = await added.value
        #expect(entries.count == 1)
        #expect(await queue.queue[nextKey]?.count == 1)
        #expect(cache.tmpDirectory(for: entries[0].chapterIdentifier).exists)
        #expect(await events.lookups == 1, "New work cannot start inside the old cleanup epoch")
        await queue.resume()
        try await wait { await events.lookups == 2 }
        try await wait { await queue.queue.isEmpty }
        await queue.cancelAll()
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await predicate())
    }
}

private actor QueueOwnershipGate {
    private var openState = false
    var entries = 0
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entries += 1
        if !openState { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        openState = true
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
}

private actor QueueOwnershipEvents {
    var lookups = 0
    var failed: [ChapterIdentifier] = []
    func lookup() { lookups += 1 }
    func failure(_ id: ChapterIdentifier) { failed.append(id) }
}

private final class QueueOwnershipProxy: DownloadTaskDelegate, @unchecked Sendable {
    private static let lock = NSLock()
    private static var retained: [QueueOwnershipProxy] = []
    let target: any DownloadTaskDelegate
    let terminal: QueueOwnershipGate
    let events: QueueOwnershipEvents
    init(target: any DownloadTaskDelegate, terminal: QueueOwnershipGate, events: QueueOwnershipEvents) {
        self.target = target; self.terminal = terminal; self.events = events
        Self.lock.lock(); Self.retained.append(self); Self.lock.unlock()
    }
    static func releaseAll() { lock.lock(); retained.removeAll(); lock.unlock() }
    func taskCancelled(task: DownloadTask) async { await target.taskCancelled(task: task) }
    func taskPaused(task: DownloadTask) async { await target.taskPaused(task: task) }
    func taskFinished(task: DownloadTask) async { await terminal.wait(); await target.taskFinished(task: task) }
    func downloadProgressChanged(download: Download) async { await target.downloadProgressChanged(download: download) }
    func downloadFinished(download: Download) async { await target.downloadFinished(download: download) }
    func downloadFailed(download: Download) async {
        await target.downloadFailed(download: download)
        await events.failure(download.chapterIdentifier)
    }
    func downloadCancelled(download: Download) async { await target.downloadCancelled(download: download) }
}

@Suite(.serialized) @MainActor
struct DownloadCompressedAdmissionTests {
    @Test func queuedTranslatedFilesAreNotReadBeforeAdmissionAndCancelledWaiterNeverReads() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("download-admission-" + UUID().uuidString)
        let bytes = Data(repeating: 7, count: 4096)
        try bytes.write(to: file)
        defer { file.removeItem() }
        let limiter = TranslationProviderRequestLimiter(maximumConcurrentRequests: 2)
        let gate = QueueOwnershipGate()
        let reads = QueueOwnershipReadCounter()
        func launch() -> Task<Int, Error> {
            Task {
                try await DownloadImageTranslator.withAdmittedFile(at: file, limiter: limiter, load: { url in
                    reads.increment()
                    return try Data(contentsOf: url)
                }) { data in
                    await gate.wait()
                    return data.count
                }
            }
        }
        let active = [launch(), launch()]
        try await wait { await gate.entries == 2 }
        let waiting = (0..<10).map { _ in launch() }
        try await wait { await limiter.queuedRequestCount == 10 }
        #expect(reads.count == 2, "Ten waiting file jobs must own no loaded compressed Data")
        waiting[0].cancel()
        _ = try? await waiting[0].value
        #expect(reads.count == 2, "A cancelled admission waiter never touches its source file")
        await gate.open()
        for task in active { #expect(try await task.value == bytes.count) }
        for task in waiting.dropFirst() { #expect(try await task.value == bytes.count) }
        #expect(reads.count == 11)
        #expect(await limiter.queuedRequestCount == 0)
    }

    private func wait(_ predicate: () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await predicate())
    }
}

private final class QueueOwnershipReadCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
    func increment() { lock.lock(); value += 1; lock.unlock() }
}
