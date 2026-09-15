import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderTranslationRenderingTests {
    @Test func backgroundReplacementPreservesDocumentAndReadablePixels() async throws {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let host = try window(frame: frame)
        host.rootViewController = UIViewController()
        let overlay = ReaderTranslationOverlayView(frame: frame)
        host.rootViewController?.view.addSubview(overlay)
        host.makeKeyAndVisible()
        defer { overlay.cancelWork(); host.isHidden = true }
        let deadline = Date().addingTimeInterval(20)
        while overlay.webView.isLoading || overlay.webView.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await overlay.webView.evaluateJavaScript("document.documentElement.dataset.testIdentity = 'retained'")
        for (color, channel) in [(UIColor.red, 0), (UIColor.blue, 2)] {
            let source = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
                color.setFill()
                context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
            }
            overlay.update(regions: [], imageSize: source.size, aspectFit: true,
                           settings: fixtureSettings(), image: source)
            var matched = false
            while !matched {
                if Date() > deadline { throw URLError(.timedOut) }
                let pixels = try await overlay.webView.evaluateJavaScript("""
                (() => {
                  const image = document.getElementById('reader-source-image');
                  if (!image?.complete || !image.naturalWidth) return [];
                  const canvas = document.createElement('canvas');
                  canvas.width = canvas.height = 1;
                  const context = canvas.getContext('2d');
                  context.drawImage(image, 0, 0, 1, 1);
                  return Array.from(context.getImageData(0, 0, 1, 1).data);
                })()
                """) as? [Int] ?? []
                matched = pixels.count == 4 && pixels[channel] > 240 && pixels[2 - channel] < 15
                if !matched { try await Task.sleep(for: .milliseconds(20)) }
            }
            let marker = try await overlay.webView.evaluateJavaScript("document.documentElement.dataset.testIdentity") as? String
            #expect(marker == "retained")
            #expect(try await overlay.webView.evaluateJavaScript("document.querySelectorAll('#reader-source-image').length") as? Int == 1)
        }
    }

    @Test func oversizedBackgroundAndCropStayBounded() throws {
        for size in [CGSize(width: 4000, height: 20000), CGSize(width: 1, height: 100000),
                     CGSize(width: 20000, height: 4000)] {
            let output = ReaderTranslationBackgroundImage.pixelSize(for: size)
            #expect(output.width * output.height <= ReaderTranslationBackgroundImage.maximumPixels)
            #expect(max(output.width, output.height) <= ReaderTranslationBackgroundImage.maximumSide)
        }
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.preferredRange = .standard
        let source = UIGraphicsImageRenderer(size: CGSize(width: 3200, height: 1600), format: format).image { context in
            UIColor.red.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 1600, height: 1600))
            UIColor.blue.setFill()
            context.fill(CGRect(x: 1600, y: 0, width: 1600, height: 1600))
        }
        let background = try ReaderTranslationBackgroundImage.prepare(source)
        let pixels = try #require(background.cgImage)
        #expect(pixels.width * pixels.height <= 4_000_000)
        #expect(abs(background.size.width / background.size.height - 2) < 0.002)
        let cropped = try ReaderTranslationBackgroundImage.prepare(source, crop: CGRect(x: 0.5, y: 0, width: 0.5, height: 1))
        #expect(cropped.size == CGSize(width: 1600, height: 1600))
        let cropPixels = try #require(cropped.cgImage)
        var rgba = [UInt8](repeating: 0, count: 4)
        let drawn = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1, bitsPerComponent: 8,
                bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(cropPixels, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            return true
        }
        #expect(drawn && rgba[2] > 240 && rgba[0] < 15)
    }

    @Test func contentTerminationBudgetSurvivesProgressUpdates() {
        let overlay = ReaderTranslationOverlayView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        defer { overlay.cancelWork() }
        let settings = fixtureSettings()
        for _ in 0..<8 {
            overlay.webViewWebContentProcessDidTerminate(overlay.webView)
            overlay.update(regions: [], imageSize: CGSize(width: 390, height: 700), aspectFit: false, settings: settings)
        }
        #expect(overlay.contentTerminationCount == 3)
        #expect(overlay.hasExhaustedRecovery)
        #expect(overlay.webView.isHidden)
        #expect(!overlay.canCacheRendering)
    }

    @Test func stalledDocumentRecoversWithoutNewTranslationData() async throws {
        let frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let host = try window(frame: frame)
        host.rootViewController = UIViewController()
        let overlay = ReaderTranslationOverlayView(frame: frame)
        host.rootViewController?.view.addSubview(overlay)
        host.makeKeyAndVisible()
        defer { overlay.cancelWork(); host.isHidden = true }
        // Simulate a document load whose completion callback never arrives.
        overlay.webView.navigationDelegate = nil
        var settings = fixtureSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        let region = ReaderTranslationRegion(id: "recovery", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.2), source: "Hello")
        overlay.update(regions: [region], imageSize: frame.size, aspectFit: false, settings: settings)
        try await Task.sleep(for: .seconds(1))
        #expect(overlay.lastDiagnostic == nil)
        overlay.webView.navigationDelegate = overlay
        try await waitForRender(overlay)
        #expect(overlay.lastDiagnostic?.renderedItemCount == 1)
    }

    @Test func sessionPaintsFirstBatchBeforePreloaderFinishesThePage() async throws {
        let source = image()
        let imageView = UIImageView(image: source)
        imageView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        imageView.contentMode = .scaleAspectFit
        let window = try window(frame: imageView.frame)
        window.rootViewController = UIViewController()
        window.rootViewController?.view.addSubview(imageView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let gate = RenderingProgressBarrier()
        let preloader = ReaderTranslationPreloader(translator: { regions, _, progress in
            #expect(regions.count >= 2)
            var partial = regions
            partial[0].translation = "먼저 도착한 번역"
            try await progress?(partial)
            await gate.wait()
            return partial.map {
                var region = $0
                if region.translation == nil { region.translation = "나머지 번역" }
                return region
            }
        })
        let session = ReaderTranslationSession(validate: { _ in }, process: { page, settings, progress in
            try await preloader.translate(page, settings: settings, onProgress: progress)
        }, cancelProcessing: { preloader.cancel() })
        defer { session.close() }
        let page = ReaderTranslationPage(imageView: imageView)
        let sourcePage = Page(sourceId: "unit-test", chapterId: "progress", index: 0, image: source)
        page.sourcePage = sourcePage
        var settings = fixtureSettings()
        settings.modelTier = .medium
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        session.update(items: [.init(sourcePage)], visible: [page], context: "progress")
        session.enable(settings: settings)
        let deadline = Date().addingTimeInterval(30)
        while !(await gate.started) {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!page.hasCompletedTranslation(settings: settings))
        let overlay = try #require(imageView.subviews.first as? ReaderTranslationOverlayView)
        do {
            try await waitForRender(overlay)
            let texts = try await overlay.webView.evaluateJavaScript("""
            Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(x => x.textContent)
            """) as? [String]
            #expect(texts?.first == "먼저 도착한 번역")
            #expect(texts?.contains("나머지 번역") == false)
            try await export(overlay, image: source, name: "first-batch-before-page-completion.png")
        } catch {
            await gate.release()
            throw error
        }
        let revision = try #require(overlay.lastDiagnostic?.revision)
        await gate.release()
        while !page.hasCompletedTranslation(settings: settings) {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(imageView.subviews.first === overlay)
        try await waitForRender(overlay, after: revision)
        #expect(page.regions.allSatisfy { $0.translation != nil })
        #expect(overlay.lastDiagnostic?.renderedItemCount == page.regions.count)
        await ReaderOCRService.shared.purge()
    }

    @Test func fullOCRTranslationAndDOMRenderingKeepsOriginalPixels() async throws {
        let source = image()
        let imageView = UIImageView(image: source)
        let selectionOverlay = UIView()
        imageView.addSubview(selectionOverlay)
        imageView.contentMode = .scaleAspectFit
        imageView.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        let window = try window(frame: imageView.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(imageView)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let service = ReaderTranslationService(client: RenderingFixtureTranslator())
        let page = ReaderTranslationPage(imageView: imageView, progressiveTranslate: { regions, settings, progress in
            try await service.translate(regions: regions, settings: settings, onProgress: progress)
        })
        var settings = fixtureSettings()
        settings.modelTier = .medium
        settings.targetLanguage = "ko"
        let count = try await page.process(translate: true, settings: settings)
        #expect(count >= 2)
        #expect(imageView.image === source)
        #expect(page.regions.allSatisfy { !$0.polygon.isEmpty && $0.confidence > 0 && $0.translationReuseIdentity != nil })
        #expect(page.regions.contains { $0.sourceOrientation == .horizontal })
        let overlay = try #require(imageView.subviews.first as? ReaderTranslationOverlayView)
        #expect(imageView.subviews.last === selectionOverlay)
        try await waitForRender(overlay)
        let texts = try #require(try await overlay.webView.evaluateJavaScript("""
        Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(x => x.textContent)
        """) as? [String])
        #expect(Set(texts) == Set(page.regions.compactMap(\.translation)))
        let hasPixelBackground = try await overlay.webView.evaluateJavaScript(
            "Boolean(document.getElementById('reader-source-image')?.complete && document.getElementById('reader-source-image')?.naturalWidth > 0)"
        ) as? Bool
        #expect(hasPixelBackground == true)
        try await export(overlay, image: source, name: "ocr-to-translation.png")
        let previousRevision = try #require(overlay.lastDiagnostic?.revision)
        settings.overlay.colorMode = .dark
        settings.overlay.opacity = 0.65
        page.applySettings(settings)
        try await waitForRender(overlay, after: previousRevision)
        #expect(page.regions.allSatisfy { $0.translation != nil })
        #expect(imageView.image === source)
        let beforeResize = try #require(overlay.lastDiagnostic?.revision)
        imageView.frame = CGRect(x: 0, y: 0, width: 700, height: 390)
        imageView.layoutIfNeeded()
        try await waitForRender(overlay, after: beforeResize)
        #expect(overlay.webView.bounds.size == imageView.bounds.size)
        page.reset()
        #expect(imageView.subviews == [selectionOverlay])
        await ReaderOCRService.shared.purge()
    }

    @Test func verticalDenseCardsUseOriginalPlannerAndDOMStyles() async throws {
        let size = CGSize(width: 390, height: 715)
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
        let window = try window(frame: overlay.frame)
        let controller = UIViewController()
        window.rootViewController = controller
        controller.view.addSubview(overlay)
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        var settings = fixtureSettings()
        settings.targetLanguage = "ko"
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        let regions = (0..<10).map { index in
            ReaderTranslationRegion(
                id: "column-\(index)",
                rect: CGRect(x: (20 + CGFloat(index) * 34) / size.width, y: 90 / size.height,
                             width: 20 / size.width, height: 150 / size.height),
                source: "縦書きの台詞です", translation: "서로 겹치지 않는 번역 말풍선입니다 \(index + 1)",
                confidence: 0.99, sourceOrientation: .vertical, sourceSingleVerticalColumn: false
            )
        }
        let items = regions.enumerated().map { $0.element.overlayItem(index: $0.offset, imageSize: size) }
        #expect(items.allSatisfy { $0.sourceOrientation == .vertical && $0.sourceSingleVerticalColumn == false && $0.confidence == 0.99 })
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items, imageSize: size, sourceRect: overlay.bounds, settings: settings.overlay,
            targetLanguage: "ko", viewport: size
        )
        overlay.update(regions: regions, imageSize: size, aspectFit: false, settings: settings)
        try await waitForRender(overlay)
        let audit = try #require(try await overlay.webView.evaluateJavaScript("""
        Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(x => ({
          text:x.textContent, x:parseFloat(x.style.left), y:parseFloat(x.style.top),
          width:parseFloat(x.style.width), height:parseFloat(x.style.height), vertical:x.style.writingMode === 'vertical-rl'
        }))
        """) as? [[String: Any]])
        #expect(audit.count == payload.count)
        for (actual, expected) in zip(audit, payload) {
            #expect(actual["text"] as? String == expected["text"] as? String)
            #expect(actual["vertical"] as? Bool == expected["vertical"] as? Bool)
            for key in ["x", "y", "width", "height"] {
                let actualValue = try #require(actual[key] as? Double)
                let expectedValue = try #require(expected[key] as? CGFloat)
                #expect(abs(actualValue - Double(expectedValue)) < 0.01)
            }
        }
        try await export(overlay, image: nil, name: "dense-vertical-to-korean.png")
    }

    @Test func partialTranslationCannotReappearAfterReset() async throws {
        let imageView = UIImageView(image: image())
        let barrier = RenderingProgressBarrier()
        let region = ReaderTranslationRegion(id: "one", rect: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.1), source: "hello")
        let page = ReaderTranslationPage(imageView: imageView, recognize: { _, _ in [region] }, progressiveTranslate: { regions, _, progress in
            try await progress?(regions)
            await barrier.wait()
            var translated = regions
            translated[0].translation = "late"
            try await progress?(translated)
            return translated
        })
        let task = Task { try await page.process(translate: true, settings: fixtureSettings()) }
        let deadline = Date().addingTimeInterval(5)
        while !(await barrier.started), Date() < deadline { await Task.yield() }
        let started = await barrier.started
        guard started else { task.cancel(); Issue.record("Fixture translation never reached the barrier"); return }
        #expect(page.regions.count == 1)
        page.reset()
        await barrier.release()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(page.regions.isEmpty)
        #expect(imageView.subviews.isEmpty)
    }

    @Test func realComicCaptionBandNeverMovesTranslationsOutsideViewport() {
        // OCR geometry and provider output from Sandra and Woo #795; the old
        // horizontal-row fallback moved the first caption to x = -71 points.
        let regions = [
            ReaderTranslationRegion(id: "0",
                rect: CGRect(x: 0.026530612244897958, y: 0.0367816091954023, width: 0.22653061224489796, height: 0.06896551724137931),
                source: "MOST COMMON EXPECTATION FOR THE YEAR 2O5O.", translation: "2050년에 대한 가장 일반적인 예상.", sourceOrientation: .horizontal),
            ReaderTranslationRegion(id: "1",
                rect: CGRect(x: 0.3551020408163265, y: 0.034482758620689655, width: 0.26632653061224487, height: 0.06896551724137931),
                source: "SECOND MOST COMMON EXPECTATION FOR THE YEAR 2OSO.", translation: "2050년에 대한 두 번째로 일반적인 예상.", sourceOrientation: .horizontal),
            ReaderTranslationRegion(id: "2",
                rect: CGRect(x: 0.6877551020408164, y: 0.041379310344827586, width: 0.21122448979591837, height: 0.03218390804597701),
                source: "REALITY IN THE YEAR 2O5O.", translation: "2050년의 현실.", sourceOrientation: .horizontal),
            ReaderTranslationRegion(id: "3",
                rect: CGRect(x: 0.7091836734693877, y: 0.11264367816091954, width: 0.2510204081632653, height: 0.10344827586206896),
                source: "Welcome to the final match of this year's Go World Cup between Google and Skynet!", translation: "구글과 스카이넷의 올해 바둑 월드컵 결승전에 오신 것을 환영합니다!", sourceOrientation: .horizontal),
            ReaderTranslationRegion(id: "4",
                rect: CGRect(x: 0.7520408163265306, y: 0.2689655172413793, width: 0.15510204081632653, height: 0.0735632183908046),
                source: "TAKE OUT THE TRASH ALREADY!!", translation: "쓰레기나 빨리 치워!!", sourceOrientation: .horizontal),
            ReaderTranslationRegion(id: "5",
                rect: CGRect(x: 0.7122448979591837, y: 0.40229885057471265, width: 0.11938775510204082, height: 0.06896551724137931),
                source: "After the game, meatbag.", translation: "게임 끝나고 나서다, 고깃덩어리야.", sourceOrientation: .horizontal),
            ReaderTranslationRegion(id: "6",
                rect: CGRect(x: 0.07755102040816327, y: 0.7816091954022989, width: 0.15714285714285714, height: 0.10114942528735632),
                source: "I've prepared every- thing for your trip to Australia.", translation: "호주 여행을 위한 모든 준비를 마쳤어요.", sourceOrientation: .horizontal),
            ReaderTranslationRegion(id: "7",
                rect: CGRect(x: 0.019387755102040816, y: 0.9471264367816092, width: 0.5051020408163265, height: 0.034482758620689655),
                source: "Sandra and Woo by Oliver Knörzer (writer) and Powree (artist) – www.sandraandwoo.com", translation: "Sandra and Woo – 작가 Oliver Knörzer, 그림 Powree – www.sandraandwoo.com", sourceOrientation: .horizontal)
        ]
        let size = CGSize(width: 980, height: 435)
        let viewport = CGSize(width: 390, height: 780)
        let bounds = ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
            imageSize: size, bounds: CGRect(origin: .zero, size: viewport), aspectFit: true)
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: ReaderTranslationRegion.overlayItems(regions, imageSize: size), imageSize: size,
            sourceRect: bounds, settings: ReaderTranslationSettings.defaultOverlay,
            targetLanguage: "ko", viewport: viewport)
        #expect(payload.count == regions.count)
        for item in payload {
            let rect = CGRect(x: item["x"] as? CGFloat ?? -.infinity, y: item["y"] as? CGFloat ?? -.infinity,
                width: item["width"] as? CGFloat ?? 0, height: item["height"] as? CGFloat ?? 0)
            #expect(CGRect(origin: .zero, size: viewport).insetBy(dx: -0.01, dy: -0.01).contains(rect))
            // The corrected caption row must stay inside the image. Other
            // independent cards (including the bottom credit) may use the
            // visible letterbox space, but cannot leave the viewport.
            if ["0", "1", "2"].contains(item["id"] as? String ?? "") {
                #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(rect))
            }
        }
    }

    @Test func horizontalReplacementUsesAvailableSpaceBeforeKeepingEmergencyFont() {
        // Rounded SPY dialogue-card dimensions from the real-image audit.
        // Its short Korean text can use the resolved envelope without growing.
        let rect = CGRect(x: 50, y: 100, width: 50, height: 43)
        let intrinsic = BrowserOverlayCardLayout(rect: rect, maximumFontSize: 5,
            contentInsets: UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        let variants: [BrowserOverlayDisplayVariant] = [.plain("누나 잘 지내?", vertical: false)]
        var settings = ReaderTranslationSettings.defaultOverlay
        let planned = BrowserOverlayLayoutPlanner.resolvePositionedLayout(intrinsic,
            source: rect, variants: variants, settings: settings,
            viewport: CGSize(width: 390, height: 780), occupied: [],
            sourceVertical: true, singleVerticalColumn: false, reservedSources: [])
        let result = BrowserOverlayLayoutPlanner.fittingFinalHorizontalFont(planned,
            variants: variants, settings: settings, occupied: [], reservedSources: [])
        let collision = BrowserOverlayLayoutPlanner.fittingFinalHorizontalFont(planned,
            variants: variants, settings: settings, occupied: [rect], reservedSources: [])
        #expect(collision.maximumFontSize == planned.maximumFontSize)
        #expect(result.rect == rect)
        #expect(result.maximumFontSize > BrowserOverlayLayoutPlanner.minimumAutoFontSize)
        #expect(BrowserOverlayLayoutPlanner.horizontalTextFits("누나 잘 지내?",
            available: CGSize(width: rect.width - 8, height: rect.height - 8),
            fontSize: result.maximumFontSize))
        settings.fontSizing = .fixed
        settings.fixedFontSizePoints = 5
        let fixed = BrowserOverlayLayoutPlanner.resolvePositionedLayout(intrinsic,
            source: rect, variants: variants, settings: settings,
            viewport: CGSize(width: 390, height: 780), occupied: [],
            sourceVertical: true, singleVerticalColumn: false, reservedSources: [])
        #expect(fixed.rect == rect)
        #expect(fixed.maximumFontSize == 5)
        settings.fontSizing = .autoFit
        settings.expansionPolicy = .sourceBounds
        let exact = BrowserOverlayLayoutPlanner.resolvePositionedLayout(intrinsic,
            source: rect, variants: variants, settings: settings,
            viewport: CGSize(width: 390, height: 780), occupied: [],
            sourceVertical: true, singleVerticalColumn: false, reservedSources: [])
        #expect(exact.rect == rect)
        #expect(exact.maximumFontSize == 5)
    }

    @Test func smallDialogueCanUseOneMoreLineWithoutMovingItsCard() {
        // Actual Cuckoo Chinese-to-Korean card from the frozen real-image audit.
        let rect = CGRect(x: 148.07875, y: 575.7375, width: 49.48, height: 38.5125)
        let original = BrowserOverlayCardLayout(rect: rect, maximumFontSize: 6.75,
            contentInsets: UIEdgeInsets(top: 3.74, left: 3.74, bottom: 3.74, right: 3.74))
        let result = BrowserOverlayLayoutPlanner.fittingFinalHorizontalFont(original,
            variants: [.plain("너희 먼저 먹어.", vertical: false)], settings: ReaderTranslationSettings.defaultOverlay,
            occupied: [], reservedSources: [])
        #expect(result.rect == original.rect)
        #expect(result.maximumFontSize >= 7.25 && result.maximumFontSize <= 12)
        #expect(BrowserOverlayLayoutPlanner.horizontalTextFits("너희 먼저 먹어.",
            available: CGSize(width: rect.width - result.contentInsets.left - result.contentInsets.right,
                height: rect.height - result.contentInsets.top - result.contentInsets.bottom),
            fontSize: result.maximumFontSize))
    }

    @Test func smallCaptionRecoversPaddingWithoutBreakingNames() {
        let rect = CGRect(x: 16, y: 337, width: 64.6579, height: 12)
        let original = BrowserOverlayCardLayout(rect: rect, maximumFontSize: 5,
            contentInsets: UIEdgeInsets(top: 3, left: 3, bottom: 3, right: 3))
        let result = BrowserOverlayLayoutPlanner.fittingFinalHorizontalFont(original,
            variants: [.plain("카게야마 토비오", vertical: false)], settings: ReaderTranslationSettings.defaultOverlay,
            occupied: [], reservedSources: [])
        #expect(result.rect == original.rect)
        #expect(result.maximumFontSize >= 5.5)
        #expect(result.contentInsets.top >= 2 && result.contentInsets.left >= 2)
        #expect(BrowserOverlayLayoutPlanner.horizontalTextFits("카게야마 토비오",
            available: CGSize(width: rect.width - result.contentInsets.left - result.contentInsets.right,
                height: rect.height - result.contentInsets.top - result.contentInsets.bottom),
            fontSize: result.maximumFontSize))
    }

    @Test func combinedOriginalAndTranslationRetainsNormalFloorRecovery() {
        let rect = CGRect(x: 50, y: 100, width: 50, height: 43)
        let intrinsic = BrowserOverlayCardLayout(rect: rect, maximumFontSize: 5,
            contentInsets: UIEdgeInsets(top: 4, left: 4, bottom: 4, right: 4))
        let variant = BrowserOverlayDisplayVariant(content: .originalAndTranslation(
            source: "原文", translation: "번역", separator: "\n"), vertical: false)
        let result = BrowserOverlayLayoutPlanner.resolvePositionedLayout(intrinsic,
            source: rect, variants: [variant], settings: ReaderTranslationSettings.defaultOverlay,
            viewport: CGSize(width: 390, height: 780), occupied: [],
            sourceVertical: true, singleVerticalColumn: false, reservedSources: [])
        #expect(result.rect == rect)
        #expect(result.maximumFontSize >= 6.75 && result.maximumFontSize <= 7)
    }

    @Test func overlayRetainsAspectCorrectSourcePolygon() {
        let region = ReaderTranslationRegion(id: "tilted", rect: CGRect(x: 0.1, y: 0.2, width: 0.3, height: 0.1),
            source: "ガチャ", translation: "달칵",
            polygon: [CGPoint(x: 0.1, y: 0.2), CGPoint(x: 0.4, y: 0.3),
                      CGPoint(x: 0.39, y: 0.4), CGPoint(x: 0.09, y: 0.3)])
        let item = region.overlayItem(index: 0, imageSize: CGSize(width: 600, height: 900))
        #expect(item.sourcePolygon.count == 4)
        #expect(item.sourcePolygon[0] == CGPoint(x: 60, y: 180))
        #expect(item.sourcePolygon[1] == CGPoint(x: 240, y: 270))
        #expect(item.sourceText == region.source && item.translatedText == region.translation)
    }

    @Test func sourceInkCleanupRequiresTranslatedLightReplacement() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        let item = BrowserOverlayItem(rect: CGRect(x: 100, y: 200, width: 40, height: 90),
            sourceText: "こんにちは", translatedText: "안녕", confidence: 1,
            sourceOrientation: .vertical)
        func payload(_ item: BrowserOverlayItem, _ settings: IPhoneOverlaySettings) throws -> [String: Any] {
            try #require(BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
                imageSize: CGSize(width: 600, height: 900), sourceRect: CGRect(x: 20, y: 30, width: 300, height: 450),
                settings: settings, targetLanguage: "ko", viewport: CGSize(width: 390, height: 780)).first)
        }
        let enabled = try payload(item, settings)
        #expect(enabled["sourceCleanup"] as? Bool == true)
        let bounds = try #require(enabled["sourceBounds"] as? [CGFloat])
        #expect(abs(bounds[0] - 100.0 / 600) < 0.000001)
        #expect(abs(bounds[1] - 200.0 / 900) < 0.000001)
        settings.mode = .originalAndTranslation
        #expect(try payload(item, settings)["sourceCleanup"] as? Bool == false)
        settings = ReaderTranslationSettings.defaultOverlay
        let untranslated = BrowserOverlayItem(rect: item.rect, sourceText: item.sourceText,
            translatedText: nil, confidence: 1, sourceOrientation: .vertical)
        #expect(try payload(untranslated, settings)["sourceCleanup"] as? Bool == false)
    }

    // Opt-in real-image audit. Copy manifest.json and referenced images into the
    // host application's Documents/RealComicRendering before test-without-building.
    // Fixtures contain actual OCR geometry and provider translations, never keys.
    @Test(.enabled(if: FileManager.default.fileExists(atPath:
        URL.documentsDirectory.appendingPathComponent("RealComicRendering/manifest.json").path)))
    func realComicProviderTranslationsPaintAndExportLayoutAudit() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("RealComicRendering", isDirectory: true)
        let fixtures = try JSONDecoder().decode([RealComicRenderingFixture].self,
            from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
        #expect(Set(fixtures.map(\.work)).count >= 2, "Real comic validation must include distinct works")
        #expect(!fixtures.isEmpty)
        for fixture in fixtures {
            let source = try #require(UIImage(contentsOfFile: directory.appendingPathComponent(fixture.image).path))
            #expect(!fixture.sourceURL.isEmpty && !fixture.regions.isEmpty)
            let size = CGSize(width: 390, height: 780)
            let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
            let window = try window(frame: overlay.frame)
            window.rootViewController = UIViewController()
            window.rootViewController?.view.addSubview(overlay)
            window.makeKeyAndVisible()
            defer { window.isHidden = true; overlay.cancelWork() }
            var settings = fixtureSettings()
            settings.targetLanguage = fixture.targetLanguage
            settings.overlay = ReaderTranslationSettings.defaultOverlay
            let regions = fixture.regions.map { item in
                ReaderTranslationRegion(id: item.id,
                    rect: CGRect(x: item.x, y: item.y, width: item.width, height: item.height),
                    source: item.source, translation: item.translation,
                    polygon: (item.originalPolygon ?? []).compactMap { point in
                        guard point.count == 2 else { return nil }
                        return CGPoint(x: point[0] / source.size.width, y: point[1] / source.size.height)
                    },
                    sourceOrientation: item.vertical == true ? .vertical : .horizontal)
            }
            let planned = BrowserPageImageOverlayRenderer.layoutPayload(
                items: ReaderTranslationRegion.overlayItems(regions, imageSize: source.size),
                imageSize: source.size,
                sourceRect: ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1),
                    imageSize: source.size, bounds: overlay.bounds, aspectFit: true),
                settings: settings.overlay, targetLanguage: fixture.targetLanguage, viewport: size)
            let started = Date()
            overlay.update(regions: regions, imageSize: source.size, aspectFit: true, settings: settings, image: source)
            try await waitForRender(overlay)
            let audit = try #require(try await overlay.webView.evaluateJavaScript("""
            Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(node => {
              const rect = node.getBoundingClientRect();
              const range = document.createRange(); range.selectNodeContents(node);
              const glyph = range.getBoundingClientRect();
              const style = getComputedStyle(node);
              const bounds = r => ({left:r.left,right:r.right,top:r.top,bottom:r.bottom,width:r.width,height:r.height});
              const excess = r => ({left:Math.max(0,rect.left-r.left),right:Math.max(0,r.right-rect.right),top:Math.max(0,rect.top-r.top),bottom:Math.max(0,r.bottom-rect.bottom)});
              const chars = [], walker = document.createTreeWalker(node, NodeFilter.SHOW_TEXT);
              while (walker.nextNode()) {
                const textNode = walker.currentNode; let offset = 0;
                for (const character of textNode.data) {
                  const characterRange = document.createRange();
                  characterRange.setStart(textNode, offset);
                  offset += character.length;
                  characterRange.setEnd(textNode, offset);
                  const characterBounds = characterRange.getBoundingClientRect();
                  chars.push({text:character,rect:bounds(characterBounds),excess:excess(characterBounds)});
                }
              }
              return {smallTextRefinement:node.dataset.smallTextRefinement || null,text:node.textContent, x:rect.x, y:rect.y, width:rect.width, height:rect.height,
                glyphRect:bounds(glyph), glyphExcess:excess(glyph), characters:chars,
                scrollWidth:node.scrollWidth,scrollHeight:node.scrollHeight,clientWidth:node.clientWidth,clientHeight:node.clientHeight,
                fontFamily:style.fontFamily,fontWeight:style.fontWeight,lineHeight:style.lineHeight,
                writingMode:style.writingMode,overflow:style.overflow,textOrientation:style.textOrientation,
                padding:[style.paddingTop,style.paddingRight,style.paddingBottom,style.paddingLeft],devicePixelRatio,
                fontSize:parseFloat(getComputedStyle(node).fontSize),
                textOutsideCard:glyph.left < rect.left-1 || glyph.right > rect.right+1 ||
                  glyph.top < rect.top-1 || glyph.bottom > rect.bottom+1,
                cardOutsideViewport:rect.left < -1 || rect.top < -1 || rect.right > innerWidth+1 || rect.bottom > innerHeight+1};
            })
            """) as? [[String: Any]])
            #expect(audit.count == regions.filter { !$0.preservesOriginalText }.count)
            #expect(audit.allSatisfy { $0["cardOutsideViewport"] as? Bool == false },
                    "Translation cards must remain visible for \(fixture.id)")
            // Persist questionable geometry instead of accepting a count-only screenshot.
            // Reviewed outliers become focused regression fixtures after diagnosis.
            let cleanup = try await overlay.webView.evaluateJavaScript("""
            (() => { const root = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
              return {fontRefinementMilliseconds:Number(root?.dataset.smallTextRefinementMilliseconds || 0),count:Number(root?.dataset.cleanupCount || 0),pixels:Number(root?.dataset.cleanupPixels || 0),
                milliseconds:Number(root?.dataset.cleanupMilliseconds || 0),
                masks:Array.from(root?.querySelectorAll('canvas') || []).map(canvas => {
                  const r = canvas.getBoundingClientRect(); return {x:r.x,y:r.y,width:r.width,height:r.height,
                    png:canvas.toDataURL('image/png')}; })}; })()
            """)
            let report: [String: Any] = ["cleanup": cleanup as Any, "id": fixture.id, "work": fixture.work,
                "sourceURL": fixture.sourceURL, "targetLanguage": fixture.targetLanguage,
                "renderMilliseconds": Date().timeIntervalSince(started) * 1000, "items": audit, "plannedItems": planned]
            let output = URL.documentsDirectory.appendingPathComponent("TranslationValidation", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(fixture.id + ".json"))
            try await export(overlay, image: source, name: fixture.id + ".png")
            // Same decoded source and same WebKit surface isolate cleanup from
            // cross-run image decoding/rasterization differences on large originals.
            _ = try await overlay.webView.evaluateJavaScript("""
            document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-cleanup"]').forEach(c => {
              c.dataset.savedOpacity = c.style.opacity; c.style.opacity = '0';
            });
            """)
            try await Task.sleep(for: .milliseconds(40))
            try await export(overlay, image: source, name: fixture.id + "-cleanup-hidden.png")
            _ = try await overlay.webView.evaluateJavaScript("""
            document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-cleanup"]').forEach(c => {
              c.style.opacity = c.dataset.savedOpacity;
            });
            """)
            try await Task.sleep(for: .milliseconds(40))
            // Compare actual painted glyphs with Range metrics. Font boxes can
            // exceed a vertical card even when the ink itself is not clipped.
            _ = try await overlay.webView.evaluateJavaScript("""
            document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]').forEach(node => {
              if (getComputedStyle(node).writingMode === 'vertical-rl') node.style.overflow = 'visible';
            });
            """)
            try await export(overlay, image: source, name: fixture.id + "-unclipped.png")
        }
    }

    private func fixtureSettings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings()
        settings.sourceLanguage = "auto"
        settings.translationSourceLanguages = []
        return settings
    }

    private func waitForRender(_ overlay: ReaderTranslationOverlayView, after revision: UInt64 = 0) async throws {
        for _ in 0..<200 {
            overlay.layoutIfNeeded()
            if let diagnostic = overlay.lastDiagnostic, diagnostic.revision > revision {
                #expect(diagnostic.outcome == .committed)
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("The embedded translation DOM renderer did not commit within 10 seconds")
        throw CancellationError()
    }

    private func image() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        return UIGraphicsImageRenderer(size: CGSize(width: 640, height: 880), format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: 640, height: 880))
            for (text, y) in [("HELLO WORLD", 100), ("こんにちは", 280), ("OCR TEST PAGE", 570)] {
                (text as NSString).draw(at: CGPoint(x: 50, y: y), withAttributes: [
                    .font: UIFont.systemFont(ofSize: 44), .foregroundColor: UIColor.black
                ])
            }
        }
    }

    private func window(frame: CGRect) throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.frame = frame
        return window
    }

    private func export(_ overlay: ReaderTranslationOverlayView, image: UIImage?, name: String) async throws {
        _ = try await overlay.webView.callAsyncJavaScript(
            """
            await Promise.race([
              new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))),
              new Promise(resolve => setTimeout(resolve, 500))
            ])
            """,
            arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld
        )
        let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
            overlay.webView.takeSnapshot(with: nil) { image, error in
                if let image {
                    continuation.resume(returning: image)
                } else {
                    continuation.resume(throwing: error ?? CancellationError())
                }
            }
        }
        let pixels = try #require(snapshot.cgImage.flatMap { NativeOCRCGImageAdapter.makeRGBAFrame(from: $0) })
        let darkPixels = stride(from: 0, to: pixels.bytes.count - 3, by: 4).filter {
            pixels.bytes[$0 + 3] > 100 && pixels.bytes[$0] < 100 && pixels.bytes[$0 + 1] < 100 && pixels.bytes[$0 + 2] < 100
        }.count
        #expect(darkPixels > 20, "DOM content must actually paint into the WebKit snapshot")
        let result = UIGraphicsImageRenderer(size: overlay.bounds.size).image { context in
            UIColor.white.setFill()
            context.fill(overlay.bounds)
            if let image {
                image.draw(in: ReaderTranslationGeometry.displayRect(CGRect(x: 0, y: 0, width: 1, height: 1), imageSize: image.size,
                                                                     bounds: overlay.bounds, aspectFit: true))
            }
            snapshot.draw(in: overlay.bounds)
        }
        let directory = URL.documentsDirectory.appendingPathComponent("TranslationValidation", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try #require(result.pngData()).write(to: directory.appendingPathComponent(name))
    }
}

private struct RenderingFixtureTranslator: RemoteTranslating {
    func translate(_ request: RemoteTranslationRequest, configuration: RemoteTranslationConfiguration) async throws -> RemoteTranslationBatchResult {
        RemoteTranslationBatchResult(translations: request.segments.map {
            RemoteTranslatedSegment(id: $0.id, text: $0.text.uppercased().contains("HELLO") ? "안녕, 세상!" : "페이지의 글자를 읽고 한국어로 옮겼습니다.")
        }, source: .network, providerRequestID: nil)
    }
}

private actor RenderingProgressBarrier {
    private(set) var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0; started = true } }
    func release() { continuation?.resume(); continuation = nil }
}

private struct RealComicRenderingFixture: Decodable {
    let id: String
    let work: String
    let sourceURL: String
    let image: String
    let targetLanguage: String
    let regions: [Region]

    struct Region: Decodable {
        let id: String
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let source: String
        let translation: String
        let vertical: Bool?
        let originalPolygon: [[Double]]?
    }
}
