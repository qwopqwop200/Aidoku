import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSmallTextDOMGuardTests {
    // Recorded planned payloads: small-font-sfx-study/captures versus
    // source-ink-cleanup-study/paired-captures. No image or dataset dependency.
    private static let fixturesJSON = #"""
    [{"page": "eval-16-ja-ko", "baseline": {"clipsText": false, "fontScript": "japanese", "fontSize": 7.25, "height": 84.6710526315789, "id": "5", "lightSurface": true, "lineHeight": 8.65185546875, "paddingBottom": 3.16, "paddingLeft": 3.16, "paddingRight": 3.16, "paddingTop": 3.16, "sourceBounds": [0.6618421052631579, 0.6108333333333333, 0.05394736842105263, 0.1375], "sourceCleanup": true, "sourceFrame": [-2.842170943040401e-14, 82.10526315789474, 390.00000000000006, 615.7894736842105], "sourceVertical": true, "text": "회오리바람이다ーーっ", "vertical": false, "width": 38.078475877192965, "wrappingScript": "korean", "x": 249.59891995614035, "y": 458.25}, "candidate": {"clipsText": false, "fontScript": "japanese", "fontSize": 7.75, "height": 84.6710526315789, "id": "5", "lightSurface": true, "lineHeight": 9.24853515625, "paddingBottom": 3.16, "paddingLeft": 3.16, "paddingRight": 3.16, "paddingTop": 3.16, "sfxDisposition": "protectedDialogue", "sfxReasons": ["hiragana_or_sentence_requires_context"], "sourceBounds": [0.6618421052631579, 0.6108333333333333, 0.05394736842105263, 0.1375], "sourceCleanup": true, "sourceFrame": [-2.842170943040401e-14, 82.10526315789474, 390.00000000000006, 615.7894736842105], "sourceVertical": true, "text": "회오리바람이다ーーっ", "vertical": false, "width": 38.078475877192965, "wrappingScript": "korean", "x": 249.59891995614035, "y": 458.25}}, {"page": "eval-21-ja-ko", "baseline": {"clipsText": false, "fontScript": "korean", "fontSize": 6.75, "height": 55.51094890510947, "id": "1", "lightSurface": true, "lineHeight": 8.05517578125, "paddingBottom": 3.85, "paddingLeft": 3.85, "paddingRight": 3.85, "paddingTop": 3.85, "sourceBounds": [0.7262773722627737, 0.12166666666666667, 0.08637469586374696, 0.0975], "sourceCleanup": true, "sourceFrame": [0, 105.32846715328469, 390, 569.3430656934306], "sourceVertical": true, "text": "아주머니라니요…?", "vertical": false, "width": 58.95072992700726, "wrappingScript": "korean", "x": 270.61587591240874, "y": 174.59854014598542}, "candidate": {"clipsText": false, "fontScript": "korean", "fontSize": 7.25, "height": 55.51094890510947, "id": "1", "lightSurface": true, "lineHeight": 8.65185546875, "paddingBottom": 3.85, "paddingLeft": 3.85, "paddingRight": 3.85, "paddingTop": 3.85, "sfxDisposition": "protectedDialogue", "sfxReasons": ["hiragana_or_sentence_requires_context"], "sourceBounds": [0.7262773722627737, 0.12166666666666667, 0.08637469586374696, 0.0975], "sourceCleanup": true, "sourceFrame": [0, 105.32846715328469, 390, 569.3430656934306], "sourceVertical": true, "text": "아주머니라니요…?", "vertical": false, "width": 58.95072992700726, "wrappingScript": "korean", "x": 270.61587591240874, "y": 174.59854014598542}}, {"page": "eval-26-ja-ko", "baseline": {"clipsText": false, "fontScript": "korean", "fontSize": 6.75, "height": 30.23089609675651, "id": "14", "lightSurface": true, "lineHeight": 8.05517578125, "paddingBottom": 3, "paddingLeft": 3, "paddingRight": 3, "paddingTop": 3, "sourceBounds": [0.7855964815832875, 0.5229321834574676, 0.023639362286970864, 0.05527244217953744], "sourceCleanup": true, "sourceFrame": [0, 116.52831225948324, 390, 546.9433754810335], "sourceVertical": true, "text": "아름다워…", "vertical": false, "width": 36, "wrappingScript": "korean", "x": 304.9571579507972, "y": 402.5426058273776}, "candidate": {"clipsText": false, "fontScript": "korean", "fontSize": 7.75, "height": 30.23089609675651, "id": "14", "lightSurface": true, "lineHeight": 9.24853515625, "paddingBottom": 3, "paddingLeft": 3, "paddingRight": 3, "paddingTop": 3, "sfxDisposition": "protectedDialogue", "sfxReasons": ["hiragana_or_sentence_requires_context"], "sourceBounds": [0.7855964815832875, 0.5229321834574676, 0.023639362286970864, 0.05527244217953744], "sourceCleanup": true, "sourceFrame": [0, 116.52831225948324, 390, 546.9433754810335], "sourceVertical": true, "text": "아름다워…", "vertical": false, "width": 36, "wrappingScript": "korean", "x": 304.9571579507972, "y": 402.5426058273776}}, {"page": "eval-26-ja-ko", "baseline": {"clipsText": false, "fontScript": "korean", "fontSize": 7, "height": 44.16712479384279, "id": "20", "lightSurface": true, "lineHeight": 8.353515625, "paddingBottom": 3, "paddingLeft": 3, "paddingRight": 3, "paddingTop": 3, "sourceBounds": [0.7047828477185266, 0.573108584868679, 0.022539857064321055, 0.08075264602116818], "sourceCleanup": true, "sourceFrame": [0, 116.52831225948324, 390, 546.9433754810335], "sourceVertical": true, "text": "누이(인형)의 시대가", "vertical": false, "width": 36, "wrappingScript": "korean", "x": 244.98456827240244, "y": 429.9862561847169}, "candidate": {"clipsText": false, "fontScript": "korean", "fontSize": 7.75, "height": 44.16712479384279, "id": "20", "lightSurface": true, "lineHeight": 9.24853515625, "paddingBottom": 3, "paddingLeft": 3, "paddingRight": 3, "paddingTop": 3, "sfxDisposition": "protectedDialogue", "sfxReasons": ["hiragana_or_sentence_requires_context"], "sourceBounds": [0.7047828477185266, 0.573108584868679, 0.022539857064321055, 0.08075264602116818], "sourceCleanup": true, "sourceFrame": [0, 116.52831225948324, 390, 546.9433754810335], "sourceVertical": true, "text": "누이(인형)의 시대가", "vertical": false, "width": 36, "wrappingScript": "korean", "x": 244.98456827240244, "y": 429.9862561847169}}]
    """#

    // Real Cuckoo fixture: the final word wraps intact and must remain enlarged.
    private static let safeFixtureJSON = #"""
    {"page": "eval-51-zh-Hant-ko", "baseline": {"clipsText": false, "fontScript": "korean", "fontSize": 6.75, "height": 38.512500000000045, "id": "5", "lightSurface": true, "lineHeight": 8.05517578125, "paddingBottom": 3.74, "paddingLeft": 3.74, "paddingRight": 3.74, "paddingTop": 3.74, "sourceBounds": [0.4025, 0.8175, 0.08125, 0.06583333333333333], "sourceCleanup": true, "sourceFrame": [0, 97.5, 390, 585], "sourceVertical": true, "text": "너희 먼저 먹어.", "vertical": false, "width": 49.480000000000004, "wrappingScript": "korean", "x": 148.07874999999999, "y": 575.7375}, "candidate": {"clipsText": false, "fontScript": "korean", "fontSize": 7.75, "height": 38.512500000000045, "id": "5", "lightSurface": true, "lineHeight": 9.24853515625, "paddingBottom": 3.74, "paddingLeft": 3.74, "paddingRight": 3.74, "paddingTop": 3.74, "sfxDisposition": "unsupported", "sfxReasons": ["no_supported_japanese_kana_evidence"], "sourceBounds": [0.4025, 0.8175, 0.08125, 0.06583333333333333], "sourceCleanup": true, "sourceFrame": [0, 97.5, 390, 585], "sourceVertical": true, "text": "너희 먼저 먹어.", "vertical": false, "width": 49.480000000000004, "wrappingScript": "korean", "x": 148.07874999999999, "y": 575.7375}}
    """#

    @Test
    func actualWordBoundaryWrapKeepsLargerFont() async throws {
        let fixture = try #require(JSONSerialization.jsonObject(with: Data(Self.safeFixtureJSON.utf8)) as? [String: Any])
        try await check(fixture, shouldAccept: true)
    }

    @Test(arguments: [0, 1, 2, 3])
    func actualBadLineBreakRestoresStrictFontAndPadding(index: Int) async throws {
        let fixtures = try #require(JSONSerialization.jsonObject(with: Data(Self.fixturesJSON.utf8)) as? [[String: Any]])
        try await check(fixtures[index], shouldAccept: false)
    }

    @Test func realBalloonWithInteriorSourceUsesSpaceWithoutMovingCard() async throws {
        // Actual eval-11-ja-ko region 15. A small neighbouring OCR source lies
        // below its centre; a blanket rectangle-collision veto left it at 5px.
        let baseline: [String: Any] = [
            "id": "15", "text": "너는 101번째 노예다", "x": 11.804744525547434,
            "y": 444.5620437956204, "width": 77.81021897810218, "height": 77.3357664233576,
            "fontSize": 5.0, "lineHeight": 5.966796875, "paddingTop": 6.0,
            "paddingRight": 6.0, "paddingBottom": 6.0, "paddingLeft": 6.0,
            "vertical": false, "fontScript": "korean", "wrappingScript": "korean", "lightSurface": true
        ]
        var candidate = baseline
        candidate["fontSize"] = 11.75; candidate["lineHeight"] = 14.02197265625
        candidate["smallTextReference"] = [
            "fontSize": 5.0, "padding": [6.0, 6.0, 6.0, 6.0], "additionalLines": 7,
            "exclusionRects": [[65.0, 488.2116788321168, 6.642335766423358, 9.014598540145984]]
        ] as [String: Any]
        try await check(["baseline": baseline, "candidate": candidate], shouldAccept: true,
                        minimumAcceptedFont: 8)
    }

    private func check(_ fixture: [String: Any], shouldAccept: Bool, minimumAcceptedFont: Double? = nil) async throws {
        var baseline = try #require(fixture["baseline"] as? [String: Any])
        var candidate = try #require(fixture["candidate"] as? [String: Any])
        // The source image is irrelevant to this text-metrics regression.
        baseline["sourceCleanup"] = false; candidate["sourceCleanup"] = false
        let referenceFont = try #require(baseline["fontSize"] as? Double)
        let referencePadding = try ["paddingTop", "paddingRight", "paddingBottom", "paddingLeft"].map {
            try #require(baseline[$0] as? Double)
        }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 780))
        window.rootViewController?.view.addSubview(webView)
        window.makeKeyAndVisible()
        let renderer = BrowserPageImageOverlayRenderer()
        defer { renderer.cancelPendingRender(); window.isHidden = true; previous?.makeKey() }
        webView.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;width:100%;height:100%}</style><div id='fixture-ready'></div>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while (try? await webView.evaluateJavaScript("!!document.getElementById('fixture-ready')") as? Bool) != true {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        let strict = try await render(baseline, on: webView, using: renderer)
        #expect(abs((try #require(strict["font"] as? Double)) - referenceFont) < 0.01)
        let suppliedReference = candidate.removeValue(forKey: "smallTextReference")
        let unguarded = try await render(candidate, on: webView, using: renderer)
        #expect((try #require(unguarded["font"] as? Double)) >= referenceFont + 0.5)
        candidate["smallTextReference"] = suppliedReference ?? ["fontSize": referenceFont, "padding": referencePadding]
        let guarded = try await render(candidate, on: webView, using: renderer)
        #expect(guarded["refinement"] as? String == (shouldAccept ? "accepted" : "retained-baseline"))
        let expectedFont = shouldAccept ? try #require(unguarded["font"] as? Double) : referenceFont
        if let minimumAcceptedFont {
            #expect((try #require(guarded["font"] as? Double)) >= minimumAcceptedFont)
            let glyphs = try #require(guarded["glyphRects"] as? [[Double]])
            let reference = try #require(candidate["smallTextReference"] as? [String: Any])
            let exclusions = try #require(reference["exclusionRects"] as? [[Double]])
            for glyph in glyphs {
                for obstacle in exclusions {
                    let overlapWidth = min(glyph[0] + glyph[2], obstacle[0] + obstacle[2]) - max(glyph[0], obstacle[0])
                    let overlapHeight = min(glyph[1] + glyph[3], obstacle[1] + obstacle[3]) - max(glyph[1], obstacle[1])
                    #expect(overlapWidth <= 0.5 || overlapHeight <= 0.5)
                }
            }
        } else {
            #expect(abs((try #require(guarded["font"] as? Double)) - expectedFont) < 0.01)
        }
        let actualPadding = try #require(guarded["padding"] as? [Double])
        #expect(actualPadding.count == 4)
        if minimumAcceptedFont == nil {
            for (actual, expected) in zip(actualPadding, referencePadding) { #expect(abs(actual - expected) < 0.01) }
        }
        #expect((guarded["text"] as? String) == (baseline["text"] as? String))
        let oldRect = try #require(strict["rect"] as? [Double])
        let newRect = try #require(guarded["rect"] as? [Double])
        #expect(oldRect == newRect)
    }

    private func render(_ item: [String: Any], on webView: WKWebView,
                        using renderer: BrowserPageImageOverlayRenderer) async throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: [item])
        let prepared = Task<Data, Error> { data }
        var finished = false
        renderer.render(on: webView, items: [], imageSize: webView.bounds.size,
                        sourceRect: webView.bounds, settings: ReaderTranslationSettings.defaultOverlay,
                        targetLanguage: "ko", preparedLayout: prepared) { _ in finished = true }
        let deadline = Date().addingTimeInterval(20)
        while !finished {
            guard Date() < deadline else { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(renderer.lastDiagnostic?.outcome == .committed)
        return try #require(try await webView.evaluateJavaScript("""
        (() => {
          const node = document.querySelector('[data-aidoku-image-ocr-overlay="item"]');
          if (!node) return null;
          const style = getComputedStyle(node), r = node.getBoundingClientRect();
          const glyphRects = [], range = document.createRange();
          let offset = 0;
          for (const character of node.textContent) {
            range.setStart(node.firstChild, offset); offset += character.length;
            range.setEnd(node.firstChild, offset);
            if (character.trim()) {
              const fragments = Array.from(range.getClientRects()).filter(r => r.width > 0 && r.height > 0);
              const g = fragments[fragments.length - 1];
              if (g) glyphRects.push([g.x, g.y, g.width, g.height]);
            }
          }
          return {font:parseFloat(style.fontSize), text:node.textContent,
            glyphRects,
            padding:[style.paddingTop,style.paddingRight,style.paddingBottom,style.paddingLeft].map(parseFloat),
            refinement:node.dataset.smallTextRefinement || '', rect:[r.x,r.y,r.width,r.height]};
        })()
        """) as? [String: Any])
    }
}
