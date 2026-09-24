import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct DownloadAuditTests {
    @Test func cancellingSubsetBeforeWorkerStartsLeavesOtherMangaQueued() async {
        let source = "test.audit." + UUID().uuidString
        let root = DownloadManager.directory.appendingSafePathComponent(source)
        let previous = UserDefaults.standard.object(forKey: "Data.downloadQueueState")
        defer { root.removeItem(); UserDefaults.standard.set(previous, forKey: "Data.downloadQueueState") }
        let queue = DownloadQueue(cache: DownloadCache())
        let first = await queue.add(chapters: [.init(key: "1")], manga: .init(sourceKey: source, key: "a", title: "A"), autoStart: false)
        let second = await queue.add(chapters: [.init(key: "2")], manga: .init(sourceKey: source, key: "b", title: "B"), autoStart: false)
        await queue.cancelDownloads(for: first.map(\.chapterIdentifier))
        #expect(await queue.queue[source] == second)
        await queue.cancelDownloads(for: second.map(\.chapterIdentifier))
        #expect(await !queue.hasQueuedDownloads())
    }

    @Test func repeatedFolderSharingUsesDistinctCompleteArchives() async throws {
        let id = ChapterIdentifier(sourceKey: "test.audit." + UUID().uuidString, mangaKey: "book", chapterKey: "chapter.1")
        let cache = DownloadCache()
        let root = cache.directory(sourceKey: id.sourceKey)
        defer { root.removeItem() }
        let folder = cache.directory(for: id)
        folder.createDirectory()
        try Data("page".utf8).write(to: folder.appendingPathComponent("001.txt"))
        let manager = DownloadManager()
        let first = try #require(await manager.getCompressedFile(for: id))
        defer { first.removeItem() }
        let second = try #require(await manager.getCompressedFile(for: id))
        defer { second.removeItem() }
        #expect(first != second)
        #expect(DownloadedChapterFile.pageCount(in: first) == 1)
        #expect(DownloadedChapterFile.pageCount(in: second) == 1)
        let chapters = await manager.getDownloadedChapters(for: id.mangaIdentifier)
        #expect(chapters.first?.chapterId == "chapter.1")
    }

    @Test func failedMetadataMigrationPreservesOriginal() async throws {
        let root = DownloadManager.directory.appendingSafePathComponent("test.audit." + UUID().uuidString)
        defer { root.removeItem() }
        let manga = root.appendingPathComponent("book")
        let chapter = manga.appendingPathComponent("chapter")
        chapter.createDirectory()
        let original = chapter.appendingPathComponent(".metadata.json")
        try Data("{broken".utf8).write(to: original)
        await DownloadManager().migrateOldMetadata()
        #expect(original.exists)
    }

    @Test func cacheIgnoresCoverAndPreservesDottedDirectoryKeys() throws {
        let source = "test.audit.\(UUID().uuidString)"
        let manga = MangaIdentifier(sourceKey: source, mangaKey: "book")
        let root = DownloadManager.directory.appendingSafePathComponent(source)
        defer { root.removeItem() }
        let directory = root.appendingSafePathComponent(manga.mangaKey)
        directory.createDirectory()
        try Data([0]).write(to: directory.appendingPathComponent("cover.png"))
        let emptyCache = DownloadCache()
        #expect(!emptyCache.hasDownloadedChapter(from: manga))
        #expect(!emptyCache.isChapterDownloaded(identifier: .init(sourceKey: source, mangaKey: "book", chapterKey: "cover")))
        directory.appendingPathComponent("chapter.1", isDirectory: true).createDirectory()
        let cache = DownloadCache()
        #expect(cache.isChapterDownloaded(identifier: .init(sourceKey: source, mangaKey: "book", chapterKey: "chapter.1")))
        #expect(!cache.isChapterDownloaded(identifier: .init(sourceKey: source, mangaKey: "book", chapterKey: "chapter")))
    }

    @Test func nonFiniteVolumeMetadataDoesNotTrap() {
        let manga = AidokuRunner.Manga(sourceKey: "test", key: "book", title: "Book")
        #expect(ComicInfo.load(manga: manga, chapter: .init(key: "1", volumeNumber: .infinity)).volume == nil)
        #expect(ComicInfo.load(manga: manga, chapter: .init(key: "1", volumeNumber: .nan)).volume == nil)
        #expect(ComicInfo.load(manga: manga, chapter: .init(key: "1", volumeNumber: 2.5)).volume == 2)
    }

    @Test func cancellingBeforeWorkerStartsRemovesQueueAndStaging() async {
        let source = "test.audit.\(UUID().uuidString)"
        let root = DownloadManager.directory.appendingSafePathComponent(source)
        let previous = UserDefaults.standard.object(forKey: "Data.downloadQueueState")
        defer {
            root.removeItem()
            UserDefaults.standard.set(previous, forKey: "Data.downloadQueueState")
        }
        let cache = DownloadCache()
        let queue = DownloadQueue(cache: cache)
        let manga = AidokuRunner.Manga(sourceKey: source, key: "book", title: "Book")
        let downloads = await queue.add(chapters: [.init(key: "1"), .init(key: "2")], manga: manga, autoStart: false)
        #expect(downloads.count == 2)
        await queue.cancelDownload(for: downloads[0].chapterIdentifier)
        #expect(await queue.queue[source]?.count == 1)
        #expect(!cache.tmpDirectory(for: downloads[0].chapterIdentifier).exists)
        await queue.cancelDownloads(for: manga.identifier)
        #expect(!(await queue.hasQueuedDownloads()))
        #expect(!cache.tmpDirectory(for: downloads[1].chapterIdentifier).exists)
        _ = await queue.add(chapters: [.init(key: "3")], manga: manga, autoStart: false)
        await queue.cancelAll()
        #expect(!(await queue.hasQueuedDownloads()))
        #expect(!cache.tmpDirectory(for: .init(sourceKey: source, mangaKey: "book", chapterKey: "3")).exists)
    }
}

