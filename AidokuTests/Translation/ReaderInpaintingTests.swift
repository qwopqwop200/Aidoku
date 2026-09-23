import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderInpaintingTests {
    @Test func retiredSwitchFollowsSourceAppearanceOnLoadAndSave() throws {
        let suite = UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var legacy = ReaderTranslationSettings.defaultOverlay
        legacy.appearance = .source
        legacy.inpaintingEnabled = false
        legacy.opacity = 0.65
        defaults.set(try JSONEncoder().encode(legacy), forKey: ReaderTranslationSettings.keyPrefix + "overlay")
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(settings.overlay.usesSourceInpainting)
        #expect(settings.overlay.opacity == 0.65)
        settings.overlay.inpaintingEnabled = false
        try settings.save(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).overlay.usesSourceInpainting)
    }

    @Test func settingsGateDefaultsAndLegacyDecoding() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        #expect(settings.inpaintingEnabled)
        #expect(!settings.usesSourceInpainting)
        settings.preserveSourceTextColor = true
        #expect(!settings.usesSourceInpainting)
        settings.preserveSourceColors = true
        #expect(settings.usesSourceInpainting)
        settings.inpaintingEnabled = false
        #expect(!settings.usesSourceInpainting)
        let encoded = try JSONEncoder().encode(settings)
        #expect(try JSONDecoder().decode(IPhoneOverlaySettings.self, from: encoded) == settings)
        var legacy = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        legacy.removeValue(forKey: "inpaintingEnabled")
        let decoded = try JSONDecoder().decode(IPhoneOverlaySettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(decoded.usesSourceInpainting)
        settings.preserveSourceColors = false
        #expect(!settings.preserveSourceTextColor && !settings.preserveSourceBackgroundColor)
    }

    @Test func inpaintingChangesRenderIdentityOnly() throws {
        let defaults = try #require(UserDefaults(suiteName: UUID().uuidString))
        var settings = ReaderTranslationSettings(defaults: defaults)
        settings.overlay.preserveSourceColors = true
        let ocr = ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings)
        let translation = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        func render(_ value: ReaderTranslationSettings) -> String {
            ReaderTranslationCacheIdentity.render(page: "page", settings: value,
                imageSize: CGSize(width: 600, height: 800), viewport: CGSize(width: 430, height: 800),
                scale: 3, aspectFit: true, crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: false)
        }
        let before = render(settings)
        settings.overlay.inpaintingEnabled = false
        #expect(render(settings) != before)
        #expect(ReaderTranslationCacheIdentity.ocr(page: "page", settings: settings) == ocr)
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: settings) == translation)
    }

    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("InpaintingQuality") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func realPagesKeepReadableTypeAndReduceCovering() async throws {
        struct Fixture: Decodable { let image: String; let regions: String; let name: String; let target: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        // An optional frozen production script isolates reconstruction changes
        // while keeping current layout, source colors and WebKit identical.
        let previousRestoration = try? String(contentsOf: Self.directory.appendingPathComponent("baseline-restoration.js"), encoding: .utf8)
        // A captured current production script can also be replayed without
        // coupling reconstruction experiments to concurrent layout builds.
        let candidateRestoration = try? String(contentsOf: Self.directory.appendingPathComponent("candidate-restoration.js"), encoding: .utf8)
        // Both comparison arms can share a frozen current sampler while other
        // renderer work continues. This keeps palette changes out of the delta.
        let sourceColors = try? String(contentsOf: Self.directory.appendingPathComponent("source-colors.js"), encoding: .utf8)
        // Keep current budgets unless an older budget experiment opts in.
        // Otherwise a new algorithm replay silently keeps comparing with v17.
        struct BaselineLimits: Decodable {
            let pagePixels: Int
            let cropPixels: Int
            let cacheBytes: Int
            let lookupPixels: Int
        }
        let limitsURL = Self.directory.appendingPathComponent("baseline-limits.json")
        let baselineLimits = try FileManager.default.fileExists(atPath: limitsURL.path)
            ? JSONDecoder().decode(BaselineLimits.self, from: Data(contentsOf: limitsURL)) : nil
        let output = Self.directory.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.rootViewController = UIViewController(); host.makeKeyAndVisible()
        defer { host.isHidden = true }
        var totalInpainted = 0, totalFallbacks = 0
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.image))
            let source = try #require(UIImage(data: data))
            let regionData = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.regions))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: regionData).map(\.region)
            try regionData.write(to: output.appendingPathComponent("\(fixture.name)-regions.json"))
            let size = CGSize(width: 430, height: 430 * source.size.height / source.size.width)
            let web = WKWebView(frame: CGRect(origin: .zero, size: size))
            web.scrollView.contentInsetAdjustmentBehavior = .never
            host.rootViewController?.view.addSubview(web)
            defer { web.removeFromSuperview() }
            web.loadHTMLString("""
            <meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0}img{display:block;width:100%}</style>
            <img id="reader-source-image" src="data:image/png;base64,\(data.base64EncodedString())">
            """, baseURL: nil)
            for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()", arguments: [:], in: nil, contentWorld: .page)
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.opacity = 1; settings.preserveSourceColors = true
            let items = ReaderTranslationRegion.overlayItems(regions, imageSize: source.size)
            var baseline: [[String: Any]] = []
            for mode in previousRestoration == nil ? ["box", "inpainting"] : ["box", "baseline", "inpainting"] {
                let enabled = mode != "box"
                settings.inpaintingEnabled = enabled
                let renderer = BrowserPageImageOverlayRenderer { webView, script, arguments in
                    var script = script
                    if let sourceColors {
                        script = script.replacingOccurrences(of: BrowserSourceTextColor.script, with: sourceColors)
                    }
                    if mode == "inpainting", let candidateRestoration {
                        script = script.replacingOccurrences(of: BrowserSourcePanelRestoration.script, with: candidateRestoration)
                    }
                    if mode == "baseline", let previousRestoration {
                        script = script.replacingOccurrences(of: BrowserSourcePanelRestoration.script, with: previousRestoration)
                            .replacingOccurrences(of: "'spatial-panel-", with: "'inpainting-replay-baseline-")
                        if let limits = baselineLimits {
                            script = script
                                .replacingOccurrences(of: "const panelRestorationPixelLimit = 1572864;", with: "const panelRestorationPixelLimit = \(limits.pagePixels);")
                                .replacingOccurrences(of: "Math.min(262144,Math.floor(panelRestorationBudget", with: "Math.min(\(limits.cropPixels),Math.floor(panelRestorationBudget")
                                .replacingOccurrences(of: "const limit = 16 * 1024 * 1024;", with: "const limit = \(limits.cacheBytes);")
                                .replacingOccurrences(of: "let restoredPanelLookupBudget = 4194304;", with: "let restoredPanelLookupBudget = \(limits.lookupPixels);")
                        }
                    }
                    do {
                        return try await BrowserPageImageOverlayRenderer.evaluateJavaScript(webView, script, arguments)
                    } catch {
                        print("Inpainting replay \(fixture.name) [\(mode)]: \((error as NSError).userInfo)")
                        throw error
                    }
                }
                renderer.render(on: web, items: items,
                    imageSize: source.size, sourceRect: CGRect(origin: .zero, size: size), settings: settings, targetLanguage: fixture.target)
                for _ in 0..<600 where renderer.lastDiagnostic == nil { try await Task.sleep(for: .milliseconds(20)) }
                // Unchanged numbers/names intentionally preserve the source.
                // An all-preserved page clears the overlay and still needs a snapshot.
                #expect(renderer.lastDiagnostic?.outcome == (items.isEmpty ? .cleared : .committed),
                        "Replay \(fixture.name) [\(mode)]")
                let raw = try await web.evaluateJavaScript("""
                (()=>({root:{panelRestorationPixels:'0',cleanupCacheBytes:'0',cleanupMilliseconds:'0',panelRestorationAudit:'[]',
                  ...document.querySelector('[data-aidoku-image-ocr-overlay="root"]')?.dataset},
                  items:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>({
                    ...n.dataset,text:n.textContent,font:parseFloat(getComputedStyle(n).fontSize),
                    x:n.offsetLeft,y:n.offsetTop,width:n.offsetWidth,height:n.offsetHeight})),
                  panelArea:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')].reduce((a,n)=>a+n.offsetWidth*n.offsetHeight,0),
                  restored:document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-panel-restoration"]').length}))()
                """)
                var report = try #require(raw as? [String: Any])
                let rubyBoxes = regions.flatMap(\.auxiliaryInkRects).map { [$0.minX, $0.minY, $0.width, $0.height] }
                if !rubyBoxes.isEmpty {
                    report["rubyPixels"] = try await web.callAsyncJavaScript("""
                    const image=document.getElementById('reader-source-image'),iw=image.naturalWidth,ih=image.naturalHeight;
                    const canvas=document.createElement('canvas');canvas.width=iw;canvas.height=ih;
                    const context=canvas.getContext('2d',{willReadFrequently:true});context.drawImage(image,0,0);
                    const before=context.getImageData(0,0,iw,ih).data,frame=image.getBoundingClientRect();
                    for(const layer of document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-panel-restoration"]')){
                      const r=layer.getBoundingClientRect();
                      context.drawImage(layer,(r.left-frame.left)/frame.width*iw,(r.top-frame.top)/frame.height*ih,
                        r.width/frame.width*iw,r.height/frame.height*ih);
                    }
                    const after=context.getImageData(0,0,iw,ih).data,seen=new Set();
                    let ink=0,removed=0;
                    for(const b of rubyBoxes)for(let y=Math.max(0,Math.floor(b[1]*ih));y<Math.min(ih,Math.ceil((b[1]+b[3])*ih));y++)
                      for(let x=Math.max(0,Math.floor(b[0]*iw));x<Math.min(iw,Math.ceil((b[0]+b[2])*iw));x++){
                        const i=y*iw+x;if(seen.has(i))continue;seen.add(i);const p=i*4;
                        if(Math.max(before[p],before[p+1],before[p+2])>100)continue;
                        ink++;if(Math.min(after[p],after[p+1],after[p+2])>=150)removed++;
                      }
                    canvas.width=0;canvas.height=0;
                    return {ink,removed,remaining:ink-removed,definition:'dark pixels in fixed ruby annotations; no hidden-background ground truth'};
                    """, arguments: ["rubyBoxes": rubyBoxes], in: nil, contentWorld: .page)
                }
                let root = try #require(report["root"] as? [String: Any])
                #expect((Int(root["panelRestorationPixels"] as? String ?? "") ?? Int.max) <= (mode == "baseline" ? baselineLimits?.pagePixels ?? 1_572_864 : 1_572_864))
                #expect((Int(root["cleanupCacheBytes"] as? String ?? "") ?? Int.max) <= 16 * 1_024 * 1_024)
                let rows = try #require(report["items"] as? [[String: Any]])
                #expect(rows.isEmpty == items.isEmpty)
                if items.isEmpty {
                    let allPreserved = regions.allSatisfy { $0.preservesOriginalText }
                    #expect(allPreserved)
                    #expect(report["restored"] as? Int == 0)
                    report["preservedOriginals"] = regions.count
                }
                if !enabled { baseline = rows; #expect(report["restored"] as? Int == 0) }
                else {
                    #expect(rows.count == baseline.count)
                    for row in rows {
                        if fixture.name.hasPrefix("user-") {
                            let ink = (row["sourceAppliedTextRGB"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
                            #expect(ink.count == 3 && ink.allSatisfy { $0 < 25 })
                            #expect(row["sourceBackgroundColor"] as? String == "inpainted")
                        }
                        let previous = try #require(baseline.first { $0["aidokuRegion"] as? String == row["aidokuRegion"] as? String })
                        #expect(row["text"] as? String == previous["text"] as? String)
                        if row["sourceBackgroundColor"] as? String == "inpainted" {
                            totalInpainted += 1
                            let contrast = Double(row["sourcePanelMinimumContrast"] as? String ?? "") ?? 0
                            #expect(contrast >= 4.5)
                            #expect(row["sourcePanelTextFit"] as? String == "inside")
                            let font = try #require(row["font"] as? Double)
                            let beforeFont = try #require(previous["font"] as? Double)
                            #expect(font >= beforeFont - 0.01)
                        } else { totalFallbacks += 1 }
                    }
                }
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("\(fixture.name)-\(mode).json"))
                _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
                let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                try #require(image.pngData()).write(to: output.appendingPathComponent("\(fixture.name)-\(mode).png"))
                if enabled {
                    _ = try await web.evaluateJavaScript("""
                    document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"],[data-aidoku-image-ocr-overlay="source-readability-panel"]').forEach(n=>n.style.visibility='hidden');
                    """)
                    _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
                    let cleaned: UIImage = try await withCheckedThrowingContinuation { continuation in
                        web.takeSnapshot(with: nil) { image, error in
                            if let image { continuation.resume(returning: image) }
                            else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                        }
                    }
                    try #require(cleaned.pngData()).write(to: output.appendingPathComponent("\(fixture.name)-\(mode)-cleaned.png"))
                }
                renderer.cancelPendingRender()
            }
        }
        #expect(totalInpainted > 0)
        #expect(totalFallbacks > 0)
    }
}
