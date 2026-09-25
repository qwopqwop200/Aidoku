import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct DownloadQueuePathSafetyTests {
    @MainActor private struct Fixture {
        let source = "queue-path-" + UUID().uuidString
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let savedQueue = UserDefaults.standard.object(forKey: "Data.downloadQueueState")
        let cache = DownloadCache()
        let aliased: Bool
        var root: URL { cache.directory(sourceKey: source) }
        var manga: AidokuRunner.Manga {
            .init(sourceKey: source, key: aliased ? "alias" : "Series/日本語", title: "Queue fixture")
        }
        var chapter: AidokuRunner.Chapter { .init(key: "chapter") }
        var identifier: ChapterIdentifier { Download.from(manga: manga, chapter: chapter).chapterIdentifier }
        var staging: URL { cache.tmpDirectory(for: identifier) }
        var sentinel: URL { staging.appendingPathComponent("sentinel.png") }
        var finished: URL { cache.directory(for: identifier.mangaIdentifier).appendingPathComponent("finished.png") }
        let bytes = Data([0, 7, 255, 3])

        init(aliased: Bool) throws {
            self.aliased = aliased
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if aliased {
                try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: outside)
            }
            try writeSentinels()
        }

        func writeSentinels() throws {
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            try bytes.write(to: sentinel)
            try bytes.write(to: finished)
        }

        func cleanup() {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
            UserDefaults.standard.set(savedQueue, forKey: "Data.downloadQueueState")
        }
    }

    private func cancel(_ operation: String, queue: DownloadQueue, identifier: ChapterIdentifier) async {
        switch operation {
        case "single": await queue.cancelDownload(for: identifier)
        case "multiple": await queue.cancelDownloads(for: [identifier])
        case "manga": await queue.cancelDownloads(for: identifier.mangaIdentifier)
        default: await queue.cancelAll()
        }
    }

    @Test func addCannotFollowMangaSymlink() async throws {
        let fixture = try Fixture(aliased: true)
        defer { fixture.cleanup() }
        let queue = DownloadQueue(cache: fixture.cache)
        let added = await queue.add(chapters: [fixture.chapter], manga: fixture.manga, autoStart: false)
        #expect(added.count == 1)
        #expect(await !queue.isRunning())
        #expect(fixture.sentinel.exists)
        if fixture.sentinel.exists { #expect(try Data(contentsOf: fixture.sentinel) == fixture.bytes) }
        #expect(try Data(contentsOf: fixture.finished) == fixture.bytes)
    }

    @Test(arguments: ["single", "multiple", "manga", "all"])
    func cancelCannotFollowMangaSymlink(operation: String) async throws {
        let fixture = try Fixture(aliased: true)
        defer { fixture.cleanup() }
        let queue = DownloadQueue(cache: fixture.cache)
        await queue.add(chapters: [fixture.chapter], manga: fixture.manga, autoStart: false)
        // Recreate after add so cancellation is independently tested on old code.
        try fixture.writeSentinels()
        await cancel(operation, queue: queue, identifier: fixture.identifier)
        #expect(await !queue.hasQueuedDownloads())
        #expect(fixture.sentinel.exists)
        if fixture.sentinel.exists { #expect(try Data(contentsOf: fixture.sentinel) == fixture.bytes) }
        #expect(try Data(contentsOf: fixture.finished) == fixture.bytes)
    }

    @Test(arguments: ["single", "multiple", "manga", "all"])
    func restoredInvalidQueueCancelsWithoutDeletingFiles(operation: String) async throws {
        let fixture = try Fixture(aliased: true)
        let previousWifiOnly = AppSettings.downloads.downloadOnlyOnWifi.get()
        defer {
            AppSettings.downloads.downloadOnlyOnWifi.set(previousWifiOnly)
            fixture.cleanup()
        }
        // Real loadQueueState entry, with networking disallowed before loading.
        // This guarantees the no-worker branch without touching external sources.
        AppSettings.downloads.downloadOnlyOnWifi.set(true)
        let queue = DownloadQueue(cache: fixture.cache)
        await queue.setWifiAvailable(false)
        let restored = Download.from(manga: fixture.manga, chapter: fixture.chapter)
        UserDefaults.standard.set(try JSONEncoder().encode([fixture.source: [restored]]), forKey: "Data.downloadQueueState")
        await queue.loadQueueState()
        #expect(await queue.queue[fixture.source] == [restored])
        #expect(await !queue.isRunning())
        await cancel(operation, queue: queue, identifier: fixture.identifier)
        #expect(await !queue.hasQueuedDownloads())
        #expect(fixture.sentinel.exists)
        if fixture.sentinel.exists { #expect(try Data(contentsOf: fixture.sentinel) == fixture.bytes) }
        #expect(try Data(contentsOf: fixture.finished) == fixture.bytes)
    }

    @Test(arguments: ["single", "multiple", "manga", "all"])
    func normalQueuePreparationAndCancellationRemainUnchanged(operation: String) async throws {
        let fixture = try Fixture(aliased: false)
        defer { fixture.cleanup() }
        let queue = DownloadQueue(cache: fixture.cache)
        let added = await queue.add(chapters: [fixture.chapter], manga: fixture.manga, autoStart: false)
        #expect(added.count == 1)
        #expect(fixture.staging.exists)
        #expect(!fixture.sentinel.exists)
        try fixture.bytes.write(to: fixture.sentinel)
        await cancel(operation, queue: queue, identifier: fixture.identifier)
        #expect(await !queue.hasQueuedDownloads())
        #expect(!fixture.staging.exists)
        #expect(try Data(contentsOf: fixture.finished) == fixture.bytes)
    }

    @Test(arguments: ["..", ".", "/"])
    func addCannotClearParentOrEmptyNormalizedManga(mangaKey: String) async throws {
        let source = "queue-parent-" + UUID().uuidString
        let chapter = AidokuRunner.Chapter(key: UUID().uuidString)
        let manga = AidokuRunner.Manga(sourceKey: source, key: mangaKey, title: "Queue fixture")
        let cache = DownloadCache()
        let identifier = Download.from(manga: manga, chapter: chapter).chapterIdentifier
        let staging = cache.tmpDirectory(for: identifier).standardizedFileURL
        let root = cache.directory(sourceKey: source)
        let saved = UserDefaults.standard.object(forKey: "Data.downloadQueueState")
        defer {
            // Both paths belong exclusively to this test, even for parent traversal.
            try? FileManager.default.removeItem(at: staging)
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.set(saved, forKey: "Data.downloadQueueState")
        }
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let sentinel = staging.appendingPathComponent("sentinel")
        let bytes = Data([1, 9, 3])
        try bytes.write(to: sentinel)
        let queue = DownloadQueue(cache: cache)
        await queue.add(chapters: [chapter], manga: manga, autoStart: false)
        #expect(sentinel.exists)
        if sentinel.exists { #expect(try Data(contentsOf: sentinel) == bytes) }
    }
}
