import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct DownloadIdentityAuditTests {
    @Test func sanitizedChapterAliasCannotHitReadReplaceOrDeleteStoredDownload() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("download-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: "part/one")
        let alias = ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: "partone")
        let cache = DownloadCache(directory: root)
        let directory = cache.directory(for: owner)
        try writeMetadata(owner, to: directory)
        let sentinel = directory.appendingPathComponent("001.png")
        let bytes = Data([1, 2, 3])
        try bytes.write(to: sentinel)
        #expect(cache.directory(for: alias).path == directory.path)
        #expect(cache.isChapterDownloaded(identifier: owner))
        #expect(!cache.isChapterDownloaded(identifier: alias))
        #expect(cache.isSafe(chapter: owner))
        #expect(!cache.isSafe(chapter: alias))
        // DownloadManager and DownloadQueue gate deletion/staging cleanup on this check.
        if cache.isSafe(chapter: alias) { try FileManager.default.removeItem(at: cache.directory(for: alias)) }
        #expect(try Data(contentsOf: sentinel) == bytes)
    }

    @Test func sanitizedMangaAliasCannotClaimOrDeleteAnotherManga() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("manga-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let owner = ChapterIdentifier(sourceKey: "source", mangaKey: "series/one", chapterKey: "chapter")
        let alias = ChapterIdentifier(sourceKey: "source", mangaKey: "seriesone", chapterKey: "other")
        let cache = DownloadCache(directory: root)
        try writeMetadata(owner, to: cache.directory(for: owner))
        #expect(cache.hasDownloadedChapter(from: owner.mangaIdentifier))
        #expect(!cache.hasDownloadedChapter(from: alias.mangaIdentifier))
        #expect(!cache.isSafe(manga: alias.mangaIdentifier))
        #expect(!cache.isSafe(chapter: alias))
        #expect(cache.isSafe(chapter: owner))
    }

    @Test func safeLegacyNamesRemainReadableWithoutMetadataAndStagingMismatchIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-identity-" + UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let chapter = ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: "chapter")
        let cache = DownloadCache(directory: root)
        try FileManager.default.createDirectory(at: cache.directory(for: chapter), withIntermediateDirectories: true)
        #expect(cache.isChapterDownloaded(identifier: chapter))
        #expect(cache.isSafe(chapter: chapter))
        let other = ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: "chap/ter")
        try writeMetadata(other, to: cache.tmpDirectory(for: other))
        #expect(!cache.isSafe(chapter: chapter))
        #expect(cache.tmpDirectory(for: other).exists)
    }

    private func writeMetadata(_ id: ChapterIdentifier, to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let manga = AidokuRunner.Manga(sourceKey: id.sourceKey, key: id.mangaKey, title: "Fixture")
        let chapter = AidokuRunner.Chapter(key: id.chapterKey)
        try Data(ComicInfo.load(manga: manga, chapter: chapter).export().utf8)
            .write(to: directory.appendingPathComponent("ComicInfo.xml"), options: .atomic)
    }
}
