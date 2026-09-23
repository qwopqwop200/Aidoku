import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Replays actual device OCR and translations against the original cached page.
/// Fixtures stay outside the repository; no provider or OCR result is mocked.
@Suite(.serialized)
@MainActor
struct ReaderPanelIncidentTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("PanelIncidents") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func capturedDevicePages() async throws {
        struct Fixture: Decodable {
            let name: String
            let language: String?
            let maximumPanels: Int?
            let captureCrops: Bool?
            let maximumSourceCenterOffset: [String: Double]?
            let erasedInkProbes: [[Double]]?
        }
        let fixtures = try JSONDecoder().decode([Fixture].self,
            from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        let label = try String(contentsOf: Self.directory.appendingPathComponent("label.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let output = Self.directory.appendingPathComponent(label)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try BrowserPageImageOverlayRenderer.renderScript.write(to: output.appendingPathComponent("render.js"), atomically: true, encoding: .utf8)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.name + ".png"))
            let image = try #require(UIImage(data: data))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
                from: Data(contentsOf: Self.directory.appendingPathComponent(fixture.name + ".json"))).map(\.region)
            let items = ReaderTranslationRegion.overlayItems(regions, imageSize: image.size)
            let size = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            let web = WKWebView(frame: CGRect(origin: .zero, size: size))
            web.scrollView.contentInsetAdjustmentBehavior = .never
            window.rootViewController?.view.addSubview(web)
            defer { web.removeFromSuperview() }
            web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}img{display:block;width:100%}</style><img id='reader-source-image' src='data:image/png;base64,\(data.base64EncodedString())'>", baseURL: nil)
            for _ in 0..<500 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()", arguments: [:], in: nil, contentWorld: .page)
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.preserveSourceColors = true; settings.inpaintingEnabled = true
            let payload = BrowserPageImageOverlayRenderer.layoutPayload(items: items, imageSize: image.size,
                sourceRect: CGRect(origin: .zero, size: size), settings: settings,
                targetLanguage: fixture.language ?? "ko", viewport: size)
            // Read-only instrumentation captures the same pixel input given to
            // restoration, so a failed mask can be replayed independently.
            let override = Self.directory.appendingPathComponent("renderer.js")
            let renderScript = FileManager.default.fileExists(atPath: override.path)
                ? try String(contentsOf: override, encoding: .utf8) : BrowserPageImageOverlayRenderer.renderScript
            let instrumented = fixture.captureCrops == false ? renderScript : renderScript
                .replacingOccurrences(of: "const restored=aidokuRestoreSourcePanel", with: """
                globalThis.__incidentCrops.push({id:String(item.id),x,y,w,h,sx,sy,b,palette,auxiliary,rubyExclusions,leadingRule,
                  vertical:Boolean(item.sourceVertical),iw,ih,image:cleanupCanvas.toDataURL('image/png')});
                const restored=aidokuRestoreSourcePanel
                """)
            let script = "globalThis.__incidentCrops=[];\n" + instrumented
            let start = Date()
            _ = try await web.callAsyncJavaScript(script,
                arguments: ["revision": "1", "session": fixture.name, "items": payload,
                    "appearance": ["opacity": 1, "preserveSourceTextColor": true,
                        "preserveSourceBackgroundColor": true, "inpaintingEnabled": true,
                        "minimumReadableFontSize": 5]], in: nil, contentWorld: .page)
            let audit = try #require(try await web.evaluateJavaScript(#"""
            (()=>{
              const rect=r=>[r.x,r.y,r.width,r.height];
              const nodes=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>{
                const s=getComputedStyle(n),range=document.createRange();range.selectNodeContents(n);
                return {...n.dataset,text:n.textContent,frame:rect(n.getBoundingClientRect()),ink:rect(range.getBoundingClientRect()),
                  font:parseFloat(s.fontSize),color:s.color,visibility:s.visibility,
                  overflow:n.scrollHeight>n.clientHeight+1||n.scrollWidth>n.clientWidth+1};
              });
              const panels=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"], [data-aidoku-image-ocr-overlay="source-readability-backing"]')]
                .map(n=>({...n.dataset,frame:rect(n.getBoundingClientRect()),color:n.style.backgroundColor,clip:n.style.clipPath}));
              const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
              return {nodes,panels,root:root?{...root.dataset}:{},crops:globalThis.__incidentCrops};
            })()
            """#) as? [String: Any])
            let directColumns = BrowserOverlayColumnLayout.plan(
                sources: regions.map { CGRect(x: $0.rect.minX * size.width, y: $0.rect.minY * size.height,
                    width: $0.rect.width * size.width, height: $0.rect.height * size.height) },
                variants: regions.map { .plain($0.translation ?? "", vertical: false) },
                eligible: regions.map { _ in true }, bounds: CGRect(origin: .zero, size: size), measurementCache: .init())
            try JSONSerialization.data(withJSONObject: ["audit": audit, "payload": payload,
                "directColumns": Dictionary(uniqueKeysWithValues: directColumns.map { (String($0.key), [$0.value.rect.minX, $0.value.rect.minY, $0.value.rect.width, $0.value.rect.height, $0.value.maximumFontSize]) }),
                "milliseconds": Date().timeIntervalSince(start) * 1000], options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent(fixture.name + ".json"))
            _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                web.takeSnapshot(with: nil) { image, error in
                    if let image { continuation.resume(returning: image) }
                    else { continuation.resume(throwing: error ?? CancellationError()) }
                }
            }
            try snapshot.pngData()?.write(to: output.appendingPathComponent(fixture.name + ".png"))
            for probe in fixture.erasedInkProbes ?? [] {
                #expect(probe.count == 6)
                guard probe.count == 6 else { continue }
                let cgImage = try #require(snapshot.cgImage)
                let pixel = try #require(cgImage.cropping(to: CGRect(
                    x: floor(probe[0] * Double(cgImage.width)),
                    y: floor(probe[1] * Double(cgImage.height)), width: 1, height: 1)))
                var rgba = [UInt8](repeating: 0, count: 4)
                let sampled = rgba.withUnsafeMutableBytes { bytes -> Bool in
                    guard let context = CGContext(data: bytes.baseAddress, width: 1, height: 1,
                        bitsPerComponent: 8, bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                    context.draw(pixel, in: CGRect(x: 0, y: 0, width: 1, height: 1))
                    return true
                }
                #expect(sampled)
                #expect((0..<3).allSatisfy { abs(Double(rgba[$0]) - probe[$0 + 2]) <= probe[5] },
                    "\(fixture.name): source ruby/punctuation must remain erased")
            }
            let nodes = try #require(audit["nodes"] as? [[String: Any]])
            #expect(nodes.count == payload.count)
            for node in nodes {
                #expect(node["overflow"] as? Bool == false)
                let id = try #require(node["aidokuRegion"] as? String)
                #expect(node["text"] as? String == payload.first { $0["id"] as? String == id }?["text"] as? String)
                if let maximum = fixture.maximumSourceCenterOffset?[id] {
                    let ink = try #require(node["ink"] as? [Double])
                    let item = try #require(payload.first(where: { $0["id"] as? String == id }))
                    let source = try #require(item["sourceBounds"] as? [CGFloat])
                    let sourceCenter = (source[0] + source[2] / 2) * size.width
                    #expect(abs(ink[0] + ink[2] / 2 - sourceCenter) <= maximum,
                        "\(fixture.name)/\(id) must stay anchored after panel compaction")
                }
            }
            if let maximum = fixture.maximumPanels {
                #expect(try #require(audit["panels"] as? [[String: Any]]).count <= maximum)
            }
        }
    }
}
