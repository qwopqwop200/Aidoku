import AidokuRunner
import AsyncDisplayKit
import Testing
import UIKit
import XCTest
import Vision
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

    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("ReportedPartialPage/source.png").path)),
        arguments: [ReadingMode.webtoon.rawValue, ReadingMode.continuous.rawValue])
    func reportedPagePartiallyVisibleCapturePreservesAllFiveRegions(mode: Int) async throws {
        let fixture = URL.documentsDirectory.appendingPathComponent("ReportedPartialPage", isDirectory: true)
        let source = try #require(UIImage(contentsOfFile: fixture.appendingPathComponent("source.png").path))
        let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
            from: Data(contentsOf: fixture.appendingPathComponent("regions.json"))).map(\.region)
        try #require(regions.count == 5 && regions.allSatisfy { !($0.translation ?? "").isEmpty },
                     "The reported page fixture must retain all five recorded translations")
        let lower = Array(regions.sorted { $0.rect.midY > $1.rect.midY }.prefix(2))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 720)
        let store = ReaderTemporaryPageStore()
        let controller = ReaderWebtoonViewController(
            source: nil, manga: AidokuRunner.Manga(sourceKey: "test", key: "reported", title: "Reported page"),
            temporaryPageStore: store)
        controller.readingMode = try #require(ReadingMode(rawValue: mode))
        let chapter = AidokuRunner.Chapter(key: "reported-partial-\(UUID().uuidString)")
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let blank = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 1000), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 390, height: 1000))
        }
        let pages = [blank, source].enumerated().map { index, image in
            var page = Page(sourceId: "test", chapterId: chapter.key, index: index)
            page.image = image
            return page
        }
        controller.viewModel.preloadedChapter = chapter
        controller.viewModel.preloadedPages = pages
        let owner = WebtoonOwner(controller: controller, pages: pages, persistsCache: true)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let disk = ReaderTranslationDiskCache(directory: directory)
        let cache = ReaderTranslationRenderCache(disk: disk)
        var settings = ReaderTranslationSettings()
        settings.automaticallyTranslate = true
        settings.sourceLanguage = "ja"
        settings.targetLanguage = "ko"
        settings.overlay = try JSONDecoder().decode(IPhoneOverlaySettings.self,
            from: Data(contentsOf: fixture.appendingPathComponent("overlay.json")))
        #expect(settings.overlay.visible, "Replay must use the enabled overlay settings from the reported device")
        var processed: [Int] = []
        let session = ReaderTranslationSession(process: { page, _, _ in
            processed.append(page.index)
            return page.index == 1 ? regions : []
        }, diskCache: disk, renderCache: cache, availableMemory: { UInt64.max })
        let coordinator = ReaderTranslationCoordinator(owner: owner, session: session,
            readSettings: { settings }, setEnabled: { _ in })
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer {
            coordinator.close()
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKey()
            Task { await store.removeAll(); try? await disk.clear(); try? FileManager.default.removeItem(at: directory) }
        }
        controller.setChapter(chapter, startPage: 1)
        // Set the reported page's leading edge low in the viewport before any
        // translation/cache work starts. Its full image will fit after scrolling.
        let path = IndexPath(item: 2, section: 0)
        try await waitUntil {
            controller.collectionNode.collectionViewLayout.layoutAttributesForItem(at: path) != nil
        }
        controller.view.layoutIfNeeded()
        let attributes = try #require(controller.collectionNode.collectionViewLayout.layoutAttributesForItem(at: path))
        let currentTop = controller.scrollView.convert(CGPoint(x: 0, y: attributes.frame.minY), to: window).y
        controller.scrollView.setContentOffset(CGPoint(x: 0,
            y: controller.scrollView.contentOffset.y + currentTop - 490), animated: false)
        controller.view.layoutIfNeeded()
        try await waitUntil {
            controller.translationPages().contains { $0.sourcePage?.index == 1 && $0.imageView?.image != nil }
        }
        let partialPage = try #require(controller.translationPages().first { $0.sourcePage?.index == 1 })
        let partialImage = try #require(partialPage.imageView)
        let loadedTop = partialImage.convert(partialImage.bounds, to: window).minY
        controller.scrollView.setContentOffset(CGPoint(x: 0,
            y: controller.scrollView.contentOffset.y + loadedTop - 490), animated: false)
        controller.view.layoutIfNeeded()
        let initialFrame = partialImage.convert(partialImage.bounds, to: window)
        #expect(abs(initialFrame.minY - 490) < 35, "Reported page must start near the lower viewport")
        for region in lower {
            let rect = CGRect(x: region.rect.minX * partialImage.bounds.width,
                              y: region.rect.minY * partialImage.bounds.height,
                              width: region.rect.width * partialImage.bounds.width,
                              height: region.rect.height * partialImage.bounds.height)
            #expect(!window.bounds.intersects(partialImage.convert(rect, to: window)),
                    "Both lower balloons must be offscreen when snapshot creation begins")
        }
        coordinator.resume()
        try await waitUntil {
            controller.translationPages().contains { candidate in
                candidate.sourcePage?.index == 1 && candidate.hasCompletedTranslation(settings: settings) &&
                candidate.imageView?.subviews.contains { $0.accessibilityIdentifier == "reader.translation.cachedOverlay" } == true
            }
        }
        let page = try #require(controller.translationPages().first { $0.sourcePage?.index == 1 })
        let imageView = try #require(page.imageView)
        #expect(page.renderCache === cache && cache.bitmapBytes > 0)
        let snapshotView = try #require(imageView.subviews.first {
            $0.accessibilityIdentifier == "reader.translation.cachedOverlay"
        } as? UIImageView)
        let pixels = try #require(snapshotView.image?.cgImage)
        let artifacts = URL.documentsDirectory.appendingPathComponent("AuditWebtoon", isDirectory: true)
        try FileManager.default.createDirectory(at: artifacts, withIntermediateDirectories: true)
        try #require(snapshotView.image?.pngData()).write(to: artifacts.appendingPathComponent("mode-\(mode)-reported-bitmap.png"))
        // Independent region crops avoid OCR mixing separate speech balloons.
        for region in regions {
            let rect = region.rect.insetBy(dx: -0.02, dy: -0.015)
            let cropRect = CGRect(x: rect.minX * CGFloat(pixels.width), y: rect.minY * CGFloat(pixels.height),
                                  width: rect.width * CGFloat(pixels.width), height: rect.height * CGFloat(pixels.height))
                .intersection(CGRect(x: 0, y: 0, width: CGFloat(pixels.width), height: CGFloat(pixels.height))).integral
            let crop = try #require(pixels.cropping(to: cropRect))
            let text = try recognizedText(crop).filter { $0.isLetter || $0.isNumber }
            let expected = try #require(region.translation).filter { $0.isLetter || $0.isNumber }
            #expect(text.contains(expected), "Complete reported-page bitmap must include \(expected), got: \(text)")
        }
        let topInWindow = imageView.convert(imageView.bounds, to: window).minY
        controller.scrollView.setContentOffset(CGPoint(x: 0,
            y: controller.scrollView.contentOffset.y + topInWindow - 100), animated: false)
        controller.view.layoutIfNeeded()
        coordinator.visiblePagesDidChange()
        let fullFrame = imageView.convert(imageView.bounds, to: window)
        #expect(fullFrame.minY >= 0 && fullFrame.maxY <= window.bounds.maxY,
                "The final screen must display the entire reported page")
        #expect(processed.filter { $0 == 1 }.count == 1, "Scrolling must not repeat processing")
        try await assertExternalScreen(label: "mode-\(mode == ReadingMode.webtoon.rawValue ? 60 : 61)-cold",
            contains: lower.compactMap(\.translation), ignoringPunctuation: true)
    }

    private func recognizedText(_ pixels: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLanguages = ["ko-KR", "en-US"]
        request.recognitionLevel = .accurate
        try VNImageRequestHandler(cgImage: pixels).perform([request])
        return (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined()
            .filter { !$0.isWhitespace }
    }

    private func assertExternalScreen(label: String, contains expected: [String], ignoringPunctuation: Bool = false) async throws {
        try await Task.sleep(for: .seconds(1))
        let directory = URL.documentsDirectory.appendingPathComponent("AuditWebtoon", isDirectory: true)
        let screenURL = directory.appendingPathComponent(label + "-external-screen.png")
        try? FileManager.default.removeItem(at: screenURL)
        try Data(label.utf8).write(to: directory.appendingPathComponent("capture-ready"), options: .atomic)
        let deadline = Date().addingTimeInterval(45)
        while !FileManager.default.fileExists(atPath: screenURL.path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
        }
        let pixels = try #require(UIImage(data: Data(contentsOf: screenURL))?.cgImage)
        #expect(pixels.width > 100 && pixels.height > 100)
        let text = try recognizedText(pixels).filter { !ignoringPunctuation || $0.isLetter || $0.isNumber }
        for expected in expected {
            let normalized = expected.filter { ignoringPunctuation ? ($0.isLetter || $0.isNumber) : !$0.isWhitespace }
            #expect(text.contains(normalized),
                    "Actual screen \(label) must contain \(expected), got: \(text)")
        }
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
