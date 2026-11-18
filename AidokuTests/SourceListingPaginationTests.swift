import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct SourceListingPaginationTests {
    private let listing = AidokuRunner.Listing(id: "test", name: "Test")
    private func result(_ keys: [String], more: Bool = true) -> AidokuRunner.MangaPageResult {
        .init(entries: keys.map { .init(sourceKey: "test", key: $0, title: $0) }, hasNextPage: more)
    }

    @Test func initialEmptyPagesAndDuplicateEntriesAdvance() async {
        var pages: [Int] = []
        let model = SourceListingViewModel(getPage: { _, page in
            pages.append(page)
            return result(page == 1 ? [] : ["one", "one"], more: page == 1)
        }, getBookmarks: { _ in [] })
        await model.reload(listing: listing)
        #expect(pages == [1, 2])
        #expect(model.entries.map(\.key) == ["one"])
        #expect(!model.hasMore)
        #expect(!model.loadingInitial)
    }

    @Test func manyCallbacksFetchOnlyOnePage() async {
        var pages: [Int] = []
        let model = SourceListingViewModel(getPage: { _, page in
            pages.append(page)
            // Only pagination needs an overlap window; initial loading is awaited.
            if page == 2 { try await Task.sleep(nanoseconds: 30_000_000) }
            return result(["\(page)"])
        }, getBookmarks: { _ in [] })
        await model.reload(listing: listing)
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { await model.loadMore() } }
        }
        #expect(pages == [1, 2])
        #expect(!model.loadingMore)
    }

    @Test func lateBookmarksCannotAppendToDifferentListing() async {
        var pending: CheckedContinuation<Set<String>, Never>?
        let model = SourceListingViewModel(getPage: { listing, page in
            result(["\(listing.id)-\(page)"])
        }, getBookmarks: { entries in
            if entries.first?.key == "old-2" {
                return await withCheckedContinuation { pending = $0 }
            }
            return Set(entries.map(\.key))
        })
        await model.reload(listing: .init(id: "old", name: "Old"))
        let oldPage = Task { await model.loadMore() }
        while pending == nil { await Task.yield() }
        await model.reload(listing: .init(id: "new", name: "New"))
        pending?.resume(returning: ["old-2"])
        await oldPage.value
        #expect(model.entries.map(\.key) == ["new-1"])
        #expect(model.bookmarkedItems == ["new-1"])
        #expect(model.nextPage == 2)
        await model.loadMore()
        #expect(model.entries.map(\.key) == ["new-1", "new-2"])
    }

    @Test func failedPagePreservesPositionAndCanRetry() async {
        var fail = true
        var pages: [Int] = []
        let model = SourceListingViewModel(getPage: { _, page in
            pages.append(page)
            if page == 2 && fail { fail = false; throw URLError(.timedOut) }
            return result(["\(page)"], more: page == 1)
        }, getBookmarks: { _ in [] })
        await model.reload(listing: listing)
        await model.loadMore()
        #expect(model.error != nil)
        #expect(!model.loadingMore)
        #expect(model.entries.map(\.key) == ["1"])
        await model.loadMore()
        #expect(pages == [1, 2, 2])
        #expect(model.error == nil)
        #expect(model.entries.map(\.key) == ["1", "2"])
    }

    @Test func cancelledCustomLayoutCannotReplaceNewListing() async {
        var pending: CheckedContinuation<AidokuRunner.Home?, Never>?
        let model = SourceListingViewModel(getPage: { listing, _ in
            result([listing.id], more: false)
        }, getHome: { listing in
            if listing.id == "old" {
                return await withCheckedContinuation { pending = $0 }
            }
            return nil
        }, getBookmarks: { _ in [] })
        let oldLoad = Task { await model.reload(listing: .init(id: "old", name: "Old")) }
        while pending == nil { await Task.yield() }
        await model.reload(listing: listing)
        pending?.resume(returning: nil)
        await oldLoad.value
        #expect(model.entries.map(\.key) == ["test"])
        #expect(!model.loadingInitial)
        #expect(model.error == nil)
    }

    @Test func customLayoutDoesNotAlsoRequestMangaPages() async {
        var requests = 0
        let model = SourceListingViewModel(getPage: { _, _ in
            requests += 1
            return result([])
        }, getHome: { _ in .init(components: []) }, getBookmarks: { _ in [] })
        await model.reload(listing: listing)
        await model.loadMore()
        #expect(model.home != nil)
        #expect(!model.hasMore)
        #expect(requests == 0)
    }

    @Test func failedInitialListingRequestCanRetry() async {
        var requests = 0
        let model = SourceListingViewModel(getPage: { _, _ in
            requests += 1
            if requests == 1 { throw URLError(.timedOut) }
            return result(["ok"], more: false)
        }, getBookmarks: { _ in [] })
        await model.reload(listing: listing)
        #expect(model.error != nil)
        #expect(!model.loadingInitial)
        await model.loadMore()
        #expect(model.error == nil)
        #expect(model.entries.map(\.key) == ["ok"])
        #expect(requests == 2)
    }

    @Test func refreshStartsAtFirstPageAndClearsOldEntries() async {
        var pages: [Int] = []
        let model = SourceListingViewModel(getPage: { _, page in
            pages.append(page)
            return result(["\(page)"])
        }, getBookmarks: { _ in [] })
        await model.reload(listing: listing)
        await model.loadMore()
        await model.reload(listing: listing)
        #expect(pages == [1, 2, 1])
        #expect(model.entries.map(\.key) == ["1"])
    }

    @Test func searchInitialEmptyPageDoesNotStrandPagination() async {
        var pages: [Int] = []
        let model = SourceSearchViewModel(getPage: { _, page, _ in
            pages.append(page)
            return result(page == 1 ? [] : ["one", "one"], more: page == 1)
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "", filters: [])
        await model.waitForSearch()
        #expect(pages == [1, 2])
        #expect(model.entries.map(\.key) == ["one"])
        #expect(model.nextPage == 3)
    }

    @Test func submittingPendingGlobalQuerySkipsDebounce() async {
        let model = SearchContentView.ViewModel()
        model.search(query: "pagination-test", delay: true)
        model.search(query: "pagination-test", delay: false)
        // No sources: an explicitly submitted search must finish without the typing delay.
        await model.waitForSearch()
        #expect(!model.isLoading)
        model.removeHistory(item: "pagination-test")
    }

    @Test func cancelledGlobalSearchCannotClearNewLoadingState() async {
        let model = SearchContentView.ViewModel()
        model.search(query: "old", delay: true)
        model.search(query: "", delay: true)
        model.search(query: "new", delay: true)
        await Task.yield()
        #expect(model.isLoading)
        model.search(query: "", delay: true)
        await model.waitForSearch()
        #expect(!model.isLoading)
        #expect(model.results.isEmpty)
    }

    @Test func globalSearchPicksUpSourcesThatLoadAfterTheQuery() async {
        let model = SearchContentView.ViewModel()
        model.search(query: "late sources", delay: true)
        model.search(query: "late sources", delay: false)
        await model.waitForSearch()
        defer { model.removeHistory(item: "late sources") }

        func matchingSource() -> AidokuRunner.Source {
            .test(runner: TestableSourceRunner { _ in
                .init(entries: [.init(sourceKey: "test", key: "match", title: "Match")], hasNextPage: false)
            })
        }
        let source = matchingSource()
        model.updateSources([source])
        await model.waitForSearch()
        #expect(model.results.map(\.id) == [source.id])

        let replacement = matchingSource()
        model.updateSources([replacement])
        await model.waitForSearch()
        #expect(model.results.count == 1)
        #expect(model.results.first?.source === replacement)
        model.updateSources([])
        await model.waitForSearch()
        #expect(model.results.isEmpty)
    }

    @Test func hiddenGlobalSearchResumesOnlyUnfinishedSources() async throws {
        let probe = GlobalSearchProbe()
        let model = SearchContentView.ViewModel()
        model.updateSources(probe.sources(count: 8))
        let query = "partial-global-test"
        defer {
            probe.releaseAll()
            model.removeHistory(item: query)
        }
        model.search(query: query, delay: false)
        try await RegressionTestWait.until { probe.pending.count == 3 }
        probe.release("\(query)/s1")
        try await RegressionTestWait.until { model.results.map(\.id) == ["s1"] && probe.started.count == 4 }
        model.setSearchVisible(false)
        probe.releaseAll()
        try await RegressionTestWait.until { probe.active == 0 }
        #expect(probe.started.count == 4)
        #expect(!model.isLoading)
        model.setSearchVisible(true)
        await model.waitForSearch()
        #expect(model.results.first?.id == "s1")
        #expect(Set(model.results.map(\.id)).count == 8)
        #expect(probe.started.filter { $0 == "\(query)/s1" }.count == 1)
    }

    @Test func replacementSearchSharesThreeSlotsWithCancelledProviders() async throws {
        let probe = GlobalSearchProbe()
        let model = SearchContentView.ViewModel()
        model.updateSources(probe.sources(count: 8))
        let old = "slow-global-test", new = "new-global-test"
        defer {
            probe.releaseAll()
            for query in [old, new, "empty"] { model.removeHistory(item: query) }
        }
        model.search(query: old, delay: false)
        try await RegressionTestWait.until { probe.pending.count == 3 }
        model.search(query: new, delay: false)
        probe.release("\(old)/s0")
        try await RegressionTestWait.until { probe.started.contains { $0.hasPrefix("\(new)/") } }
        probe.releaseAll()
        await model.waitForSearch()
        #expect(probe.peak == 3)
        #expect(model.results.count == 8)
        #expect(model.results.allSatisfy { $0.links.first?.title == new })

        model.search(query: "empty", delay: false)
        await model.waitForSearch()
        let requests = probe.started.count
        #expect(model.results.isEmpty)
        model.updateFilters([])
        await model.waitForSearch()
        #expect(probe.started.count == requests)
    }
}

@MainActor private final class GlobalSearchProbe {
    private(set) var started: [String] = []
    private(set) var active = 0
    private(set) var peak = 0
    private(set) var pending: [String: CheckedContinuation<Void, Never>] = [:]
    private var holding = true

    func sources(count: Int) -> [AidokuRunner.Source] {
        (0..<count).map { index in
            let key = "s\(index)"
            return .init(key: key, name: key, version: 1, contentRating: .safe, runner: TestableSourceRunner { query in
                await self.page(source: key, query: query ?? "")
            })
        }
    }

    func release(_ key: String) {
        pending.removeValue(forKey: key)?.resume()
    }

    func releaseAll() {
        holding = false
        for key in Array(pending.keys) { release(key) }
    }

    private func page(source: String, query: String) async -> AidokuRunner.MangaPageResult {
        let key = "\(query)/\(source)"
        started.append(key)
        active += 1
        peak = max(peak, active)
        if holding {
            await withCheckedContinuation { pending[key] = $0 }
        }
        active -= 1
        let entries: [AidokuRunner.Manga] = query == "empty" ? [] : [.init(sourceKey: source, key: key, title: query)]
        return .init(entries: entries, hasNextPage: false)
    }
}
