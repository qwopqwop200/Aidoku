// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import Testing
import UIKit
import WebKit
@testable import Aidoku

@MainActor
private final class BrowserTestNavigationWaiter: NSObject,
    WKNavigationDelegate
{
    private var continuation: CheckedContinuation<Void, Never>?

    func load(
        url: URL,
        in webView: WKWebView
    ) async {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadFileURL(
                url,
                allowingReadAccessTo: url.deletingLastPathComponent()
            )
        }
    }

    func load(
        html: String,
        baseURL: URL? = nil,
        in webView: WKWebView
    ) async {
        webView.navigationDelegate = self
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            webView.loadHTMLString(html, baseURL: baseURL)
        }
    }

    func webView(
        _ webView: WKWebView,
        didFinish navigation: WKNavigation!
    ) {
        continuation?.resume()
        continuation = nil
    }
}

@Suite(.serialized)
struct ReaderOverlayEngineTests {
    @MainActor
    @Test func pageImageOverlayUsesSafeTextAndPageCoordinateRendering() {
        let script = BrowserPageImageOverlayRenderer.renderScript

        #expect(script.contains("node.textContent"))
        #expect(!script.contains("innerHTML"))
        #expect(script.contains("position: 'absolute'"))
        #expect(script.contains("scrollX"))
        #expect(script.contains("scrollY"))
        #expect(script.contains("writingMode"))
        #expect(script.contains("webkitTextSizeAdjust"))
        #expect(script.contains("data-aidoku-image-ocr-overlay"))
        #expect(!script.contains("item.callout"))
        #expect(!script.contains("'connector'"))
        #expect(!script.contains("'source-mask'"))
        #expect(script.contains("__aidokuImageOCROverlayRevision"))
        #expect(
            BrowserPageImageOverlayRenderer.clearScript.contains(
                "__aidokuImageOCROverlayRevision"
            )
        )
    }

    @MainActor
    @Test func pageImageDOMOverlayCommitsAtomicallyAndHonorsRevisions()
        async throws
    {
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let waiter = BrowserTestNavigationWaiter()
        await waiter.load(
            html: """
            <!doctype html><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;width:100%;height:100%;}</style>
            """,
            in: webView
        )
        let appearance: [String: Any] = [
            "opacity": 0.84,
            "minimumReadableFontSize": 5,
        ]
        func item(id: String, text: String) -> [String: Any] {
            [
                "id": id,
                "x": 20,
                "y": 30,
                "width": 180,
                "height": 54,
                "text": text,
                "vertical": false,
                "wrappingScript": "word",
                "fontScript": "word",
                "fontSize": 14,
                "lineHeight": 17,
                "paddingTop": 4,
                "paddingRight": 4,
                "paddingBottom": 4,
                "paddingLeft": 4,
                "lightSurface": true,
                "clipsText": false,
            ]
        }
        func execute(
            _ script: String,
            items: [[String: Any]]? = nil,
            revision: String
        ) async throws -> [String: Any] {
            var arguments: [String: Any] = ["revision": revision]
            if let items {
                arguments["items"] = items
                arguments["appearance"] = appearance
            }
            let raw = try await webView.callAsyncJavaScript(
                script,
                arguments: arguments,
                in: nil,
                contentWorld: ReaderTranslationDOM.contentWorld
            )
            return try #require(raw as? [String: Any])
        }
        func audit() async throws -> [String: Any] {
            let raw = try await webView.callAsyncJavaScript(
                """
                const root = document.querySelector(
                  '[data-aidoku-image-ocr-overlay="root"]'
                );
                return {
                  revision: root?.dataset.aidokuRevision || '',
                  text: root?.textContent || '',
                  itemCount: root?.childElementCount || 0,
                  measurementCount: document.querySelectorAll(
                    '[data-aidoku-image-ocr-overlay="measurement"]'
                  ).length,
                  watermark: String(
                    globalThis.__aidokuImageOCROverlayRevision ?? ''
                  )
                };
                """,
                arguments: [:],
                in: nil,
                contentWorld: ReaderTranslationDOM.contentWorld
            )
            return try #require(raw as? [String: Any])
        }

        let committed = try await execute(
            BrowserPageImageOverlayRenderer.renderScript,
            items: [item(id: "old", text: "previous overlay")],
            revision: "10"
        )
        #expect(committed["status"] as? String == "committed")
        #expect((committed["itemCount"] as? NSNumber)?.intValue == 1)

        var broken = item(id: "broken", text: "must never commit")
        broken["x"] = "not-a-number"
        var detachedBuildFailed = false
        do {
            _ = try await execute(
                BrowserPageImageOverlayRenderer.renderScript,
                items: [
                    item(id: "detached", text: "partially built"),
                    broken,
                ],
                revision: "11"
            )
        } catch {
            detachedBuildFailed = true
        }
        #expect(detachedBuildFailed)
        let afterFailure = try await audit()
        #expect(afterFailure["revision"] as? String == "10")
        #expect(afterFailure["text"] as? String == "previous overlay")
        #expect((afterFailure["itemCount"] as? NSNumber)?.intValue == 1)
        #expect((afterFailure["measurementCount"] as? NSNumber)?.intValue == 0)
        #expect(afterFailure["watermark"] as? String == "10")

        let staleRender = try await execute(
            BrowserPageImageOverlayRenderer.renderScript,
            items: [item(id: "stale", text: "stale overlay")],
            revision: "9"
        )
        #expect(staleRender["status"] as? String == "stale")
        let staleClear = try await execute(
            BrowserPageImageOverlayRenderer.clearScript,
            revision: "9"
        )
        #expect(staleClear["status"] as? String == "stale")
        let afterStaleOperations = try await audit()
        #expect(afterStaleOperations["revision"] as? String == "10")
        #expect(afterStaleOperations["text"] as? String == "previous overlay")

        let cleared = try await execute(
            BrowserPageImageOverlayRenderer.renderScript,
            items: [],
            revision: "12"
        )
        #expect(cleared["status"] as? String == "cleared")
        let afterClear = try await audit()
        #expect(afterClear["revision"] as? String == "")
        #expect((afterClear["itemCount"] as? NSNumber)?.intValue == 0)
        #expect(afterClear["watermark"] as? String == "12")
    }

    @MainActor
    @Test func pageImageDOMClearRemovesHigherRevisionFromPreviousSession()
        async throws
    {
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let waiter = BrowserTestNavigationWaiter()
        await waiter.load(
            html: """
            <!doctype html><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;width:100%;height:100%;}</style>
            """,
            in: webView
        )
        let oldItem: [String: Any] = [
            "id": "legacy-translation",
            "x": 20,
            "y": 30,
            "width": 180,
            "height": 54,
            "text": "이전 번역",
            "vertical": false,
            "wrappingScript": "korean",
            "fontScript": "korean",
            "fontSize": 14,
            "lineHeight": 17,
            "paddingTop": 4,
            "paddingRight": 4,
            "paddingBottom": 4,
            "paddingLeft": 4,
            "lightSurface": true,
            "clipsText": false,
        ]
        let oldRaw = try await webView.callAsyncJavaScript(
            BrowserPageImageOverlayRenderer.renderScript,
            arguments: [
                "items": [oldItem],
                "appearance": [
                    "opacity": 0.84,
                    "minimumReadableFontSize": 5,
                ],
                "revision": "400",
                "session": "previous-renderer",
            ],
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
        let oldResult = try #require(oldRaw as? [String: Any])
        #expect(oldResult["status"] as? String == "committed")

        // A newly created app/controller renderer starts its local revision at
        // one. The previous DOM used to win this comparison forever, leaving
        // its Korean translation visibly underneath the new native OCR card.
        let clearRaw = try await webView.callAsyncJavaScript(
            BrowserPageImageOverlayRenderer.clearScript,
            arguments: [
                "revision": "1",
                "session": "replacement-renderer",
            ],
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
        let clearResult = try #require(clearRaw as? [String: Any])
        #expect(clearResult["status"] as? String == "cleared")

        let auditRaw = try await webView.callAsyncJavaScript(
            """
            return {
              rootCount: document.querySelectorAll(
                '[data-aidoku-image-ocr-overlay="root"]'
              ).length,
              watermark: String(
                globalThis.__aidokuImageOCROverlayRevision ?? ''
              ),
              session: String(
                globalThis.__aidokuImageOCROverlaySession ?? ''
              )
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
        let audit = try #require(auditRaw as? [String: Any])
        #expect((audit["rootCount"] as? NSNumber)?.intValue == 0)
        #expect(audit["watermark"] as? String == "1")
        #expect(audit["session"] as? String == "replacement-renderer")
    }

    @MainActor
    @Test func pageImageDOMRendererPublishesContentFreeFailures() async {
        let sensitiveError = "translated-user-content-must-not-leak"
        let renderer = BrowserPageImageOverlayRenderer { _, _, _ in
            throw NSError(domain: sensitiveError, code: 77)
        }
        var callbackDiagnostic: BrowserPageImageOverlayDiagnostic?
        renderer.onDiagnostic = { callbackDiagnostic = $0 }
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let diagnostic = await withCheckedContinuation { continuation in
            renderer.render(
                on: webView,
                items: [],
                imageSize: CGSize(width: 390, height: 715),
                sourceRect: CGRect(x: 0, y: 0, width: 390, height: 715),
                settings: ReaderTranslationSettings.defaultOverlay,
                targetLanguage: "ko",
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(diagnostic.operation == .render)
        #expect(diagnostic.revision == 1)
        #expect(diagnostic.outcome == .failed(.javaScriptEvaluationFailed))
        #expect(diagnostic.renderedItemCount == 0)
        #expect(callbackDiagnostic == diagnostic)
        #expect(renderer.lastDiagnostic == diagnostic)
        #expect(!String(describing: diagnostic).contains(sensitiveError))
    }

    @MainActor
    @Test func pageImageDOMRendererRejectsMalformedJavaScriptResults() async {
        let renderer = BrowserPageImageOverlayRenderer { _, _, arguments in
            [
                "status": "committed",
                "revision": arguments["revision"] as? String ?? "",
                "itemCount": 0,
            ]
        }
        let webView = WKWebView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let diagnostic = await withCheckedContinuation { continuation in
            renderer.clear(
                on: webView,
                completion: { continuation.resume(returning: $0) }
            )
        }

        #expect(diagnostic.operation == .clear)
        #expect(diagnostic.revision == 1)
        #expect(diagnostic.outcome == .failed(.malformedJavaScriptResult))
        #expect(diagnostic.renderedItemCount == 0)
    }

    @MainActor
    @Test func pageImageDOMOverlayUsesExistingCollisionAwareCardLayout() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let sources = (0..<10).map { column in
            CGRect(
                x: 20 + CGFloat(column) * 34,
                y: 90,
                width: 20,
                height: 150
            )
        }
        let items = sources.enumerated().map { index, source in
            BrowserOverlayItem(
                stableRegionID: UInt64(index + 1),
                rect: source,
                sourceText: "縦書きの台詞です",
                translatedText:
                    "서로 겹치지 않는 번역 말풍선입니다 \(index + 1)",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        let viewport = CGSize(width: 390, height: 715)
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: viewport,
            sourceRect: CGRect(origin: .zero, size: viewport),
            settings: settings,
            targetLanguage: "ko",
            viewport: viewport
        )
        let cards = payload.compactMap { item -> CGRect? in
            guard let x = item["x"] as? CGFloat,
                  let y = item["y"] as? CGFloat,
                  let width = item["width"] as? CGFloat,
                  let height = item["height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        #expect(payload.count == items.count)
        #expect(cards.count == payload.count)
        #expect(Set(payload.compactMap { $0["id"] as? String }) == Set(
            items.compactMap(\.stableRegionID).map { String($0) }
        ))
        #expect(Set(payload.compactMap { $0["text"] as? String }) == Set(
            items.compactMap(\.translatedText)
        ))
        for (item, card) in zip(payload, cards) {
            let text = item["text"] as? String
            let vertical = item["vertical"] as? Bool
            let fontSize = item["fontSize"] as? CGFloat
            let lineHeight = item["lineHeight"] as? CGFloat
            let lightSurface = item["lightSurface"] as? Bool
            let clipsText = item["clipsText"] as? Bool
            let top = item["paddingTop"] as? CGFloat
            let left = item["paddingLeft"] as? CGFloat
            let bottom = item["paddingBottom"] as? CGFloat
            let right = item["paddingRight"] as? CGFloat

            #expect(items.compactMap(\.translatedText).contains(text ?? ""))
            #expect(text?.contains("\n") == false)
            #expect(vertical == false)
            #expect(lightSurface == true)
            #expect(clipsText == false)
            #expect(item["callout"] == nil)
            #expect((fontSize ?? 0) >= 5)
            #expect((lineHeight ?? 0) >= (fontSize ?? .infinity))
            #expect(CGRect(origin: .zero, size: viewport).contains(card))
            #expect(card.width < viewport.width / 2)
            #expect(card.height < viewport.height / 2)
            #expect(sources.contains { source in
                card.insetBy(dx: -0.5, dy: -0.5).contains(source)
            })
            if let text, let fontSize, let top, let left, let bottom,
               let right
            {
                #expect(BrowserOverlayDisplayVariant.plain(
                    text,
                    vertical: false
                ).fits(
                    available: CGSize(
                        width: card.width - left - right,
                        height: card.height - top - bottom
                    ),
                    fontSize: fontSize
                ))
            }
        }
        for left in cards.indices {
            for right in cards.indices where right > left {
                let overlap = cards[left].intersection(cards[right])
                #expect(
                    overlap.isNull || overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @MainActor
    @Test func koreanDialogueBalancesLinesWithoutChangingTextOrExplicitBreaks() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        let waiter = BrowserTestNavigationWaiter()
        await waiter.load(html: "<!doctype html><meta name=viewport content=width=device-width>", in: webView)
        // Real SPY dialogue geometry; test browser line layout, not just CSS serialization.
        let dialogue = "지금보다 훨씬 더 바쁘게 돌아다녀야 할 것 같아"
        let samples: [(String, String, Bool)] = [
            (dialogue, "korean", false),
            ("명시한 첫 줄\n명시한 다음 줄", "korean", false),
            ("명시한 첫 줄\r명시한 다음 줄", "korean", false),
            (String(repeating: "긴 문장은 그대로 유지한다. ", count: 20), "korean", false),
            ("An ordinary English caption.", "word", false),
            ("日本語の縦書き", "cjk", true),
            ("한국어 세로쓰기", "korean", true),
        ]
        let payload: [[String: Any]] = samples.enumerated().map { index, sample in
            ["id": String(index), "text": sample.0, "wrappingScript": sample.1,
             "fontScript": sample.1, "vertical": sample.2,
             "x": 10, "y": 10 + index * 100, "width": 51.55759162303667, "height": 69.93455497382206,
             "fontSize": 6.75, "lineHeight": 8.05517578125,
             "paddingTop": 4.84, "paddingRight": 4.84, "paddingBottom": 4.84, "paddingLeft": 4.84,
             "lightSurface": true, "clipsText": false]
        }
        _ = try await webView.callAsyncJavaScript(
            BrowserPageImageOverlayRenderer.renderScript,
            arguments: ["items": payload, "appearance": ["opacity": 0.84, "minimumReadableFontSize": 5], "revision": "1"],
            in: nil, contentWorld: ReaderTranslationDOM.contentWorld
        )
        let result = try await webView.callAsyncJavaScript("""
        await document.fonts.ready;
        const nodes = [...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')];
        const node = nodes[0];
        const widths = () => {
          const range = document.createRange(); range.selectNodeContents(node);
          return [...range.getClientRects()].filter(r => r.width > 0).map(r => r.width);
        };
        const balanced = widths();
        const styles = nodes.map(n => n.style.textWrap);
        const before = node.getBoundingClientRect();
        const font = getComputedStyle(node).fontSize;
        node.style.textWrap = 'wrap';
        const ordinary = widths();
        const after = node.getBoundingClientRect();
        return {styles, texts:nodes.map(n => n.textContent), balanced, ordinary,
          sameBox: before.x === after.x && before.y === after.y && before.width === after.width && before.height === after.height,
          sameFont: font === getComputedStyle(node).fontSize};
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let audit = try #require(result as? [String: Any])
        #expect(audit["styles"] as? [String] == ["balance", "wrap", "wrap", "wrap", "wrap", "wrap", "wrap"])
        #expect(audit["texts"] as? [String] == samples.map { $0.0 })
        #expect(audit["sameBox"] as? Bool == true)
        #expect(audit["sameFont"] as? Bool == true)
        let balanced = try #require(audit["balanced"] as? [Double])
        let ordinary = try #require(audit["ordinary"] as? [Double])
        #expect(balanced.count == ordinary.count && balanced.count > 1)
        func spread(_ values: [Double]) -> Double { (values.max() ?? 0) - (values.min() ?? 0) }
        #expect(spread(balanced) < spread(ordinary))
    }

    @MainActor
    @Test func pageImageDOMOverlayExecutesWithFivePointAttachedCards()
        async throws
    {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let viewport = CGSize(width: 390, height: 715)
        let items = (0..<10).map { column in
            BrowserOverlayItem(
                stableRegionID: UInt64(column + 1),
                rect: CGRect(
                    x: 20 + CGFloat(column) * 34,
                    y: 90,
                    width: 20,
                    height: 150
                ),
                sourceText: "縦書きの台詞です",
                translatedText:
                    "서로 겹치지 않는 번역 말풍선입니다 \(column + 1)",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: viewport,
            sourceRect: CGRect(origin: .zero, size: viewport),
            settings: settings,
            targetLanguage: "ko",
            viewport: viewport
        )
        #expect(payload.count == items.count)
        #expect(Set(payload.compactMap { $0["id"] as? String }) == Set(
            items.compactMap(\.stableRegionID).map { String($0) }
        ))
        #expect(Set(payload.compactMap { $0["text"] as? String }) == Set(
            items.compactMap(\.translatedText)
        ))

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: viewport)
        )
        let waiter = BrowserTestNavigationWaiter()
        await waiter.load(
            html: """
            <!doctype html><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;width:100%;height:100%;}</style>
            """,
            in: webView
        )
        _ = try await webView.callAsyncJavaScript(
            BrowserPageImageOverlayRenderer.renderScript,
            arguments: [
                "items": payload,
                "appearance": [
                    "opacity": settings.opacity,
                    "minimumReadableFontSize":
                        BrowserOverlayLayoutPlanner.minimumRenderedFontSize,
                ],
                "revision": "1",
            ],
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
        let rawAudit = try await webView.callAsyncJavaScript(
            """
            const selector = '[data-aidoku-image-ocr-overlay="item"]';
            const nodes = Array.from(document.querySelectorAll(selector));
            return {
              count: nodes.length,
              connectors: document.querySelectorAll(
                '[data-aidoku-image-ocr-overlay="connector"]'
              ).length,
              masks: document.querySelectorAll(
                '[data-aidoku-image-ocr-overlay="source-mask"]'
              ).length,
              cards: nodes.map(node => {
                const rect = node.getBoundingClientRect();
                const style = getComputedStyle(node);
                return {
                  x: rect.x, y: rect.y, width: rect.width,
                  height: rect.height,
                  fontSize: parseFloat(style.fontSize),
                  writingMode: style.writingMode,
                  borderRadius: style.borderRadius,
                  borderWidth: style.borderWidth,
                  boxShadow: style.boxShadow,
                  backgroundImage: style.backgroundImage,
                  textShadow: style.textShadow
                };
              })
            };
            """,
            arguments: [:],
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
        let audit = try #require(rawAudit as? [String: Any])
        #expect((audit["count"] as? NSNumber)?.intValue == payload.count)
        #expect((audit["connectors"] as? NSNumber)?.intValue == 0)
        #expect((audit["masks"] as? NSNumber)?.intValue == 0)
        let rendered = try #require(audit["cards"] as? [[String: Any]])
        let cards = try rendered.map { card -> CGRect in
            let x = try #require(card["x"] as? NSNumber)
            let y = try #require(card["y"] as? NSNumber)
            let width = try #require(card["width"] as? NSNumber)
            let height = try #require(card["height"] as? NSNumber)
            let fontSize = try #require(card["fontSize"] as? NSNumber)
            #expect(fontSize.doubleValue >= 5)
            #expect(card["writingMode"] as? String == "horizontal-tb")
            #expect(card["borderRadius"] as? String == "6px")
            #expect(card["borderWidth"] as? String == "0px")
            #expect(card["boxShadow"] as? String == "none")
            #expect(card["backgroundImage"] as? String != "none")
            #expect(card["textShadow"] as? String != "none")
            return CGRect(
                x: x.doubleValue,
                y: y.doubleValue,
                width: width.doubleValue,
                height: height.doubleValue
            )
        }
        for card in cards {
            #expect(card.width < viewport.width / 2)
            #expect(card.height < viewport.height / 2)
        }
        for left in cards.indices {
            for right in cards.indices where right > left {
                let overlap = cards[left].intersection(cards[right])
                #expect(
                    overlap.isNull || overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @MainActor
    @Test func pageImageDOMTranslateOnlyReplacesSourceWithTranslation()
        async throws
    {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let viewport = CGSize(width: 390, height: 715)
        let sourceText = "慣れないと……"
        let translationText = "익숙해지지 않으면……"

        func payload(translation: String?) -> [[String: Any]] {
            BrowserPageImageOverlayRenderer.layoutPayload(
                items: [BrowserOverlayItem(
                    stableRegionID: 901,
                    rect: CGRect(x: 40, y: 80, width: 180, height: 32),
                    sourceText: sourceText,
                    translatedText: translation,
                    confidence: 0.99,
                    sourceOrientation: .horizontal,
                    sourceSingleVerticalColumn: false
                )],
                imageSize: viewport,
                sourceRect: CGRect(origin: .zero, size: viewport),
                settings: settings,
                targetLanguage: "ko",
                viewport: viewport
            )
        }

        let sourcePayload = payload(translation: nil)
        let translatedPayload = payload(translation: translationText)
        let sourceItem = try #require(sourcePayload.first)
        let translatedItem = try #require(translatedPayload.first)
        #expect(sourcePayload.count == 1)
        #expect(translatedPayload.count == 1)
        #expect(sourceItem["id"] as? String == "901")
        #expect(translatedItem["id"] as? String == "901")
        #expect(sourceItem["text"] as? String == sourceText)
        #expect(translatedItem["text"] as? String == translationText)
        #expect(sourceItem["showsOriginalAndTranslation"] == nil)
        #expect(translatedItem["showsOriginalAndTranslation"] == nil)
        #expect(sourceItem["sourceText"] == nil)
        #expect(translatedItem["sourceText"] == nil)
        #expect(sourceItem["translationText"] == nil)
        #expect(translatedItem["translationText"] == nil)

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: viewport)
        )
        let waiter = BrowserTestNavigationWaiter()
        await waiter.load(
            html: """
            <!doctype html><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;width:100%;height:100%;}</style>
            """,
            in: webView
        )
        func renderAndAudit(
            _ items: [[String: Any]],
            revision: String
        ) async throws -> [String: Any] {
            _ = try await webView.callAsyncJavaScript(
                BrowserPageImageOverlayRenderer.renderScript,
                arguments: [
                    "items": items,
                    "appearance": [
                        "opacity": settings.opacity,
                        "minimumReadableFontSize":
                            BrowserOverlayLayoutPlanner.minimumRenderedFontSize,
                    ],
                    "revision": revision,
                ],
                in: nil,
                contentWorld: ReaderTranslationDOM.contentWorld
            )
            let raw = try await webView.callAsyncJavaScript(
                """
                const selector =
                  '[data-aidoku-image-ocr-overlay="item"]';
                const card = document.querySelector(selector);
                return {
                  count: document.querySelectorAll(selector).length,
                  region: card?.dataset.aidokuRegion || '',
                  text: card?.textContent || '',
                  sourceRoles: card?.querySelectorAll(
                    '[data-aidoku-overlay-role="source"]'
                  ).length || 0,
                  translationRoles: card?.querySelectorAll(
                    '[data-aidoku-overlay-role="translation"]'
                  ).length || 0
                };
                """,
                arguments: [:],
                in: nil,
                contentWorld: ReaderTranslationDOM.contentWorld
            )
            return try #require(raw as? [String: Any])
        }

        let sourceAudit = try await renderAndAudit(
            sourcePayload,
            revision: "1"
        )
        #expect((sourceAudit["count"] as? NSNumber)?.intValue == 1)
        #expect(sourceAudit["region"] as? String == "901")
        #expect(sourceAudit["text"] as? String == sourceText)
        #expect((sourceAudit["sourceRoles"] as? NSNumber)?.intValue == 0)
        #expect((sourceAudit["translationRoles"] as? NSNumber)?.intValue == 0)

        let translatedAudit = try await renderAndAudit(
            translatedPayload,
            revision: "2"
        )
        #expect((translatedAudit["count"] as? NSNumber)?.intValue == 1)
        #expect(translatedAudit["region"] as? String == "901")
        #expect(translatedAudit["text"] as? String == translationText)
        #expect(
            (translatedAudit["text"] as? String)?.contains(sourceText) == false
        )
        #expect((translatedAudit["sourceRoles"] as? NSNumber)?.intValue == 0)
        #expect(
            (translatedAudit["translationRoles"] as? NSNumber)?.intValue == 0
        )
    }

    @MainActor
    @Test func pageImageDOMSourceTextWrapsByWritingScriptInsideItsCard()
        async throws
    {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let viewport = CGSize(width: 390, height: 715)
        let fixtures: [(UInt64, CGRect, String, BrowserOCRSourceOrientation)] = [
            (
                931,
                CGRect(x: 20, y: 20, width: 70, height: 300),
                "慣れなくちゃいけないのにマリィさんに頼ってばかりじゃダメなのに",
                .vertical
            ),
            (
                932,
                CGRect(x: 120, y: 30, width: 240, height: 70),
                "Open the settings screen and choose the source language.",
                .vertical
            ),
            (
                933,
                CGRect(x: 120, y: 130, width: 240, height: 70),
                "설정 화면을 열고 원문 언어를 선택하세요.",
                .vertical
            ),
            (
                934,
                CGRect(x: 120, y: 230, width: 240, height: 70),
                "横書きの日本語も自然に折り返して表示します。",
                .horizontal
            ),
        ]
        let items = fixtures.map { id, rect, text, orientation in
            BrowserOverlayItem(
                stableRegionID: id,
                rect: rect,
                sourceText: text,
                translatedText: nil,
                confidence: 0.99,
                sourceOrientation: orientation,
                sourceSingleVerticalColumn: false
            )
        }
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: viewport,
            sourceRect: CGRect(origin: .zero, size: viewport),
            settings: settings,
            targetLanguage: "ko",
            viewport: viewport
        )
        let payloadByID = Dictionary(uniqueKeysWithValues: payload.compactMap {
            item -> (String, [String: Any])? in
            guard let id = item["id"] as? String else { return nil }
            return (id, item)
        })

        #expect(payload.count == fixtures.count)
        for fixture in fixtures {
            let item = try #require(payloadByID[String(fixture.0)])
            #expect(item["text"] as? String == fixture.2)
            #expect(!(item["text"] as? String ?? "").contains("\n"))
            #expect((item["fontSize"] as? CGFloat ?? 0) >= 5)
        }
        #expect(payloadByID["931"]?["vertical"] as? Bool == true)
        #expect(payloadByID["931"]?["wrappingScript"] as? String == "cjk")
        #expect(payloadByID["931"]?["fontScript"] as? String == "japanese")
        #expect(payloadByID["931"]?["clipsText"] as? Bool == true)
        #expect(payloadByID["932"]?["vertical"] as? Bool == false)
        #expect(payloadByID["932"]?["wrappingScript"] as? String == "word")
        #expect(payloadByID["932"]?["fontScript"] as? String == "word")
        #expect(payloadByID["933"]?["vertical"] as? Bool == false)
        #expect(payloadByID["933"]?["wrappingScript"] as? String == "korean")
        #expect(payloadByID["933"]?["fontScript"] as? String == "korean")
        #expect(payloadByID["934"]?["vertical"] as? Bool == false)
        #expect(payloadByID["934"]?["wrappingScript"] as? String == "cjk")
        #expect(payloadByID["934"]?["fontScript"] as? String == "japanese")

        let webView = WKWebView(
            frame: CGRect(origin: .zero, size: viewport)
        )
        let waiter = BrowserTestNavigationWaiter()
        await waiter.load(
            html: """
            <!doctype html><meta name="viewport" content="width=device-width">
            <style>html,body{margin:0;width:100%;height:100%;}</style>
            """,
            in: webView
        )
        _ = try await webView.callAsyncJavaScript(
            BrowserPageImageOverlayRenderer.renderScript,
            arguments: [
                "items": payload,
                "appearance": [
                    "opacity": settings.opacity,
                    "minimumReadableFontSize":
                        BrowserOverlayLayoutPlanner.minimumRenderedFontSize,
                ],
                "revision": "17",
            ],
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
        let rawAudit = try await webView.callAsyncJavaScript(
            """
            const selector =
              '[data-aidoku-image-ocr-overlay="item"]';
            return Array.from(document.querySelectorAll(selector)).map(node => {
              const style = getComputedStyle(node);
              return {
                id: node.dataset.aidokuRegion || '',
                text: node.textContent || '',
                writingMode: style.writingMode,
                overflow: style.overflow,
                wordBreak: style.wordBreak,
                lang: node.lang,
                fontFamily: style.fontFamily,
                fontSize: parseFloat(style.fontSize),
                clientWidth: node.clientWidth,
                scrollWidth: node.scrollWidth,
                clientHeight: node.clientHeight,
                scrollHeight: node.scrollHeight
              };
            });
            """,
            arguments: [:],
            in: nil,
            contentWorld: ReaderTranslationDOM.contentWorld
        )
        let rendered = try #require(rawAudit as? [[String: Any]])
        let renderedByID = Dictionary(uniqueKeysWithValues: rendered.compactMap {
            item -> (String, [String: Any])? in
            guard let id = item["id"] as? String else { return nil }
            return (id, item)
        })

        #expect(rendered.count == fixtures.count)
        for fixture in fixtures {
            let item = try #require(renderedByID[String(fixture.0)])
            #expect(item["text"] as? String == fixture.2)
            #expect((item["fontSize"] as? NSNumber)?.doubleValue ?? 0 >= 5)
            let clientWidth =
                (item["clientWidth"] as? NSNumber)?.doubleValue ?? 0
            let scrollWidth =
                (item["scrollWidth"] as? NSNumber)?.doubleValue ?? .infinity
            let clientHeight =
                (item["clientHeight"] as? NSNumber)?.doubleValue ?? 0
            let scrollHeight =
                (item["scrollHeight"] as? NSNumber)?.doubleValue ?? .infinity
            #expect(scrollWidth <= clientWidth + 1)
            #expect(scrollHeight <= clientHeight + 1)
        }
        #expect(renderedByID["931"]?["writingMode"] as? String == "vertical-rl")
        #expect(renderedByID["931"]?["overflow"] as? String == "hidden")
        #expect(renderedByID["931"]?["lang"] as? String == "ja")
        #expect(
            (renderedByID["931"]?["fontFamily"] as? String)?
                .contains("Hiragino Sans") == true
        )
        #expect(renderedByID["932"]?["writingMode"] as? String == "horizontal-tb")
        #expect(renderedByID["933"]?["writingMode"] as? String == "horizontal-tb")
        #expect(renderedByID["933"]?["wordBreak"] as? String == "keep-all")
        #expect(renderedByID["933"]?["lang"] as? String == "ko")
        #expect(
            (renderedByID["933"]?["fontFamily"] as? String)?
                .contains("Apple SD Gothic Neo") == true
        )
        #expect(renderedByID["934"]?["writingMode"] as? String == "horizontal-tb")
    }

    @Test func paddleOCRLineOrientationDecodeIsBackwardAndForwardTolerant()
        throws
    {
        let missing = try JSONDecoder().decode(
            PaddleOCRLine.self,
            from: Data(
                #"{"poly":[{"x":0,"y":0},{"x":10,"y":20}],"text":"縦","score":0.9}"#
                    .utf8
            )
        )
        #expect(missing.orientationRaw == nil)
        #expect(missing.sourceOrientation == .unknown)

        let vertical = try JSONDecoder().decode(
            PaddleOCRLine.self,
            from: Data(
                #"{"poly":[{"x":0,"y":0},{"x":10,"y":20}],"text":"縦","score":0.9,"orientation":"vertical"}"#
                    .utf8
            )
        )
        #expect(vertical.orientationRaw == "vertical")
        #expect(vertical.sourceOrientation == .vertical)

        let future = try JSONDecoder().decode(
            PaddleOCRLine.self,
            from: Data(
                #"{"poly":[{"x":0,"y":0},{"x":10,"y":20}],"text":"斜","score":0.9,"orientation":"diagonal"}"#
                    .utf8
            )
        )
        #expect(future.orientationRaw == "diagonal")
        #expect(future.sourceOrientation == .unknown)
    }

    @Test func sidePanelHistoryUpdatesRowsWithoutSourceOnlyReuse() {
        var history = BrowserSidePanelSessionHistory(maximumItems: 3)
        history.remember([
            .init(
                id: "ocr-0",
                item: overlayItem(
                    source: "同じ文字",
                    translation: "이전 번역"
                )
            ),
            .init(
                id: "ocr-1",
                item: overlayItem(
                    source: "次の文字",
                    translation: "다음 번역"
                )
            ),
        ])

        history.remember([
            .init(
                id: "ocr-0",
                item: overlayItem(
                    source: "同じ文字",
                    translation: nil
                )
            ),
        ])

        #expect(history.entries.map(\.id) == ["ocr-0", "ocr-1"])
        #expect(history.items[0].translatedText == nil)
        #expect(history.items[1].translatedText == "다음 번역")
    }

    @Test func sidePanelHistoryIsBoundedAndExplicitlyEphemeral() {
        var history = BrowserSidePanelSessionHistory(maximumItems: 2)
        history.remember((0..<4).map { index in
            .init(
                id: "ocr-\(index)",
                item: overlayItem(
                    source: "source-\(index)",
                    translation: "translation-\(index)"
                )
            )
        })

        #expect(history.entries.map(\.id) == ["ocr-2", "ocr-3"])
        history.removeAll()
        #expect(history.entries.isEmpty)

        var disabled = BrowserSidePanelSessionHistory(maximumItems: 0)
        disabled.remember([
            .init(
                id: "discarded",
                item: overlayItem(
                    source: "source",
                    translation: "translation"
                )
            ),
        ])
        #expect(disabled.entries.isEmpty)
    }

    @Test func sidePanelHistoryResetIsLimitedToSessionInvalidation() {
        #expect(
            !BrowserOCRInvalidationScope.display
                .clearsSidePanelSessionHistory
        )
        #expect(
            BrowserOCRInvalidationScope.session
                .clearsSidePanelSessionHistory
        )
    }

    @Test func verticalOverlayRequiresTallCJKText() {
        let tall = CGRect(x: 0, y: 0, width: 30, height: 120)
        #expect(BrowserOverlayTextFlow.usesVerticalLayout(
            rect: tall,
            texts: ["縦書き", "세로쓰기"]
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalLayout(
            rect: tall,
            texts: ["Vertical text", "세로쓰기"]
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalLayout(
            rect: CGRect(x: 0, y: 0, width: 120, height: 30),
            texts: ["縦書き"]
        ))
        #expect(
            BrowserOverlayTextFlow.verticalized("字幕") ==
                "字\n幕"
        )
    }

    @Test func explicitOCRSourceOrientationStillRespectsWritingScript() {
        let tall = CGRect(x: 0, y: 0, width: 30, height: 120)
        let wide = CGRect(x: 0, y: 0, width: 120, height: 30)
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: tall,
            text: "縦書き",
            sourceOrientation: .horizontal
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: wide,
            text: "Horizontal text",
            sourceOrientation: .vertical
        ))
        #expect(!BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: tall,
            text: "세로로 검출된 한국어",
            sourceOrientation: .vertical
        ))
        #expect(BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: wide,
            text: "縦書きの日本語",
            sourceOrientation: .vertical
        ))
        #expect(BrowserOverlayTextFlow.usesVerticalSourceLayout(
            rect: tall,
            text: "縦書き",
            sourceOrientation: .unknown
        ))
    }

    @Test func overlayWrappingScriptMatchesTheDisplayedLanguage() {
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "日本語の文章") ==
                .cjk
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "中文换行") == .cjk
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "한국어 줄바꿈") ==
                .korean
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "English wrapping") ==
                .word
        )
        #expect(
            BrowserOverlayTextFlow.wrappingScript(for: "مرحبا بالعالم") ==
                .rightToLeft
        )
    }

    @Test func overlayTextFlowDetectsRTLConservatively() {
        #expect(BrowserOverlayTextFlow.isRightToLeft("مرحبا بالعالم"))
        #expect(BrowserOverlayTextFlow.isRightToLeft("שלום"))
        #expect(!BrowserOverlayTextFlow.isRightToLeft("English text"))
        #expect(!BrowserOverlayTextFlow.isRightToLeft("日本語"))
        #expect(!BrowserOverlayTextFlow.isRightToLeft("English مرحبا"))
    }

    @Test func visibleItemsPublishOCRBeforeTranslation() {
        let sourceOnly = overlayItem(source: "原文", translation: nil)
        let blank = overlayItem(source: "空白", translation: "  \n")
        let translated = overlayItem(source: "翻訳", translation: "번역")

        let translateOnly = BrowserOverlayVisibility.visibleItems(
            [sourceOnly, blank, translated]
        )
        #expect(translateOnly.map(\.sourceText) == ["原文", "空白", "翻訳"])
        #expect(translateOnly.map(\.translatedText) == [nil, nil, "번역"])
        #expect(BrowserOverlayVisibility.visibleItems(
            [sourceOnly, translated]
        ) == [sourceOnly, translated])

    }

    @Test func koreanTranslationStaysHorizontalOnVerticalSource() {
        #expect(!BrowserOverlayTextFlow.translatedTextUsesVerticalLayout(
            sourceIsVertical: true,
            targetLanguage: "ko",
            text: "세로 문장을 인식합니다"
        ))
        #expect(BrowserOverlayTextFlow.translatedTextUsesVerticalLayout(
            sourceIsVertical: true,
            targetLanguage: "ja",
            text: "縦書きの翻訳"
        ))
    }

    @Test func singleLogicalLineRejectsEveryActualLineBreak() {
        #expect(BrowserOverlayTextFlow.isSingleLogicalLine("縦書き"))
        #expect(BrowserOverlayTextFlow.isSingleLogicalLine(" 세로 쓰기 "))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine("縦書き\n二列"))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine("縦書き\n"))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine("\n縦書き"))
        #expect(!BrowserOverlayTextFlow.isSingleLogicalLine(" \n "))
    }

    @Test @MainActor
    func pendingVerticalJapanesePreservesSourceWritingDirection() throws {
        let text = "どうしよ……ここで私が断って寄付が止んじゃったらしい"
        let item = BrowserOverlayItem(
            stableRegionID: 994,
            rect: CGRect(x: 220, y: 40, width: 28, height: 120),
            sourceText: text,
            translatedText: nil,
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )
        let content = BrowserOverlayCardContent.make(
            item: item,
            mode: .translateOnly,
            sourceVertical: true,
            translatedVertical: true
        )

        let verticalText = BrowserOverlayTextFlow.verticalized(text)
        #expect(content.displayed.displayText == verticalText)
        #expect(content.displayed.vertical)
        #expect(content.singleVerticalColumn)

        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let cards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        cards.first?.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(cards.count == 1)
        #expect(label.numberOfLines == 0)
        #expect(label.attributedText?.string == text)
        #expect(label.attributedText?.string.contains("\n") == false)
        #expect(label.attributedText?.attribute(
            BrowserOverlayVerticalTextRenderer.verticalFormsAttributeKey,
            at: 0,
            effectiveRange: nil
        ) as? Bool == true)
        let renderedFont = try #require(label.attributedText?.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? UIFont)
        let verticalSnapshot = BrowserOverlayVerticalTextRenderer.snapshot(
            text: text,
            bounds: label.bounds.inset(
                by: BrowserOverlayCardTextInsets.singleVerticalColumn
            ).size,
            fontSize: renderedFont.pointSize
        )
        #expect(verticalSnapshot.fits)
        #expect(verticalSnapshot.progressesRightToLeft)
        #expect(cards.first?.accessibilityLabel?.contains(text) == true)
        let baselinePayload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko",
            viewport: overlay.bounds.size
        )
        let baseline = try #require(baselinePayload.first)
        let baselineRect = CGRect(
            x: try #require(baseline["x"] as? CGFloat),
            y: try #require(baseline["y"] as? CGFloat),
            width: try #require(baseline["width"] as? CGFloat),
            height: try #require(baseline["height"] as? CGFloat)
        )
        #expect(cards.first?.frame == baselineRect)
        #expect(baseline["paddingTop"] as? CGFloat == 0.5)
        #expect(baseline["paddingLeft"] as? CGFloat == 0.5)
        #expect(baseline["paddingBottom"] as? CGFloat == 0.5)
        #expect(baseline["paddingRight"] as? CGFloat == 0.5)
    }

    @Test @MainActor
    func coreTextVerticalPainterUsesRawMixedOrientationText() throws {
        let text = "「縦書き。」…ABC"
        let attributed = BrowserOverlayVerticalTextRenderer.attributedString(
            text: text,
            fontSize: 16,
            weight: .heavy,
            foregroundColor: .label
        )

        #expect(attributed.string == text)
        #expect(!attributed.string.contains("\n"))
        #expect(attributed.attribute(
            BrowserOverlayVerticalTextRenderer.verticalFormsAttributeKey,
            at: 0,
            effectiveRange: nil
        ) as? Bool == true)
        let punctuationOffset = (text as NSString).range(of: "。").location
        #expect(attributed.attribute(
            BrowserOverlayVerticalTextRenderer.verticalFormsAttributeKey,
            at: punctuationOffset,
            effectiveRange: nil
        ) as? Bool == true)
        let paragraph = try #require(attributed.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        #expect(paragraph.alignment == .center)

        let snapshot = BrowserOverlayVerticalTextRenderer.snapshot(
            text: text,
            bounds: CGSize(width: 128, height: 52),
            fontSize: 16
        )
        #expect(snapshot.fits)
        #expect(snapshot.usesVerticalForms)
        #expect(snapshot.progressesRightToLeft)
        #expect(snapshot.lineOrigins.count >= 2)
        for pair in zip(
            snapshot.lineOrigins,
            snapshot.lineOrigins.dropFirst()
        ) {
            #expect(pair.0.x > pair.1.x)
        }
    }

    @Test @MainActor
    func narrowVerticalCoreTextInkNeverEscapesTheActualCard() throws {
        let source = "縦組みの表示検証です。長い文章でも文字がカードの外へ出ないことを確認します……"
        let item = BrowserOverlayItem(
            stableRegionID: 10_020,
            rect: CGRect(x: 180, y: 70, width: 20, height: 140),
            sourceText: source,
            translatedText: nil,
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: false
        )
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: card,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()
        let attributed = try #require(label.attributedText)
        let font = try #require(attributed.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? UIFont)
        let contentInsets = item.sourceSingleVerticalColumn == true
            ? BrowserOverlayCardTextInsets.singleVerticalColumn
            : BrowserOverlayCardTextInsets.regular
        let available = label.bounds.inset(by: contentInsets)
        let snapshot = BrowserOverlayVerticalTextRenderer.snapshot(
            text: source,
            bounds: available.size,
            fontSize: font.pointSize,
            weight: .heavy
        )

        #expect(card.frame == item.rect)
        #expect(label.clipsToBounds)
        #expect(font.pointSize >=
            BrowserOverlayLayoutPlanner.minimumRenderedFontSize)
        // c1 keeps the 5pt readability floor. If an adversarial source still
        // cannot fully fit, the explicit Core Text clip is the bounded fallback.
        #expect(snapshot.fits || abs(
            font.pointSize -
                BrowserOverlayLayoutPlanner.minimumRenderedFontSize
        ) < 0.01)
        if snapshot.fits {
            #expect(snapshot.availableBounds.insetBy(dx: -0.5, dy: -0.5)
                .contains(snapshot.paintedInkBounds))
        }
        let backdrop = try #require(replacementBackdrop(in: card))
        let surface = try #require(replacementSurface(in: card))
        #expect(!backdrop.isHidden)
        #expect(backdrop.effect is UIBlurEffect)
        #expect(abs((surface.backgroundColor?.cgColor.alpha ?? 0) - 0.9072) <
            0.001)

        // Isolate the actual card's text from its deliberately visible drop
        // shadow, surface, and border. The card itself remains unmasked, so a
        // Core Text column drawn outside its bounds is observable here.
        card.backgroundColor = .clear
        backdrop.effect = nil
        surface.backgroundColor = .clear
        card.layer.borderWidth = 0
        card.layer.shadowOpacity = 0
        let margin = 12
        let pixels = try #require(alphaPixelBounds(
            of: card,
            margin: margin
        ))
        let cardPixels = CGRect(
            x: CGFloat(margin),
            y: CGFloat(margin),
            width: ceil(card.bounds.width),
            height: ceil(card.bounds.height)
        ).insetBy(dx: -0.5, dy: -0.5)
        #expect(cardPixels.contains(pixels))
    }

    @Test @MainActor
    func verticalJapaneseSourceKeepsKoreanTranslationHorizontal() throws {
        let source = "縦書きの日本語です。"
        let translation = "세로 문장을 인식합니다."
        let item = BrowserOverlayItem(
            stableRegionID: 995,
            rect: CGRect(x: 220, y: 40, width: 28, height: 160),
            sourceText: source,
            translatedText: translation,
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: card,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(label.attributedText?.string == translation)
        #expect(label.attributedText?.attribute(
            BrowserOverlayVerticalTextRenderer.verticalFormsAttributeKey,
            at: 0,
            effectiveRange: nil
        ) == nil)
        #expect(displayedTextFits(label))
        #expect(card.accessibilityLabel?.contains(translation) == true)
        let payload = try #require(
            BrowserPageImageOverlayRenderer.layoutPayload(
                items: [item],
                imageSize: overlay.bounds.size,
                sourceRect: overlay.bounds,
                settings: settings,
                targetLanguage: "ko",
                viewport: overlay.bounds.size
            ).first
        )
        #expect(payload["vertical"] as? Bool == false)
    }

    @Test @MainActor
    func finalKoreanReplacementHasNoSourceRunAndMatchesC1Typography() throws {
        let source = "縦組みの合成原文を使って最終表示を検証します……"
        let translation = "가상의 세로 원문을 긴 한국어 문장으로 바꾸어도 읽기 좋게 줄을 나누어 표시하는지 확인합니다."
        let item = BrowserOverlayItem(
            stableRegionID: 10_021,
            rect: CGRect(x: 175, y: 70, width: 34, height: 280),
            sourceText: source,
            translatedText: translation,
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: false
        )
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        settings.fontSizing = .autoFit
        settings.colorMode = .white
        settings.opacity = 0.25
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: card,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()
        let attributed = try #require(label.attributedText)
        let font = try #require(attributed.attribute(
            .font,
            at: 0,
            effectiveRange: nil
        ) as? UIFont)
        let paragraph = try #require(attributed.attribute(
            .paragraphStyle,
            at: 0,
            effectiveRange: nil
        ) as? NSParagraphStyle)
        let payload = try #require(
            BrowserPageImageOverlayRenderer.layoutPayload(
                items: [item],
                imageSize: overlay.bounds.size,
                sourceRect: overlay.bounds,
                settings: settings,
                targetLanguage: "ko",
                viewport: overlay.bounds.size
            ).first
        )
        let payloadFontSize = try #require(payload["fontSize"] as? CGFloat)

        #expect(attributed.string == translation)
        #expect((attributed.string as NSString).range(of: source).location ==
            NSNotFound)
        var foregroundColors: [UIColor] = []
        attributed.enumerateAttribute(
            .foregroundColor,
            in: NSRange(location: 0, length: attributed.length)
        ) { value, _, _ in
            if let color = value as? UIColor,
               !foregroundColors.contains(where: { colorsMatch($0, color) })
            {
                foregroundColors.append(color)
            }
        }
        #expect(foregroundColors.count == 1)
        #expect(font.familyName == "Apple SD Gothic Neo")
        #expect(font.fontName == "AppleSDGothicNeo-Bold")
        #expect(font.pointSize <= payloadFontSize + 0.01)
        #expect(
            abs(font.pointSize - payloadFontSize) <= 0.01 ||
                abs(font.pointSize * 4 - round(font.pointSize * 4)) <= 0.01
        )
        let c1LineHeight = UIFont.systemFont(
            ofSize: font.pointSize,
            weight: .bold
        ).lineHeight
        #expect(abs(paragraph.minimumLineHeight - c1LineHeight) < 0.01)
        #expect(abs(paragraph.maximumLineHeight - c1LineHeight) < 0.01)
        #expect(displayedTextFits(
            label,
            contentInsets: UIEdgeInsets(
                top: try #require(payload["paddingTop"] as? CGFloat),
                left: try #require(payload["paddingLeft"] as? CGFloat),
                bottom: try #require(payload["paddingBottom"] as? CGFloat),
                right: try #require(payload["paddingRight"] as? CGFloat)
            )
        ))
        let backdrop = try #require(replacementBackdrop(in: card))
        let surface = try #require(replacementSurface(in: card))
        #expect(!backdrop.isHidden)
        #expect(backdrop.effect is UIBlurEffect)
        #expect(card.backgroundColor == .clear)
        #expect(abs((surface.backgroundColor?.cgColor.alpha ?? 0) - 0.565) <
            0.001)
        #expect(card.layer.masksToBounds == false)
        #expect(abs(card.layer.shadowOpacity - 0.26) < 0.001)
        #expect(abs(card.layer.shadowRadius - 3.5) < 0.001)
    }

    @Test @MainActor
    func horizontalFinalReplacementPreservesC1TextShadowOverhangPolicy()
        throws
    {
        let item = BrowserOverlayItem(
            stableRegionID: 10_022,
            rect: CGRect(x: 40, y: 90, width: 140, height: 36),
            sourceText: "設定画面を開いてください",
            translatedText: "설정 화면을 열어 주세요",
            confidence: 0.99,
            sourceOrientation: .horizontal
        )
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.colorMode = .dark
        settings.fontSizing = .autoFit
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: card,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()
        let attributed = try #require(label.attributedText)
        let textShadow = try #require(attributed.attribute(
            .shadow,
            at: 0,
            effectiveRange: nil
        ) as? NSShadow)
        let payload = try #require(
            BrowserPageImageOverlayRenderer.layoutPayload(
                items: [item],
                imageSize: overlay.bounds.size,
                sourceRect: overlay.bounds,
                settings: settings,
                targetLanguage: "ko",
                viewport: overlay.bounds.size
            ).first
        )

        #expect(payload["clipsText"] as? Bool == false)
        #expect(!label.clipsToBounds)
        #expect(!card.clipsToBounds)
        #expect(!card.layer.masksToBounds)
        #expect(textShadow.shadowOffset == CGSize(width: 0, height: 1))
        #expect(textShadow.shadowBlurRadius == 2)
        #expect(card.layer.shadowOpacity > 0)
    }

    @Test @MainActor
    func fiveCardC1TranslationFixtureHasFullFitAndNoOverlap() throws {
        let sourceRects = [
            CGRect(x: 28, y: 90, width: 22, height: 170),
            CGRect(x: 103, y: 82, width: 24, height: 220),
            CGRect(x: 178, y: 72, width: 34, height: 280),
            CGRect(x: 264, y: 80, width: 22, height: 220),
            CGRect(x: 338, y: 70, width: 24, height: 280),
        ]
        let sources = [
            "「短い縦組み例……一」",
            "「中くらいの縦組み検証文……二」",
            "「長い縦組み文章でも配置と折返しを安全に検証します……三」",
            "「別の縦組み検証文です……四」",
            "「最後の合成例……五」",
        ]
        let translations = [
            "짧은 번역 예시 하나……",
            "중간 길이 번역 예시 두 번째",
            "아주 긴 합성 번역 문장은 카드가 빽빽한 상황에서도 읽기 좋은 크기와 줄바꿈을 유지해야 합니다…… 세 번째",
            "다른 중간 길이 번역 예시 네 번째",
            "마지막 짧은 합성 예시……",
        ]
        let items = sourceRects.indices.map { index in
            BrowserOverlayItem(
                stableRegionID: UInt64(10_100 + index),
                rect: sourceRects[index],
                sourceText: sources[index],
                translatedText: translations[index],
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        settings.fontSizing = .autoFit
        settings.colorMode = .white
        settings.opacity = 0.25
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            items,
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let cards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko",
            viewport: overlay.bounds.size
        )
        let payloadByText = Dictionary(uniqueKeysWithValues: payload.compactMap {
            entry -> (String, [String: Any])? in
            guard let text = entry["text"] as? String else { return nil }
            return (text, entry)
        })
        let sourceByTranslation = Dictionary(
            uniqueKeysWithValues: zip(translations, sources)
        )

        #expect(cards.count == 5)
        #expect(payload.count == 5)
        var nativeFramesByText: [String: CGRect] = [:]
        for card in cards {
            card.layoutIfNeeded()
            let label = try #require(view(
                in: card,
                identifier: "aidoku.reader.overlay.item.text"
            ) as? UILabel)
            label.layoutIfNeeded()
            let attributed = try #require(label.attributedText)
            let translation = attributed.string
            let baseline = try #require(payloadByText[translation])
            let source = try #require(sourceByTranslation[translation])
            let baselineFrame = CGRect(
                x: try #require(baseline["x"] as? CGFloat),
                y: try #require(baseline["y"] as? CGFloat),
                width: try #require(baseline["width"] as? CGFloat),
                height: try #require(baseline["height"] as? CGFloat)
            )
            let insets = UIEdgeInsets(
                top: try #require(baseline["paddingTop"] as? CGFloat),
                left: try #require(baseline["paddingLeft"] as? CGFloat),
                bottom: try #require(baseline["paddingBottom"] as? CGFloat),
                right: try #require(baseline["paddingRight"] as? CGFloat)
            )
            let payloadFontSize = try #require(
                baseline["fontSize"] as? CGFloat
            )
            let font = try #require(attributed.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont)

            nativeFramesByText[translation] = card.frame
            #expect(card.frame == baselineFrame)
            #expect(overlay.bounds.contains(card.frame))
            #expect(attributed.string.contains(source) == false)
            #expect(font.familyName == "Apple SD Gothic Neo")
            #expect(font.fontName == "AppleSDGothicNeo-Bold")
            #expect(font.pointSize >= 5)
            #expect(font.pointSize <= payloadFontSize + 0.01)
            #expect(
                abs(font.pointSize - payloadFontSize) <= 0.01 ||
                    abs(font.pointSize * 4 - round(font.pointSize * 4)) <= 0.01
            )
            #expect(displayedTextFits(label, contentInsets: insets))
            let backdrop = try #require(replacementBackdrop(in: card))
            let surface = try #require(replacementSurface(in: card))
            #expect(!backdrop.isHidden)
            #expect(backdrop.effect is UIBlurEffect)
            #expect(abs((surface.backgroundColor?.cgColor.alpha ?? 0) - 0.565) <
                0.001)
            #expect(!label.clipsToBounds)
        }
        #expect(Set(nativeFramesByText.keys) == Set(translations))
        for left in cards.indices {
            for right in cards.indices where right > left {
                let overlap = cards[left].frame.intersection(
                    cards[right].frame
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test @MainActor
    func verticalDualLanguagePainterKeepsTheC1ComposedPayload() throws {
        let item = BrowserOverlayItem(
            stableRegionID: 996,
            rect: CGRect(x: 220, y: 40, width: 40, height: 160),
            sourceText: "縦書き原文",
            translatedText: "縦書き翻訳",
            confidence: 0.99,
            sourceOrientation: .vertical
        )
        let content = BrowserOverlayCardContent.make(
            item: item,
            mode: .originalAndTranslation,
            sourceVertical: true,
            translatedVertical: true
        )

        #expect(BrowserOverlayVerticalTextPainter.text(
            for: item,
            content: content,
            mode: .originalAndTranslation
        ) == content.displayed.displayText)
    }

    @Test @MainActor
    func siteFourRegionFixtureKeepsEveryNativeVerticalCard() throws {
        let imageSize = CGSize(width: 2_600, height: 1_950)
        let sourceRect = CGRect(x: 0, y: 190, width: 390, height: 292.5)
        let items = [
            BrowserOverlayItem(
                stableRegionID: 10_001,
                rect: CGRect(x: 465, y: 320, width: 95, height: 500),
                sourceText: "「はい……こんな痩せた体で良ければ……」",
                translatedText: nil,
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            ),
            BrowserOverlayItem(
                stableRegionID: 10_002,
                rect: CGRect(x: 2_000, y: 285, width: 105, height: 710),
                sourceText: "マリィさんが頑張ってくれてるのに私が何もしないなんて……",
                translatedText: nil,
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            ),
            BrowserOverlayItem(
                stableRegionID: 10_003,
                rect: CGRect(x: 2_208, y: 315, width: 74, height: 275),
                sourceText: "「ほら早くっ」",
                translatedText: nil,
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: true
            ),
            BrowserOverlayItem(
                stableRegionID: 10_004,
                rect: CGRect(x: 2_375, y: 285, width: 195, height: 875),
                sourceText: "どうしよ……ここで私が断ってもし寄付が止んじゃったりしたら……そしたらまたみんながお腹空かせちゃう……それに……こんなに沢山の金貨……",
                translatedText: nil,
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            ),
        ]
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            items,
            imageSize: imageSize,
            sourceRect: sourceRect,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let cards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: imageSize,
            sourceRect: sourceRect,
            settings: settings,
            targetLanguage: "ko",
            viewport: overlay.bounds.size
        )
        let payloadByText = Dictionary(uniqueKeysWithValues: payload.compactMap {
            entry -> (String, [String: Any])? in
            guard let text = entry["text"] as? String else { return nil }
            return (text, entry)
        })

        #expect(cards.count == 4)
        #expect(payload.count == 4)
        #expect(Set(payloadByText.keys) == Set(items.map(\.sourceText)))
        for card in cards {
            card.layoutIfNeeded()
            let label = try #require(view(
                in: card,
                identifier: "aidoku.reader.overlay.item.text"
            ) as? UILabel)
            label.layoutIfNeeded()
            let rawText = try #require(label.attributedText?.string)
            let baseline = try #require(payloadByText[rawText])
            let baselineFrame = CGRect(
                x: try #require(baseline["x"] as? CGFloat),
                y: try #require(baseline["y"] as? CGFloat),
                width: try #require(baseline["width"] as? CGFloat),
                height: try #require(baseline["height"] as? CGFloat)
            )
            let plannerInsets = UIEdgeInsets(
                top: try #require(baseline["paddingTop"] as? CGFloat),
                left: try #require(baseline["paddingLeft"] as? CGFloat),
                bottom: try #require(baseline["paddingBottom"] as? CGFloat),
                right: try #require(baseline["paddingRight"] as? CGFloat)
            )
            let renderedFont = try #require(label.attributedText?.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont)
            let sourceItem = try #require(items.first {
                $0.sourceText == rawText
            })
            let expectedPlannerInsets =
                sourceItem.sourceSingleVerticalColumn == true
                ? BrowserOverlayCardTextInsets.singleVerticalColumn
                : BrowserOverlayCardTextInsets.regular
            let snapshot = BrowserOverlayVerticalTextRenderer.snapshot(
                text: rawText,
                bounds: label.bounds.inset(
                    by: expectedPlannerInsets
                ).size,
                fontSize: renderedFont.pointSize
            )

            #expect(card.frame == baselineFrame)
            #expect(plannerInsets == expectedPlannerInsets)
            #expect(label.attributedText?.attribute(
                BrowserOverlayVerticalTextRenderer.verticalFormsAttributeKey,
                at: 0,
                effectiveRange: nil
            ) as? Bool == true)
            #expect(renderedFont.pointSize >=
                BrowserOverlayLayoutPlanner.minimumRenderedFontSize)
            #expect(
                snapshot.fits || abs(
                    renderedFont.pointSize -
                        BrowserOverlayLayoutPlanner.minimumRenderedFontSize
                ) < 0.01,
                "text=\(rawText) bounds=\(label.bounds.inset(by: expectedPlannerInsets).size) font=\(renderedFont.pointSize) frame=\(card.frame)"
            )
            #expect(snapshot.progressesRightToLeft)
            #expect(card.accessibilityLabel?.contains(rawText) == true)
        }
        for left in cards.indices {
            for right in cards.indices where right > left {
                let overlap = cards[left].frame.intersection(
                    cards[right].frame
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test func finalImageBoundaryDropsOnlyExactTextDuplicateLikeBaseline()
        throws
    {
        let items = [
            BrowserOverlayItem(
                stableRegionID: 100,
                rect: CGRect(x: 68, y: 104, width: 18, height: 119),
                sourceText: "どうしよ……ここで私が断って寄付が止んじゃったらしい",
                translatedText: nil,
                confidence: 0.96,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: true
            ),
            BrowserOverlayItem(
                stableRegionID: 101,
                rect: CGRect(x: 69, y: 105, width: 17, height: 117),
                sourceText: "どうしよ……ここで私が断って寄付が止んじゃったらしい",
                translatedText: nil,
                confidence: 0.94,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: true
            ),
        ]

        let result = BrowserImageSourceOverlayConsolidator.consolidate(items)
        let remaining = try #require(result.first)
        #expect(result.count == 1)
        #expect(remaining.sourceText ==
            "どうしよ……ここで私が断って寄付が止んじゃったらしい")
        #expect(remaining.rect == CGRect(x: 68, y: 104, width: 18, height: 119))
        #expect(remaining.stableRegionID == 100)
    }

    @Test func finalImageBoundaryOnlyTrimsAndCaseFoldsForDeduplication() {
        let rect = CGRect(x: 80, y: 120, width: 42, height: 96)
        func consolidatedCount(_ left: String, _ right: String) -> Int {
            BrowserImageSourceOverlayConsolidator.consolidate([
                BrowserOverlayItem(
                    stableRegionID: 1,
                    rect: rect,
                    sourceText: left,
                    translatedText: nil,
                    confidence: 0.99,
                    sourceOrientation: .vertical
                ),
                BrowserOverlayItem(
                    stableRegionID: 2,
                    rect: rect,
                    sourceText: right,
                    translatedText: nil,
                    confidence: 0.98,
                    sourceOrientation: .vertical
                ),
            ]).count
        }

        #expect(consolidatedCount(" \nAb C\t", "aB c") == 1)
        #expect(consolidatedCount("A B", "AB") == 2)
        #expect(consolidatedCount("縦\n書き", "縦書き") == 2)
        #expect(consolidatedCount("Ａ", "A") == 2)
    }

    @Test func finalImageBoundaryDoesNotInventVerticalJoin() {
        let result = BrowserImageSourceOverlayConsolidator.consolidate([
            BrowserOverlayItem(
                stableRegionID: 300,
                rect: CGRect(x: 338, y: 42, width: 34, height: 21),
                sourceText: "どう",
                translatedText: nil,
                confidence: 0.98,
                sourceOrientation: .horizontal,
                sourceSingleVerticalColumn: false
            ),
            BrowserOverlayItem(
                stableRegionID: 301,
                rect: CGRect(x: 339, y: 55, width: 31, height: 112),
                sourceText: "しよ……ここで私が断って寄付が止んじゃったらしい",
                translatedText: nil,
                confidence: 0.96,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: true
            ),
        ])

        #expect(result.count == 2)
    }

    @Test func finalImageBoundaryKeepsNeighboringVerticalColumnsSeparate() {
        let result = BrowserImageSourceOverlayConsolidator.consolidate([
            BrowserOverlayItem(
                rect: CGRect(x: 40, y: 100, width: 16, height: 90),
                sourceText: "右の文章",
                translatedText: nil,
                confidence: 0.95,
                sourceOrientation: .vertical
            ),
            BrowserOverlayItem(
                rect: CGRect(x: 66, y: 101, width: 16, height: 90),
                sourceText: "左の文章",
                translatedText: nil,
                confidence: 0.95,
                sourceOrientation: .vertical
            ),
        ])

        #expect(result.count == 2)
    }

    @Test func finalImageBoundaryPreservesDifferentContainedText() {
        let full = BrowserOverlayItem(
            stableRegionID: 200,
            rect: CGRect(x: 274, y: 96, width: 38, height: 104),
            sourceText: "イさが頑張ってくれてるのに何もしないなんて",
            translatedText: nil,
            confidence: 0.91,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )
        let contained = BrowserOverlayItem(
            stableRegionID: 201,
            rect: CGRect(x: 294, y: 124, width: 17, height: 70),
            sourceText: "何もしないなんて",
            translatedText: nil,
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )

        let result = BrowserImageSourceOverlayConsolidator.consolidate([
            contained, full,
        ])
        #expect(result.count == 2)
    }

    @Test func wrappedEnglishLinesBecomeOnePresentationCard() throws {
        let groups = BrowserOverlayPresentationGrouper.groups([
            presentationSegment(
                rect: CGRect(x: 210, y: 100, width: 128, height: 24),
                source: "設定画面を開いて",
                translation: "Open the"
            ),
            presentationSegment(
                rect: CGRect(x: 210, y: 128, width: 118, height: 24),
                source: "設定を",
                translation: "settings"
            ),
            presentationSegment(
                rect: CGRect(x: 210, y: 156, width: 108, height: 24),
                source: "開いてください",
                translation: "screen."
            ),
        ])

        let group = try #require(groups.first)
        #expect(groups.count == 1)
        #expect(group.segments.count == 3)
        #expect(group.overlayItem.translatedText == "Open the settings screen.")
    }

    @Test func overlappingContainedPriceDuplicateKeepsOneFullLabel() throws {
        let full = presentationSegment(
            rect: CGRect(x: 210, y: 500, width: 142, height: 40),
            source: "価格 12,345円",
            translation: "가격 12,345엔"
        )
        let contained = presentationSegment(
            rect: CGRect(x: 226, y: 508, width: 104, height: 24),
            source: "12,345円",
            translation: "12,345엔"
        )

        let unique = BrowserOverlayPresentationDeduplicator.deduplicate([
            contained,
            full,
        ])
        let remaining = try #require(unique.first)
        #expect(unique.count == 1)
        #expect(remaining.sourceText == "価格 12,345円")
        #expect(remaining.translatedText == "가격 12,345엔")
    }

    @Test @MainActor
    func browserOverlayHidesRoutineStatusUntilAnErrorNeedsAttention() throws {
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let container = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.status.container"
        ))
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.status"
        ) as? UILabel)

        #expect(container.isHidden)
        #expect(label.text == nil)

        overlay.showStatus("OCR failed", isError: true)
        #expect(!container.isHidden)
        #expect(label.text == "OCR failed")

        overlay.hideStatus()
        #expect(container.isHidden)
        #expect(label.text == nil)
    }

    @Test func overlappingDistinctPricePartsAreNotDeduplicated() {
        let label = presentationSegment(
            rect: CGRect(x: 210, y: 500, width: 80, height: 30),
            source: "価格",
            translation: "가격"
        )
        let amount = presentationSegment(
            rect: CGRect(x: 230, y: 500, width: 122, height: 30),
            source: "12,345円",
            translation: "12,345엔"
        )
        let confidence = presentationSegment(
            rect: CGRect(x: 260, y: 500, width: 70, height: 30),
            source: "95%",
            translation: "95%"
        )

        let unique = BrowserOverlayPresentationDeduplicator.deduplicate([
            label,
            amount,
            confidence,
        ])
        #expect(unique.count == 3)
    }

    @Test func narrowVerticalSourceGetsReadableHorizontalKoreanCard() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        let source = CGRect(x: 220, y: 80, width: 24, height: 150)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: "세로 문장을 인식합니다",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: [],
            sourceVertical: true
        )

        #expect(
            plan.maximumFontSize >=
                BrowserOverlayLayoutPlanner.minimumReadableHorizontalFontSize
        )
        #expect(
            plan.rect.width - plan.contentInsets.left -
                plan.contentInsets.right >=
                plan.maximumFontSize * 6
        )
        #expect(plan.rect.minX <= source.minX)
        #expect(plan.rect.maxX >= source.maxX)
        #expect(plan.rect.minY <= source.minY)
        #expect(plan.rect.maxY >= source.maxY)
    }

    @Test func sourceBoundsPolicyKeepsUnreadableTranslationAnchored() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .autoFit
        settings.expansionPolicy = .sourceBounds
        let source = CGRect(x: 220, y: 80, width: 24, height: 150)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: String(repeating: "세로문장을인식합니다", count: 40),
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: [],
            sourceVertical: true
        )

        #expect(!plan.rect.isNull)
        #expect(plan.rect == source)
        #expect(CGRect(x: 0, y: 0, width: 390, height: 715).contains(
            plan.rect
        ))
    }

    @Test func unrestrictedPolicyCanUseTheFullReadableEnvelope() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .autoFit
        settings.expansionPolicy = .unrestricted
        let source = CGRect(x: 220, y: 80, width: 24, height: 150)
        let text = "세로문장을인식하고자유롭게확장합니다"
        let unrestricted = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: text,
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: [],
            sourceVertical: true
        )
        settings.expansionPolicy = .panelConstrained
        let constrained = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: text,
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: [],
            sourceVertical: true
        )

        #expect(unrestricted.rect.width > constrained.rect.width)
        #expect(
            constrained.maximumFontSize >=
                BrowserOverlayLayoutPlanner.minimumReadableHorizontalFontSize
        )
        #expect(
            constrained.rect.width - constrained.contentInsets.left -
                constrained.contentInsets.right >=
                constrained.maximumFontSize * 6
        )
        #expect(
            unrestricted.maximumFontSize == constrained.maximumFontSize
        )
    }

    @Test func readableReplacementKeepsTheExactSourceRect() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        let source = CGRect(x: 24, y: 90, width: 132, height: 32)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: "설정 화면을",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(
            plan.maximumFontSize >=
                BrowserOverlayLayoutPlanner.minimumAutoFontSize
        )
        #expect(plan.rect == source)
    }

    @Test func denseTwoColumnReplacementsDoNotExpandAcrossEachOther() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        let sources = [
            CGRect(x: 20, y: 100, width: 142, height: 32),
            CGRect(x: 180, y: 100, width: 142, height: 32),
            CGRect(x: 20, y: 142, width: 142, height: 32),
            CGRect(x: 180, y: 142, width: 142, height: 32),
        ]
        let translations = [
            "설정 화면을",
            "번역 화면을",
            "자막을 표시합니다",
            "작은 글자와 대비",
        ]
        var occupied: [CGRect] = []
        var plans: [BrowserOverlayCardLayout] = []

        for (index, source) in sources.enumerated() {
            let plan = BrowserOverlayLayoutPlanner.plan(
                source: source,
                text: translations[index],
                vertical: false,
                settings: settings,
                viewport: CGSize(width: 390, height: 715),
                occupied: occupied,
                reservedSources: sources.enumerated().compactMap {
                    otherIndex, rect in
                    otherIndex == index ? nil : rect
                }
            )
            plans.append(plan)
            occupied.append(plan.rect)
        }

        #expect(plans.map(\.rect) == sources)
        for left in plans.indices {
            for right in plans.indices where right > left {
                #expect(
                    plans[left].rect.intersection(plans[right].rect).isNull
                )
            }
        }
    }

    @Test func largerConstrainedCardClaimsSpaceBeforeSmallerNeighbor() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .fixed
        settings.fixedFontSizePoints = 14
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let viewport = CGSize(width: 210, height: 400)
        let sources = [
            CGRect(x: 110, y: 80, width: 20, height: 100),
            CGRect(x: 145, y: 60, width: 20, height: 280),
        ]
        let variants = [
            BrowserOverlayDisplayVariant.plain("응…… 네……", vertical: false),
            BrowserOverlayDisplayVariant.plain(
                "그만 먹고 쓴 돈이니까 즐겁게 해줘야 한다?",
                vertical: false
            ),
        ]
        let intrinsic = [
            BrowserOverlayCardLayout(
                rect: CGRect(x: 50, y: 60, width: 90, height: 140),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 130, y: 20, width: 75, height: 350),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
        ]

        func plans(in order: [Int]) -> [BrowserOverlayCardLayout] {
            var occupied: [CGRect] = []
            var result = intrinsic
            for index in order {
                let plan = BrowserOverlayLayoutPlanner.resolvePositionedLayout(
                    intrinsic[index],
                    source: sources[index],
                    variants: [variants[index]],
                    settings: settings,
                    viewport: viewport,
                    occupied: occupied,
                    sourceVertical: false,
                    singleVerticalColumn: false,
                    reservedSources: sources.enumerated().compactMap {
                        otherIndex, rect in
                        otherIndex == index ? nil : rect
                    }
                )
                result[index] = plan
                occupied.append(plan.rect)
            }
            return result
        }

        let packingOrder = BrowserOverlayLayoutPlanner.packingOrder(intrinsic)
        let packedPlans = plans(in: packingOrder)

        #expect(packingOrder == [1, 0])
        let overlap = packedPlans[0].rect.intersection(packedPlans[1].rect)
        #expect(
            overlap.isNull || overlap.width <= 0.25 || overlap.height <= 0.25
        )
        #expect(packedPlans[0].rect.minX == 40)
        #expect(packedPlans[1].rect.minX == 130)
        #expect(packedPlans[0].rect.size == intrinsic[0].rect.size)
        #expect(packedPlans[1].rect.size == intrinsic[1].rect.size)
        #expect(packedPlans[0].rect.contains(sources[0]))
        #expect(packedPlans[1].rect.contains(sources[1]))
    }

    @Test func fourCardClusterReflowsAfterGreedyOverlapWhenSpaceExists() {
        let viewport = CGSize(width: 470, height: 450)
        let sources = [
            CGRect(x: 70, y: 70, width: 20, height: 60),
            CGRect(x: 180, y: 100, width: 20, height: 240),
            CGRect(x: 270, y: 90, width: 20, height: 220),
            CGRect(x: 370, y: 100, width: 20, height: 250),
        ]
        let intrinsic = [
            BrowserOverlayCardLayout(
                rect: CGRect(x: 25, y: 50, width: 105, height: 105),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 133, y: 50, width: 110, height: 374),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 241, y: 50, width: 88, height: 310),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
            BrowserOverlayCardLayout(
                rect: CGRect(x: 306, y: 50, width: 139, height: 349),
                maximumFontSize: 14,
                contentInsets: .zero
            ),
        ]

        func positiveOverlapArea(
            _ layouts: [BrowserOverlayCardLayout]
        ) -> CGFloat {
            var area: CGFloat = 0
            for left in layouts.indices {
                for right in layouts.indices where right > left {
                    let overlap = layouts[left].rect.intersection(
                        layouts[right].rect
                    )
                    if !overlap.isNull,
                       overlap.width > 0.25,
                       overlap.height > 0.25
                    {
                        area += overlap.width * overlap.height
                    }
                }
            }
            return area
        }

        let initialArea = positiveOverlapArea(intrinsic)
        let relaxedPlans = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            intrinsic,
            sources: sources,
            viewport: viewport
        )

        #expect(initialArea > 0.25)
        #expect(positiveOverlapArea(relaxedPlans) <= 0.25)
        for index in relaxedPlans.indices {
            #expect(relaxedPlans[index].rect.size == intrinsic[index].rect.size)
            #expect(relaxedPlans[index].rect.contains(sources[index]))
            #expect(CGRect(origin: .zero, size: viewport).contains(
                relaxedPlans[index].rect
            ))
        }
    }

    @Test @MainActor
    func denseMangaColumnsContractUntilRenderedCardsDoNotOverlap() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let sources = (0..<10).map { column in
            CGRect(
                x: 20 + CGFloat(column) * 34,
                y: 90,
                width: 20,
                height: 150
            )
        }
        let items = sources.enumerated().map { index, source in
            BrowserOverlayItem(
                stableRegionID: UInt64(index + 1),
                rect: source,
                sourceText: "縦書きの台詞です",
                translatedText:
                    "서로 겹치지 않는 번역 말풍선입니다 \(index + 1)",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            items,
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let cards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).sorted { $0.frame.minX < $1.frame.minX }
        let baselinePayload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko",
            viewport: overlay.bounds.size
        )

        #expect(cards.count == items.count)
        var renderedTexts = Set<String>()
        for card in cards {
            card.layoutIfNeeded()
            #expect(overlay.bounds.contains(card.frame))
            let label = try #require(view(
                in: card,
                identifier: "aidoku.reader.overlay.item.text"
            ) as? UILabel)
            label.layoutIfNeeded()
            let renderedFont = try #require(
                label.attributedText?.attribute(
                    .font,
                    at: 0,
                    effectiveRange: nil
                ) as? UIFont
            )
            #expect(renderedFont.pointSize >= 5)
            #expect(label.attributedText?.string.contains("\n") == false)
            if let text = label.attributedText?.string {
                renderedTexts.insert(text)
            }
            #expect(displayedTextFits(label))
            #expect(card.frame.width < overlay.bounds.width / 2)
            #expect(card.frame.height < overlay.bounds.height / 2)
            #expect(sources.contains { source in
                card.frame.insetBy(dx: -0.5, dy: -0.5).contains(source)
            })
        }
        #expect(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.source-mask"
        ).isEmpty)
        for left in cards.indices {
            for right in cards.indices where right > left {
                let overlap = cards[left].frame.intersection(
                    cards[right].frame
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
        #expect(renderedTexts == Set(items.compactMap(\.translatedText)))
        let nativeFramesByText = Dictionary(uniqueKeysWithValues: cards.compactMap {
            card -> (String, CGRect)? in
            guard let label = view(
                in: card,
                identifier: "aidoku.reader.overlay.item.text"
            ) as? UILabel, let text = label.attributedText?.string else {
                return nil
            }
            return (text, card.frame)
        })
        for payload in baselinePayload {
            guard let text = payload["text"] as? String,
                  let x = payload["x"] as? CGFloat,
                  let y = payload["y"] as? CGFloat,
                  let width = payload["width"] as? CGFloat,
                  let height = payload["height"] as? CGFloat
            else {
                Issue.record("malformed baseline layout payload")
                continue
            }
            let expected = CGRect(
                x: x, y: y, width: width, height: height
            )
            let actual = try #require(nativeFramesByText[text])
            #expect(abs(actual.minX - expected.minX) < 0.001)
            #expect(abs(actual.minY - expected.minY) < 0.001)
            #expect(abs(actual.width - expected.width) < 0.001)
            #expect(abs(actual.height - expected.height) < 0.001)
        }
    }

    @Test @MainActor
    func overlappingTranslatedSourceBoxesDetachIntoNearbyClearSpace()
        throws
    {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let sources = (0..<4).map { index in
            CGRect(
                x: 180 + CGFloat(index) * 6,
                y: 100,
                width: 20,
                height: 150
            )
        }
        let items = sources.enumerated().map { index, source in
            BrowserOverlayItem(
                stableRegionID: UInt64(920 + index),
                rect: source,
                sourceText: "原文\(index + 1)",
                translatedText: "번역 \(index + 1)",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        let expectedTranslationToSource = Dictionary(uniqueKeysWithValues:
            items.enumerated().map { index, item in
                (
                    item.translatedText ?? "",
                    sources[index]
                )
            }
        )
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            items,
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let cards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )

        #expect(cards.count == items.count)
        #expect(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.source-mask"
        ) == nil)
        var renderedTexts = Set<String>()
        var cardCenters: [CGPoint] = []
        var movedCardCount = 0
        for card in cards {
            card.layoutIfNeeded()
            let label = try #require(view(
                in: card,
                identifier: "aidoku.reader.overlay.item.text"
            ) as? UILabel)
            label.layoutIfNeeded()
            let text = try #require(label.attributedText?.string)
            let source = try #require(expectedTranslationToSource[text])
            renderedTexts.insert(text)
            #expect(overlay.bounds.contains(card.frame))
            #expect(!items.map(\.sourceText).contains(text))
            let displacement = hypot(
                card.frame.midX - source.midX,
                card.frame.midY - source.midY
            )
            #expect(displacement <= 72.5)
            if displacement > 1 {
                movedCardCount += 1
            }
            cardCenters.append(CGPoint(
                x: card.frame.midX,
                y: card.frame.midY
            ))
        }
        for left in cards.indices {
            for right in cards.indices where right > left {
                let overlap = cards[left].frame.intersection(
                    cards[right].frame
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
        let sourceCentroidX = sources.reduce(CGFloat.zero) {
            $0 + $1.midX
        } / CGFloat(sources.count)
        let cardCentroidX = cardCenters.reduce(CGFloat.zero) {
            $0 + $1.x
        } / CGFloat(cardCenters.count)
        #expect(movedCardCount >= 3)
        #expect(abs(cardCentroidX - sourceCentroidX) <= 4)
        #expect(renderedTexts == Set(expectedTranslationToSource.keys))

        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko",
            viewport: overlay.bounds.size
        )
        let payloadFrames = payload.compactMap { item -> CGRect? in
            guard let x = item["x"] as? CGFloat,
                  let y = item["y"] as? CGFloat,
                  let width = item["width"] as? CGFloat,
                  let height = item["height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        #expect(payloadFrames.count == items.count)
        #expect(payload.allSatisfy { $0["maskX"] == nil })
        for left in payloadFrames.indices {
            for right in payloadFrames.indices where right > left {
                let overlap = payloadFrames[left].intersection(
                    payloadFrames[right]
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test @MainActor
    func detachedTranslationsStayInsideOffsetSourceImage() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        settings.expansionPolicy = .panelConstrained
        let imageSize = CGSize(width: 300, height: 450)
        let sourceRect = CGRect(x: 35, y: 360, width: 300, height: 450)
        let items = (0..<4).map { index in
            BrowserOverlayItem(
                stableRegionID: UInt64(960 + index),
                rect: CGRect(
                    x: 160 + CGFloat(index) * 6,
                    y: 50,
                    width: 20,
                    height: 150
                ),
                sourceText: "原文\(index + 1)",
                translatedText: "번역 \(index + 1)",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }

        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: imageSize,
            sourceRect: sourceRect,
            settings: settings,
            targetLanguage: "ko",
            viewport: CGSize(width: 390, height: 844)
        )
        let frames = payload.compactMap { item -> CGRect? in
            guard let x = item["x"] as? CGFloat,
                  let y = item["y"] as? CGFloat,
                  let width = item["width"] as? CGFloat,
                  let height = item["height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }

        #expect(frames.count == items.count)
        for frame in frames {
            #expect(sourceRect.contains(frame))
        }
        for left in frames.indices {
            for right in frames.indices where right > left {
                let overlap = frames[left].intersection(frames[right])
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func jointPackingLimitsTheWorstIndividualCardTravel() {
        let sourceRects = (0..<4).map { index in
            CGRect(
                x: 220 + CGFloat(index) * 6,
                y: 100,
                width: 46,
                height: 120
            )
        }
        let layouts = sourceRects.map { source in
            BrowserOverlayCardLayout(
                rect: source,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sourceRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 35, y: 80, width: 300, height: 180),
            allowsDetachedPlacements: Array(repeating: true, count: 4)
        )

        #expect(packed.count == layouts.count)
        for left in packed.indices {
            let dx = packed[left].rect.midX - layouts[left].rect.midX
            let dy = packed[left].rect.midY - layouts[left].rect.midY
            #expect(hypot(dx, dy) <= 75)
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func adjacentCardsShiftTogetherInsteadOfEjectingTheLastCard() {
        let xPositions: [CGFloat] = [100, 142, 184, 226, 250]
        let sourceRects = xPositions.map { x in
            CGRect(x: x, y: 100, width: 40, height: 120)
        }
        let layouts = sourceRects.map { source in
            BrowserOverlayCardLayout(
                rect: source,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sourceRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 80, y: 80, width: 216, height: 180),
            allowsDetachedPlacements: Array(repeating: true, count: 5)
        )

        var movedCards = 0
        for left in packed.indices {
            let dx = packed[left].rect.midX - layouts[left].rect.midX
            let dy = packed[left].rect.midY - layouts[left].rect.midY
            if hypot(dx, dy) > 1 { movedCards += 1 }
            #expect(hypot(dx, dy) <= 22)
            #expect(abs(dy) <= 1)
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
        #expect(movedCards >= 4)
    }

    @Test
    func jointPackingNeverKeepsAnOverlapAtTheFormerTravelLimit() {
        let sourceRects = [
            CGRect(x: 110, y: 80, width: 104, height: 180),
            CGRect(x: 138, y: 96, width: 48, height: 70),
            CGRect(x: 216, y: 80, width: 58, height: 180),
        ]
        let layouts = sourceRects.map { source in
            BrowserOverlayCardLayout(
                rect: source,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sourceRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 40, y: 40, width: 310, height: 240),
            allowsDetachedPlacements: Array(repeating: true, count: 3)
        )

        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func jointPackingReplacesAnAlreadyScatteredGreedyLayout() {
        let preferredRects = (0..<4).map { index in
            CGRect(
                x: 180 + CGFloat(index) * 6,
                y: 100,
                width: 40,
                height: 120
            )
        }
        let scatteredRects = (0..<4).map { index in
            CGRect(
                x: 40 + CGFloat(index) * 70,
                y: 100,
                width: 40,
                height: 120
            )
        }
        let layouts = scatteredRects.map { rect in
            BrowserOverlayCardLayout(
                rect: rect,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: preferredRects,
            viewport: CGSize(width: 390, height: 300),
            placementBounds: CGRect(x: 20, y: 40, width: 350, height: 240),
            preferredRects: preferredRects,
            allowsDetachedPlacements: Array(repeating: true, count: 4)
        )

        let ordered = packed.map(\.rect).sorted { $0.minX < $1.minX }
        for index in ordered.indices.dropFirst() {
            #expect(ordered[index].minX - ordered[index - 1].maxX <= 2.25)
        }
        let sourceCentroid = CGPoint(
            x: preferredRects.reduce(CGFloat.zero) { $0 + $1.midX } / 4,
            y: preferredRects.reduce(CGFloat.zero) { $0 + $1.midY } / 4
        )
        let packedCentroid = CGPoint(
            x: packed.reduce(CGFloat.zero) { $0 + $1.rect.midX } / 4,
            y: packed.reduce(CGFloat.zero) { $0 + $1.rect.midY } / 4
        )
        #expect(abs(packedCentroid.x - sourceCentroid.x) <= 4)
        #expect(abs(packedCentroid.y - sourceCentroid.y) <= 4)
        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func sitePageNineUsesDynamicNeighborSlotsForShorterChainShift() {
        let sources = [
            CGRect(x: 258.5635, y: 57.9889, width: 20.1563, height: 99.0474),
            CGRect(x: 301.0433, y: 58.6391, width: 10.1865, height: 38.1452),
            CGRect(x: 341.3558, y: 57.9889, width: 11.4869, height: 126.7893),
            CGRect(x: 366.0635, y: 58.2056, width: 19.7228, height: 99.9143),
            CGRect(x: 292.3740, y: 61.0232, width: 18.6391, height: 61.3357),
            CGRect(x: 267.4496, y: 128.8609, width: 10.4032, height: 51.7994),
            CGRect(x: 292.3740, y: 130.5948, width: 9.7530, height: 46.5978),
        ]
        let preferred = [
            CGRect(x: 246.7816, y: 57.9889, width: 43.72, height: 99.0474),
            CGRect(x: 288.1366, y: 58.6391, width: 36, height: 38.1452),
            CGRect(x: 329.0993, y: 57.9889, width: 36, height: 126.7893),
            CGRect(x: 354.0949, y: 58.2056, width: 43.66, height: 99.9143),
            CGRect(x: 283.6635, y: 61.0232, width: 36.06, height: 61.3357),
            CGRect(x: 260.1512, y: 128.8609, width: 25, height: 51.7994),
            CGRect(x: 279.2505, y: 130.5948, width: 36, height: 46.5978),
        ]
        let greedyRects = [
            CGRect(x: 258.5635, y: 57.9889, width: 20.1563, height: 99.0474),
            CGRect(x: 301.0433, y: 58.6391, width: 19, height: 38.1452),
            CGRect(x: 329.0993, y: 57.9889, width: 36, height: 126.7893),
            CGRect(x: 366.0635, y: 58.2056, width: 43.66, height: 99.9143),
            CGRect(x: 291.9531, y: 61.0232, width: 19.06, height: 61.3357),
            CGRect(x: 267.4496, y: 128.8609, width: 19, height: 51.7994),
            CGRect(x: 279.2505, y: 130.5948, width: 36, height: 46.5978),
        ]
        let previousJoint = [
            CGRect(x: 258.5635, y: 57.9889, width: 20.1563, height: 99.0474),
            CGRect(x: 296.6366, y: 20.8780, width: 19, height: 38.1452),
            CGRect(x: 318, y: 57.9889, width: 36, height: 126.7893),
            CGRect(x: 354.0949, y: 58.2056, width: 43.66, height: 99.9143),
            CGRect(x: 292.1635, y: 61.0232, width: 19.06, height: 61.3357),
            CGRect(x: 237.5635, y: 128.8609, width: 19, height: 51.7994),
            CGRect(x: 279.2505, y: 130.5948, width: 36, height: 46.5978),
        ]
        let layouts = greedyRects.map { rect in
            BrowserOverlayCardLayout(
                rect: rect,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }

        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sources,
            viewport: CGSize(width: 430, height: 715),
            placementBounds: CGRect(x: 0, y: 0, width: 430, height: 715),
            preferredRects: preferred,
            allowsDetachedPlacements: Array(repeating: true, count: layouts.count)
        )
        func totalSquaredMovement(_ rects: [CGRect]) -> CGFloat {
            zip(rects, preferred).reduce(CGFloat.zero) { total, pair in
                let dx = pair.0.midX - pair.1.midX
                let dy = pair.0.midY - pair.1.midY
                return total + dx * dx + dy * dy
            }
        }

        #expect(
            totalSquaredMovement(packed.map(\.rect)) + 0.25 <
                totalSquaredMovement(previousJoint)
        )
        let sourceAlignedTopRow = [0, 4, 1, 2, 3]
        for index in sourceAlignedTopRow {
            #expect(abs(packed[index].rect.minY - preferred[index].minY) <= 2)
        }
        for position in sourceAlignedTopRow.indices.dropFirst() {
            let previous = sourceAlignedTopRow[position - 1]
            let current = sourceAlignedTopRow[position]
            #expect(packed[previous].rect.maxX <= packed[current].rect.minX)
        }
        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test
    func sourceRowRestoresOrderAfterGreedyAlreadyRemovedOverlap() {
        let preferred = [
            CGRect(x: 76, y: 130, width: 104, height: 245),
            CGRect(x: 190, y: 130, width: 66, height: 188),
        ]
        let greedilyEjected = [
            CGRect(x: 76, y: 130, width: 104, height: 245),
            CGRect(x: 0, y: 130, width: 66, height: 188),
        ]
        let layouts = greedilyEjected.map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: preferred,
            viewport: CGSize(width: 430, height: 715),
            placementBounds: CGRect(x: 0, y: 0, width: 430, height: 536),
            preferredRects: preferred,
            allowsDetachedPlacements: [true, true]
        )

        #expect(packed[0].rect.maxX <= packed[1].rect.minX)
        #expect(abs(packed[0].rect.minY - preferred[0].minY) <= 0.25)
        #expect(abs(packed[1].rect.minY - preferred[1].minY) <= 0.25)
    }

    @Test
    func sitePageFifteenRepacksTheWholeTopRowBeforeEjectingCards() {
        let sources = [
            CGRect(x: 45.51, y: 57.34, width: 18.21, height: 126.57),
            CGRect(x: 95.15, y: 56.04, width: 10.19, height: 105.12),
            CGRect(x: 119.85, y: 56.04, width: 10.40, height: 84.09),
            CGRect(x: 144.99, y: 56.26, width: 18.21, height: 97.75),
            CGRect(x: 185.74, y: 56.04, width: 18.86, height: 146.73),
            CGRect(x: 218.47, y: 55.82, width: 11.49, height: 36.84),
            CGRect(x: 243.83, y: 56.26, width: 27.09, height: 139.36),
            CGRect(x: 285.22, y: 56.26, width: 27.09, height: 97.96),
            CGRect(x: 326.18, y: 56.04, width: 11.27, height: 84.31),
            CGRect(x: 351.33, y: 59.07, width: 18.64, height: 95.15),
            CGRect(x: 377.12, y: 58.86, width: 16.69, height: 80.41),
        ]
        let preferred = [
            CGRect(x: 34.37, y: 57.34, width: 40.50, height: 126.57),
            CGRect(x: 82.24, y: 56.04, width: 36.00, height: 105.12),
            CGRect(x: 107.06, y: 56.04, width: 36.00, height: 84.09),
            CGRect(x: 133.85, y: 56.26, width: 40.50, height: 97.75),
            CGRect(x: 174.13, y: 56.04, width: 42.08, height: 146.73),
            CGRect(x: 206.21, y: 55.82, width: 36.00, height: 36.84),
            CGRect(x: 232.88, y: 56.26, width: 48.98, height: 139.36),
            CGRect(x: 275.06, y: 56.26, width: 47.41, height: 97.96),
            CGRect(x: 313.82, y: 56.04, width: 36.00, height: 84.31),
            CGRect(x: 339.68, y: 59.07, width: 41.94, height: 95.15),
            CGRect(x: 367.46, y: 58.86, width: 36.00, height: 80.41),
        ]
        let greedy = [
            CGRect(x: 34.37, y: 57.34, width: 40.50, height: 126.57),
            CGRect(x: 82.24, y: 56.04, width: 36.00, height: 105.12),
            CGRect(x: 133.85, y: 155.57, width: 19.00, height: 84.09),
            CGRect(x: 133.85, y: 55.82, width: 40.50, height: 97.75),
            CGRect(x: 174.13, y: 56.04, width: 42.08, height: 146.73),
            CGRect(x: 215.96, y: 18.49, width: 16.50, height: 36.84),
            CGRect(x: 228.08, y: 56.26, width: 48.98, height: 139.36),
            CGRect(x: 277.97, y: 56.26, width: 44.33, height: 97.96),
            CGRect(x: 326.06, y: 56.04, width: 11.52, height: 84.31),
            CGRect(x: 339.58, y: 59.07, width: 39.91, height: 95.15),
            CGRect(x: 380.00, y: 58.86, width: 36.00, height: 80.41),
        ]
        let layouts = greedy.map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let packed = BrowserOverlayLayoutPlanner.relaxingCardPositions(
            layouts,
            sources: sources,
            viewport: CGSize(width: 430, height: 715),
            placementBounds: CGRect(x: 0, y: 0, width: 430, height: 292.5),
            preferredRects: preferred,
            allowsDetachedPlacements: Array(repeating: true, count: 11)
        )

        #expect(abs(packed[2].rect.midY - preferred[2].midY) < 4)
        #expect(abs(packed[5].rect.midY - preferred[5].midY) < 4)
        let preferredBounds = preferred.dropFirst().reduce(preferred[0]) {
            $0.union($1)
        }
        let packedBounds = packed.dropFirst().reduce(packed[0].rect) {
            $0.union($1.rect)
        }
        #expect(abs(packedBounds.midX - preferredBounds.midX) < 5)
        for left in packed.indices {
            for right in packed.indices where right > left {
                let overlap = packed[left].rect.intersection(
                    packed[right].rect
                )
                #expect(
                    overlap.isNull ||
                        overlap.width <= 0.25 ||
                        overlap.height <= 0.25
                )
            }
        }
    }

    @Test @MainActor
    func sitePageFifteenRealTranslationsPreferHorizontalRedistribution() {
        let sources = [
            CGRect(x: 45.51, y: 57.34, width: 18.21, height: 126.57),
            CGRect(x: 95.15, y: 56.04, width: 10.19, height: 105.12),
            CGRect(x: 119.85, y: 56.04, width: 10.40, height: 84.09),
            CGRect(x: 144.99, y: 56.26, width: 18.21, height: 97.75),
            CGRect(x: 185.74, y: 56.04, width: 18.86, height: 146.73),
            CGRect(x: 218.47, y: 55.82, width: 11.49, height: 36.84),
            CGRect(x: 243.83, y: 56.26, width: 27.09, height: 139.36),
            CGRect(x: 285.22, y: 56.26, width: 27.09, height: 97.96),
            CGRect(x: 326.18, y: 56.04, width: 11.27, height: 84.31),
            CGRect(x: 351.33, y: 59.07, width: 18.64, height: 95.15),
            CGRect(x: 377.12, y: 58.86, width: 16.69, height: 80.41),
        ]
        let translations = [
            "……아아, 정말 둔하다니까! 이리 내! 자, 전부 벗어!",
            "「그러니까 사과 안 해도 된다니까!」",
            "「미안…… 미안해……」",
            "자, 물 끓었으니까 얼른 몸 깨끗이 씻으렴!",
            "그런 건 내 일이야! 당신은 애들이나 돌보고 있으라고!",
            "\"아우...\"",
            "어차피 밀어붙여서 거절 못 한 거지? 맨날 그렇게 손해만 보고 말이야!",
            "정말! 왜 당신이 사과하는 건데! 사과해야 할 쪽은 나라고!",
            "\"미... 미안해...\"",
            "왜 그런 짓을 한 거야! 당신은 처음이란 말이야!",
            "이 멍청아!",
        ]
        let items = sources.indices.map { index in
            BrowserOverlayItem(
                stableRegionID: UInt64(15_000 + index),
                rect: sources[index],
                sourceText: "縦書き原文\(index)",
                translatedText: translations[index],
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )
        }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        settings.expansionPolicy = .panelConstrained
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(
            items: items,
            imageSize: CGSize(width: 430, height: 322.5),
            sourceRect: CGRect(x: 0, y: 0, width: 430, height: 322.5),
            settings: settings,
            targetLanguage: "ko",
            viewport: CGSize(width: 430, height: 715)
        )
        #expect(payload.count == items.count)
        for index in payload.indices {
            let y = payload[index]["y"] as? CGFloat
            #expect(y != nil)
            if let y {
                #expect(abs(y - sources[index].minY) < 12)
            }
            #expect(payload[index]["vertical"] as? Bool == false)
        }
        let firstX = payload[0]["x"] as? CGFloat
        #expect(firstX != nil)
        if let firstX {
            #expect(abs(firstX - 34.3669) < 18)
        }
        let frames = payload.compactMap { entry -> CGRect? in
            guard let x = entry["x"] as? CGFloat,
                  let y = entry["y"] as? CGFloat,
                  let width = entry["width"] as? CGFloat,
                  let height = entry["height"] as? CGFloat
            else { return nil }
            return CGRect(x: x, y: y, width: width, height: height)
        }
        #expect(frames.count == payload.count)
        if let firstFrame = frames.first {
            let bounds = frames.dropFirst().reduce(firstFrame) {
                $0.union($1)
            }
            #expect(abs(bounds.midX - 218.9136) < 4)
        }
    }

    @Test
    func denseVerticalColumnsChooseWritingDirectionBeforeMovingCards() {
        let horizontal = [
            CGRect(x: 0, y: 20, width: 60, height: 120),
            CGRect(x: 5, y: 20, width: 60, height: 120),
            CGRect(x: 120, y: 20, width: 50, height: 120),
        ].map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let vertical = [
            0: BrowserOverlayCardLayout(
                rect: CGRect(x: -15, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
            1: BrowserOverlayCardLayout(
                rect: CGRect(x: 25, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
        ]

        let selected =
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: horizontal,
                verticalLayouts: vertical
            )

        #expect(selected == Set([0]))
    }

    @Test
    func minorDenseColumnOverlapDoesNotTriggerVerticalTranslation() {
        let horizontal = [
            CGRect(x: 0, y: 20, width: 60, height: 120),
            CGRect(x: 40, y: 20, width: 60, height: 120),
        ].map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let vertical = [
            0: BrowserOverlayCardLayout(
                rect: CGRect(x: 20, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
            1: BrowserOverlayCardLayout(
                rect: CGRect(x: 60, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
        ]

        #expect(
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: horizontal,
                verticalLayouts: vertical
            ).isEmpty
        )
    }

    @Test
    func separatedVerticalSourcesKeepKoreanTranslationHorizontal() {
        let horizontal = [
            CGRect(x: 0, y: 20, width: 40, height: 120),
            CGRect(x: 60, y: 20, width: 40, height: 120),
        ].map {
            BrowserOverlayCardLayout(
                rect: $0,
                maximumFontSize: 12,
                contentInsets: .zero
            )
        }
        let vertical = [
            0: BrowserOverlayCardLayout(
                rect: CGRect(x: 10, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
            1: BrowserOverlayCardLayout(
                rect: CGRect(x: 70, y: 20, width: 20, height: 120),
                maximumFontSize: 12,
                contentInsets: .zero
            ),
        ]

        #expect(
            BrowserOverlayLayoutPlanner.adaptiveVerticalTranslationIndices(
                horizontalLayouts: horizontal,
                verticalLayouts: vertical
            ).isEmpty
        )
    }

    @Test
    func adaptiveVerticalCandidateIsLimitedToNarrowKoreanReplacement() {
        let item = BrowserOverlayItem(
            rect: CGRect(x: 100, y: 50, width: 24, height: 160),
            sourceText: "「どうして謝るの」",
            translatedText: "왜 사과하는 거야",
            confidence: 0.99,
            sourceOrientation: .vertical,
            sourceSingleVerticalColumn: true
        )
        let horizontal = BrowserOverlayCardContent.make(
            item: item,
            mode: .translateOnly,
            sourceVertical: true,
            translatedVertical: false
        )

        let candidate = BrowserOverlayCardContent.adaptiveVerticalCandidate(
            item: item,
            current: horizontal,
            mode: .translateOnly,
            textPlacement: .replace,
            sourceVertical: true,
            sourceRect: item.rect
        )
        #expect(candidate?.displayed.vertical == true)
        #expect(BrowserOverlayCardContent.adaptiveVerticalCandidate(
            item: item,
            current: horizontal,
            mode: .translateOnly,
            textPlacement: .expanded,
            sourceVertical: true,
            sourceRect: item.rect
        ) == nil)
    }

    @Test func longTranslationExpandsAroundItsSourceWithoutClippingScreen() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .fixed
        settings.fixedFontSizePoints = 24
        let source = CGRect(x: 120, y: 120, width: 42, height: 22)
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: source,
            text: "고정 글꼴도 배경이 함께 확장되어 잘리지 않습니다",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(plan.maximumFontSize == 24)
        #expect(plan.rect.width > source.width)
        #expect(plan.rect.height > source.height)
        #expect(plan.rect.minX >= 0)
        #expect(plan.rect.minY >= 0)
        #expect(plan.rect.maxX <= 390)
        #expect(plan.rect.maxY <= 715)
        #expect(plan.rect.contains(source))
    }

    @Test @MainActor
    func viewportWideUnbrokenTokenFallsBackToCharacterWrapping() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .fixed
        settings.fixedFontSizePoints = 24
        settings.textPlacement = .replace
        let translation = String(repeating: "AidokuReader", count: 24)
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 701,
                rect: CGRect(x: 20, y: 80, width: 100, height: 28),
                sourceText: "source",
                translatedText: translation,
                confidence: 0.99
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        label.superview?.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(label.lineBreakMode == .byCharWrapping)
        #expect(displayedTextFits(label))
    }

    @Test @MainActor
    func replacementUsesExactlyOneCardWithoutASecondSourceMask() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.colorMode = .dark
        settings.opacity = 0.25
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                rect: CGRect(x: 20, y: 80, width: 130, height: 32),
                sourceText: "設定画面",
                translatedText: "설정 화면",
                confidence: 0.99
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )

        #expect(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.source-mask"
        ) == nil)
        let cards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let card = try #require(cards.first)
        #expect(cards.count == 1)
        let backdrop = try #require(replacementBackdrop(in: card))
        let surface = try #require(replacementSurface(in: card))
        #expect(card.backgroundColor == .clear)
        #expect(!backdrop.isHidden)
        #expect(backdrop.effect is UIBlurEffect)
        // c1's dark veil is .64 over the configured .25 surface.
        #expect(abs((surface.backgroundColor?.cgColor.alpha ?? 0) - 0.73) <
            0.001)
        #expect(card.layer.cornerRadius == 6)
        #expect(card.layer.borderWidth == 1)
        #expect(colorsMatch(
            card.layer.borderColor.map(UIColor.init(cgColor:)),
            UIColor.white.withAlphaComponent(0.40)
        ))
        #expect(abs(card.layer.shadowOpacity - 0.38) < 0.001)
        #expect(abs(card.layer.shadowRadius - 4) < 0.001)
        #expect(card.layer.shadowOffset == CGSize(width: 0, height: 2))
    }

    @Test @MainActor
    func nativeBackdropIsActiveOnlyForReplacementCards() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.colorMode = .dark
        settings.opacity = 0.25
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let item = BrowserOverlayItem(
            stableRegionID: 70_200,
            rect: CGRect(x: 20, y: 80, width: 130, height: 32),
            sourceText: "設定画面",
            translatedText: "설정 화면",
            confidence: 0.99
        )

        overlay.render(
            [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        let replacementCard = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let activeBackdrop = try #require(replacementBackdrop(
            in: replacementCard
        ))
        let activeSurface = try #require(replacementSurface(
            in: replacementCard
        ))
        #expect(!activeBackdrop.isHidden)
        #expect(activeBackdrop.effect is UIBlurEffect)
        #expect(abs(
            (activeSurface.backgroundColor?.cgColor.alpha ?? 0) - 0.73
        ) < 0.001)

        settings.textPlacement = .expanded
        overlay.render(
            [item],
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        let expandedCard = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        #expect(replacementCard === expandedCard)
        #expect(replacementBackdrop(in: expandedCard) == nil)
        #expect(activeBackdrop.superview == nil)
        #expect(colorsMatch(
            expandedCard.backgroundColor,
            UIColor(
                red: 7 / 255,
                green: 9 / 255,
                blue: 13 / 255,
                alpha: 0.73
            )
        ))
    }

    @Test @MainActor
    func OCRCardIsUpdatedInPlaceWhenTranslationArrives() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.colorMode = .dark
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let source = BrowserOverlayItem(
            stableRegionID: 702,
            rect: CGRect(x: 20, y: 80, width: 130, height: 32),
            sourceText: "設定画面",
            translatedText: nil,
            confidence: 0.99
        )

        overlay.render(
            BrowserOverlayVisibility.visibleItems(
                [source]
            ),
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        let sourceCards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let sourceCard = try #require(sourceCards.first)
        let sourceLabel = try #require(view(
            in: sourceCard,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        sourceCard.layoutIfNeeded()
        sourceLabel.layoutIfNeeded()
        let sourceBackdrop = try #require(replacementBackdrop(in: sourceCard))
        let sourceSurface = try #require(replacementSurface(in: sourceCard))
        #expect(sourceCards.count == 1)
        #expect(sourceLabel.attributedText?.string == source.sourceText)
        #expect(
            sourceLabel.attributedText?.string.contains("설정 화면") == false
        )
        #expect(!sourceBackdrop.isHidden)
        #expect(sourceBackdrop.effect is UIBlurEffect)
        // Dark c1 veil: .64 over the configured default .84 surface.
        #expect(abs((sourceSurface.backgroundColor?.cgColor.alpha ?? 0) -
            0.9424) < 0.001)

        let translated = BrowserOverlayItem(
            stableRegionID: source.stableRegionID,
            rect: source.rect,
            sourceText: source.sourceText,
            translatedText: "설정 화면",
            confidence: source.confidence
        )
        overlay.render(
            BrowserOverlayVisibility.visibleItems(
                [translated]
            ),
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )

        let translatedCards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let translatedCard = try #require(translatedCards.first)
        let translatedLabel = try #require(view(
            in: translatedCard,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        translatedCard.layoutIfNeeded()
        translatedLabel.layoutIfNeeded()
        let translatedBackdrop = try #require(replacementBackdrop(
            in: translatedCard
        ))
        let translatedSurface = try #require(replacementSurface(
            in: translatedCard
        ))
        #expect(translatedCards.count == 1)
        #expect(sourceCard === translatedCard)
        #expect(sourceLabel === translatedLabel)
        #expect(sourceBackdrop === translatedBackdrop)
        #expect(sourceSurface === translatedSurface)
        #expect(!translatedBackdrop.isHidden)
        #expect(translatedBackdrop.effect is UIBlurEffect)
        #expect(abs((translatedSurface.backgroundColor?.cgColor.alpha ?? 0) -
            0.9424) < 0.001)
        #expect(translatedLabel.attributedText?.string == "설정 화면")
        #expect(
            translatedLabel.attributedText?.string.contains(
                source.sourceText
            ) == false
        )
        #expect(translatedCard.accessibilityLabel?.contains("설정 화면") == true)
    }

    @Test @MainActor
    func automaticPaletteMatchesDesktopHorizontalAndVerticalSurfaces() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.colorMode = .automatic
        settings.opacity = 0.25

        func renderedCard(
            sourceOrientation: BrowserOCRSourceOrientation,
            singleVerticalColumn: Bool
        ) throws -> UIView {
            let sourceIsVertical = sourceOrientation == .vertical
            let overlay = BrowserOverlayView(
                frame: CGRect(x: 0, y: 0, width: 390, height: 715)
            )
            overlay.render(
                [BrowserOverlayItem(
                    rect: sourceIsVertical
                        ? CGRect(x: 30, y: 80, width: 34, height: 180)
                        : CGRect(x: 30, y: 80, width: 180, height: 34),
                    sourceText: sourceIsVertical
                        ? (singleVerticalColumn ? "縦書き" : "縦書き\n二列")
                        : "横書き",
                    translatedText: sourceIsVertical
                        ? (singleVerticalColumn ? "세로쓰기" : "여러 줄 세로쓰기")
                        : "가로쓰기",
                    confidence: 0.99,
                    sourceOrientation: sourceOrientation,
                    sourceSingleVerticalColumn: singleVerticalColumn
                )],
                imageSize: CGSize(width: 390, height: 715),
                sourceRect: overlay.bounds,
                settings: settings,
                targetLanguage: "ko"
            )
            return try #require(view(
                in: overlay,
                identifier: "aidoku.reader.overlay.item"
            ))
        }

        let horizontal = try renderedCard(
            sourceOrientation: .horizontal,
            singleVerticalColumn: false
        )
        let vertical = try renderedCard(
            sourceOrientation: .vertical,
            singleVerticalColumn: true
        )
        let multiColumnVertical = try renderedCard(
            sourceOrientation: .vertical,
            singleVerticalColumn: false
        )
        var horizontalRed: CGFloat = 0
        var horizontalGreen: CGFloat = 0
        var horizontalBlue: CGFloat = 0
        var horizontalAlpha: CGFloat = 0
        var verticalRed: CGFloat = 0
        var verticalGreen: CGFloat = 0
        var verticalBlue: CGFloat = 0
        var verticalAlpha: CGFloat = 0
        let horizontalSurface = try #require(replacementSurface(
            in: horizontal
        ))
        let verticalSurface = try #require(replacementSurface(in: vertical))
        let multiColumnVerticalSurface = try #require(replacementSurface(
            in: multiColumnVertical
        ))
        #expect(horizontalSurface.backgroundColor?.getRed(
            &horizontalRed,
            green: &horizontalGreen,
            blue: &horizontalBlue,
            alpha: &horizontalAlpha
        ) == true)
        #expect(verticalSurface.backgroundColor?.getRed(
            &verticalRed,
            green: &verticalGreen,
            blue: &verticalBlue,
            alpha: &verticalAlpha
        ) == true)

        #expect(abs(horizontalRed - (7 / 255)) < 0.001)
        #expect(abs(horizontalGreen - (9 / 255)) < 0.001)
        #expect(abs(horizontalBlue - (13 / 255)) < 0.001)
        #expect(abs(horizontalAlpha - 0.73) < 0.001)
        #expect(verticalRed > 0.99)
        #expect(verticalGreen > 0.99)
        #expect(verticalBlue > 0.98)
        #expect(abs(verticalAlpha - 0.565) < 0.001)
        #expect(colorsMatch(
            multiColumnVerticalSurface.backgroundColor,
            verticalSurface.backgroundColor
        ))
    }

    @Test @MainActor
    func warmVerticalCardMatchesDesktopTextAndSurfaceRoles() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .originalAndTranslation
        settings.textPlacement = .replace
        settings.colorMode = .automatic
        settings.opacity = 0.25
        let source = "縦書き\n二列"
        let translation = "여러 줄 세로쓰기"
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 811,
                rect: CGRect(x: 30, y: 80, width: 72, height: 180),
                sourceText: source,
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()

        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()

        let imageAlpha: CGFloat = 0.42
        let baseAlpha: CGFloat = 0.25
        let effectiveAlpha = imageAlpha + baseAlpha * (1 - imageAlpha)
        let baseContribution = baseAlpha * (1 - imageAlpha)
        let expectedWarm = UIColor(
            red: 1,
            green: (imageAlpha + (254 / 255) * baseContribution) /
                effectiveAlpha,
            blue: (imageAlpha + (249 / 255) * baseContribution) /
                effectiveAlpha,
            alpha: effectiveAlpha
        )
        let expectedForeground = UIColor(
            red: 17 / 255,
            green: 18 / 255,
            blue: 23 / 255,
            alpha: 1
        )
        let expectedSecondary = expectedForeground.withAlphaComponent(0.66)
        let attributed = try #require(label.attributedText)
        let translationIndex = (attributed.string as NSString)
            .range(of: translation).location
        let sourceColor = attributed.attribute(
            .foregroundColor,
            at: 0,
            effectiveRange: nil
        ) as? UIColor
        let translationColor = attributed.attribute(
            .foregroundColor,
            at: translationIndex,
            effectiveRange: nil
        ) as? UIColor
        let sourceShadow = attributed.attribute(
            .shadow,
            at: 0,
            effectiveRange: nil
        ) as? NSShadow
        let translationShadow = attributed.attribute(
            .shadow,
            at: translationIndex,
            effectiveRange: nil
        ) as? NSShadow

        let backdrop = try #require(replacementBackdrop(in: card))
        let surface = try #require(replacementSurface(in: card))
        #expect(!backdrop.isHidden)
        #expect(colorsMatch(surface.backgroundColor, expectedWarm))
        #expect(colorsMatch(
            card.layer.borderColor.map(UIColor.init(cgColor:)),
            expectedForeground.withAlphaComponent(0.72)
        ))
        #expect(colorsMatch(sourceColor, expectedSecondary))
        #expect(colorsMatch(translationColor, expectedForeground))
        #expect(sourceShadow == nil)
        #expect(translationShadow?.shadowOffset == CGSize(width: 0, height: 1))
        #expect(translationShadow?.shadowBlurRadius == 0)
        #expect(colorsMatch(
            translationShadow?.shadowColor as? UIColor,
            UIColor.white.withAlphaComponent(0.75)
        ))
        #expect(abs(card.layer.shadowOpacity - 0.26) < 0.001)
        #expect(abs(card.layer.shadowRadius - 3.5) < 0.001)
    }

    @Test @MainActor
    func expandedVerticalCardUsesDesktopPaperGeometryAndShadow() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .expanded
        settings.colorMode = .automatic
        settings.opacity = 0.25
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 812,
                rect: CGRect(x: 30, y: 80, width: 72, height: 180),
                sourceText: "縦書き\n二列",
                translatedText: "여러 줄 세로쓰기",
                confidence: 0.99,
                sourceOrientation: .vertical,
                sourceSingleVerticalColumn: false
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))

        #expect(abs(card.layer.cornerRadius - 14 * 1.45) < 0.001)
        #expect(card.layer.borderWidth == 2)
        #expect(abs(card.layer.shadowOpacity - 0.32) < 0.001)
        #expect(abs(card.layer.shadowRadius - 9) < 0.001)
        #expect(card.layer.shadowOffset == CGSize(width: 0, height: 5))
    }

    @Test @MainActor
    func subtitleAndSidePanelUseTheAutomaticDarkDesktopPalette() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.colorMode = .automatic
        settings.opacity = 0.25
        let item = BrowserOverlayItem(
            stableRegionID: 813,
            rect: CGRect(x: 30, y: 80, width: 180, height: 34),
            sourceText: "設定画面",
            translatedText: "설정 화면",
            confidence: 0.99,
            sourceOrientation: .horizontal
        )
        let expectedBackground = UIColor(
            red: 7 / 255,
            green: 9 / 255,
            blue: 13 / 255,
            alpha: 0.73
        )
        let expectedBorder = UIColor.white.withAlphaComponent(0.40)

        settings.mode = .subtitle
        let subtitleOverlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        subtitleOverlay.render(
            [item],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: subtitleOverlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        let subtitle = try #require(view(
            in: subtitleOverlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let subtitleLabel = try #require(firstLabel(in: subtitle))
        #expect(colorsMatch(subtitle.backgroundColor, expectedBackground))
        #expect(colorsMatch(
            subtitle.layer.borderColor.map(UIColor.init(cgColor:)),
            expectedBorder
        ))
        #expect(colorsMatch(subtitleLabel.textColor, .white))
        #expect(abs(subtitle.layer.cornerRadius - 14 * 0.72) < 0.001)
        #expect(abs(subtitle.layer.shadowOpacity - 0.58) < 0.001)
        #expect(abs(subtitle.layer.shadowRadius - 13) < 0.001)
        #expect(subtitle.layer.shadowOffset == CGSize(width: 0, height: 7))

        settings.mode = .sidePanel
        let panelOverlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        panelOverlay.render(
            [item],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: panelOverlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        let panel = try #require(view(
            in: panelOverlay,
            identifier: "aidoku.reader.overlay.side-panel"
        ))
        let panelLabel = try #require(view(
            in: panel,
            identifier: "aidoku.reader.overlay.item"
        ) as? UILabel)
        #expect(colorsMatch(panel.backgroundColor, expectedBackground))
        #expect(colorsMatch(
            panel.layer.borderColor.map(UIColor.init(cgColor:)),
            expectedBorder
        ))
        #expect(colorsMatch(panelLabel.textColor, .white))
        #expect(panel.layer.cornerRadius == 15)
        #expect(abs(panel.layer.shadowOpacity - 0.58) < 0.001)
        #expect(abs(panel.layer.shadowRadius - 13) < 0.001)
        #expect(panel.layer.shadowOffset == CGSize(width: 0, height: 7))
    }

    @Test @MainActor
    func duplicateStableRegionIDsAreAllExcludedAndNeverLeaveOrphans() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [
                BrowserOverlayItem(
                    stableRegionID: 9,
                    rect: CGRect(x: 20, y: 80, width: 120, height: 32),
                    sourceText: "重複一",
                    translatedText: "중복 하나",
                    confidence: 0.99
                ),
                BrowserOverlayItem(
                    stableRegionID: 9,
                    rect: CGRect(x: 22, y: 82, width: 118, height: 30),
                    sourceText: "重複二",
                    translatedText: "중복 둘",
                    confidence: 0.98
                ),
                BrowserOverlayItem(
                    stableRegionID: 10,
                    rect: CGRect(x: 20, y: 140, width: 120, height: 32),
                    sourceText: "一意",
                    translatedText: "고유",
                    confidence: 0.97
                ),
            ],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )

        let visible = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        #expect(visible.count == 1)
        #expect(visible[0].accessibilityLabel?.contains("고유") == true)

        overlay.render(
            [],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        #expect(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).isEmpty)
        #expect(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.items"
        )?.subviews.isEmpty == true)
    }

    @Test @MainActor
    func movedStableRegionReplacesOldProjectionBeforeRendering() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        let oldSourceRect = CGRect(x: 20, y: 80, width: 34, height: 120)
        let newSourceRect = CGRect(x: 245, y: 180, width: 51, height: 180)
        let old = BrowserOverlayItem(
            stableRegionID: 712,
            rect: oldSourceRect,
            sourceText: "vertical source region",
            translatedText: "이전 좌표",
            confidence: 0.99,
            sourceOrientation: .vertical
        )
        let moved = BrowserOverlayItem(
            stableRegionID: 712,
            rect: newSourceRect,
            sourceText: old.sourceText,
            translatedText: "새 좌표",
            confidence: old.confidence,
            sourceOrientation: .vertical
        )
        let merged = BrowserProgressiveImageOverlayPolicy.mergedItems(
            baseItems: [old],
            replacementItems: [moved],
            successfulReplacementRects: [
                CGRect(x: 230, y: 160, width: 90, height: 220),
            ]
        )
        let consolidated = BrowserImageSourceOverlayConsolidator.consolidate(
            merged
        )
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )

        overlay.render(
            consolidated,
            imageSize: overlay.bounds.size,
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()

        let cards = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let card = try #require(cards.first)
        #expect(merged == [moved])
        #expect(consolidated == [moved])
        #expect(cards.count == 1)
        #expect(card.accessibilityLabel?.contains("새 좌표") == true)
        #expect(card.frame.insetBy(dx: -0.5, dy: -0.5).contains(newSourceRect))
        #expect(!card.frame.intersects(oldSourceRect))
    }

    @Test @MainActor
    func positionedRendererKeepsCanonicalOCRRowsSeparate() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [
                BrowserOverlayItem(
                    stableRegionID: 1,
                    rect: CGRect(x: 210, y: 100, width: 128, height: 24),
                    sourceText: "設定画面を開いて",
                    translatedText: "Open the",
                    confidence: 0.98
                ),
                BrowserOverlayItem(
                    stableRegionID: 2,
                    rect: CGRect(x: 210, y: 128, width: 118, height: 24),
                    sourceText: "設定を",
                    translatedText: "settings",
                    confidence: 0.97
                ),
                BrowserOverlayItem(
                    stableRegionID: 3,
                    rect: CGRect(x: 210, y: 156, width: 108, height: 24),
                    sourceText: "開いてください",
                    translatedText: "screen.",
                    confidence: 0.96
                ),
            ],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "en"
        )

        #expect(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).count == 3)
    }

    @Test @MainActor
    func positionedRendererReusesTheStableRegionCard() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let sourceRect = CGRect(x: 20, y: 80, width: 150, height: 40)
        func render(_ translation: String) {
            overlay.render(
                [BrowserOverlayItem(
                    stableRegionID: 42,
                    rect: sourceRect,
                    sourceText: "設定画面",
                    translatedText: translation,
                    confidence: 0.99
                )],
                imageSize: CGSize(width: 390, height: 715),
                sourceRect: overlay.bounds,
                settings: settings,
                targetLanguage: "ko"
            )
        }

        render("설정 화면")
        let first = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)
        render("새 설정 화면")
        let second = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)

        #expect(first === second)
        #expect(second.accessibilityLabel?.contains("새 설정 화면") == true)
    }

    @Test @MainActor
    func overlayCardDoesNotToggleBackToSourceOnTap() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 43,
                rect: CGRect(x: 20, y: 80, width: 150, height: 40),
                sourceText: "設定画面",
                translatedText: "설정 화면",
                confidence: 0.99
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )

        let card = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)
        let label = try #require(view(
            in: card,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)

        #expect(label.attributedText?.string == "설정 화면")
        #expect(card.gestureRecognizers?.contains {
            $0 is UITapGestureRecognizer
        } != true)
        #expect(!card.accessibilityTraits.contains(.button))
        #expect(card.accessibilityValue == nil)
    }

    @Test @MainActor
    func settingTheSameLocaleDoesNotDestroyVisibleCards() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 77,
                rect: CGRect(x: 20, y: 80, width: 150, height: 40),
                sourceText: "設定画面",
                translatedText: "설정 화면",
                confidence: 0.99
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        let first = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)

        overlay.setLocale(.korean)

        let second = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)
        #expect(first === second)
    }

    @Test func replacementPlannerUsesUIKitMeasurementWithoutClipping() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .fixed
        settings.fixedFontSizePoints = 24
        settings.textPlacement = .replace
        let text = "Open the AidokuReader settings screen."
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: CGRect(x: 120, y: 120, width: 42, height: 22),
            text: text,
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(BrowserOverlayLayoutPlanner.horizontalTextFits(
            text,
            available: CGSize(
                width: plan.rect.width -
                    plan.contentInsets.left - plan.contentInsets.right,
                height: plan.rect.height -
                    plan.contentInsets.top - plan.contentInsets.bottom
            ),
            fontSize: plan.maximumFontSize
        ))
    }

    @Test func shortTranslationCanUseAReadableLargeAutoFont() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: CGRect(x: 24, y: 90, width: 180, height: 56),
            text: "설정 화면",
            vertical: false,
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(plan.maximumFontSize >= 28)
    }

    @Test @MainActor
    func expandedAutoFitUsesTheLargestActualUIFontThatFits() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .expanded
        settings.fontSizing = .autoFit
        let text = "설정 화면"
        let variant = BrowserOverlayDisplayVariant.plain(
            text,
            vertical: false
        )
        let plan = BrowserOverlayLayoutPlanner.plan(
            source: CGRect(x: 24, y: 90, width: 180, height: 56),
            variants: [variant],
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: []
        )

        #expect(plan.maximumFontSize >= 31.75)
        #expect(variant.fits(
            available: CGSize(
                width: plan.rect.width -
                    plan.contentInsets.left - plan.contentInsets.right,
                height: plan.rect.height -
                    plan.contentInsets.top - plan.contentInsets.bottom
            ),
            fontSize: plan.maximumFontSize
        ))

        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 81,
                rect: CGRect(x: 24, y: 90, width: 180, height: 56),
                sourceText: "設定画面",
                translatedText: text,
                confidence: 0.99
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        label.superview?.layoutIfNeeded()
        label.layoutIfNeeded()
        #expect(label.font.pointSize >= plan.maximumFontSize - 0.5)
        #expect(displayedTextFits(label))
    }

    @Test @MainActor
    func translatedVerticalCardCannotToggleBackToSource() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .fixed
        settings.fixedFontSizePoints = 24
        let source = "縦書きの文章を認識"
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 82,
                rect: CGRect(x: 210, y: 80, width: 28, height: 170),
                sourceText: source,
                translatedText: "OK",
                confidence: 0.99,
                sourceOrientation: .vertical
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()
        let plannedFrame = card.frame
        #expect(label.attributedText?.string == "OK")
        #expect(label.attributedText?.string.contains("\n") == false)
        #expect(displayedTextFits(label))

        #expect(!card.accessibilityActivate())
        card.layoutIfNeeded()
        label.layoutIfNeeded()
        #expect(card.frame == plannedFrame)
        #expect(label.attributedText?.string == "OK")
        #expect(label.attributedText?.string.contains("\n") == false)
        #expect(displayedTextFits(label))
    }

    @Test @MainActor
    func explicitSingleLineVerticalSourceUsesHorizontalKoreanTranslation() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let imageSourceRect = CGRect(
            x: 420,
            y: 160,
            width: 56,
            height: 340
        )
        let mappedSourceRect = CGRect(
            x: 210,
            y: 80,
            width: 28,
            height: 170
        )
        let translation = "세로쓰기문장을한줄로인식하고표시합니다."
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 821,
                rect: imageSourceRect,
                sourceText: "縦書きの文章を認識します。",
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .vertical
            )],
            imageSize: CGSize(width: 780, height: 1_430),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(card.frame.contains(mappedSourceRect))
        #expect(!card.clipsToBounds)
        #expect(!label.clipsToBounds)
        #expect(label.attributedText?.string == translation)
        #expect(label.attributedText?.string.contains("\n") == false)
        let renderedFont = try #require(
            label.attributedText?.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont
        )
        #expect(renderedFont.pointSize >= 5)
        #expect(displayedTextFits(label))
        #expect(overlay.bounds.contains(card.frame))
        #expect(card.frame.width < overlay.bounds.width / 2)
        #expect(card.frame.height < overlay.bounds.height / 2)
        #expect(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.source-mask"
        ) == nil)
    }

    @Test @MainActor
    func unreadableConstrainedVerticalTranslationRemainsVisibleAndAnchored()
        throws
    {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        settings.expansionPolicy = .panelConstrained
        let sourceRect = CGRect(x: 185, y: 250, width: 40, height: 250)
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let translation = String(
            repeating:
                "그런건내일이야당신은아이들이나잘돌보고있으라고",
            count: 240
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 826,
                rect: sourceRect,
                sourceText: "縦書きの文章を最初のフレームで認識します。",
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .vertical,
                // The first merge may know that the region is vertical before
                // its single-column classification has stabilized.
                sourceSingleVerticalColumn: false
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: card,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(!card.isHidden)
        #expect(card.alpha > 0)
        #expect(overlay.bounds.contains(card.frame))
        #expect(card.frame.insetBy(dx: -0.5, dy: -0.5).contains(sourceRect))
        #expect(label.attributedText?.string == translation)
    }

    @Test @MainActor
    func physicalNarrowVerticalFixtureUsesReadableHorizontalKoreanCard() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let fixtureScale: CGFloat = 390 / 1_290
        let fixtureRect = CGRect(
            x: 538 * fixtureScale,
            y: 1_590 * fixtureScale,
            width: 40 * fixtureScale,
            height: 185 * fixtureScale
        )
        let translation = "세로쓰기"
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 825,
                rect: fixtureRect,
                sourceText: "縦書き",
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .vertical
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let card = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ))
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        card.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(card.frame.insetBy(dx: -0.5, dy: -0.5).contains(
            fixtureRect
        ))
        #expect(card.frame.width >= fixtureRect.width)
        #expect(card.frame.height >= fixtureRect.height)
        #expect(!card.clipsToBounds)
        #expect(!label.clipsToBounds)
        #expect(label.attributedText?.string == translation)
        #expect(label.attributedText?.string.contains("\n") == false)
        let renderedFont = try #require(
            label.attributedText?.attribute(
                .font,
                at: 0,
                effectiveRange: nil
            ) as? UIFont
        )
        #expect(renderedFont.pointSize >= 5)
        #expect(displayedTextFits(label))
        #expect(overlay.bounds.contains(card.frame))
        #expect(card.frame.width < overlay.bounds.width / 2)
        #expect(card.frame.height < overlay.bounds.height / 2)
        #expect(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.source-mask"
        ) == nil)
    }

    @Test @MainActor
    func explicitHorizontalTranslationIsNotVerticalized() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let translation = "가로 번역은 그대로 표시합니다"
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 822,
                rect: CGRect(x: 40, y: 90, width: 250, height: 48),
                sourceText: "Horizontal source text",
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .horizontal
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        label.superview?.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(label.attributedText?.string == translation)
        #expect(!translation.contains("\n"))
        #expect(displayedTextFits(label))
    }

    @Test @MainActor
    func explicitVerticalRTLTranslationStaysHorizontal() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let translation = "افتح شاشة الإعدادات"
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 823,
                rect: CGRect(x: 210, y: 80, width: 28, height: 170),
                sourceText: "縦書きの文章",
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .vertical
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ar"
        )
        overlay.layoutIfNeeded()
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        label.superview?.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(label.attributedText?.string == translation)
        #expect(displayedTextFits(label))
    }

    @Test @MainActor
    func explicitMultilineVerticalSourceKeepsExistingTargetPolicy() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.textPlacement = .replace
        settings.fontSizing = .autoFit
        let translation = "여러 OCR 줄은 가로 번역 정책을 유지합니다"
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 824,
                rect: CGRect(x: 190, y: 70, width: 70, height: 180),
                sourceText: "縦書き\n二列",
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .vertical
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        label.superview?.layoutIfNeeded()
        label.layoutIfNeeded()

        #expect(label.attributedText?.string == translation)
        #expect(displayedTextFits(label))
    }

    @Test @MainActor
    func originalAndTranslationUsesDesktopStyleFontHierarchyAndFits() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .originalAndTranslation
        settings.textPlacement = .replace
        settings.fontSizing = .fixed
        settings.fixedFontSizePoints = 24
        let source = "設定画面を開いてください"
        let translation = "설정 화면을 열어 주세요"
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 83,
                rect: CGRect(x: 40, y: 90, width: 140, height: 36),
                sourceText: source,
                translatedText: translation,
                confidence: 0.99,
                sourceOrientation: .horizontal
            )],
            imageSize: CGSize(width: 390, height: 715),
            sourceRect: overlay.bounds,
            settings: settings,
            targetLanguage: "ko"
        )
        overlay.layoutIfNeeded()
        let label = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.item.text"
        ) as? UILabel)
        label.superview?.layoutIfNeeded()
        label.layoutIfNeeded()
        let attributed = try #require(label.attributedText)
        #expect(attributed.string == source + "\n" + translation)
        let sourceFont = try #require(
            attributed.attribute(.font, at: 0, effectiveRange: nil) as? UIFont
        )
        let translationIndex = (attributed.string as NSString)
            .range(of: translation).location
        let translationFont = try #require(
            attributed.attribute(
                .font,
                at: translationIndex,
                effectiveRange: nil
            ) as? UIFont
        )
        #expect(sourceFont.pointSize <= translationFont.pointSize * 0.65)
        #expect(translationFont.pointSize == 24)
        #expect(displayedTextFits(label))
    }

    @Test func wrappedTwoColumnGroupsStaySeparateAndDoNotOverlap() throws {
        var segments: [BrowserOverlayPresentationSegment] = []
        let translations = ["Open the", "settings", "screen."]
        for (column, x) in [CGFloat(20), CGFloat(210)].enumerated() {
            for row in translations.indices {
                segments.append(presentationSegment(
                    rect: CGRect(
                        x: x,
                        y: 100 + CGFloat(row) * 28,
                        width: 128 - CGFloat(row) * 10,
                        height: 24
                    ),
                    source: "source-\(column)-\(row)",
                    translation: translations[row]
                ))
            }
        }
        let groups = BrowserOverlayPresentationGrouper.groups(segments)
        #expect(groups.count == 2)
        #expect(groups.allSatisfy { $0.segments.count == 3 })

        var settings = ReaderTranslationSettings.defaultOverlay
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        var occupied: [CGRect] = []
        var plans: [BrowserOverlayCardLayout] = []
        for (index, group) in groups.enumerated() {
            let plan = BrowserOverlayLayoutPlanner.plan(
                source: group.sourceBounds,
                text: try #require(group.overlayItem.translatedText),
                vertical: false,
                settings: settings,
                viewport: CGSize(width: 390, height: 715),
                occupied: occupied,
                reservedSources: groups.enumerated().compactMap {
                    $0.offset == index ? nil : $0.element.sourceBounds
                }
            )
            plans.append(plan)
            occupied.append(plan.rect)
        }
        #expect(plans.count == 2)
        #expect(plans[0].rect.intersection(plans[1].rect).isNull)
        #expect(!plans[0].rect.intersects(groups[1].sourceBounds))
        #expect(!plans[1].rect.intersects(groups[0].sourceBounds))
    }

    @Test @MainActor
    func positionedOverlayCachesStablePrefixLayoutsAndSupportsExplicitInvalidation() {
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        let sourceItems = [
            BrowserOverlayItem(
                stableRegionID: 1,
                rect: CGRect(x: 24, y: 90, width: 150, height: 40),
                sourceText: "最初の行",
                translatedText: nil,
                confidence: 0.99
            ),
            BrowserOverlayItem(
                stableRegionID: 2,
                rect: CGRect(x: 24, y: 150, width: 150, height: 40),
                sourceText: "次の行",
                translatedText: nil,
                confidence: 0.98
            ),
        ]
        let imageSize = CGSize(width: 390, height: 715)

        overlay.render(
            sourceItems,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        #expect(
            overlay.lastLayoutCacheStatistics ==
                BrowserOverlayLayoutCacheStatistics(hits: 0, misses: 2)
        )
        #expect(overlay.lastRenderStatistics.cardUpdates == 2)
        #expect(overlay.lastRenderStatistics.intrinsicLayoutMisses == 2)

        overlay.render(
            sourceItems,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        #expect(
            overlay.lastLayoutCacheStatistics ==
                BrowserOverlayLayoutCacheStatistics(hits: 2, misses: 0)
        )
        #expect(overlay.lastRenderStatistics.semanticNoOp)
        #expect(overlay.lastRenderStatistics.cardUpdates == 0)

        let translatedTail = [
            sourceItems[0],
            BrowserOverlayItem(
                stableRegionID: 2,
                rect: sourceItems[1].rect,
                sourceText: sourceItems[1].sourceText,
                translatedText: "다음 줄",
                confidence: sourceItems[1].confidence
            ),
        ]
        overlay.render(
            translatedTail,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        #expect(
            overlay.lastLayoutCacheStatistics ==
                BrowserOverlayLayoutCacheStatistics(hits: 2, misses: 0)
        )
        #expect(!overlay.lastRenderStatistics.semanticNoOp)
        #expect(overlay.lastRenderStatistics.cardUpdates == 1)
        #expect(overlay.lastRenderStatistics.intrinsicLayoutHits == 1)
        #expect(overlay.lastRenderStatistics.intrinsicLayoutMisses == 1)

        overlay.render(
            translatedTail,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings,
            invalidatingStableRegionIDs: [1]
        )
        #expect(overlay.lastLayoutCacheStatistics.misses >= 1)
        #expect(!overlay.lastRenderStatistics.semanticNoOp)
    }

    @Test @MainActor
    func positionedOverlayDiffsStableCardsAndFallsBackForGeometry() {
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .translateOnly
        settings.fontSizing = .autoFit
        settings.textPlacement = .replace
        let imageSize = CGSize(width: 390, height: 715)
        let items = (0..<3).map { index in
            BrowserOverlayItem(
                stableRegionID: UInt64(index + 1),
                rect: CGRect(
                    x: 24,
                    y: 90 + CGFloat(index) * 90,
                    width: 150,
                    height: 40
                ),
                sourceText: "source-\(index)",
                translatedText: "번역-\(index)",
                confidence: 0.99
            )
        }
        overlay.render(
            items,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )

        var confidenceUpdate = items
        confidenceUpdate[1] = BrowserOverlayItem(
            stableRegionID: items[1].stableRegionID,
            rect: items[1].rect,
            sourceText: items[1].sourceText,
            translatedText: items[1].translatedText,
            confidence: 0.62
        )
        overlay.render(
            confidenceUpdate,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        #expect(!overlay.lastRenderStatistics.semanticNoOp)
        #expect(!overlay.lastRenderStatistics.usedFullLayoutFallback)
        #expect(overlay.lastRenderStatistics.cardUpdates == 1)
        #expect(overlay.lastRenderStatistics.cardFrameChanges == 0)
        #expect(overlay.lastRenderStatistics.intrinsicLayoutHits == 3)
        #expect(overlay.lastRenderStatistics.intrinsicLayoutMisses == 0)
        #expect(
            overlay.lastLayoutCacheStatistics ==
                BrowserOverlayLayoutCacheStatistics(hits: 3, misses: 0)
        )

        var geometryUpdate = confidenceUpdate
        geometryUpdate[1] = BrowserOverlayItem(
            stableRegionID: confidenceUpdate[1].stableRegionID,
            rect: confidenceUpdate[1].rect.offsetBy(dx: 8, dy: 0),
            sourceText: confidenceUpdate[1].sourceText,
            translatedText: confidenceUpdate[1].translatedText,
            confidence: confidenceUpdate[1].confidence
        )
        overlay.render(
            geometryUpdate,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        #expect(overlay.lastRenderStatistics.usedFullLayoutFallback)
        #expect(
            overlay.lastLayoutCacheStatistics ==
                BrowserOverlayLayoutCacheStatistics(hits: 0, misses: 3)
        )

        settings.opacity = 0.72
        overlay.render(
            geometryUpdate,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        #expect(overlay.lastRenderStatistics.usedFullLayoutFallback)
        #expect(overlay.lastRenderStatistics.cardUpdates == 3)
        #expect(
            overlay.lastLayoutCacheStatistics ==
                BrowserOverlayLayoutCacheStatistics(hits: 0, misses: 3)
        )
    }

    @Test @MainActor
    func positionedCollisionDependenciesExcludeDistantCards() {
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.expansionPolicy = .panelConstrained
        let intrinsic = BrowserOverlayCardLayout(
            rect: CGRect(x: 70, y: 90, width: 100, height: 60),
            maximumFontSize: 14,
            contentInsets: BrowserOverlayCardTextInsets.regular
        )
        let dependencies = BrowserOverlayLayoutPlanner.collisionDependencies(
            intrinsicLayout: intrinsic,
            source: CGRect(x: 100, y: 100, width: 40, height: 40),
            variants: [.plain("translated", vertical: false)],
            settings: settings,
            viewport: CGSize(width: 390, height: 715),
            occupied: [
                BrowserOverlayPositionedCollisionDependency(
                    key: "near",
                    rect: CGRect(x: 130, y: 100, width: 40, height: 40)
                ),
                BrowserOverlayPositionedCollisionDependency(
                    key: "far",
                    rect: CGRect(x: 280, y: 500, width: 50, height: 50)
                ),
            ],
            sourceVertical: false,
            singleVerticalColumn: false
        )
        #expect(dependencies.map(\.key) == ["near"])
    }

    @Test @MainActor
    func overlayTextMeasurementsAreMemoizedExactly() {
        let cache = BrowserOverlayTextMeasurementCache()
        let variant = BrowserOverlayDisplayVariant.plain(
            "설정 화면을 여세요",
            vertical: false
        )
        cache.beginPass()
        let first = variant.measuredSize(
            width: 132,
            fontSize: 14,
            measurementCache: cache
        )
        let afterFirst = cache.passStatistics
        let second = variant.measuredSize(
            width: 132,
            fontSize: 14,
            measurementCache: cache
        )
        let afterSecond = cache.passStatistics

        #expect(first == second)
        #expect(afterFirst.misses > 0)
        #expect(afterSecond.misses == afterFirst.misses)
        #expect(afterSecond.hits > afterFirst.hits)

        _ = variant.measuredSize(
            width: 133,
            fontSize: 14,
            measurementCache: cache
        )
        #expect(cache.passStatistics.misses > afterSecond.misses)
    }

    @Test @MainActor func subtitleAndSidePanelReuseTheirStableViews() throws {
        let overlay = BrowserOverlayView(
            frame: CGRect(x: 0, y: 0, width: 390, height: 715)
        )
        let imageSize = CGSize(width: 390, height: 715)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.mode = .subtitle
        let source = BrowserOverlayItem(
            stableRegionID: 7,
            rect: CGRect(x: 20, y: 100, width: 160, height: 40),
            sourceText: "字幕",
            translatedText: nil,
            confidence: 0.99
        )

        overlay.render(
            [source],
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        let firstSubtitle = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)
        overlay.render(
            [BrowserOverlayItem(
                stableRegionID: 7,
                rect: source.rect,
                sourceText: source.sourceText,
                translatedText: "자막",
                confidence: source.confidence
            )],
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        let secondSubtitle = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)
        #expect(firstSubtitle === secondSubtitle)

        settings.mode = .sidePanel
        let panelItems = [
            source,
            BrowserOverlayItem(
                stableRegionID: 8,
                rect: CGRect(x: 20, y: 160, width: 160, height: 40),
                sourceText: "次",
                translatedText: nil,
                confidence: 0.98
            ),
        ]
        overlay.render(
            panelItems,
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        let firstPanel = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.side-panel"
        ))
        let firstRows = views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        )
        let firstRow = try #require(firstRows.first)

        overlay.render(
            [
                BrowserOverlayItem(
                    stableRegionID: 7,
                    rect: source.rect,
                    sourceText: source.sourceText,
                    translatedText: "자막",
                    confidence: source.confidence
                ),
                panelItems[1],
            ],
            imageSize: imageSize,
            sourceRect: overlay.bounds,
            settings: settings
        )
        let secondPanel = try #require(view(
            in: overlay,
            identifier: "aidoku.reader.overlay.side-panel"
        ))
        let secondRow = try #require(views(
            in: overlay,
            identifier: "aidoku.reader.overlay.item"
        ).first)
        #expect(firstPanel === secondPanel)
        #expect(firstRow === secondRow)
    }

    @MainActor
    private func button(
        in view: UIView,
        identifier: String
    ) -> UIButton? {
        if let button = view as? UIButton,
           button.accessibilityIdentifier == identifier
        {
            return button
        }
        for subview in view.subviews {
            if let match = button(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    private func overlayItem(
        source: String,
        translation: String?
    ) -> BrowserOverlayItem {
        BrowserOverlayItem(
            rect: CGRect(x: 1, y: 2, width: 30, height: 12),
            sourceText: source,
            translatedText: translation,
            confidence: 0.98
        )
    }

    private func presentationSegment(
        rect: CGRect,
        source: String,
        translation: String?
    ) -> BrowserOverlayPresentationSegment {
        BrowserOverlayPresentationSegment(
            sourceRect: rect,
            sourceText: source,
            translatedText: translation,
            confidence: 0.98,
            sourceVertical: false,
            translatedVertical: false,
            displayVertical: false
        )
    }

    @MainActor
    private func view(
        in root: UIView,
        identifier: String
    ) -> UIView? {
        if root.accessibilityIdentifier == identifier {
            return root
        }
        for subview in root.subviews {
            if let match = view(in: subview, identifier: identifier) {
                return match
            }
        }
        return nil
    }

    @MainActor
    private func replacementBackdrop(in card: UIView) -> UIVisualEffectView? {
        view(
            in: card,
            identifier: "aidoku.reader.overlay.item.backdrop"
        ) as? UIVisualEffectView
    }

    @MainActor
    private func replacementSurface(in card: UIView) -> UIView? {
        view(
            in: card,
            identifier: "aidoku.reader.overlay.item.surface"
        )
    }

    @MainActor
    private func views(
        in root: UIView,
        identifier: String
    ) -> [UIView] {
        var matches: [UIView] = []
        if root.accessibilityIdentifier == identifier {
            matches.append(root)
        }
        for subview in root.subviews {
            matches.append(contentsOf: views(
                in: subview,
                identifier: identifier
            ))
        }
        return matches
    }

    @MainActor
    private func firstLabel(in root: UIView) -> UILabel? {
        if let label = root as? UILabel {
            return label
        }
        for subview in root.subviews {
            if let match = firstLabel(in: subview) {
                return match
            }
        }
        return nil
    }

    private func colorsMatch(
        _ left: UIColor?,
        _ right: UIColor?,
        tolerance: CGFloat = 0.001
    ) -> Bool {
        switch (left, right) {
        case (nil, nil):
            return true
        case let (left?, right?):
            var leftRed: CGFloat = 0
            var leftGreen: CGFloat = 0
            var leftBlue: CGFloat = 0
            var leftAlpha: CGFloat = 0
            var rightRed: CGFloat = 0
            var rightGreen: CGFloat = 0
            var rightBlue: CGFloat = 0
            var rightAlpha: CGFloat = 0
            guard left.getRed(
                &leftRed,
                green: &leftGreen,
                blue: &leftBlue,
                alpha: &leftAlpha
            ), right.getRed(
                &rightRed,
                green: &rightGreen,
                blue: &rightBlue,
                alpha: &rightAlpha
            ) else {
                return left.isEqual(right)
            }
            return abs(leftRed - rightRed) <= tolerance &&
                abs(leftGreen - rightGreen) <= tolerance &&
                abs(leftBlue - rightBlue) <= tolerance &&
                abs(leftAlpha - rightAlpha) <= tolerance
        default:
            return false
        }
    }

    @MainActor
    private func displayedTextFits(
        _ label: UILabel,
        contentInsets: UIEdgeInsets = BrowserOverlayCardTextInsets.regular
    ) -> Bool {
        let available = label.bounds.inset(by: contentInsets)
        guard available.width > 0, available.height > 0 else {
            return false
        }
        let measured = label.textRect(
            forBounds: CGRect(origin: .zero, size: available.size),
            limitedToNumberOfLines: 0
        )
        return ceil(measured.width) <= available.width + 0.5 &&
            ceil(measured.height) <= available.height + 0.5
    }

    @MainActor
    private func alphaPixelBounds(
        of view: UIView,
        margin: Int
    ) -> CGRect? {
        view.layoutIfNeeded()
        let pixelWidth = max(1, Int(ceil(view.bounds.width)) + margin * 2)
        let pixelHeight = max(1, Int(ceil(view.bounds.height)) + margin * 2)
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = false
        let image = UIGraphicsImageRenderer(
            size: CGSize(
                width: CGFloat(pixelWidth),
                height: CGFloat(pixelHeight)
            ),
            format: format
        ).image { context in
            context.cgContext.translateBy(
                x: CGFloat(margin) - view.bounds.minX,
                y: CGFloat(margin) - view.bounds.minY
            )
            view.layer.render(in: context.cgContext)
        }
        guard let cgImage = image.cgImage,
              let frame = NativeOCRCGImageAdapter.makeRGBAFrame(from: cgImage)
        else { return nil }
        var minimumX = frame.width
        var minimumY = frame.height
        var maximumX = -1
        var maximumY = -1
        for y in 0..<frame.height {
            for x in 0..<frame.width {
                let alpha = frame.bytes[
                    y * frame.bytesPerRow + x * 4 + 3
                ]
                guard alpha > 2 else { continue }
                minimumX = min(minimumX, x)
                minimumY = min(minimumY, y)
                maximumX = max(maximumX, x)
                maximumY = max(maximumY, y)
            }
        }
        guard maximumX >= minimumX, maximumY >= minimumY else { return nil }
        return CGRect(
            x: CGFloat(minimumX),
            y: CGFloat(minimumY),
            width: CGFloat(maximumX - minimumX + 1),
            height: CGFloat(maximumY - minimumY + 1)
        )
    }

    private func image(color: UIColor) -> UIImage? {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 4, height: 3))
        return renderer.image { context in
            color.setFill()
            context.cgContext.fill(CGRect(x: 0, y: 0, width: 4, height: 3))
        }
    }

}
