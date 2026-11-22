//
//  DownloadTask.swift
//  Aidoku
//
//  Created by Skitty on 5/14/22.
//

import AidokuRunner
import Foundation
import Nuke
import UniformTypeIdentifiers
import ZIPFoundation

protocol DownloadTaskDelegate: AnyObject, Sendable {
    func taskCancelled(task: DownloadTask) async
    func taskPaused(task: DownloadTask) async
    func taskFinished(task: DownloadTask) async
    func downloadProgressChanged(download: Download) async
    func downloadFinished(download: Download) async
    func downloadFailed(download: Download) async
    func downloadCancelled(download: Download) async
}

// performs the actual download operations
actor DownloadTask: Identifiable {
    let id: String

    private let cache: DownloadCache
    private let bulkAdmission = BulkDownloadAdmission.shared
    private var downloads: [Download]
    private weak var delegate: DownloadTaskDelegate?

    private var worker: Task<Void, Never>?
    // A drained or cancelled worker is never revived; new entries go to a successor.
    private var retired = false
    private var controlGeneration = 0
    private var enqueueGeneration: UInt64 = 0
    private var warmedPages: (chapter: ChapterIdentifier, task: Task<[Page], Never>)?

    private var currentPage: Int = 0
    private var failedPages: Int = 0
    private var descriptionWriteFailed = false
    private var failedPageNumbers: [Int] = []
    private var pages: [Page] = []

    private(set) var running: Bool = false

    private static let maxConcurrentPageTasks = 5

    private static let maxPageRetries = 3
    private static let retryBaseDelay: TimeInterval = 1
    private static let maxRetryDelay: TimeInterval = 60

    enum DownloadError: Error {
        case pageProcessorFailed
    }

    init(id: String, cache: DownloadCache, downloads: [Download], delegate: DownloadTaskDelegate?) {
        self.id = id
        self.cache = cache
        self.downloads = downloads
        self.delegate = delegate
    }

    func resume() {
        guard !running, !retired else { return }
        controlGeneration += 1
        running = true
        let previousWorker = worker
        worker = Task(priority: .utility) {
            // Let a cancelled worker unwind before touching the same files and counters.
            await previousWorker?.value
            guard !Task.isCancelled, running else { return }
            await next()
        }
    }

    func pause() async {
        controlGeneration += 1
        worker?.cancel()
        warmedPages?.task.cancel(); warmedPages = nil
        running = false
        for (i, download) in downloads.enumerated() where download.status == .queued || download.status == .downloading {
            downloads[i].status = .paused
        }
        Task {
            await delegate?.taskPaused(task: self)
        }
    }

    func cancel(manga: MangaIdentifier? = nil, chapter: ChapterIdentifier? = nil) async {
        let cancelAll = manga == nil && chapter == nil
        let cancelled: [Download]
        let cancelledCurrent: Bool
        if cancelAll {
            cancelled = downloads
            cancelledCurrent = !downloads.isEmpty
            downloads = []
        } else {
            func matches(_ download: Download) -> Bool {
                if let chapter { return download.chapterIdentifier == chapter }
                return download.mangaIdentifier == manga
            }
            cancelled = downloads.filter(matches)
            guard let first = cancelled.first else { return }
            cancelledCurrent = downloads.first == first
            downloads.removeAll(where: matches)
        }
        if !cancelledCurrent, !cancelAll {
            // Removing future entries leaves the active worker running.
            if let warmedPages, cancelled.contains(where: { $0.chapterIdentifier == warmedPages.chapter }) {
                warmedPages.task.cancel()
                self.warmedPages = nil
            }
            for download in cancelled where cache.isSafe(chapter: download.chapterIdentifier) {
                cache.tmpDirectory(for: download.chapterIdentifier).removeItem()
            }
            // Clean up before yielding: a delegate callback may re-enqueue the chapter.
            let generation = enqueueGeneration
            for download in cancelled {
                if enqueueGeneration != generation, downloads.contains(download) { continue }
                await delegate?.downloadCancelled(download: download)
            }
            return
        }
        let wasRunning = running
        controlGeneration += 1
        let generation = controlGeneration
        let previousWorker = worker
        previousWorker?.cancel()
        warmedPages?.task.cancel()
        warmedPages = nil
        running = false
        let cancellation = Task {
            await previousWorker?.value
            for download in cancelled where cache.isSafe(chapter: download.chapterIdentifier) {
                cache.tmpDirectory(for: download.chapterIdentifier).removeItem()
            }
            if cancelledCurrent {
                pages = []
                currentPage = 0
                failedPages = 0
                descriptionWriteFailed = false
                failedPageNumbers = []
            }
            if cancelAll {
                retired = true
                await delegate?.taskCancelled(task: self)
            } else {
                for download in cancelled { await delegate?.downloadCancelled(download: download) }
                if wasRunning, generation == controlGeneration { resume() }
            }
        }
        // A concurrent resume must wait for cleanup, not just the old transport task.
        worker = cancellation
        await cancellation.value
    }

    func add(download: Download) {
        guard !retired, !downloads.contains(where: { $0 == download }) else { return }
        downloads.append(download)
        enqueueGeneration &+= 1
    }
}

