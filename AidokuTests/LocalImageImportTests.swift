import AidokuRunner
import ImageIO
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

@MainActor
struct LocalImageImportTests {
    @Test func archivePreviewCountsVisiblePagesAndPreservesThumbnailPixelsAndOrder() async throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let source = folder.appendingPathComponent("source.png")
        let archiveURL = folder.appendingPathComponent("preview.cbz")
        var expected: [Data] = []
        do {
            let archive = try Archive(url: archiveURL, accessMode: .create)
            for (name, color) in [("10.png", UIColor.red), ("2.png", .green), ("1.png", .blue), ("11.png", .white)] {
                try writeImage(to: source, color: color)
                try archive.addEntry(with: name, fileURL: source, compressionMethod: .deflate)
                let data = try Data(contentsOf: source)
                let imageSource = try #require(CGImageSourceCreateWithData(data as CFData, nil))
                let thumbnail = try #require(CGImageSourceCreateThumbnailAtIndex(imageSource, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 400
                ] as CFDictionary))
                expected.append(try #require(UIImage(cgImage: thumbnail).pngData()))
            }
            for name in ["3.txt", "2.desc.txt", "__MACOSX/0.png", ".hidden/0.png"] {
                try archive.addEntry(with: name, fileURL: source)
            }
        }
        let result = await LocalFileManager.shared.loadImportFileInfo(url: archiveURL)
        let info = try #require(result)
        #expect(info.pageCount == 5)
        #expect(info.fileType == .cbz)
        #expect(info.previewImages.compactMap { $0.pngData() } == [expected[2], expected[1], expected[0]])
    }

    @Test func invalidDescriptionDoesNotHideLaterValidDescription() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder.createDirectory()
        defer { folder.removeItem() }
        let url = folder.appendingPathComponent("chapter.cbz")
        let archive = try Archive(url: url, accessMode: .create)
        for (name, content) in [("001.txt", "page"), ("000.desc.txt", "invalid"), ("001.desc.txt", "valid")] {
            let file = folder.appendingPathComponent(name)
            try Data(content.utf8).write(to: file)
            try archive.addEntry(with: name, fileURL: file)
        }
        let pages = LocalFileManager.shared.readPages(from: url)
        #expect(pages.count == 1)
        #expect(pages.first?.description == "valid")
    }

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

    @Test func defaultCoverUsesFirstImageAndPreservesChosenCover() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let first = folder.appendingPathComponent("2.png")
        let later = folder.appendingPathComponent("10.png")
        try writeImage(to: first, color: .red)
        try writeImage(to: later, color: .blue)
        do {
            let archive = try Archive(url: folder.appendingPathComponent("chapter.cbz"), accessMode: .create)
            try archive.addEntry(with: "10.png", relativeTo: folder)
            try archive.addEntry(with: "2.png", relativeTo: folder)
        }
        let cover = try #require(LocalFileManager.defaultCover(in: folder))
        #expect(try Data(contentsOf: cover) == Data(contentsOf: first))
        // A user-selected cover must survive rescans and additional imports.
        try writeImage(to: cover, color: .green)
        let chosen = try Data(contentsOf: cover)
        #expect(LocalFileManager.defaultCover(in: folder) == cover)
        #expect(try Data(contentsOf: cover) == chosen)
        // Older imports without a cover can be repaired from their first page.
        try FileManager.default.removeItem(at: cover)
        let repaired = try #require(LocalFileManager.defaultCover(in: folder))
        #expect(try Data(contentsOf: repaired) == Data(contentsOf: first))
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

    @Test(arguments: ["cbz", "ZIP"])
    func sharedArchiveAutomaticallyPersistsPagesAndLibraryEntry(ext: String) async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let name = "SharedArchive-" + UUID().uuidString
        let url = directory.appendingPathComponent(name + "." + ext)
        let page = directory.appendingPathComponent("1.png")
        try writeImage(to: page, color: .blue)
        do {
            let archive = try Archive(url: url, accessMode: .create)
            try archive.addEntry(with: "1.png", relativeTo: directory)
        }
        let manga = try await LocalFileManager.shared.importSharedArchive(from: url)
        #expect(manga.key == name.normalized)
        #expect(manga.chapters?.count == 1)
        let inLibrary = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.hasLibraryManga(mangaId: manga.identifier, context: context)
        }
        #expect(inLibrary)
        #expect(FileManager.default.fileExists(atPath: url.path))
        await MangaManager.shared.removeFromLibrary(mangaId: manga.identifier)
        await LocalFileManager.shared.removeManga(with: manga.key)
    }

    private func writeImage(to url: URL, color: UIColor) throws {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 12, height: 18)).image { context in
            color.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 12, height: 18))
        }
        try #require(image.pngData()).write(to: url)
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

    @Test func singleImageFileIsAcceptedWithoutUserArchive() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".PNG")
        defer { try? FileManager.default.removeItem(at: url) }
        try writeImage(to: url, color: .green)
        let result = await LocalFileManager.shared.loadImportFileInfo(url: url)
        let info = try #require(result)
        #expect(info.name == url.lastPathComponent)
        #expect(info.pageCount == 1)
        #expect(info.fileType == .image)
    }

    @Test func invalidSelectionFailsInsteadOfSilentlyDroppingPages() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("not an image".utf8).write(to: url)
        let result = await LocalFileManager.shared.prepareImageImport(from: [url], name: "Invalid")
        #expect(result == nil)
        let empty = await LocalFileManager.shared.prepareImageImport(from: [], name: "Empty")
        #expect(empty == nil)
    }

    @Test func temporaryFilesAreRemovedWhenImportIsReleased() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var owner: TemporaryLocalImageFile? = TemporaryLocalImageFile(directory: directory)
        #expect(owner?.directory == directory)
        owner = nil
        #expect(!FileManager.default.fileExists(atPath: directory.path))
    }
}

extension LocalImageImportTests {
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

    @Test func comicInfoIgnoresAppleDoubleAndSuffixLookalikes() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        folder.createDirectory()
        defer { folder.removeItem() }
        let url = folder.appendingPathComponent("chapter.cbz")
        let archive = try Archive(url: url, accessMode: .create)
        let file = folder.appendingPathComponent("payload")
        let entries = [
            ("__MACOSX/._ComicInfo.xml", "binary sidecar"),
            ("NotComicInfo.xml", "<ComicInfo><Series>Wrong</Series></ComicInfo>"),
            ("ComicInfo.xml", "<ComicInfo><Series>Right</Series></ComicInfo>")
        ]
        for (name, content) in entries {
            try Data(content.utf8).write(to: file)
            try archive.addEntry(with: name, fileURL: file)
        }
        #expect(ComicInfo.load(from: url)?.series == "Right")
    }

    @Test func hugeImportImagesAreDownsampledBeforeRendering() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
        defer { try? FileManager.default.removeItem(at: url) }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 200, height: 100), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 200, height: 100))
        }
        try #require(image.pngData()).write(to: url)
        let full = try #require(LocalFileManager.loadImportImage(at: url, maxPixels: 200 * 100))
        #expect(full.size == CGSize(width: 200, height: 100))
        let reduced = try #require(LocalFileManager.loadImportImage(at: url, maxPixels: 5000))
        let pixels = reduced.size.width * reduced.scale * reduced.size.height * reduced.scale
        #expect(pixels <= 5000)
        #expect(reduced.size.width > reduced.size.height)
    }
}
