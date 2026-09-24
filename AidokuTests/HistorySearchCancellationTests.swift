import Testing
@testable import Aidoku

@MainActor
struct HistorySearchCancellationTests {
    @Test func clearingBeforeDebounceDoesNotApplyTheAbandonedQuery() async throws {
        let model = HistoryView.ViewModel()
        await model.search(query: "abandoned", delay: true)
        await model.search(query: "", delay: false)
        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(model.searchQuery.isEmpty)
    }

    @Test func returningToAppliedQueryCancelsPendingReplacement() async throws {
        let model = HistoryView.ViewModel()
        await model.search(query: "original", delay: false)
        // Allow the immediate task to apply the first query.
        for _ in 0..<100 where model.searchQuery != "original" {
            await Task.yield()
        }
        #expect(model.searchQuery == "original")
        await model.search(query: "replacement", delay: true)
        await model.search(query: "original", delay: false)
        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(model.searchQuery == "original")
    }

    @Test func normalDebouncedSearchStillApplies() async throws {
        let model = HistoryView.ViewModel()
        await model.search(query: "latest", delay: true)
        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(model.searchQuery == "latest")
    }
}
