import AidokuRunner
import CoreData
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

@MainActor
struct LocalImageImportTests {
    @Test func archivePagesKeepNumericOrderAndSidecarPrecedence() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder.createDirectory()
        defer { folder.removeItem() }
        let url = folder.appendingPathComponent("chapter.cbz")
        let archive = try Archive(url: url, accessMode: .create)
        let file = folder.appendingPathComponent("payload")
        for path in ["p10.JPG", "extras/002.desc.txt", "__MACOSX/1.jpg", "p2.md", ".hidden/1.png", "002.desc.txt", "p1.avif"] {
            try Data(path.utf8).write(to: file)
            try archive.addEntry(with: path, fileURL: file)
        }
        let pages = LocalFileManager.shared.readPages(from: url)
        #expect(pages.map(\.content) == ["p1.avif", "p2.md", "p10.JPG"].map { .zipFile(url: url, filePath: $0) })
        #expect(pages.map(\.description) == [nil, "002.desc.txt", nil])
        #expect(pages.map(\.hasDescription) == [false, true, false])
    }

    @Test func invalidSharedArchiveDoesNotCreateLibraryEntry() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".cbz")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("invalid archive".utf8).write(to: url)
        do {
            _ = try await LocalFileManager.shared.importSharedArchive(from: url)
            Issue.record("Invalid archive was accepted")
        } catch {
            let manga = await LocalFileDataManager.shared.fetchLocalSeries(id: url.deletingPathExtension().lastPathComponent.normalized)
            #expect(manga == nil)
        }
    }

    @Test func multipleImagesPreserveSelectionOrderAndUseReaderPages() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        // Deliberately use reverse filenames: Photos order must survive preparation.
        let first = directory.appendingPathComponent("10.png")
        let second = directory.appendingPathComponent("2.png")
        try writeImage(to: first, color: .red)
        try writeImage(to: second, color: .blue)
        let result = await LocalFileManager.shared.prepareImageImport(from: [first, second], name: "Selection.png")
        let info = try #require(result)
        #expect(info.pageCount == 2)
        #expect(info.previewImages.count == 2)
        #expect(info.fileType == .image)
        #expect(LocalFileManager.shared.readPages(from: info.url).count == 2)
        let archive = try Archive(url: info.url, accessMode: .read)
        for (index, original) in [first, second].enumerated() {
            let entry = try #require(archive[String(format: "%08d.png", index + 1)])
            var data = Data()
            _ = try archive.extract(entry) { data.append($0) }
            let actual = try #require(UIImage(data: data)?.cgImage?.dataProvider?.data)
            let expected = try #require(UIImage(contentsOfFile: original.path)?.cgImage?.dataProvider?.data)
            #expect(actual == expected)
        }
    }

    @Test func cappedArchiveExtractionRejectsOversizedEntries() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder.createDirectory()
        defer { folder.removeItem() }
        let url = folder.appendingPathComponent("bomb.cbz")
        let file = folder.appendingPathComponent("payload")
        try Data(repeating: 0, count: 256 * 1024).write(to: file)
        let archive = try Archive(url: url, accessMode: .create)
        try archive.addEntry(with: "001.desc.txt", fileURL: file, compressionMethod: .deflate)
        let entry = try #require(archive["001.desc.txt"])
        #expect(throws: ArchiveEntryReadError.self) { try archive.extractData(entry, limit: 1024) }
        #expect(try archive.extractData(entry, limit: 256 * 1024).count == 256 * 1024)
    }

    @Test func hugeImportImagesAreDownsampledBeforeRendering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeImage(to: url, color: .red, size: CGSize(width: 200, height: 100))
        let full = try #require(LocalFileManager.loadImportImage(at: url, maxPixels: 200 * 100))
        #expect(full.size == CGSize(width: 200, height: 100))
        let reduced = try #require(LocalFileManager.loadImportImage(at: url, maxPixels: 5000))
        let pixels = reduced.size.width * reduced.scale * reduced.size.height * reduced.scale
        #expect(pixels <= 5000)
        #expect(reduced.size.width > reduced.size.height)
    }

    private func writeImage(to url: URL, color: UIColor, size: CGSize = CGSize(width: 12, height: 18)) throws {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
            color.setFill()
            context.fill(CGRect(origin: .zero, size: size))
        }
        try #require(image.pngData()).write(to: url)
    }
}

@Suite(.serialized) @MainActor
struct LocalImportSchedulingTests {
    private enum Failure: Error { case save }

    @Test func failedSecondChapterPreservesPreviouslyCommittedSeriesAndChapter() async throws {
        let fixture = try TemporaryCoreDataStore(configurations: ["Cloud", "Local"])
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

    /// A local root that cannot be listed must not be treated as "no files" and erase stored series.
    @Test func unreadableRootCannotEraseLocalMetadata() async throws {
        let fixture = try TemporaryCoreDataStore(configurations: ["Cloud", "Local"])
        defer { fixture.close() }
        let writer = LocalFileDataManager(context: fixture.newContext())
        try await commit(writer, fixture: fixture, chapter: "chapter")
        let notDirectory = fixture.directory.appendingPathComponent("not-a-directory")
        try Data([1]).write(to: notDirectory)
        let manager = LocalFileManager(dataManager: writer, startsListener: false, localDirectory: notDirectory)
        await manager.scanLocalFiles()
        #expect(await writer.hasSeries(id: "fixture"))
        #expect(await writer.fetchChapters(mangaId: "fixture").map(\.key) == ["chapter"])
    }

    private func commit(_ writer: LocalFileDataManager, fixture: TemporaryCoreDataStore, chapter: String) async throws {
        try await writer.commitImport(
            folder: fixture.directory, mangaId: "fixture", mangaTitle: "Fixture", cover: nil,
            description: nil, archive: fixture.directory.appendingPathComponent(chapter + ".cbz"),
            chapterId: chapter, chapterTitle: chapter, volume: nil, chapter: 1, comicInfo: nil
        )
    }
}

private extension TemporaryCoreDataStore {
    func newContext() -> NSManagedObjectContext {
        let context = NSManagedObjectContext(concurrencyType: .privateQueueConcurrencyType)
        context.persistentStoreCoordinator = coordinator
        return context
    }
}
