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
    private let network: SourceNetwork
    private var downloads: [Download]
    private weak var delegate: DownloadTaskDelegate?

    private var worker: Task<Void, Never>?
    private var controlGeneration = 0
    private var warmedPages: (chapter: ChapterIdentifier, task: Task<[Page], Never>)?

    private var currentPage: Int = 0
    private var failedPages: Int = 0
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

    init(id: String, cache: DownloadCache, downloads: [Download], network: SourceNetwork = .shared,
         delegate: DownloadTaskDelegate? = nil) {
        self.id = id
        self.network = network
        self.cache = cache
        self.downloads = downloads
        self.delegate = delegate
    }

    func setDelegate(delegate: DownloadTaskDelegate?) {
        self.delegate = delegate
    }

    func resume() {
        guard !running else { return }
        controlGeneration += 1
        running = true
        let previousWorker = worker
        worker = Task {
            // A cancelled render/network operation must finish unwinding before
            // a replacement touches the same chapter files and counters.
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
        let cancelled = downloads.filter {
            if let chapter { return $0.chapterIdentifier == chapter }
            if let manga { return $0.mangaIdentifier == manga }
            return true
        }
        guard !cancelled.isEmpty || (manga == nil && chapter == nil) else { return }
        let wasRunning = running
        controlGeneration += 1
        let generation = controlGeneration
        let previousWorker = worker
        previousWorker?.cancel()
        warmedPages?.task.cancel()
        warmedPages = nil
        running = false
        let cancelledCurrent = downloads.first.map { cancelled.contains($0) } ?? false
        // Remove by identity before suspending; indices cannot survive delegate callbacks.
        downloads.removeAll { cancelled.contains($0) }
        let cancellation = Task {
            await previousWorker?.value
            for download in cancelled {
                cache.tmpDirectory(for: download.chapterIdentifier).removeItem()
            }
            if cancelledCurrent {
                pages = []
                currentPage = 0
                failedPages = 0
                failedPageNumbers = []
            }
            if manga == nil && chapter == nil {
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
        guard !downloads.contains(where: { $0 == download }) else { return }
        downloads.append(download)
    }
}

extension DownloadTask {
    private func next() async {
        guard running, !Task.isCancelled else { return }

        // done with all downloads
        if downloads.isEmpty {
            running = false
            await delegate?.taskFinished(task: self)
            return
        }

        // attempt to download first chapter in the queue
        if
            let download = downloads.first,
            let source = await SourceManager.shared.source(for: download.chapterIdentifier.sourceKey)
        {
            guard running, !Task.isCancelled else { return }
            // if chapter already downloaded, skip
            let directory = cache.directory(for: download.chapterIdentifier)
            guard !directory.exists && !directory.appendingPathExtension("cbz").exists else {
                downloads.removeFirst()
                await delegate?.downloadFinished(download: download)
                return await next()
            }

            // download has been cancelled or failed, skip
            if download.status != .queued && download.status != .downloading && download.status != .paused {
                downloads.removeFirst()
                await delegate?.downloadCancelled(download: download)
                return await next()
            }

            await self.download(from: source)
        } else {
            guard running, !Task.isCancelled else { return }
            // source not found, skip this download
            let failed = downloads.removeFirst()
            markFailed(tmpDirectory: cache.tmpDirectory(for: failed.chapterIdentifier))
            await delegate?.downloadFailed(download: failed)
            await next()
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
        let page: NetworkPage
        let data: Data?
        let targetPath: URL?
        var stagedFile: URL? = nil
    }

    // perform download
    private func download(from source: AidokuRunner.Source) async {
        guard running && !downloads.isEmpty else { return }

        let download = downloads[0]
        let translationSettings = download.translatesImages == true ? await MainActor.run {
            var settings = ReaderTranslationSettings()
            settings.rightToLeftPanelOrder = download.manga.viewer == .rightToLeft
            return settings
        } : nil
        guard !Task.isCancelled, running, downloads.first == download else { return }
        currentPage = 0
        failedPages = 0
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
            guard !Task.isCancelled, running, downloads.first == download else { return }
            pages = loadedPages
            downloads[0].total = pages.count
        }

        var networkPages: [NetworkPage] = []
        var descriptions: [(Page, URL)] = []

        for (i, page) in pages.enumerated() {
            guard !Task.isCancelled, running, downloads.first == download else { return }
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
                        let output = try await translatedData(data, settings: translationSettings)
                        try Task.checkCancellation()
                        try output.write(to: targetPath.appendingPathExtension(DownloadImageTranslator.fileExtension(for: output)), options: .atomic)
                    } else if let text = page.text, let data = text.data(using: .utf8) {
                        guard translationSettings == nil else { throw DownloadError.pageProcessorFailed }
                        try data.write(to: targetPath.appendingPathExtension("txt"))
                    } else if let image = page.image {
                        guard let data = image.pngData() else { throw DownloadError.pageProcessorFailed }
                        let output = try await translatedData(data, settings: translationSettings)
                        try Task.checkCancellation()
                        try output.write(to: targetPath.appendingPathExtension(DownloadImageTranslator.fileExtension(for: output)), options: .atomic)
                    } else {
                        throw DownloadError.pageProcessorFailed
                    }
                } catch {
                    guard !Task.isCancelled, running, downloads.first == download else { return }
                    failedPages += 1
                    failedPageNumbers.append(i + 1)
                    LogManager.logger.error("Error writing page data: \(error)")
                }
                if let index = downloads.firstIndex(where: { $0 == download }) {
                    downloads[index].progress = currentPage
                    await delegate?.downloadProgressChanged(download: downloads[index])
                }
            }

            if page.hasDescription { descriptions.append((page, targetPath)) }
        }

        // Keep compressed files in the bounded queue, never decoded images. A
        // completed request immediately opens a slot; a slow retry cannot stall
        // every page in a fixed-size batch. Heavy image work remains serial;
        // at most two translated pages can overlap their text-only API waits.
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
                    result.stagedFile?.removeItem()
                    // Join and clean files created by requests that raced cancellation.
                    for await abandoned in group { abandoned.stagedFile?.removeItem() }
                    return
                }
                var failed = false
                do {
                    defer { result.stagedFile?.removeItem() }
                    guard let path = result.targetPath else { throw DownloadError.pageProcessorFailed }
                    if let file = result.stagedFile {
                        try FileManager.default.moveItem(at: file, to: path)
                    } else if let data = result.data {
                        try data.write(to: path)
                    } else { throw DownloadError.pageProcessorFailed }
                } catch {
                    failed = true
                    LogManager.logger.error("Error saving downloaded page: \(error)")
                }
                guard !Task.isCancelled, running, downloads.first == download else {
                    group.cancelAll()
                    for await abandoned in group { abandoned.stagedFile?.removeItem() }
                    return
                }
                // Refill before publishing progress to keep transport slots busy.
                if let page = next.next() {
                    group.addTask { await self.downloadPage(page, source: source, tmpDirectory: tmpDirectory, translationSettings: translationSettings) }
                }
                await incrementProgress(for: download.chapterIdentifier, failedPage: failed ? result.page.pageNumber : nil)
            }
        }

        // Metadata must finish before chapter promotion, but must not delay
        // the first image request. Descriptions use one bounded source request.
        for (page, target) in descriptions {
            guard !Task.isCancelled, running, downloads.first == download else { return }
            var description = page.description
            if description == nil { description = try? await source.getPageDescription(page: page.toNew()) }
            guard !Task.isCancelled, running, downloads.first == download else { return }
            if let data = description?.data(using: .utf8) { try? data.write(to: target.appendingPathExtension("desc.txt")) }
        }
        if !Task.isCancelled, running, downloads.first == download, currentPage == pages.count {
            await handleChapterDownloadFinish(download: download)
        }
    }

    // Every producer returns a file, including sources that transform images.
    // This bounds queued decoded output even when translation is much slower.
    func downloadPage(_ page: NetworkPage, source: AidokuRunner.Source, tmpDirectory: URL,
                              translationSettings: ReaderTranslationSettings? = nil) async -> PageDownloadResult {
        let request = await source.getModifiedImageRequest(url: page.url, context: page.context)
        let network = self.network
        let fetched = await fetchPageResource(for: request, tmpDirectory: tmpDirectory,
            fetch: { try await network.download(for: request) }, cleanup: { $0.removeItem() })
        guard fetched != nil || source.features.processesPages else { return .init(page: page, data: nil, targetPath: nil) }
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
                let input = try Data(contentsOf: staged, options: .mappedIfSafe)
                let output = try await DownloadImageTranslator.translate(input, settings: translationSettings)
                try Task.checkCancellation()
                try output.write(to: staged, options: .atomic)
                if output.starts(with: [137, 80, 78, 71, 13, 10, 26, 10]) { fileExtension = "png" }
            }
            try Task.checkCancellation()
            return .init(page: page, data: nil, targetPath: page.targetPath.appendingPathExtension(fileExtension), stagedFile: staged)
        } catch {
            staged.removeItem()
            if !(error is CancellationError) { LogManager.logger.error("Error processing downloaded page: \(error)") }
            return .init(page: page, data: nil, targetPath: nil)
        }
    }

    private func translatedData(_ data: Data, settings: ReaderTranslationSettings?) async throws -> Data {
        guard let settings else { return data }
        return try await DownloadImageTranslator.translate(data, settings: settings)
    }

    // Retry policy is identical for file-backed and data-backed responses.
    private func fetchPageResource<Payload: Sendable>(
        for urlRequest: URLRequest, tmpDirectory: URL,
        fetch: @Sendable () async throws -> (Payload, URLResponse),
        cleanup: @Sendable (Payload) -> Void
    ) async -> (Payload, URLResponse)? {
        var attempt = 0
        while !Task.isCancelled {
            let result = try? await fetch()

            // response was okay, bail out
            if let result, self.isSuccessResponse(result.1), !Task.isCancelled {
                return result
            }
            if let result { cleanup(result.0) }
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

    private func handleChapterDownloadFinish(download: Download) async {
        let tmpDirectory = cache.tmpDirectory(for: download.chapterIdentifier)
        // Overlap only lightweight next-chapter metadata with finalization.
        // Pixel downloads wait for the existing bounded queue to own the chapter.
        if downloads.count > 1, warmedPages == nil,
           let source = await SourceManager.shared.source(for: download.chapterIdentifier.sourceKey),
           (source.config?.maximumParallelRequests ?? Self.maxConcurrentPageTasks) > 1 {
            let next = downloads[1]
            warmedPages = (next.chapterIdentifier, Task { await Self.loadPages(next, source: source) })
        }


        if pages.isEmpty || (failedPages == pages.count && download.translatesImages != true) {
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
            await DownloadManager.shared.saveChapterMetadata(manga: download.manga, chapter: download.chapter, to: tmpDirectory)

            markFailed(tmpDirectory: tmpDirectory)

            if let downloadIndex = downloads.firstIndex(where: { $0 == download }) {
                downloads[downloadIndex].status = .failed
                let failed = downloads.remove(at: downloadIndex)
                await delegate?.downloadFailed(download: failed)
            }
        } else {
            do {
                // Save chapter metadata after successful download
                await DownloadManager.shared.saveChapterMetadata(manga: download.manga, chapter: download.chapter, to: tmpDirectory)

                let directory = cache.directory(for: download.chapterIdentifier)

                if AppSettings.downloads.compress.get() {
                    let archive = tmpDirectory.appendingPathExtension("cbz")
                    defer { archive.removeItem() }
                    try FileManager.default.zipItem(at: tmpDirectory, to: archive, shouldKeepParent: false)
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
                guard !Task.isCancelled else { return }
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
        failedPageNumbers = []
        await next()
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