extension DownloadTask {
    // Iterate rather than recurse, so finished chapters' pages are released.
    private func next() async {
        while await advance() {}
    }

    /// Processes the head of the queue; returns false when this worker stops.
    private func advance() async -> Bool {
        guard running, !Task.isCancelled else { return false }

        // Reject malformed identifiers before anything touches their derived paths.
        while let download = downloads.first, !cache.isSafe(chapter: download.chapterIdentifier) {
            downloads.removeFirst()
            await delegate?.downloadFailed(download: download)
            guard running, !Task.isCancelled else { return false }
        }

        // done with all downloads
        if downloads.isEmpty {
            running = false
            retired = true
            await delegate?.taskFinished(task: self)
            return false
        }

        // attempt to download first chapter in the queue
        if
            let download = downloads.first,
            let source = await SourceManager.shared.source(for: download.chapterIdentifier.sourceKey)
        {
            guard running, !Task.isCancelled else { return false }
            // if chapter already downloaded, skip
            let directory = cache.directory(for: download.chapterIdentifier)
            guard !directory.exists && !directory.appendingPathExtension("cbz").exists else {
                downloads.removeFirst()
                await delegate?.downloadFinished(download: download)
                return true
            }

            // download has been cancelled or failed, skip
            if download.status != .queued && download.status != .downloading && download.status != .paused {
                downloads.removeFirst()
                await delegate?.downloadCancelled(download: download)
                return true
            }

            return await self.download(from: source)
        } else {
            guard running, !Task.isCancelled else { return false }
            // source not found, skip this download
            let failed = downloads.removeFirst()
            markFailed(tmpDirectory: cache.tmpDirectory(for: failed.chapterIdentifier))
            await delegate?.downloadFailed(download: failed)
            return true
        }
    }

    struct NetworkPage {
        let url: URL
        let context: PageContext?
        let targetPath: URL
        /// The page's position in the chapter, one-based, which is the number it is stored under.
        let pageNumber: Int
    }

    /// A finished page download, carrying the page it belongs to.
    ///
    /// A concurrent download hands results back in whatever order they finish, so a failure has to
    /// name its page rather than be inferred from how many have completed.
    struct PageDownloadResult {
        let pageNumber: Int
        let file: (staging: URL, destination: URL)?
    }

