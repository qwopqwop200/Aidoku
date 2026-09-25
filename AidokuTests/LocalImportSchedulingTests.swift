import CoreData
import Foundation
import Testing
import ZIPFoundation
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LocalImportSchedulingTests {
    private enum Failure: Error { case save }

    @Test func failedImportRollsBackSeriesAndChapterAndCanRetry() async throws {
        let fixture = try ImportStore()
        defer { fixture.close() }
        let failing = LocalFileDataManager(context: fixture.newContext(), saveImport: { _ in throw Failure.save })
        do {
            try await commit(failing, fixture: fixture, chapter: "first")
            Issue.record("Expected durable save failure")
        } catch Failure.save { }
        #expect(await failing.hasSeries(id: "fixture") == false)
        #expect(await failing.fetchChapters(mangaId: "fixture").isEmpty)
        let writer = LocalFileDataManager(context: fixture.newContext())
        try await commit(writer, fixture: fixture, chapter: "first")
        let reopened = LocalFileDataManager(context: fixture.newContext())
        #expect(await reopened.hasSeries(id: "fixture"))
        #expect(await reopened.fetchChapters(mangaId: "fixture").map(\.key) == ["first"])
    }

    @Test func failedSecondChapterPreservesPreviouslyCommittedSeriesAndChapter() async throws {
        let fixture = try ImportStore()
        defer { fixture.close() }
        let writer = LocalFileDataManager(context: fixture.newContext())
        try await commit(writer, fixture: fixture, chapter: "first")
        let failing = LocalFileDataManager(context: fixture.newContext(), saveImport: { _ in throw Failure.save })
        do {
            try await commit(failing, fixture: fixture, chapter: "second")
            Issue.record("Expected second chapter save failure")
        } catch Failure.save { }
        #expect(await failing.hasSeries(id: "fixture"))
        #expect(await failing.fetchChapters(mangaId: "fixture").map(\.key) == ["first"])
        let reopened = LocalFileDataManager(context: fixture.newContext())
        #expect(await reopened.hasSeries(id: "fixture"))
        #expect(await reopened.fetchChapters(mangaId: "fixture").map(\.key) == ["first"])
    }

    @Test func concurrentImportsCreateOneSeriesAndCommitBothChapters() async throws {
        let fixture = try ImportStore()
        defer { fixture.close() }
        let writer = LocalFileDataManager(context: fixture.newContext())
        async let first: Void = commit(writer, fixture: fixture, chapter: "first")
        async let second: Void = commit(writer, fixture: fixture, chapter: "second")
        _ = try await (first, second)
        let verify = fixture.newContext()
        let mangaCount = try await verify.perform {
            try verify.count(for: MangaObject.fetchRequest())
        }
        #expect(mangaCount == 1)
        #expect(Set(await writer.fetchChapters(mangaId: "fixture").map(\.key)) == ["first", "second"])
    }

    @Test func nestedMutationsAndLateEventsProduceExactlyOneTrailingScan() {
        var demand = LocalFileScanDemand()
        demand.request()
        let firstPass = demand.takePass()
        #expect(firstPass)
        // The first scan already took its filesystem snapshot.
        demand.beginMutation(); demand.beginMutation()
        for _ in 0..<1000 { demand.request() }
        demand.endMutation()
        let blockedPass = demand.takePass()
        #expect(demand.mutations == 1 && !blockedPass)
        demand.endMutation()
        let trailingPass = demand.takePass()
        let redundantPass = demand.takePass()
        #expect(trailingPass)
        #expect(!redundantPass)
        // Demand arriving while idle also cannot disappear under a lease.
        demand.beginMutation(); demand.request()
        let leasedPass = demand.takePass()
        #expect(!leasedPass)
        demand.endMutation()
        let releasedPass = demand.takePass()
        let extraPass = demand.takePass()
        #expect(releasedPass && !extraPass)
    }

    @Test func failedReconciliationCannotLeakDeletionsIntoTheNextImport() async throws {
        let fixture = try ImportStore()
        defer { fixture.close() }
        let writer = LocalFileDataManager(context: fixture.newContext(), saveReconciliation: { _ in throw Failure.save })
        try await commit(writer, fixture: fixture, chapter: "first")
        do {
            _ = try await writer.removeMissingChapters(mangaId: "fixture", availableChapters: [])
            Issue.record("Expected reconciliation failure")
        } catch Failure.save { }
        try await commit(writer, fixture: fixture, chapter: "second")
        let reopened = LocalFileDataManager(context: fixture.newContext())
        #expect(Set(await reopened.fetchChapters(mangaId: "fixture").map(\.key)) == ["first", "second"])
    }

    @Test func replayedCanonicalArchiveDoesNotDuplicateCommittedChapter() async throws {
        let fixture = try ImportStore()
        defer { fixture.close() }
        let writer = LocalFileDataManager(context: fixture.newContext())
        try await commit(writer, fixture: fixture, chapter: "first")
        try await writer.commitImport(
            folder: fixture.directory, mangaId: "fixture", mangaTitle: "Fixture", cover: nil, description: nil,
            archive: fixture.directory.appendingPathComponent("./first.cbz"), chapterId: "replay-uuid",
            chapterTitle: "Replay", volume: nil, chapter: 1, comicInfo: nil
        )
        #expect(await writer.fetchChapters(mangaId: "fixture").map(\.key) == ["first"])
    }

    @Test func admittedScanOrdersUploadsAndCancelledWaiterDoesNotBlockNextImport() async throws {
        let fixture = try ImportStore()
        defer { fixture.close() }
        let root = fixture.directory.appendingPathComponent("Local", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let page = fixture.directory.appendingPathComponent("001.txt")
        try Data("page".utf8).write(to: page)
        let archiveURL = fixture.directory.appendingPathComponent("input.cbz")
        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            try archive.addEntry(with: "001.txt", fileURL: page)
        }
        let writer = LocalFileDataManager(context: fixture.newContext())
        let barrier = LocalScanCheckpoint()
        let manager = LocalFileManager(dataManager: writer, startsListener: false, localDirectory: root,
                                       scanCheckpoint: { await barrier.pauseOnce() })
        let scan = Task { await manager.scanLocalFiles() }
        await barrier.waitUntilEntered()
        let start = ProcessInfo.processInfo.systemUptime
        let cancelled = Task { try await manager.uploadFile(from: archiveURL, mangaName: "cancelled") }
        let survivor = Task { try await manager.uploadFile(from: archiveURL, mangaName: "survivor") }
        try await Task.sleep(nanoseconds: 30_000_000)
        #expect(await writer.hasSeries(id: "survivor") == false)
        cancelled.cancel()
        await barrier.resume()
        await scan.value
        do { try await cancelled.value; Issue.record("Cancelled import must not publish") } catch { }
        try await survivor.value
        #expect(await writer.hasSeries(id: "cancelled") == false)
        #expect(await writer.fetchChapters(mangaId: "survivor").count == 1)
        await manager.scanLocalFiles()
        #expect(await writer.fetchChapters(mangaId: "survivor").count == 1)
        print("LOCAL_SCAN_ORDER injectedPauseMS=30 completedWaitMS=\((ProcessInfo.processInfo.systemUptime-start)*1000) survivingChapters=1 cancelledChapters=0")
    }

    private func commit(_ writer: LocalFileDataManager, fixture: ImportStore, chapter: String) async throws {
        try await writer.commitImport(
            folder: fixture.directory, mangaId: "fixture", mangaTitle: "Fixture", cover: nil,
            description: nil, archive: fixture.directory.appendingPathComponent(chapter + ".cbz"),
            chapterId: chapter, chapterTitle: chapter, volume: nil, chapter: 1, comicInfo: nil
        )
    }
}

@MainActor private final class ImportStore {
    let directory: URL
    let coordinator: NSPersistentStoreCoordinator
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("local-import-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        coordinator = NSPersistentStoreCoordinator(managedObjectModel: CoreDataManager.shared.container.managedObjectModel)
        for configuration in ["Cloud", "Local"] {
            try coordinator.addPersistentStore(ofType: NSSQLiteStoreType, configurationName: configuration,
                                              at: directory.appendingPathComponent(configuration + ".sqlite"))
        }
    }
    func newContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
    func close() {
        for store in coordinator.persistentStores { try? coordinator.remove(store) }
        try? FileManager.default.removeItem(at: directory)
    }
}

private actor LocalScanCheckpoint {
    private var entered = false
    private var pause: CheckedContinuation<Void, Never>?
    private var observers: [CheckedContinuation<Void, Never>] = []
    func pauseOnce() async {
        guard !entered else { return }
        entered = true
        let waiting = observers
        observers.removeAll()
        waiting.forEach { $0.resume() }
        await withCheckedContinuation { pause = $0 }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { observers.append($0) }
    }
    func resume() { pause?.resume(); pause = nil }
}
