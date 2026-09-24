import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

/// Dedicated simulator only: real registered built-in source and worker entry,
/// with filesystem error injection at the awaited text-page progress callback.
@Suite(.serialized)
@MainActor
struct DownloadDescriptionPromotionPublicEntryTests {
    private static let marker = URL.documentsDirectory.appendingPathComponent("Round2DownloadFlow/enabled")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: URL.documentsDirectory.appendingPathComponent("Round2DownloadFlow/enabled").path)), arguments: [false, true])
    func realSourceAndWorkerEntryPreservePayloadWhenDescriptionCannotBeWritten(injectFailure: Bool) async throws {
        #expect(try String(contentsOf: Self.marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator")
        guard try String(contentsOf: Self.marker, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines) == "dedicated-audit-simulator" else { return }
        await SourceManager.shared.waitForSourcesLoad()
        if await SourceManager.shared.source(for: "demo") == nil {
            // Leave the newly registered demo fixture available for subsequent
            // tests. Never unregister an existing source or erase its settings.
            let created = await SourceManager.shared.createCustomSource(.demo)
            #expect(created == "demo")
        }
        let source = try #require(await SourceManager.shared.source(for: "demo"))
        let manga = AidokuRunner.Manga(sourceKey: source.key,
            key: "description-promotion-\(UUID().uuidString)", title: "Description persistence fixture")
        let chapter = AidokuRunner.Chapter(key: "3")
        let expectedPages = try await source.getPageList(manga: manga, chapter: chapter)
        #expect(expectedPages.count == 1)
        let expectedPage = try #require(expectedPages.first)
        guard case let .text(text) = expectedPage.content else {
            Issue.record("Built-in demo chapter3 must be a text page")
            return
        }
        #expect(expectedPage.hasDescription)
        let description = try #require(try await source.getPageDescription(page: expectedPage))
        let cache = DownloadCache()
        let item = Download.from(manga: manga, chapter: chapter)
        let staging = cache.tmpDirectory(for: item.chapterIdentifier)
        let final = cache.directory(for: item.chapterIdentifier)
        let ownedMangaDirectory = cache.directory(for: item.mangaIdentifier)
        let previousCompression = AppSettings.downloads.compress.get()
        AppSettings.downloads.compress.set(false)
        defer {
            ownedMangaDirectory.removeItem()
            AppSettings.downloads.compress.set(previousCompression)
        }
        let delegate = PublicEntryDescriptionDelegate(staging: staging, injectFailure: injectFailure)
        let task = DownloadTask(id: UUID().uuidString, cache: cache, downloads: [item], delegate: delegate)
        await task.resume()
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while !(await delegate.drained), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let drained = await delegate.drained
        if !drained { await task.cancel() }
        #expect(drained, "Actual worker must drain through normal finalization")
        guard drained else { return }
        let events = await delegate.events
        #expect(await delegate.progressCount == 1)
        #expect(await delegate.injectionError == nil)
        #expect(await task.running == false)
        if injectFailure {
            #expect(events == ["failed", "drained"])
            #expect(await delegate.terminalStatus == .failed)
            #expect(!final.exists)
            #expect(!final.appendingPathExtension("cbz").exists)
            #expect(!cache.isChapterDownloaded(identifier: item.chapterIdentifier))
            #expect(try Data(contentsOf: staging.appendingPathComponent("001.txt")) == Data(text.utf8))
            #expect(staging.appendingPathComponent("001.desc.txt").isDirectory)
            let failures = try JSONDecoder().decode([Int].self,
                from: Data(contentsOf: cache.failureMarker(inTmpDirectory: staging)))
            #expect(failures == [1])
            #expect(staging.appendingPathComponent("ComicInfo.xml").exists)
        } else {
            #expect(events == ["finished", "drained"])
            #expect(!staging.exists)
            #expect(cache.isChapterDownloaded(identifier: item.chapterIdentifier))
            #expect(try Data(contentsOf: final.appendingPathComponent("001.txt")) == Data(text.utf8))
            #expect(try Data(contentsOf: final.appendingPathComponent("001.desc.txt")) == Data(description.utf8))
            #expect(final.appendingPathComponent("ComicInfo.xml").exists)
        }
    }
}

private actor PublicEntryDescriptionDelegate: DownloadTaskDelegate {
    let staging: URL
    let injectFailure: Bool
    var events: [String] = []
    var progressCount = 0
    var injectionError: String?
    var terminalStatus: DownloadStatus?
    var drained = false
    init(staging: URL, injectFailure: Bool) {
        self.staging = staging
        self.injectFailure = injectFailure
    }
    func taskCancelled(task: DownloadTask) async { events.append("taskCancelled") }
    func taskPaused(task: DownloadTask) async { events.append("paused") }
    func taskFinished(task: DownloadTask) async { events.append("drained"); drained = true }
    func downloadProgressChanged(download: Download) async {
        progressCount += 1
        guard injectFailure else { return }
        do {
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("001.desc.txt"),
                withIntermediateDirectories: false)
        } catch { injectionError = error.localizedDescription }
    }
    func downloadFinished(download: Download) async { events.append("finished"); terminalStatus = download.status }
    func downloadFailed(download: Download) async { events.append("failed"); terminalStatus = download.status }
    func downloadCancelled(download: Download) async { events.append("cancelled"); terminalStatus = download.status }
}
