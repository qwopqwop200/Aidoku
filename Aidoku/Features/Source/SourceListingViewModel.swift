import AidokuRunner
import SwiftUI

/// Owns a listing's request lifetime, independently of SwiftUI cell lifetimes.
@MainActor
final class SourceListingViewModel: ObservableObject {
    @Published var entries: [AidokuRunner.Manga] = []
    @Published var bookmarkedItems: Set<String> = []
    @Published private(set) var home: Home?
    @Published private(set) var error: Error?
    @Published private(set) var loadingInitial = false
    @Published private(set) var loadingMore = false
    private(set) var hasMore = false
    private(set) var nextPage = 1

    private let getPage: (AidokuRunner.Listing, Int) async throws -> AidokuRunner.MangaPageResult
    private let getHome: (AidokuRunner.Listing) async throws -> Home?
    private let getBookmarks: ([AidokuRunner.Manga]) async -> Set<String>
    private(set) var currentListing: AidokuRunner.Listing?
    private var generation = 0
    private var task: Task<Void, Never>?

    init(
        getPage: @escaping (AidokuRunner.Listing, Int) async throws -> AidokuRunner.MangaPageResult,
        getHome: @escaping (AidokuRunner.Listing) async throws -> Home? = { _ in nil },
        getBookmarks: @escaping ([AidokuRunner.Manga]) async -> Set<String> = SourceSearchViewModel.loadBookmarks
    ) {
        self.getPage = getPage
        self.getHome = getHome
        self.getBookmarks = getBookmarks
    }

    func cancel() {
        generation += 1
        task?.cancel()
        task = nil
        error = nil
        loadingInitial = false
        loadingMore = false
        hasMore = false
    }

    func reload(listing: AidokuRunner.Listing) async {
        cancel()
        self.currentListing = listing
        entries = []
        bookmarkedItems = []
        home = nil
        error = nil
        nextPage = 1
        hasMore = true
        loadingInitial = true
        await start(initial: true)
    }

    func loadMore() async {
        if let task {
            await task.value
            return
        }
        guard hasMore, home == nil else { return }
        await start(initial: nextPage == 1)
    }

    private func start(initial: Bool) async {
        guard let listing = currentListing else { return }
        let requestGeneration = generation
        error = nil
        loadingInitial = initial
        loadingMore = !initial
        let request = Task { @MainActor in
            defer {
                if generation == requestGeneration {
                    task = nil
                    loadingInitial = false
                    loadingMore = false
                }
            }
            do {
                if initial {
                    let customHome = try await getHome(listing)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    if let customHome {
                        home = customHome
                        hasMore = false
                        return
                    }
                }
                repeat {
                    let result = try await getPage(listing, nextPage)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    let bookmarks = await getBookmarks(result.entries)
                    guard !Task.isCancelled, generation == requestGeneration else { return }
                    bookmarkedItems.formUnion(bookmarks)
                    var keys = Set(entries.map(\.key))
                    let additions = result.entries.filter { keys.insert($0.key).inserted }
                    nextPage += 1
                    hasMore = result.hasNextPage
                    if !additions.isEmpty {
                        entries += additions
                        break
                    }
                } while hasMore
            } catch {
                guard !Task.isCancelled, generation == requestGeneration else { return }
                self.error = error
            }
        }
        task = request
        await request.value
    }
}
