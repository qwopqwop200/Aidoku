import AidokuRunner
import Foundation
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTextNavigationRecoveryTests {
    @Test(arguments: [false, true])
    func obsoleteAdjacentChapterCannotOverrideExplicitSelection(previous: Bool) async throws {
        let gate = TextNavigationGate()
        defer { Task { await gate.release() } }
        let source = makeSource(gate)
        let manga = AidokuRunner.Manga(sourceKey: source.key, key: "book", title: "Book")
        let reader = ReaderPagedTextViewController(source: source, manga: manga)
        let spy = TextRecoveryDelegate()
        reader.delegate = spy
        reader.loadViewIfNeeded(); reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        await reader.loadChapter(.init(key: "origin"), startPage: 0)
        if previous { reader.loadPreviousChapter() } else { reader.loadNextChapter() }
        try await wait { await gate.waiting }
        await reader.loadChapter(.init(key: "explicit"), startPage: 0)
        #expect(reader.chapter?.key == "explicit")
        await gate.release()
        try await wait { await gate.completed }
        for _ in 0..<100 { await Task.yield() }
        #expect(reader.chapter?.key == "explicit")
        #expect(spy.chapterSelections.isEmpty, "Old adjacent load must not select a chapter after explicit navigation")
        #expect(reader.viewModel.pages.first?.text?.contains("explicit") == true)
    }

    @Test(arguments: [1e100, -1e100, 0.0, 1.0])
    func finiteImportedProgressRestoresWithinNormalizedDomain(value: Double) async throws {
        let source = makeSource(TextNavigationGate())
        let spy = TextRecoveryDelegate()
        let reader = ReaderTextViewController(source: source,
            manga: .init(sourceKey: source.key, key: "scroll", title: "Scroll"),
            readingProgressLoader: { _ in CGFloat(value) })
        reader.delegate = spy
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let old = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = reader; window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; old?.makeKey() }
        reader.loadViewIfNeeded(); reader.view.layoutIfNeeded()
        await reader.loadInitialChapter(.init(key: "scroll"), restorePosition: true)
        try await wait { spy.lastPosition != nil }
        #expect(spy.lastPosition == min(1, max(0, value)))
        #expect((spy.lastPage ?? 0) >= 1)
        #expect((spy.lastPage ?? Int.max) <= spy.pageCount)
    }

    private func makeSource(_ gate: TextNavigationGate) -> AidokuRunner.Source {
        .init(url: nil, key: "text-recovery-\(UUID())", name: "Text recovery", version: 1,
            languages: ["en"], contentRating: .safe, runner: TextRecoveryRunner(gate: gate))
    }
    private func wait(_ predicate: @escaping () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        try #require(await predicate(), "Controlled operation failed to reach its expected state")
    }
}

private actor TextNavigationGate {
    private var pending: CheckedContinuation<Void, Never>?
    var waiting: Bool { pending != nil }
    private(set) var completed = false
    func load() async { await withCheckedContinuation { pending = $0 }; completed = true }
    func release() { pending?.resume(); pending = nil }
}
private final class TextRecoveryRunner: AidokuRunner.Runner {
    let features = AidokuRunner.SourceFeatures()
    let gate: TextNavigationGate
    init(gate: TextNavigationGate) { self.gate = gate }
    func getSearchMangaList(query: String?, page: Int, filters: [AidokuRunner.FilterValue]) async throws -> AidokuRunner.MangaPageResult {
        .init(entries: [], hasNextPage: false)
    }
    func getMangaUpdate(manga: AidokuRunner.Manga, needsDetails: Bool, needsChapters: Bool) async throws -> AidokuRunner.Manga { manga }
    func getPageList(manga: AidokuRunner.Manga, chapter: AidokuRunner.Chapter) async throws -> [AidokuRunner.Page] {
        if chapter.key == "adjacent" { await gate.load() }
        return [.init(content: .text(String(repeating: "\(chapter.key) A complete sentence fills this reader page. ", count: 150)))]
    }
}
@MainActor private final class TextRecoveryDelegate: ReaderHoldingDelegate {
    let barsHidden = false
    var chapterSelections: [String] = []
    var lastPosition: Double?
    var lastPage: Int?
    var pageCount = 0
    func hideBars() {}
    func getNextChapter() -> AidokuRunner.Chapter? { .init(key: "adjacent") }
    func getPreviousChapter() -> AidokuRunner.Chapter? { .init(key: "adjacent") }
    func setChapter(_ chapter: AidokuRunner.Chapter) { chapterSelections.append(chapter.key) }
    func setCurrentPage(_ page: Int, position: Double?) { lastPage = page; if let position { lastPosition = position } }
    func setCurrentPages(_ pages: ClosedRange<Int>) {}
    func setPages(_ pages: [Aidoku.Page]) { pageCount = pages.count }
    func displayPage(_ page: Int) {}
    func setSliderOffset(_ offset: CGFloat) {}
    func setCompleted() {}
}
