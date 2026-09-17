//
//  DownloadQueue.swift
//  Aidoku
//
//  Created by Skitty on 5/13/22.
//

import AidokuRunner
@preconcurrency import BackgroundTasks
import Foundation
import UIKit

// stores queued and active downloads
// creates a downloadtask for every source
// only one chapter per source is downloaded at a time
actor DownloadQueue {
    private let cache: DownloadCache
    private var onCompletion: (() -> Void)?

    private(set) var queue: [String: [Download]] = [:] // all queued downloads stored under source id
    private var tasks: [String: DownloadTask] = [:] // tasks for each source
    private var progressBlocks: [ChapterIdentifier: (Int, Int) -> Void] = [:]

    private var paused = false
    private(set) var suspendedForBackground = false
    private var registeredTask = false
    private var backgroundRequestPending = false
    private var wifiAvailable = Reachability.getConnectionType() == .wifi

    private var canUseNetwork: Bool {
        !AppSettings.downloads.downloadOnlyOnWifi.get() || wifiAvailable
    }
    private var totalDownloads: Int = 0
    private var completedDownloads: Int = 0
    private var bgTask: ProgressReporting?
    private var sendCancelNotification = true

    private static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".download"

    init(cache: DownloadCache, onCompletion: (() -> Void)? = nil) {
        self.cache = cache
        self.onCompletion = onCompletion
    }

    func setOnCompletion(_ onCompletion: (() -> Void)?) {
        self.onCompletion = onCompletion
    }

    func start() async {
        paused = false

        guard !queue.isEmpty, !suspendedForBackground, canUseNetwork else { return }

#if !targetEnvironment(simulator)
        if
            bgTask == nil,
            !backgroundRequestPending,
            #available(iOS 26.0, *),
            AppSettings.downloads.background.get(),
            !ProcessInfo.processInfo.isMacCatalystApp
        {
            await register()

            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.taskIdentifier,
                title: NSLocalizedString("DOWNLOADING"),
                subtitle: NSLocalizedString("PROCESSING_QUEUE")
            )
            // Do not leave a visible foreground download queued behind the
            // system's continued-processing scheduler.
            request.strategy = .fail
            backgroundRequestPending = true
            do {
                try await BGTaskScheduler.shared.submit(request: request)
            } catch {
                backgroundRequestPending = false
                LogManager.logger.error("Failed to start background downloading: \(error)")
            }
        }
#endif

        await initAndResumeTasks()
    }

    private func initAndResumeTasks() async {
        guard !paused, !suspendedForBackground, canUseNetwork else { return }
        for sourceKey in Array(queue.keys) {
            guard !paused, !suspendedForBackground, canUseNetwork else { return }
            guard let downloads = queue[sourceKey], !downloads.isEmpty else { continue }
            if tasks[sourceKey] == nil {
                // Publish a fully initialized worker without an actor suspension;
                // foreground and scheduler callbacks may both arrive here.
                tasks[sourceKey] = DownloadTask(id: sourceKey, cache: cache, downloads: downloads, delegate: self)
            }
            guard !paused, !suspendedForBackground, canUseNetwork else { return }
            await tasks[sourceKey]?.resume()
        }
    }

    func resume() async {
        await start()
    }

    // System suspension preserves the user's intent to run the queue. A manual
    // pause remains authoritative even if it happens while the app is hidden.
    func suspendForBackground() async {
        guard !paused, !queue.isEmpty else { return }
        suspendedForBackground = true
        await pauseTasksIfNeeded()
        guard suspendedForBackground else { return }
        saveQueueState()
        NotificationCenter.default.post(name: .downloadsPaused, object: nil)
    }

    func applicationDidEnterBackground() async {
        // Ordinary URLSession downloads also need suspension when no continued
        // processing grant exists (older iOS, disabled setting, denied request).
        guard bgTask == nil || queue.values.joined().contains(where: { $0.translatesImages == true }) else { return }
        await suspendForBackground()
    }

    func applicationDidBecomeActive() async {
        guard suspendedForBackground else { return }
        suspendedForBackground = false
        guard !paused else { return }
        guard canUseNetwork else { return }
        // Foreground recovery must not wait for another background task grant.
        await initAndResumeTasks()
        NotificationCenter.default.post(name: .downloadsResumed, object: nil)
    }

    func pause() async {
        paused = true

        if #available(iOS 26.0, *) {
            if let task = bgTask as? BGContinuedProcessingTask {
                task.updateTitle(
                    NSLocalizedString("DOWNLOADING"),
                    subtitle: NSLocalizedString("PAUSED")
                )
            }
        }

        await pauseTasksIfNeeded()
    }

    private func pauseTasksIfNeeded() async {
        for task in tasks.values {
            // A newer resume/foreground/network event can arrive while awaiting
            // a different source. Do not let an older pause stop it afterward.
            guard paused || suspendedForBackground || !canUseNetwork else { return }
            await task.pause()
        }
    }

    func setWifiAvailable(_ available: Bool) async {
        wifiAvailable = available
        if !canUseNetwork {
            await pauseTasksIfNeeded()
            NotificationCenter.default.post(name: .downloadsPaused, object: nil)
        } else if !paused, !suspendedForBackground {
            await initAndResumeTasks()
            NotificationCenter.default.post(name: .downloadsResumed, object: nil)
        }
    }

    @discardableResult
    func add(chapters: [AidokuRunner.Chapter], manga: AidokuRunner.Manga, autoStart: Bool = true, translatesImages: Bool = false) async -> [Download] {
        var downloads: [Download] = []
        for chapter in chapters {
            let identifier = ChapterIdentifier(
                sourceKey: manga.sourceKey,
                mangaKey: manga.key,
                chapterKey: chapter.key
            )
            guard !(await cache.isChapterDownloaded(identifier: identifier)) else {
                continue
            }

            guard queue[manga.sourceKey]?.contains(where: { $0.chapterIdentifier == identifier }) != true else { continue }

            // create tmp directory so we know it's queued
            let tmpDirectory = cache.tmpDirectory(for: identifier)
            tmpDirectory.removeItem() // remove in case it exists from a previous failed download
            tmpDirectory.createDirectory()

            var download = Download.from(manga: manga, chapter: chapter)
            download.translatesImages = translatesImages
            downloads.append(download)
            if queue[manga.sourceKey] == nil {
                queue[manga.sourceKey] = [download]
            } else {
                queue[manga.sourceKey]?.append(download)
                await tasks[manga.sourceKey]?.add(download: download)
            }
        }
        totalDownloads += downloads.count
        bgTask?.progress.totalUnitCount = Int64(totalDownloads)
        if autoStart {
            await start()
        }
        saveQueueState()
        return downloads
    }

    func cancelDownload(for chapter: ChapterIdentifier) async {
        if let task = tasks[chapter.sourceKey] {
            await task.cancel(chapter: chapter)
        } else {
            // no longer in queue but the tmp download directory still exists, so we should remove it
            cache.tmpDirectory(for: chapter).removeItem()
        }
        saveQueueState()
    }

    func cancelDownloads(for chapters: [ChapterIdentifier]) async {
        // disable individual download cancelled notifications
        sendCancelNotification = false
        defer { sendCancelNotification = true }
        for chapter in chapters {
            if let task = tasks[chapter.sourceKey] {
                await task.cancel(chapter: chapter)
            } else {
                cache.tmpDirectory(for: chapter).removeItem()
            }
            if let queueItem = queue[chapter.sourceKey]?.firstIndex(where: {
                $0.chapterIdentifier == chapter
            }) {
                queue[chapter.sourceKey]?.remove(at: queueItem)
            }
        }
        NotificationCenter.default.post(name: .downloadsCancelled, object: chapters)
        saveQueueState()
    }

    func cancelDownloads(for manga: MangaIdentifier) async {
        if let task = tasks[manga.sourceKey] {
            await task.cancel(manga: manga)
        } else {
            cache.directory(for: manga)
                .contentsIncludingHidden
                .filter {
                    $0.lastPathComponent.hasPrefix(DownloadCache.tmpDirectoryPrefix)
                        && !cache.hasFailureMarker(inTmpDirectory: $0)
                }
                .forEach { $0.removeItem() }
        }
        saveQueueState()
    }

    func cancelAll() async {
        sendCancelNotification = false
        defer { sendCancelNotification = true }
        for task in tasks {
            await task.value.cancel()
        }
        queue = [:]
        finishBackgroundTaskIfEmpty()
        NotificationCenter.default.post(name: .downloadsCancelled, object: nil)
        saveQueueState()
    }

    // register callback for download progress change
    func onProgress(for chapter: ChapterIdentifier, block: @escaping (Int, Int) -> Void) {
        progressBlocks[chapter] = block
    }

    func removeProgressBlock(for chapter: ChapterIdentifier) {
        progressBlocks.removeValue(forKey: chapter)
    }

    func saveQueueState() {
        let queueData = try? JSONEncoder().encode(queue)
        UserDefaults.standard.set(queueData, forKey: "Data.downloadQueueState")
    }

    func loadQueueState() async {
        guard
            let queueData = UserDefaults.standard.data(forKey: "Data.downloadQueueState"),
            let queueState = try? JSONDecoder().decode([String: [Download]].self, from: queueData)
        else {
            return
        }
        queue = queueState
        if !queue.isEmpty {
            await start()
        }
    }

    func hasQueuedDownloads() -> Bool {
        !queue.isEmpty
    }

    func isRunning() async -> Bool {
        for task in tasks where await task.value.running {
            return true
        }
        return false
    }
}

