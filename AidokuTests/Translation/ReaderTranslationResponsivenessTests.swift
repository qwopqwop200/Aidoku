import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderTranslationResponsivenessTests {
    @Test func spatialCandidateDeduplicationKeepsOriginalToleranceAndOrder() {
        var candidates: [CGRect] = (0..<4_096).map { index in
            let x = CGFloat((index * 13) % 51) / 17 - 1
            let y = CGFloat((index * 23) % 79) / 19 - 2
            return CGRect(x: x, y: y, width: 30, height: 50)
        }
        candidates.append(contentsOf: [CGRect(x: 0.25, y: 0, width: 30, height: 50), CGRect(x: 0.2499, y: 0, width: 30, height: 50)])
        var original: [CGRect] = []
        for candidate in candidates {
            if original.contains(where: { abs($0.minX - candidate.minX) < 0.25 && abs($0.minY - candidate.minY) < 0.25 }) { continue }
            original.append(candidate)
            if original.count == 160 { break }
        }
        #expect(BrowserOverlayLayoutPlanner.uniquePackingCandidatesInOrder(candidates, limit: 160) == original)
    }

    @Test func irregularSourcePageLayoutFinishesPromptly() async throws {
        let viewport = CGSize(width: 430, height: 600)
        let items = ReaderLayoutRegressionFixture.items.map { item in
            BrowserOverlayItem(
                stableRegionID: item.stableRegionID,
                rect: CGRect(x: item.rect.minX * viewport.width, y: item.rect.minY * viewport.height,
                             width: item.rect.width * viewport.width, height: item.rect.height * viewport.height),
                sourceText: item.sourceText, translatedText: item.translatedText, confidence: item.confidence,
                sourceOrientation: item.sourceOrientation, sourceSingleVerticalColumn: item.sourceSingleVerticalColumn
            )
        }
        let start = ProcessInfo.processInfo.systemUptime
        let payload = try await BrowserPageImageOverlayRenderer.prepareLayoutData(
            items: items, imageSize: viewport, sourceRect: CGRect(origin: .zero, size: viewport),
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport
        )
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        print("IRREGULAR_PAGE_LAYOUT_SECONDS=\(elapsed)")
        #expect(elapsed < 5)
        #expect((try JSONSerialization.jsonObject(with: payload) as? [[String: Any]])?.count == 29)
    }

    @Test func precomputedPackingScoresPreserveCandidateOrder() {
        let anchor = CGRect(x: 110, y: 180, width: 40, height: 60)
        var candidates: [CGRect] = (0..<2_048).map { index in
            let x = CGFloat((index * 73) % 309) / 3
            let y = CGFloat((index * 137) % 517) / 3
            return CGRect(x: x, y: y, width: 40, height: 60)
        }
        candidates.append(contentsOf: [anchor, anchor, anchor.offsetBy(dx: 0.1, dy: 0.1)])
        let originalOrder = candidates.sorted { left, right in
            let leftDX = left.midX - anchor.midX
            let leftDY = left.midY - anchor.midY
            let rightDX = right.midX - anchor.midX
            let rightDY = right.midY - anchor.midY
            let leftDistance = leftDX * leftDX + leftDY * leftDY
            let rightDistance = rightDX * rightDX + rightDY * rightDY
            if abs(leftDistance - rightDistance) > 0.25 { return leftDistance < rightDistance }
            if abs(left.minX - right.minX) > 0.25 { return left.minX < right.minX }
            return left.minY < right.minY
        }
        #expect(BrowserOverlayLayoutPlanner.orderedPackingCandidates(candidates, preferredRect: anchor) == originalOrder)
    }

    @Test func cachedTextMeasurementsPreserveExactLayout() {
        let viewport = CGSize(width: 390, height: 780)
        let items = Array(denseItems.prefix(8))
        let cache = BrowserOverlayTextMeasurementCache()
        let cached = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items, imageSize: viewport, sourceRect: CGRect(origin: .zero, size: viewport),
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport,
            measurementCache: cache
        )
        let uncached = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items, imageSize: viewport, sourceRect: CGRect(origin: .zero, size: viewport),
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: viewport,
            measurementCache: nil
        )
        #expect((cached as NSArray).isEqual(to: uncached))
        #expect(cache.passStatistics.hits > 0)
    }

    @Test func cancellingDenseLayoutLetsTheNextRenderProceed() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        var publishedCounts: [Int] = []
        var cancelled = false
        var cleared = false
        let renderer = BrowserPageImageOverlayRenderer { _, _, arguments in
            let count = (arguments["items"] as? [[String: Any]])?.count ?? 0
            publishedCounts.append(count)
            return ["status": "committed", "revision": arguments["revision"] ?? "", "itemCount": count]
        }
        renderer.render(on: webView, items: denseItems, imageSize: webView.bounds.size, sourceRect: webView.bounds,
                        settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko") {
            cancelled = $0.outcome == .stale
        }
        try await Task.sleep(for: .milliseconds(30))
        renderer.cancelPendingRender()
        renderer.render(on: webView, items: [], imageSize: webView.bounds.size, sourceRect: webView.bounds,
                        settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko") { _ in cleared = true }
        let deadline = Date().addingTimeInterval(2)
        while !cancelled || !cleared {
            if Date() > deadline { renderer.cancelPendingRender(); throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(publishedCounts == [0])
    }

    @Test func denseOverlaySchedulingDoesNotBlockMainActor() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        var completed = false
        var renderedCount = 0
        let renderer = BrowserPageImageOverlayRenderer { _, _, arguments in
            renderedCount = (arguments["items"] as? [[String: Any]])?.count ?? 0
            return ["status": "committed", "revision": arguments["revision"] ?? "", "itemCount": renderedCount]
        }
        let began = ProcessInfo.processInfo.systemUptime
        renderer.render(on: webView, items: denseItems, imageSize: webView.bounds.size, sourceRect: webView.bounds,
                        settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko") { _ in completed = true }
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        print("TRANSLATION_RENDER_MAIN_SECONDS=\(elapsed)")
        #expect(elapsed < 0.1)
        let deadline = Date().addingTimeInterval(30)
        var previousTick = ProcessInfo.processInfo.systemUptime
        var largestGap: Double = 0
        while !completed {
            if Date() > deadline { renderer.cancelPendingRender(); throw URLError(.timedOut) }
            try await Task.sleep(nanoseconds: 10_000_000)
            let tick = ProcessInfo.processInfo.systemUptime
            largestGap = max(largestGap, tick - previousTick)
            previousTick = tick
        }
        print("TRANSLATION_RENDER_TOTAL_SECONDS=\(ProcessInfo.processInfo.systemUptime - began)")
        print("TRANSLATION_MAIN_TICK_MAX_SECONDS=\(largestGap)")
        #expect(largestGap < 0.25)
        #expect(renderedCount == 48)
        #expect(renderer.lastDiagnostic?.outcome == .committed)
    }

    private var denseItems: [BrowserOverlayItem] {
        (0..<48).map { index in
            BrowserOverlayItem(
                stableRegionID: UInt64(index),
                rect: CGRect(x: 12 + (index % 6) * 60, y: 30 + (index / 6) * 88, width: 50, height: 80),
                sourceText: "縦書きの台詞です", translatedText: "여러 말풍선이 겹치지 않도록 배치하는 번역 문장입니다.",
                confidence: 0.99, sourceOrientation: .vertical, sourceSingleVerticalColumn: false
            )
        }
    }
}
