//
//  SourceSearchViewModel.swift
//  Aidoku
//
//  Created by Skitty on 11/19/25.
//

import AidokuRunner
import SwiftUI
import CoreData

@MainActor
class SourceSearchViewModel: ObservableObject {
    private let getPage: (String, Int, [FilterValue]) async throws -> AidokuRunner.MangaPageResult
    private let getBookmarks: ([AidokuRunner.Manga]) async -> Set<String>

    @Published var entries: [AidokuRunner.Manga] = []
    @Published var error: Error?
    @Published var loadingInitial = true
    @Published var shouldScrollToTop = false
    @Published var bookmarkedItems: Set<String> = .init()

    private(set) var hasAppeared = false
    private(set) var hasMore = true
    private(set) var nextPage = 1

    private var currentSearch: String?
    private var generation = 0
    private var loadingSearch = false
    private var searchIsDebouncing = false
    private var searchTask: Task<(), Never>?
    private var loadMoreTask: Task<(), Never>?

    init(source: AidokuRunner.Source) {
        getPage = { query, page, filters in
            try await source.getSearchMangaList(query: query, page: page, filters: filters)
        }
        getBookmarks = Self.loadBookmarks
    }

    static func loadBookmarks(_ entries: [AidokuRunner.Manga]) async -> Set<String> {
        await CoreDataManager.shared.container.performBackgroundTask { context in
            var keys = Set<String>()
            for (source, manga) in Dictionary(grouping: entries, by: \.sourceKey) {
                let request = NSFetchRequest<NSDictionary>(entityName: "LibraryManga")
                request.resultType = .dictionaryResultType
                request.propertiesToFetch = ["manga.id"]
                request.predicate = NSPredicate(format: "manga.sourceId == %@ AND manga.id IN %@", source, manga.map(\.key))
                let results = (try? context.fetch(request)) ?? []
                keys.formUnion(results.compactMap { $0["manga.id"] as? String })
            }
            return keys
        }
    }

    init(
        getPage: @escaping (String, Int, [FilterValue]) async throws -> AidokuRunner.MangaPageResult,
        getBookmarks: @escaping ([AidokuRunner.Manga]) async -> Set<String>
    ) {
        self.getPage = getPage
        self.getBookmarks = getBookmarks
    }

    func onAppear(searchText: String, filters: [FilterValue]) {
        guard !hasAppeared, entries.isEmpty else { return }
        hasAppeared = true
        loadManga(searchText: searchText, filters: filters)
    }

    func waitForSearch() async {
        await searchTask?.value
    }

    func loadManga(
        searchText: String,
        filters: [FilterValue],
        delay: Bool = false,
        force: Bool = false
    ) {
        guard force || currentSearch != searchText || (!delay && searchIsDebouncing) else { return }
        generation += 1
        let requestGeneration = generation
        loadingSearch = true
        searchIsDebouncing = delay
        error = nil
        hasMore = true
        nextPage = 1
        currentSearch = searchText
        searchTask?.cancel()
        loadMoreTask?.cancel()
        loadMoreTask = nil
        searchTask = Task {
            if delay {
                // Coalesce typing without adding a full second to every search.
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
            guard !Task.isCancelled else { return }
            searchIsDebouncing = false
            do {
                var page = 1
                var result = try await getPage(searchText, page, filters)
                guard !Task.isCancelled else { return }
                while result.entries.isEmpty && result.hasNextPage {
                    page += 1
                    result = try await getPage(searchText, page, filters)
                    guard !Task.isCancelled else { return }
                }
                let bookmarks = await getBookmarks(result.entries)
                guard !Task.isCancelled, generation == requestGeneration else { return }
                bookmarkedItems = bookmarks
                hasMore = result.hasNextPage
                var keys = Set<String>()
                entries = result.entries.filter { keys.insert($0.key).inserted }
                nextPage = page + 1
                shouldScrollToTop = true
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                // A failed replacement search must not display the previous query's results.
                entries = []
                bookmarkedItems = []
                self.error = error
                hasMore = false
            }
            loadingSearch = false
            loadingInitial = false
        }
    }

    func loadMore(searchText: String, filters: [FilterValue]) async {
        // Coalesce cell callbacks instead of queuing another page behind each callback.
        if let loadMoreTask {
            await loadMoreTask.value
            return
        }
        guard !loadingSearch, hasMore, currentSearch == searchText else { return }
        error = nil
        let requestGeneration = generation
        let task = Task { @MainActor in
            defer {
                if generation == requestGeneration { loadMoreTask = nil }
            }
            do {
                repeat {
                    let result = try await getPage(searchText, nextPage, filters)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    let bookmarks = await getBookmarks(result.entries)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    bookmarkedItems.formUnion(bookmarks)
                    hasMore = result.hasNextPage
                    nextPage += 1

                    var keys = Set(entries.map(\.key))
                    let newEntries = result.entries.filter { keys.insert($0.key).inserted }
                    if !newEntries.isEmpty {
                        entries += newEntries
                        break
                    }
                    // Empty/duplicate-only pages must advance without awaiting this same task.
                } while hasMore
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                self.error = error
            }
        }
        loadMoreTask = task
        await task.value
    }
}
