import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Opt-in replay of a locally captured layout and its original image, without OCR or provider calls.
@Suite(.serialized)
@MainActor
struct ReaderCachedLayoutReplayTests {
    private static var directory: URL { URL.documentsDirectory.appendingPathComponent("CachedLayoutReplay") }

    @Test
    func capturedLayoutUsesNativeBackgroundPreparation() async throws {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("OverlayIncidentReplay")
        if let data = try? Data(contentsOf: caches.appendingPathComponent("pages.json")) {
            let names = try JSONDecoder().decode([String].self, from: data)
            try #require(!names.isEmpty)
            for name in names { try await replay(caches.appendingPathComponent(name)) }
        } else { try await replay(Self.directory) }
    }

    private func replay(_ directory: URL) async throws {
        let regionURL = directory.appendingPathComponent("regions.json")
        if FileManager.default.fileExists(atPath: regionURL.path) {
            let stored = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(contentsOf: regionURL))
            let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.image").path))
            let cg = try #require(image.cgImage)
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent("refresh-ocr").path) {
                let recognized = try await ReaderOCRService.shared.recognize(image: cg, configuration: .init(
                    detectorMaximumSide: 2000, confidenceThreshold: 0.35,
                    detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
                try JSONEncoder().encode(recognized.map(ReaderTranslationStoredRegion.init))
                    .write(to: directory.appendingPathComponent("recognized.json"))
                #expect(!recognized.isEmpty)
            }
            let size = CGSize(width: cg.width, height: cg.height)
            let viewport = CGSize(width: 430, height: 932)
            let height = 430 * size.height / size.width
            let frame = CGRect(x: 0, y: (viewport.height - height) / 2, width: 430, height: height)
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.inpaintingEnabled = true
            settings.preserveSourceBackgroundColor = true
            settings.preserveSourceTextColor = true
            settings.opacity = 1
            let items = BrowserPageImageOverlayRenderer.layoutPayload(
                items: ReaderTranslationRegion.layoutItems(stored.map(\.region), imageSize: size),
                imageSize: size, sourceRect: frame, settings: settings, targetLanguage: "ko", viewport: viewport)
            let payload: [String: Any] = ["items": items, "viewport": [430, 932], "scale": 3,
                "imageSize": [cg.width, cg.height], "displayRect": [frame.minX, frame.minY, frame.width, frame.height],
                "appearance": ["inpaintingEnabled": true, "preserveSourceBackgroundColor": true,
                               "preserveSourceTextColor": true, "opacity": 1, "minimumReadableFontSize": 5]]
            try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
                .write(to: directory.appendingPathComponent("payload.json"))
        }
        try #require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("payload.json").path),
                     "Install the captured payload.json and original.image in Documents/CachedLayoutReplay before this explicit replay")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("payload.json"))) as? [String: Any])
        let expectationURL = directory.appendingPathComponent("expectations.json")
        let expectations = FileManager.default.fileExists(atPath: expectationURL.path)
            ? try #require(JSONSerialization.jsonObject(with: Data(contentsOf: expectationURL)) as? [String: Any]) : payload
        let viewport = try #require(payload["viewport"] as? [Double])
        let items = try #require(payload["items"])
        let appearance = try #require(payload["appearance"])
        let image = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.image").path))
        let encodedSource = try ReaderTranslationBackgroundImage.dataURL(for: image)
        let source = try #require(encodedSource)
        let prepared = try ReaderTranslationBackgroundImage.prepare(image)
        try #require(prepared.pngData())
            .write(to: directory.appendingPathComponent("prepared.png"))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: viewport[0], height: viewport[1]))
        web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:0'>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await web.callAsyncJavaScript(LegacyReaderTranslationOverlayView.backgroundScript,
            arguments: ["source": source, "fit": "contain", "revision": 1], in: nil, contentWorld: .page)
        _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderInstallAndCallScript,
            arguments: ["items": items, "appearance": appearance, "revision": "1", "session": "cached-replay",
                        "libraryVersion": BrowserPageImageOverlayRenderer.renderLibraryVersion],
            in: nil, contentWorld: .page)
        let audit = try await web.evaluateJavaScript("""
        JSON.stringify(Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay]')).map(n=>({
          kind:n.dataset.aidokuImageOcrOverlay,id:n.dataset.aidokuRegion,
          data:{...n.dataset},style:n.getAttribute('style'),
          ink:(()=>{const r=document.createRange();r.selectNodeContents(n);return [...r.getClientRects()]
            .filter(v=>v.width>0&&v.height>0).map(v=>[v.x,v.y,v.width,v.height]);})()})))
        """)
        let auditText = try #require(audit as? String)
        try Data(auditText.utf8).write(to: directory.appendingPathComponent("audit.json"))
        let snapshot = try await web.takeSnapshot(configuration: nil)
        try #require(snapshot.pngData()).write(to: directory.appendingPathComponent("render.png"))
        let count = try await web.evaluateJavaScript("document.querySelectorAll('[data-aidoku-image-ocr-overlay=item]').length")
        #expect((count as? Int ?? 0) > 0)
        for rule in expectations["styleRules"] as? [[String: Any]] ?? [] {
            let matches = try await web.callAsyncJavaScript("""
            const rgb=s=>(String(s).match(/[0-9.]+/g)||[]).slice(0,3).map(Number);
            const within=(value,minimum,maximum)=>value.length===3&&value.every((v,i)=>
              Number.isFinite(v)&&(!minimum||v>=minimum[i])&&(!maximum||v<=maximum[i]));
            return rule.ids.every(id=>{
              const node=Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=item]'))
                .find(n=>n.dataset.aidokuRegion===String(id));
              if(!node)return false;
              const css=getComputedStyle(node),width=parseFloat(css.webkitTextStrokeWidth)||0;
              return within(rgb(css.webkitTextFillColor),rule.minimumFill,rule.maximumFill)&&
                (!rule.minimumStroke&&!rule.maximumStroke||within(rgb(css.webkitTextStrokeColor),
                  rule.minimumStroke,rule.maximumStroke))&&
                (rule.minimumStrokeWidth===undefined||width>=rule.minimumStrokeWidth)&&
                (rule.maximumStrokeWidth===undefined||width<=rule.maximumStrokeWidth)&&
                (rule.fontSize===undefined||Math.abs(parseFloat(css.fontSize)-rule.fontSize)<.01)&&
                (rule.lineHeight===undefined||Math.abs(parseFloat(css.lineHeight)-rule.lineHeight)<.02);
            });
            """, arguments: ["rule": rule], in: nil, contentWorld: .page)
            #expect(matches as? Bool == true, "Final native lettering must satisfy independently supplied source-style bounds")
        }
        for id in expectations["expectedInpaintedIDs"] as? [String] ?? [] {
            let background = try await web.callAsyncJavaScript("""
            const node = Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=item]'))
              .find(n => n.dataset.aidokuRegion === id);
            const panels = Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=source-readability-panel]'))
              .filter(n => n.dataset.aidokuRegion === id);
            return node?.dataset.sourceBackgroundColor === 'inpainted' && panels.length === 0;
            """, arguments: ["id": id], in: nil, contentWorld: .page)
            #expect(background as? Bool == true, "Captured region \(id) must retain inpainting without a flat panel")
        }
        for id in expectations["expectedTopAlignedIDs"] as? [String] ?? [] {
            let error = try await web.callAsyncJavaScript("""
            const item=items.find(i=>String(i.id)===id);
            const node=Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay=item]'))
              .find(n=>n.dataset.aidokuRegion===id);
            if(!item||!node)return 999;
            const range=document.createRange();range.selectNodeContents(node);
            const rects=[...range.getClientRects()].filter(r=>r.width>0&&r.height>0);
            return Math.abs(Math.min(...rects.map(r=>r.top))-(item.sourceFrame[1]+item.sourceBounds[1]*item.sourceFrame[3]));
            """, arguments: ["id": id, "items": items], in: nil, contentWorld: .page)
            #expect((error as? Double ?? 999) <= 0.5, "Final glyphs must begin at the source top")
        }
        if let minimumErased = payload["minimumErasedPixels"] as? [String: Int] {
            let decodedAudit = try JSONSerialization.jsonObject(with: Data(auditText.utf8))
            let entries = try #require(decodedAudit as? [[String: Any]])
            let root = try #require(entries.first { $0["kind"] as? String == "root" }?["data"] as? [String: Any])
            let restoration = try #require(root["panelRestorationAudit"] as? String)
            let decodedRestoration = try JSONSerialization.jsonObject(with: Data(restoration.utf8))
            let repairs = try #require(decodedRestoration as? [[String: Any]])
            for (id, minimum) in minimumErased {
                let repair = try #require(repairs.first { $0["id"] as? String == id })
                #expect(repair["sourceErasureVerified"] as? Bool == true)
                #expect((repair["erased"] as? Int ?? 0) >= minimum, "The captured source outline must be removed too")
            }
        }
    }
}
