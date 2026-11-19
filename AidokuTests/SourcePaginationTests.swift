import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct SourcePaginationTests {
    private let listing = AidokuRunner.Listing(id: "test", name: "Test")
    private func result(_ keys: [String], more: Bool = true) -> AidokuRunner.MangaPageResult {
        .init(entries: keys.map { .init(sourceKey: "test", key: $0, title: $0) }, hasNextPage: more)
    }

    @Test func searchSkipsEmptyAndDuplicatePagesWithoutDeadlock() async {
        var pages: [Int] = []
        let model = SourceSearchViewModel(getPage: { _, page, _ in
            pages.append(page)
            switch page {
            case 1, 3: return result(["first"])
            case 2: return result([])
            default: return result(["last"], more: false)
            }
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "", filters: [])
        await model.waitForSearch()
        await model.loadMore(searchText: "", filters: [])
        await model.loadMore(searchText: "", filters: [])
        #expect(pages == [1, 2, 3, 4])
        #expect(model.entries.map(\.key) == ["first", "last"])
        #expect(!model.hasMore)
    }

    @Test func searchFailedPageRetriesSamePageAndKeepsEntries() async {
        var pages: [Int] = []
        var fail = true
        let model = SourceSearchViewModel(getPage: { _, page, _ in
            pages.append(page)
            if page == 2 && fail {
                fail = false
                throw URLError(.timedOut)
            }
            return result(["\(page)"], more: page < 2)
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "", filters: [])
        await model.waitForSearch()
        await model.loadMore(searchText: "", filters: [])
        #expect(model.entries.map(\.key) == ["1"])
        #expect(model.error != nil)
        await model.loadMore(searchText: "", filters: [])
        #expect(pages == [1, 2, 2])
        #expect(model.error == nil)
        #expect(model.entries.map(\.key) == ["1", "2"])
    }

    @Test func searchCancelledPageCannotOverwriteNewSearch() async {
        var finishOldPage: CheckedContinuation<Void, Never>?
        let model = SourceSearchViewModel(getPage: { query, page, _ in
            if query == "old" && page == 2 {
                await withCheckedContinuation { finishOldPage = $0 }
            }
            return result(["\(query)-\(page)"])
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "old", filters: [])
        await model.waitForSearch()
        let pending = Task { await model.loadMore(searchText: "old", filters: []) }
        while finishOldPage == nil { await Task.yield() }
        model.loadManga(searchText: "new", filters: [])
        await model.waitForSearch()
        finishOldPage?.resume()
        await pending.value
        #expect(model.entries.map(\.key) == ["new-1"])
    }

    @Test func listingInitialEmptyPagesAndDuplicateEntriesAdvance() async {
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

    @Test func listingFailedPagePreservesPositionAndCanRetry() async {
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
        #expect(model.entries.map(\.key) == ["1"])
        await model.loadMore()
        #expect(pages == [1, 2, 2])
        #expect(model.error == nil)
        #expect(model.entries.map(\.key) == ["1", "2"])
    }
}
