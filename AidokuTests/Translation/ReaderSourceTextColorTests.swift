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
            if (style === 'outlined') { ctx.strokeStyle = '#000000'; ctx.lineWidth = 3; ctx.strokeText('HELLO', 15, 49); }
            ctx.fillText('HELLO', 15, 49);
            if (style === 'mixed') { ctx.fillStyle = '#0000c0'; ctx.fillText('LO', 80, 49); }
          }
          return aidokuEstimateTextColor(ctx.getImageData(0, 0, 180, 80).data, 180, 80);
        };
        const dense = new Uint8ClampedArray(72 * 44 * 4);
        for (let y = 0; y < 44; y++) for (let x = 0; x < 72; x++) {
          const glyph = [5, 27, 49].some(left => x >= left && x < left + 18 && y >= 5 && y < 39 &&
            !(x >= left + 5 && x < left + 13 && y >= 10 && y < 34));
          const i = (y * 72 + x) * 4; dense.set([glyph ? 255 : 16, glyph ? 255 : 16, glyph ? 255 : 16, 255], i);
        }
        return {
          densePanel: aidokuEstimateSourceColors(dense, 72, 44),
          outlined: run('#b020b0', '#ffffff', 'outlined'),
          red: run('#b02030', '#ffffff'), blue: run('#2030b0', '#ffffff'),
          black: run('#101010', '#ffffff'), white: run('#ffffff', '#101010'),
          blank: run('#b02030', '#ffffff', 'blank'), art: run('#b02030', '#ffffff', 'art'),
          mixed: run('#b02030', '#ffffff', 'mixed'),
          redOnWhite: aidokuReadableSourceColor([176,32,48], true, 0.84),
          whiteOnWhite: aidokuReadableSourceColor([255,255,255], true, 0.84),
          whiteOnDark: aidokuReadableSourceColor([255,255,255], false, 0.84),
          lowContrast: aidokuReadableSourceColor([160,160,160], true, 0.2),
          pinkAdjusted: aidokuReadableSourceColor([219,100,144], true, 0.84),
          pinkContrast: aidokuSourceColorContrast(
            aidokuReadableSourceColor([219,100,144], true, 0.84), true, 0.84),
          purplePanelAdjusted: aidokuReadableSourceColor([165,127,174], true, 0.84, [255,254,255]),
          purplePanelContrast: aidokuSourceColorContrast(
            aidokuReadableSourceColor([165,127,174], true, 0.84, [255,254,255]), true, 0.84, [255,254,255]),
          paleYellowFallback: aidokuReadableSourceColor([255,255,224], true, 0.2),
          translucent: aidokuEstimateTextColor(new Uint8Array(16 * 16 * 4), 16, 16)
        };
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let values = try #require(result)
        for (key, expected) in [("red", [176, 32, 48]), ("blue", [32, 48, 176]),
                                ("black", [16, 16, 16]), ("white", [255, 255, 255])] {
            let actual = try #require(values[key] as? [Int], "Missing estimate for \(key)")
            #expect(zip(actual, expected).allSatisfy { abs($0 - $1) <= 8 })
        }
        for key in ["blank", "art", "translucent"] {
            #expect(values[key] is NSNull, "No valid glyph ink for \(key)")
        }
        // Mixed lettering may now choose a supported source candidate. It must
        // not manufacture a third palette color merely to improve contrast.
        if let mixed = values["mixed"] as? [Int] {
            #expect([[176, 32, 48], [0, 0, 192]].contains { expected in
                zip(mixed, expected).allSatisfy { abs($0 - $1) <= 16 }
            })
        } else { #expect(values["mixed"] is NSNull) }
        #expect(values["redOnWhite"] as? [Int] == [176, 32, 48])
        #expect(values["whiteOnDark"] as? [Int] == [255, 255, 255])
        let densePanel = try #require(values["densePanel"] as? [String: Any])
        #expect(densePanel["background"] as? [Int] == [16, 16, 16])
        #expect(densePanel["foreground"] as? [Int] == [255, 255, 255])
        // An outline is not the original fill. Ambiguous two-ink crops may abstain,
        // but must never return the black outline as the magenta lettering color.
        if let outlined = values["outlined"] as? [Int] {
            #expect(zip(outlined, [176, 32, 176]).allSatisfy { abs($0 - $1) <= 12 })
        } else { #expect(values["outlined"] is NSNull) }
        // Source preservation must retain the actual RGB, including low-contrast
        // and inverted ink. The renderer owns a contrast outline, not recoloring.
        for (key, expected) in [
            ("whiteOnWhite", [255, 255, 255]), ("lowContrast", [160, 160, 160]),
            ("pinkAdjusted", [219, 100, 144]), ("purplePanelAdjusted", [165, 127, 174]),
            ("paleYellowFallback", [255, 255, 224])
        ] {
            #expect(values[key] as? [Int] == expected)
        }

    }

    @Test func extractsFillAndIndependentSourceStrokeWithoutRecoloring() async throws {
        let web = WKWebView()
        web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const diagnostics = {};
        const rgbaBase64 = bytes => {
          let binary = '';
          for (let i = 0; i < bytes.length; i += 8192)
            binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
          return btoa(binary);
        };
        const sample = (fill, stroke, background, name) => {
          const canvas = document.createElement('canvas'); canvas.width = 224; canvas.height = 90;
          const ctx = canvas.getContext('2d');
          ctx.fillStyle = background; ctx.fillRect(0, 0, canvas.width, canvas.height);
          ctx.font = 'bold 44px sans-serif'; ctx.lineJoin = 'round';
          if (stroke) { ctx.strokeStyle = stroke; ctx.lineWidth = 5; ctx.strokeText('HELLO', 22, 61); }
          ctx.fillStyle = fill; ctx.fillText('HELLO', 22, 61);
          const rgba = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
          const result = aidokuEstimateSourceColors(rgba, canvas.width, canvas.height);
          diagnostics[name] = {width:canvas.width, height:canvas.height, rgbaBase64:rgbaBase64(rgba),
            pngDataURL:canvas.toDataURL('image/png'), sample:result, fill, stroke, background,
            font:ctx.font, lineWidth:ctx.lineWidth, userAgent:navigator.userAgent};
          return result;
        };
        const result = {
          whiteBrown: sample('#ffffff', '#60361c', '#ffffff', 'whiteBrown'),
          blackWhite: sample('#101010', '#ffffff', '#242c3c', 'blackWhite'),
          pinkGreen: sample('#d05080', '#205030', '#fff8e8', 'pinkGreen'),
          inverted: sample('#ffffff', null, '#101820', 'inverted'),
          noImage: aidokuEstimateSourceColors(null, 32, 32),
          malformed: aidokuEstimateSourceColors(new Uint8ClampedArray(3), 32, 32),
          tooSmall: aidokuEstimateSourceColors(new Uint8ClampedArray(4 * 4 * 4), 4, 4)
        };
        result.diagnostics = diagnostics;
        return result;
        """, arguments: [:], in: nil, contentWorld: .page) as? [String: Any]
        let values = try #require(result)
        // Export before any color expectation can throw, preserving failing iOS pixels.
        let diagnostics = try #require(values["diagnostics"] as? [String: [String: Any]])
        for (name, report) in diagnostics { try writeStrokeFixtureDiagnostic(report, name: "canvas-\(name)") }
        for (key, fill, stroke) in [
            ("whiteBrown", [255, 255, 255], [96, 54, 28]),
            ("blackWhite", [16, 16, 16], [255, 255, 255]),
            ("pinkGreen", [208, 80, 128], [32, 80, 48])
        ] {
            let sample = try #require(values[key] as? [String: Any], "Missing sample for \(key)")
            let actualFill = try #require(sample["foreground"] as? [Int], "Missing fill for \(key)")
            let actualStroke = try #require(sample["stroke"] as? [Int], "Missing stroke for \(key)")
            #expect(actualFill.count == 3 && zip(actualFill, fill).allSatisfy { abs($0 - $1) <= 12 })
            #expect(actualStroke.count == 3 && zip(actualStroke, stroke).allSatisfy { abs($0 - $1) <= 12 })
            #expect(sample["outline"] as? [Int] == actualStroke)
        }
        let inverted = try #require(values["inverted"] as? [String: Any])
        #expect(inverted["foreground"] as? [Int] == [255, 255, 255])
        #expect(inverted["background"] as? [Int] == [16, 24, 32])
        for key in ["noImage", "malformed", "tooSmall"] { #expect(values[key] is NSNull) }
    }

    @Test func appliedStrokeMatchesSampleAndClearsWhenTextPreservationIsDisabled() async throws {
        let (host, overlay) = try makeOverlay(size: CGSize(width: 390, height: 260))
        defer { overlay.cancelWork(); host.isHidden = true }
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let source = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 260), format: format).image { ctx in
            UIColor.white.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 390, height: 260))
            ("HELLO" as NSString).draw(at: CGPoint(x: 65, y: 70), withAttributes: [
                .font: UIFont.boldSystemFont(ofSize: 38), .foregroundColor: UIColor.white,
                .strokeColor: UIColor(red: 96/255, green: 54/255, blue: 28/255, alpha: 1), .strokeWidth: -10
            ])
        }
        let region = ReaderTranslationRegion(id: "outlined-color",
            rect: CGRect(x: 55/390.0, y: 60/260.0, width: 170/390.0, height: 65/260.0),
            source: "HELLO", translation: "안녕하세요")
        let diagnosticDirectory = try strokeFixtureDiagnosticDirectory()
        try #require(source.pngData()).write(to: diagnosticDirectory.appendingPathComponent("uikit-source.png"))
        var settings = freshSettings()
        var revision: UInt64 = 0
        for (step, options) in [(true, false), (true, true), (false, true), (false, false), (true, false)].enumerated() {
            let (text, panel) = options
            settings.overlay.preserveSourceTextColor = text
            settings.overlay.preserveSourceBackgroundColor = panel
            overlay.update(regions: [region], imageSize: source.size, aspectFit: false, settings: settings, image: source)
            try await wait(overlay, after: revision)
            revision = try #require(overlay.lastDiagnostic?.revision)
            if step == 0 {
                let pixelReport = try #require(try await overlay.webView.callAsyncJavaScript("""
                return (() => {
                  const image = document.getElementById('reader-source-image');
                  const canvas = document.createElement('canvas');
                  canvas.width = image.naturalWidth; canvas.height = image.naturalHeight;
                  const ctx = canvas.getContext('2d'); ctx.drawImage(image, 0, 0);
                  const bytes = ctx.getImageData(0, 0, canvas.width, canvas.height).data;
                  let binary = '';
                  for (let i = 0; i < bytes.length; i += 8192)
                    binary += String.fromCharCode(...bytes.subarray(i, i + 8192));
                  const cache = globalThis.__aidokuSourceTextColorsV12?.get(image);
                  const samples = cache ? Array.from(cache, ([key, sample]) =>
                    ({sourceBounds:key.split(',').map(Number), sample, provenance:'actual renderer sampler cache'})) : [];
                  return {width:canvas.width, height:canvas.height, rgbaBase64:btoa(binary),
                    pngDataURL:canvas.toDataURL('image/png'), samples, userAgent:navigator.userAgent};
                })()
                """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? [String: Any])
                try writeStrokeFixtureDiagnostic(pixelReport, name: "uikit-reader-decoded")
            }
            let audit = try #require(try await overlay.webView.evaluateJavaScript("""
            (() => { const n = document.querySelector('[data-aidoku-image-ocr-overlay="item"]');
              const s = getComputedStyle(n);
              const luminance=rgb=>rgb.split(',').map(Number).reduce((sum,v,i)=>{
                const c=v/255;return sum+(c<=.04045?c/12.92:Math.pow((c+.055)/1.055,2.4))*[.2126,.7152,.0722][i];},0);
              const a=luminance(n.dataset.sourceAppliedTextRGB||'0,0,0');
              const b=luminance(n.dataset.sourceAppliedBackgroundRGB||n.dataset.sourceSampledBackgroundRGB||'255,255,255');
              return {contrast:String((Math.max(a,b)+.05)/(Math.min(a,b)+.05)),
                sampled:n.dataset.sourceSampledStrokeRGB, applied:n.dataset.sourceAppliedStrokeRGB,
                state:n.dataset.sourceStrokeColor, backgroundMode:n.dataset.sourceBackgroundColor, stroke:s.webkitTextStrokeColor,
                width:s.webkitTextStrokeWidth, paintOrder:s.paintOrder,
                sampledFill:n.dataset.sourceSampledTextRGB, appliedFill:n.dataset.sourceAppliedTextRGB
              }; })()
            """) as? [String: String])
            try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
                .write(to: diagnosticDirectory.appendingPathComponent("uikit-step-\(step)-audit.json"))
            if text {
                let sampled = try #require(audit["sampled"])
                let channels = sampled.split(separator: ",").compactMap { Int($0) }
                #expect(channels.count == 3 && zip(channels, [96, 54, 28]).allSatisfy { abs($0 - $1) <= 16 })
                if panel {
                    #expect((Double(audit["contrast"] ?? "") ?? 0) >= 4.5)
                } else {
                    #expect(audit["appliedFill"] == audit["sampledFill"])
                }
                let width = try #require(Double((audit["width"] ?? "").replacingOccurrences(of: "px", with: "")))
                if panel {
                    #expect(audit["state"] == "none")
                    #expect(audit["applied"] == "")
                    #expect(width == 0)
                } else {
                    #expect(audit["state"] == "preserved")
                    #expect(audit["applied"] == sampled)
                    #expect(audit["stroke"] == "rgb(\(channels.map(String.init).joined(separator: ", ")))")
                    #expect(width > 0)
                    #expect(audit["paintOrder"]?.hasPrefix("stroke") == true)
                }
            } else {
                #expect(audit["state"] != "preserved")
                #expect(audit["applied"] == nil || audit["applied"] == "")
                #expect(audit["width"] == "0px")
            }
        }
    }

    @Test func cleanupCachePreservesPixelsAndInvalidatesOnSourceReload() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.callAsyncJavaScript("""
        const source=document.createElement('canvas');source.width=120;source.height=120;
        const c=source.getContext('2d');c.fillStyle='white';c.fillRect(0,0,120,120);
        for(let y=17;y<100;y+=30)for(let x=17;x<100;x+=30){
          c.fillStyle='black';c.fillRect(x,y,22,26);
          c.fillStyle='white';c.fillRect(x+6,y+5,16,16);
        }
        const image=new Image();image.id='reader-source-image';image.src=source.toDataURL();
        await image.decode();document.body.appendChild(image);
        globalThis.cleanupReads=0;
        const original=CanvasRenderingContext2D.prototype.getImageData;
        CanvasRenderingContext2D.prototype.getImageData=function(...args){
          globalThis.cleanupReads++;return original.apply(this,args);
        };
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let item: [String: Any] = [
            "id": "dense", "x": 10, "y": 10, "width": 90, "height": 90,
            "text": "한글", "vertical": false, "wrappingScript": "korean", "fontScript": "korean",
            "fontSize": 18, "lineHeight": 22, "paddingTop": 4, "paddingRight": 4,
            "paddingBottom": 4, "paddingLeft": 4, "lightSurface": true, "clipsText": false,
            "allowsAutomaticFontRecovery": false, "sourceColorEligible": false,
            "sourceCleanupLexical": true, "sourceCleanup": true, "sourceVertical": true,
            "sourceBounds": [10.0 / 120, 10.0 / 120, 100.0 / 120, 100.0 / 120],
            "sourceFrame": [0, 0, 120, 120]
        ]
        func render(_ revision: Int, cleanup: Bool = true) async throws -> [String: Any] {
            var next = item; next["sourceCleanup"] = cleanup
            _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
                arguments: ["revision": String(revision), "session": "cleanup-cache-test", "items": [next],
                    "appearance": ["minimumReadableFontSize": 1, "opacity": 0.84,
                        "preserveSourceTextColor": false, "preserveSourceBackgroundColor": false]],
                in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            let value = try await web.callAsyncJavaScript("""
            const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
            const canvas=root.querySelector('canvas');
            const node=root.querySelector('[data-aidoku-image-ocr-overlay="item"]');
            const cache=globalThis.__aidokuSourceCleanupV1.last;
            return {reads:globalThis.cleanupReads,canvas:canvas?.toDataURL()||'',
              count:Number(root.dataset.cleanupCount),blur:getComputedStyle(node).webkitBackdropFilter,
              pixels:cache.pixels,entries:cache.entries.size};
            """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            return try #require(value as? [String: Any])
        }
        let first = try await render(1)
        #expect(first["count"] as? Int == 1)
        #expect(first["blur"] as? String == "none")
        _ = try await web.callAsyncJavaScript("globalThis.retiredCanvas=document.querySelector('[data-aidoku-image-ocr-overlay=\"root\"] canvas')", arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let second = try await render(2)
        let released = try await web.callAsyncJavaScript("return retiredCanvas.width===0&&retiredCanvas.height===0", arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? Bool
        #expect(released == true)
        _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.clearScript,
            arguments: ["revision": "1", "session": "cleanup-cache-test"], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let stalePreserved = try await web.callAsyncJavaScript("return document.querySelector('[data-aidoku-image-ocr-overlay=\"root\"] canvas').width>0&&globalThis.__aidokuSourceCleanupV1.last.entries.size>0", arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? Bool
        #expect(stalePreserved == true)
        #expect(first["canvas"] as? String == second["canvas"] as? String)
        #expect(first["reads"] as? Int == second["reads"] as? Int)
        #expect(second["entries"] as? Int == 1)
        let disabled = try await render(3, cleanup: false)
        #expect(disabled["count"] as? Int == 0)
        let restored = try await render(4)
        #expect(restored["canvas"] as? String == first["canvas"] as? String)
        #expect(restored["reads"] as? Int == first["reads"] as? Int)
        _ = try await web.callAsyncJavaScript("""
        const canvas=document.createElement('canvas');canvas.width=120;canvas.height=120;
        const c=canvas.getContext('2d');c.fillStyle='white';c.fillRect(0,0,120,120);
        const image=document.getElementById('reader-source-image');
        await new Promise((resolve,reject)=>{image.onload=resolve;image.onerror=reject;image.src=canvas.toDataURL();});
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let replaced = try await render(5)
        #expect(replaced["count"] as? Int == 0)
        let readsBefore = try #require(first["reads"] as? Int)
        let readsAfter = try #require(replaced["reads"] as? Int)
        #expect(readsAfter > readsBefore)
        #expect(replaced["entries"] as? Int == 1)
        let pixels = try #require(replaced["pixels"] as? Int)
        #expect(pixels <= 2_000_000)
        // Exercise the production insertion path with more retained RGBA data
        // than its byte cap, including the extra one-byte safety mask.
        let pressured = BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(
            of: "const cleanupCanvas = document.createElement('canvas');",
            with: """
            for(let i=0;i<24;i++) storeCleanup('pressure-'+i,
              {restored:{rgba:new Uint8ClampedArray(65536*4),layoutSafe:new Uint8Array(65536)}},65536);
            const cleanupCanvas = document.createElement('canvas');
            """)
        _ = try await web.callAsyncJavaScript(pressured,
            arguments: ["revision": "6", "session": "cleanup-cache-test", "items": [item],
                "appearance": ["minimumReadableFontSize": 1, "opacity": 1]], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let bounded = try await web.callAsyncJavaScript("""
        const c=globalThis.__aidokuSourceCleanupV1.last;
        const actual=[...c.entries.values()].reduce((n,e)=>n+(e.restored?.rgba?.byteLength||0)+(e.restored?.layoutSafe?.byteLength||0)+(e.output?.data?.byteLength||0),0);
        return actual===c.bytes&&c.bytes<=4*1024*1024&&c.bytes>3*1024*1024&&!c.entries.has('pressure-0')&&c.entries.has('pressure-23');
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? Bool
        #expect(bounded == true)
        _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.clearScript,
            arguments: ["revision": "7", "session": "cleanup-cache-test"], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let cleared = try await web.callAsyncJavaScript("return !globalThis.__aidokuSourceCleanupV1.last", arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? Bool
        #expect(cleared == true)
    }

    @Test func neutralReadabilityEdgeUsesActualRendererWithoutChangingManualFonts() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        web.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        // Seed the existing sampler cache, isolating renderer behavior from OCR/
        // font-raster-dependent extraction already covered by the tests above.
        // This runs the real renderScript and real WK computed styles, not a
        // second implementation of its eligibility expression.
        _ = try await web.callAsyncJavaScript("""
        const canvas = document.createElement('canvas'); canvas.width = 100; canvas.height = 100;
        const image = new Image(); image.id = 'reader-source-image';
        image.src = canvas.toDataURL(); await image.decode(); document.body.appendChild(image);
        const cache = new Map();
        const samples = [
          {foreground:[251,251,251]}, {foreground:[251,251,251]},
          {foreground:[251,251,251]}, {foreground:[251,251,251]},
          {foreground:[255,220,0]}, {foreground:[251,251,251],stroke:[96,54,28],
            widthEvidence:{relativeToGlyph:0.05},confidence:{stroke:0.9}}
        ];
        samples.forEach((sample,index) => cache.set([index / 10,0,0.09,1].join(','),
          {background:[11,11,11],stroke:null,...sample,confidence:{background:1,stroke:0,...sample.confidence}}));
        globalThis.__aidokuSourceTextColorsV12 = new WeakMap([[image,cache]]);
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let fonts: [Double] = [9, 12, 5, 8.99, 12, 12]
        let items: [[String: Any]] = fonts.enumerated().map { index, font in
            ["id": String(index), "x": 20, "y": 110 + index * 70,
             "width": 140, "height": 60, "text": "한글", "vertical": false,
             "wrappingScript": "korean", "fontScript": "korean", "fontSize": font,
             "lineHeight": font + 2, "paddingTop": 4, "paddingRight": 4,
             "paddingBottom": 4, "paddingLeft": 4, "lightSurface": true,
             "clipsText": false, "allowsAutomaticFontRecovery": false,
             "sourceColorEligible": true, "sourceBounds": [Double(index) / 10, 0, 0.09, 1]]
        }
        for (step, flags) in [(true, false), (true, true), (false, true), (false, false), (true, false)].enumerated() {
            let (text, panel) = flags
            _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
                arguments: ["revision": String(step + 1), "session": "neutral-edge-test", "items": items,
                    "appearance": ["minimumReadableFontSize": 1, "opacity": 0.84,
                        "preserveSourceTextColor": text, "preserveSourceBackgroundColor": panel]],
                in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            let rows = try #require(try await web.callAsyncJavaScript("""
            return Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'), n => {
              const s = getComputedStyle(n);
              return {id:n.dataset.aidokuRegion,state:n.dataset.sourceStrokeColor,
                fill:n.dataset.sourceAppliedTextRGB,sampledFill:n.dataset.sourceSampledTextRGB,
                sampledStroke:n.dataset.sourceSampledStrokeRGB,appliedStroke:n.dataset.sourceAppliedStrokeRGB,
                width:parseFloat(s.webkitTextStrokeWidth),font:parseFloat(s.fontSize),
                paintOrder:s.paintOrder,origin:n.dataset.sourceReadabilityAssistOrigin || ''};
            });
            """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? [[String: Any]])
            #expect(rows.count == fonts.count)
            for row in rows {
                let identifier = try #require(row["id"] as? String)
                let index = try #require(Int(identifier))
                let font = try #require(row["font"] as? Double)
                #expect(abs(font - fonts[index]) < 0.001, "Manual font must not be resized")
                let width = try #require(row["width"] as? Double)
                let state = row["state"] as? String
                if text { #expect(row["fill"] as? String == row["sampledFill"] as? String) }
                if text && !panel && index < 2 {
                    #expect(state == "readability-assist")
                    #expect(row["origin"] as? String == "existing-contrast-edge-width")
                    #expect(row["sampledStroke"] as? String == "")
                    #expect(row["appliedStroke"] as? String == "17,18,23")
                    #expect(abs(width - (index == 0 ? 1.26 : 1.5)) < 0.001)
                    #expect((row["paintOrder"] as? String)?.hasPrefix("stroke") == true)
                } else {
                    #expect(state != "readability-assist")
                    if panel {
                        #expect(state == "none")
                        #expect(row["appliedStroke"] as? String == "")
                        #expect(width == 0)
                    } else if text && index == 5 {
                        #expect(state == "preserved")
                        #expect(row["appliedStroke"] as? String == "96,54,28")
                        #expect(abs(width - 1.2) < 0.001)
                    } else if !text { #expect(width == 0) }
                    else if !panel { #expect(width <= 1) }
                }
            }
        }
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
                strokeWidth:s.webkitTextStrokeWidth, paintOrder:s.paintOrder,
                sampledRGB:n.dataset.sourceSampledTextRGB, appliedRGB:n.dataset.sourceAppliedTextRGB,
                text:n.dataset.sourceTextColor, panel:n.dataset.sourceBackgroundColor}; })()
            """) as? [String: String])
            #expect(audit["panel"] == (panel ? "restored" : "fallback"))
            #expect(audit["text"] == (text ? "preserved" : "fallback"))
            if text {
                let sampledRGB = try #require(audit["sampledRGB"])
                #expect(audit["appliedRGB"] == sampledRGB)
                let channels = sampledRGB.split(separator: ",").compactMap { Int($0) }
                #expect(channels.count == 3 && channels.allSatisfy { abs($0 - 255) <= 8 })
                #expect(audit["color"] == "rgb(\(channels.map(String.init).joined(separator: ", ")))")
            }
            let strokeWidth = try #require(Double((audit["strokeWidth"] ?? "").replacingOccurrences(of: "px", with: "")))
            if text && !panel {
                // Exact white ink on the unchanged light surface needs a
                // continuous edge painted behind the original-color fill.
                #expect(strokeWidth > 0)
                #expect(audit["paintOrder"]?.hasPrefix("stroke") == true)
            } else {
                // Dark preserved panels need no edge; disabling preservation
                // again must also clear the previous text-only stroke.
                #expect(strokeWidth == 0)
            }
            if panel {
                #expect(audit["background"] == "rgba(0, 0, 0, 0)")
                #expect(audit["veil"] == "none")
                #expect(audit["color"] != "rgb(17, 18, 23)")
            } else {
                #expect(audit["background"] == "rgba(255, 254, 249, 0.84)")
                if !text { #expect(audit["color"] == "rgb(17, 18, 23)") }
            }
        }
    }

    @Test func tightOutlinedColumnsKeepTheObservedGrayPanel() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        web.loadHTMLString("<html><body></body></html>", baseURL: nil)
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let result = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const values = [];
        for (const gray of [128, 195]) {
          const canvas = document.createElement('canvas'); canvas.width = 120; canvas.height = 360;
          const ctx = canvas.getContext('2d');
          ctx.fillStyle = `rgb(${gray},${gray},${gray})`; ctx.fillRect(0,0,120,360);
          ctx.font = 'bold 30px sans-serif'; ctx.textAlign = 'center'; ctx.lineJoin = 'round';
          ctx.strokeStyle = '#fff'; ctx.lineWidth = 5; ctx.fillStyle = '#08080a';
          Array.from('いらないってばっ').forEach((letter,i) => {
            ctx.strokeText(letter,60,45+i*36); ctx.fillText(letter,60,45+i*36);
          });
          const image = new Image(); image.src = canvas.toDataURL(); await image.decode();
          values.push(aidokuSourceColorSampler(image,true).sample([49/120,18/360,22/120,284/360]));
        }
        return values;
        """, arguments: [:], in: nil, contentWorld: .page)
        let samples = try #require(result as? [[String: Any]])
        #expect(samples.count == 2)
        for (sample, gray) in zip(samples, [128, 195]) {
            let background = try #require(sample["background"] as? [Int])
            #expect(background.allSatisfy { abs($0 - gray) <= 4 })
        }
    }

    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }

    @Test func panelRecoveryRequiresMatchingSurfacesAcrossText() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html><body></body></html>", baseURL: nil)
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let result = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const sample = (left,right,background=null,foreground=[12,12,12]) => {
          const rgba = new Uint8ClampedArray(60*100*4);
          for(let y=0;y<100;y++)for(let x=0;x<60;x++) {
            const v=x<20?left:x>=40?right:255, p=(y*60+x)*4;
            rgba.set([v,v,v,255],p);
          }
          return aidokuRecoverSourcePanel(rgba,60,100,[20,10,20,80],
            {foreground,background,stroke:[255,255,255],confidence:{}});
        };
        return {shared:sample(128,128),halo:sample(200,200,[255,252,255]),
          artwork:sample(40,200),colored:sample(200,200,[24,40,64]),
          noInk:sample(195,195,null,null),noInkHalo:sample(195,195,[255,255,255],null),
          noInkArtwork:sample(40,200,null,null)};
        """, arguments: [:], in: nil, contentWorld: .page)
        let rows = try #require(result as? [String: [String: Any]])
        #expect(rows["shared"]?["background"] as? [Int] == [128, 128, 128])
        #expect(rows["shared"]?["foreground"] as? [Int] == [12, 12, 12])
        #expect(rows["shared"]?["stroke"] as? [Int] == [255, 255, 255])
        #expect(rows["halo"]?["background"] as? [Int] == [200, 200, 200])
        #expect(rows["colored"]?["background"] as? [Int] == [24, 40, 64])
        #expect(rows["artwork"]?["background"] is NSNull)
        #expect(rows["noInk"]?["background"] as? [Int] == [195, 195, 195])
        #expect(rows["noInkHalo"]?["background"] as? [Int] == [195, 195, 195])
        #expect(rows["noInk"]?["foreground"] is NSNull)
        #expect(rows["noInkArtwork"]?["background"] is NSNull)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("white-panel-page2.png").path)))
    func capturedTranslucentPanelsDoNotBecomeWhite() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html><body></body></html>", baseURL: nil)
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        for (name, box, expected) in [
            ("page2", [1000, 365, 70, 350], [130, 131, 136]),
            ("page15", [1070, 320, 28, 127], [207, 202, 206]),
            ("page15", [157, 988, 85, 272], [224, 222, 226])
        ] {
            let source = try Data(contentsOf: Self.directory.appendingPathComponent("white-panel-\(name).png"))
            let result = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
            const image = new Image(); image.src = 'data:image/png;base64,' + encoded; await image.decode();
            return aidokuSourceColorSampler(image,true).sample(
              [box[0]/image.naturalWidth,box[1]/image.naturalHeight,box[2]/image.naturalWidth,box[3]/image.naturalHeight]);
            """, arguments: ["encoded": source.base64EncodedString(), "box": box], in: nil, contentWorld: .page)
            let row = try #require(result as? [String: Any])
            let background = try #require(row["background"] as? [Int])
            #expect(zip(background,expected).allSatisfy { abs($0-$1) <= 8 })
            let foreground = try #require(row["foreground"] as? [Int])
            #expect(foreground.allSatisfy { $0 < 50 })
        }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("user-source-color.png").path)))
    func capturedOutlinedGrayBalloonKeepsItsBackground() async throws {
        let source = try Data(contentsOf: Self.directory.appendingPathComponent("user-source-color.png"))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 932))
        web.loadHTMLString("<html><body></body></html>", baseURL: nil)
        for _ in 0..<100 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let result = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const image = new Image(); image.src = 'data:image/png;base64,' + encoded; await image.decode();
        const sampler = aidokuSourceColorSampler(image,true);
        return [[1067,26],[1072,23],[1075,20],[1077,16]].map(([x,w]) =>
          sampler.sample([x/image.naturalWidth,677/image.naturalHeight,w/image.naturalWidth,271/image.naturalHeight]));
        """, arguments: ["encoded": source.base64EncodedString()], in: nil, contentWorld: .page)
        let samples = try #require(result as? [[String: Any]])
        #expect(samples.count == 4)
        for sample in samples {
            let background = try #require(sample["background"] as? [Int])
            #expect(zip(background, [195, 195, 199]).allSatisfy { abs($0 - $1) <= 4 })
        }
        try JSONSerialization.data(withJSONObject: samples, options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.directory.appendingPathComponent("user-source-color-samples.json"))
    }

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
            var baselineLayout: [[String: Any]]?
            for (mode, text, panel) in [("off", false, false), ("text", true, false), ("panel", false, true), ("both", true, true)] {
                settings.overlay.preserveSourceTextColor = text
                settings.overlay.preserveSourceBackgroundColor = panel
                let renderStarted = Date()
                overlay.update(regions: regions, imageSize: source.size, aspectFit: false, settings: settings, image: source)
                try await wait(overlay, after: revision)
                revision = try #require(overlay.lastDiagnostic?.revision)
                let renderMilliseconds = Date().timeIntervalSince(renderStarted) * 1_000
                let name = fixture.name + "-" + mode
                let audit = try await overlay.webView.evaluateJavaScript("""
                (() => { const root = document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
                  return {stats: {...root.dataset}, dom: Array.from(root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]'))
                    .map(n => ({id:n.dataset.aidokuRegion, text:n.textContent, color:getComputedStyle(n).color,
                                state:n.dataset.sourceTextColor, adjusted:n.dataset.sourceTextColorAdjusted,
                                background:getComputedStyle(n).backgroundColor,
                                panel:n.dataset.sourceBackgroundColor, fontSize:getComputedStyle(n).fontSize,
                                x:n.offsetLeft, y:n.offsetTop, width:n.offsetWidth, height:n.offsetHeight,
                                scrollWidth:n.scrollWidth, scrollHeight:n.scrollHeight}))}; })()
                """)
                var report = try #require(audit as? [String: Any])
                report["renderMilliseconds"] = renderMilliseconds
                report["mode"] = mode
                let rows = try #require(report["dom"] as? [[String: Any]])
                // Ambiguous art/gradients may legitimately abstain. A larger
                // number of preserved estimates is not a quality assertion.
                let layoutKeys = ["id", "text", "fontSize", "x", "y", "width", "height"]
                let layout = rows.map { row in row.filter { layoutKeys.contains($0.key) } }
                if let baselineLayout {
                    #expect(NSArray(array: layout).isEqual(to: baselineLayout),
                            "Color options changed text or layout for \(fixture.name)")
                } else { baselineLayout = layout }
                #expect(!rows.isEmpty || regions.isEmpty)
                if !text { #expect(rows.allSatisfy { $0["state"] as? String == "fallback" }) }
                if !panel { #expect(rows.allSatisfy { $0["panel"] as? String == "fallback" }) }
                let stats = try #require(report["stats"] as? [String: String])
                if !text && !panel { #expect(stats["sourceColorPixels"] == "0") }
                #expect(renderMilliseconds.isFinite && renderMilliseconds >= 0)
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
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

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("panel-surface-replay.json").path)))
    func panelSurfaceReplayComparesSameSettingsAndLayout() async throws {
        struct Fixture: Decodable { let image: String; let regions: String; let name: String; let target: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf:
            Self.directory.appendingPathComponent("panel-surface-replay.json")))
        let baseline = try String(contentsOf: Self.directory.appendingPathComponent("baseline-source-colors.js"), encoding: .utf8)
        let output = Self.directory.appendingPathComponent("panel-surface-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for fixture in fixtures {
            let imageData = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.image))
            let image = try #require(UIImage(data: imageData))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
                from: Data(contentsOf: Self.directory.appendingPathComponent(fixture.regions))).map(\.region)
            let size = CGSize(width: 430, height: 430 * image.size.height / image.size.width)
            let (host, overlay) = try makeOverlay(size: size)
            defer { overlay.cancelWork(); host.isHidden = true }
            overlay.cancelWork()
            overlay.removeFromSuperview()
            let web = WKWebView(frame: CGRect(origin: .zero, size: size))
            web.scrollView.contentInsetAdjustmentBehavior = .never
            host.rootViewController?.view.addSubview(web)
            web.loadHTMLString("""
            <meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0}img{display:block;width:100%}</style>
            <img id="reader-source-image" src="data:image/png;base64,\(imageData.base64EncodedString())">
            """, baseURL: nil)
            for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()",
                arguments: [:], in: nil, contentWorld: .page)
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.opacity = 1
            settings.preserveSourceTextColor = true
            settings.preserveSourceBackgroundColor = true
            var beforeLayout: [[String: Any]]?
            for mode in ["before", "after"] {
                let renderer = BrowserPageImageOverlayRenderer { web, script, arguments in
                    let script = mode == "before" ? script.replacingOccurrences(of: BrowserSourceTextColor.script, with: baseline) : script
                    return try await BrowserPageImageOverlayRenderer.evaluateJavaScript(web, script, arguments)
                }
                renderer.render(on: web, items: ReaderTranslationRegion.overlayItems(regions, imageSize: image.size),
                    imageSize: image.size, sourceRect: CGRect(origin: .zero, size: size), settings: settings, targetLanguage: fixture.target)
                for _ in 0..<600 where renderer.lastDiagnostic == nil { try await Task.sleep(for: .milliseconds(20)) }
                #expect(renderer.lastDiagnostic?.outcome == .committed)
                let audit = try await web.evaluateJavaScript("""
                (()=>({root:{...document.querySelector('[data-aidoku-image-ocr-overlay="root"]').dataset},
                  items:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>({
                    ...n.dataset,text:n.textContent,background:getComputedStyle(n).backgroundColor,
                    x:n.offsetLeft,y:n.offsetTop,width:n.offsetWidth,height:n.offsetHeight}))}))()
                """)
                let report = try #require(audit as? [String: Any])
                let rows = try #require(report["items"] as? [[String: Any]])
                let keys = ["aidokuRegion", "text", "x", "y", "width", "height"]
                let layout = rows.map { row in row.filter { keys.contains($0.key) } }
                if let beforeLayout {
                    #expect(NSArray(array: layout).isEqual(to: beforeLayout), "Panel recovery changed layout for \(fixture.name)")
                } else { beforeLayout = layout }
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
                    .write(to: output.appendingPathComponent("\(fixture.name)-\(mode).json"))
                _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))",
                    arguments: [:], in: nil, contentWorld: .page)
                let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: nil) { image,error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                try snapshot.pngData()?.write(to: output.appendingPathComponent("\(fixture.name)-\(mode).png"))
                renderer.cancelPendingRender()
            }
        }
    }

    private func freshSettings() -> ReaderTranslationSettings {
        var settings = ReaderTranslationSettings()
        settings.overlay = ReaderTranslationSettings.defaultOverlay
        return settings
    }

    private func strokeFixtureDiagnosticDirectory() throws -> URL {
        let url = URL.documentsDirectory.appendingPathComponent("MangaQuality/stroke-fixture-diagnostics", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeStrokeFixtureDiagnostic(_ report: [String: Any], name: String) throws {
        let directory = try strokeFixtureDiagnosticDirectory()
        var metadata = report
        if let encoded = metadata.removeValue(forKey: "rgbaBase64") as? String {
            let rgba = try #require(Data(base64Encoded: encoded))
            try rgba.write(to: directory.appendingPathComponent(name + ".rgba"))
            metadata["rgbaFormat"] = "RGBA8, top-left origin, row-major, no row padding, Canvas getImageData"
            metadata["rgbaBytes"] = rgba.count
        }
        if let dataURL = metadata.removeValue(forKey: "pngDataURL") as? String {
            let encoded = try #require(dataURL.split(separator: ",", maxSplits: 1).last)
            try #require(Data(base64Encoded: String(encoded))).write(to: directory.appendingPathComponent(name + ".png"))
        }
        try JSONSerialization.data(withJSONObject: metadata, options: [.prettyPrinted, .sortedKeys])
            .write(to: directory.appendingPathComponent(name + ".json"))
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
