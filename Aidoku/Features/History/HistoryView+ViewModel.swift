//
//  HistoryView+ViewModel.swift
//  Aidoku
//
//  Created by Skitty on 7/31/25.
//

import AidokuRunner
import Combine
import CoreData
import SwiftUI

extension HistoryView {
    @MainActor
    class ViewModel: ObservableObject {
        @Published var filteredHistory: [Int: HistorySection] = [:]
        @Published var mangaCache: [MangaIdentifier: AidokuRunner.Manga] = [:]
        @Published var chapterCache: [ChapterIdentifier: AidokuRunner.Chapter] = [:]

        enum LoadingState {
            case idle  // more available to laod
            case loading  // currently loading more
            case complete  // nothing more to load
        }

        @Published var loadingState: LoadingState = .idle

        private var offset = 0
        private var historyData: [Int: [HistoryEntry]] = [:]
        private var loadTask: Task<Bool, Never>?
        private var historyReloadGeneration = 0
        private var historyContentRevision = 0
        private var loadTaskID = UUID()
        private let historyIdentityLoader: (@Sendable ([ChapterIdentifier]) async -> HistoryBatch)?
        private let historyPageLoader: (@Sendable (Int, Int) async -> HistoryBatch)?

        private(set) var searchQuery: String = ""
        private var searchTask: Task<Void, Never>?

        private var missingMangaQueue: [MangaIdentifier: Set<String>] = [:]  // [mangaKey: Set<chapterId>]
        private var mangaLoadTask: Task<Void, Never>?
        private let maxConcurrentLoads = 3

        private let batchSize = 100

        private var cancellables = Set<AnyCancellable>()

        init(historyPageLoader: (@Sendable (Int, Int) async -> HistoryBatch)? = nil,
             historyIdentityLoader: (@Sendable ([ChapterIdentifier]) async -> HistoryBatch)? = nil,
             observesNotifications: Bool = true) {
            self.historyIdentityLoader = historyIdentityLoader
            self.historyPageLoader = historyPageLoader
            if observesNotifications { registerNotifications() }
        }
    }
}