    // perform download; returns true once the queue may advance
    private func download(from source: AidokuRunner.Source) async -> Bool {
        guard running && !downloads.isEmpty else { return false }

        let download = downloads[0]
        let translationSettings = download.translatesImages == true ? await MainActor.run {
            var settings = ReaderTranslationSettings()
            settings.readingDirection = switch download.manga.viewer {
            case .leftToRight: .leftToRight
            case .vertical, .webtoon: .topToBottom
            case .rightToLeft, .unknown: .rightToLeft
            }
            return settings
        } : nil
        guard !Task.isCancelled, running, downloads.first == download else { return false }
        currentPage = 0
        failedPages = 0
        descriptionWriteFailed = false
        failedPageNumbers = []
        downloads[0].status = .downloading

        let tmpDirectory = cache.tmpDirectory(for: download.chapterIdentifier)
        tmpDirectory.removeItem() // remove in case it exists from a previous failed download
        tmpDirectory.createDirectory()

        if pages.isEmpty {
            let loadedPages: [Page]
            if let warmedPages, warmedPages.chapter == download.chapterIdentifier {
                loadedPages = await warmedPages.task.value
                self.warmedPages = nil
            } else {
                loadedPages = await Self.loadPages(download, source: source)
            }
            guard !Task.isCancelled, running, downloads.first == download else { return false }
            pages = loadedPages
            downloads[0].total = pages.count
        }

        var networkPages: [NetworkPage] = []
        var descriptions: [(page: Page, target: URL, pageNumber: Int)] = []

        for (i, page) in pages.enumerated() {
            guard !Task.isCancelled, running, downloads.first == download else { return false }
            let pageNumber = String(format: "%03d", i + 1)
            let targetPath = tmpDirectory.appendingPathComponent(pageNumber)

            if let urlString = page.imageURL, let url = URL(string: urlString) {
                // add pages that require network requests to a concurrent queue
                networkPages.append(.init(
                    url: url,
                    context: page.context,
                    targetPath: targetPath,
                    pageNumber: i + 1
                ))
            } else {
                currentPage += 1
                do {
                    if let base64 = page.base64, let data = Data(base64Encoded: base64) {
                        try await writeImage(data, to: targetPath, settings: translationSettings)
                    } else if let text = page.text, let data = text.data(using: .utf8) {
                        guard translationSettings == nil else { throw DownloadError.pageProcessorFailed }
                        try data.write(to: targetPath.appendingPathExtension("txt"))
                    } else if let image = page.image {
                        guard let data = image.pngData() else { throw DownloadError.pageProcessorFailed }
                        try await writeImage(data, to: targetPath, settings: translationSettings)
                    } else {
                        throw DownloadError.pageProcessorFailed
                    }
                } catch {
                    guard !Task.isCancelled, running, downloads.first == download else { return false }
                    failedPages += 1
                    failedPageNumbers.append(i + 1)
                    LogManager.logger.error("Error writing page data: \(error)")
                }
                if let index = downloads.firstIndex(where: { $0 == download }) {
                    downloads[index].progress = currentPage
                    await delegate?.downloadProgressChanged(download: downloads[index])
                }
            }

            if page.hasDescription { descriptions.append((page, targetPath, i + 1)) }
        }

        // A sliding window of page requests that hold files, not decoded images.
        await withTaskGroup(of: PageDownloadResult.self) { group in
            let ceiling = translationSettings == nil ? Self.maxConcurrentPageTasks : 2
            let limit = AppSettings.downloads.parallel.get()
                ? max(1, min(source.config?.maximumParallelRequests ?? ceiling, ceiling)) : 1
            var next = networkPages.makeIterator()
            for _ in 0..<limit {
                if let page = next.next() {
                    group.addTask { await self.downloadPage(page, source: source, tmpDirectory: tmpDirectory, translationSettings: translationSettings) }
                }
            }
            while let result = await group.next() {
                guard !Task.isCancelled, running, downloads.first == download, tmpDirectory.exists else {
                    group.cancelAll()
                    result.file?.staging.removeItem()
                    // Join and clean files created by requests that raced cancellation.
                    for await abandoned in group { abandoned.file?.staging.removeItem() }
                    return
                }
                var failed = false
                do {
                    guard let file = result.file else { throw DownloadError.pageProcessorFailed }
                    defer { file.staging.removeItem() }
                    try FileManager.default.moveItem(at: file.staging, to: file.destination)
                } catch {
                    failed = true
                    LogManager.logger.error("Error saving downloaded page: \(error)")
                }
                guard !Task.isCancelled, running, downloads.first == download else {
                    group.cancelAll()
                    for await abandoned in group { abandoned.file?.staging.removeItem() }
                    return
                }
                // Refill before publishing progress to keep transport slots busy.
                if let page = next.next() {
                    group.addTask { await self.downloadPage(page, source: source, tmpDirectory: tmpDirectory, translationSettings: translationSettings) }
                }
                await incrementProgress(for: download.chapterIdentifier, failedPage: failed ? result.pageNumber : nil)
            }
        }

        // Descriptions are fetched after images but before chapter promotion.
        for (page, target, pageNumber) in descriptions {
            guard !Task.isCancelled, running, downloads.first == download else { return false }
            var description = page.description
            if description == nil { description = try? await source.getPageDescription(page: page.toNew()) }
            guard !Task.isCancelled, running, downloads.first == download else { return false }
            if let data = description?.data(using: .utf8) {
                do {
                    try data.write(to: target.appendingPathExtension("desc.txt"))
                } catch {
                    descriptionWriteFailed = true
                    // A lost description counts as a failed page (once per page).
                    if !failedPageNumbers.contains(pageNumber) {
                        failedPageNumbers.append(pageNumber)
                        failedPages += 1
                    }
                    LogManager.logger.error("Error writing page description: \(error)")
                }
            }
        }
        if !Task.isCancelled, running, downloads.first == download, currentPage == pages.count {
            return await handleChapterDownloadFinish(download: download)
        }
        return false
    }

