//
//  LocalFileManager.swift
//  Aidoku
//
//  Created by Skitty on 6/6/25.
//

import AidokuRunner
import CoreData
import Foundation
import ImageIO
import UIKit
import ZIPFoundation

/// Manages local files stored in the documents directory for the local files source.
actor LocalFileManager {
    static let shared = LocalFileManager()

    private var lastScanTime = Date.distantPast
    private var scanTask: Task<Void, Never>?

    static let allowedFileExtensions = Set(["cbz", "zip"])
    static let allowedImageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "avif"])
    static let allowedTextExtensions = Set(["txt", "md"])
    static let allowedPageExtensions = allowedImageExtensions.union(allowedTextExtensions)

    private var localFolderFileDescriptor: CInt?
    private var localFolderSource: DispatchSourceFileSystemObject?

    private var suppressFileEvents = false

    private init() {
        Task {
            await startFileSystemListener()
        }
    }

    deinit {
        localFolderSource?.cancel()
        localFolderSource = nil
    }
}

extension LocalFileManager {
    /// Import an archive received through Open In without requiring the import form.
    func importSharedArchive(from url: URL) async throws -> AidokuRunner.Manga {
        guard url.isFileURL, Self.allowedFileExtensions.contains(url.pathExtension.lowercased()),
              loadImportFileInfo(url: url) != nil else {
            throw LocalFileManagerError.invalidFileType
        }
        guard await SourceManager.shared.ensureLocalSourceForImport() else {
            throw LocalFileManagerError.fileCopyFailed
        }
        try await uploadFile(from: url)
        let mangaId = url.deletingPathExtension().lastPathComponent.normalized
        guard var manga = await LocalFileDataManager.shared.fetchLocalSeries(id: mangaId) else {
            throw LocalFileManagerError.fileCopyFailed
        }
        manga.chapters = await LocalFileDataManager.shared.fetchChapters(mangaId: mangaId)
        await MangaManager.shared.addToLibrary(manga: manga, chapters: manga.chapters ?? [])
        return manga
    }

    // get info about a file to be imported
    func loadImportFileInfo(url: URL) -> ImportFileInfo? {
        // if the given url comes from an imported file that isn't copied, we need to do this
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            return prepareImageImport(from: [url], name: url.lastPathComponent)
        }

        // ensure the file is one we can parse
        let pathExtension = url.pathExtension.lowercased()
        guard Self.allowedFileExtensions.contains(pathExtension) else {
            return nil
        }

        // read zip file
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            return nil
        }

        // find image entries (pages)
        let pageEntries = archive
            .filter { entry in
                let lastPathComponent = entry.path.lastPathComponent()
                guard entry.type == .file, !lastPathComponent.hasPrefix("."),
                      !entry.path.split(separator: "/").contains(where: { $0 == "__MACOSX" || ($0 != "." && $0.hasPrefix(".")) }) else {
                    return false
                }
                let ext = entry.path.pathExtension().lowercased()
                if ext == "txt" {
                    return !entry.path.hasSuffix("desc.txt")
                }
                return Self.allowedPageExtensions.contains(ext)
            }
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }

        guard !pageEntries.isEmpty else {
            return nil
        }

        // extract the first three images for preview
        let previewImages = pageEntries
            .filter { LocalFileManager.allowedImageExtensions.contains($0.path.pathExtension().lowercased()) }
            .prefix(3)
            .compactMap { entry -> PlatformImage? in
                var imageData = Data()
                do {
                    _ = try archive.extract(
                        entry,
                        consumer: { data in
                            imageData.append(data)
                        }
                    )
                    guard let source = CGImageSourceCreateWithData(imageData as CFData, nil),
                          let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                            kCGImageSourceCreateThumbnailFromImageAlways: true,
                            kCGImageSourceCreateThumbnailWithTransform: true,
                            kCGImageSourceThumbnailMaxPixelSize: 400
                          ] as CFDictionary) else { return nil }
                    return PlatformImage(cgImage: thumbnail)
                } catch {
                    return nil
                }
            }

        let fileType = switch pathExtension {
            case "cbz": LocalFileType.cbz
            case "zip": LocalFileType.zip
            default: LocalFileType.zip
        }

        return ImportFileInfo(
            url: url,
            previewImages: previewImages,
            name: url.lastPathComponent,
            pageCount: pageEntries.count,
            fileType: fileType,
            comicInfo: ComicInfo.load(from: url)
        )
    }
}

