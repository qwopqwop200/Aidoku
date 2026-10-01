import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSourceTextColorTests {
    private static let webFixture = RegressionWebFixture()

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
        settings.overlay.appearance = .source
        try settings.autosave(defaults: defaults)
        #expect(ReaderTranslationSettings(defaults: defaults).overlay.appearance == .source)
        #expect(renderKey(settings) != before)
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: settings) == translation)
        settings.overlay.appearance = .white
        try settings.autosave(defaults: defaults)
        #expect(!ReaderTranslationSettings(defaults: defaults).overlay.preserveSourceColors)
        #expect(renderKey(settings) == before)
        settings.overlay.preserveSourceBackgroundColor = true
        try settings.autosave(defaults: defaults)
        let migrated = ReaderTranslationSettings(defaults: defaults)
        #expect(migrated.overlay.appearance == .source)
        #expect(migrated.overlay.preserveSourceTextColor && migrated.overlay.preserveSourceBackgroundColor)
        #expect(ReaderTranslationCacheIdentity.translation(page: "page", settings: migrated) == translation)

    }

    @Test func estimatesSolidInkAndRejectsAmbiguousPixels() async throws {
        let web = Self.webFixture.acquire()
        defer { Self.webFixture.release(web) }
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        try await RegressionWebFixture.load("<!doctype html><html><body></body></html>", in: web)

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
        #expect(values["whiteOnWhite"] as? [Int] == [255, 255, 255])
        #expect(values["pinkAdjusted"] as? [Int] == [219,100,144])
        #expect(values["purplePanelAdjusted"] as? [Int] == [165,127,174])
        for key in ["lowContrast", "paleYellowFallback"] {
            let rgb = try #require(values[key] as? [Int])
            #expect(rgb.count == 3 && rgb.allSatisfy { (0...255).contains($0) })
        }

    }

    @Test func extractsFillAndIndependentSourceStrokeWithoutRecoloring() async throws {
        let web = Self.webFixture.acquire()
        defer { Self.webFixture.release(web) }
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        try await RegressionWebFixture.load("<!doctype html><html><body></body></html>", in: web)

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
                  const cache = Object.keys(globalThis).filter(key => key.startsWith('__aidokuSourceTextColorsV'))
                    .map(key => globalThis[key]?.get(image)).find(Boolean);
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
              const o=luminance(n.dataset.sourceAppliedStrokeRGB||'255,255,255');
              return {contrast:String((Math.max(a,b)+.05)/(Math.min(a,b)+.05)),
                strokeContrast:String((Math.max(o,b)+.05)/(Math.min(o,b)+.05)),
                sampled:n.dataset.sourceSampledStrokeRGB, applied:n.dataset.sourceAppliedStrokeRGB,
                state:n.dataset.sourceStrokeColor, backgroundMode:n.dataset.sourceBackgroundColor, stroke:s.webkitTextStrokeColor,
                width:s.webkitTextStrokeWidth, paintOrder:s.paintOrder,
                sampledFill:n.dataset.sourceSampledTextRGB, appliedFill:n.dataset.sourceAppliedTextRGB,
                adjusted:n.dataset.sourceTextColorAdjusted
              }; })()
            """) as? [String: String])
            try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys])
                .write(to: diagnosticDirectory.appendingPathComponent("uikit-step-\(step)-audit.json"))
            if text {
                let sampled = try #require(audit["sampled"])
                let channels = sampled.split(separator: ",").compactMap { Int($0) }
                #expect(channels.count == 3 && zip(channels, [96, 54, 28]).allSatisfy { abs($0 - $1) <= 16 })
            }
            // With the panel kept, the observed fill + outline pair is the lettering style; without it the
            // fill is adjusted for contrast and the outline dropped. The fixture fixes which path applies.
            if text && panel {
                // Keep both, with the outline painted under the fill, matching the sample and
                // supplying the contrast against the panel.
                #expect(audit["state"] == "preserved")
                #expect((Double(audit["strokeContrast"] ?? "") ?? 0) >= 4.5)
                #expect(audit["applied"] == audit["sampled"])
                #expect(audit["appliedFill"] == audit["sampledFill"])
                #expect(audit["width"] != "0px")
                #expect(audit["paintOrder"]?.hasPrefix("stroke") == true)
            } else {
                if text {
                    #expect(audit["appliedFill"] != audit["sampledFill"])
                    #expect(audit["adjusted"] == "true")
                    #expect((Double(audit["contrast"] ?? "") ?? 0) >= 4.5)
                }
                #expect(audit["state"] == "none")
                #expect(audit["applied"] == "")
                #expect(audit["width"] == "0px")
                #expect(audit["paintOrder"] == "normal")
            }
        }
    }

    @Test func opaqueBoxesReuseColorSamplesAndInvalidateOnSourceReload() async throws {
        let web = Self.webFixture.acquire(frame: CGRect(x: 0, y: 0, width: 390, height: 400))
        defer { Self.webFixture.release(web) }
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        try await RegressionWebFixture.load("<!doctype html><html><body></body></html>", in: web)

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
            "allowsAutomaticFontRecovery": false, "sourceColorEligible": true,
            "sourceCleanupLexical": true, "sourceCleanup": true, "sourceVertical": true,
            "sourceBounds": [10.0 / 120, 10.0 / 120, 100.0 / 120, 100.0 / 120],
            "sourceFrame": [0, 0, 120, 120]
        ]
        func render(_ revision: Int, cleanup: Bool = true) async throws -> [String: Any] {
            var next = item; next["sourceCleanup"] = cleanup
            _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
                arguments: ["revision": String(revision), "session": "cleanup-cache-test", "items": [next],
                    "appearance": ["minimumReadableFontSize": 1, "opacity": 0.84,
                        "preserveSourceTextColor": true, "preserveSourceBackgroundColor": true]],
                in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            let value = try await web.callAsyncJavaScript("""
            const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
            const canvas=root.querySelector('canvas');
            const node=root.querySelector('[data-aidoku-image-ocr-overlay="item"]');
            const cache=globalThis.__aidokuSourceCleanupV1.last;
            return {reads:globalThis.cleanupReads,canvas:canvas?.toDataURL()||'',
              count:Number(root.dataset.cleanupCount),blur:getComputedStyle(node).webkitBackdropFilter,
              pixels:cache.pixels,entries:cache.entries.size,plates:Number(root.dataset.readabilityPanels)};
            """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            return try #require(value as? [String: Any])
        }
        let first = try await render(1)
        #expect(first["count"] as? Int == 0)
        #expect(first["canvas"] as? String == "")
        #expect(first["plates"] as? Int == 1)
        #expect(first["blur"] as? String == "none")
        let second = try await render(2)
        #expect(first["reads"] as? Int == second["reads"] as? Int)
        #expect(second["entries"] as? Int == 0)
        let disabled = try await render(3, cleanup: false)
        #expect(disabled["count"] as? Int == 0)
        #expect(disabled["plates"] as? Int == 1)
        let repeated = try await render(4)
        #expect(repeated["canvas"] as? String == "")
        #expect(repeated["reads"] as? Int == first["reads"] as? Int)
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
        #expect(replaced["entries"] as? Int == 0)
        #expect(replaced["plates"] as? Int == 1)
        let pixels = try #require(replaced["pixels"] as? Int)
        #expect(pixels <= 2_000_000)
        // Exercise the production insertion path with more retained RGBA data
        // than its byte cap, including the extra one-byte safety mask.
        let pressured = BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(
            of: "const cleanupCanvas = document.createElement('canvas');",
            with: """
            for(let i=0;i<80;i++) storeCleanup('pressure-'+i,
              {restored:{rgba:new Uint8ClampedArray(65536*4),layoutSafe:new Uint8Array(65536)}},65536);
            const cleanupCanvas = document.createElement('canvas');
            """)
        _ = try await web.callAsyncJavaScript(pressured,
            arguments: ["revision": "6", "session": "cleanup-cache-test", "items": [item],
                "appearance": ["minimumReadableFontSize": 1, "opacity": 1]], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let bounded = try await web.callAsyncJavaScript("""
        const c=globalThis.__aidokuSourceCleanupV1.last;
        const actual=[...c.entries.values()].reduce((n,e)=>n+(e.restored?.rgba?.byteLength||0)+(e.restored?.layoutSafe?.byteLength||0)+(e.output?.data?.byteLength||0),0);
        return actual===c.bytes&&c.bytes<=16*1024*1024&&c.bytes>15*1024*1024&&!c.entries.has('pressure-0')&&c.entries.has('pressure-79');
        """, arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? Bool
        #expect(bounded == true)
        _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.clearScript,
            arguments: ["revision": "7", "session": "cleanup-cache-test"], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
        let cleared = try await web.callAsyncJavaScript("return !globalThis.__aidokuSourceCleanupV1.last", arguments: [:], in: nil, contentWorld: ReaderTranslationDOM.contentWorld) as? Bool
        #expect(cleared == true)
    }

    @Test func outlineFreeReadabilityKeepsManualFontsAndSourceSampling() async throws {
        // Inject the same independently specified source observations at the
        // native style boundary, without depending on an obsolete JS cache key.
        let fonts: [Double] = [9, 12, 5, 8.99, 12, 12, 12, 12]
        let sampleInputs: [[String: Any]] = [
            ["foreground": [251.0, 251, 251]], ["foreground": [251.0, 251, 251]],
            ["foreground": [251.0, 251, 251]], ["foreground": [251.0, 251, 251]],
            ["foreground": [255.0, 220, 0]],
            ["foreground": [251.0, 251, 251], "stroke": [96.0, 54, 28],
             "widthEvidence": ["relativeToGlyph": 0.05], "confidence": ["stroke": 0.9]],
            ["foreground": [220.0, 220, 220], "background": [255.0, 255, 255]],
            ["background": [25.0, 28, 32], "stroke": [96.0, 54, 28], "confidence": ["stroke": 0.9]]
        ]
        let samples = sampleInputs.map { value in
            var sample: [String: Any] = ["background": [11.0, 11, 11]]
            sample.merge(value) { _, new in new }
            var confidence: [String: Double] = ["background": 1, "stroke": 0]
            confidence.merge(value["confidence"] as? [String: Double] ?? [:]) { _, new in new }
            sample["confidence"] = confidence
            return sample
        }
        let descriptors: [[String: Any]] = fonts.enumerated().map { index, font in
            ["id": String(index), "x": 20, "y": 110 + index * 70,
             "width": 140, "height": 60, "text": "한글", "vertical": false,
             "wrappingScript": "korean", "fontScript": "korean", "fontSize": font,
             "lineHeight": font + 2, "paddingTop": 4, "paddingRight": 4,
             "paddingBottom": 4, "paddingLeft": 4, "lightSurface": true,
             "clipsText": false, "allowsAutomaticFontRecovery": false,
             "sourceColorEligible": true, "sourceBounds": [Double(index) / 10, 0, 0.09, 1],
             "sourceFrame": [0, 0, 100, 100]]
        }
        let items = try JSONDecoder().decode([NativeTranslationLayoutItem].self,
            from: JSONSerialization.data(withJSONObject: descriptors))
        let originalEvidence = try JSONSerialization.data(withJSONObject: samples, options: [.sortedKeys])
        for (text, panel) in [(true, false), (true, true), (false, true), (false, false), (true, false)] {
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.inpaintingEnabled = false
            settings.opacity = 0.84
            settings.preserveSourceTextColor = text
            settings.preserveSourceBackgroundColor = panel
            var restoration = NativeTranslationRestoration.Result()
            var cards: [NativeTranslationRenderer.Card] = []
            for (index, item) in items.enumerated() {
                let sample = samples[index]
                let foreground = text ? NativeSourceColorSampler.rgb(sample["foreground"]).map {
                    NativeTranslationRenderer.color($0.map { CGFloat($0) })
                } : nil
                let surface = panel ? NativeSourceColorSampler.rgb(sample["background"]).map {
                    NativeTranslationRenderer.color($0.map { CGFloat($0) })
                } : nil
                restoration.appearances[item.id] = .init(foreground: foreground, background: surface,
                    restored: false, sourceSample: sample)
                let fallback = surface.map { NativeTranslationRenderer.panelForeground($0, opacity: 0.84) }
                    ?? NativeTranslationRenderer.color([17, 18, 23])
                let style = NativeTranslationTypography.Style(fontScript: item.fontScript, fontSize: item.fontSize,
                    foreground: foreground ?? fallback, lineHeight: item.lineHeight)
                cards.append(.init(item: item,
                    typography: NativeTranslationTypography.layout(text: item.text, in: item.contentRect.size, style: style),
                    style: style, drawsPanel: true, background: surface ?? NativeTranslationRenderer.color([255, 254, 249]),
                    usesFallbackVeil: surface == nil, lightSurface: true, heavyStrokeWidth: 0, finalFontSize: item.fontSize))
            }
            NativeTranslationRenderer.applySourceStyles(to: &cards, restoration: restoration, settings: settings,
                stage: .initialInk, itemCount: items.count)
            NativeTranslationRenderer.applySourceStyles(to: &cards, restoration: restoration, settings: settings,
                stage: .finalContrast, itemCount: items.count)
            #expect(cards.count == fonts.count)
            for (index, card) in cards.enumerated() {
                #expect(abs(Double(card.style.fontSize) - fonts[index]) < 0.001, "Manual font must not be resized")
                #expect(abs(Double(card.style.lineHeight) - (fonts[index] + 2)) < 0.001)
                #expect(card.typography.visibleUTF16Range.length == card.item.text.utf16.count)
                let fill = try #require(NativeTranslationRenderer.rgb(card.style.foreground))
                if text && index != 7 {
                    #expect(fill == NativeSourceColorSampler.rgb(samples[index]["foreground"]),
                            "Native styling must retain the independently sampled text color")
                } else if panel {
                    let background = try #require(NativeTranslationRenderer.rgb(card.background))
                    let a = NativeSourceColorSampler.luminance(fill), b = NativeSourceColorSampler.luminance(background)
                    #expect((max(a, b) + 0.05) / (min(a, b) + 0.05) >= 4.5)
                } else {
                    #expect(fill == [17, 18, 23], "Disabled or absent sampled ink uses the native fallback")
                }
                if text && index == 4 { #expect(fill == [255, 220, 0]) }
                #expect(card.sourceStrokeKind == "none")
                #expect(card.style.outline == nil)
                #expect(card.style.outlineWidth == 0)
                #expect(card.paintOrderLift == nil)
            }
            let retained = items.map { restoration.appearances[$0.id]?.sourceSample ?? [:] }
            let retainedEvidence = try JSONSerialization.data(withJSONObject: retained, options: [.sortedKeys])
            #expect(retainedEvidence == originalEvidence,
                    "Display color decisions must not overwrite original source sampling evidence")
        }
        // Also exercise complete native layout refinement and CoreText rendering:
        // direct style tests alone cannot detect a later pass resizing manual text.
        let viewport = CGSize(width: 390, height: 700)
        let layout = NativeTranslationLayout(imageSize: CGSize(width: 100, height: 100),
            sourceRect: CGRect(x: 0, y: 0, width: 100, height: 100), viewport: viewport, items: items)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.inpaintingEnabled = false
        settings.preserveSourceTextColor = false
        settings.preserveSourceBackgroundColor = false
        let result = try NativeTranslationRenderer.renderSynchronously(layout: layout, image: nil,
            settings: settings, collectDiagnostics: true)
        let diagnosticData = try #require(result.diagnosticData)
        let auditObject = try JSONSerialization.jsonObject(with: diagnosticData)
        let audit = try #require(auditObject as? [String: Any])
        let cards = try #require(audit["cards"] as? [[String: Any]])
        #expect(cards.count == fonts.count)
        for (index, font) in fonts.enumerated() {
            let card = try #require(cards.first { $0["id"] as? String == String(index) })
            let actualFont = try #require(card["fontSize"] as? Double)
            #expect(abs(actualFont - font) < 0.001)
            #expect(card["outlineWidth"] as? Double == 0)
            #expect(card["sourceStrokeKind"] as? String == "none")
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

    @Test(arguments: [false, true])
    func panelAndTextOptionsAreIndependentAndKeepDarkPanelsReadable(inpainting: Bool) async throws {
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
        settings.overlay.inpaintingEnabled = inpainting
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
            #expect(audit["panel"] == (panel ? (text && inpainting ? "inpainted" : "readability-panel") : "fallback"))
            #expect(audit["text"] == (text ? "preserved" : "fallback"))
            if text {
                let sampledRGB = try #require(audit["sampledRGB"])
                let channels = sampledRGB.split(separator: ",").compactMap { Int($0) }
                #expect(channels.count == 3 && channels.allSatisfy { abs($0 - 255) <= 8 })
                #expect(audit["appliedRGB"] == sampledRGB)
            }
            #expect(audit["strokeWidth"] == "0px")
            #expect(audit["paintOrder"] == "normal")
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
        let web = Self.webFixture.acquire(frame: CGRect(x: 0, y: 0, width: 200, height: 400))
        defer { Self.webFixture.release(web) }
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        try await RegressionWebFixture.load("<html><body></body></html>", in: web)

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

    @Test func panelRecoveryRequiresMatchingSurfacesAcrossText() async throws {
        let web = Self.webFixture.acquire()
        defer { Self.webFixture.release(web) }
        web.scrollView.contentInsetAdjustmentBehavior = .automatic
        try await RegressionWebFixture.load("<html><body></body></html>", in: web)

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

    private func makeHost() throws -> UIWindow {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene); host.rootViewController = UIViewController()
        host.makeKeyAndVisible()
        return host
    }

    private func makeOverlay(size: CGSize) throws -> (UIWindow, LegacyReaderTranslationOverlayView) {
        let host = try makeHost()
        let overlay = LegacyReaderTranslationOverlayView(frame: CGRect(origin: .zero, size: size))
        host.rootViewController?.view.addSubview(overlay)
        return (host, overlay)
    }

    private func wait(_ overlay: LegacyReaderTranslationOverlayView, after revision: UInt64) async throws {
        for _ in 0..<600 {
            overlay.layoutIfNeeded()
            if let diagnostic = overlay.lastDiagnostic, diagnostic.revision > revision, diagnostic.outcome == .committed { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        Issue.record("Source color render did not commit")
        throw URLError(.timedOut)
    }
}
