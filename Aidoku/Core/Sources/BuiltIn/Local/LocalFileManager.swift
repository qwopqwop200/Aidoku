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

    private let fileOperations = LocalFileOperationGate()
    private let dataManager: LocalFileDataManager
    private let localDirectory: URL

    private var lastScanTime = Date.distantPast
    private var scanTask: Task<Void, Never>?

    static let allowedFileExtensions = Set(["cbz", "zip"])
    static let allowedImageExtensions = Set(["jpg", "jpeg", "png", "webp", "gif", "heic", "avif", "jxl"])
    static let allowedTextExtensions = Set(["txt", "md"])
    static let allowedPageExtensions = allowedImageExtensions.union(allowedTextExtensions)

    private var localFolderSource: DispatchSourceFileSystemObject?

    private var scanDemand = LocalFileScanDemand()

    private func beginFileMutation() { scanDemand.beginMutation() }

    private func endFileMutation() {
        scanDemand.endMutation()
        if scanDemand.canRun && scanTask == nil {
            Task { await self.scanLocalFiles() }
        }
    }

    init(
        dataManager: LocalFileDataManager = .shared, startsListener: Bool = true,
        localDirectory: URL = FileManager.default.documentDirectory.appendingPathComponent("Local", isDirectory: true)
    ) {
        self.dataManager = dataManager
        self.localDirectory = localDirectory
        if startsListener {
            Task { await startFileSystemListener() }
        }
    }

    deinit {
        localFolderSource?.cancel()
        localFolderSource = nil
    }
}

extension LocalFileManager {
    private static func isHiddenPath(_ path: String) -> Bool {
        path.lastPathComponent().hasPrefix(".")
            || path.split(separator: "/").contains(where: { $0 == "__MACOSX" || ($0 != "." && $0.hasPrefix(".")) })
    }

    private static func isImportPage(_ entry: Entry) -> Bool {
        guard entry.type == .file, !isHiddenPath(entry.path) else { return false }
        let ext = entry.path.pathExtension().lowercased()
        return allowedPageExtensions.contains(ext) && !(ext == "txt" && entry.path.hasSuffix("desc.txt"))
    }

    private static func hasImportPage(at url: URL) -> Bool {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        guard let archive = try? Archive(url: url, accessMode: .read, pathEncoding: nil) else { return false }
        return archive.contains(where: isImportPage)
    }

    /// Import an archive received through Open In without requiring the import form.
    func importSharedArchive(from url: URL) async throws -> AidokuRunner.Manga {
        guard url.isFileURL, Self.allowedFileExtensions.contains(url.pathExtension.lowercased()),
              Self.hasImportPage(at: url) else {
            throw LocalFileManagerError.invalidFileType
        }
        guard await SourceManager.shared.ensureLocalSourceForImport() else {
            throw LocalFileManagerError.fileCopyFailed
        }
        try await uploadFile(from: url)
        let mangaId = url.deletingPathExtension().lastPathComponent.normalized
        guard var manga = await dataManager.fetchLocalSeries(id: mangaId) else {
            throw LocalFileManagerError.fileCopyFailed
        }
        manga.chapters = await dataManager.fetchChapters(mangaId: mangaId)
        await MangaManager.shared.addToLibrary(manga: manga, chapters: manga.chapters ?? [])
        return manga
    }