extension LocalFileManager {
    // Keep selection order; process one image at a time to avoid holding every full-resolution photo in memory.
    func prepareImageImport(from urls: [URL], name: String) -> ImportFileInfo? {
        guard !urls.isEmpty else { return nil }
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let temporaryFile = TemporaryLocalImageFile(directory: directory)
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let archiveURL = directory.appendingPathComponent(UUID().uuidString + ".cbz")
            let archive = try Archive(url: archiveURL, accessMode: .create)
            var previews: [PlatformImage] = []
            for (index, url) in urls.enumerated() {
                let accessGranted = url.startAccessingSecurityScopedResource()
                defer { if accessGranted { url.stopAccessingSecurityScopedResource() } }
                try autoreleasepool {
                    guard let image = PlatformImage(contentsOfFile: url.path) else {
                        throw LocalFileManagerError.invalidFileType
                    }
                    // Drawing applies EXIF orientation consistently for reading and OCR.
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                        image.draw(in: CGRect(origin: .zero, size: image.size))
                    }
                    guard let png = normalized.pngData() else { throw LocalFileManagerError.invalidFileType }
                    let pageName = String(format: "%08d.png", index + 1)
                    let pageURL = directory.appendingPathComponent(pageName)
                    try png.write(to: pageURL)
                    try archive.addEntry(with: pageName, fileURL: pageURL)
                    try FileManager.default.removeItem(at: pageURL)
                    if previews.count < 3 {
                        let scale = min(1, 400 / max(image.size.width, image.size.height))
                        let size = CGSize(width: image.size.width * scale, height: image.size.height * scale)
                        previews.append(UIGraphicsImageRenderer(size: size, format: format).image { _ in
                            normalized.draw(in: CGRect(origin: .zero, size: size))
                        })
                    }
                }
            }
            return ImportFileInfo(
                url: archiveURL,
                previewImages: previews,
                name: name,
                pageCount: urls.count,
                fileType: .image,
                comicInfo: nil,
                temporaryImageFile: temporaryFile
            )
        } catch {
            LogManager.logger.error("Failed to prepare local images: \(error)")
            return nil
        }
    }

}

extension LocalFileManager {
    // fetch pages for a chapter from file system
    func fetchPages(mangaId: String, chapterId: String) async -> [AidokuRunner.Page] {
        guard let cbzPath = await LocalFileDataManager.shared.fetchChapterArchivePath(mangaId: mangaId, chapterId: chapterId)
        else { return [] }

        let documentsDir = FileManager.default.documentDirectory
        let archiveURL = documentsDir.appendingPathComponent(cbzPath)
        return readPages(from: archiveURL)
    }

    // read pages from an archive file
    nonisolated func readPages(from archiveURL: URL) -> [AidokuRunner.Page] {
        let archive: Archive
        do {
            archive = try Archive(url: archiveURL, accessMode: .read)
        } catch {
            LogManager.logger.error("Failed to read archive: \(error)")
            return []
        }

        var descriptionFiles: [Entry] = []

        var pages = archive
            .filter { entry in
                // ignore hidden files
                let lastPathComponent = entry.path.lastPathComponent()
                guard entry.type == .file, !lastPathComponent.hasPrefix("."),
                      !entry.path.split(separator: "/").contains(where: { $0 == "__MACOSX" || ($0 != "." && $0.hasPrefix(".")) }) else {
                    return false
                }
                // ensure extension is allowed
                let ext = entry.path.pathExtension().lowercased()
                if ext == "txt" {
                    if entry.path.hasSuffix("desc.txt") {
                        descriptionFiles.append(entry)
                        return false
                    }
                    return true
                }
                return Self.allowedPageExtensions.contains(ext)
            }
            // sort by file name
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            .map { entry in
                AidokuRunner.Page(content: .zipFile(url: archiveURL, filePath: entry.path))
            }

        for entry in descriptionFiles {
            guard
                let index = entry.path
                    .lastPathComponent()
                    .split(separator: ".", maxSplits: 1)
                    .first
                    .flatMap({ Int($0) }),
                index > 0,
                index <= pages.count
            else { continue }

            do {
                var descriptionData = Data()
                _ = try archive.extract(
                    entry,
                    consumer: { data in
                        descriptionData.append(data)
                    }
                )
                pages[index - 1].hasDescription = true
                pages[index - 1].description = String(data: descriptionData, encoding: .utf8)
            } catch {
                LogManager.logger.error("Failed to extract page description text from archive: \(error)")
                continue
            }
        }

        return pages
    }
}

