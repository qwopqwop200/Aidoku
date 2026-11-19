import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized)
struct DownloadPathContainmentTests {
    @Test func componentsPreserveNamesAndRejectNavigationAndAliases() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let downloads = root.appendingPathComponent("Downloads")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: downloads, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let sentinel = outside.appendingPathComponent("sentinel")
        let bytes = Data([0, 1, 2, 3])
        try bytes.write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: downloads.appendingPathComponent("alias"), withDestinationURL: outside)
        for invalid in ["", ".", "..", "/", ":/", "\n", "alias"] {
            #expect(!DownloadCache.isSafeDownloadPath(components: [invalid, "manga", "chapter"], root: downloads))
        }
        for invalid in ["", ".", "..", "/", ":/", "\n"] {
            #expect(!DownloadCache.isSafeDownloadPath(components: ["source", invalid, "chapter"], root: downloads))
            #expect(!DownloadCache.isSafeDownloadPath(components: ["source", "manga", invalid], root: downloads))
        }
        for valid in ["normal", "series/chapter", "a:b", "日本語", "chapter..", ".chapter"] {
            #expect(DownloadCache.isSafeDownloadPath(components: ["source", "manga", valid], root: downloads))
            let original = downloads.appendingSafePathComponent("source").appendingSafePathComponent("manga").appendingSafePathComponent(valid)
            #expect(original.lastPathComponent == valid.directoryName)
        }
        let redirectedRoot = root.appendingPathComponent("RedirectedDownloads")
        try FileManager.default.createSymbolicLink(at: redirectedRoot, withDestinationURL: outside)
        #expect(!DownloadCache.isSafeDownloadPath(components: ["source", "manga"], root: redirectedRoot))
        #expect(!DownloadCache.isSafeChapterPath(source: "source", manga: "manga", chapter: "chapter", root: redirectedRoot))
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    @Test @MainActor func parentChapterCannotDeleteItsSource() async throws {
        let source = "download-path-regression-\(UUID().uuidString)"
        let root = DownloadManager.directory.appendingPathComponent(source)
        defer { try? FileManager.default.removeItem(at: root) }
        let manga = root.appendingPathComponent("manga")
        let other = root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: manga, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let original = Data("unchanged download bytes".utf8)
        let first = manga.appendingPathComponent("sentinel.png")
        let second = other.appendingPathComponent("sentinel.png")
        try original.write(to: first)
        try original.write(to: second)
        await DownloadManager().delete(chapters: [.init(sourceKey: source, mangaKey: "manga", chapterKey: "..")])
        #expect(try Data(contentsOf: first) == original)
        #expect(try Data(contentsOf: second) == original)
    }

    @Test @MainActor func deletingLastCompletedChapterPreservesOtherStagingBytes() async throws {
        let source = "download-staging-regression-\(UUID().uuidString)"
        let root = DownloadManager.directory.appendingPathComponent(source)
        let previousQueue = UserDefaults.standard.object(forKey: "Data.downloadQueueState")
        defer {
            try? FileManager.default.removeItem(at: root)
            UserDefaults.standard.set(previousQueue, forKey: "Data.downloadQueueState")
        }
        let manga = root.appendingPathComponent("manga")
        let completed = manga.appendingPathComponent("completed")
        let staging = manga.appendingPathComponent(DownloadCache.tmpDirectoryPrefix + "next")
        try FileManager.default.createDirectory(at: completed, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let sentinel = staging.appendingPathComponent("001.png")
        let original = Data([137, 80, 78, 71, 13, 10, 26, 10, 1, 2, 3])
        try original.write(to: sentinel)

        await DownloadManager().delete(chapters: [
            .init(sourceKey: source, mangaKey: "manga", chapterKey: "completed")
        ])

        #expect(!completed.exists)
        #expect(try Data(contentsOf: sentinel) == original)
    }

    @Test @MainActor func queueAddCannotFollowMangaSymlink() async throws {
        let source = "queue-path-" + UUID().uuidString
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let savedQueue = UserDefaults.standard.object(forKey: "Data.downloadQueueState")
        let cache = DownloadCache()
        let root = cache.directory(sourceKey: source)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
            UserDefaults.standard.set(savedQueue, forKey: "Data.downloadQueueState")
        }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("alias"), withDestinationURL: outside)
        let manga = AidokuRunner.Manga(sourceKey: source, key: "alias", title: "Queue fixture")
        let chapter = AidokuRunner.Chapter(key: "chapter")
        let staging = cache.tmpDirectory(for: Download.from(manga: manga, chapter: chapter).chapterIdentifier)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        let sentinel = staging.appendingPathComponent("sentinel.png")
        let bytes = Data([0, 7, 255, 3])
        try bytes.write(to: sentinel)

        let queue = DownloadQueue(cache: cache)
        await queue.add(chapters: [chapter], manga: manga, autoStart: false)
        await queue.cancelAll()
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    /// Sanitized directory names collide ("part/one" and "partone"); the alias must not own the stored download.
    @Test @MainActor func sanitizedChapterAliasCannotClaimStoredDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: "part/one")
        let alias = ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: "partone")
        let cache = DownloadCache(directory: root)
        let directory = cache.directory(for: owner)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let metadata = ComicInfo.load(
            manga: AidokuRunner.Manga(sourceKey: owner.sourceKey, key: owner.mangaKey, title: "Fixture"),
            chapter: AidokuRunner.Chapter(key: owner.chapterKey)
        )
        try Data(metadata.export().utf8).write(to: directory.appendingPathComponent("ComicInfo.xml"))
        #expect(cache.directory(for: alias).path == directory.path)
        #expect(cache.isChapterDownloaded(identifier: owner))
        #expect(!cache.isChapterDownloaded(identifier: alias))
        #expect(cache.isSafe(chapter: owner))
        #expect(!cache.isSafe(chapter: alias))
    }
}

struct LocalPathContainmentTests {
    @Test func dotTraversalRootSiblingAndSymlinkEscapeRejectedWithoutTouchingData() throws {
        let fm = FileManager.default
        let sandbox = fm.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let local = sandbox.appendingPathComponent("Local")
        let outside = sandbox.appendingPathComponent("outside")
        try fm.createDirectory(at: local, withIntermediateDirectories: true)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: sandbox) }
        let sentinel = outside.appendingPathComponent("sentinel")
        let original = Data("keep".utf8)
        try original.write(to: sentinel)
        try fm.createSymbolicLink(at: local.appendingPathComponent("link"), withDestinationURL: outside)
        for path in ["..", ".", "", "../outside/sentinel", "../Local-other/target", "link/sentinel", "link/new.png"] {
            #expect(!LocalFileManager.isContainedLocalURL(local.appendingPathComponent(path), root: local))
        }
        let redirectedRoot = sandbox.appendingPathComponent("RedirectedLocal")
        try fm.createSymbolicLink(at: redirectedRoot, withDestinationURL: outside)
        #expect(!LocalFileManager.isContainedLocalURL(redirectedRoot.appendingPathComponent("sentinel"), root: redirectedRoot))
        #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("Series/Volume 1/001.png"), root: local))
        #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("한글/日本語.cbz"), root: local))
        #expect(LocalFileManager.isContainedLocalURL(local.appendingPathComponent("Series/a/../001.png"), root: local))
        #expect(try Data(contentsOf: sentinel) == original)
    }
}
