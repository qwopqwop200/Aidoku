//
//  LibraryViewModel.swift
//  Aidoku (iOS)
//
//  Created by Skitty on 7/25/22.
//

import AidokuRunner
import CoreData
import UIKit

@MainActor
class LibraryViewModel {
    private(set) var displayRevision: UInt64 = 0
    var manga: [MangaInfo] = [] {
        didSet { displayRevision &+= 1 }
    }
    var pinnedManga: [MangaInfo] = [] {
        didSet { displayRevision &+= 1 }
    }
    var sourceKeys: [String] = []

    // temporary storage when searching
    private var searchQuery: String = ""
    private var storedManga: [MangaInfo]?
    private var storedPinnedManga: [MangaInfo]?

    enum PinType: String, CaseIterable {
        case none
        case unread
        case updatedChapters

        var title: String {
            switch self {
                case .none: NSLocalizedString("PIN_DISABLED")
                case .unread: NSLocalizedString("PIN_UNREAD")
                case .updatedChapters: NSLocalizedString("PIN_UPDATED_CHAPTERS")
            }
        }

        var needsUpdateOnContentOpen: Bool {
            switch self {
                case .none: false
                case .unread: false
                case .updatedChapters: true
            }
        }
    }

    enum SortMethod: Int, CaseIterable {
        case alphabetical = 0
        case lastRead
        case lastOpened
        case lastUpdated
        case dateAdded
        case lastChapter
        case unreadChapters
        case totalChapters

        var title: String {
            switch self {
                case .alphabetical: NSLocalizedString("SORT_TITLE")
                case .lastRead: NSLocalizedString("SORT_LAST_READ")
                case .lastOpened: NSLocalizedString("SORT_LAST_OPENED")
                case .lastUpdated: NSLocalizedString("SORT_LAST_UPDATED")
                case .dateAdded: NSLocalizedString("SORT_DATE_ADDED")
                case .lastChapter: NSLocalizedString("SORT_LATEST_CHAPTER")
                case .unreadChapters: NSLocalizedString("SORT_UNREAD_CHAPTERS")
                case .totalChapters: NSLocalizedString("SORT_TOTAL_CHAPTERS")
            }
        }

        var descendingTitle: String {
            switch self {
                case .alphabetical: NSLocalizedString("ASCENDING") // reverse default for alphabetical sort
                case .lastRead: NSLocalizedString("NEWEST_FIRST")
                case .lastOpened: NSLocalizedString("NEWEST_FIRST")
                case .lastUpdated: NSLocalizedString("NEWEST_FIRST")
                case .dateAdded: NSLocalizedString("NEWEST_FIRST")
                case .lastChapter: NSLocalizedString("NEWEST_FIRST")
                case .unreadChapters: NSLocalizedString("HIGHEST_FIRST")
                case .totalChapters: NSLocalizedString("HIGHEST_FIRST")
            }
        }

        var ascendingTitle: String {
            switch self {
                case .alphabetical: NSLocalizedString("DESCENDING")
                case .lastRead: NSLocalizedString("OLDEST_FIRST")
                case .lastOpened: NSLocalizedString("OLDEST_FIRST")
                case .lastUpdated: NSLocalizedString("OLDEST_FIRST")
                case .dateAdded: NSLocalizedString("OLDEST_FIRST")
                case .lastChapter: NSLocalizedString("OLDEST_FIRST")
                case .unreadChapters: NSLocalizedString("LOWEST_FIRST")
                case .totalChapters: NSLocalizedString("LOWEST_FIRST")
            }
        }

        var sortStringValue: String {
            switch self {
                case .alphabetical: "manga.title"
                case .lastRead: "lastRead"
                case .lastOpened: "lastOpened"
                case .lastUpdated: "lastUpdated"
                case .dateAdded: "dateAdded"
                case .lastChapter: "lastChapter"
                case .unreadChapters: ""
                case .totalChapters: "manga.chapterCount"
            }
        }
    }

    struct BadgeType: OptionSet {
        let rawValue: Int

        static let unread = BadgeType(rawValue: 1 << 0)
        static let downloaded = BadgeType(rawValue: 1 << 1)
    }

    lazy var pinType: PinType = getPinType()
    lazy var sortMethod = SortMethod(rawValue: AppSettings.library.sortOption.get()) ?? .lastOpened
    lazy var sortAscending = AppSettings.library.sortAscending.get()
    lazy var badgeType = getBadgeType()

