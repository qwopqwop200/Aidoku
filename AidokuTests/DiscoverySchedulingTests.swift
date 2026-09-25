import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct DiscoverySchedulingTests {
    @Test func migrationCancellationStopsBeforeNextSourceEvenWhenFirstIgnoresIt() async throws {
        let first = DiscoveryRunner(mode: .suspended)
        let second = DiscoveryRunner(mode: .match)
        let sources = [source(first, key: "first"), source(second, key: "second")]
        let task = Task { await MigrationMatchSearch.firstMatch(for: manga, sources: sources) }
        try await wait { await first.searchCount == 1 }
        task.cancel()
        await first.release()
        #expect(await task.value == nil)
        #expect(await second.searchCount == 0)
    }

    @Test func ordinaryMigrationFailureStillFallsBackButCancellationErrorDoesNot() async {
        let next = DiscoveryRunner(mode: .match)
        let failed = DiscoveryRunner(mode: .failure)
        let matched = await MigrationMatchSearch.firstMatch(for: manga, sources: [source(failed), source(next)])
        #expect(matched?.key == "matched")
        #expect(await next.searchCount == 1)
        let cancelled = DiscoveryRunner(mode: .cancelled)
        let unused = DiscoveryRunner(mode: .match)
        #expect(await MigrationMatchSearch.firstMatch(for: manga, sources: [source(cancelled), source(unused)]) == nil)
        #expect(await unused.searchCount == 0)
    }

    @Test(arguments: [false, true])
    func obsoleteGridPreparationDoesNotEnterSourceModifier(reuse: Bool) async throws {
        let gate = DiscoveryResolutionGate()
        let runner = DiscoveryRunner(mode: .match)
        let source = source(runner)
        let cell = MangaGridCell(frame: CGRect(x: 0, y: 0, width: 100, height: 150))
        cell.identifier = manga.identifier
        cell.resolveImageSource = { _ in await gate.wait(); return source }
        cell.startImageLoad(url: URL(string: "https://discovery.invalid/old"))
        try await wait { await gate.started }
        let pending = try #require(cell.preparationTask)
        if reuse { cell.prepareForReuse() } else { cell.startImageLoad(url: nil) }
        await gate.release()
        try await wait { await gate.finished }
        await pending.value
        #expect(await runner.imageCount == 0)
    }

    @Test(arguments: [false, true])
    func obsoleteListPreparationDoesNotEnterSourceModifier(reuse: Bool) async throws {
        let gate = DiscoveryResolutionGate()
        let runner = DiscoveryRunner(mode: .match)
        let source = source(runner)
        let cell = MangaListCell(frame: CGRect(x: 0, y: 0, width: 100, height: 150))
        cell.resolveImageSource = { _ in await gate.wait(); return source }
        var entry = manga
        entry.cover = "https://discovery.invalid/old"
        cell.configure(with: entry)
        try await wait { await gate.started }
        let pending = try #require(cell.preparationTask)
        if reuse { cell.prepareForReuse() } else { cell.startImageLoad(url: nil) }
        await gate.release()
        try await wait { await gate.finished }
        await pending.value
        #expect(await runner.imageCount == 0)
    }

    private var manga: AidokuRunner.Manga { .init(sourceKey: "fixture", key: "input", title: "Fixture") }
    private func source(_ runner: DiscoveryRunner, key: String = "fixture") -> AidokuRunner.Source {
        .init(key: key, name: "Fixture", version: 1, contentRating: .safe, runner: runner)
    }
    private func wait(_ condition: () async -> Bool) async throws {
        for _ in 0..<300 {
            if await condition() { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(await condition())
    }
}

private actor DiscoveryResolutionGate {
    var started = false
    var finished = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
        finished = true
    }
    func release() { continuation?.resume(); continuation = nil }
}

private actor DiscoveryRunner: AidokuRunner.Runner {
    enum Mode { case suspended, match, failure, cancelled }
    enum FixtureError: Error { case unavailable }
    nonisolated let features = SourceFeatures(providesImageRequests: true)
    let mode: Mode
    var searchCount = 0
    var imageCount = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(mode: Mode) { self.mode = mode }
    func release() { continuation?.resume(); continuation = nil }
    func getSearchMangaList(query: String?, page: Int, filters: [FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        searchCount += 1
        switch mode {
        case .suspended: await withCheckedContinuation { continuation = $0 }; return .init(entries: [], hasNextPage: false)
        case .match: return .init(entries: [.init(sourceKey: "fixture", key: "matched", title: "Matched")], hasNextPage: false)
        case .failure: throw FixtureError.unavailable
        case .cancelled: throw CancellationError()
        }
    }
    func getImageRequest(url: String, context: PageContext?) async throws -> URLRequest {
        imageCount += 1
        return URLRequest(url: URL(string: url)!)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga { manga }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] { [] }
}
