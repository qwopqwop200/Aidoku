import AidokuRunner
import AsyncDisplayKit
import Testing
import UIKit
import XCTest
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderWebtoonLifecycleTests {
    @Test func malformedChapterNumbersDoNotCrashTransitionLabels() {
        let view = ReaderInfoPageView(type: .next)
        #expect(view.chapterDifference(higherChapterNumber: 12.5, lowerChapterNumber: 9.2) == 3)
        for number in [Float.infinity, -.infinity, .nan, .greatestFiniteMagnitude] {
            #expect(view.chapterDifference(higherChapterNumber: number, lowerChapterNumber: 1) == 0)
            #expect(view.chapterDifference(higherChapterNumber: 1, lowerChapterNumber: number) == 0)
        }
    }

    @Test func transitionCountsOnlyMissingChapters() {
        let view = ReaderInfoPageView(type: .next)
        view.currentChapter = AidokuRunner.Chapter(key: "one", chapterNumber: 1)
        view.nextChapter = AidokuRunner.Chapter(key: "three", chapterNumber: 3)
        #expect(view.skippingChaptersLabel.text == NSLocalizedString("SKIPPING_ONE_CHAPTER"))
    }

    @Test func deferredBackingViewPublishesReadyImage() async throws {
        let node = GIFImageNode()
        let image = Self.image()
        node.image = image
        // Let the original image notification run before Texture creates a view.
        for _ in 0..<10 { await Task.yield() }
        #expect(node.imageView == nil)
        var receivedReadyImage = false
        let observer = NotificationCenter.default.addObserver(
            forName: ReaderTranslationPage.imageChanged, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if node.imageView?.image === image { receivedReadyImage = true }
            }
        }
        defer { NotificationCenter.default.removeObserver(observer) }
        _ = node.view
        for _ in 0..<20 { await Task.yield() }
        #expect(receivedReadyImage)
    }

    @Test func resetReleasesStoredPixelsAndDoesNotClearQuickReturn() async {
        let node = GIFImageNode()
        _ = node.view
        node.image = Self.image()
        for _ in 0..<10 { await Task.yield() }
        node.reset()
        #expect(node.image == nil)
        let replacement = Self.image()
        node.image = replacement
        for _ in 0..<20 { await Task.yield() }
        #expect(node.imageView?.image === replacement)
    }

    @Test func splitPagePreservesSuppressedRubyInkAndOrderingEvidence() throws {
        var region = ReaderTranslationRegion(id: "split", rect: CGRect(x: 0.6, y: 0.2, width: 0.2, height: 0.3),
            source: "本文", translation: "본문")
        region.translationOrder = 2
        region.translationOrderVersion = "current"
        region.auxiliaryInkRects = [CGRect(x: 0.8, y: 0.2, width: 0.04, height: 0.3),
                                    CGRect(x: 0.1, y: 0.2, width: 0.04, height: 0.3)]
        let cropped = try #require(region.cropped(to: CGRect(x: 0.5, y: 0, width: 0.5, height: 1)))
        #expect(cropped.translationOrder == 2)
        #expect(cropped.translationOrderVersion == "current")
        #expect(cropped.auxiliaryInkRects.count == 1)
        let auxiliary = try #require(cropped.auxiliaryInkRects.first)
        #expect(abs(auxiliary.minX - 0.6) < 0.0001)
        #expect(abs(auxiliary.width - 0.08) < 0.0001)
    }

    @Test func changingTextPageToImageReleasesHostingController() {
        let parent = UIViewController()
        let page = ReaderPageView(parent: parent, temporaryPageStore: ReaderTemporaryPageStore())
        page.setPageText(text: "Old chapter")
        #expect(parent.children.count == 1)
        page.setPageImage(Self.image())
        #expect(parent.children.isEmpty)
        #expect(page.imageView.image != nil)
    }

    @Test func automaticBackgroundSupportsGrayscaleAndRetinaImages() throws {
        let context = try #require(CGContext(data: nil, width: 101, height: 103, bitsPerComponent: 8,
            bytesPerRow: 101, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue))
        context.setFillColor(CGColor(gray: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 101, height: 103))
        let pixels = try #require(context.makeImage())
        for scale: CGFloat in [1, 2] {
            let result = PageBackground.choose(for: UIImage(cgImage: pixels, scale: scale, orientation: .up), isLandscape: true)
            guard case .color(let color) = result else { Issue.record("Expected solid dark background"); continue }
            var white: CGFloat = 1
            color.getWhite(&white, alpha: nil)
            #expect(white < 0.1)
        }
    }

    @Test func chapterCacheKeepsOutgoingChapterIdentity() async {
        let model = ReaderPagedViewModel(source: nil, manga: AidokuRunner.Manga(sourceKey: "test", key: "manga", title: "Test"))
        let first = AidokuRunner.Chapter(key: "first")
        let second = AidokuRunner.Chapter(key: "second")
        let original = Page(sourceId: "test", chapterId: first.key, index: 0)
        model.chapter = first
        model.pages = [original]
        await model.loadPages(chapter: second)
        #expect(model.preloadedChapter == first)
        #expect(model.preloadedPages == [original])
        await model.loadPages(chapter: first)
        #expect(model.chapter == first)
        #expect(model.pages == [original])
    }

    @Test func leavingDoublePageRestoresZoom() async throws {
        let controller = ReaderPageViewController(type: .page, delegate: nil, temporaryPageStore: ReaderTemporaryPageStore())
        controller.loadViewIfNeeded()
        var page = Page(sourceId: "test", chapterId: "zoom", index: 0)
        page.image = Self.image()
        controller.setPage(page, skipProcessing: true)
        try await waitUntil { controller.zoomView?.zoomEnabled == true }
        controller.isInDoublePageController = true
        #expect(controller.zoomView?.zoomEnabled == false)
        controller.isInDoublePageController = false
        #expect(controller.zoomView?.zoomEnabled == true)
    }

    @Test func navigationBeforeChapterHasLoadedIsSafe() {
        let controller = ReaderPagedViewController(source: nil,
            manga: AidokuRunner.Manga(sourceKey: "test", key: "manga", title: "Test"),
            temporaryPageStore: ReaderTemporaryPageStore())
        controller.move(toPage: 1, animated: false)
        #expect(controller.pageViewControllers.isEmpty)
    }

    private func waitUntil(_ predicate: () -> Bool) async throws {
        for _ in 0..<600 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(predicate(), "Visible webtoon translation did not commit within 15 seconds")
    }

    private static func image() -> UIImage {
        UIGraphicsImageRenderer(size: CGSize(width: 100, height: 140)).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 100, height: 140))
            ("Hello" as NSString).draw(at: CGPoint(x: 20, y: 45), withAttributes: [
                .font: UIFont.systemFont(ofSize: 14), .foregroundColor: UIColor.black
            ])
        }
    }
}

@MainActor private final class WebtoonOwner: ReaderTranslationOwner {
    let controller: ReaderWebtoonViewController
    let translationUpcomingPages: [Aidoku.Page]
    let navigationItem = UINavigationItem()
    var translationVisiblePages: [ReaderTranslationPage] { controller.translationPages() }
    var translationChapterKey: String { "webtoon-lifecycle" }
    let translationPersistsCache: Bool
    var translationCurrentPageIndex: Int { max(0, controller.getCurrentPage() - 1) }
    init(controller: ReaderWebtoonViewController, pages: [Aidoku.Page], persistsCache: Bool = false) {
        translationPersistsCache = persistsCache
        self.controller = controller
        translationUpcomingPages = pages
    }
}