    // Every result is a file, so queued output never holds decoded images.
    private func downloadPage(_ page: NetworkPage, source: AidokuRunner.Source, tmpDirectory: URL,
                              translationSettings: ReaderTranslationSettings?) async -> PageDownloadResult {
        let request = await source.getModifiedImageRequest(url: page.url, context: page.context)
        let fetched = await fetchPageData(for: request, tmpDirectory: tmpDirectory)
        guard fetched != nil || source.features.processesPages else { return .init(pageNumber: page.pageNumber, file: nil) }
        defer { fetched?.0.removeItem() }
        let staged = tmpDirectory.appendingPathComponent(".incoming-\(page.pageNumber)-\(UUID().uuidString)")
        do {
            try Task.checkCancellation()
            guard tmpDirectory.exists else { throw CancellationError() }
            var fileExtension: String
            if source.features.processesPages {
                let data = try fetched.map { try Data(contentsOf: $0.0, options: .mappedIfSafe) }
                let response = fetched?.1 ?? HTTPURLResponse(url: page.url, statusCode: 404, httpVersion: nil, headerFields: nil)
                try await TranslationImageWorkBudget.shared.withPermit(priority: .prefetch,
                    decodedBytes: data.map(TranslationImageWorkBudget.decodedBytes) ?? 0) {
                    let image = data.flatMap { PlatformImage(data: $0) } ?? .mangaPlaceholder
                    let container = ImageContainer(image: image, data: data)
                    let imageRequest = ImageRequest(urlRequest: request, userInfo: [.processesKey: true])
                    let processor = PageInterceptorProcessor(source: source, pageContext: page.context)
                    guard let result = try await processor.processAsync(container, context: .init(request: imageRequest,
                        response: .init(container: container, request: imageRequest, urlResponse: response), isCompleted: true)) else {
                        throw DownloadError.pageProcessorFailed
                    }
                    try Task.checkCancellation()
                    try autoreleasepool {
                        guard let encoded = result.pngData() else { throw DownloadError.pageProcessorFailed }
                        try encoded.write(to: staged, options: .atomic)
                    }
                }
                fileExtension = "png"
            } else {
                guard let (file, response) = fetched else { throw DownloadError.pageProcessorFailed }
                try FileManager.default.moveItem(at: file, to: staged)
                fileExtension = guessFileExtension(response: response, defaultValue: "png")
            }
            if let translationSettings {
                let output = try await DownloadImageTranslator.translate(fileURL: staged, settings: translationSettings)
                try Task.checkCancellation()
                try output.write(to: staged, options: .atomic)
                if output.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { fileExtension = "png" }
            }
            try Task.checkCancellation()
            return .init(pageNumber: page.pageNumber, file: (staged, page.targetPath.appendingPathExtension(fileExtension)))
        } catch {
            staged.removeItem()
            if !(error is CancellationError) { LogManager.logger.error("Error processing downloaded page: \(error)") }
            return .init(pageNumber: page.pageNumber, file: nil)
        }
    }