extension HistoryView.ViewModel {
    private func registerNotifications() {
        NotificationCenter.default.publisher(for: .updateHistory)
            .sink { [weak self] _ in
                // reset all cached history entries
                guard let self else { return }
                Task { @MainActor in
                    _ = await self.loadTask?.value
                    self.historyReloadGeneration += 1
                    self.historyContentRevision += 1
                    self.loadTask = nil
                    self.filteredHistory = [:]
                    self.historyData = [:]
                    self.offset = 0
                    self.loadingState = .idle
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .historyAdded)
            .sink { [weak self] output in
                // fetch new history entries
                guard
                    let self,
                    let chapters = output.object as? [ChapterIdentifier]
                else {
                    return
                }
                Task { @MainActor in
                    await self.receiveHistoryChange(chapterIds: chapters)
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .historyRemoved)
            .sink { [weak self] output in
                // remove history entries
                guard let self else { return }
                Task { @MainActor in
                    if let chapters = output.object as? [ChapterIdentifier] {
                        for chapterId in chapters {
                            self.removeStoredHistory(chapterId: chapterId)
                        }
                    } else if let mangaId = output.object as? MangaIdentifier {
                        self.removeStoredHistory(mangaId: mangaId)
                    }
                }
            }
            .store(in: &cancellables)

        NotificationCenter.default.publisher(for: .historySet)
            .sink { [weak self] output in
                // remove existing history entry and add new one
                guard
                    let self,
                    let item = output.object as? (chapterId: ChapterIdentifier, page: Int)
                else {
                    return
                }
                Task { @MainActor in
                    await self.receiveHistoryChange(chapterIds: [item.chapterId])
                }
            }
            .store(in: &cancellables)
    }
}

// MARK: Loading
extension HistoryView.ViewModel {
    func receiveHistoryChange(chapterIds: [ChapterIdentifier]) async {
        let ids = Array(Set(chapterIds))
        guard !ids.isEmpty else { return }
        await fetchNew(count: ids.count, changedChapterIds: ids)
    }

    // fetch a specified number of new history entries (that will be appended to the top)
    func fetchNew(count: Int, refreshingDays: Set<Int> = [], replacingChapter: ChapterIdentifier? = nil, changedChapterIds: [ChapterIdentifier]? = nil) async {
        let generation = historyReloadGeneration
        // Several mutation notifications can await the same predecessor. Recheck
        // ownership after every suspension so only one successor reads/merges.
        while let predecessor = loadTask {
            let predecessorID = loadTaskID
            _ = await predecessor.value
            guard generation == historyReloadGeneration, !Task.isCancelled else { return }
            if loadTaskID == predecessorID { loadTask = nil }
        }
        guard !Task.isCancelled else { return }
        var refreshingDays = refreshingDays
        if let replacingChapter,
           let day = removeStoredHistory(chapterId: replacingChapter, updateFilteredHistory: false) {
            refreshingDays.insert(day)
        }
        let issued = UUID()
        loadTaskID = issued
        let task = Task.detached {
            while !Task.isCancelled, await self.isCurrentHistoryGeneration(generation) {
                // offset needs to be the number of items before today, in case of entries in the future
                let now = Date()
                let offset = await self.historyData.reduce(into: 0) { offset, section in
                    switch section.key {
                        case ..<0: // future
                            offset += section.value.count
                        case 0: // today
                            offset += section.value.prefix(while: { $0.date >= now }).count
                        default: // past
                            break
                    }
                }
                let newObjectCount = await self.processHistoryObjects(
                    limit: count,
                    offset: offset,
                    refreshingDays: refreshingDays, chapterIds: changedChapterIds
                )
                if let newObjectCount {
                    await self.increaseOffset(by: changedChapterIds == nil ? newObjectCount.fetched : newObjectCount.inserted, generation: generation)
                    break
                }
                // A removal changed the content snapshot while I/O was suspended.
                // Re-read the current top window instead of losing this new event.
                await Task.yield()
            }
            return false
        }
        loadTask = task
        _ = await task.value
        if loadTaskID == issued { loadTask = nil }
    }

    // load more history entries (called when scrolling to the bottom)
    func loadMore() async {
        guard loadingState == .idle else { return }

        let generation = historyReloadGeneration
        loadingState = .loading

        if loadTask == nil {
            loadTaskID = UUID()
            loadTask = Task.detached { [offset] in
                guard let newObjectCount = await self.processHistoryObjects(limit: self.batchSize, offset: offset) else { return false }
                await self.increaseOffset(by: newObjectCount.fetched, generation: generation)
                return newObjectCount.fetched < self.batchSize // if less than the limit, we reached the end
            }
        }
        guard let loadTask else { return }
        let issued = loadTaskID
        let completed = await loadTask.value
        // A refresh may have reset pagination while this task was suspended.
        guard generation == historyReloadGeneration else { return }
        if loadTaskID == issued { self.loadTask = nil }

        loadingState = completed ? .complete : .idle
    }
}

// MARK: Searching
extension HistoryView.ViewModel {
    // start a new search task with an optional delay
    func search(query: String, delay: Bool) async {
        // Cancel pending input even when returning to the currently applied query.
        searchTask?.cancel()
        guard searchQuery != query else { return }
        searchTask = Task {
            if delay {
                try? await Task.sleep(nanoseconds: 500_000_000) // wait 0.5s
            }
            guard !Task.isCancelled else { return }
            searchQuery = query
            refilterHistory()
        }
    }

    // refilter all of the existing cached history entries
    private func refilterHistory() {
        for (index, existingSection) in filteredHistory {
            let newSection = HistorySection(
                daysAgo: existingSection.daysAgo,
                entries: filterDay(entries: historyData[existingSection.daysAgo] ?? [])
            )
            filteredHistory[index] = newSection
        }
    }
}

// MARK: Removing
extension HistoryView.ViewModel {
    // remove history linked to an entry
    // if all is true, removes all history for the associated manga
    func removeHistory(entry: HistoryEntry, all: Bool = false) async {
        if all {
            await HistoryManager.shared.removeHistory(mangaId: entry.chapterId.mangaIdentifier)
        } else {
            await HistoryManager.shared.removeHistory(chapterIds: [entry.chapterId])
        }
    }

    // removes all history
    func clearHistory() {
        Task {
            await clearHistory {
                await CoreDataManager.shared.container.performBackgroundTask { context in
                    CoreDataManager.shared.clearHistory(context: context)
                }
            }
        }
    }

    // Batch deletion commits at execute(), not at a later context.save().
    // Keep the displayed records and pagination until that operation acknowledges success.
    func clearHistory(deleteHistory: () async -> Bool) async {
        _ = await loadTask?.value
        guard await deleteHistory() else { return }
        historyReloadGeneration += 1
        historyContentRevision += 1
        loadTask = nil
        filteredHistory = [:]
        historyData = [:]
        offset = 0
        loadingState = .idle
    }

    // remove a cached history entry for a chapter
    @discardableResult
    func removeStoredHistory(chapterId: ChapterIdentifier, updateFilteredHistory: Bool = true) -> Int? {
        historyContentRevision += 1
        for section in historyData {
            for (index, entry) in section.value.enumerated() where entry.chapterId == chapterId {
                historyData[section.key]?.remove(at: index)
                if updateFilteredHistory {
                    filteredHistory[section.key] = HistorySection(
                        daysAgo: section.key,
                        entries: filterDay(entries: historyData[section.key] ?? [])
                    )
                }
                offset -= 1
                return section.key
            }
        }
        return nil
    }

    // remove all cached history entries for a manga
    private func removeStoredHistory(mangaId: MangaIdentifier) {
        historyContentRevision += 1
        var modifiedDays = Set<Int>()
        for section in historyData {
            var index = 0
            for _ in 0..<section.value.count {
                let entry = historyData[section.key]![index]
                if entry.chapterId.mangaIdentifier == mangaId {
                    historyData[section.key]?.remove(at: index)
                    modifiedDays.insert(section.key)
                    offset -= 1
                } else {
                    index += 1
                }
            }
        }

        for day in modifiedDays {
            filteredHistory[day] = HistorySection(
                daysAgo: day,
                entries: filterDay(entries: historyData[day] ?? [])
            )
        }
    }
}

// MARK: Queue
extension HistoryView.ViewModel {
    private func startMissingMangaQueueIfNeeded() {
        if mangaLoadTask == nil || mangaLoadTask?.isCancelled == true {
            mangaLoadTask = Task { await self.processMissingMangaQueue() }
        }
    }

    // add a chapter (missing from coredata) to the queue for loading
    private func addToQueue(mangaId: MangaIdentifier, chapterKey: String) {
        if missingMangaQueue[mangaId] == nil {
            missingMangaQueue[mangaId] = []
        }
        missingMangaQueue[mangaId]?.insert(chapterKey)
    }

    // loader for manga/chapters missing from coredata
    private func processMissingMangaQueue() async {
        while !missingMangaQueue.isEmpty {
            let mangaIds = Array(missingMangaQueue.keys.prefix(maxConcurrentLoads))
            await withTaskGroup(of: Void.self) { group in
                for mangaId in mangaIds {
                    guard let chapterIds = missingMangaQueue.removeValue(forKey: mangaId) else { continue }
                    group.addTask {
                        await self.loadMangaAndChapters(mangaId: mangaId, chapterIds: chapterIds)
                    }
                }
                await group.waitForAll()
            }

        }
        mangaLoadTask = nil
    }

    // load manga and chapter data from source into cache
    private func loadMangaAndChapters(mangaId: MangaIdentifier, chapterIds: Set<String>) async {
        guard let source = await SourceManager.shared.source(for: mangaId.sourceKey) else { return }
        let tempManga = AidokuRunner.Manga(sourceKey: mangaId.sourceKey, key: mangaId.mangaKey, title: "")

        let needsManga = mangaCache[mangaId] == nil
        let generation = HistoryMetadataCache.shared.generation

        if let newManga = try? await source.getMangaUpdate(
            manga: tempManga,
            needsDetails: needsManga,
            needsChapters: true
        ) {
            guard !Task.isCancelled, generation == HistoryMetadataCache.shared.generation else { return }
            let resolvedManga = needsManga ? newManga : (mangaCache[mangaId] ?? newManga)
            let resolvedChapters = (newManga.chapters ?? []).filter { chapterIds.contains($0.key) }
            await CoreDataManager.shared.container.performBackgroundTask { context in
                let existing = resolvedChapters.filter {
                    CoreDataManager.shared.hasHistory(chapterId: .init(
                        sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: $0.key
                    ), context: context)
                }
                HistoryMetadataCache.shared.store(manga: resolvedManga, chapters: existing, generation: generation)
            }
            guard !Task.isCancelled, generation == HistoryMetadataCache.shared.generation else { return }
            await MainActor.run {
                if needsManga {
                    var compact = newManga
                    compact.chapters = nil
                    self.mangaCache[mangaId] = compact
                }
                if let chapters = newManga.chapters {
                    for chapter in chapters where chapterIds.contains(chapter.key) {
                        let key = ChapterIdentifier(sourceKey: mangaId.sourceKey, mangaKey: mangaId.mangaKey, chapterKey: chapter.key)
                        self.chapterCache[key] = chapter
                    }
                }
                self.refilterHistory()
            }
        }
    }
}

// MARK: Processing
extension HistoryView.ViewModel {
    struct HistoryInfo: Sendable {
        let chapterId: ChapterIdentifier
        let dateRead: Date?
        let progress: Int16
        let total: Int16
        let completed: Bool
    }

    struct HistoryBatch: Sendable {
        let history: [HistoryInfo]
        let metadata: HistoryMetadataBatch
    }

    private func historySnapshot() -> (generation: Int, data: [Int: [HistoryEntry]]) {
        (historyContentRevision, historyData)
    }

    // fetch history objects from core data and process them into history entries
    // returns the number of history objects found (if less than limit then the end was reached)
    private nonisolated func processHistoryObjects(
        limit: Int,
        offset: Int,
        refreshingDays: Set<Int> = [], chapterIds: [ChapterIdentifier]? = nil
    ) async -> (fetched: Int, inserted: Int)? {
        let snapshot = await historySnapshot()
        let batch: HistoryBatch
        if let chapterIds {
            if let historyIdentityLoader { batch = await historyIdentityLoader(chapterIds) }
            else {
                batch = await CoreDataManager.shared.container.performBackgroundTask { context in
                    Self.readIdentityHistoryBatch(chapterIds: chapterIds, context: context)
                }
            }
        } else if let historyPageLoader {
            batch = await historyPageLoader(limit, offset)
        } else {
            batch = await Self.readHistoryBatch(limit: limit, offset: offset)
        }
        guard !Task.isCancelled else { return nil }
        let historyObj = batch.history
        let metadata = batch.metadata

        var modifiedDays = refreshingDays
        var newHistoryData = snapshot.data
        var missingChapters: [ChapterIdentifier] = []
        let endOfDay = Date.endOfDay()
        let startOfDay = Date.startOfDay()
        let calendar = Calendar.autoupdatingCurrent

        var replacedCount = 0
        let changedIDs = Set(historyObj.map(\.chapterId))
        for day in Array(newHistoryData.keys) {
            let original = newHistoryData[day] ?? []
            let retained = original.filter { !changedIDs.contains($0.chapterId) }
            if retained.count != original.count {
                replacedCount += original.count - retained.count
                newHistoryData[day] = retained
                modifiedDays.insert(day)
            }
        }
        for obj in historyObj {
            let readDate = obj.dateRead ?? Date.distantPast
            let isInFuture = readDate > endOfDay
            let endDate = if isInFuture {
                // if the date is in the future, compare the difference to the start of the day instead of end
                startOfDay
            } else {
                endOfDay
            }
            let days = calendar.dateComponents(
                Set([Calendar.Component.day]),
                from: readDate,
                to: endDate
            ).day ?? 0

            let chapterId = obj.chapterId
            if metadata.manga[chapterId.mangaIdentifier] == nil || metadata.chapters[chapterId] == nil {
                missingChapters.append(chapterId)
            }

            let newEntry = HistoryEntry(
                chapterId: obj.chapterId,
                date: obj.dateRead ?? Date.distantPast,
                currentPage: obj.completed ? -1 : Int(obj.progress),
                totalPages: Int(obj.total)
            )
            var arr = newHistoryData[days] ?? []
            arr.append(newEntry)
            newHistoryData[days] = arr
            modifiedDays.insert(days)
        }

        // re-sort in case we appended "new" history at the bottom
        for day in modifiedDays {
            newHistoryData[day] = newHistoryData[day]?.sorted { $0.date > $1.date }  // sort by date, most recent first
        }

        let applied = await commitHistoryData(newHistoryData, metadata: metadata,
            missingChapters: missingChapters, modifiedDays: modifiedDays, generation: snapshot.generation)
        return applied ? (historyObj.count, historyObj.count - replacedCount) : nil
    }

    /// Exact event identities avoid reading the same newest row for different
    /// queued notifications. Bound the SQL predicate even for large imports.
    nonisolated static func readIdentityHistoryBatch(chapterIds: [ChapterIdentifier], context: NSManagedObjectContext) -> HistoryBatch {
        let ids = Array(Set(chapterIds))
        var rows: [HistoryObject] = []
        for start in stride(from: 0, to: ids.count, by: 100) {
            let request = HistoryObject.fetchRequest()
            request.predicate = NSCompoundPredicate(orPredicateWithSubpredicates: ids[start..<min(start + 100, ids.count)].map {
                NSPredicate(format: "sourceId == %@ AND mangaId == %@ AND chapterId == %@", $0.sourceKey, $0.mangaKey, $0.chapterKey)
            })
            rows += (try? context.fetch(request)) ?? []
        }
        let history = rows.map { HistoryInfo(chapterId: .init(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.chapterId),
            dateRead: $0.dateRead, progress: $0.progress, total: $0.total, completed: $0.completed) }
        return HistoryBatch(history: history,
            metadata: HistoryMetadataBatch.load(chapterIds: history.map(\.chapterId), context: context, cache: .shared))
    }

    var loadedHistoryIdentifiers: [ChapterIdentifier] { historyData.values.flatMap { $0.map(\.chapterId) } }
    var paginationOffset: Int { offset }

    private nonisolated static func readHistoryBatch(limit: Int, offset: Int) async -> HistoryBatch {
        await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            let history = CoreDataManager.shared.getRecentHistory(limit: limit, offset: offset, context: context)
                .map {
                    HistoryInfo(
                        chapterId: .init(sourceKey: $0.sourceId, mangaKey: $0.mangaId, chapterKey: $0.chapterId),
                        dateRead: $0.dateRead,
                        progress: $0.progress,
                        total: $0.total,
                        completed: $0.completed
                    )
                }
            return HistoryBatch(history: history, metadata: HistoryMetadataBatch.load(chapterIds: history.map(\.chapterId), context: context, cache: .shared))
        }
    }

    private func commitHistoryData(_ data: [Int: [HistoryEntry]], metadata: HistoryMetadataBatch,
                                   missingChapters: [ChapterIdentifier], modifiedDays: Set<Int>, generation: Int) -> Bool {
        guard generation == historyContentRevision, !Task.isCancelled else { return false }
        addMetadata(metadata, missingChapters: missingChapters)
        historyData = data
        var filtered = filteredHistory
        for day in modifiedDays {
            filtered[day] = HistorySection(daysAgo: day, entries: filterDay(entries: data[day] ?? []))
        }
        filteredHistory = filtered
        startMissingMangaQueueIfNeeded()
        return true
    }

    // filter a day's worth of history entries based on the search query
    // also deduplicates entries by manga, only showing the most recent entry for each manga (with additional count)
    private func filterDay(entries: [HistoryEntry]) -> [HistoryEntry] {
        var newEntries: [HistoryEntry] = []

        var counts: [MangaIdentifier: Int] = [:]  // keyed by manga key

        for entry in entries {
            let mangaId = entry.chapterId.mangaIdentifier
            if let existingCount = counts[mangaId] {
                counts[mangaId] = existingCount + 1
                continue
            }
            if !searchQuery.isEmpty {
                let query = searchQuery.lowercased()
                let manga = mangaCache[mangaId]
                if let manga, manga.title.lowercased().contains(query) {
                    newEntries.append(entry)
                }
            } else {
                newEntries.append(entry)
            }
            counts[mangaId] = 0
        }

        for (i, entry) in newEntries.enumerated() {
            if let additionalCount = counts[entry.chapterId.mangaIdentifier], additionalCount > 0 {
                newEntries[i].additionalEntryCount = additionalCount
            } else {
                newEntries[i].additionalEntryCount = nil
            }
        }

        return newEntries
    }
}

// MARK: Setters
extension HistoryView.ViewModel {
    private func isCurrentHistoryGeneration(_ generation: Int) -> Bool {
        generation == historyReloadGeneration
    }

    private func increaseOffset(by value: Int, generation: Int) {
        guard generation == historyReloadGeneration else { return }
        offset += value
    }

    private func addMetadata(_ metadata: HistoryMetadataBatch, missingChapters: [ChapterIdentifier]) {
        mangaCache.merge(metadata.manga) { _, new in new }
        chapterCache.merge(metadata.chapters) { _, new in new }
        for chapterId in missingChapters {
            addToQueue(mangaId: chapterId.mangaIdentifier, chapterKey: chapterId.chapterKey)
        }
    }

    private func setHistoryData(_ newHistoryData: [Int: [HistoryEntry]]) {
        historyData = newHistoryData
    }

    private func setFilteredHistory(_ newFilteredHistory: [Int: HistorySection]) {
        filteredHistory = newFilteredHistory
    }
}
