import AidokuRunner
import Foundation
import Testing
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderChapterHandoffTests {
    private func makeModel(_ gate: ChapterRequestGate, webtoon: Bool = false) -> ReaderPagedViewModel {
        let source = AidokuRunner.Source(url: nil, key: "handoff-\(UUID())", name: "Handoff", version: 1,
            languages: ["en"], contentRating: .safe, runner: ChapterRequestRunner(gate: gate))
        let manga = AidokuRunner.Manga(sourceKey: source.key, key: "book", title: "Book")
        return webtoon ? ReaderWebtoonViewModel(source: source, manga: manga) : ReaderPagedViewModel(source: source, manga: manga)
    }

    private func waitFor(_ condition: @escaping () async -> Bool) async throws {
        for _ in 0..<2_000 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await condition(), "Controlled source did not reach expected state")
    }

    @Test(arguments: [false, true])
    func transferredPreloadSurvivesOldConsumerCancellation(webtoon: Bool) async throws {
        let gate = ChapterRequestGate()
        let model = makeModel(gate, webtoon: webtoon)
        let chapter = AidokuRunner.Chapter(key: "a")
        let preload = Task { await model.preload(chapter: chapter) }
        defer { preload.cancel() }
        try await waitFor { await gate.active == 1 }
        let handoff = try #require(model.takePendingPreload(for: chapter))
        #expect(model.takePendingPreload(for: chapter) == nil)
        preload.cancel()
        let foreground = Task { await model.loadPages(chapter: chapter, handoff: handoff) }
        defer { foreground.cancel() }
        await gate.finish("a")
        await foreground.value
        #expect(await preload.value.isEmpty)
        #expect(await gate.starts == ["a"])
        #expect(await gate.cancellations == 0)
        #expect(model.pages.map(\.imageURL) == (1...3).map { "https://fixture.invalid/a/\($0).png" })
        #expect(model.preloadedChapter == nil)
        #expect(await gate.active == 0)
    }

    @Test func cancelledSpeculationDoesNotBecomeReusableFailure() async throws {
        let gate = ChapterRequestGate()
        let model = makeModel(gate)
        let chapter = AidokuRunner.Chapter(key: "a")
        let first = Task { await model.preload(chapter: chapter) }
        defer { first.cancel() }
        try await waitFor { await gate.active == 1 }
        first.cancel()
        #expect(await first.value.isEmpty)
        #expect(await gate.cancellations == 1)
        #expect(model.takePendingPreload(for: chapter) == nil)
        #expect(model.preloadedPages.isEmpty)
        let retry = Task { await model.preload(chapter: chapter) }
        defer { retry.cancel() }
        try await waitFor { await gate.starts.count == 2 }
        await gate.finish("a")
        #expect(await retry.value.count == 3)
        await model.loadPages(chapter: chapter)
        #expect(await gate.starts.count == 2, "Completed preload must still be reused")
        #expect(model.pages.count == 3)
    }

    @Test func foregroundCancellationCancelsTransferredSource() async throws {
        let gate = ChapterRequestGate()
        let model = makeModel(gate)
        let chapter = AidokuRunner.Chapter(key: "a")
        let preload = Task { await model.preload(chapter: chapter) }
        defer { preload.cancel() }
        try await waitFor { await gate.active == 1 }
        let handoff = try #require(model.takePendingPreload(for: chapter))
        preload.cancel()
        let foreground = Task { await model.loadPages(chapter: chapter, handoff: handoff) }
        defer { foreground.cancel() }
        try await waitFor { model.chapter == chapter }
        foreground.cancel()
        await foreground.value
        #expect(await preload.value.isEmpty)
        #expect(await gate.cancellations == 1)
        #expect(await gate.active == 0)
        #expect(model.pages.isEmpty)
    }

    @Test func droppedReservationCancelsWithoutLoading() async throws {
        let gate = ChapterRequestGate()
        let model = makeModel(gate)
        let chapter = AidokuRunner.Chapter(key: "a")
        let preload = Task { await model.preload(chapter: chapter) }
        defer { preload.cancel() }
        try await waitFor { await gate.active == 1 }
        var handoff: ReaderChapterPageHandoff? = try #require(model.takePendingPreload(for: chapter))
        preload.cancel()
        #expect(handoff != nil)
        handoff = nil
        #expect(await preload.value.isEmpty)
        #expect(await gate.cancellations == 1)
        #expect(await gate.active == 0)
    }

    @Test func oldTransferredResultCannotOverwriteNewChapter() async throws {
        let gate = ChapterRequestGate()
        let model = makeModel(gate)
        let a = AidokuRunner.Chapter(key: "a")
        let b = AidokuRunner.Chapter(key: "b")
        let preload = Task { await model.preload(chapter: a) }
        defer { preload.cancel() }
        try await waitFor { await gate.active == 1 }
        #expect(model.takePendingPreload(for: b) == nil)
        let handoff = try #require(model.takePendingPreload(for: a))
        preload.cancel()
        let first = Task { await model.loadPages(chapter: a, handoff: handoff) }
        defer { first.cancel() }
        try await waitFor { model.chapter == a }
        let second = Task { await model.loadPages(chapter: b) }
        defer { second.cancel() }
        try await waitFor { await gate.starts.count == 2 }
        await gate.finish("b")
        await second.value
        await gate.finish("a")
        await first.value
        _ = await preload.value
        #expect(model.chapter == b)
        #expect(model.pages.allSatisfy { $0.chapterId == "b" })
        #expect(model.pages.count == 3)
        #expect(await gate.starts == ["a", "b"])
        #expect(await gate.active == 0)
    }

    @Test func earlierPreloadCancellationCannotCancelLaterTransferredOne() async throws {
        let gate = ChapterRequestGate()
        let model = makeModel(gate)
        let a = AidokuRunner.Chapter(key: "a")
        let b = AidokuRunner.Chapter(key: "b")
        let first = Task { await model.preload(chapter: a) }
        defer { first.cancel() }
        try await waitFor { await gate.active == 1 }
        let second = Task { await model.preload(chapter: b) }
        defer { second.cancel() }
        try await waitFor { await gate.active == 2 }
        let handoff = try #require(model.takePendingPreload(for: b))
        first.cancel(); second.cancel()
        let foreground = Task { await model.loadPages(chapter: b, handoff: handoff) }
        defer { foreground.cancel() }
        #expect(await first.value.isEmpty)
        await gate.finish("b")
        await foreground.value
        _ = await second.value
        #expect(await gate.cancellations == 1)
        #expect(await gate.starts == ["a", "b"])
        #expect(await gate.maximumActive == 2)
        #expect(model.pages.count == 3)
        #expect(model.pages.allSatisfy { $0.chapterId == "b" })
    }

    @Test func transferredFailureCanBeRetried() async throws {
        let gate = ChapterRequestGate()
        let model = makeModel(gate)
        let chapter = AidokuRunner.Chapter(key: "a")
        let preload = Task { await model.preload(chapter: chapter) }
        defer { preload.cancel() }
        try await waitFor { await gate.active == 1 }
        let handoff = try #require(model.takePendingPreload(for: chapter))
        preload.cancel()
        let foreground = Task { await model.loadPages(chapter: chapter, handoff: handoff) }
        defer { foreground.cancel() }
        await gate.finish("a", fails: true)
        await foreground.value
        _ = await preload.value
        #expect(model.pages.isEmpty)
        let retry = Task { await model.loadPages(chapter: chapter) }
        defer { retry.cancel() }
        try await waitFor { await gate.starts.count == 2 }
        await gate.finish("a")
        await retry.value
        #expect(model.pages.count == 3)
    }
}