    private func writeImage(_ data: Data, to targetPath: URL, settings: ReaderTranslationSettings?) async throws {
        let output = if let settings { try await DownloadImageTranslator.translate(data, settings: settings) } else { data }
        try Task.checkCancellation()
        try output.write(to: targetPath.appendingPathExtension(DownloadImageTranslator.fileExtension(for: output)), options: .atomic)
    }

    // fetch page data, retrying on any non-2xx HTTP response or network error
    private func fetchPageData(for urlRequest: URLRequest, tmpDirectory: URL) async -> (URL, URLResponse)? {
        var attempt = 0
        while !Task.isCancelled {
            // The shared transport slot is held only for the request itself.
            let result = try? await bulkAdmission.withPermit { try await SourceNetwork.shared.download(for: urlRequest) }

            // response was okay, bail out
            if let result, self.isSuccessResponse(result.1), !Task.isCancelled {
                return result
            }
            if let result { result.0.removeItem() }
            guard !Task.isCancelled else { return nil }

            let statusCode = (result?.1 as? HTTPURLResponse)?.statusCode

            let reason = switch statusCode {
                case 429: "rate limited (HTTP 429)"
                case let statusCode?: "HTTP \(statusCode)"
                case nil: "network error"
            }

            let isRetryable = statusCode.map(self.isRetryableStatus) ?? true

            guard isRetryable, attempt < Self.maxPageRetries else {
                LogManager.logger.error("Failed to download image (\(reason)): \(urlRequest)")
                return nil
            }

            // honor the server's Retry-After when present, otherwise use exponential backoff
            let (delay, waitSource): (TimeInterval, String) = if let retryAfter = self.retryDelay(from: result?.1) {
                (retryAfter, "Retry-After")
            } else {
                (Self.backoffDelay(forAttempt: attempt), "backoff")
            }
            LogManager.logger.warn("Image download \(reason), retrying in \(Int(delay))s via \(waitSource): \(urlRequest)")

            // stop retrying if the download was cancelled
            guard tmpDirectory.exists else { return nil }
            do {
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            } catch {
                return nil // task cancelled during backoff
            }
            guard tmpDirectory.exists else { return nil }

            attempt += 1
        }
        return nil
    }

    private func incrementProgress(for id: ChapterIdentifier, failedPage: Int? = nil) async {
        guard let downloadIndex = downloads.firstIndex(where: { $0.chapterIdentifier == id }) else {
            return
        }
        currentPage += 1
        downloads[downloadIndex].progress = currentPage
        let download = downloads[downloadIndex]
        Task {
            await delegate?.downloadProgressChanged(download: download)
        }
        if let failedPage {
            failedPages += 1
            failedPageNumbers.append(failedPage)
        }
    }

