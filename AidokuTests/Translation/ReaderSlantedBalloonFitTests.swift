import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSlantedBalloonFitTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("SlantedText") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func recoveredRubyAlsoFitsInTheActualRenderer() async throws {
        struct Fixture: Decodable {
            let id: String
            let source: String
            let translation: String
            let orientation: String
            let cropPolygon: [[Double]]
            let auxiliaryInkRects: [[Double]]?
            let auxiliaryInkPolygons: [[[Double]]]?
        }
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        let partialSources = ["diverse2-3428-g8", "diverse-2238-g7-art-en"]
        let ids = ["ruby-05--25", "ruby-05-+25", "ruby-05-+78", "ruby-04--45"] + partialSources
        #expect(ids.allSatisfy { id in fixtures.contains { $0.id == id } })
        let output = Self.directory.appendingPathComponent("balloon-fit")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for fixture in fixtures where ids.contains(fixture.id) {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.id + ".png"))
            let image = try #require(UIImage(data: data))
            let points = fixture.cropPolygon.map { CGPoint(x: $0[0], y: $0[1]) }
            let rect = CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
                width: points.map(\.x).max()! - points.map(\.x).min()!,
                height: points.map(\.y).max()! - points.map(\.y).min()!)
            let size = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            let web = WKWebView(frame: CGRect(origin: .zero, size: size))
            web.scrollView.contentInsetAdjustmentBehavior = .never
            window.rootViewController?.view.addSubview(web)
            defer { web.removeFromSuperview() }
            web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}img{display:block;width:100%}</style><img id='reader-source-image' src='data:image/png;base64,\(data.base64EncodedString())'>", baseURL: nil)
            for _ in 0..<500 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()",
                arguments: [:], in: nil, contentWorld: .page)
            let item = BrowserOverlayItem(stableRegionID: 0, rect: rect, sourceText: fixture.source,
                translatedText: fixture.translation, confidence: 0.99,
                sourceOrientation: .init(tolerantRawValue: fixture.orientation),
                sourceSingleVerticalColumn: fixture.orientation == "vertical", sourcePolygon: points,
                auxiliaryInkRects: (fixture.auxiliaryInkRects ?? []).map { CGRect(x: $0[0], y: $0[1], width: $0[2], height: $0[3]) },
                auxiliaryInkPolygons: (fixture.auxiliaryInkPolygons ?? []).map { $0.map { CGPoint(x: $0[0], y: $0[1]) } })
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.preserveSourceColors = true
            settings.inpaintingEnabled = true
            let payload = BrowserPageImageOverlayRenderer.layoutPayload(items: [item], imageSize: image.size,
                sourceRect: CGRect(origin: .zero, size: size), settings: settings, targetLanguage: "ko", viewport: size)
            var script = BrowserPageImageOverlayRenderer.renderScript
            script = script.replacingOccurrences(of: "const result=prepared.restored;",
                with: "const result=prepared.restored;window.__slantedDiagnostic={palette,box,w,h,geometry,method:result?.method,erased:result?.erased};")
            _ = try await web.callAsyncJavaScript(script,
                arguments: ["revision": "1", "session": fixture.id, "items": payload,
                    "appearance": ["opacity": 1, "preserveSourceTextColor": true, "preserveSourceBackgroundColor": true,
                        "inpaintingEnabled": true, "minimumReadableFontSize": 5]], in: nil, contentWorld: .page)
            let audit = try #require(try await web.evaluateJavaScript(#"""
            (()=>{const n=document.querySelector('[data-aidoku-image-ocr-overlay="item"]'),s=getComputedStyle(n);
              return {...n.dataset,text:n.textContent,font:parseFloat(s.fontSize),visibility:s.visibility,
                overflow:n.scrollHeight>n.clientHeight+1||n.scrollWidth>n.clientWidth+1,
                diagnostic:window.__slantedDiagnostic||null};})()
            """#) as? [String: Any])
            try JSONSerialization.data(withJSONObject: ["audit": audit, "payload": payload],
                options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent(fixture.id + ".json"))
            _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))",
                arguments: [:], in: nil, contentWorld: .page)
            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CancellationError()) }
                }
            }
            try snapshot.pngData()?.write(to: output.appendingPathComponent(fixture.id + ".png"))
            #expect(audit["text"] as? String == fixture.translation)
            #expect(audit["overflow"] as? Bool == false)
            if partialSources.contains(fixture.id) {
                // Misgrouped source strips leave adjacent words outside their
                // quads. They must retain the original rather than newly commit
                // a partial translation via paragraph reflow.
                #expect(audit["slantedSourceErased"] as? String == "false")
                #expect(audit["visibility"] as? String == "hidden")
            } else {
                #expect(audit["slantedSourceErased"] as? String == "true", "\(fixture.id) must visibly apply the recovered source")
                #expect(audit["visibility"] as? String == "visible", "\(fixture.id) cannot pass by hiding translation")
            }
            let fontFloor = try #require((audit["slantedFontFloor"] as? String).flatMap(Double.init))
            #expect((audit["font"] as? Double ?? 0) >= fontFloor)
            let contrast = (audit["sourceContrastAfter"] as? String).flatMap(Double.init)
            #expect((contrast ?? 0) >= 4.5)
        }
    }
}
