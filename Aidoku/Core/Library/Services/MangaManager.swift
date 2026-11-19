//
//  MangaManager.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 8/14/22.
//

import AidokuRunner
import BackgroundTasks
import CoreData
import Nuke
import UIKit

actor MangaManager {
    static let shared = MangaManager()

    private static let taskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".libraryRefresh"

    private static let continuedTaskIdentifier = (Bundle.main.bundleIdentifier ?? "") + ".continuedLibraryRefresh"

    private var libraryRefreshTask: Task<Bool, Never>?
    private var libraryRefreshProgressTask: Task<(), Never>?
    private var onLibraryRefreshProgress: (@MainActor (Progress) -> Void)?

    private var pendingBackgroundRefresh: (category: String?, skipReachabilityCheck: Bool)?
    private var nextAutomaticRefreshAttempt = Date.distantPast

    private static let maxConcurrentLibraryUpdateTasks = 10

    nonisolated func getNextChapter(
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter],
        readingHistory: [String: (page: Int, date: Int)],
        sortAscending: Bool
    ) -> AidokuRunner.Chapter? {
        let resumeLastOpened = AppSettings.library.resumeLastOpenedChapter.get()

        // 1. Resume Reading: Find the most recently read chapter that isn't
        // completed, unless the "resume last opened" option is enabled.
        var selectedChapter: AidokuRunner.Chapter?
        var selectedDate: Int = -1

        for chapter in chapters {
            guard
                let history = readingHistory[chapter.id],
                resumeLastOpened || history.page != -1,
                history.date > selectedDate
            else { continue }

            if chapter.locked {
                let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
                let isDownloaded = DownloadManager.shared.getDownloadStatus(for: identifier) == .finished
                guard isDownloaded else { continue }
            }

            selectedDate = history.date
            selectedChapter = chapter
        }

        if let selectedChapter {
            return selectedChapter
        }

        // 2. Fallback: Find first uncompleted chapter in sort order (Start Reading)
        func canStart(_ chapter: AidokuRunner.Chapter) -> Bool {
            guard readingHistory[chapter.id]?.page != -1 else { return false }
            guard chapter.locked else { return true }
            let identifier = ChapterIdentifier(sourceKey: manga.sourceKey, mangaKey: manga.key, chapterKey: chapter.key)
            return DownloadManager.shared.getDownloadStatus(for: identifier) == .finished
        }
        return sortAscending ? chapters.first(where: canStart) : chapters.last(where: canStart)
    }

    /// Fetches the stored chapters for a manga in the user's sort order, along with the next chapter to read.
    nonisolated func getNextChapter(
        mangaId: MangaIdentifier,
        fallbackChapters: [AidokuRunner.Chapter]? = nil,
        fetchIfNeeded: Bool = false
    ) async -> (chapters: [AidokuRunner.Chapter], nextChapter: AidokuRunner.Chapter?) {
        let readingHistory = await CoreDataManager.shared.getReadingHistory(mangaId: mangaId)
        var chapters = await CoreDataManager.shared.getChapters(mangaId: mangaId)
            .map { $0.toNew() }

        // chapters are only stored for manga in the library, so fall back to the ones we have loaded
        if chapters.isEmpty {
            if let fallbackChapters, !fallbackChapters.isEmpty {
                chapters = fallbackChapters
            } else if fetchIfNeeded, let source = await SourceManager.shared.source(for: mangaId.sourceKey) {
                let manga = AidokuRunner.Manga(sourceKey: mangaId.sourceKey, key: mangaId.mangaKey, title: "")
                let updatedManga = try? await source.getMangaUpdate(
                    manga: manga,
                    needsDetails: false,
                    needsChapters: true
                )
                chapters = updatedManga?.chapters ?? []
            }
        }

        let filters = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getMangaChapterFilters(
                mangaId: mangaId,
                context: context
            )
        }
        let sortOption = ChapterSortOption(flags: filters.flags)
        let sortAscending = filters.flags & ChapterFlagMask.sortAscending != 0

        let sortedChapters: [AidokuRunner.Chapter] = switch sortOption {
            case .sourceOrder:
                sortAscending ? chapters.reversed() : chapters
            case .chapter:
                chapters.sorted {
                    let lhs = $0.chapterNumber ?? -1
                    let rhs = $1.chapterNumber ?? -1
                    return sortAscending ? lhs < rhs : lhs > rhs
                }
            case .uploadDate:
                chapters.sorted {
                    let lhs = $0.dateUploaded ?? .distantPast
                    let rhs = $1.dateUploaded ?? .distantPast
                    return sortAscending ? lhs < rhs : lhs > rhs
                }
        }

        let manga = AidokuRunner.Manga(sourceKey: mangaId.sourceKey, key: mangaId.mangaKey, title: "")
        let nextChapter = getNextChapter(
            manga: manga,
            chapters: sortedChapters,
            readingHistory: readingHistory,
            sortAscending: sortAscending
        )

        return (sortedChapters, nextChapter)
    }
}

