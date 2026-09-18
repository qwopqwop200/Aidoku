import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSourceInkRestorationTests {
    private nonisolated static var folder: URL { URL.documentsDirectory.appendingPathComponent("InkRestoration") }

    @Test func haloIsBoundedAndProtectsDrawingAndDifferentColors() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html><body></body></html>", baseURL: nil)
        while web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let value = try await web.callAsyncJavaScript(BrowserSourceInkCleanup.script + """
        const w=30,h=30,n=w*h,rgba=new Uint8ClampedArray(n*4),mask=new Uint8Array(n),protect=new Uint8Array(n);
        for(let i=0;i<n;i++)rgba.set([195,195,199,255],i*4);
        const pixel=(x,y,color)=>rgba.set([...color,255],(y*w+x)*4);
        mask[10*w+10]=1;
        pixel(12,10,[225,225,228]); // Detached outline fringe, two pixels away.
        pixel(13,10,[225,225,228]); // Must not grow from the repaired fringe.
        pixel(9,9,[200,40,40]); // Different-color artwork near the same glyph.
        pixel(10,8,[220,220,223]);
        protect[7*w+10]=1; // Preserve the one-pixel moat around protected art.
        aidokuRecoverInkHalo(rgba,w,h,mask,[10,10,14],[195,195,199],[251,251,253],protect);
        return {fringe:mask[10*w+12],distant:mask[10*w+13],color:mask[9*w+9],
          moat:mask[8*w+10],protected:mask[7*w+10],seed:mask[10*w+10],border:mask[0]};
        """, arguments: [:], in: nil, contentWorld: .page)
        let result = try #require(value as? [String: Int])
        #expect(result["fringe"] == 1)
        #expect(result["seed"] == 1)
        for key in ["distant", "color", "moat", "protected", "border"] { #expect(result[key] == 0) }
    }

    // Opt-in local corpus replay: no OCR/provider requests or credentials. The
    // same native layout, image and WKWebView render both cleanup implementations.
    @Test(.enabled(if: FileManager.default.fileExists(atPath: folder.appendingPathComponent("run.json").path)))
    func compareRealPageCleanup() async throws {
        let folder = Self.folder
        let names = try JSONDecoder().decode([String].self, from: Data(contentsOf: folder.appendingPathComponent("run.json")))
        let oldInk = try String(contentsOf: folder.appendingPathComponent("baseline-ink.js"), encoding: .utf8)
        let candidate = BrowserPageImageOverlayRenderer.renderScript
        let baseline = candidate.replacingOccurrences(of: BrowserSourceInkCleanup.script, with: oldInk)
            .replacingOccurrences(
                of: "const neutralFallbackEligible = Boolean(item.sourceCleanup && cleanupBG && Math.max(...cleanupBG) < 250);",
                with: "const neutralFallbackEligible = false;")
        #expect(candidate != baseline)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene), controller = UIViewController()
        window.rootViewController = controller
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        let suite = "AidokuTests.InkRestoration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.targetLanguage = "ko"
        settings.overlay.preserveSourceTextColor = true
        var reports: [[String: Any]] = []
        for name in names {
            let image = try #require(UIImage(contentsOfFile: folder.appendingPathComponent(name + ".png").path))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
                from: Data(contentsOf: folder.appendingPathComponent(name + "-regions.json"))).map(\.region)
            let size = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            for preserveBackground in [false, true] {
                settings.overlay.preserveSourceBackgroundColor = preserveBackground
                let mode = preserveBackground ? "both" : "ink"
                let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
                controller.view.addSubview(overlay)
                overlay.update(regions: regions, imageSize: image.size, aspectFit: false, settings: settings, image: image)
                for _ in 0..<600 {
                    if overlay.lastDiagnostic?.outcome == .committed { break }
                    try await Task.sleep(for: .milliseconds(50))
                }
                #expect(overlay.lastDiagnostic?.outcome == .committed)
                let encoded = try await BrowserPageImageOverlayRenderer.prepareLayoutData(
                    items: ReaderTranslationRegion.overlayItems(regions, imageSize: image.size), imageSize: image.size,
                    sourceRect: CGRect(origin: .zero, size: size), settings: settings.overlay,
                    targetLanguage: settings.targetLanguage, viewport: size)
                let payload = try #require(JSONSerialization.jsonObject(with: encoded) as? [[String: Any]])
                try encoded.write(to: folder.appendingPathComponent(name + "-" + mode + "-layout.json"))
                for (variant, script) in [("baseline", baseline), ("candidate", candidate)] {
                    // Separate worlds prevent an accepted mask from one variant
                    // being reused by the other, while DOM/source/layout stay fixed.
                    let world = WKContentWorld.world(name: "ink-" + UUID().uuidString)
                    for iteration in 0..<3 {
                        let result = try await overlay.webView.callAsyncJavaScript(script, arguments: [
                            "items": payload, "revision": String(iteration + 1), "session": UUID().uuidString,
                            "appearance": ["opacity": settings.overlay.opacity,
                                "preserveSourceTextColor": true, "preserveSourceBackgroundColor": preserveBackground,
                                "minimumReadableFontSize": BrowserOverlayLayoutPlanner.minimumRenderedFontSize]
                        ], in: nil, contentWorld: world)
                        let status = try #require(result as? [String: Any])
                        #expect(status["status"] as? String == "committed")
                        let audit = try await overlay.webView.evaluateJavaScript("""
                        (() => {
                        const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
                        return {stats:{...root.dataset},dom:Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')).map(n=>{
                          const s=getComputedStyle(n);return {text:n.textContent,background:s.backgroundColor,
                            color:s.color,blur:s.webkitBackdropFilter,font:s.fontSize,
                            overflow:n.scrollWidth>n.clientWidth+1||n.scrollHeight>n.clientHeight+1};})};
                        })()
                        """)
                        reports.append(["page": name, "mode": mode, "variant": variant,
                                        "iteration": iteration, "audit": audit])
                        if iteration == 0 {
                            _ = try await overlay.webView.callAsyncJavaScript(
                                "await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))",
                                arguments: [:], in: nil, contentWorld: world)
                            let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                                overlay.webView.takeSnapshot(with: nil) { value, error in
                                    if let value { continuation.resume(returning: value) }
                                    else { continuation.resume(throwing: error ?? CancellationError()) }
                                }
                            }
                            try snapshot.pngData()?.write(to: folder.appendingPathComponent(name + "-" + mode + "-" + variant + ".png"))
                        }
                    }
                }
                overlay.removeFromSuperview()
            }
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys])
            .write(to: folder.appendingPathComponent("render-audit.json"))
    }
}