    private static func loadPages(_ download: Download, source: AidokuRunner.Source) async -> [Page] {
        guard !Task.isCancelled else { return [] }
        let pages = (try? await source.getPageList(manga: download.manga, chapter: download.chapter)) ?? []
        guard !Task.isCancelled else { return [] }
        return pages.map { $0.toOld(sourceId: source.key, chapterId: download.chapterIdentifier.chapterKey,
                                   language: download.chapter.language ?? source.languages.first) }
    }

    // Recheck queue state after the source lookup's actor hop.
    private func warmNextChapter(after download: Download) async {
        guard downloads.count > 1, warmedPages == nil else { return }
        let generation = controlGeneration
        guard let source = await SourceManager.shared.source(for: download.chapterIdentifier.sourceKey),
              !Task.isCancelled, generation == controlGeneration,
              downloads.first == download, downloads.count > 1, warmedPages == nil,
              (source.config?.maximumParallelRequests ?? Self.maxConcurrentPageTasks) > 1 else { return }
        let next = downloads[1]
        warmedPages = (next.chapterIdentifier, Task { await Self.loadPages(next, source: source) })
    }

    private func handleChapterDownloadFinish(download: Download) async -> Bool {
        let tmpDirectory = cache.tmpDirectory(for: download.chapterIdentifier)
        // Prefetch only the next chapter's page list during finalization.
        await warmNextChapter(after: download)
        guard !Task.isCancelled, running, downloads.first == download else { return false }

        if pages.isEmpty || (failedPages == pages.count && download.translatesImages != true && !descriptionWriteFailed) {
            // the entire chapter failed to download, skip adding to cache and cancel
            tmpDirectory.removeItem()
            if let downloadIndex = downloads.firstIndex(where: { $0 == download }) {
                downloads[downloadIndex].status = .cancelled
                downloads.remove(at: downloadIndex)
                await delegate?.downloadCancelled(download: download)
            }
            LogManager.logger.error("Chapter failed to download: \(download.chapter.formattedTitle())")
        } else if failedPages > 0 {
            LogManager.logger.error(
                "Chapter downloaded with \(failedPages) failed page\(failedPages == 1 ? "" : "s"): \(download.chapter.formattedTitle())"
            )

            // save metadata for failed download in downloads view
            try? await DownloadManager.shared.saveChapterMetadata(manga: download.manga, chapter: download.chapter, to: tmpDirectory)
            guard !Task.isCancelled, running, downloads.first == download else { return false }
            markFailed(tmpDirectory: tmpDirectory)

            if let downloadIndex = downloads.firstIndex(where: { $0 == download }) {
                downloads[downloadIndex].status = .failed
                let failed = downloads.remove(at: downloadIndex)
                await delegate?.downloadFailed(download: failed)
            }
        } else {
            do {
                // Save chapter metadata after successful download
                try await DownloadManager.shared.saveChapterMetadata(manga: download.manga, chapter: download.chapter, to: tmpDirectory)

                let directory = cache.directory(for: download.chapterIdentifier)

                if AppSettings.downloads.compress.get() {
                    let archive = tmpDirectory.appendingPathExtension("cbz")
                    defer { archive.removeItem() }
                    try await Self.writeChapterArchive(from: tmpDirectory, to: archive)
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: archive, to: directory.appendingPathExtension("cbz"))
                    tmpDirectory.removeItem()
                } else {
                    try Task.checkCancellation()
                    try FileManager.default.moveItem(at: tmpDirectory, to: directory)
                }

                // save manga cover if not already present
                let mangaDirectory = cache.directory(for: download.mangaIdentifier)
                let coverPath = mangaDirectory.appendingPathComponent("cover.png")
                if
                    !coverPath.exists,
                    let coverUrl = download.manga.cover.flatMap({ URL(string: $0) }),
                    let source = await SourceManager.shared.source(for: download.chapterIdentifier.sourceKey)
                {
                    let request = await source.getModifiedImageRequest(url: coverUrl, context: nil)
                    let result = try? await SourceNetwork.shared.data(for: request)
                    if let data = result?.0, self.isSuccessResponse(result?.1) {
                        try? data.write(to: coverPath)
                    }
                }

                await cache.add(chapter: download.chapterIdentifier)
            } catch {
                guard !Task.isCancelled else { return false }
                LogManager.logger.error("Error moving temporary download directory (\(tmpDirectory)) to final location: \(error)")
                markFailed(tmpDirectory: tmpDirectory)
                if let index = downloads.firstIndex(of: download) {
                    downloads[index].status = .failed
                    let failed = downloads.remove(at: index)
                    await delegate?.downloadFailed(download: failed)
                }
            }
            if let downloadIndex = downloads.firstIndex(where: { $0 == download }) {
                downloads[downloadIndex].status = .finished
                downloads.remove(at: downloadIndex)
                await delegate?.downloadFinished(download: download)
            }
        }
        pages = []
        currentPage = 0
        failedPages = 0
        descriptionWriteFailed = false
        failedPageNumbers = []
        return true
    }

    // Runs off the actor; cancellation interrupts the ZIP write.
    @concurrent
    nonisolated static func writeChapterArchive(from directory: URL, to archive: URL) async throws {
        let progress = Progress(totalUnitCount: 0)
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try FileManager.default.zipItem(at: directory, to: archive, shouldKeepParent: false, progress: progress)
        } onCancel: {
            progress.cancel()
        }
    }

    // store file with failed pages in failed download directory
    private func markFailed(tmpDirectory: URL) {
        let marker = cache.failureMarker(inTmpDirectory: tmpDirectory)
        do {
            try JSONEncoder().encode(failedPageNumbers.sorted()).write(to: marker)
        } catch {
            LogManager.logger.error("Error marking failed download (\(tmpDirectory)): \(error)")
        }
    }
}