// MARK: - Library Managing
extension MangaManager {
    func addToLibrary(
        manga: AidokuRunner.Manga,
        chapters: [AidokuRunner.Chapter] = [],
        fetchMangaDetails: Bool = false
    ) async {
        var manga = manga
        var chapters = chapters
        // update manga or chapters
        if fetchMangaDetails || chapters.isEmpty {
            if let source = await SourceManager.shared.source(for: manga.sourceKey) {
                manga = (try? await source.getMangaUpdate(manga: manga, needsDetails: fetchMangaDetails, needsChapters: chapters.isEmpty)) ?? manga
                chapters = manga.chapters ?? chapters
            }
        }
        let saved = await CoreDataManager.shared.container.performBackgroundTask { [manga, chapters] context in
            CoreDataManager.shared.addToLibrary(
                manga: manga,
                chapters: chapters,
                context: context
            )
            // add to default category
            let defaultCategory = AppSettings.library.defaultCategory.get()
            if let defaultCategory {
                let hasCategory = CoreDataManager.shared.hasCategory(title: defaultCategory, context: context)
                if hasCategory {
                    CoreDataManager.shared.addCategoriesToManga(
                        mangaId: manga.identifier,
                        categories: [defaultCategory],
                        context: context
                    )
                }
            }
            do {
                try context.save()
                return true
            } catch {
                context.rollback()
                LogManager.logger.error("MangaManager.addToLibrary: \(error.localizedDescription)")
                return false
            }
        }
        guard saved else { return }
        // add enhanced trackers
        await TrackerManager.shared.bindEnhancedTrackers(manga: manga)

        let mangaId = manga.identifier
        await MainActor.run {
            NotificationCenter.default.post(name: .addToLibrary, object: mangaId)
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
        }
    }

    func removeFromLibrary(mangaId: MangaIdentifier) async {
        let saved = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeManga(mangaId: mangaId, context: context)
            CoreDataManager.shared.removeChapters(mangaId: mangaId, context: context)
            CoreDataManager.shared.removeTracks(mangaId: mangaId, context: context)
            do {
                try context.save()
                return true
            } catch {
                context.rollback()
                LogManager.logger.error("Failed to remove manga: \(error)")
                return false
            }
        }
        guard saved else { return }
        await MainActor.run {
            NotificationCenter.default.post(name: .removeFromLibrary, object: mangaId)
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
            NotificationCenter.default.post(name: .updateTrackers, object: nil)
        }
    }

    func removeFromLibrary(mangaIds: [MangaIdentifier]) async {
        if mangaIds.count > 100 {
            await UIApplication.shared.appDelegate?.showLoadingIndicator()
        }
        let saved = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.removeFromLibrary(ids: mangaIds, context: context)
            do {
                try context.save()
                return true
            } catch {
                context.rollback()
                LogManager.logger.error("Failed to remove multiple manga: \(error)")
                return false
            }
        }
        guard saved else {
            await UIApplication.shared.appDelegate?.hideLoadingIndicator()
            return
        }
        await MainActor.run {
            for id in mangaIds {
                NotificationCenter.default.post(name: .removeFromLibrary, object: id)
            }
            NotificationCenter.default.post(name: .updateLibrary, object: nil)
            NotificationCenter.default.post(name: .updateTrackers, object: nil)
        }
        await UIApplication.shared.appDelegate?.hideLoadingIndicator()
    }

    func restoreToLibrary(
        manga: Manga,
        chapters: [Chapter],
        trackItems: [TrackItem],
        categories: [String]
    ) async -> Bool {
        let newManga = manga.toNew()
        let newChapters = chapters.map { $0.toNew() }
        let lastOpened = manga.lastOpened
        let lastUpdated = manga.lastUpdated
        let lastUpdatedChapters = manga.lastUpdatedChapters
        let lastChapter = manga.lastChapter
        let lastRead = manga.lastRead
        let dateAdded = manga.dateAdded

        return await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.addToLibrary(
                manga: newManga,
                chapters: newChapters,
                context: context
            )

            if let libraryObject = CoreDataManager.shared.getLibraryManga(
                mangaId: newManga.identifier,
                context: context
            ) {
                if
                    let lastOpened,
                    let lastUpdated,
                    let lastUpdatedChapters,
                    let dateAdded
                {
                    libraryObject.lastOpened = lastOpened
                    libraryObject.lastUpdated = lastUpdated
                    libraryObject.lastUpdatedChapters = lastUpdatedChapters
                    libraryObject.lastChapter = lastChapter
                    libraryObject.lastRead = lastRead
                    libraryObject.dateAdded = dateAdded
                }
            }

            for item in trackItems {
                CoreDataManager.shared.createTrack(
                    id: item.id,
                    trackerId: item.trackerId,
                    mangaId: item.mangaId,
                    title: item.title,
                    chapterOffset: item.chapterOffset,
                    context: context
                )
            }

            for category in categories {
                let hasCategory = CoreDataManager.shared.hasCategory(title: category, context: context)
                if !hasCategory {
                    do {
                        try CoreDataManager.shared.createCategory(title: category, context: context)
                    } catch {
                        context.rollback()
                        LogManager.logger.error("MangaManager.restoreToLibrary category: \(error.localizedDescription)")
                        return false
                    }
                }
            }
            CoreDataManager.shared.addCategoriesToManga(
                mangaId: newManga.identifier,
                categories: categories,
                context: context
            )

            do {
                try context.save()
                return true
            } catch {
                context.rollback()
                LogManager.logger.error(
                    "MangaManager.restoreToLibrary: \(error.localizedDescription)")
                return false
            }
        }
    }

    static func shouldAskForCategories() async -> Bool {
        let categories = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getCategoryTitles(sorted: false, context: context)
        }
        guard !categories.isEmpty else { return false }
        if
            let defaultCategory = AppSettings.library.defaultCategory.get(),
            defaultCategory == "none" || categories.contains(defaultCategory)
        {
            return false
        }
        return true
    }
}