    var filters: [LibraryFilter] {
        didSet {
            saveFilters()
        }
    }
    var activeFilters: [LibraryFilter] {
        if let currentCategory, let group = filterGroups.first(where: { $0.title == currentCategory }) {
            group.filters + self.filters
        } else {
            self.filters
        }
    }

    var categories: [String] = []
    var filterGroups: [FilterGroup] = []
    lazy var currentCategory: String? = AppSettings.library.currentCategory.get() {
        didSet {
            if oldValue != currentCategory {
                categoryRevision &+= 1
                loadRevision &+= 1
                locked = isCategoryLocked()
            }
            AppSettings.library.currentCategory.set(currentCategory)
        }
    }
    private(set) var categoryRevision: UInt64 = 0
    private var publishedCategoryRevision: UInt64 = 0
    var hasCurrentCategorySnapshot: Bool { publishedCategoryRevision == categoryRevision }
    lazy var locked = isCategoryLocked()

    var isInRealCategory: Bool {
        if let currentCategory, !currentCategory.isEmpty {
            categories.contains(currentCategory)
        } else {
            false
        }
    }
    var isInUncategorizedCategory: Bool {
        currentCategory?.isEmpty ?? false
    }
    private(set) var actuallyEmpty = true

    struct LoadRequest {
        let filters: [LibraryFilter]
        let category: String?
        let sortMethod: SortMethod
        let sortAscending: Bool
        let pinType: PinType
    }

    struct Snapshot {
        var manga: [MangaInfo]
        var pinnedManga: [MangaInfo] = []
        var sourceKeys: [String] = []
        var actuallyEmpty = false
    }

    private let snapshotLoader: ((LoadRequest) async -> Snapshot?)?
    private var loadRevision: UInt64 = 0
    private var downloadCountRequests: [MangaIdentifier: UUID] = [:]
    private var libraryLoadTask: Task<Void, Never>?

    init(snapshotLoader: ((LoadRequest) async -> Snapshot?)? = nil) {
        self.snapshotLoader = snapshotLoader
        let filtersData = AppSettings.library.filtersData.get()
        if let filtersData {
            let filters = try? JSONDecoder().decode([LibraryFilter].self, from: filtersData)
            self.filters = filters ?? []
        } else {
            self.filters = []
        }
    }
}

extension LibraryViewModel {
    func isCategoryLocked() -> Bool {
        guard AppSettings.library.lockLibrary.get() else { return false }
        if let currentCategory, !currentCategory.isEmpty {
            let lockedCategories = AppSettings.library.lockedCategories.get()
            return lockedCategories.contains(currentCategory)
        }
        return true
    }

    func getBadgeType() -> BadgeType {
        var type: BadgeType = []
        if AppSettings.library.unreadChapterBadges.get() {
            type.insert(.unread)
        }
        if AppSettings.library.downloadedChapterBadges.get() {
            type.insert(.downloaded)
        }
        return type
    }

    func getPinType() -> PinType {
        PinType(rawValue: AppSettings.library.pinTitles.get()) ?? .none
    }

    func reloadSettings() {
        sortMethod = SortMethod(rawValue: AppSettings.library.sortOption.get()) ?? .lastOpened
        sortAscending = AppSettings.library.sortAscending.get()
        if
            let data = AppSettings.library.filtersData.get(),
            let restoredFilters = try? JSONDecoder().decode([LibraryFilter].self, from: data),
            filters != restoredFilters
        {
            filters = restoredFilters
        }
    }

