import Foundation
import Testing
import ZIPFoundation
@testable import Aidoku

@Suite(.serialized)
struct DownloadMetadataTests {
    @Test func archiveAndFolderReadMetadataAndCountOnlyPages() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("chapter")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let xml = "<ComicInfo><Series>Downloaded series</Series><Title>Chapter title</Title></ComicInfo>"
        try Data(xml.utf8).write(to: folder.appendingPathComponent("ComicInfo.xml"))
        for name in ["001.png", "002.JPG", "003.avif", "004.txt", "001.desc.txt", "cover.png", ".hidden.png"] {
            try Data([1, 2, 3]).write(to: folder.appendingPathComponent(name))
        }
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("fake.png"), withIntermediateDirectories: true)
        let archive = root.appendingPathComponent("chapter.cbz")
        try FileManager.default.zipItem(at: folder, to: archive, shouldKeepParent: false)
        for url in [folder, archive] {
            #expect(DownloadedChapterFile.comicInfo(in: url)?.series == "Downloaded series")
            #expect(DownloadedChapterFile.pageCount(in: url) == 4)
        }
    }

    @Test @MainActor func compressedDownloadListRetainsTitleCoverAndPageCountWithoutLibraryEntry() async throws {
        let source = "metadata-regression-\(UUID().uuidString)"
        let root = DownloadManager.directory.appendingPathComponent(source)
        let manga = root.appendingPathComponent("numeric-id")
        let chapter = manga.appendingPathComponent("chapter")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: chapter, withIntermediateDirectories: true)
        try Data("<ComicInfo><Series>Offline series title</Series></ComicInfo>".utf8)
            .write(to: chapter.appendingPathComponent("ComicInfo.xml"))
        for index in 1...24 {
            try Data([0]).write(to: chapter.appendingPathComponent("\(index).png"))
        }
        try Data([0]).write(to: manga.appendingPathComponent("cover.png"))
        try FileManager.default.zipItem(at: chapter, to: manga.appendingPathComponent("chapter.cbz"), shouldKeepParent: false)
        try FileManager.default.removeItem(at: chapter)
        let manager = DownloadManager()
        let downloads = await manager.getAllDownloadedManga()
        let item = try #require(downloads.first { $0.sourceId == source })
        #expect(item.title == "Offline series title")
        #expect(item.coverUrl == manga.appendingPathComponent("cover.png").absoluteString)
        #expect(item.chapterCount == 1)
        #expect(item.pageCount == 24)
    }

    @Test func missingOrCorruptArchiveDoesNotInventPages() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID().uuidString).cbz")
        defer { try? FileManager.default.removeItem(at: file) }
        #expect(DownloadedChapterFile.pageCount(in: file) == 0)
        try Data("broken".utf8).write(to: file)
        #expect(DownloadedChapterFile.pageCount(in: file) == 0)
        #expect(DownloadedChapterFile.comicInfo(in: file) == nil)
    }
}