    // get info about a file to be imported
    func loadImportFileInfo(url: URL) async -> ImportFileInfo? {
        // if the given url comes from an imported file that isn't copied, we need to do this
        let accessGranted = url.startAccessingSecurityScopedResource()
        defer {
            if accessGranted { url.stopAccessingSecurityScopedResource() }
        }

        if let source = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(source) > 0 {
            return await prepareImageImport(from: [url], name: url.lastPathComponent)
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
            .filter(Self.isImportPage)
            .sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }

        guard !pageEntries.isEmpty else {
            return nil
        }

        // extract the first three images for preview
        let previewImages = Array(pageEntries.lazy
            .filter { LocalFileManager.allowedImageExtensions.contains($0.path.pathExtension().lowercased()) }
            .prefix(3)
            .compactMap { Self.previewImage(for: $0, in: archive) })

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
            comicInfo: ComicInfo.load(from: archive)
        )
    }

    /// Compressed preview pages above this size are skipped rather than inflated into memory.
    static let maxPreviewEntryBytes = 64 * 1024 * 1024
    /// Page description sidecars are plain text; larger entries are ignored.
    static let maxDescriptionEntryBytes = 1024 * 1024
    /// Imported photos above this pixel count are downsampled before full-size rendering.
    static let maxImportImagePixels = 48 * 1024 * 1024

    private static func previewImage(for entry: Entry, in archive: Archive) -> PlatformImage? {
        do {
            let imageData = try archive.extractData(entry, limit: maxPreviewEntryBytes)
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
}

extension LocalFileManager {
    /// Decodes an image for import, downsampling it when its full-size bitmap would exceed `maxPixels`.
    nonisolated static func loadImportImage(at url: URL, maxPixels: Int = maxImportImagePixels) -> PlatformImage? {
        let options = [kCGImageSourceShouldCache: false] as CFDictionary
        guard let source = CGImageSourceCreateWithURL(url as CFURL, options),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = (properties?[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue ?? 0
        let height = (properties?[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue ?? 0
        guard width * height > Double(maxPixels) else { return PlatformImage(contentsOfFile: url.path) }
        let scale = (Double(maxPixels) / (width * height)).squareRoot()
        let maxSide = max(1, Int((max(width, height) * scale).rounded(.down)))
        // The thumbnail applies EXIF orientation, matching the full-size draw below.
        guard let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: maxSide
        ] as CFDictionary) else { return nil }
        return PlatformImage(cgImage: thumbnail)
    }

    // Keep selection order; process one image at a time to avoid holding every full-resolution photo in memory.
    // Nonisolated async: minutes of decoding must not block the actor (page fetches, scans, uploads).
    nonisolated func prepareImageImport(from urls: [URL], name: String) async -> ImportFileInfo? {
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
                    guard let image = Self.loadImportImage(at: url) else {
                        throw LocalFileManagerError.invalidFileType
                    }
                    // Drawing applies EXIF orientation consistently for reading and OCR.
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = 1
                    // .automatic picks a 16-bit extended-range buffer for P3 photos, doubling memory.
                    format.preferredRange = .standard
                    let normalized = UIGraphicsImageRenderer(size: image.size, format: format).image { _ in
                        image.draw(in: CGRect(origin: .zero, size: image.size))
                    }
                    let pageName = String(format: "%08d.png", index + 1)
                    let pageURL = directory.appendingPathComponent(pageName)
                    // Encode straight to the file instead of holding a second, encoded copy in memory.
                    guard let bitmap = normalized.cgImage,
                          let png = CGImageDestinationCreateWithURL(pageURL as CFURL, "public.png" as CFString, 1, nil)
                    else { throw LocalFileManagerError.invalidFileType }
                    CGImageDestinationAddImage(png, bitmap, nil)
                    guard CGImageDestinationFinalize(png) else { throw LocalFileManagerError.invalidFileType }
                    try archive.addEntry(with: pageName, fileURL: pageURL)
                    try FileManager.default.removeItem(at: pageURL)
                    if previews.count < 3 {
                        let scale = min(1, 400 / max(image.size.width, image.size.height, 1))
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
        guard let cbzPath = await dataManager.fetchChapterArchivePath(mangaId: mangaId, chapterId: chapterId)
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

        var descriptionFiles: [(entry: Entry, index: Int)] = []
        // ZIPFoundation decodes Entry.path on each access, so sort decoded paths instead of entries.
        var paths = archive.compactMap { entry -> String? in
            guard entry.type == .file else { return nil }
            let path = entry.path
            guard !Self.isHiddenPath(path) else { return nil }
            let ext = path.pathExtension().lowercased()
            if ext == "txt", path.hasSuffix("desc.txt") {
                if let number = path.lastPathComponent().split(separator: ".", maxSplits: 1).first.flatMap({ Int($0) }), number > 0 {
                    descriptionFiles.append((entry, number - 1))
                }
                return nil
            }
            return Self.allowedPageExtensions.contains(ext) ? path : nil
        }
        paths.sort { $0.localizedStandardCompare($1) == .orderedAscending }
        var pages = paths.map {
            AidokuRunner.Page(content: .zipFile(url: archiveURL, filePath: $0))
        }

        for (entry, index) in descriptionFiles where index < pages.count {
            do {
                let descriptionData = try archive.extractData(entry, limit: Self.maxDescriptionEntryBytes)
                pages[index].hasDescription = true
                pages[index].description = String(data: descriptionData, encoding: .utf8)
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
                $0.type == .file && !isHiddenPath($0.path) &&
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
        chapter: Float? = nil,
        scanOwned: Bool = false
    ) async throws(LocalFileManagerError) {
        if !scanOwned {
            do { try await fileOperations.acquire() } catch { throw .fileCopyFailed }
        }
        defer { if !scanOwned { fileOperations.release() } }
        // disable file listener while we make changes to the disk
        beginFileMutation()
        defer { endFileMutation() }

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

        guard archive.contains(where: Self.isImportPage) else {
            throw LocalFileManagerError.noImagesFound
        }

        let comicInfo = ComicInfo.load(from: archive)

        let resolvedMangaId = (mangaId ?? mangaName ?? url.deletingPathExtension().lastPathComponent).normalized
        let mangaTitle = mangaName ?? comicInfo?.series ?? resolvedMangaId

        // create new folder for the manga
        let fileManager = FileManager.default
        let localFolder = localDirectory
        localFolder.createDirectory()
        let mangaFolder = localFolder.appendingPathComponent(resolvedMangaId, isDirectory: true)
        guard Self.isContainedLocalURL(mangaFolder, root: localDirectory) else { throw LocalFileManagerError.fileCopyFailed }
        mangaFolder.createDirectory()

        // get chapter number
        let chapter = if volume == nil && chapter == nil {
            if let comicInfo, let number = comicInfo.number, let chapter = Float(number) {
                chapter
            } else if let chapter = LocalFileNameParser.getMangaChapterNumber(from: url.lastPathComponent) {
                chapter
            } else if let mangaId {
                await dataManager.getNextChapterNumber(series: mangaId)
            } else {
                Float(1)
            }
        } else {
            chapter
        }
        let volume = volume ?? comicInfo?.volume.map { Float($0) }
            ?? LocalFileNameParser.getMangaVolumeNumber(from: url.lastPathComponent)

        let destURL: URL

        if skipUpload {
            guard Self.isContainedLocalURL(url, root: localDirectory) else { throw LocalFileManagerError.fileCopyFailed }
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
            guard Self.isContainedLocalURL(newDestURL, root: localDirectory) else { throw LocalFileManagerError.fileCopyFailed }
            destURL = newDestURL
            do {
                try fileManager.copyItem(at: url, to: destURL)
            } catch {
                throw LocalFileManagerError.fileCopyFailed
            }
        }

        var imported = false
        defer {
            // Never delete a pre-existing file discovered by the scanner.
            if !imported && !skipUpload { try? FileManager.default.removeItem(at: destURL) }
        }
        let coverURL: URL?
        if let mangaCoverImage {
            // save provided cover image to manga folder
            let coverFileName = "cover.png"
            let newCoverURL = mangaFolder.appendingPathComponent(coverFileName)
            guard Self.isContainedLocalURL(newCoverURL, root: localDirectory) else { throw LocalFileManagerError.fileCopyFailed }
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

        // Commit series and chapter together so a failed commit is never reported as imported.
        let cover = coverURL?.toAidokuImageUrl()?.absoluteString
        let title: String?
        if let chapterName {
            title = chapterName.isEmpty ? nil : chapterName
        } else {
            title = url.deletingPathExtension().lastPathComponent
        }
        do {
            try await dataManager.commitImport(
                folder: mangaFolder, mangaId: resolvedMangaId, mangaTitle: mangaTitle, cover: cover,
                description: mangaDescription, archive: destURL, chapterId: UUID().uuidString,
                chapterTitle: title, volume: volume, chapter: chapter, comicInfo: comicInfo
            )
            imported = true
        } catch {
            throw LocalFileManagerError.databaseWriteFailed
        }
    }
}

extension LocalFileManager {
    func setCover(for mangaKey: String, image: PlatformImage) async -> String? {
        guard (try? await fileOperations.acquire()) != nil else { return nil }
        defer { fileOperations.release() }
        beginFileMutation()
        defer { endFileMutation() }
        let mangaData = await dataManager.fetchLocalSeries(id: mangaKey)

        let previousCover = mangaData?.cover.flatMap(URL.init(string:)).map { $0.toAidokuFileUrl() ?? $0 }

        // upload the new cover
        let fileManager = FileManager.default
        let localFolder = localDirectory
        let mangaFolder = localFolder.appendingPathComponent(mangaKey, isDirectory: true)
        let coverFileName = "cover.png"
        let newCoverURL = mangaFolder.appendingPathComponent(coverFileName)
        guard Self.isContainedLocalURL(newCoverURL, root: localDirectory) else { return nil }
        do {
            guard let data = image.pngData() else { return nil }
            try data.write(to: newCoverURL, options: .atomic)
        } catch {
            LogManager.logger.error("Failed to write cover image for manga \(mangaKey): \(error)")
            return nil
        }

        if let previousCover, previousCover.isFileURL, previousCover != newCoverURL, Self.isContainedLocalURL(previousCover, root: localDirectory) {
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
    func removeManga(with mangaId: String, scanOwned: Bool = false) async {
        if !scanOwned { guard (try? await fileOperations.acquire()) != nil else { return } }
        defer { if !scanOwned { fileOperations.release() } }
        beginFileMutation()
        defer { endFileMutation() }
        // remove from db
        let filePath = await dataManager.removeManga(with: mangaId)
        guard let filePath else { return }

        let documentsDir = FileManager.default.documentDirectory
        let fileURL = documentsDir.appendingPathComponent(filePath)
        if Self.isContainedLocalURL(fileURL, root: localDirectory), fileURL.exists {
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    // remove a chapter from a given local manga
    func removeChapter(mangaId: String, chapterId: String) async {
        guard (try? await fileOperations.acquire()) != nil else { return }
        defer { fileOperations.release() }
        beginFileMutation()
        defer { endFileMutation() }
        // remove from db
        let filePath = await dataManager.removeChapter(mangaId: mangaId, chapterId: chapterId)

        if let filePath {
            let documentsDir = FileManager.default.documentDirectory
            let fileURL = documentsDir.append(path: filePath)
            if Self.isContainedLocalURL(fileURL, root: localDirectory), fileURL.exists {
                try? FileManager.default.removeItem(at: fileURL)
            }
        }

        // remove the manga entry once no chapters remain
        if await dataManager.fetchChapters(mangaId: mangaId).isEmpty {
            await removeManga(with: mangaId, scanOwned: true)
        }
    }

    // remove all local source files and db objects
    func removeAllLocalFiles() async {
        guard (try? await fileOperations.acquire()) != nil else { return }
        // disable file listener while we make changes to the disk
        beginFileMutation()

        let fileManager = FileManager.default
        let documentsDir = fileManager.documentDirectory
        let localFolder = localDirectory
        do {
            try fileManager.removeItem(at: localFolder)
        } catch {
            LogManager.logger.error("Failed to remove Local folder: \(error)")
        }

        // update database
        endFileMutation()
        fileOperations.release()
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
        // Record demand even when a mutation or running scan defers the work.
        scanDemand.request()
        guard scanDemand.canRun else { return }

        // ensure only one scan is running at a time
        guard scanTask == nil else {
            await scanTask?.value
            return
        }

        scanTask = Task {
            while scanDemand.takePass() {
                do { try await fileOperations.acquire() } catch { scanDemand.request(); break }
                do { try await scanLocalFilesPass() }
                catch {
                    // Keep demand, but retry only on a later event rather than spinning on persistent failures.
                    scanDemand.request()
                    fileOperations.release()
                    break
                }
                fileOperations.release()
            }
            scanTask = nil
        }
        await scanTask?.value
    }

    private func scanLocalFilesPass() async throws {
        let fileManager = FileManager.default
        let localFolder = localDirectory
        try fileManager.createDirectory(at: localFolder, withIntermediateDirectories: true)

        // get all manga folders
        let localContents = try fileManager.contentsOfDirectory(
            at: localFolder, includingPropertiesForKeys: [.isDirectoryKey], options: .skipsHiddenFiles
        )
        let mangaFolders = try localContents.filter { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true }
        try Task.checkCancellation()

        // Read every directory before reconciling, so a failed read never looks like an empty folder.
        let folderChapters = try mangaFolders.map { folder in
            try Task.checkCancellation()
            let chapters = try fileManager.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: nil, options: .skipsHiddenFiles
            ).filter {
                Self.allowedFileExtensions.contains($0.pathExtension.lowercased())
            }.sorted {
                $0.path.localizedStandardCompare($1.path) == .orderedAscending
            }
            return (folder, chapters)
        }
        try Task.checkCancellation()

        let (toRemove, toAdd) = try await dataManager.findMangaDiskChanges(mangaFolders: mangaFolders)

        // remove manga from db that no longer exist on disk
        for mangaId in toRemove {
            await removeManga(with: mangaId, scanOwned: true)
        }

        // for each manga folder, ensure chapters in db match local files
        for (folder, cbzFiles) in folderChapters {
            try Task.checkCancellation()
            let mangaId = folder.lastPathComponent.normalized
            let isNew = toAdd.contains(mangaId)

            // new manga get every cbz file as a chapter; existing manga only get missing ones
            var chaptersToAdd = cbzFiles
            if !isNew {
                let dbChapterFileNames = try await dataManager.removeMissingChapters(
                    mangaId: mangaId,
                    availableChapters: Set(cbzFiles.map { $0.lastPathComponent })
                )
                chaptersToAdd = cbzFiles.filter { !dbChapterFileNames.contains($0.lastPathComponent) }
            }
            for cbzFile in chaptersToAdd {
                do {
                    try await uploadFile(from: cbzFile, skipUpload: true, mangaId: mangaId, scanOwned: true)
                } catch {
                    let kind = isNew ? "new manga" : "manga"
                    LogManager.logger.error("Failed to process file \(cbzFile.lastPathComponent) for \(kind) \(mangaId): \(error)")
                    if case LocalFileManagerError.databaseWriteFailed = error { throw error }
                }
            }
        }
    }
}

// MARK: File Listener
extension LocalFileManager {
    // start listening for file system changes in the local folder
    func startFileSystemListener() {
        guard localFolderSource == nil else { return }
        let localFolder = localDirectory
        localFolder.createDirectory()

        let fd = open(localFolder.path, O_EVTONLY)
        guard fd >= 0 else { return }

        let source = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fd,
            eventMask: [.write, .delete, .rename],
            queue: DispatchQueue.global(qos: .background)
        )
        source.setEventHandler { [weak self, weak source] in
            // A deleted or renamed Local folder leaves this descriptor watching a dead vnode, so watch the new one.
            let moved = source.map { !$0.data.isDisjoint(with: [.delete, .rename]) } ?? false
            // run a scan when a file is changed
            Task { await self?.scanLocalFiles(); if moved { await self?.restartFileSystemListener() } }
        }
        source.setCancelHandler { close(fd) }
        localFolderSource = source
        source.resume()
    }

    private func restartFileSystemListener() {
        localFolderSource?.cancel()
        localFolderSource = nil
        startFileSystemListener()
    }

    // stop file system listener
//    func stopFileSystemListener() {
//        localFolderSource?.cancel()
//        localFolderSource = nil
//    }

}

// All writes and deletions must stay strictly below Local, after resolving symlinks and dot components.
extension LocalFileManager {
    nonisolated static func isContainedLocalURL(_ url: URL, root: URL = FileManager.default.documentDirectory.appendingPathComponent("Local", isDirectory: true)) -> Bool {
        guard url.isFileURL, root.isFileURL else { return false }
        let expectedRoot = root.deletingLastPathComponent().standardizedFileURL
            .resolvingSymlinksInPath().appendingPathComponent(root.lastPathComponent).standardizedFileURL
        let resolvedRoot = root.standardizedFileURL.resolvingSymlinksInPath()
        guard resolvedRoot.path == expectedRoot.path else { return false }
        let base = resolvedRoot.path
        // Foundation does not resolve symlinks above a nonexistent leaf: resolve the nearest
        // existing ancestor, then append the missing suffix.
        var ancestor = url.standardizedFileURL
        var missingComponents: [String] = []
        let fileManager = FileManager.default
        while !fileManager.fileExists(atPath: ancestor.path) {
            // Refuse dangling links rather than validating their unresolved spelling.
            if (try? fileManager.destinationOfSymbolicLink(atPath: ancestor.path)) != nil { return false }
            let parent = ancestor.deletingLastPathComponent()
            guard parent.path != ancestor.path else { return false }
            missingComponents.append(ancestor.lastPathComponent)
            ancestor = parent
        }
        var candidate = ancestor.resolvingSymlinksInPath()
        for component in missingComponents.reversed() {
            candidate.appendPathComponent(component)
        }
        return candidate.standardizedFileURL.path.hasPrefix(base + "/")
    }
}

/// Actor-owned scan demand: mutations nest, and an event after a pass starts causes one trailing pass.
struct LocalFileScanDemand {
    private(set) var mutations = 0
    private(set) var dirty = false
    var canRun: Bool { mutations == 0 && dirty }

    mutating func request() { dirty = true }
    mutating func beginMutation() { mutations += 1 }
    mutating func endMutation() {
        precondition(mutations > 0)
        mutations -= 1
    }
    mutating func takePass() -> Bool {
        guard canRun else { return false }
        dirty = false
        return true
    }
}

/// FIFO ownership across actor suspension; cancellation removes queued waiters.
final class LocalFileOperationGate: @unchecked Sendable {
    private let lock = NSLock()
    private var active = false
    private var waiting: [(UUID, CheckedContinuation<Void, Error>)] = []

    func acquire() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                lock.lock()
                if Task.isCancelled {
                    lock.unlock()
                    continuation.resume(throwing: CancellationError())
                } else if !active {
                    active = true
                    lock.unlock()
                    continuation.resume()
                } else {
                    waiting.append((id, continuation))
                    lock.unlock()
                }
            }
        } onCancel: {
            self.lock.lock()
            let index = self.waiting.firstIndex { $0.0 == id }
            let continuation = index.map { self.waiting.remove(at: $0).1 }
            self.lock.unlock()
            continuation?.resume(throwing: CancellationError())
        }
        do { try Task.checkCancellation() }
        catch { release(); throw error }
    }

    func release() {
        lock.lock()
        if waiting.isEmpty {
            active = false
            lock.unlock()
        } else {
            let next = waiting.removeFirst().1
            lock.unlock()
            next.resume()
        }
    }
}
