import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Explicit real-image regression for the two narrow neighbouring speech balloons.
@Suite(.serialized)
@MainActor
struct ReaderSmallBalloonReplayTests {
    @Test
    func originalPage() async throws {
        try await replay(URL.documentsDirectory.appendingPathComponent("SmallBalloonReplay"))
    }

    private func replay(_ directory: URL) async throws {
        let cgImage = try #require(UIImage(contentsOfFile: directory.appendingPathComponent("original.image").path)?.cgImage)
        var regions = try await ReaderOCRService.shared.recognize(image: cgImage, configuration: .init(
            detectorMaximumSide: 2000, confidenceThreshold: 0.35, detectorPixelThreshold: 0.3, detectorConfidenceThreshold: 0.3))
        for index in regions.indices {
            let x = regions[index].rect.midX
            regions[index].translation = x > 0.93 ? "치..." : x > 0.85 ? "음(승인가)" : x > 0.5 ? "퐁냐!" : "자○지냐냥?"
        }
        try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init))
            .write(to: directory.appendingPathComponent("regions.json"))
        let size = CGSize(width: cgImage.width, height: cgImage.height)
        let layoutViewport = CGSize(width: 430, height: 932)
        let height = 430 * size.height / size.width
        let frame = CGRect(x: 0, y: (layoutViewport.height - height) / 2, width: 430, height: height)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.inpaintingEnabled = true
        settings.preserveSourceBackgroundColor = true
        settings.preserveSourceTextColor = true
        settings.opacity = 1
        let layoutItems = BrowserPageImageOverlayRenderer.layoutPayload(
            items: ReaderTranslationRegion.layoutItems(regions, imageSize: size),
            imageSize: size, sourceRect: frame, settings: settings, targetLanguage: "ko", viewport: layoutViewport)
        let generatedPayload: [String: Any] = ["items": layoutItems, "viewport": [430, 932], "scale": 3,
            "imageSize": [cgImage.width, cgImage.height], "displayRect": [frame.minX, frame.minY, frame.width, frame.height],
            "appearance": ["inpaintingEnabled": true, "preserveSourceBackgroundColor": true,
                           "preserveSourceTextColor": true, "opacity": 1, "minimumReadableFontSize": 5]]
        try JSONSerialization.data(withJSONObject: generatedPayload, options: [.sortedKeys])
            .write(to: directory.appendingPathComponent("payload.json"))
        try #require(FileManager.default.fileExists(atPath: directory.appendingPathComponent("payload.json").path),
                     "Install the captured payload.json and original.image in Documents/CachedLayoutReplay before this explicit replay")
        let payload = try #require(JSONSerialization.jsonObject(with: Data(contentsOf:
            directory.appendingPathComponent("payload.json"))) as? [String: Any])
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
        _ = try await web.callAsyncJavaScript(ReaderTranslationOverlayView.backgroundScript,
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
        let verified = try await web.callAsyncJavaScript("""
        return (()=>{
          const nodes=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay=item]')];
          const one=nodes.find(n=>n.dataset.aidokuRegion==='1'),two=nodes.find(n=>n.dataset.aidokuRegion==='2');
          if(one?.dataset.sourceBackgroundColor!=='inpainted'||two?.dataset.slantedSourceErased!=='true')return false;
          if(document.querySelector('[data-aidoku-image-ocr-overlay=source-readability-panel], [data-aidoku-image-ocr-overlay=source-rotated-panel]'))return false;
          if(nodes.some(n=>n.dataset.sourceTopAnchored==='true'))return false;
          const punctuation=document.createRange();punctuation.selectNodeContents(one);
          const rows=[...punctuation.getClientRects()].filter(r=>r.width>0&&r.height>0);
          if(Math.max(...rows.map(r=>r.top))-Math.min(...rows.map(r=>r.top))>1)return false;
          for(const id of ['0','3']){
            const node=nodes.find(n=>n.dataset.aidokuRegion===id);
            const range=document.createRange();range.selectNodeContents(node);
            const rects=[...range.getClientRects()].filter(r=>r.width>0&&r.height>0);
            const center=(Math.min(...rects.map(r=>r.top))+Math.max(...rects.map(r=>r.bottom)))/2;
            const item=items.find(i=>String(i.id)===id),b=item.sourceBounds,f=item.sourceFrame;
            if(Math.abs(center-(f[1]+(b[1]+b[3]/2)*f[3]))>8)return false;
          }
          return true;
        })()
        """, arguments: ["items": items], in: nil, contentWorld: .page)
        #expect(verified as? Bool == true, "Both narrow balloons must erase without panels; dialogue must not be top anchored")
    }
}
