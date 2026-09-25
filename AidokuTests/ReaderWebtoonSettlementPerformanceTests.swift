import AidokuRunner
import AsyncDisplayKit
import Testing
import UIKit
@testable import Aidoku

/// Baseline-compatible real controller replay. Latency is recorded, never asserted
/// as a baseline invariant. Run alone on a dedicated simulator in both revisions.
@Suite(.serialized) @MainActor
struct ReaderWebtoonSettlementPerformanceTests {
    @Test func settlementToChapterInsertion() async throws {
        let defaults = UserDefaults.standard
        let keys = ["Reader.verticalInfiniteScroll", "Reader.liveText", "Dictionary.enable", "Reader.animatePageTransitions"]
        let saved = keys.map { defaults.object(forKey: $0) }
        defaults.set(true, forKey: keys[0])
        keys.dropFirst().forEach { defaults.set(false, forKey: $0) }
        defer {
            for (key, value) in zip(keys, saved) {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 900), format: format).image {
            UIColor.white.setFill(); $0.fill(CGRect(x: 0, y: 0, width: 390, height: 900))
        }
        var rows: [[String: Any]] = []
        for scenario in ["drag", "deceleration", "slider", "nonanimated", "cancel"] {
            let store = ReaderTemporaryPageStore()
            let controller = ReaderWebtoonViewController(source: nil,
                manga: AidokuRunner.Manga(sourceKey: "settlement", key: UUID().uuidString, title: "Settlement"),
                temporaryPageStore: store)
            let first = AidokuRunner.Chapter(key: "first")
            let second = AidokuRunner.Chapter(key: "second")
            let owner = WebtoonSettlementOwner(next: second)
            controller.delegate = owner
            func pages(_ chapter: AidokuRunner.Chapter) -> [Aidoku.Page] {
                (0..<5).map { index in
                    var page = Aidoku.Page(sourceId: "settlement", chapterId: chapter.key, index: index)
                    page.image = image
                    return page
                }
            }
            controller.viewModel.preloadedChapter = first
            controller.viewModel.preloadedPages = pages(first)
            window.rootViewController = controller; window.makeKeyAndVisible()
            controller.setChapter(first, startPage: 2)
            for _ in 0..<400 {
                if controller.numberOfSections(in: controller.collectionNode) == 1,
                   controller.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)) != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            try await stabilizeInitialImageLayout(controller, expectedRatio: image.size.height / image.size.width)
            controller.viewModel.preloadedChapter = second
            controller.viewModel.preloadedPages = pages(second)
            // Zoom flag is a public, deterministic insertion barrier in both builds.
            controller.scrollViewWillBeginZooming(controller.scrollView, with: nil)
            let task = Task { await controller.appendNextChapter() }
            try await Task.sleep(for: .milliseconds(80))
            #expect(controller.numberOfSections(in: controller.collectionNode) == 1)
            let before = controller.scrollView.contentOffset
            let anchor = try #require(controller.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0)))
            let beforeAnchor = controller.collectionNode.view.convert(anchor.frame, to: window).minY
            let beforeInnerOffset = controller.collectionNode.contentOffset.y
            let beforeContentHeight = controller.collectionNode.collectionViewLayout.collectionViewContentSize.height
            let preservationPending = (controller.collectionNode.collectionViewLayout as? VerticalContentOffsetPreservingLayout)?.isInsertingCellsAbove ?? false
            let started = CACurrentMediaTime()
            var completed = false
            let completion = Task { await task.value; completed = true }
            if scenario == "cancel" {
                controller.cancelPendingChapterLoads()
            } else {
                controller.scrollViewDidEndZooming(controller.scrollView, with: nil, atScale: 1)
                switch scenario {
                case "drag": controller.scrollViewDidEndDragging(controller.scrollView, willDecelerate: false)
                case "deceleration": controller.scrollViewDidEndDecelerating(controller.scrollView)
                case "slider": controller.sliderStopped(value: 0.2)
                default: controller.moveLeft()
                }
            }
            // Bound baseline's known missing slider/programmatic settlement, record
            // it, then rescue via a real existing callback to avoid retaining tasks.
            for _ in 0..<140 {
                if completed { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let completedWithoutRescue = completed
            let measuredMS = (CACurrentMediaTime() - started) * 1000
            if !completed {
                controller.scrollViewDidEndDecelerating(controller.scrollView)
                for _ in 0..<140 {
                    if completed { break }
                    try await Task.sleep(for: .milliseconds(5))
                }
            }
            if !completed { task.cancel(); controller.cancelPendingChapterLoads() }
            await completion.value
            controller.view.layoutIfNeeded()
            let afterFrame = try #require(controller.collectionNode.collectionViewLayout.layoutAttributesForItem(at: IndexPath(item: 2, section: 0))).frame
            let afterAnchor = controller.collectionNode.view.convert(afterFrame, to: window).minY
            let sections = controller.numberOfSections(in: controller.collectionNode)
            #expect(sections == (scenario == "cancel" ? 1 : 2))
            if scenario != "nonanimated" { #expect(abs(afterAnchor - beforeAnchor) < 1, "Insertion must preserve visible geometry") }
            rows.append(["scenario": scenario, "settleToCompletionMS": measuredMS,
                "completedWithoutRescue": completedWithoutRescue, "sections": sections,
                "anchorDelta": afterAnchor - beforeAnchor, "offsetBefore": before.y,
                "offsetAfter": controller.scrollView.contentOffset.y,
                "innerOffsetBefore": beforeInnerOffset, "innerOffsetAfter": controller.collectionNode.contentOffset.y,
                "anchorWindowYBefore": beforeAnchor, "anchorWindowYAfter": afterAnchor,
                "contentHeightBefore": beforeContentHeight,
                "contentHeightAfter": controller.collectionNode.collectionViewLayout.collectionViewContentSize.height,
                "preservationPendingBefore": preservationPending])
            controller.cancelPendingChapterLoads()
            window.rootViewController = nil
            await store.removeAll()
        }
        let directory = URL.documentsDirectory.appendingPathComponent("ReaderWebtoonSettlement", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["rows": rows,
            "scope": "Real Webtoon controller and Texture layout; in-memory pages; public settlement callbacks, no physical gestures or network; measured completion includes batch insertion."], options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent("results.json"), options: .atomic)
        print("WEBTOON_SETTLEMENT \(String(data: try JSONSerialization.data(withJSONObject: rows), encoding: .utf8)!)")
    }

    private func stabilizeInitialImageLayout(_ controller: ReaderWebtoonViewController, expectedRatio: CGFloat) async throws {
        // This benchmark isolates chapter-insertion scheduling from first-image
        // dimension discovery. Realize the five small fixture pages first; ratio
        // survives Texture evicting an offscreen decoded image.
        for item in 1...5 {
            var node: ReaderWebtoonPageNode?
            for _ in 0..<400 {
                node = controller.collectionNode.nodeForItem(at: IndexPath(item: item, section: 0)) as? ReaderWebtoonPageNode
                if node != nil { break }
                try await Task.sleep(for: .milliseconds(5))
            }
            let page = try #require(node)
            await page.loadPage()
            try #require(abs((page.ratio ?? 0) - expectedRatio) < 0.001)
        }
        var last: [CGFloat] = []
        var stableSamples = 0
        // Page dimension changes animate for 300ms. Require a longer stable
        // observation interval including both nested scroll views and the anchor.
        for _ in 0..<400 {
            controller.view.layoutIfNeeded()
            controller.collectionNode.view.layoutIfNeeded()
            if let frame = controller.collectionNode.collectionViewLayout
                .layoutAttributesForItem(at: IndexPath(item: 2, section: 0))?.frame {
                let sample = [controller.scrollView.contentOffset.y,
                    controller.collectionNode.contentOffset.y,
                    controller.scrollView.contentSize.height,
                    controller.collectionNode.collectionViewLayout.collectionViewContentSize.height,
                    frame.minY, frame.height]
                let same = last.count == sample.count && zip(last, sample).allSatisfy { abs($0 - $1) < 0.1 }
                stableSamples = same ? stableSamples + 1 : 0
                last = sample
                if stableSamples >= 20 { return }
            }
            try await Task.sleep(for: .milliseconds(20))
        }
        Issue.record("Initial image dimensions / nested scroll geometry never stabilized")
        throw CancellationError()
    }

}

@MainActor private final class WebtoonSettlementOwner: ReaderHoldingDelegate {
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