private final class ChapterRequestRunner: AidokuRunner.Runner {
    let features = AidokuRunner.SourceFeatures()
    let gate: ChapterRequestGate
    init(gate: ChapterRequestGate) { self.gate = gate }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga { manga }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        try await gate.load(chapter.key)
    }
}

private actor ChapterRequestGate {
    private struct Pending {
        let chapter: String
        let continuation: CheckedContinuation<[AidokuRunner.Page], Error>
    }
    private var pending: [UUID: Pending] = [:]
    private var cancelledBeforeRegistration = Set<UUID>()
    private(set) var starts: [String] = []
    private(set) var cancellations = 0
    private(set) var maximumActive = 0
    var active: Int { pending.count }
    func load(_ chapter: String) async throws -> [AidokuRunner.Page] {
        let id = UUID()
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await withCheckedThrowingContinuation { continuation in
                if cancelledBeforeRegistration.remove(id) != nil || Task.isCancelled {
                    continuation.resume(throwing: CancellationError())
                    return
                }
                starts.append(chapter)
                pending[id] = Pending(chapter: chapter, continuation: continuation)
                maximumActive = max(maximumActive, pending.count)
            }
        } onCancel: {
            Task { await self.cancel(id) }
        }
    }
    private func cancel(_ id: UUID) {
        if let request = pending.removeValue(forKey: id) {
            cancellations += 1
            request.continuation.resume(throwing: CancellationError())
        } else { cancelledBeforeRegistration.insert(id) }
    }
    func finish(_ chapter: String, fails: Bool = false) {
        for id in pending.filter({ $0.value.chapter == chapter }).map(\.key) {
            guard let request = pending.removeValue(forKey: id) else { continue }
            if fails { request.continuation.resume(throwing: URLError(.badServerResponse)) }
            else {
                request.continuation.resume(returning: (1...3).map {
                    .init(content: .url(url: URL(string: "https://fixture.invalid/\(chapter)/\($0).png")!))
                })
            }
        }
    }
}
