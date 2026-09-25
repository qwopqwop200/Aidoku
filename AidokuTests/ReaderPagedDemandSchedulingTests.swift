import AidokuRunner
import Nuke
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderPagedDemandSchedulingTests {
    @Test func zeroLookaheadStillLoadsDestinationAndReleasesDistantPages() throws {
        try withReader(preload: 0) { reader, pager in
            let controllers = reader.pageViewControllers
            pager.setViewControllers([controllers[2]], direction: .forward, animated: false)
            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
            #expect(reader.currentPage == 2)
            #expect(controllers[2].page?.index == 1)

            pager.setViewControllers([controllers[40]], direction: .forward, animated: false)
            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [controllers[2]], transitionCompleted: true)
            #expect(reader.currentPage == 40)
            #expect(controllers[40].page?.index == 39)
            #expect(controllers[2].page == nil)
            #expect(controllers[41].page == nil)
        }
    }

    @Test func incomingDragPromotesImageRequestAndCancellationRestoresPriority() throws {
        try withReader(preload: 3) { reader, pager in
            let controllers = reader.pageViewControllers
            pager.setViewControllers([controllers[10]], direction: .forward, animated: false)
            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
            #expect(controllers[11].pageView?.imageLoadPriority == .low)

            reader.pageViewController(pager, willTransitionTo: [controllers[11]])
            #expect(controllers[11].pageView?.imageLoadPriority == .high)
            #expect(controllers[10].pageView?.imageLoadPriority == .high)

            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
            #expect(reader.currentPage == 10)
            #expect(controllers[11].pageView?.imageLoadPriority == .low)
            #expect(controllers[10].pageView?.imageLoadPriority == .high)
        }
    }

    @Test func cancelledChapterPreviewDragPreservesPreviewWithZeroLookahead() throws {
        try withReader(preload: 0, adjacentChapters: true) { reader, pager in
            let controllers = reader.pageViewControllers
            // One previous preview shifts content pages by one controller slot.
            pager.setViewControllers([controllers[51]], direction: .forward, animated: false)
            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
            let nextPreview = controllers[53]
            nextPreview.setPage(Page(sourceId: "demand-tests", chapterId: "next", index: 0))
            pager.setViewControllers([controllers[52]], direction: .forward, animated: false)
            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
            reader.pageViewController(pager, willTransitionTo: [nextPreview])
            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
            #expect(nextPreview.page?.chapterId == "next")
            #expect(reader.currentPage == 50)

            let previousPreview = controllers[0]
            previousPreview.setPage(Page(sourceId: "demand-tests", chapterId: "previous", index: 10))
            pager.setViewControllers([controllers[1]], direction: .reverse, animated: false)
            reader.pageViewController(pager, willTransitionTo: [previousPreview])
            reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: false)
            #expect(previousPreview.page?.chapterId == "previous")
        }
    }

    @Test(arguments: [false, true])
    func sustainedReversalMovesBoundedWindowWithoutSingleStepJitter(doublePages: Bool) throws {
        try withReader(preload: 3, doublePages: doublePages) { reader, pager in
            let controllers = reader.pageViewControllers
            func settle(_ page: Int) {
                pager.setViewControllers([controllers[page]], direction: .forward, animated: false)
                reader.pageViewController(pager, didFinishAnimating: true, previousViewControllers: [], transitionCompleted: true)
            }
            func loaded() -> [Int] { controllers.enumerated().filter { $0.element.page != nil }.map(\.offset) }
            let step = doublePages ? 2 : 1
            let margin = doublePages ? 1 : 0
            settle(40)
            settle(40 - step)
            #expect(loaded() == Array((39 - step - margin)...(43 - step + margin)))
            settle(40) // a quick reread resets the opposite-step streak
            settle(40 - step)
            #expect(loaded() == Array((39 - step - margin)...(43 - step + margin)))
            settle(40 - 2 * step)
            let anchor = 40 - 2 * step
            #expect(loaded() == Array((anchor - 3 - margin)...(anchor + 1 + margin)))
            settle(10) // a large reverse jump immediately uses the destination
            #expect(loaded() == Array((7 - margin)...(11 + margin)))
            settle(30) // a large forward jump immediately changes direction
            #expect(loaded() == Array((29 - margin)...(33 + margin)))
        }
    }

    private func withReader(
        preload: Int,
        adjacentChapters: Bool = false,
        doublePages: Bool = false,
        _ body: (ReaderPagedViewController, UIPageViewController) throws -> Void
    ) throws {
        let defaults = UserDefaults.standard
        let settings: [String: Any] = ["Reader.pagesToPreload": preload, "Reader.pagedPageLayout": doublePages ? "double" : "single",
            "Reader.splitWideImages": false, "Reader.translation.automatic": false,
            "Reader.liveText": false, "Dictionary.enable": false, "Reader.upscaleImages": false]
        let saved = settings.keys.reduce(into: [String: Any]()) { result, key in result[key] = defaults.object(forKey: key) }
        settings.forEach { defaults.set($0.value, forKey: $0.key) }
        defer {
            for key in settings.keys {
                if let value = saved[key] { defaults.set(value, forKey: key) }
                else { defaults.removeObject(forKey: key) }
            }
        }
        let reader = ReaderPagedViewController(source: nil,
            manga: .init(sourceKey: "demand-tests", key: "book", title: "Book"),
            temporaryPageStore: ReaderTemporaryPageStore())
        let delegate = PagedDemandChapterDelegate()
        if adjacentChapters { reader.delegate = delegate }
        let chapter = AidokuRunner.Chapter(key: "chapter")
        reader.chapter = chapter
        reader.viewModel.pages = (0..<50).map { Page(sourceId: "demand-tests", chapterId: "chapter", index: $0) }
        reader.loadViewIfNeeded()
        reader.loadPageControllers(chapter: chapter)
        let pager = try #require(reader.children.compactMap { $0 as? UIPageViewController }.first)
        defer { reader.pageViewControllers.forEach { $0.clearPage() } }
        try withExtendedLifetime(delegate) { try body(reader, pager) }
    }
}

@MainActor private final class PagedDemandChapterDelegate: ReaderHoldingDelegate {
    let barsHidden = true
    func hideBars() {}
    func getNextChapter() -> AidokuRunner.Chapter? { .init(key: "next") }
    func getPreviousChapter() -> AidokuRunner.Chapter? { .init(key: "previous") }
    func setChapter(_ chapter: AidokuRunner.Chapter) {}
    func setCurrentPage(_ page: Int, position: Double?) {}
    func setCurrentPages(_ pages: ClosedRange<Int>) {}
    func setPages(_ pages: [Aidoku.Page]) {}
    func displayPage(_ page: Int) {}
    func setSliderOffset(_ offset: CGFloat) {}
    func setCompleted() {}
}
