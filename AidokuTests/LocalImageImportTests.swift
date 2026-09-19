import AidokuRunner
import Testing
import UIKit
import ZIPFoundation
@testable import Aidoku

@MainActor
struct LocalImageImportTests {
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