// MARK: - Category Managing
extension MangaManager {
    func setCategories(mangaId: MangaIdentifier, categories: [String]) async {
        await CoreDataManager.shared.setMangaCategories(
            mangaId: mangaId,
            categories: categories
        )
        NotificationCenter.default.post(name: .updateMangaCategories, object: MangaInfo(id: mangaId))
    }
}

// MARK: - Library Updating
extension MangaManager {
    nonisolated func register() {
#if !targetEnvironment(simulator)
        let launch: @Sendable (BGTask) -> Void = { [weak self] task in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            let delivery = LibraryBackgroundRefresh { success in task.setTaskCompleted(success: success) }
            task.expirationHandler = { delivery.expire() }
            delivery.start { await self.runBackgroundRefresh(task) }
        }
        BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.taskIdentifier, using: nil, launchHandler: launch)
        if #available(iOS 26.0, *) {
            BGTaskScheduler.shared.register(forTaskWithIdentifier: Self.continuedTaskIdentifier, using: nil, launchHandler: launch)
        }
#endif
    }

    private func runBackgroundRefresh(_ task: BGTask) async -> Bool {
        if #available(iOS 26.0, *), task is BGContinuedProcessingTask {
            let options = pendingBackgroundRefresh
            pendingBackgroundRefresh = nil
            return await refreshLibrary(
                category: options?.category,
                skipReachabilityCheck: options?.skipReachabilityCheck ?? false,
                task: task as? ProgressReporting
            )
        }
        let action = automaticRefreshAction(canStart: true)
        guard action == .start else {
            scheduleSystemRefresh(action)
            return true
        }
        return await refreshLibrary(task: task as? ProgressReporting)
    }

    private func automaticRefreshAction(canStart: Bool) -> LibraryAutomaticRefresh {
        .action(
            interval: AppSettings.library.updateInterval.get(),
            lastUpdated: AppSettings.library.lastUpdated.get(),
            retryAfter: nextAutomaticRefreshAttempt,
            now: .now,
            canStart: canStart
        )
    }

    func refreshLibraryIfOverdue() async {
        guard automaticRefreshAction(canStart: true) == .start, !AppSettings.flags.libraryRefreshInProgress.get() else { return }
        await refreshLibrary()
    }

    func scheduleLibraryRefresh() async {
        let active = await UIApplication.shared.applicationState == .active
        let action = automaticRefreshAction(canStart: active)
        if action == .start {
            guard !AppSettings.flags.libraryRefreshInProgress.get() else { return }
            Task { await refreshLibrary() }
        } else {
            scheduleSystemRefresh(action)
        }
    }

    private func scheduleSystemRefresh(_ action: LibraryAutomaticRefresh) {
#if !targetEnvironment(simulator)
        switch action {
            case .disabled:
                BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: Self.taskIdentifier)
            case .schedule(let date):
                let request = BGProcessingTaskRequest(identifier: Self.taskIdentifier)
                request.earliestBeginDate = date
                request.requiresExternalPower = false
                request.requiresNetworkConnectivity = true
                do {
                    try BGTaskScheduler.shared.submit(request)
                } catch {
                    LogManager.logger.error("Could not schedule library refresh: \(error)")
                }
            case .start:
                break
        }
