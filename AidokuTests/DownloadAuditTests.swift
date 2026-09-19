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