extension LocalFileManager {
    /// Preserve a chosen cover; otherwise use the first image in chapter/page order.
    static func defaultCover(in folder: URL) -> URL? {
        for ext in allowedImageExtensions.sorted() {
            let existing = folder.appendingPathComponent("cover.\(ext)")
            if existing.exists { return existing }
        }
        let chapters = folder.contents.filter { allowedFileExtensions.contains($0.pathExtension.lowercased()) }
            .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        for chapter in chapters {
            guard let archive = try? Archive(url: chapter, accessMode: .read) else { continue }
            let pages = archive.filter {
                $0.type == .file && !$0.path.hasPrefix("__MACOSX/") &&
                allowedImageExtensions.contains(($0.path as NSString).pathExtension.lowercased())
            }.sorted { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            guard let first = pages.first, first.uncompressedSize <= 250 * 1024 * 1024 else { continue }
            let cover = folder.appendingPathComponent("cover.\((first.path as NSString).pathExtension.lowercased())")
            do {
                _ = try archive.extract(first, to: cover)
                return cover
            } catch { try? FileManager.default.removeItem(at: cover) }
        }
        return nil
    }

    // add a new file to the local files source
    // swiftlint:disable:next cyclomatic_complexity
    func uploadFile(
        from url: URL,
        // if the file already exists, skip uploading it to avoid duplicates
        skipUpload: Bool = false,
        // the (optional) manga id to add to
        mangaId: String? = nil,
        // optional metadata for new db objects:
        mangaCoverImage: PlatformImage? = nil,
        mangaName: String? = nil,
        mangaDescription: String? = nil,
        chapterName: String? = nil,
        volume: Float? = nil,
        chapter: Float? = nil
    ) async throws(LocalFileManagerError) {
        // disable file listener while we make changes to the disk
        self.suppressFileEvents = true
        defer { self.suppressFileEvents = false }

        let documentsDirectory = FileManager.default.documentDirectory

        // ensure the file is one we can parse
        guard Self.allowedFileExtensions.contains(url.pathExtension.lowercased()) else {
            throw LocalFileManagerError.invalidFileType
        }

        // if the url isn't in the documents directory, we need to copy it there
        var url = url
        var shouldRemoveUrl = false
        var temporaryDirectory: URL?
        defer { temporaryDirectory?.removeItem() }
        if !url.path.contains(documentsDirectory.path) {
            // if the given url comes from an imported file that isn't copied, we need to do this
            let accessGranted = url.startAccessingSecurityScopedResource()
            defer {
                if accessGranted { url.stopAccessingSecurityScopedResource() }
            }

            // create a temporary url to copy file to
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            temporaryDirectory = directory
            let tempUrl = directory.appendingPathComponent(url.lastPathComponent)
            // copy url to temp folder
            do {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                try FileManager.default.copyItem(at: url, to: tempUrl)
            } catch {
                throw LocalFileManagerError.fileCopyFailed
            }
            // remove the temporary file when done
            shouldRemoveUrl = true
            url = tempUrl
        }
        defer {
            if shouldRemoveUrl {
                try? FileManager.default.removeItem(at: url)
            }
        }

        // read zip file
        let archive: Archive
        do {
            archive = try Archive(url: url, accessMode: .read)
        } catch {
            LogManager.logger.error("Failed to read archive at \(url.path): \(error)")
            throw LocalFileManagerError.cannotReadArchive
        }

        // find image entries (pages)
        let pageEntries = archive
            .filter { entry in
                let lastPathComponent = entry.path.lastPathComponent()
                guard entry.type == .file, !lastPathComponent.hasPrefix("."),
                      !entry.path.split(separator: "/").contains(where: { $0 == "__MACOSX" || ($0 != "." && $0.hasPrefix(".")) }) else {
                    return false
                }
                let ext = entry.path.pathExtension().lowercased()
                if ext == "txt" {
                    return !entry.path.hasSuffix("desc.txt")
                }
                return Self.allowedPageExtensions.contains(ext)
            }
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }

        guard !pageEntries.isEmpty else {
            throw LocalFileManagerError.noImagesFound
        }

        let comicInfo = ComicInfo.load(from: archive)

        let resolvedMangaId = (mangaId ?? mangaName ?? url.deletingPathExtension().lastPathComponent).normalized
        let mangaTitle = mangaName ?? comicInfo?.series ?? resolvedMangaId

        // create new folder for the manga
        let fileManager = FileManager.default
        let localFolder = fileManager.documentDirectory.appendingPathComponent("Local", isDirectory: true)
        localFolder.createDirectory()
        let mangaFolder = localFolder.appendingPathComponent(resolvedMangaId, isDirectory: true)
        mangaFolder.createDirectory()

        // get chapter number
        let chapter = if volume == nil && chapter == nil {
            if let comicInfo, let number = comicInfo.number, let chapter = Float(number) {
                chapter
            } else if let chapter = LocalFileNameParser.getMangaChapterNumber(from: url.lastPathComponent) {
                chapter
            } else if let mangaId {
                await LocalFileDataManager.shared.getNextChapterNumber(series: mangaId)
            } else {
                Float(1)
            }
        } else {
            chapter
        }

        let destURL: URL

        if skipUpload {
            destURL = url
        } else {
            // get new name for file if necessary
            let newFile = if let chapterName {
                if chapterName.isEmpty {
                    if let volume, let chapter {
                        "volume_\(volume)_chapter_\(chapter).\(url.pathExtension)"
                    } else if let volume {
                        "volume_\(volume).\(url.pathExtension)"
                    } else if let chapter {
                        "chapter_\(chapter).\(url.pathExtension)"
                    } else {
                        "\(resolvedMangaId).\(url.pathExtension)"
                    }
                } else {
                    "\(chapterName).\(url.pathExtension)"
                }
            } else {
                url.lastPathComponent
            }

            // copy file to Documents/Local/<mangaId>/<cbzfile>
            var newDestURL = mangaFolder.appendingPathComponent(newFile)
            var counter = 1
            while newDestURL.exists {
                // if the file already exists, append a number to the name
                let name = newFile.removingExtension() + " (\(counter)).\(url.pathExtension)"
                newDestURL = mangaFolder.appendingPathComponent(name)
                counter += 1
            }
            destURL = newDestURL
            do {
                try fileManager.copyItem(at: url, to: destURL)
            } catch {
                throw LocalFileManagerError.fileCopyFailed
            }
        }

        let coverURL: URL?
        if let mangaCoverImage {
            // save provided cover image to manga folder
            let coverFileName = "cover.png"
            let newCoverURL = mangaFolder.appendingPathComponent(coverFileName)
            do {
                guard let data = mangaCoverImage.pngData() else { throw LocalFileManagerError.fileCopyFailed }
                try data.write(to: newCoverURL, options: .atomic)
                coverURL = newCoverURL
            } catch {
                throw LocalFileManagerError.fileCopyFailed
            }
        } else {
            coverURL = Self.defaultCover(in: mangaFolder)
        }

        // create the objects in db
        let hasMangaObject = await LocalFileDataManager.shared.hasSeries(id: resolvedMangaId)
        if !hasMangaObject {
            let cover = coverURL?.toAidokuImageUrl()?.absoluteString ?? {
                // if no cover url, try finding one in the directory
                for ext in Self.allowedImageExtensions {
                    let coverPath = mangaFolder.appendingPathComponent("cover.\(ext)")
                    if coverPath.exists {
                        return coverPath.toAidokuImageUrl()?.absoluteString
                    }
                }
                return nil
            }()
            await LocalFileDataManager.shared.createManga(
                url: mangaFolder,
                id: resolvedMangaId,
                title: mangaTitle,
                cover: cover,
                description: mangaDescription,
                comicInfo: comicInfo
            )
        }

        let title = if let chapterName {
            chapterName.isEmpty ? nil : chapterName
        } else {
            url.deletingPathExtension().lastPathComponent
        }

        await LocalFileDataManager.shared.createChapter(
            mangaId: resolvedMangaId,
            url: destURL,
            id: UUID().uuidString,
            title: title,
            volume: volume,
            chapter: chapter,
            comicInfo: comicInfo
        )
    }
}