#endif
    }

    func backgroundRefreshLibrary(category: String? = nil, skipReachabilityCheck: Bool = false) async {
#if !targetEnvironment(simulator)
        if #available(iOS 26.0, *), AppSettings.library.backgroundRefresh.get(), !ProcessInfo.processInfo.isMacCatalystApp {
            let request = BGContinuedProcessingTaskRequest(
                identifier: Self.continuedTaskIdentifier,
                title: NSLocalizedString("REFRESHING_LIBRARY"),
                subtitle: NSLocalizedString("PROCESSING_ENTRIES")
            )
            do {
                try BGTaskScheduler.shared.submit(request)
                pendingBackgroundRefresh = (category, skipReachabilityCheck)
                return
            } catch {
                LogManager.logger.error("Failed to start background library refresh: \(error)")
            }
        }
#endif

        await refreshLibrary(category: category, skipReachabilityCheck: skipReachabilityCheck)
    }

    /// Refresh manga objects in library.
    @discardableResult
    func refreshLibrary(
        category: String? = nil,
        forceAll: Bool = false,
        skipReachabilityCheck: Bool = false,
        task: (ProgressReporting & Sendable)? = nil
    ) async -> Bool {
        guard !Task.isCancelled else { return false }
        if let libraryRefreshTask {
            // A caller joining an existing refresh does not own its cancellation or completion effects.
            return await libraryRefreshTask.value
        } else {
            // spawn new library refresh
            nextAutomaticRefreshAttempt = Date.now.addingTimeInterval(300)
            AppSettings.flags.libraryRefreshInProgress.set(true)
            let worker = Task {
                let tabController = await UIApplication.shared.firstKeyWindow?.rootViewController as? TabBarController
                await doLibraryRefresh(
                    category: category,
                    skipReachabilityCheck: skipReachabilityCheck,
                    forceAll: forceAll,
                    refreshStarted: {
                        await tabController?.showLibraryRefreshView()

                        self.onLibraryRefreshProgress = { progress in
                            tabController?.setLibraryRefreshProgress(Float(progress.fractionCompleted))
                            task?.progress.totalUnitCount = progress.totalUnitCount
                            task?.progress.completedUnitCount = progress.completedUnitCount
                            if #available(iOS 26.0, *), let task = task as? BGContinuedProcessingTask {
                                task.updateTitle(
                                    NSLocalizedString("REFRESHING_LIBRARY"),
                                    subtitle: String(format: NSLocalizedString("%i_OF_%i"), progress.completedUnitCount, progress.totalUnitCount)
                                )
                            }
                        }
                    }
                )

                // wait 0.5s for final progress animation to complete
                try? await Task.sleep(nanoseconds: 500_000_000)
                libraryRefreshProgressTask?.cancel()
                libraryRefreshProgressTask = nil
                onLibraryRefreshProgress = nil
                await tabController?.hideAccessoryView()
                NotificationCenter.default.post(name: .updateLibrary, object: nil)
                if Task.isCancelled {
                    nextAutomaticRefreshAttempt = Date.now.addingTimeInterval(300)
                }
                libraryRefreshTask = nil
                AppSettings.flags.libraryRefreshInProgress.reset()
                await scheduleLibraryRefresh()
                return !Task.isCancelled
            }
            libraryRefreshTask = worker
            return await withTaskCancellationHandler {
                await worker.value
            } onCancel: {
                worker.cancel()
            }
        }
    }

    /// Check if a manga should skip updating based on skip options.
    private nonisolated func shouldSkip(
        manga: Manga,
        options: [String],
        excludedCategories: [String] = [],
        loadedSourceKeys: Set<String>,
        context: NSManagedObjectContext
    ) -> Bool {
        // update strategy is never
        if manga.updateStrategy == .never {
            return true
        }
        // next update time hasn't been reached
        if let nextUpdateTime = manga.nextUpdateTime {
            if nextUpdateTime > Date() {
                return true
            }
        }
        // source is missing
        if !loadedSourceKeys.contains(manga.sourceId) {
            return true
        }
        // completed
        if options.contains("completed") && manga.status == .completed {
            return true
        }
        // has unread chapters
        if options.contains("hasUnread") && CoreDataManager.shared.unreadCount(
            mangaId: manga.identifier,
            lang: manga.langFilter,
            scanlators: manga.scanlatorFilter,
            context: context
        ) > 0 {
            return true
        }
        // has no read chapters
        if options.contains("notStarted") && CoreDataManager.shared.readCount(
            mangaId: manga.identifier,
            lang: manga.langFilter,
            scanlators: manga.scanlatorFilter,
            context: context
        ) == 0 {
            return true
        }

        if !excludedCategories.isEmpty {
            // check if excluded via category
            let categories = CoreDataManager.shared.getCategories(
                mangaId: manga.identifier,
                context: context
            ).compactMap { $0.title }

            if !categories.isEmpty {
                if excludedCategories.contains(where: categories.contains) {
                    return true
                }
            }
        }

        return false
    }

    private func doLibraryRefresh(
        category: String?,
        skipReachabilityCheck: Bool,
        forceAll: Bool,
        refreshStarted: (() async -> Void)? = nil
    ) async {
        guard !Task.isCancelled else { return }
        // make sure user agent and sources have loaded before doing library refresh
        _ = await UserAgentProvider.shared.getUserAgent()
        await SourceManager.shared.waitForSourcesLoad()

        guard !Task.isCancelled else { return }
        // process failed tracker updates first
        await TrackerManager.shared.processPendingUpdates()

        guard !Task.isCancelled else { return }
        // fetch all library items from db
        let allManga = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.getLibraryManga(category: category, context: context).compactMap { $0.manga?.toManga() }
        }

        // ensure there are manga to update
        guard !allManga.isEmpty, !Task.isCancelled else {
            return
        }

        // check if connected to wi-fi
        if
            !skipReachabilityCheck,
            AppSettings.library.updateOnlyOnWifi.get(),
            Reachability.getConnectionType() != .wifi
        {
            return
        }

        let skipOptions = forceAll ? [] : AppSettings.library.skipTitles.get()
        let excludedCategories = forceAll ? [] : AppSettings.library.excludedUpdateCategories.get().filter { $0 != category }
        let updateMetadata = forceAll || AppSettings.library.refreshMetadata.get()

        await refreshStarted?()

        let allLoadedSourceKeys = await Set(SourceManager.shared.getLoadedSources().map { $0.key })

        // filter items that we should skip
        let filteredManga = await CoreDataManager.shared.container.performBackgroundTask { context in
            allManga.filter { manga in
                !self.shouldSkip(
                    manga: manga,
                    options: skipOptions,
                    excludedCategories: excludedCategories,
                    loadedSourceKeys: allLoadedSourceKeys,
                    context: context
                )
            }
        }

        let total = filteredManga.count
        var completed = 0

        let notificationsEnabled = AppSettings.library.notifyNewChapters.get()
        var pendingNotifications: [NotificationManager.NewChaptersSummary] = []

        let newDetails = await {
            var results: [MangaIdentifier: AidokuRunner.Manga] = [:]
            let progress = Progress(totalUnitCount: Int64(total))

            for manga in filteredManga {
                guard !Task.isCancelled else { return results }

                guard
                    let newManga = try? await SourceManager.shared.source(for: manga.sourceId)?
                        .getMangaUpdate(manga: manga.toNew(), needsDetails: updateMetadata, needsChapters: true)
                else {
                    completed += 1
                    progress.completedUnitCount = Int64(completed)
                    updateLibraryRefreshProgress(progress)
                    continue
                }

                guard !Task.isCancelled else { return results }
                if updateMetadata {
                    results[manga.identifier] = Self.compactRefreshMetadata(newManga)
                }

                let mangaId = manga.identifier
                let mangaTitle = manga.title

                let summary = await MangaUpdateWriter.shared.perform(for: mangaId) { context -> NotificationManager.NewChaptersSummary? in
                    guard
                        let libraryObject = CoreDataManager.shared.getLibraryManga(
                            mangaId: mangaId,
                            context: context
                        ),
                        let mangaObject = libraryObject.manga
                    else {
                        return nil
                    }

                    // update details
                    if updateMetadata {
                        mangaObject.load(from: newManga)
                    }

                    let chapters = newManga.chapters ?? []
                    let newChapters = chapters.isEmpty ? [] : CoreDataManager.shared.setChapters(
                        chapters,
                        mangaId: mangaId,
                        context: context
                    )
                    let notifiableCount: Int
                    do {
                        notifiableCount = try CoreDataManager.shared.createMangaUpdates(
                            mangaId: mangaId,
                            chapters: newChapters,
                            language: mangaObject.langFilter,
                            scanlators: mangaObject.scanlatorFilter ?? [],
                            context: context
                        )
                        if !newChapters.isEmpty {
                            libraryObject.lastChapter = chapters.compactMap { $0.dateUploaded }.max()
                            libraryObject.lastUpdatedChapters = Date.now
                        }
                        if updateMetadata || !newChapters.isEmpty {
                            libraryObject.lastUpdated = Date.now
                        }
                        if context.hasChanges {
                            try context.save()
                        }
                    } catch {
                        context.rollback()
                        LogManager.logger.error("Failed to store library refresh: \(error.localizedDescription)")
                        return nil
                    }

                    guard notifiableCount > 0 else { return nil }
                    let title = mangaObject.title.isEmpty ? (mangaTitle ?? "") : mangaObject.title
                    return NotificationManager.NewChaptersSummary(
                        mangaIdentifier: mangaId,
                        mangaTitle: title,
                        chapterCount: notifiableCount
                    )
                }

                if notificationsEnabled, let summary {
                    pendingNotifications.append(summary)
                }

                completed += 1
                progress.completedUnitCount = Int64(completed)
                updateLibraryRefreshProgress(progress)
            }

            return results
        }()

        // These summaries describe committed rows, including a write that finished during cancellation.
        await NotificationManager.shared.notifyNewChapters(pendingNotifications)
        guard !Task.isCancelled else { return }

        if updateMetadata {
            for mangaItem in filteredManga {
                guard let newInfo = newDetails[mangaItem.identifier] else { continue }
                mangaItem.load(from: newInfo.toOld())
            }
        }

        guard !Task.isCancelled else { return }
        if category == nil {
            AppSettings.library.lastUpdated.set(Date.now)
        }
    }

    /// Final metadata publication needs no source chapter arrays. The current
    /// response remains available to its DB transaction, then can be released.
    nonisolated static func compactRefreshMetadata(_ manga: AidokuRunner.Manga) -> AidokuRunner.Manga {
        var compact = manga
        compact.chapters = nil
        return compact
    }

    private func updateLibraryRefreshProgress(_ progress: Progress) {
        libraryRefreshProgressTask?.cancel()
        libraryRefreshProgressTask = Task {
            // buffer progress updates by 100ms
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            await onLibraryRefreshProgress?(progress)
        }
    }
}