extension DownloadQueue {
    private func setBackgroundTask(_ task: ProgressReporting?) {
        bgTask = task
        backgroundRequestPending = false
        totalDownloads = queue.values.reduce(0) { $0 + $1.count }
        completedDownloads = 0
        bgTask?.progress.totalUnitCount = Int64(totalDownloads)
    }

    private func finishBackgroundTaskIfEmpty() {
        guard queue.isEmpty else { return }
        if #available(iOS 26.0, *), let task = bgTask as? BGContinuedProcessingTask {
            task.setTaskCompleted(success: true)
        }
        setBackgroundTask(nil)
    }

    @available(iOS 26.0, *)
    private func backgroundTaskExpired(_ task: BGContinuedProcessingTask) async {
        guard let current = bgTask as? BGContinuedProcessingTask, current === task else { return }
        setBackgroundTask(nil)
        task.setTaskCompleted(success: false)
        await suspendForBackground()
        if await MainActor.run(body: { UIApplication.shared.applicationState == .active }) {
            await applicationDidBecomeActive()
        }
    }

#if !targetEnvironment(simulator)
    @available(iOS 26.0, *)
    private func register() async {
        guard !registeredTask else { return }
        registeredTask = true

        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil) { @Sendable [weak self] task in
            guard let self, let task = task as? BGContinuedProcessingTask else { return }

            task.expirationHandler = {
                Task {
                    await self.backgroundTaskExpired(task)
                }
            }

            Task { @Sendable in
                await self.setBackgroundTask(task)
                await self.initAndResumeTasks()
                await self.finishBackgroundTaskIfEmpty()
            }
        }
    }