extension LocalFileManager {
    func setCover(for mangaKey: String, image: PlatformImage) async -> String? {
        let mangaData = await LocalFileDataManager.shared.fetchLocalSeries(id: mangaKey)

        let previousCover = mangaData?.cover.flatMap(URL.init(string:)).map { $0.toAidokuFileUrl() ?? $0 }

        // upload the new cover
        let fileManager = FileManager.default
        let localFolder = fileManager.documentDirectory.appendingPathComponent("Local", isDirectory: true)
        let mangaFolder = localFolder.appendingPathComponent(mangaKey, isDirectory: true)
        let coverFileName = "cover.png"
        let newCoverURL = mangaFolder.appendingPathComponent(coverFileName)
        do {
            guard let data = image.pngData() else { return nil }
            try data.write(to: newCoverURL, options: .atomic)
        } catch {
            LogManager.logger.error("Failed to write cover image for manga \(mangaKey): \(error)")
            return nil
        }

        if let previousCover, previousCover.isFileURL, previousCover != newCoverURL {
            previousCover.removeItem()
        }
        // set cover image in coredata
        return await CoreDataManager.shared.setCover(
            mangaId: .init(sourceKey: LocalSourceRunner.sourceKey, mangaKey: mangaKey),
            coverUrl: newCoverURL.toAidokuImageUrl()?.absoluteString
        )
    }
}

