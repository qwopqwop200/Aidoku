import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

struct HistoryMetadataCacheTests {
    @Test func newInstanceRestoresSourceAndOnlyTheRequestedChapterWithoutChapterList() throws {
        try withCache { cache, directory in
            var manga = AidokuRunner.Manga(sourceKey: "source-a", key: "manga", title: "Stored title", cover: "https://example.invalid/cover")
            manga.chapters = (0..<1000).map { .init(key: "other-\($0)") }
            let chapter = AidokuRunner.Chapter(key: "one", title: "Chapter 1")
            cache.store(manga: manga, chapters: [chapter], generation: cache.generation)
            let id = ChapterIdentifier(sourceKey: "source-a", mangaKey: "manga", chapterKey: "one")
            let reopened = HistoryMetadataCache(directory: directory)
            let result = reopened.load(chapterIds: [id])
            #expect(result.manga[id.mangaIdentifier]?.sourceKey == "source-a")
            #expect(result.manga[id.mangaIdentifier]?.title == manga.title)
            #expect(result.manga[id.mangaIdentifier]?.cover == manga.cover)
            #expect(result.manga[id.mangaIdentifier]?.chapters == nil)
            #expect(result.chapters[id] == chapter)
            #expect(reopened.load(chapterIds: [.init(sourceKey: "source-b", mangaKey: "manga", chapterKey: "one")]).manga.isEmpty)
            #expect(reopened.load(chapterIds: [.init(sourceKey: "source-a", mangaKey: "manga", chapterKey: "missing")]).chapters.isEmpty)
        }
    }

    @Test func deleteChapterDeleteMangaAndClearRejectLateWriters() throws {
        try withCache { cache, directory in
            let manga = AidokuRunner.Manga(sourceKey: "source", key: "manga", title: "Title")
            let chapters: [AidokuRunner.Chapter] = [.init(key: "a"), .init(key: "b")]
            let ids = chapters.map { ChapterIdentifier(sourceKey: "source", mangaKey: "manga", chapterKey: $0.key) }
            let generation = cache.generation
            cache.store(manga: manga, chapters: chapters, generation: generation)
            cache.remove(chapterIds: [ids[0]])
            cache.store(manga: manga, chapters: chapters, generation: generation)
            #expect(Set(cache.load(chapterIds: ids).chapters.keys) == [ids[1]])
            cache.remove(mangaId: ids[1].mangaIdentifier)
            #expect(HistoryMetadataCache(directory: directory).load(chapterIds: ids).manga.isEmpty)
            cache.store(manga: manga, chapters: chapters, generation: cache.generation)
            let inFlight = cache.generation
            cache.clear()
            cache.store(manga: manga, chapters: chapters, generation: inFlight)
            #expect(HistoryMetadataCache(directory: directory).load(chapterIds: ids).chapters.isEmpty)
        }
    }

    @Test func lruAndExpiryRemainBoundedAcrossReopen() throws {
        try withCache(maxEntries: 2) { cache, directory in
            let base = Date().addingTimeInterval(-600)
            func id(_ key: String) -> ChapterIdentifier { .init(sourceKey: "source", mangaKey: key, chapterKey: "one") }
            func store(_ key: String, _ date: Date) {
                cache.store(manga: .init(sourceKey: "source", key: key, title: key), chapters: [.init(key: "one")],
                            generation: cache.generation, now: date)
            }
            store("a", base)
            store("b", base.addingTimeInterval(1))
            _ = cache.load(chapterIds: [id("a")], now: base.addingTimeInterval(100))
            store("c", base.addingTimeInterval(101))
            let reopened = HistoryMetadataCache(directory: directory, maxEntries: 2)
            let result = reopened.load(chapterIds: [id("a"), id("b"), id("c")], now: base.addingTimeInterval(102))
            #expect(Set(result.chapters.keys) == [id("a"), id("c")])
            #expect(reopened.load(chapterIds: [id("a"), id("c")], now: base.addingTimeInterval(90_000)).manga.isEmpty)
        }
    }

    @Test func diskBudgetOversizedEntriesAndCorruptArchivesFallBackToMisses() throws {
        try withCache(maxBytes: 1800) { cache, directory in
            let ids = (0..<20).map { ChapterIdentifier(sourceKey: "s", mangaKey: "m\($0)", chapterKey: "one") }
            for id in ids {
                cache.store(manga: .init(sourceKey: id.sourceKey, key: id.mangaKey, title: String(repeating: "title", count: 30)),
                            chapters: [.init(key: "one")], generation: cache.generation)
            }
            let file = directory.appendingPathComponent("metadata.json")
            #expect(try Data(contentsOf: file).count <= 1800)
            #expect(cache.load(chapterIds: ids).manga.count < ids.count)
            let oversize = AidokuRunner.Manga(sourceKey: "s", key: "huge", title: String(repeating: "x", count: 40_000))
            cache.store(manga: oversize, chapters: [.init(key: "one")], generation: cache.generation)
            #expect(cache.load(chapterIds: [.init(sourceKey: "s", mangaKey: "huge", chapterKey: "one")]).manga.isEmpty)
            try Data("{bad json".utf8).write(to: file)
            #expect(cache.load(chapterIds: ids).chapters.isEmpty)
            try Data(repeating: 32, count: 1801).write(to: file)
            #expect(cache.load(chapterIds: ids).chapters.isEmpty)
        }
    }

    private func withCache(maxEntries: Int = 256, maxBytes: Int = 2 * 1024 * 1024,
                           _ body: (HistoryMetadataCache, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        try body(HistoryMetadataCache(directory: root, maxEntries: maxEntries, maxBytes: maxBytes), root)
    }
}