    func refreshCategories(skipDataLoad: Bool = false) async {
        (categories, filterGroups) = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            (
                CoreDataManager.shared.getCategoryTitles(context: context),
                CoreDataManager.shared.getFilterGroups(context: context)
            )
        }
        if !skipDataLoad {
            let isInFilterGroup = filterGroups.contains(where: { $0.title == currentCategory })
            let showUncategorized = AppSettings.library.showUncategorizedCategory.get()
            if let currentCategory, (!categories.contains(currentCategory) && !isInFilterGroup) || (currentCategory.isEmpty && !showUncategorized) {
                let persistedCategory = AppSettings.library.currentCategory.get()
                if let persistedCategory,
                   categories.contains(persistedCategory) || filterGroups.contains(where: { $0.title == persistedCategory }) {
                    self.currentCategory = persistedCategory
                } else {
                    self.currentCategory = nil
                }
                await loadLibrary()
            } else if isInFilterGroup || filters.contains(where: { $0.type == .category }) {
                // A changed category or filter group can affect membership in the current list.
                await loadLibrary()
            }
        }
    }

    /// One drain owns publication. New events replace pending demand instead of
    /// creating concurrent fetch/enrichment chains over shared mutable arrays.
    func loadLibrary() async {
        loadRevision &+= 1
        downloadCountRequests.removeAll()
        if let libraryLoadTask {
            await libraryLoadTask.value
            return
        }
        let task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                let issued = loadRevision
                let request = LoadRequest(filters: activeFilters,
                    category: (isInUncategorizedCategory || isInRealCategory) ? currentCategory : nil,
                    sortMethod: sortMethod, sortAscending: sortAscending, pinType: pinType)
                let snapshot: Snapshot?
                if let snapshotLoader { snapshot = await snapshotLoader(request) }
                else { snapshot = await Self.makeSnapshot(request, isCurrent: { self.loadRevision == issued }) }
                guard !Task.isCancelled else { break }
                // A newer notification or category/filter change owns the next
                // snapshot. Never expose an obsolete partially enriched list.
                guard issued == loadRevision else { continue }
                if let snapshot {
                    publishedCategoryRevision = categoryRevision
                    manga = snapshot.manga
                    pinnedManga = snapshot.pinnedManga
                    sourceKeys = snapshot.sourceKeys
                    actuallyEmpty = snapshot.actuallyEmpty
                    storedManga = nil
                    storedPinnedManga = nil
                    if !searchQuery.isEmpty { applySearchFilter(query: searchQuery) }
                }
                break
            }
            libraryLoadTask = nil
        }
        libraryLoadTask = task
        await task.value
    }

    // swiftlint:disable:next cyclomatic_complexity
    private static func makeSnapshot(_ request: LoadRequest, isCurrent: () -> Bool) async -> Snapshot? {
        let filters = request.filters
        let currentCategory = request.category
        let sortMethod = request.sortMethod
        let sortAscending = request.sortAscending
        let pinType = request.pinType
        var (
            success,
            actuallyEmpty,
            pinnedManga,
            manga,
            sourceKeys,
            unappliedFilters
        ) = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            var pinnedManga: [MangaInfo] = []
            var manga: [MangaInfo] = []
            var sourceKeys: Set<String> = []
            let unappliedFilters = filters.filter { $0.type == .downloaded || $0.type == .hasUnread }

            let needsCategories = filters.contains { $0.type == .category && $0.value != nil }
            let request = LibraryMangaObject.fetchRequest()
            request.relationshipKeyPathsForPrefetching = needsCategories ? ["manga", "categories"] : ["manga"]
            if let currentCategory {
                if currentCategory.isEmpty {
                    request.predicate = NSPredicate(format: "manga != nil AND categories.@count == 0")
                } else {
                    request.predicate = NSPredicate(format: "manga != nil AND ANY categories.title == %@", currentCategory)
                }
            } else {
                request.predicate = NSPredicate(format: "manga != nil")
            }
            if sortMethod != .unreadChapters {
                request.sortDescriptors = [
                    NSSortDescriptor(
                        key: sortMethod.sortStringValue,
                        ascending: sortMethod == .alphabetical ? !sortAscending : sortAscending
                    )
                ]
            }
            guard let libraryObjects = try? context.fetch(request) else {
                return (false, true, pinnedManga, manga, sourceKeys, unappliedFilters)
            }

            let actuallyEmpty = libraryObjects.isEmpty

            var ids = Set<MangaIdentifier>()

            main: for libraryObject in libraryObjects {
                guard
                    let mangaObject = libraryObject.manga,
                    // ensure the manga hasn't already been accounted for
                    ids.insert(mangaObject.identifier).inserted
                else {
                    continue
                }

                let categories = needsCategories
                    ? (libraryObject.categories?.allObjects as? [CategoryObject])?.map { $0.title } ?? []
                    : []

                let info = MangaInfo(
                    id: mangaObject.identifier,
                    coverUrl: mangaObject.cover.flatMap { URL(string: $0) },
                    title: mangaObject.title,
                    author: mangaObject.author,
                    url: mangaObject.url.flatMap { URL(string: $0) }
                )

                sourceKeys.insert(mangaObject.sourceId)

                // process filters
                var filteredSourceKeys: Set<String> = []
                var filteredContentRatings: Set<Int16> = []
                var filteredCategories: Set<String> = []
                for filter in filters {
                    let condition: Bool
                    switch filter.type {
                        case .downloaded:
                            continue
                        case .tracking:
                            condition = CoreDataManager.shared.hasTrack(
                                mangaId: info.id,
                                context: context
                            )
                        case .hasUnread:
                            continue
                        case .started:
                            condition = CoreDataManager.shared.hasHistory(
                                mangaId: info.id,
                                context: context
                            )
                        case .completed:
                            condition = mangaObject.status == AidokuRunner.PublishingStatus.completed.rawValue
                        case .source:
                            guard let sourceId = filter.value else { continue }
                            if filter.exclude {
                                condition = info.id.sourceKey == sourceId
                            } else {
                                // handle included source filters as OR
                                filteredSourceKeys.insert(sourceId)
                                continue
                            }
                        case .contentRating:
                            guard let contentRating = filter.value.flatMap(MangaContentRating.init) else { continue }
                            if filter.exclude {
                                condition = mangaObject.nsfw == contentRating.rawValue
                            } else {
                                // handle included content rating filters as OR
                                filteredContentRatings.insert(Int16(contentRating.rawValue))
                                continue
                            }
                        case .category:
                            guard let category = filter.value else { continue }
                            if filter.exclude {
                                condition = categories.contains(category)
                            } else {
                                // handle included category filters as OR
                                filteredCategories.insert(category)
                                continue
                            }

                    }
                    let shouldSkip = filter.exclude ? condition : !condition
                    if shouldSkip {
                        continue main
                    }
                }
                if !filteredSourceKeys.isEmpty && !filteredSourceKeys.contains(info.id.sourceKey) {
                    continue main
                }
                if !filteredContentRatings.isEmpty && !filteredContentRatings.contains(mangaObject.nsfw) {
                    continue main
                }
                if !filteredCategories.isEmpty && !filteredCategories.contains(where: { categories.contains($0) }) {
                    continue main
                }

                switch pinType {
                    case .none:
                        manga.append(info)
                    case .unread:
                        // don't have unread info to sort yet
                        manga.append(info)
                    case .updatedChapters:
                        if libraryObject.lastUpdatedChapters > libraryObject.lastOpened {
                            pinnedManga.append(info)
                        } else {
                            manga.append(info)
                        }
                }
            }

            return (true, actuallyEmpty, pinnedManga, manga, sourceKeys, unappliedFilters)
        }

        guard success, isCurrent(), !Task.isCancelled else { return nil }
        let identifiers = (manga + pinnedManga).map(\.id)
        let unreads = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.unreadCounts(mangaIds: identifiers, context: context)
        }
        guard isCurrent(), !Task.isCancelled else { return nil }
        var downloads: [MangaIdentifier: Int] = [:]
        for identifier in identifiers {
            guard isCurrent(), !Task.isCancelled else { return nil }
            downloads[identifier] = await DownloadManager.shared.downloadsCount(for: identifier)
        }
        guard isCurrent(), !Task.isCancelled else { return nil }
        func enrich(_ values: [MangaInfo]) -> [MangaInfo] {
            values.map { value in
                var value = value
                value.unread = unreads[value.id] ?? 0
                value.downloads = downloads[value.id] ?? 0
                return value
            }.filter { value in
                unappliedFilters.allSatisfy { filter in
                    let condition = filter.type == .downloaded ? value.downloads > 0 : value.unread > 0
                    return filter.exclude ? !condition : condition
                }
            }
        }
        manga = enrich(manga)
        pinnedManga = enrich(pinnedManga)
        if pinType == .unread {
            let all = manga + pinnedManga
            pinnedManga = all.filter { $0.unread > 0 }
            manga = all.filter { $0.unread == 0 }
        }
        if sortMethod == .unreadChapters {
            let precedes: (MangaInfo, MangaInfo) -> Bool = { lhs, rhs in
                if !sortAscending { return lhs.unread > rhs.unread }
                if lhs.unread == 0 { return false }
                if rhs.unread == 0 { return true }
                return lhs.unread < rhs.unread
            }
            manga.sort(by: precedes)
            pinnedManga.sort(by: precedes)
        }
        return Snapshot(manga: manga, pinnedManga: pinnedManga,
                        sourceKeys: sourceKeys.sorted(), actuallyEmpty: actuallyEmpty)
    }

    /// All incremental changes update the canonical (unsearched) value first.
    /// A pending full snapshot must re-read after this newer data revision.
    private func mutateLibrary<Result>(_ body: () -> Result) -> Result {
        loadRevision &+= 1
        if let storedManga { manga = storedManga }
        if let storedPinnedManga { pinnedManga = storedPinnedManga }
        let result = body()
        if !searchQuery.isEmpty {
            storedManga = manga
            storedPinnedManga = pinnedManga
            applySearchFilter(query: searchQuery)
        }
        return result
    }

    func updateHistory(for mangaIds: Set<MangaIdentifier>, read: Bool) async {
        // Some affected rows may currently be filtered out. Rebuild membership and counts together.
        if libraryLoadTask != nil || pinType == .unread || activeFilters.contains(where: { $0.type == .hasUnread || $0.type == .started }) {
            await loadLibrary()
            return
        }
        let regular = (storedManga ?? manga).lazy.map(\.id)
        let pinned = (storedPinnedManga ?? pinnedManga).lazy.map(\.id)
        let affected = mangaIds.intersection(regular).union(mangaIds.intersection(pinned))
        guard !affected.isEmpty else { return }

        let revision = loadRevision
        let unreadCounts = await CoreDataManager.shared.container.performBackgroundTask { context in
            CoreDataManager.shared.unreadCounts(mangaIds: Array(affected), context: context)
        }
        guard revision == loadRevision else {
            await loadLibrary()
            return
        }

        mutateLibrary {
            let moveRead = read && sortMethod == .lastRead
            let ascending = sortAscending
            func update(_ rows: inout [MangaInfo]) {
                var moved: [MangaInfo] = []
                for index in rows.indices {
                    guard let count = unreadCounts[rows[index].id] else { continue }
                    rows[index].unread = count
                    if moveRead { moved.append(rows[index]) }
                }
                guard !moved.isEmpty else { return }
                rows.removeAll { unreadCounts[$0.id] != nil }
                if ascending { rows.append(contentsOf: moved) }
                else { rows.insert(contentsOf: moved, at: 0) }
            }
            update(&manga)
            update(&pinnedManga)
            if sortMethod == .unreadChapters { sortCanonicalLibrary() }
        }
    }

    func fetchUnreads(for identifier: MangaIdentifier) async {
        if libraryLoadTask != nil || activeFilters.contains(where: { $0.type == .hasUnread }) {
            await loadLibrary()
            return
        }
        let revision = loadRevision
        let unreadCount = await CoreDataManager.shared.container.performBackgroundTask { @Sendable context in
            let filters = CoreDataManager.shared.getMangaChapterFilters(
                mangaId: identifier,
                context: context
            )
            return CoreDataManager.shared.unreadCount(
                mangaId: identifier,
                lang: filters.language,
                scanlators: filters.scanlators,
                context: context
            )
        }
        guard revision == loadRevision else {
            await loadLibrary()
            return
        }
        var didUpdate = false
        mutateLibrary {
            if let index = self.manga.firstIndex(where: { $0.id == identifier }) {
                if self.manga[index].unread != unreadCount {
                    didUpdate = true
                    self.manga[index].unread = unreadCount
                }
            } else if let index = self.pinnedManga.firstIndex(where: { $0.id == identifier }) {
                if self.pinnedManga[index].unread != unreadCount {
                    didUpdate = true
                    self.pinnedManga[index].unread = unreadCount
                }
            }
        }
        // re-sort library if needed
        if didUpdate {
            if pinType == .unread {
                await loadLibrary()
            } else if sortMethod == .unreadChapters {
                await sortLibrary()
            }
        }
    }

    func fetchDownloadCounts(
        for identifier: MangaIdentifier?,
        count: @MainActor (MangaIdentifier) async -> Int = { await DownloadManager.shared.downloadsCount(for: $0) }
    ) async {
        // A deletion of all downloads or a membership change can affect rows outside the displayed set.
        guard let identifier, libraryLoadTask == nil, !activeFilters.contains(where: { $0.type == .downloaded }) else {
            await loadLibrary()
            return
        }
        let request = UUID()
        downloadCountRequests[identifier] = request
        let downloads = await count(identifier)
        guard downloadCountRequests[identifier] == request else { return }
        downloadCountRequests[identifier] = nil
        applyDownloadCounts([identifier: downloads])
    }

    func applyDownloadCounts(_ counts: [MangaIdentifier: Int]) {
        mutateLibrary {
            for index in pinnedManga.indices {
                if let count = counts[pinnedManga[index].id] { pinnedManga[index].downloads = count }
            }
            for index in manga.indices {
                if let count = counts[manga[index].id] { manga[index].downloads = count }
            }
        }
    }

    @MainActor
    func sortLibrary() async {
        // A pending snapshot captured the previous sort. Local reordering alone
        // would be overwritten when it finishes; queue a current snapshot instead.
        if libraryLoadTask != nil {
            await loadLibrary()
            return
        }
        if sortMethod == .alphabetical || sortMethod == .unreadChapters {
            mutateLibrary { sortCanonicalLibrary() }
        } else {
            await loadLibrary()
        }
    }

    private func sortCanonicalLibrary() {
        switch sortMethod {
            case .alphabetical:
                if sortAscending {
                    pinnedManga.sort { $0.title ?? "" > $1.title ?? "" }
                    manga.sort { $0.title ?? "" > $1.title ?? "" }
                } else {
                    pinnedManga.sort { $0.title ?? "" < $1.title ?? "" }
                    manga.sort { $0.title ?? "" < $1.title ?? "" }
                }

            case .unreadChapters:
                if sortAscending {
                    pinnedManga.sort {
                        if $0.unread == 0 {
                            false
                        } else if $1.unread == 0 {
                            true
                        } else {
                            $0.unread < $1.unread
                        }
                    }
                    manga.sort {
                        if $0.unread == 0 {
                            false
                        } else if $1.unread == 0 {
                            true
                        } else {
                            $0.unread < $1.unread
                        }
                    }
                } else {
                    pinnedManga.sort { $0.unread > $1.unread }
                    manga.sort { $0.unread > $1.unread }
                }

            default:
                break
        }
    }

    func setSort(method: SortMethod, ascending: Bool) async {
        guard sortMethod != method || sortAscending != ascending else {
            return
        }
        if sortAscending != ascending {
            sortAscending = ascending
            AppSettings.library.sortAscending.set(sortAscending)
        }
        if sortMethod != method {
            sortMethod = method
            AppSettings.library.sortOption.set(sortMethod.rawValue)
        }
        await sortLibrary()
    }

    func toggleFilter(method: LibraryFilter.FilterMethod, value: String? = nil) async {
        let filterIndex = filters.firstIndex(where: { $0.type == method && $0.value == value })
        if let filterIndex {
            if filters[filterIndex].exclude {
                filters.remove(at: filterIndex)
            } else {
                filters[filterIndex].exclude = true
            }
        } else {
            filters.append(LibraryFilter(type: method, value: value, exclude: false))
        }
        await loadLibrary()
    }

    private func saveFilters() {
        let filtersData = try? JSONEncoder().encode(filters)
        if let filtersData {
            AppSettings.library.filtersData.set(filtersData)
        }
    }

    func search(query: String) async {
        searchQuery = query

        guard !query.isEmpty else {
            // Every snapshot and mutation already maintains the canonical order while searching.
            if let storedManga {
                manga = storedManga
                self.storedManga = nil
            }
            if let storedPinnedManga {
                pinnedManga = storedPinnedManga
                self.storedPinnedManga = nil
            }
            return
        }
        applySearchFilter(query: query)
    }

    // Synchronous final projection: snapshot publication must not suspend after
    // its revision check and allow a new pending demand to be lost.
    private func applySearchFilter(query: String) {
        if storedManga == nil {
            storedManga = manga
            storedPinnedManga = pinnedManga
        }
        guard let storedManga, let storedPinnedManga else {
            return
        }

        let query = query.lowercased()
        pinnedManga = storedPinnedManga.filter { $0.title?.lowercased().contains(query) ?? false }
        manga = storedManga.filter { $0.title?.lowercased().fuzzyMatch(query) ?? false || $0.author?.lowercased().fuzzyMatch(query) ?? false }
    }

    // returns true if library was reloaded
    @discardableResult
    func mangaOpened(mangaId: MangaIdentifier) async -> Bool {
        guard sortMethod == .lastOpened || pinType.needsUpdateOnContentOpen else { return false }

        let libraryReloaded = mutateLibrary {
            var libraryReloaded = false

            let pinnedIndex = pinnedManga.firstIndex(where: { $0.id == mangaId })
            if let pinnedIndex {
                if sortMethod == .lastOpened {
                    let manga = pinnedManga.remove(at: pinnedIndex)
                    if pinType.needsUpdateOnContentOpen {
                        if sortAscending { self.manga.append(manga) }
                        else { self.manga.insert(manga, at: 0) }
                    } else {
                        if sortAscending { pinnedManga.append(manga) }
                        else { pinnedManga.insert(manga, at: 0) }
                    }
                } else {
                    libraryReloaded = true
                }
            } else if sortMethod == .lastOpened {
                let index = manga.firstIndex(where: { $0.id == mangaId })
                if let index {
                    let manga = manga.remove(at: index)
                    if sortAscending {
                        // add to end
                        self.manga.append(manga)
                    } else {
                        // add to start
                        self.manga.insert(manga, at: 0)
                    }
                }
            }

            return libraryReloaded
        }
        if libraryReloaded { await loadLibrary() }
        return libraryReloaded
    }

    @discardableResult
    func mangaRead(mangaId: MangaIdentifier) async -> Bool {
        let filters = activeFilters
        if filters.contains(where: { $0.type == .started }) {
            let present = (storedManga ?? manga).contains { $0.id == mangaId }
                || (storedPinnedManga ?? pinnedManga).contains { $0.id == mangaId }
            if libraryLoadTask != nil || filters.contains(where: { $0.type == .started && $0.exclude == present }) {
                await loadLibrary()
                return true
            }
        }
        if filters.contains(where: { $0.type == .hasUnread }) {
            await loadLibrary()
            return true
        }
        guard sortMethod == .lastRead else { return false }

        mutateLibrary {
            if let pinnedIndex = pinnedManga.firstIndex(where: { $0.id == mangaId }) {
                let manga = pinnedManga.remove(at: pinnedIndex)
                if pinType.needsUpdateOnContentOpen {
                    if sortAscending { self.manga.append(manga) }
                    else { self.manga.insert(manga, at: 0) }
                } else {
                    if sortAscending { pinnedManga.append(manga) }
                    else { pinnedManga.insert(manga, at: 0) }
                }
            } else if let index = manga.firstIndex(where: { $0.id == mangaId }) {
                let manga = manga.remove(at: index)
                if sortAscending { self.manga.append(manga) }
                else { self.manga.insert(manga, at: 0) }
            }
        }
        return true
    }

    func removeFromLibrary(manga: MangaInfo) async {
        mutateLibrary {
            pinnedManga.removeAll { $0.id == manga.id }
            self.manga.removeAll { $0.id == manga.id }
        }
        await MangaManager.shared.removeFromLibrary(mangaId: manga.id)
    }

    func removeFromLibrary(mangaIds: [MangaIdentifier]) async {
        let set = Set(mangaIds)
        mutateLibrary {
            pinnedManga.removeAll { set.contains($0.id) }
            self.manga.removeAll { set.contains($0.id) }
        }
        await MangaManager.shared.removeFromLibrary(mangaIds: mangaIds)
    }

    func addToCurrentCategory(manga: MangaInfo) async {
        guard let currentCategory, isInRealCategory else { return }
        await CoreDataManager.shared.addCategoriesToManga(
            mangaId: manga.id,
            categories: [currentCategory]
        )
    }

    func removeFromCurrentCategory(manga: MangaInfo) async {
        guard let currentCategory, isInRealCategory else { return }
        mutateLibrary {
            pinnedManga.removeAll { $0.id == manga.id }
            self.manga.removeAll { $0.id == manga.id }
        }
        await CoreDataManager.shared.removeCategoriesFromManga(
            mangaId: manga.id,
            categories: [currentCategory]
        )
    }
}