#endif
}

// MARK: - Task Delegate
extension DownloadQueue: DownloadTaskDelegate {
    func taskCancelled(task: DownloadTask) async {
        await taskFinished(task: task)
    }

    func taskPaused(task _: DownloadTask) async {}

    func taskFinished(task: DownloadTask) async {
        tasks.removeValue(forKey: task.id)
        queue.removeValue(forKey: task.id)
        finishBackgroundTaskIfEmpty()
        saveQueueState()
    }

    func downloadFinished(download: Download) async {
        await downloadCancelled(download: download)
        progressBlocks.removeValue(forKey: download.chapterIdentifier)
        onCompletion?()
        NotificationCenter.default.post(name: .downloadFinished, object: download)
    }

    func downloadFailed(download: Download) async {
        await downloadCancelled(download: download)
        progressBlocks.removeValue(forKey: download.chapterIdentifier)
        onCompletion?()
        NotificationCenter.default.post(name: .downloadFailed, object: download)
    }

    func downloadCancelled(download: Download) async {
        var sourceDownloads = queue[download.chapterIdentifier.sourceKey] ?? []
        sourceDownloads.removeAll { $0 == download }
        if sourceDownloads.isEmpty {
            queue.removeValue(forKey: download.chapterIdentifier.sourceKey)
        } else {
            queue[download.chapterIdentifier.sourceKey] = sourceDownloads
        }
        saveQueueState()
        progressBlocks.removeValue(forKey: download.chapterIdentifier)
        if sendCancelNotification {
            NotificationCenter.default.post(name: .downloadCancelled, object: download)
        }

        completedDownloads += 1
        bgTask?.progress.completedUnitCount = Int64(completedDownloads)
        finishBackgroundTaskIfEmpty()

        if #available(iOS 26.0, *) {
            if !paused, let task = bgTask as? BGContinuedProcessingTask {
                task.updateTitle(
                    NSLocalizedString("DOWNLOADING"),
                    subtitle: String(format: NSLocalizedString("%i_OF_%i"), completedDownloads, totalDownloads)
                )
            }
        }
    }

    func downloadProgressChanged(download: Download) async {
        if let index = queue[download.chapterIdentifier.sourceKey]?.firstIndex(where: { $0 == download }) {
            queue[download.chapterIdentifier.sourceKey]?[index] = download
        }
        if let block = progressBlocks[download.chapterIdentifier] {
            block(download.progress, download.total)
        }
        NotificationCenter.default.post(name: .downloadProgressed, object: download)
    }
}