// MARK: - Detail Editing
extension MangaManager {
    // sets uploaded cover image and returns the new cover url
    func setCover(manga: AidokuRunner.Manga, cover: PlatformImage) async -> String? {
        if manga.isLocal() {
            return await LocalFileManager.shared.setCover(for: manga.key, image: cover)
        }

        // upload cover image to Documents/Covers/id.png
        let documentsDirectory = FileManager.default.documentDirectory
        let targetDirectory = documentsDirectory.appendingPathComponent("Covers")
        let ext = if #available(iOS 17.0, *) {
            "heic"
        } else {
            "png"
        }
        var targetUrl = targetDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        while targetUrl.exists {
            targetUrl = targetDirectory.appendingPathComponent(UUID().uuidString).appendingPathExtension(ext)
        }
        targetDirectory.createDirectory()
        do {
            let data = if #available(iOS 17.0, *) {
                cover.heicData()
            } else {
                cover.pngData()
            }
            guard let data else { return nil }
            try data.write(to: targetUrl)
        } catch {
            LogManager.logger.error("MangaManager.setMangaCover: \(error.localizedDescription)")
            return nil
        }

        // set cover in coredata
        let coverUrl = "aidoku-image:///Covers/\(targetUrl.lastPathComponent)"
        await CoreDataManager.shared.setCover(
            mangaId: manga.identifier,
            coverUrl: coverUrl
        )

        return coverUrl
    }

    func resetCover(manga: AidokuRunner.Manga) async -> String? {
        var cover: String?
        defer {
            // a cancelled reset must not clear the stored cover
            if !Task.isCancelled {
                // set new cover and get old cover url
                let originalCover = await CoreDataManager.shared.setCover(
                    mangaId: manga.identifier,
                    coverUrl: cover,
                    original: true
                )

                // if the original cover is an aidoku image, remove it
                if originalCover != cover, let originalCover, let url = URL(string: originalCover)?.toAidokuFileUrl() {
                    url.removeItem()
                }
            }
        }

        guard let source = await SourceManager.shared.source(for: manga.sourceKey) else { return nil }

        // fetch new manga details (for cover)
        let newManga = try? await source.getMangaUpdate(
            manga: manga,
            needsDetails: true,
            needsChapters: false
        )

        cover = newManga?.cover

        return cover
    }
}

