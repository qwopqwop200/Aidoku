import AidokuRunner
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTextProgressRestorationTests {
    @Test func oldHistoryResponseCannotMoveNewChapter() async throws {
        let gate = ProgressGate()
        let reader = ReaderPagedTextViewController(source: nil,
            manga: .init(sourceKey: "test", key: "book", title: "Book"),
            readingProgressLoader: { _ in await gate.load() })
        reader.loadViewIfNeeded()
        reader.view.frame = CGRect(x: 0, y: 0, width: 390, height: 800)
        let first = AidokuRunner.Chapter(key: "first")
        let second = AidokuRunner.Chapter(key: "second")
        setCachedChapter(first, on: reader, startPage: 2)
        for _ in 0..<2_000 {
            if await gate.isWaiting { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try #require(await gate.isWaiting)
        setCachedChapter(second, on: reader, startPage: 0)
        #expect(reader.chapter?.key == "second")
        #expect(visiblePage(on: reader) == 0)
        await gate.finish(progress: 1)
        // Drain the MainActor continuation of the old database request.
        for _ in 0..<100 { await Task.yield() }
        #expect(reader.chapter?.key == "second")
        #expect(visiblePage(on: reader) == 0)
    }

    private func setCachedChapter(_ chapter: AidokuRunner.Chapter,
                                  on reader: ReaderPagedTextViewController, startPage: Int) {
        var page = Page(sourceId: "test", chapterId: chapter.key, index: 0)
        page.text = String(repeating: "A complete sentence fills this reader page. ", count: 150)
        reader.viewModel.chapter = chapter
        reader.viewModel.pages = [page]
        reader.setChapter(chapter, startPage: startPage)
    }

    private func visiblePage(on reader: ReaderPagedTextViewController) -> Int? {
        let controller = reader.children.compactMap { $0 as? UIPageViewController }.first
        if let single = controller?.viewControllers?.first as? TextSinglePageViewController { return single.page.id }
        return (controller?.viewControllers?.first as? TextDoublePageViewController)?.leftPage.id
    }
}

private actor ProgressGate {
    private var continuation: CheckedContinuation<CGFloat?, Never>?
    var isWaiting: Bool { continuation != nil }
    func load() async -> CGFloat? {
        await withCheckedContinuation { continuation = $0 }
    }
    func finish(progress: CGFloat) {
        continuation?.resume(returning: progress)
        continuation = nil
    }
}
