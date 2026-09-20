import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderInpaintingTests {
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
            var baseline: [[String: Any]] = []
            for enabled in [false, true] {
                settings.inpaintingEnabled = enabled
                let renderer = BrowserPageImageOverlayRenderer()
                renderer.render(on: web, items: ReaderTranslationRegion.overlayItems(regions, imageSize: source.size),
                    imageSize: source.size, sourceRect: CGRect(origin: .zero, size: size), settings: settings, targetLanguage: fixture.target)
                for _ in 0..<600 where renderer.lastDiagnostic == nil { try await Task.sleep(for: .milliseconds(20)) }
                #expect(renderer.lastDiagnostic?.outcome == .committed)
                let raw = try await web.evaluateJavaScript("""
                (()=>({root:{...document.querySelector('[data-aidoku-image-ocr-overlay="root"]').dataset},
                  items:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>({
                    ...n.dataset,text:n.textContent,font:parseFloat(getComputedStyle(n).fontSize),
                    x:n.offsetLeft,y:n.offsetTop,width:n.offsetWidth,height:n.offsetHeight})),
                  panelArea:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')].reduce((a,n)=>a+n.offsetWidth*n.offsetHeight,0),
                  restored:document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-panel-restoration"]').length}))()
                """)
                let report = try #require(raw as? [String: Any])
                let rows = try #require(report["items"] as? [[String: Any]])
                #expect(!rows.isEmpty)
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
                let mode = enabled ? "inpainting" : "box"
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
                renderer.cancelPendingRender()
            }
        }
        #expect(totalInpainted > 0)
        #expect(totalFallbacks > 0)
    }
}
