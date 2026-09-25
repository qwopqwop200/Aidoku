import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct LibraryFollowupWorkTests {
    @Test func refreshMetadataRetainsNoCompletedChapterArrays() {
        let chapters = (0..<1_000).map { AidokuRunner.Chapter(key: "chapter-\($0)") }
        var responses: [AidokuRunner.Manga] = []
        for index in 0..<100 {
            var response = AidokuRunner.Manga(sourceKey: "refresh-fixture", key: "manga-\(index)", title: "Title \(index)")
            response.chapters = chapters
            responses.append(response)
        }
        let retained = responses.map(MangaManager.compactRefreshMetadata)
        #expect(responses.reduce(0) { $0 + ($1.chapters?.count ?? 0) } == 100_000)
        #expect(retained.reduce(0) { $0 + ($1.chapters?.count ?? 0) } == 0)
        #expect(retained.map(\.identifier) == responses.map(\.identifier))
        #expect(retained.map(\.title) == responses.map(\.title))
        #expect(responses.allSatisfy { $0.chapters?.count == 1_000 })
    }

    @Test func updatesDeletionRecoveryAndPaginationShareOneOperationOwner() async throws {
        let owner = MangaUpdatesOperationQueue()
        let gate = UpdatesTurnGate()
        var order: [String] = []
        var active = 0
        var maximumActive = 0
        let page = Task {
            await owner.run {
                active += 1; maximumActive = max(maximumActive, active)
                order.append("page-start")
                await gate.wait()
                order.append("page-end")
                active -= 1
            }
        }
        try await waitUntil { gate.started }
        var entered = 0
        let failedDelete = Task {
            entered += 1
            await owner.run {
                active += 1; maximumActive = max(maximumActive, active)
                order.append("delete-failed")
                await Task.yield() // recovery belongs to this same owned turn
                order.append("recovery-end")
                active -= 1
            }
        }
        try await waitUntil { entered == 1 }
        let nextPage = Task {
            entered += 1
            await owner.run {
                active += 1; maximumActive = max(maximumActive, active)
                order.append("next-page")
                active -= 1
            }
        }
        try await waitUntil { entered == 2 }
        #expect(order == ["page-start"])
        gate.release()
        await page.value
        await failedDelete.value
        await nextPage.value
        #expect(order == ["page-start", "page-end", "delete-failed", "recovery-end", "next-page"])
        #expect(maximumActive == 1)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        for _ in 0..<2_000 {
            if condition() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw FixtureTimeout()
    }
    private struct FixtureTimeout: Error {}
}

@MainActor
private final class UpdatesTurnGate {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { started = true; await withCheckedContinuation { continuation = $0 } }
    func release() { continuation?.resume(); continuation = nil }
}
