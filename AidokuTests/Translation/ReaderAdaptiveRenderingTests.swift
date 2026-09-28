import Darwin
import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderAdaptiveRenderingTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("AdaptiveRendering") }

    @Test func smoothGradientsPassButIllustrationTextureRejectsRestoration() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let result = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=120,h=140,n=w*h,mask=new Uint8Array(n),blocked=new Uint8Array(n),p=new Uint8ClampedArray(n*4);
        for(let y=0;y<h;y++)for(let x=0;x<w;x++){
          const i=y*w+x;p.set([180+x*.3+y*.1,190+x*.2,200+y*.15,255],i*4);
          if(x>45&&x<75&&y>20&&y<120)mask[i]=1;
        }
        const gradient=aidokuSourceSurfaceQuality(p,w,h,mask,blocked);
        for(let y=0;y<h;y++)for(let x=0;x<w;x++)if((Math.floor(x/9)+Math.floor(y/11))%2){const i=(y*w+x)*4;p[i]-=65;p[i+1]-=35;}
        const texture=aidokuSourceSurfaceQuality(p,w,h,mask,blocked);
        blocked.fill(1);const unknown=aidokuSourceSurfaceQuality(p,w,h,mask,blocked);
        return {gradient:gradient.safe,texture:!texture.safe,unknown:!unknown.safe,bounded:gradient.samples<=4096};
        """, arguments: [:], in: nil, contentWorld: .page)
        for (key, passed) in try #require(result as? [String: Bool]) { #expect(passed, "\(key)") }
    }

    @Test(arguments: [false, true], ["신경 쓰지 않아도 돼", "괜찮아…… 정말로"])
    func narrowKoreanCaptionRecoversIntermediateSizeWithoutSplittingWords(automatic: Bool, text: String) async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 160))
        web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:0'>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceBackgroundColor = true
        let item = BrowserOverlayItem(rect: CGRect(x: 20, y: 20, width: 27, height: 100),
            sourceText: "原文", translatedText: text, confidence: 1, sourceOrientation: .vertical)
        var payload = try #require(BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
            imageSize: CGSize(width: 240, height: 160), sourceRect: CGRect(x: 0, y: 0, width: 240, height: 160),
            settings: settings, targetLanguage: "ko", viewport: CGSize(width: 240, height: 160)).first)
        for (key, value) in ["x": 20, "y": 20, "width": 27, "height": 100, "fontSize": 5,
                            "lineHeight": 6, "paddingLeft": 2, "paddingRight": 2, "paddingTop": 2, "paddingBottom": 2] {
            payload[key] = value
        }
        payload.removeValue(forKey: "smallTextReference")
        // This fixture overrides the column solver with a fixed legacy box.
        // Keep its recovery path explicit; balanced columns have their own suite.
        payload["balancedColumn"] = false
        payload["allowsAutomaticFontRecovery"] = automatic
        // Exercise legacy recovery in this deliberately overridden 5pt box.
        // The later typography wrapper has separate word-layout coverage.
        let legacyRecoveryScript = BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(
            of: "let typographyCharacterBudget = 8192;", with: "let typographyCharacterBudget = 0;")
        _ = try await web.callAsyncJavaScript(legacyRecoveryScript,
            arguments: ["revision": "1", "session": "intermediate-font", "items": [payload],
                        "appearance": ["minimumReadableFontSize": 1, "opacity": 1, "preserveSourceBackgroundColor": true]],
            in: nil, contentWorld: .page)
        let result = try #require(try await web.evaluateJavaScript("""
        (()=>{
          const n=document.querySelector('[data-aidoku-image-ocr-overlay="item"]'),t=n.firstChild,r=document.createRange();
          let intact=true;
          for(const word of t.data.matchAll(/[^\\s]+/gu)) {
            const tops=[];
            for(let i=word.index;i<word.index+word[0].length;i++) {
              r.setStart(t,i);r.setEnd(t,i+1);
              const rects=[...r.getClientRects()].filter(b=>b.width>0&&b.height>0);
              tops.push(rects[rects.length-1].top);
            }
            intact &&= Math.max(...tops)-Math.min(...tops)<0.5;
          }
          return {font:parseFloat(getComputedStyle(n).fontSize),intact,text:n.textContent};
        })()
        """) as? [String: Any])
        let font = try #require(result["font"] as? Double)
        // The ellipsis token already occupies the 5pt box. It may only grow
        // inside the opaque plate it owns, and never by splitting a word
        // (checked below). Without automatic recovery the size is fixed.
        if automatic && !text.contains("……") {
            #expect(font > 5); #expect(font < 10.5)
        } else if automatic {
            #expect(font >= 5); #expect(font < 10.5)
        } else {
            #expect(font == 5)
        }
        #expect(result["intact"] as? Bool == true)
        #expect(result["text"] as? String == text)
    }

    @Test(arguments: ["room", "blocked", "manual", "newline", "edge", "tight"])
    func captionReflowUsesSpaceWithoutSplittingWordsOrCrossingNeighbors(scenario: String) async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 240, height: 180))
        web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:0'>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        var settings = ReaderTranslationSettings.defaultOverlay
        settings.preserveSourceBackgroundColor = true
        let text = scenario == "newline" ? "아저씨가\n기다리고 있어" : "아저씨가 기다리고 있어"
        let item = BrowserOverlayItem(rect: CGRect(x: 30, y: 20, width: 27, height: 100),
            sourceText: "原文", translatedText: text, confidence: 1, sourceOrientation: .vertical)
        var payload = try #require(BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
            imageSize: CGSize(width: 240, height: 180), sourceRect: CGRect(x: 0, y: 0, width: 240, height: 180),
            settings: settings, targetLanguage: "ko", viewport: CGSize(width: 240, height: 180)).first)
        for (key, value) in ["x": scenario == "edge" ? 0 : 30, "y": 20, "width": 27, "height": 100,
                            "fontSize": 9, "lineHeight": 11, "paddingLeft": 2, "paddingRight": 2,
                            "paddingTop": 2, "paddingBottom": 2] { payload[key] = value }
        payload["sourceBounds"] = [Double(scenario == "edge" ? 0 : scenario == "tight" ? 32 : 20)/240,
                                   20.0/180, Double(scenario == "tight" ? 23 : 60)/240, 100.0/180]
        payload["text"] = text
        payload.removeValue(forKey: "smallTextReference")
        payload["balancedColumn"] = false
        payload["allowsAutomaticFontRecovery"] = scenario != "manual"
        payload["id"] = "reflow-subject"
        var items = [payload]
        if scenario == "blocked" {
            for (index, x) in [0, 60].enumerated() {
                var obstacle = payload
                obstacle["id"] = "obstacle-\(index)"; obstacle["x"] = x; obstacle["width"] = 27
                obstacle["text"] = "옆 대사"; obstacle["allowsAutomaticFontRecovery"] = false
                obstacle["sourceBounds"] = [Double(x)/240, 20.0/180, 27.0/240, 100.0/180]
                items.append(obstacle)
            }
        }
        var results: [[String: Any]] = []
        // Keep the fixed-box reflow under test separate from word-aware spans,
        // which intentionally supersede that reflow in ordinary production use.
        // Observe the live DOM on both sides of the final unified-caption pass.
        // A child's final width belongs to its panel and cannot measure an earlier reflow.
        let geometryAudit = #"""
        (()=>{const n=root.querySelector('[data-aidoku-image-ocr-overlay="item"][data-aidoku-region="reflow-subject"]');
          const r=n.getBoundingClientRect(),t=n.firstChild,words=[];
          if(t?.nodeType===Node.TEXT_NODE)for(const word of t.data.matchAll(/[^\s]+/gu)){
            const glyphs=[];
            for(let i=word.index;i<word.index+word[0].length;i++){
              const q=document.createRange();q.setStart(t,i);q.setEnd(t,i+1);
              const rects=[...q.getClientRects()].filter(b=>b.width>0&&b.height>0),b=rects.at(-1);
              if(b)glyphs.push([b.left,b.top,b.width,b.height]);
            }
            words.push({text:word[0],glyphs});
          }
          const neighbors=[...root.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')]
            .filter(other=>other!==n).map(other=>{const q=document.createRange();q.selectNodeContents(other);return q.getBoundingClientRect();});
          const overlaps=words.flatMap(w=>w.glyphs).filter(g=>neighbors.some(b=>
            Math.min(g[0]+g[2],b.right)-Math.max(g[0],b.left)>.5&&
            Math.min(g[1]+g[3],b.bottom)-Math.max(g[1],b.top)>.5)).length;
          const wordBreaks=words.reduce((sum,w)=>sum+w.glyphs.slice(1).filter((g,i)=>Math.abs(g[1]-w.glyphs[i][1])>.5).length,0);
          return {width:r.width,words,wordBreaks,overlaps};})()
        """#
        let legacyRecoveryScript = BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(
            of: "let typographyCharacterBudget = 8192;", with: "let typographyCharacterBudget = 0;")
            .replacingOccurrences(of: "// Commit each opaque caption as one rectangle and one stacking context.",
                with: "globalThis.__captionBeforeUnified = \(geometryAudit);\n// Commit each opaque caption as one rectangle and one stacking context.")
        let output = URL.documentsDirectory.appendingPathComponent("AuditCaptionReflow", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        for enabled in [false, true] {
            let script = enabled ? legacyRecoveryScript :
                legacyRecoveryScript.replacingOccurrences(
                    of: "let captionReflowCharacterBudget = 8192;", with: "let captionReflowCharacterBudget = 0;")
            _ = try await web.callAsyncJavaScript(script,
                arguments: ["revision": enabled ? "2" : "1", "session": "caption-reflow", "items": items,
                    "appearance": ["minimumReadableFontSize": 1, "opacity": 1, "preserveSourceBackgroundColor": true]],
                in: nil, contentWorld: .page)
            results.append(try #require(try await web.evaluateJavaScript("""
            (()=>{const n=document.querySelector('[data-aidoku-image-ocr-overlay="item"][data-aidoku-region="reflow-subject"]');
              const p=document.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"][data-aidoku-region="reflow-subject"]');
              const r=n.getBoundingClientRect(),b=p.getBoundingClientRect();
              const range=document.createRange();range.selectNodeContents(n);const ink=range.getBoundingClientRect();
              const plates=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')]
                .map(p=>{const r=p.getBoundingClientRect();return [r.x,r.y,r.width,r.height];});
              const root=document.querySelector('[data-aidoku-image-ocr-overlay="root"]');
              const finalGeometry=\(geometryAudit);
              return {...n.dataset,text:n.textContent,width:r.width,left:r.left,right:r.right,plates:JSON.stringify(plates),
                intermediate:globalThis.__captionBeforeUnified,finalGeometry,
                font:parseFloat(n.style.fontSize),paddingLeft:parseFloat(getComputedStyle(n).paddingLeft),
                paddingRight:parseFloat(getComputedStyle(n).paddingRight),
                usableWidth:r.width-parseFloat(getComputedStyle(n).paddingLeft)-parseFloat(getComputedStyle(n).paddingRight),
                contained:b.left<=ink.left+.5&&b.right>=ink.right-.5&&
                  b.top<=ink.top+.5&&b.bottom>=ink.bottom-.5};})()
            """) as? [String: Any]))
            let phase = enabled ? "after" : "before"
            let snapshot = try await web.takeSnapshot(configuration: nil)
            try #require(snapshot.pngData()).write(to: output.appendingPathComponent("\(scenario)-\(phase).png"))
            let auditData = try JSONSerialization.data(withJSONObject: try #require(results.last), options: [.sortedKeys])
            try auditData.write(to: output.appendingPathComponent("\(scenario)-\(phase).json"))
        }
        let before = results[0], after = results[1]
        for (phase, result) in [("before", before), ("after", after)] {
            let data = try JSONSerialization.data(withJSONObject: result, options: [.sortedKeys])
            print("CAPTION_REFLOW_DIAGNOSTIC \(scenario) \(phase) \(String(decoding: data, as: UTF8.self))")
        }
        #expect(after["text"] as? String == text)
        #expect(after["font"] as? Double == before["font"] as? Double)
        #expect(after["contained"] as? Bool == true)
        #expect(after["plates"] as? String == before["plates"] as? String)
        let beforeFinal = try #require(before["finalGeometry"] as? [String: Any])
        let afterFinal = try #require(after["finalGeometry"] as? [String: Any])
        #expect(try #require(afterFinal["overlaps"] as? Int) <= #require(beforeFinal["overlaps"] as? Int))
        if scenario == "room" || scenario == "edge" {
            #expect(after["captionReflow"] as? String == "inside-fixed-box")
            let previousStage = try #require(before["intermediate"] as? [String: Any])
            let nextStage = try #require(after["intermediate"] as? [String: Any])
            #expect(try #require(nextStage["width"] as? Double) > #require(previousStage["width"] as? Double))
            #expect(try #require(nextStage["wordBreaks"] as? Int) <= #require(previousStage["wordBreaks"] as? Int))
            #expect(try #require(nextStage["overlaps"] as? Int) <= #require(previousStage["overlaps"] as? Int))
            #expect(after["unifiedCaption"] as? String == "true")
            // Final owner geometry and exact glyph rectangles must survive the
            // intermediate optimization; compare actual ranges, not dataset claims.
            let oldFinal = try #require(before["finalGeometry"] as? [String: Any])
            let newFinal = try #require(after["finalGeometry"] as? [String: Any])
            #expect(try JSONSerialization.data(withJSONObject: oldFinal, options: [.sortedKeys]) ==
                JSONSerialization.data(withJSONObject: newFinal, options: [.sortedKeys]))
            let words = try #require(newFinal["words"] as? [[String: Any]])
            #expect(words.map { $0["text"] as? String } == text.split(whereSeparator: \.isWhitespace).map { Optional(String($0)) })
            for word in words {
                let glyphs = try #require(word["glyphs"] as? [[Double]])
                try #require(!glyphs.isEmpty)
                let tops = glyphs.map { $0[1] }
                #expect(try #require(tops.max()) - #require(tops.min()) < 0.5)
            }
            #expect(try #require(after["left"] as? Double) >= 0)
            #expect(try #require(after["right"] as? Double) <= 240)
        } else {
            #expect(after["width"] as? Double == before["width"] as? Double)
            #expect(after["captionReflow"] == nil)
        }
    }

    @Test func captionPaletteKeepsSourceSurfaceAndHonorsInkPreservation() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 260))
        web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><body style='margin:0;background:#eee'>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let result = try #require(try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const cases=[
          {sample:{background:[246,242,237],confidence:{background:1}},ink:[0,158,225],bg:[246,242,237]},
          {sample:null,ink:[0,158,225],bg:[242,240,235]},
          {sample:{surface:{color:[245,239,231]},background:[10,10,10],confidence:{background:1}},ink:[170,210,235],bg:[245,239,231]},
          {sample:{background:[25,28,32],confidence:{background:1}},ink:[0,50,80],bg:[25,28,32]},
          {sample:{background:[255,245,180],confidence:{background:1}},ink:[120,35,45],bg:[255,245,180]},
          {sample:{foreground:[220,220,220],background:[255,255,255],confidence:{background:1}},
            ink:[17,18,23],bg:[255,255,255],preserve:true,exactInk:[220,220,220]},
          {sample:{foreground:[255,255,255],stroke:[96,54,28],background:[255,255,255],confidence:{background:1}},
            ink:[255,255,255],bg:[255,255,255],preserve:true,exactInk:[255,255,255]},
          {sample:{foreground:[225,190,205],background:[246,242,237],confidence:{background:1}},
            ink:[225,190,205],bg:[246,242,237],preserve:true,exactInk:[225,190,205]},
          {sample:{foreground:[220,220,220],background:[255,255,255],confidence:{background:1}},
            ink:[220,220,220],bg:[255,255,255],preserve:false},
          {sample:null,ink:[242,240,235],bg:[242,240,235],preserve:true},
          {sample:{background:[25,28,32],stroke:[96,54,28],confidence:{background:1}},
            ink:[25,28,32],bg:[25,28,32],preserve:true},
          {sample:{foreground:[220,NaN,220],background:[255,255,255],confidence:{background:1}},
            ink:[255,255,255],bg:[255,255,255],preserve:true}
        ];
        return cases.map(c=>{
          const before=JSON.stringify(c),p=aidokuCaptionPalette(c.sample,c.ink,c.preserve);
          return {surface:p.background.every((v,i)=>v===c.bg[i]),
            preservation:p.preserved===Boolean(c.exactInk),
            readable:c.exactInk
              ? p.foreground.every((v,i)=>v===c.exactInk[i])
              : aidokuSourceColorContrast(p.foreground,true,1,p.background)>=4.5,
            exact:!c.exactInk||p.foreground.every((v,i)=>v===c.exactInk[i]),
            unchanged:Boolean(c.exactInk)||aidokuSourceColorContrast(c.ink,true,1,c.bg)<4.5||p.foreground.every((v,i)=>v===c.ink[i]),
            // Coloured ink keeps its hue order; neutral ink (spread < 24) that crosses its surface goes to
            // the opposite extreme, where no hue order remains.
            blueOrder:Boolean(c.exactInk)||c.ink[2]<=c.ink[0]||Math.max(...c.ink)-Math.min(...c.ink)<24||p.foreground[2]>p.foreground[0],
            inputUnchanged:JSON.stringify(c)===before};
        });
        """, arguments: [:], in: nil, contentWorld: .page) as? [[String: Bool]])
        #expect(result.count == 12)
        for row in result { for (key, passed) in row { #expect(passed, "\(key)") } }
    }

    @Test func captionPlatePaddingSurvivesImageExport() async throws {
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 300, height: 300))
        web.loadHTMLString("<html><body style='margin:0'></body></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        _ = try await web.callAsyncJavaScript("""
        const c=document.createElement('canvas');c.width=c.height=1;
        const image=new Image();image.id='reader-source-image';image.src=c.toDataURL();document.body.append(image);await image.decode();
        const plate=document.createElement('div');plate.setAttribute('data-aidoku-image-ocr-overlay','source-readability-panel');
        plate.style.cssText='position:absolute;left:10px;top:20px;width:120px;height:40px;background:white';document.body.append(plate);
        const source=plate.cloneNode();source.dataset.sourceErasure='true';
        source.style.cssText='position:absolute;left:40px;top:0px;width:12px;height:120px;background:white';document.body.append(source);
        """, arguments: [:], in: nil, contentWorld: .page)
        let raw = try #require(try await web.callAsyncJavaScript(ReaderTranslationImageExporter.prepareExportScript,
            arguments: [:], in: nil, contentWorld: .page) as? String)
        let report = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let bounds = try #require(report["paintBounds"] as? [[Double]])
        #expect(bounds == [[10, 20, 120, 40], [40, 0, 12, 120]])
        #expect((report["masks"] as? [Any])?.isEmpty == true)
        let visible = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('[data-aidoku-image-ocr-overlay=source-readability-panel]')).visibility") as? String
        #expect(visible == "visible")
    }

}