// MARK: Migration
extension MangaManager {
    func migrate(
        copy: Bool,
        forceRemoveFromLibrary: Bool = false,
        fromSeries: [AidokuRunner.Manga],
        toSeries: [MangaIdentifier: AidokuRunner.Manga?],
        withChapters: [MangaIdentifier: [AidokuRunner.Chapter]] = [:],
        progressReport: (@Sendable (Float) -> Void)? = nil
    ) async {
        let newDetails = await fetchNewDetails(
            fromSeries: fromSeries,
            toSeries: toSeries,
            withChapters: withChapters,
            progressReport: { counter in
                if let progressReport {
                    progressReport(Float(counter) / Float(fromSeries.count * 2))
                }
            }
        )

        await withTaskGroup(of: (from: AidokuRunner.Manga, to: AidokuRunner.Manga)?.self) { group in
            let batchSize = 10
            var counter = fromSeries.count

            for i in stride(from: 0, to: fromSeries.count, by: batchSize) {
                let batch = Array(fromSeries[i..<min(i + batchSize, fromSeries.count)])

                for oldManga in batch {
                    group.addTask {
                        guard
                            let details = newDetails[oldManga.identifier]
                        else { return nil }

                        let newManga = details.0
                        let newChapters = details.1

                        return await Self.migrate(
                            copy: copy,
                            forceRemoveFromLibrary: forceRemoveFromLibrary,
                            from: oldManga,
                            to: newManga,
                            withChapters: newChapters
                        )
                    }
                }

                for await result in group {
                    counter += 1
                    if let progressReport {
                        progressReport(Float(counter) / Float(fromSeries.count * 2))
                    }
                    if let result {
                        if !copy {
                            await TrackerManager.shared.bindEnhancedTrackers(manga: result.to)
                            NotificationCenter.default.post(name: .migratedManga, object: result)
                        }
                    }
                }
            }
        }
    }

