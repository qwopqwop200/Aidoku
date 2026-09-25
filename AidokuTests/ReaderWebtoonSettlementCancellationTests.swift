import AidokuRunner
import AsyncDisplayKit
import Testing
import UIKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderWebtoonSettlementCancellationTests {
    @Test(arguments: ["slider", "zoom", "auto"])
    func interruptingAnimatedMovementDoesNotLeaveInsertionBlocked(takeover: String) async throws {
        let defaults = UserDefaults.standard
        let previousAnimation = defaults.object(forKey: "Reader.animatePageTransitions")
        defaults.set(true, forKey: "Reader.animatePageTransitions")
        defer {
            if let previousAnimation { defaults.set(previousAnimation, forKey: "Reader.animatePageTransitions") }
            else { defaults.removeObject(forKey: "Reader.animatePageTransitions") }
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        defer { window.isHidden = true; window.rootViewController = nil; previousWindow?.makeKey() }
        let controller = ReaderWebtoonViewController(source: nil,
            manga: AidokuRunner.Manga(sourceKey: "test", key: "takeover", title: "Takeover"),
            temporaryPageStore: ReaderTemporaryPageStore())
        let first = AidokuRunner.Chapter(key: "first")
        let next = AidokuRunner.Chapter(key: "next")
        let owner = WebtoonCancellationOwner(next: next)
        controller.delegate = owner
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 900)).image {
            UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 390, height: 900))
        }
        controller.viewModel.preloadedChapter = first
        controller.viewModel.preloadedPages = (0..<5).map {
            var page = Page(sourceId: "test", chapterId: first.key, index: $0)
            page.image = image
            return page
        }
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.setChapter(first, startPage: 2)
        for _ in 0..<200 {
            if controller.scrollView.contentSize.height > 2000 { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(controller.scrollView.contentSize.height > 2000)
        try await Task.sleep(for: .milliseconds(100))
        controller.viewModel.preloadedChapter = next
        controller.viewModel.preloadedPages = [Page(sourceId: "test", chapterId: next.key, index: 0)]
        controller.moveRight()
        switch takeover {
        case "slider": controller.sliderMoved(value: 0.2)
        case "zoom": controller.scrollViewWillBeginZooming(controller.scrollView, with: nil)
        default: controller.toggleAutoScroll()
        }
        var completed = false
        let insertion = Task { await controller.appendNextChapter(); completed = true }
        try await Task.sleep(for: .milliseconds(40))
        #expect(!completed, "Takeover remains an active insertion barrier until it ends")
        switch takeover {
        case "slider": controller.sliderStopped(value: 0.2)
        case "zoom": controller.scrollViewDidEndZooming(controller.scrollView, with: nil, atScale: 1)
        default: controller.stopAutoScroll()
        }
        for _ in 0..<60 {
            if completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed, "Interrupted animation must not retain a phantom insertion barrier")
        #expect(controller.numberOfSections(in: controller.collectionNode) == 2)
        insertion.cancel()
        controller.cancelPendingChapterLoads()
        await insertion.value
    }

    @Test func appendingWithPendingAboveResizePreservesActualViewport() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let controller = ReaderWebtoonViewController(source: nil,
            manga: AidokuRunner.Manga(sourceKey: "test", key: "append-anchor", title: "Anchor"),
            temporaryPageStore: ReaderTemporaryPageStore())
        let first = AidokuRunner.Chapter(key: "first")
        let next = AidokuRunner.Chapter(key: "next")
        let owner = WebtoonCancellationOwner(next: next)
        controller.delegate = owner
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 900)).image {
            UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 390, height: 900))
        }
        controller.viewModel.preloadedChapter = first
        controller.viewModel.preloadedPages = (0..<5).map {
            var page = Page(sourceId: "test", chapterId: first.key, index: $0)
            page.image = image
            return page
        }
        window.rootViewController = controller; window.makeKeyAndVisible()
        controller.setChapter(first, startPage: 2)
        for _ in 0..<200 {
            if controller.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)) != nil { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        for item in 1...5 {
            let node = try #require(controller.collectionNode.nodeForItem(at: IndexPath(item: item, section: 0)) as? ReaderWebtoonPageNode)
            await node.loadPage()
        }
        try await Task.sleep(for: .milliseconds(400))
        controller.view.layoutIfNeeded()
        let layout = try #require(controller.collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout)
        let path = IndexPath(item: 2, section: 0)
        let frame = try #require(layout.layoutAttributesForItem(at: path)).frame
        controller.scrollView.setContentOffset(CGPoint(x: 0, y: frame.minY + 100), animated: false)
        controller.view.layoutIfNeeded()
        let before = controller.collectionNode.view.convert(frame, to: window).minY
        // Reproduce the real node-resize flag persisting until the next prepare.
        // The appended placeholder heights must not be treated as added above.
        layout.isInsertingCellsAbove = true
        controller.viewModel.preloadedChapter = next
        controller.viewModel.preloadedPages = (0..<5).map {
            Page(sourceId: "test", chapterId: next.key, index: $0)
        }
        let append = Task { await controller.appendNextChapter() }
        controller.scrollViewDidEndDecelerating(controller.scrollView)
        await append.value
        let afterFrame = try #require(layout.layoutAttributesForItem(at: path)).frame
        let after = controller.collectionNode.view.convert(afterFrame, to: window).minY
        #expect(controller.numberOfSections(in: controller.collectionNode) == 2)
        #expect(abs(after - before) < 1, "New below-viewport placeholders must not move existing visible content")
        #expect(abs(controller.collectionNode.contentOffset.y - controller.scrollView.contentOffset.y) < 1)
        controller.cancelPendingChapterLoads()
    }

    @Test func cancellingInsertionDoesNotNeedASettlementEvent() async throws {
        let controller = ReaderWebtoonViewController(source: nil,
            manga: AidokuRunner.Manga(sourceKey: "test", key: "cancel-wait", title: "Cancellation"),
            temporaryPageStore: ReaderTemporaryPageStore())
        let next = AidokuRunner.Chapter(key: "next")
        let owner = WebtoonCancellationOwner(next: next)
        controller.delegate = owner
        controller.loadViewIfNeeded()
        controller.viewModel.preloadedChapter = next
        controller.viewModel.preloadedPages = [Page(sourceId: "test", chapterId: next.key, index: 0)]
        controller.scrollViewWillBeginZooming(controller.scrollView, with: nil)
        var completed = false
        let task = Task { await controller.appendNextChapter(); completed = true }
        for _ in 0..<10 { await Task.yield() }
        #expect(!completed)
        task.cancel()
        for _ in 0..<40 {
            if completed { break }
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(completed, "Task cancellation must wake a suspended insertion without another gesture")
        #expect(controller.numberOfSections(in: controller.collectionNode) == 0)
        controller.cancelPendingChapterLoads()
        await task.value
    }
}

@MainActor private final class WebtoonCancellationOwner: ReaderHoldingDelegate {
    let next: AidokuRunner.Chapter
    init(next: AidokuRunner.Chapter) { self.next = next }
    var barsHidden: Bool { true }
    func hideBars() {}
    func getNextChapter() -> AidokuRunner.Chapter? { next }
    func getPreviousChapter() -> AidokuRunner.Chapter? { nil }
    func setChapter(_ chapter: AidokuRunner.Chapter) {}
    func setCurrentPage(_ page: Int, position: Double?) {}
    func setCurrentPages(_ pages: ClosedRange<Int>) {}
    func setPages(_ pages: [Aidoku.Page]) {}
    func displayPage(_ page: Int) {}
    func setSliderOffset(_ offset: CGFloat) {}
    func setCompleted() {}
}