// MARK: Utility
extension DownloadTask {
    private nonisolated func isSuccessResponse(_ response: URLResponse?) -> Bool {
        guard let httpResponse = response as? HTTPURLResponse else { return true }

        // redirect are followed by URLSession
        return (200..<300).contains(httpResponse.statusCode)
    }

    private nonisolated func isRetryableStatus(_ statusCode: Int) -> Bool {
        statusCode == 429 || (500...599).contains(statusCode)
    }

    // exponential backoff
    private nonisolated static func backoffDelay(forAttempt attempt: Int) -> TimeInterval {
        min(maxRetryDelay, retryBaseDelay * pow(2, Double(attempt)))
    }

    private nonisolated func retryDelay(from response: URLResponse?) -> TimeInterval? {
        guard
            let httpResponse = response as? HTTPURLResponse,
            let value = httpResponse.value(forHTTPHeaderField: "Retry-After")?
                .trimmingCharacters(in: .whitespaces),
            !value.isEmpty
        else {
            return nil
        }

        // Retry-After: <delay-seconds>
        if let seconds = TimeInterval(value), seconds.isFinite {
            return min(Self.maxRetryDelay, max(0, seconds))
        }

        // Retry-After: <http-date> (e.g. "Wed, 21 Oct 2015 07:28:00 GMT")
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "GMT")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
        if let date = formatter.date(from: value) {
            return min(Self.maxRetryDelay, max(0, date.timeIntervalSinceNow))
        }

        return nil
    }

    private nonisolated func guessFileExtension(response: URLResponse, defaultValue: String) -> String {
        if
            let suggestedFilename = response.suggestedFilename,
            !suggestedFilename.isEmpty,
            let pathExtension = URL(string: suggestedFilename)?.pathExtension,
            LocalFileManager.allowedImageExtensions.contains(pathExtension.lowercased())
        {
            return pathExtension
        }
        if
            let mimeType = response.mimeType,
            let type = UTType(mimeType: mimeType),
            let pathExtension = type.preferredFilenameExtension,
            LocalFileManager.allowedImageExtensions.contains(pathExtension)
        {
            return pathExtension
        }
        return defaultValue
    }
}