    static func migrate(
        copy: Bool,
        forceRemoveFromLibrary: Bool,
        from oldManga: AidokuRunner.Manga,
        to newManga: AidokuRunner.Manga,
        withChapters newChapters: [AidokuRunner.Chapter],
    ) async -> (AidokuRunner.Manga, AidokuRunner.Manga)? {
        // The same destination already owns this history, downloads and settings.
        // Replacing or removing its source would discard those persistent records.
        guard oldManga.identifier != newManga.identifier else { return nil }

        // add new item to library if copying
        if copy {
            let inLibrary = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
                let storedNewManga = CoreDataManager.shared.getManga(
                    mangaId: newManga.identifier,
                    context: context
                )
                guard let storedNewManga else {
                    return false // add to library
                }
                // update details
                storedNewManga.load(from: newManga)
                // update chapters
                CoreDataManager.shared.setChapters(
                    newChapters,
                    mangaId: newManga.identifier,
                    context: context
                )
                do { try context.save() } catch { return false }
                return storedNewManga.libraryObject != nil
            }
            if !inLibrary {
                await MangaManager.shared.addToLibrary(
                    manga: newManga,
                    chapters: newChapters
                )
            }
        }

        // migrate/copy data
        let result: (AidokuRunner.Manga, AidokuRunner.Manga)? = await CoreDataManager.shared.container.performBackgroundTask { context in
            do {
                // update manga object in library with new data
                // remove old entry if the new one already exists in library
                if !copy {
                    var mangaObjectToUpdate: MangaObject?

                    // new is already in library
                    if newManga.identifier != oldManga.identifier, let storedNewManga = CoreDataManager.shared.getManga(
                        mangaId: newManga.identifier,
                        context: context
                    ) {
                        // update the object in the library with the new details we fetched already
                        mangaObjectToUpdate = storedNewManga
                        // remove old entry
                        CoreDataManager.shared.removeManga(
                            mangaId: oldManga.identifier,
                            context: context
                        )
                    } else {
                        // get existing old object to replace data with new details
                        mangaObjectToUpdate = CoreDataManager.shared.getManga(
                            mangaId: oldManga.identifier,
                            context: context
                        )
                    }

                    mangaObjectToUpdate?.load(from: newManga)
                }

                // copy categories
                if copy {
                    let categories = CoreDataManager.shared.getCategories(
                        mangaId: oldManga.identifier,
                        context: context
                    )
                    CoreDataManager.shared.addCategoriesToManga(
                        mangaId: newManga.identifier,
                        categories: categories,
                        context: context
                    )
                }

                // migrate history
                let storedOldHistory = CoreDataManager.shared.getHistoryForManga(
                    mangaId: oldManga.identifier,
                    context: context
                )

                var maxChapterRead = storedOldHistory
                    .compactMap { history -> NSNumber? in
                        if history.completed, let chapterNum = history.chapter?.chapter {
                            return chapterNum
                        } else {
                            return nil
                        }
                    }
                    .max { $0.decimalValue < $1.decimalValue }?
                    .floatValue

                if maxChapterRead == nil || maxChapterRead == -1 {
                    // try finding max volume read instead, in case of no chapters
                    maxChapterRead = storedOldHistory
                        .filter { $0.completed }
                        .compactMap { $0.chapter?.volume != nil ? $0.chapter : nil }
                        .max { $0.volume!.decimalValue < $1.volume!.decimalValue }?
                        .volume?.floatValue
                }

                // remove old chapters and history
                if !copy {
                    CoreDataManager.shared.removeChapters(
                        mangaId: oldManga.identifier,
                        context: context
                    )

                    CoreDataManager.shared.removeHistory(
                        mangaId: oldManga.identifier,
                        context: context
                    )

                    // store new chapters
                    CoreDataManager.shared.setChapters(
                        newChapters,
                        mangaId: newManga.identifier,
                        context: context
                    )
                }

                // mark new chapters as read
                if let maxChapterRead {
                    var chaptersToMark = newChapters.filter({ $0.chapterNumber ?? Float.greatestFiniteMagnitude <= maxChapterRead })
                    if chaptersToMark.isEmpty {
                        // fall back to using volume numbers instead, in case the source we're migrating to uses volumes
                        chaptersToMark = newChapters.filter({ $0.volumeNumber ?? Float.greatestFiniteMagnitude <= maxChapterRead })
                    }
                    if !chaptersToMark.isEmpty {
                        CoreDataManager.shared.setCompleted(
                            chapterIds: chaptersToMark.map {
                                .init(sourceKey: newManga.sourceKey, mangaKey: newManga.key, chapterKey: $0.key)
                            },
                            context: context
                        )
                    }
                }

                // migrate trackers
                let trackItems = CoreDataManager.shared.getTracks(
                    mangaId: oldManga.identifier,
                    context: context
                )

                for item in trackItems {
                    guard
                        let trackId = item.id,
                        let trackerId = item.trackerId,
                        !CoreDataManager.shared.hasTrack(
                            trackerId: trackerId,
                            mangaId: newManga.identifier,
                            context: context
                        ),
                        let tracker = TrackerManager.getTracker(id: trackerId),
                        tracker.canRegister(mangaId: newManga.identifier)
                    else {
                        if !copy && newManga.identifier != oldManga.identifier {
                            context.delete(item)
                        }
                        continue
                    }

                    if copy {
                        CoreDataManager.shared.createTrack(
                            id: trackId,
                            trackerId: trackerId,
                            mangaId: newManga.identifier,
                            title: item.title,
                            chapterOffset: Int(item.chapterOffset),
                            context: context
                        )
                    } else {
                        item.sourceId = newManga.sourceKey
                        item.mangaId = newManga.key
                    }
                }

                try context.save()

                return (from: oldManga, to: newManga)
            } catch {
                LogManager.logger.error("Error migrating manga \(oldManga.key): \(error)")
                return nil
            }
        }