@MainActor
struct DownloadPrefetchCancellationTests {
    @Test(arguments: [false, true])
    func cancellationDuringSourceLookupDoesNotIndexRemovedChapter(cancelAll: Bool) async {
        let sourceKey = "test.prefetch." + UUID().uuidString
        let cache = DownloadCache()
        defer { cache.directory(sourceKey: sourceKey).removeItem() }
        let manga = AidokuRunner.Manga(sourceKey: sourceKey, key: "book", title: "Book")
        let first = Download.from(manga: manga, chapter: .init(key: "1"))
        let second = Download.from(manga: manga, chapter: .init(key: "2"))
        let task = DownloadTask(id: sourceKey, cache: cache, downloads: [first, second])
        let gate = DownloadSourceLookupGate()
        let prefetch = Task {
            await task.warmNextChapter(after: first) { await gate.lookup() }
            return true
        }
        await gate.waitForLookup()
        if cancelAll {
            await task.cancel()
        } else {
            await task.cancel(chapter: second.chapterIdentifier)
        }
        await gate.release()
        #expect(await prefetch.value)
        #expect(await !task.running)
    }
}

private actor DownloadSourceLookupGate {
    private var lookupContinuation: CheckedContinuation<AidokuRunner.Source?, Never>?
    private var entryContinuation: CheckedContinuation<Void, Never>?

    func lookup() async -> AidokuRunner.Source? {
        await withCheckedContinuation { continuation in
            lookupContinuation = continuation
            entryContinuation?.resume()
            entryContinuation = nil
        }
    }

    func waitForLookup() async {
        if lookupContinuation != nil { return }
        await withCheckedContinuation { entryContinuation = $0 }
    }

    func release() {
        lookupContinuation?.resume(returning: .test(runner: TestableSourceRunner(processesPages: false)))
        lookupContinuation = nil
    }
}

@MainActor
struct DownloadMetadataWriteFailureTests {
    @Test func metadataWriteFailurePropagatesWithoutDeletingPageFiles() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { folder.removeItem() }
        folder.createDirectory()
        let metadata = folder.appendingPathComponent("ComicInfo.xml", isDirectory: true)
        metadata.createDirectory()
        let page = folder.appendingPathComponent("001.txt")
        let original = Data("preserved page".utf8)
        try original.write(to: page)
        let manga = AidokuRunner.Manga(sourceKey: "test", key: "book", title: "Book")
        do {
            try await DownloadManager().saveChapterMetadata(manga: manga, chapter: .init(key: "1"), to: folder)
            Issue.record("A directory at ComicInfo.xml must fail metadata persistence")
        } catch {
            #expect(metadata.isDirectory)
            #expect(try Data(contentsOf: page) == original)
        }
    }

    @Test func savedMetadataPreservesUTF8XMLAndOfflineIdentifiers() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { folder.removeItem() }
        folder.createDirectory()
        let manga = AidokuRunner.Manga(sourceKey: "test", key: "book", title: "한국어 & 日本語")
        let chapter = AidokuRunner.Chapter(key: "chapter.1", title: "<첫 장>", chapterNumber: 1.5, volumeNumber: 2)
        try await DownloadManager().saveChapterMetadata(manga: manga, chapter: chapter, to: folder)
        let actual = try Data(contentsOf: folder.appendingPathComponent("ComicInfo.xml"))
        let xml = try #require(String(data: actual, encoding: .utf8))
        let decoded = try #require(ComicInfo.load(xmlString: xml))
        #expect(decoded.series == manga.title)
        #expect(decoded.title == chapter.title)
        #expect(decoded.toManga()?.identifier == manga.identifier)
        #expect(decoded.toChapter()?.key == chapter.key)
        // Exporting the persisted fields reproduces every byte, including notes,
        // escaping, Unicode, whitespace and chapter/volume numeric formatting.
        #expect(Data(decoded.export().utf8) == actual)
    }
}

