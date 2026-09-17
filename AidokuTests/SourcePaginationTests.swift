import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@MainActor
struct SourcePaginationTests {
    private func result(_ keys: [String], more: Bool = true) -> AidokuRunner.MangaPageResult {
        .init(entries: keys.map { .init(sourceKey: "test", key: $0, title: $0) }, hasNextPage: more)
    }

    @Test func failedReplacementSearchClearsPreviousResultsAndCanRetry() async {
        var fail = true
        let model = SourceSearchViewModel(getPage: { query, _, _ in
            if query == "new" && fail { throw URLError(.timedOut) }
            return result([query], more: false)
        }, getBookmarks: { entries in Set(entries.map(\.key)) })
        model.loadManga(searchText: "old", filters: [])
        await model.waitForSearch()
        #expect(model.entries.map(\.key) == ["old"])
        model.loadManga(searchText: "new", filters: [])
        await model.waitForSearch()
        #expect(model.entries.isEmpty)
        #expect(model.bookmarkedItems.isEmpty)
        #expect(model.error != nil)
        #expect(!model.hasMore)
        fail = false
        model.loadManga(searchText: "new", filters: [], force: true)
        await model.waitForSearch()
        #expect(model.entries.map(\.key) == ["new"])
        #expect(model.error == nil)
    }

    @Test func concurrentTriggersShareOneRequest() async {
        var pages: [Int] = []
        let model = SourceSearchViewModel(getPage: { _, page, _ in
            pages.append(page)
            try await Task.sleep(nanoseconds: 30_000_000)
            return result(["\(page)"])
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "", filters: [])
        await model.waitForSearch()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 {
                group.addTask { await model.loadMore(searchText: "", filters: []) }
            }
        }
        #expect(pages == [1, 2])
        #expect(model.entries.map(\.key) == ["1", "2"])
        #expect(model.nextPage == 3)
    }

    @Test func skipsEmptyAndDuplicatePagesWithoutDeadlock() async {
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

    @Test func cancelledPageCannotOverwriteNewSearch() async {
        var started = false
        let model = SourceSearchViewModel(getPage: { query, page, _ in
            if query == "old" && page == 2 {
                started = true
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            return result(["\(query)-\(page)"])
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "old", filters: [])
        await model.waitForSearch()
        let pending = Task { await model.loadMore(searchText: "old", filters: []) }
        while !started { await Task.yield() }
        model.loadManga(searchText: "new", filters: [])
        await model.waitForSearch()
        await pending.value
        #expect(model.entries.map(\.key) == ["new-1"])
        #expect(model.error == nil)
        await model.loadMore(searchText: "new", filters: [])
        #expect(model.entries.map(\.key) == ["new-1", "new-2"])
    }

    @Test func failedPageRetriesSamePageAndKeepsEntries() async {
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
        #expect(model.nextPage == 2)
        #expect(model.error != nil)
        await model.loadMore(searchText: "", filters: [])
        #expect(pages == [1, 2, 2])
        #expect(model.error == nil)
        #expect(model.entries.map(\.key) == ["1", "2"])
    }

    @Test func submitStartsPendingSearchAndDoesNotRestartInFlightRequest() async {
        var requests = 0
        var finish: CheckedContinuation<Void, Never>?
        let model = SourceSearchViewModel(getPage: { _, _, _ in
            requests += 1
            await withCheckedContinuation { finish = $0 }
            return result(["match"], more: false)
        }, getBookmarks: { _ in [] })
        model.loadManga(searchText: "artist:example", filters: [], delay: true)
        model.loadManga(searchText: "artist:example", filters: [])
        // A submit must skip debounce, and repeated submits must share the request.
        for _ in 0..<100 {
            if requests > 0 { break }
            await Task.yield()
        }
        #expect(requests == 1)
        model.loadManga(searchText: "artist:example", filters: [])
        await Task.yield()
        #expect(requests == 1)
        finish?.resume()
        await model.waitForSearch()
        #expect(model.entries.map(\.key) == ["match"])
    }

}
