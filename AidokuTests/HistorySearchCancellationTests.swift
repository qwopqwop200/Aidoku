import Testing
@testable import Aidoku

@MainActor
struct HistorySearchCancellationTests {
    private func waitForQuery(_ query: String, in model: HistoryView.ViewModel) async throws {
        let deadline = ContinuousClock.now + .seconds(3)
        while model.searchQuery != query {
            try #require(ContinuousClock.now < deadline, "Timed out waiting for search query")
            try await Task.sleep(for: .milliseconds(1))
        }
    }

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
        try await waitForQuery("original", in: model)
        #expect(model.searchQuery == "original")
        await model.search(query: "replacement", delay: true)
        await model.search(query: "original", delay: false)
        try await Task.sleep(nanoseconds: 650_000_000)
        #expect(model.searchQuery == "original")
    }

    @Test func normalDebouncedSearchStillApplies() async throws {
        let model = HistoryView.ViewModel()
        await model.search(query: "latest", delay: true)
        try await waitForQuery("latest", in: model)
        #expect(model.searchQuery == "latest")
    }
}
