import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderOCRPreviewColorTests {
    @Test(arguments: ["missing", "transparent", "read-error", "low-confidence"])
    func unresolvedPanelUsesReadableCaptionWithoutBlurringArtwork(failure: String) async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        web.loadHTMLString("<html><body style='margin:0;background:#584060'></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.callAsyncJavaScript("""
        if (failure !== 'missing') {
          const canvas=document.createElement('canvas');canvas.width=240;canvas.height=120;
          if(failure==='read-error'||failure==='low-confidence') {
            const ctx=canvas.getContext('2d');ctx.fillStyle='#584060';ctx.fillRect(0,0,240,120);
          }
          const image=new Image();image.id='reader-source-image';image.src=canvas.toDataURL();
          await image.decode();document.body.appendChild(image);
          if(failure==='read-error') CanvasRenderingContext2D.prototype.getImageData=()=>{throw new Error('unavailable');};
        }
        """, arguments: ["failure": failure], in: nil, contentWorld: .page)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceTextColor = true
        settings.preserveSourceBackgroundColor = true
        settings.colorMode = .white
        settings.opacity = 1
        for (revision, translated) in [false, true].enumerated() {
            let item = BrowserOverlayItem(rect: CGRect(x: 15, y: 15, width: 210, height: 90),
                sourceText: "HELLO", translatedText: translated ? "안녕" : nil,
                confidence: 1, sourceOrientation: .horizontal)
            let payload = try #require(BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
                imageSize: CGSize(width: 240, height: 120), sourceRect: CGRect(x: 0, y: 0, width: 240, height: 120),
                settings: settings, targetLanguage: "ko", viewport: CGSize(width: 240, height: 120)).first)
            #expect(payload["sourceColorEligible"] as? Bool == true)
            if failure == "low-confidence" {
                _ = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
                const image=document.getElementById('reader-source-image');
                const cache=new Map([[bounds.join(','), {background:[255,255,255],confidence:{background:0.1}}]]);
                aidokuSourceColorSampler(image, true, 'ocr');
                aidokuSourceColorSampler(image, true, 'translation');
                for (const prefix of ['__aidokuSourceTextColorsV', '__aidokuTranslatedSourceTextColorsV']) {
                  const cacheName=Object.keys(globalThis).find(key=>key.startsWith(prefix));
                  if (!cacheName) throw new Error('Production source-color cache was not initialized');
                  globalThis[cacheName].set(image,cache);
                }
                """, arguments: ["bounds": try #require(payload["sourceBounds"])], in: nil, contentWorld: .page)
            }
            _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
                arguments: ["revision": String(revision + 1), "session": "unresolved-panel", "items": [payload],
                    "appearance": ["minimumReadableFontSize": 1, "opacity": 1,
                        "preserveSourceTextColor": true, "preserveSourceBackgroundColor": true]],
                in: nil, contentWorld: .page)
            let audit = try #require(try await web.evaluateJavaScript("""
            (()=>{const node=document.querySelector('[data-aidoku-image-ocr-overlay="item"]');
            const style=getComputedStyle(node),parent=node.parentElement,parentStyle=getComputedStyle(parent);
            const range=document.createRange();range.selectNodeContents(node);
            const ink=range.getBoundingClientRect(),box=parent.getBoundingClientRect();
            return {ownsText:parent.getAttribute('data-aidoku-image-ocr-overlay')==='source-readability-panel'&&
              parent.dataset.aidokuRegion===node.dataset.aidokuRegion&&parent.contains(node),
            parentIsolation:parentStyle.isolation,parentZ:Number(parentStyle.zIndex),
            textStack:style.zIndex,inkContained:ink.width>0&&ink.height>0&&
              ink.left>=box.left-.5&&ink.right<=box.right+.5&&ink.top>=box.top-.5&&ink.bottom<=box.bottom+.5,
            textVisible:style.visibility==='visible'&&Number(style.opacity)>0,
            panel:style.backgroundColor,veil:style.backgroundImage,
            blur:style.webkitBackdropFilter,stroke:parseFloat(style.webkitTextStrokeWidth)>0,
            state:node.dataset.sourceBackgroundColor,text:node.textContent,
            plates:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')].map(n=>({
              x:n.offsetLeft,y:n.offsetTop,w:n.offsetWidth,h:n.offsetHeight,color:getComputedStyle(n).backgroundColor,
              z:Number(getComputedStyle(n).zIndex)})),
            sourceBlur:Array.from(document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-blur"],[data-aidoku-image-ocr-overlay="source-readability-blur"]')).map(n=>({filter:getComputedStyle(n).webkitBackdropFilter,z:Number(getComputedStyle(n).zIndex),width:n.getBoundingClientRect().width,height:n.getBoundingClientRect().height,raster:n.tagName==="CANVAS"?1:n.querySelectorAll("canvas").length})),textZ:style.zIndex};})()
            """) as? [String: Any])
            #expect(audit["panel"] as? String == "rgba(0, 0, 0, 0)")
            #expect(audit["veil"] as? String == "none")
            #expect(audit["blur"] as? String == "none")
            #expect(audit["stroke"] as? Bool == false)
            #expect(audit["state"] as? String == "readability-panel")
            let blurs = try #require(audit["sourceBlur"] as? [[String: Any]])
            #expect(blurs.isEmpty)
            let plates = try #require(audit["plates"] as? [[String: Any]])
            #expect(plates.count == 1)
            let plate = try #require(plates.first)
            #expect((plate["w"] as? Double ?? 0) > 0)
            #expect((plate["h"] as? Double ?? 0) > 0)
            #expect((plate["x"] as? Double ?? -1) >= 0)
            // Text is now inside the opaque panel's stacking context. A sibling
            // z-index comparison misreads `auto` as zero and cannot prove paint order.
            #expect(audit["ownsText"] as? Bool == true)
            #expect(audit["parentIsolation"] as? String == "isolate")
            #expect(audit["parentZ"] as? Int == plate["z"] as? Int)
            #expect(audit["textStack"] as? String == "auto")
            #expect(audit["inkContained"] as? Bool == true)
            #expect(audit["textVisible"] as? Bool == true)
            // Observe actual WebKit pixels with/without only the glyph node.
            // If the panel painted over its descendant, hiding the text could
            // not change this otherwise identical final image.
            let visible = try await web.takeSnapshot(configuration: nil)
            _ = try await web.evaluateJavaScript("document.querySelector('[data-aidoku-image-ocr-overlay=\"item\"]').style.visibility='hidden'")
            let hidden: UIImage
            do { hidden = try await web.takeSnapshot(configuration: nil) }
            catch {
                _ = try? await web.evaluateJavaScript("document.querySelector('[data-aidoku-image-ocr-overlay=\"item\"]').style.visibility=''")
                throw error
            }
            _ = try await web.evaluateJavaScript("document.querySelector('[data-aidoku-image-ocr-overlay=\"item\"]').style.visibility=''")
            let visibleCG = try #require(visible.cgImage), hiddenCG = try #require(hidden.cgImage)
            #expect(visibleCG.width == hiddenCG.width && visibleCG.height == hiddenCG.height)
            func pixels(_ image: CGImage) throws -> [UInt8] {
                var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
                try bytes.withUnsafeMutableBytes { storage in
                    let context = try #require(CGContext(data: storage.baseAddress, width: image.width,
                        height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                        space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
                }
                return bytes
            }
            let visibleBytes = try pixels(visibleCG), hiddenBytes = try pixels(hiddenCG)
            let changedBytes = zip(visibleBytes, hiddenBytes).filter { $0 != $1 }.count
            #expect(changedBytes > 0, "Actual glyph paint must be visible above the opaque owner")
            print("CAPTION_STACK_PAINT \(failure) translated=\(translated) changedRGBABytes=\(changedBytes)")
            let output = URL.documentsDirectory.appendingPathComponent("AuditCaptionStack", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let name = "\(failure)-\(translated ? "translated" : "ocr")"
            try #require(visible.pngData()).write(to: output.appendingPathComponent("\(name)-visible.png"))
            try #require(hidden.pngData()).write(to: output.appendingPathComponent("\(name)-hidden.png"))
            try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
                .write(to: output.appendingPathComponent("\(name).json"))
            #expect(plate["color"] as? String != "rgba(0, 0, 0, 0)")
            #expect(audit["text"] as? String == (translated ? "안녕" : "HELLO"))
        }
    }

    @Test(arguments: ["ocr", "ja", "ko"], [false, true])
    func largeOutlinedColumnsUseOpaqueBoxesWithinSamplingBudget(language: String, colored: Bool) async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 600, height: 600))
        web.loadHTMLString("<html><body style='margin:0'></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.callAsyncJavaScript("""
        const canvas=document.createElement('canvas');canvas.width=600;canvas.height=600;
        const ctx=canvas.getContext('2d'),gradient=ctx.createLinearGradient(0,0,600,600);
        gradient.addColorStop(0,'#e7e8e6');gradient.addColorStop(1,'#d3d5df');
        ctx.fillStyle=gradient;ctx.fillRect(0,0,600,600);
        // Deterministic glyph-shaped masks isolate the budget path from font loading.
        for(let x=155;x<430;x+=65)for(let y=160;y<430;y+=48){
          ctx.fillStyle='#ffffff';ctx.fillRect(x-3,y-3,26,34);
          ctx.fillStyle=colored?'#e75d26':'#101010';
          ctx.fillRect(x,y,4,28);ctx.fillRect(x+16,y,4,28);ctx.fillRect(x,y+12,20,4);
        }
        const image=new Image();image.id='reader-source-image';image.src=canvas.toDataURL();
        await image.decode();document.body.appendChild(image);
        """, arguments: ["colored": colored], in: nil, contentWorld: .page)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceTextColor = true
        settings.preserveSourceBackgroundColor = true
        settings.opacity = 1
        let item = BrowserOverlayItem(rect: CGRect(x: 130, y: 130, width: 335, height: 335),
            sourceText: "ああああああ", translatedText: language == "ocr" ? nil : language == "ja" ? "背景を残す" : "배경 유지",
            confidence: 1, sourceOrientation: .vertical)
        let payload = BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
            imageSize: CGSize(width: 600, height: 600), sourceRect: CGRect(x: 0, y: 0, width: 600, height: 600),
            settings: settings, targetLanguage: language == "ocr" ? "ja" : language, viewport: CGSize(width: 600, height: 600))
        var diagnosticPanel = BrowserSourcePanelRestoration.script
        var failureStage = 0
        while let range = diagnosticPanel.range(of: "return null;") {
            failureStage += 1
            diagnosticPanel.replaceSubrange(range, with: "{ (globalThis.panelFailures ||= []).push({stage:\(failureStage),b,palette,alpha:rgba.filter((_,i)=>i%4===3).reduce((n,v)=>Math.min(n,v),255)}); return /* diagnostic */ null; }")
        }
        let diagnosticRenderer = BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(
            of: BrowserSourcePanelRestoration.script, with: diagnosticPanel)
        _ = try await web.callAsyncJavaScript(diagnosticRenderer,
            arguments: ["revision": "1", "session": "large-panel", "items": payload,
                "appearance": ["minimumReadableFontSize": 1, "opacity": 1,
                    "preserveSourceTextColor": true, "preserveSourceBackgroundColor": true]],
            in: nil, contentWorld: .page)
        let result = try #require(try await web.evaluateJavaScript("""
        (()=>{const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
        const node=root.querySelector('[data-aidoku-image-ocr-overlay="item"]'),style=getComputedStyle(node);
        const audit=JSON.parse(root.dataset.panelRestorationAudit);
        return {transparent:style.backgroundColor==='rgba(0, 0, 0, 0)'&&style.backgroundImage==='none',
          // Box rendering never erases or blurs either neutral or colored source ink.
          presentation:node.dataset.sourceBackgroundColor==='readability-panel'&&root.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]').length===1,
          bounded:audit.length===0&&Number(root.dataset.panelRestorationPixels)===0&&Number(root.dataset.sourceColorPixels)<=393216,
          font:parseFloat(style.fontSize)>0,text:node.textContent,details:JSON.stringify({audit,data:node.dataset,failures:globalThis.panelFailures})};})()
        """) as? [String: Any])
        for key in ["transparent", "presentation", "bounded", "font"] { #expect(result[key] as? Bool == true, "\(key): \(result["details"] ?? "")") }
        #expect(result["text"] as? String == (language == "ocr" ? "ああああああ" : language == "ja" ? "背景を残す" : "배경 유지"))
    }

    @Test func previewAndTranslationSampleIndependentlyOnce() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 120))
        web.loadHTMLString("<html><body style='margin:0'></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        _ = try await web.callAsyncJavaScript("""
        const canvas=document.createElement('canvas');canvas.width=240;canvas.height=120;
        const ctx=canvas.getContext('2d');ctx.fillStyle='#fff0c0';ctx.fillRect(0,0,240,120);
        ctx.font='bold 34px sans-serif';ctx.fillStyle='#b02030';ctx.fillText('HELLO',30,70);
        const image=new Image();image.id='reader-source-image';image.src=canvas.toDataURL();
        await image.decode();document.body.appendChild(image);
        """, arguments: [:], in: nil, contentWorld: .page)
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceTextColor = true
        settings.preserveSourceBackgroundColor = true
        settings.opacity = 1
        func payload(_ translation: String?) throws -> [String: Any] {
            let item = BrowserOverlayItem(rect: CGRect(x: 15, y: 15, width: 210, height: 90),
                sourceText: "HELLO", translatedText: translation, confidence: 1, sourceOrientation: .horizontal)
            return try #require(BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
                imageSize: CGSize(width: 240, height: 120), sourceRect: CGRect(x: 0, y: 0, width: 240, height: 120),
                settings: settings, targetLanguage: "ko", viewport: CGSize(width: 240, height: 120)).first)
        }
        func render(_ revision: Int, _ translation: String?) async throws -> [String: String] {
            let item = try payload(translation)
            #expect(item["sourceColorEligible"] as? Bool == true)
            if translation == nil { #expect(item["sourceCleanup"] as? Bool == true) }
            _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
                arguments: ["revision": String(revision), "session": "preview-color", "items": [item],
                    "appearance": ["minimumReadableFontSize": 1, "opacity": 1,
                        "preserveSourceTextColor": true, "preserveSourceBackgroundColor": true]],
                in: nil, contentWorld: .page)
            return try #require(try await web.evaluateJavaScript("""
            (()=>{const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
            const node=root.querySelector('[data-aidoku-image-ocr-overlay="item"]');
            const style=getComputedStyle(node);return {text:style.color,panel:style.backgroundColor,
            visible:style.opacity,content:node.textContent,
            ink:node.dataset.sourceTextColor,surface:node.dataset.sourceBackgroundColor,
            samples:root.dataset.sourceColorSamples,hits:root.dataset.sourceColorCacheHits};})()
            """) as? [String: String])
        }
        let preview = try await render(1, nil)
        let previewAgain = try await render(2, nil)
        let translated = try await render(3, "안녕")
        let translatedAgain = try await render(4, "안녕")
        let returnedPreview = try await render(5, nil)
        #expect(preview["ink"] == "preserved")
        #expect(preview["visible"] == "1")
        #expect(preview["content"] == "HELLO")
        #expect(translated["visible"] == "1")
        #expect(translated["content"] == "안녕")
        #expect(preview["surface"] == "readability-panel")
        #expect(preview["samples"] == "1")
        #expect(translated["samples"] == "1")
        #expect(translated["hits"] == "0")
        for repeated in [previewAgain, translatedAgain, returnedPreview] {
            #expect(repeated["samples"] == "0")
            #expect(repeated["hits"] == "1")
        }
        #expect(preview["text"] == translated["text"])
        #expect(preview["panel"] == translated["panel"])
        settings.mode = .originalAndTranslation
        #expect(try payload(nil)["sourceColorEligible"] as? Bool == false)
    }

    @Test func texturedSurfaceAndOutlinedColorStayVisibleAcrossTranslation() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 120, height: 720))
        web.loadHTMLString("<html><body style='margin:0'></body></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let audit = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const canvas=document.createElement('canvas');canvas.width=120;canvas.height=720;
        const ctx=canvas.getContext('2d');
        const gradient=ctx.createLinearGradient(0,0,0,720);gradient.addColorStop(0,'#efcfb0');gradient.addColorStop(1,'#403b49');
        ctx.fillStyle=gradient;ctx.fillRect(0,0,120,720);
        ctx.font='bold 38px sans-serif';ctx.lineWidth=7;ctx.strokeStyle='#ffffff';ctx.fillStyle='#dd6046';
        for(let y=52;y<690;y+=45){ctx.strokeText('あ',40,y);ctx.fillText('あ',40,y);}
        const image=new Image();image.id='reader-source-image';image.src=canvas.toDataURL();await image.decode();document.body.appendChild(image);
        const sample=aidokuSourceColorSampler(image,true),bounds=[30/120,15/720,60/120,680/720];
        const result=sample.sample(bounds),again=sample.sample(bounds);
        return {result,stats:sample.stats,same:JSON.stringify(result)===JSON.stringify(again)};
        """, arguments: [:], in: nil, contentWorld: .page)
        let dictionary = try #require(audit as? [String: Any])
        let result = try #require(dictionary["result"] as? [String: Any])
        let foreground = try #require(result["foreground"] as? [Int])
        #expect(foreground[0] > 180 && foreground[1] < 140 && foreground[2] < 130)
        #expect(dictionary["same"] as? Bool == true)
        let stats = try #require(dictionary["stats"] as? [String: Any])
        #expect((stats["pixels"] as? Int ?? .max) <= 393216)
        #expect(stats["hits"] as? Int == 1)

        // Exercise the display-only surface when reconstruction is unavailable.
        // The original OCR must remain a visible DOM text node, then be replaced.
        let script = BrowserPageImageOverlayRenderer.renderScript
            .replacingOccurrences(of: "const sampled = cachedSourceSample(item);", with: "const sampled = {...cachedSourceSample(item),background:null,surface:{color:[175,146,129],stops:[[239,207,176],[64,59,73]],vertical:true}};")
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceTextColor = true
        settings.preserveSourceBackgroundColor = true
        settings.opacity = 1
        var appearances: [[String: String]] = []
        for (index, translation) in [nil, "번역된 글자"].enumerated() {
            let item = BrowserOverlayItem(rect: CGRect(x: 30, y: 15, width: 60, height: 680),
                sourceText: "あああ", translatedText: translation, confidence: 1, sourceOrientation: .vertical)
            var payload = BrowserPageImageOverlayRenderer.layoutPayload(items: [item], imageSize: CGSize(width: 120, height: 720),
                sourceRect: CGRect(x: 0, y: 0, width: 120, height: 720), settings: settings, targetLanguage: "ko", viewport: CGSize(width: 120, height: 720))
            // Smooth gradients can be restored; explicitly isolate the fallback
            // caption path here. Restoration success has its own rendering tests.
            for position in payload.indices { payload[position]["sourcePanelRestorationEligible"] = false }
            _ = try await web.callAsyncJavaScript(script, arguments: ["revision": index, "session": "surface-transition", "items": payload,
                "appearance": ["opacity": 1, "minimumReadableFontSize": 1, "preserveSourceTextColor": true, "preserveSourceBackgroundColor": true]], in: nil, contentWorld: .page)
            appearances.append(try #require(try await web.evaluateJavaScript("""
            (()=>{const n=document.querySelector('[data-aidoku-image-ocr-overlay="item"]'),s=getComputedStyle(n);
            const p=document.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]');
            return {text:n.textContent,color:s.color,opacity:s.opacity,background:s.backgroundImage,
              surface:n.dataset.sourceBackgroundColor,sampled:n.dataset.sourceSampledTextRGB,
              applied:n.dataset.sourceAppliedTextRGB,panel:p?getComputedStyle(p).backgroundColor:'',
              adjusted:n.dataset.sourceTextColorAdjusted};})()
            """) as? [String: String]))
        }
        #expect(appearances[0]["text"] == "あああ")
        #expect(appearances[1]["text"] == "번역된 글자")
        for appearance in appearances {
            #expect(appearance["opacity"] == "1")
            #expect(appearance["surface"] == "readability-panel")
            #expect(appearance["background"] == "none")
        }
        // Translation may darken the display ink to make outline-free text
        // readable. The sampled source color must survive that adjustment.
        let sampled = try #require(appearances[0]["sampled"])
        #expect(!sampled.isEmpty)
        #expect(sampled == appearances[1]["sampled"])
        #expect(appearances[1]["adjusted"] == "true")
        let ink = try #require(appearances[1]["applied"]).split(separator: ",").compactMap { Double($0) }
        let displayedInk = try #require(appearances[1]["color"])
            .components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Double($0) }
        let panel = try #require(appearances[1]["panel"])
            .components(separatedBy: CharacterSet.decimalDigits.inverted).compactMap { Double($0) }
        try #require(ink.count == 3 && panel.count == 3)
        #expect(displayedInk == ink)
        #expect(ink[0] > ink[1] && ink[1] > ink[2], "Keep the sampled red hue when improving contrast")
        func luminance(_ rgb: [Double]) -> Double {
            let linear = rgb.map { value in
                let channel = value / 255
                return channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
            }
            return linear[0] * 0.2126 + linear[1] * 0.7152 + linear[2] * 0.0722
        }
        let foregroundLuminance = luminance(ink)
        let backgroundLuminance = luminance(panel)
        let contrast = (max(foregroundLuminance, backgroundLuminance) + 0.05) /
            (min(foregroundLuminance, backgroundLuminance) + 0.05)
        #expect(contrast >= 4.5)
    }

    @Test func outlinedRecoveryRejectsAmbiguousColorsAndSolidArtwork() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading || web.url == nil { try await Task.sleep(for: .milliseconds(20)) }
        let value = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const c=document.createElement('canvas');c.width=180;c.height=120;const ctx=c.getContext('2d');
        const reset=()=>{ctx.fillStyle='#fff';ctx.fillRect(0,0,180,120);};
        const data=()=>ctx.getImageData(0,0,180,120).data;
        reset();
        for(let i=0;i<6;i++){ctx.fillStyle=i<3?'#dd6046':'#3060c0';ctx.beginPath();ctx.arc(15+i*28,60,8,0,Math.PI*2);ctx.fill();}
        const mixed=aidokuRecoverOutlinedColor(data(),180,120,{background:[255,255,255]});
        reset();ctx.fillStyle='#dd6046';for(let i=0;i<4;i++)ctx.fillRect(10+i*40,30,24,45);
        const art=aidokuRecoverOutlinedColor(data(),180,120,{background:[255,255,255]});
        const alpha=data();alpha[3]=0;
        return {mixed:mixed===null,art:art===null,
          alpha:aidokuRecoverOutlinedColor(alpha,180,120,{})===null,
          acceptedInk:aidokuRecoverOutlinedColor(data(),180,120,{foreground:[20,30,40],confidence:{foreground:.9}})===null};
        """, arguments: [:], in: nil, contentWorld: .page)
        for (name, passed) in try #require(value as? [String: Bool]) { #expect(passed, "\(name)") }
    }
}
