import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSourceTextColorTests {
    @Test func defaultsMigrationPersistenceAndCacheIdentity() throws {
        let suite = "source-color-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var settings = ReaderTranslationSettings(defaults: defaults)
        #expect(!settings.overlay.preserveSourceTextColor)
        #expect(!settings.overlay.preserveSourceBackgroundColor)
        var legacy = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(settings.overlay)) as? [String: Any])
        legacy.removeValue(forKey: "preserveSourceTextColor")
        legacy.removeValue(forKey: "preserveSourceBackgroundColor")
        let decoded = try JSONDecoder().decode(IPhoneOverlaySettings.self, from: JSONSerialization.data(withJSONObject: legacy))
        #expect(!decoded.preserveSourceTextColor)
        #expect(!decoded.preserveSourceBackgroundColor)
        func renderKey(_ settings: ReaderTranslationSettings) -> String {
            ReaderTranslationCacheIdentity.render(page: "page", settings: settings, imageSize: CGSize(width: 600, height: 900),
                viewport: CGSize(width: 390, height: 585), scale: 3, aspectFit: true,
                crop: CGRect(x: 0, y: 0, width: 1, height: 1), dark: false)
        }
        let before = renderKey(settings)
        let translation = ReaderTranslationCacheIdentity.translation(page: "page", settings: settings)
        settings.overlay.preserveSourceTextColor = true
        try settings.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).overlay.preserveSourceTextColor)
        #expect(renderKey(settings) != before)
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: settings) == translation)
        settings.overlay.preserveSourceTextColor = false
        try settings.autosave(defaults: defaults)
        #expect(!ReaderTranslationSettings(defaults: defaults).overlay.preserveSourceTextColor)
        #expect(renderKey(settings) == before)
        settings.overlay.preserveSourceBackgroundColor = true
        try settings.autosave(defaults: defaults)
        let panelOnly = ReaderTranslationSettings(defaults: defaults)
        #expect(panelOnly.overlay.preserveSourceBackgroundColor && !panelOnly.overlay.preserveSourceTextColor)
        #expect(renderKey(settings) != before)
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: settings) == translation)
        settings.overlay.preserveSourceTextColor = true
        #expect(renderKey(settings) != renderKey(panelOnly))
        settings.overlay.preserveSourceBackgroundColor = false
        try settings.autosave(defaults: defaults)
        #expect(!ReaderTranslationSettings(defaults: defaults).overlay.preserveSourceBackgroundColor)
    }

    @Test func estimatesSolidInkAndRejectsAmbiguousPixels() async throws {
        let web = WKWebView()
        web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const run = (foreground, background, style = '') => {
          const canvas = document.createElement('canvas'); canvas.width = 180; canvas.height = 80;
          const ctx = canvas.getContext('2d');
          ctx.fillStyle = background; ctx.fillRect(0, 0, 180, 80);
          ctx.font = 'bold 34px sans-serif'; ctx.fillStyle = foreground;
          if (style === 'art') { ctx.fillRect(15, 15, 80, 35); }
          else if (style !== 'blank') {
            ctx.fillText('HELLO', 15, 49);
            if (style === 'mixed') { ctx.fillStyle = '#0000c0'; ctx.fillText('LO', 80, 49); }
          }
          return aidokuEstimateTextColor(ctx.getImageData(0, 0, 180, 80).data, 180, 80);
        };
        return {
          red: run('#b02030', '#ffffff'), blue: run('#2030b0', '#ffffff'),
          black: run('#101010', '#ffffff'), white: run('#ffffff', '#101010'),
          blank: run('#b02030', '#ffffff', 'blank'), art: run('#b02030', '#ffffff', 'art'),
          mixed: run('#b02030', '#ffffff', 'mixed'),
          redOnWhite: aidokuReadableSourceColor([176,32,48], true, 0.84),
          whiteOnWhite: aidokuReadableSourceColor([255,255,255], true, 0.84),
          whiteOnDark: aidokuReadableSourceColor([255,255,255], false, 0.84),
          lowContrast: aidokuReadableSourceColor([160,160,160], true, 0.2),
          translucent: aidokuEstimateTextColor(new Uint8Array(16 * 16 * 4), 16, 16)
        };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let values = try #require(result)
        for (key, expected) in [("red", [176, 32, 48]), ("blue", [32, 48, 176]),
                                ("black", [16, 16, 16]), ("white", [255, 255, 255])] {
            let actual = try #require(values[key] as? [Int], "Missing estimate for \(key)")
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 8 })
        }
        for key in ["blank", "art", "mixed", "whiteOnWhite", "lowContrast", "translucent"] {
            #expect(values[key] is NSNull, "Expected conservative fallback for \(key)")
        }
        #expect(values["redOnWhite"] as? [Int] == [176, 32, 48])
        #expect(values["whiteOnDark"] as? [Int] == [255, 255, 255])
    }

    @Test func liveToggleRestoresPaletteAndReusesSourceSample() async throws {
        let (host, overlay) = try makeOverlay(size: CGSize(width: 390, height: 260))
        defer { overlay.cancelWork(); host.isHidden = true }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 260), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 390, height: 260))
            ("HELLO" as NSString).draw(at: CGPoint(x: 65, y: 70), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor(red: 176/255, green: 32/255, blue: 48/255, alpha: 1)
            ])
        }
        let region = ReaderTranslationRegion(id: "color", rect: CGRect(x: 55/390.0, y: 60/260.0, width: 160/390.0, height: 65/260.0),
                                             source: "HELLO", translation: "안녕하세요")
        var settings = freshSettings()
        var revision: UInt64 = 0
        for (step, enabled) in [false, true, false, true].enumerated() {
            settings.overlay.preserveSourceTextColor = enabled
            overlay.update(regions: [region], imageSize: source.size, aspectFit: false, settings: settings, image: source)
            try await wait(overlay, after: revision)
            revision = try #require(overlay.lastDiagnostic?.revision)
            let audit = try await overlay.webView.evaluateJavaScript("""
            (() => { const root = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
              const node = root.querySelector('[data-aidoku-image-ocr-overlay="item"]');
              return {color: getComputedStyle(node).color, state: node.dataset.sourceTextColor,
                      pixels: Number(root.dataset.sourceColorPixels), hits: Number(root.dataset.sourceColorCacheHits)};
            })()
            """) as? [String: Any]
            let value = try #require(audit)
            #expect(value["state"] as? String == (enabled ? "preserved" : "fallback"))
            if enabled { #expect(value["color"] as? String != "rgb(17, 18, 23)") }
            else {
                #expect(value["color"] as? String == "rgb(17, 18, 23)")
                #expect(value["pixels"] as? Int == 0)
            }
            if step == 3 { #expect(value["hits"] as? Int == 1) }
        }
        // A different page with identical bounds must never reuse the red estimate.
        let blank = UIGraphicsImageRenderer(size: source.size, format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(origin: .zero, size: source.size))
        }
        overlay.update(regions: [region], imageSize: blank.size, aspectFit: false, settings: settings, image: blank)
        try await wait(overlay, after: revision)
        #expect(try await overlay.webView.evaluateJavaScript(
            "document.querySelector('[data-aidoku-image-ocr-overlay=\"item\"]').dataset.sourceTextColor"
        ) as? String == "fallback")
    }

    @Test func panelAndTextOptionsAreIndependentAndKeepDarkPanelsReadable() async throws {
        let (host, overlay) = try makeOverlay(size: CGSize(width: 390, height: 260))
        defer { overlay.cancelWork(); host.isHidden = true }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 260), format: format).image { ctx in
            UIColor(red: 24/255, green: 40/255, blue: 64/255, alpha: 1).setFill()
            ctx.fill(CGRect(x: 0, y: 0, width: 390, height: 260))
            ("HELLO" as NSString).draw(at: CGPoint(x: 65, y: 70), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.white
            ])
        }
        let region = ReaderTranslationRegion(id: "panel", rect: CGRect(x: 55/390.0, y: 60/260.0, width: 160/390.0, height: 65/260.0),
                                             source: "HELLO", translation: "안녕하세요")
        var settings = freshSettings()
        var revision: UInt64 = 0
        for (text, panel) in [(false, false), (true, false), (false, true), (true, true), (false, false)] {
            settings.overlay.preserveSourceTextColor = text
            settings.overlay.preserveSourceBackgroundColor = panel
            overlay.update(regions: [region], imageSize: source.size, aspectFit: false, settings: settings, image: source)
            try await wait(overlay, after: revision)
            revision = try #require(overlay.lastDiagnostic?.revision)
            let audit = try #require(try await overlay.webView.evaluateJavaScript("""
            (() => { const n = document.querySelector('[data-aidoku-image-ocr-overlay="item"]');
              const s = getComputedStyle(n); return {color:s.color, background:s.backgroundColor, veil:s.backgroundImage,
                text:n.dataset.sourceTextColor, panel:n.dataset.sourceBackgroundColor}; })()
            """) as? [String: String])
            #expect(audit["panel"] == (panel ? "preserved" : "fallback"))
            #expect(audit["text"] == (text && panel ? "preserved" : "fallback"))
            if panel {
                #expect(audit["background"] == "rgba(24, 40, 64, 0.84)")
                #expect(audit["veil"] == "none")
                #expect(audit["color"] != "rgb(17, 18, 23)")
            } else {
                #expect(audit["background"] == "rgba(255, 254, 249, 0.84)")
                #expect(audit["color"] == "rgb(17, 18, 23)")
            }
        }
    }

    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("source-color-replay.json").path)))
    func realPageReplayExportsBeforeAndAfter() async throws {
        struct Fixture: Decodable { let image: String; let regions: String; let name: String; let target: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf:
            Self.directory.appendingPathComponent("source-color-replay.json")))
        let output = Self.directory.appendingPathComponent("source-color-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for fixture in fixtures {
            let source = try #require(UIImage(contentsOfFile: Self.directory.appendingPathComponent(fixture.image).path))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
                from: Data(contentsOf: Self.directory.appendingPathComponent(fixture.regions))).map(\.region)
            let size = CGSize(width: 430, height: 430 * source.size.height / source.size.width)
            let (host, overlay) = try makeOverlay(size: size)
            defer { overlay.cancelWork(); host.isHidden = true }
            var settings = freshSettings(); settings.targetLanguage = fixture.target
            var revision: UInt64 = 0
            for (mode, text, panel) in [("off", false, false), ("text", true, false), ("panel", false, true), ("both", true, true)] {
                settings.overlay.preserveSourceTextColor = text
                settings.overlay.preserveSourceBackgroundColor = panel
                overlay.update(regions: regions, imageSize: source.size, aspectFit: false, settings: settings, image: source)
                try await wait(overlay, after: revision)
                revision = try #require(overlay.lastDiagnostic?.revision)
                let name = fixture.name + "-" + mode
                let audit = try await overlay.webView.evaluateJavaScript("""
                (() => { const root = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
                  return {stats: {...root.dataset}, dom: Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
                    .map(n => ({id:n.dataset.aidokuRegion, text:n.textContent, color:getComputedStyle(n).color,
                                state:n.dataset.sourceTextColor, background:getComputedStyle(n).backgroundColor,
                                panel:n.dataset.sourceBackgroundColor}))}; })()
                """)
                let report = try #require(audit as? [String: Any])
                let rows = try #require(report["dom"] as? [[String: Any]])
                if text { #expect(rows.contains { $0["state"] as? String == "preserved" }) }
                if panel { #expect(rows.contains { $0["panel"] as? String == "preserved" }) }
                try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent(name + ".json"))
                _ = try await overlay.webView.callAsyncJavaScript(
                    "await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))",
                    arguments: [:], in: nil, contentWorld: .page)
                let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                    overlay.webView.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                try snapshot.pngData()?.write(to: output.appendingPathComponent(name + ".png"))
            }
        }
    }

    private func freshSettings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        return settings
    }

    private func makeOverlay(size: CGSize) throws -> (UIWindow, ReaderTranslationOverlayView) {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene); host.rootViewController = UIViewController()
        host.makeKeyAndVisible()
        let overlay = ReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
        host.rootViewController?.view.addSubview(overlay)
        return (host, overlay)
    }

    private func wait(_ overlay: ReaderTranslationOverlayView, after revision: UInt64) async throws {
        for _ in 0..<600 {
            overlay.layoutIfNeeded()
            if let diagnostic = overlay.lastDiagnostic, diagnostic.revision > revision, diagnostic.outcome == .committed { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Source color render did not commit")
        throw URLError(.timedOut)
    }
}