        // migrate settings
        if result != nil, let readingMode = UserDefaults.standard.string(forKey: "Reader.readingMode.\(oldManga.identifier)") {
            UserDefaults.standard.set(readingMode, forKey: "Reader.readingMode.\(newManga.identifier)")
            if !copy {
                UserDefaults.standard.removeObject(forKey: "Reader.readingMode.\(oldManga.identifier)")
            }
        }

        if copy && result != nil {
            // remove old item from library
            if forceRemoveFromLibrary {
                await shared.removeFromLibrary(mangaId: oldManga.identifier)
            } else {
                // categories were copied; refresh library to show the new entry
                await MainActor.run {
                    NotificationCenter.default.post(name: .updateLibrary, object: nil)
                }
            }
        }

        return result
    }

    private func fetchNewDetails(
        fromSeries: [AidokuRunner.Manga],
        toSeries: [MangaIdentifier: AidokuRunner.Manga?],
        withChapters: [MangaIdentifier: [AidokuRunner.Chapter]],
        progressReport: (Int) -> Void
    ) async -> [MangaIdentifier: (AidokuRunner.Manga, [AidokuRunner.Chapter])] {
        await withTaskGroup(
            of: (MangaIdentifier, AidokuRunner.Manga, [AidokuRunner.Chapter])?.self,
            returning: [MangaIdentifier: (AidokuRunner.Manga, [AidokuRunner.Chapter])].self
        ) { group in
            let batchSize = 5
            var ret: [MangaIdentifier: (AidokuRunner.Manga, [AidokuRunner.Chapter])] = [:]
            var counter = 0

            for i in stride(from: 0, to: fromSeries.count, by: batchSize) {
                let batch = Array(fromSeries[i..<min(i + batchSize, fromSeries.count)])

                for oldManga in batch {
                    group.addTask {
                        guard
                            let newManga = toSeries[oldManga.identifier],
                            let newManga,
                            let source = await SourceManager.shared.source(for: newManga.sourceKey)
                        else { return nil }

                        let newChapters = withChapters[oldManga.identifier]

                        let updatedManga = try? await source.getMangaUpdate(
                            manga: newManga,
                            needsDetails: true,
                            needsChapters: newChapters == nil
                        )

                        let mangaDetails = updatedManga ?? newManga
                        guard let chapters = newChapters ?? updatedManga?.chapters else { return nil }

                        return (oldManga.identifier, mangaDetails, chapters)
                    }
                }

                // wait for all results in batch to finish before continuing
                for await result in group {
                    counter += 1
                    progressReport(counter)
                    if let result {
                        ret[result.0] = (result.1, result.2)
                    }
                }
            }

            return ret
        }
    }
}
