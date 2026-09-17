import Foundation
import Testing
@testable import Aidoku

@MainActor
struct LegacySourcePaginationTests {
    @Test func overlappingLegacyCallbacksDoNotDuplicatePage() async throws {
        var calls: [Int] = []
        let model = SourceViewModel(pageLoader: { @MainActor page in
            calls.append(page)
            try await Task.sleep(nanoseconds: 30_000_000)
            return .init(manga: [], hasNextPage: true)
        })
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<12 { group.addTask { await model.loadNextMangaPage() } }
        }
        #expect(calls == [1])
        #expect(await model.currentPage == 1)
    }

    @Test func failedLegacyPageCanBeRetriedWithoutSkipping() async throws {
        var calls: [Int] = []
        let model = SourceViewModel(pageLoader: { @MainActor page in
            calls.append(page)
            if calls.count == 1 { throw URLError(.timedOut) }
            return .init(manga: [], hasNextPage: false)
        })
        await model.loadNextMangaPage()
        #expect(await model.currentPage == nil)
        #expect(await model.hasMore)
        await model.loadNextMangaPage()
        #expect(calls == [1, 1])
        #expect(await model.currentPage == 1)
        #expect(await !model.hasMore)
    }

    @Test func refreshRejectsLegacyResponseAlreadyInFlight() async throws {
        var pending: CheckedContinuation<MangaPageResult, Never>?
        var calls = 0
        let model = SourceViewModel(pageLoader: { @MainActor _ in
            calls += 1
            if calls == 1 { return await withCheckedContinuation { pending = $0 } }
            return .init(manga: [], hasNextPage: true)
        })
        let oldRequest = Task { await model.loadNextMangaPage() }
        while pending == nil { await Task.yield() }
        await model.setCurrentPage(nil)
        await model.loadNextMangaPage()
        pending?.resume(returning: .init(manga: [], hasNextPage: false))
        await oldRequest.value
        #expect(await model.hasMore)
        #expect(await model.currentPage == 1)
    }
}