// MARK: Removing
extension LocalFileManager {
    // remove all db objects and local files associated with a given mangaId
    func removeManga(with mangaId: String) async {
        // remove from db
        let filePath = await LocalFileDataManager.shared.removeManga(with: mangaId)
        guard let filePath else { return }

        // disable file listener while we make changes to the disk
        self.suppressFileEvents = true
        defer { self.suppressFileEvents = false }

        let documentsDir = FileManager.default.documentDirectory
        let fileURL = documentsDir.appendingPathComponent(filePath)
        if fileURL.exists {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // remove a chapter from a given local manga
    func removeChapter(mangaId: String, chapterId: String) async {
        // remove from db
        let filePath = await LocalFileDataManager.shared.removeChapter(mangaId: mangaId, chapterId: chapterId)

        if let filePath {
            // disable file listener while we make changes to the disk
            self.suppressFileEvents = true
            defer { self.suppressFileEvents = false }

            let documentsDir = FileManager.default.documentDirectory
            let fileURL = documentsDir.append(path: filePath)
            if fileURL.exists {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        // remove the manga entry once no chapters remain
        if await LocalFileDataManager.shared.fetchChapters(mangaId: mangaId).isEmpty {
            await removeManga(with: mangaId)
        }
    }

    // remove all local source files and db objects
    func removeAllLocalFiles() async {
        // disable file listener while we make changes to the disk
        self.suppressFileEvents = true

        let fileManager = FileManager.default
        let documentsDir = fileManager.documentDirectory
        let localFolder = documentsDir.appendingPathComponent("Local", isDirectory: true)
        do {
            try fileManager.removeItem(at: localFolder)
        } catch {
            LogManager.logger.error("Failed to remove Local folder: \(error)")
        }

        // update database
        self.suppressFileEvents = false
        await scanLocalFiles()
    }
}

// MARK: Scanning
extension LocalFileManager {
    // performs a scan if the last one was over an hour ago (or if one hasn't been run this app launch)
//    func scanIfNecessary() async {
//        if lastScanTime < Date().addingTimeInterval(-60 * 60) {
//            await scanLocalFiles()
//            lastScanTime = Date()
//        }
//    }

    // scan the local files folder and synchronize the db to match the file system
    func scanLocalFiles() async {
        // don't scan while suppressing file events
        guard !suppressFileEvents else { return }

        // ensure only one scan is running at a time
        guard scanTask == nil else {
            await scanTask?.value
            return
        }

        scanTask = Task {
            let fileManager = FileManager.default
            let documentsDir = fileManager.documentDirectory
            let localFolder = documentsDir.appendingPathComponent("Local", isDirectory: true)
            localFolder.createDirectory()

            // get all manga folders
            let mangaFolders = localFolder.contents.filter { $0.isDirectory }

            let (toRemove, toAdd) = await LocalFileDataManager.shared.findMangaDiskChanges(mangaFolders: mangaFolders)

            // remove manga from db that no longer exist on disk
            for mangaId in toRemove {
                await removeManga(with: mangaId)
            }

            // for each manga folder, ensure chapters in db match local files
            for folder in mangaFolders {
                let mangaId = folder.lastPathComponent.normalized

                // find cbz files in this folder
                let cbzFiles = folder.contents
                    .filter {
                        Self.allowedFileExtensions.contains($0.pathExtension.lowercased())
                    }
                    .sorted {
                        $0.path.localizedStandardCompare($1.path) == .orderedAscending
                    }

                // add manga to db that exist on disk but not in db yet
                if toAdd.contains(mangaId) {
                    // add cbz files as chapters
                    for cbzFile in cbzFiles {
                        do {
                            try await uploadFile(from: cbzFile, skipUpload: true, mangaId: mangaId)
                        } catch {
                            LogManager.logger.error("Failed to process file \(cbzFile.lastPathComponent) for new manga \(mangaId): \(error)")
                        }
                    }
                } else {
                    // add missing chapters
                    let cbzFileNames = Set(cbzFiles.map { $0.lastPathComponent })

                    let dbChapterFileNames = await LocalFileDataManager.shared.removeMissingChapters(
                        mangaId: mangaId,
                        availableChapters: cbzFileNames
                    )

                    // add chapters for new cbz files
                    let chaptersToAdd = cbzFiles.filter { !dbChapterFileNames.contains($0.lastPathComponent) }
                    for cbzFile in chaptersToAdd {
                        do {
                            try await uploadFile(from: cbzFile, skipUpload: true, mangaId: mangaId)
                        } catch {
                            LogManager.logger.error("Failed to process file \(cbzFile.lastPathComponent) for manga \(mangaId): \(error)")
                        }
                    }
                }
            }

            // clear running task (complete)
            scanTask = nil
        }
        await scanTask?.value
    }
}

// MARK: File Listener
extension LocalFileManager {
    // start listening for file system changes in the local folder
    func startFileSystemListener() {
        let localFolder = FileManager.default.documentDirectory
            .appendingPathComponent("Local", isDirectory: true)
        localFolder.createDirectory()

        let fd = open(localFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }
        localFolderFileDescriptor = fd

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .background)
        )
        source.setEventHandler {
            // run a scan when a file is changed
            Task { await LocalFileManager.shared.scanLocalFiles() }
        }
        source.setCancelHandler {
            Task { await LocalFileManager.shared.closeLocalFolderFileDescriptor() }
        }
        localFolderSource = source
        source.resume()
    }

    // stop file system listener
//    func stopFileSystemListener() {
//        localFolderSource?.cancel()
//        localFolderSource = nil
//    }

    private func closeLocalFolderFileDescriptor() {
        if let fd = self.localFolderFileDescriptor {
            close(fd)
            self.localFolderFileDescriptor = nil
        }
    }
}