@MainActor
struct LocalDeletionSaveFailureTests {
    private enum InjectedFailure: Error { case save }

    @Test(arguments: [false, true])
    func failedDatabaseDeletionDoesNotReleasePathForFileRemoval(removeWholeManga: Bool) async throws {
        let id = "deletion-save-failure-" + UUID().uuidString
        let folder = FileManager.default.documentDirectory.appendingPathComponent("Local").appendingPathComponent(id)
        folder.createDirectory()
        let archive = folder.appendingPathComponent("chapter.cbz")
        let original = Data("archive fixture remains unchanged".utf8)
        try original.write(to: archive)
        let writer = LocalFileDataManager()
        await writer.createManga(url: folder, id: id, title: id)
        await writer.createChapter(mangaId: id, url: archive, id: "1", chapter: 1)
        let failing = LocalFileDataManager(saveDeletion: { _ in throw InjectedFailure.save })
        let path: String?
        if removeWholeManga {
            path = await failing.removeManga(with: id)
        } else {
            path = await failing.removeChapter(mangaId: id, chapterId: "1")
        }
        #expect(path == nil)
        // LocalFileManager's fallback only removes an empty manga. Rollback must
        // restore the chapter so that this second deletion path remains closed.
        #expect(await failing.fetchChapters(mangaId: id).count == 1)
        #expect(await failing.fetchLocalSeries(id: id) != nil)
        #expect(try Data(contentsOf: archive) == original)
        _ = await writer.removeManga(with: id)
        folder.removeItem()
    }
}

struct SourceRequestCookieScopeTests {
    private func storage() throws -> HTTPCookieStorage {
        try #require(URLSessionConfiguration.ephemeral.httpCookieStorage)
    }

    private func cookie(_ name: String, domain: String = "reader.example", path: String = "/", secure: Bool = false) throws -> HTTPCookie {
        var properties: [HTTPCookiePropertyKey: Any] = [
            .name: name, .value: "value-" + name, .domain: domain, .path: path,
            .expires: Date().addingTimeInterval(3600)
        ]
        if secure { properties[.secure] = "TRUE" }
        return try #require(HTTPCookie(properties: properties))
    }

    @Test func eligibleHTTPSCookiesKeepExactHistoricalHeaderAndCacheScope() throws {
        let storage = try storage()
        storage.setCookie(try cookie("clearance", domain: ".reader.example", secure: true))
        storage.setCookie(try cookie("session", path: "/pages", secure: true))
        let url = try #require(URL(string: "https://reader.example/pages/1.png"))
        let before = HTTPCookie.requestHeaderFields(with: storage.allCookies(for: url) ?? [])
        let after = HTTPCookie.requestHeaderFields(with: storage.requestCookies(for: url) ?? [])
        #expect(before == after)
        #expect(storage.requestCookies(for: url)?.count == 2)
        let http = try #require(URL(string: "http://reader.example/pages/1.png"))
        #expect(storage.requestCookies(for: http)?.isEmpty != false)
        #expect(storage.allCookies(for: http)?.count == 2) // broad cache clearing preserved
    }

    @Test func pathAndHostOnlyAndDomainScopeFollowFoundation() throws {
        let storage = try storage()
        storage.setCookie(try cookie("host"))
        storage.setCookie(try cookie("subdomains", domain: ".reader.example"))
        storage.setCookie(try cookie("restricted", path: "/private"))
        for address in ["https://reader.example/public", "https://child.reader.example/", "https://unrelated.example/"] {
            let url = try #require(URL(string: address))
            let scoped = storage.requestCookies(for: url) ?? []
            let foundation = storage.cookies(for: url) ?? []
            #expect(Set(scoped.map(\.name)) == Set(foundation.map(\.name)))
            #expect(!scoped.contains { $0.name == "restricted" })
            if url.host == "child.reader.example" {
                #expect(!scoped.contains { $0.name == "host" })
                #expect(scoped.contains { $0.name == "subdomains" })
            }
            if url.host == "unrelated.example" { #expect(scoped.isEmpty) }
        }
    }
}
