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
        payload["allowsAutomaticFontRecovery"] = automatic
        _ = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
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
        // The ellipsis token already occupies the available width at 5pt.
        // Increasing it would split that token, so this case must stay unchanged.
        if automatic && !text.contains("……") { #expect(font > 5); #expect(font < 10.5) }
        else { #expect(font == 5) }
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
        payload["allowsAutomaticFontRecovery"] = scenario != "manual"
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
        for enabled in [false, true] {
            let script = enabled ? BrowserPageImageOverlayRenderer.renderScript :
                BrowserPageImageOverlayRenderer.renderScript.replacingOccurrences(
                    of: "let captionReflowCharacterBudget = 8192;", with: "let captionReflowCharacterBudget = 0;")
            _ = try await web.callAsyncJavaScript(script,
                arguments: ["revision": enabled ? "2" : "1", "session": "caption-reflow", "items": items,
                    "appearance": ["minimumReadableFontSize": 1, "opacity": 1, "preserveSourceBackgroundColor": true]],
                in: nil, contentWorld: .page)
            results.append(try #require(try await web.evaluateJavaScript("""
            (()=>{const n=document.querySelector('[data-aidoku-image-ocr-overlay="item"]');
              const p=document.querySelector('[data-aidoku-image-ocr-overlay="source-readability-panel"]');
              const r=n.getBoundingClientRect(),b=p.getBoundingClientRect();
              const range=document.createRange();range.selectNodeContents(n);const ink=range.getBoundingClientRect();
              const plates=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')]
                .map(p=>{const r=p.getBoundingClientRect();return [r.x,r.y,r.width,r.height];});
              return {...n.dataset,text:n.textContent,width:r.width,left:r.left,right:r.right,plates:JSON.stringify(plates),
                font:parseFloat(n.style.fontSize),contained:b.left<=ink.left+.5&&b.right>=ink.right-.5&&
                  b.top<=ink.top+.5&&b.bottom>=ink.bottom-.5};})()
            """) as? [String: Any]))
        }
        let before = results[0], after = results[1]
        #expect(after["text"] as? String == text)
        #expect(after["font"] as? Double == before["font"] as? Double)
        #expect(after["contained"] as? Bool == true)
        #expect(after["plates"] as? String == before["plates"] as? String)
        if scenario == "room" || scenario == "edge" {
            #expect(after["captionReflow"] as? String == "inside-fixed-box")
            #expect(try #require(after["width"] as? Double) > #require(before["width"] as? Double))
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
            blueOrder:Boolean(c.exactInk)||c.ink[2]<=c.ink[0]||p.foreground[2]>p.foreground[0],
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
        """, arguments: [:], in: nil, contentWorld: .page)
        let raw = try #require(try await web.callAsyncJavaScript(ReaderTranslationImageExporter.prepareExportScript,
            arguments: [:], in: nil, contentWorld: .page) as? String)
        let report = try #require(JSONSerialization.jsonObject(with: Data(raw.utf8)) as? [String: Any])
        let bounds = try #require(report["paintBounds"] as? [[Double]])
        #expect(bounds == [[10, 20, 120, 40]])
        #expect((report["masks"] as? [Any])?.isEmpty == true)
        let visible = try await web.evaluateJavaScript("getComputedStyle(document.querySelector('[data-aidoku-image-ocr-overlay=source-readability-panel]')).visibility") as? String
        #expect(visible == "visible")
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func sustainedRealPageRenderingReleasesRetiredCanvases() async throws {
        struct Fixture: Decodable { let name: String; let image: String; let regions: String; let target: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 430, height: 900))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        window.rootViewController?.view.addSubview(web)
        defer { web.removeFromSuperview(); window.isHidden = true; previous?.makeKey() }
        web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}img{width:430px}</style><img id='reader-source-image'>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        var rows: [[String: Any]] = []
        var retiredCount = 0
        let requested = (try? String(contentsOf: Self.directory.appendingPathComponent("memory-soak-count.txt"), encoding: .utf8))
            .flatMap { Int($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 60
        let pageCount = min(1800, max(60, requested))
        let diagnostic = FileManager.default.fileExists(atPath: Self.directory.appendingPathComponent("memory-diagnostic.txt").path)
        for page in 0..<pageCount {
            let fixture = fixtures[page % fixtures.count]
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.image))
            let source = try #require(UIImage(data: data))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self,
                from: Data(contentsOf: Self.directory.appendingPathComponent(fixture.regions))).map(\.region)
            if diagnostic {
                web.frame.size = CGSize(width: 430, height: 430 * source.size.height / source.size.width)
                _ = try await web.callAsyncJavaScript(ReaderTranslationOverlayView.backgroundScript,
                    arguments: ["revision": page + 1, "source": "data:image/png;base64," + data.base64EncodedString(), "fit": "contain"],
                    in: nil, contentWorld: .page)
            } else {
                _ = try await web.callAsyncJavaScript("""
                const image=document.getElementById('reader-source-image'); image.src=source; await image.decode();
                """, arguments: ["source": "data:image/png;base64," + data.base64EncodedString()], in: nil, contentWorld: .page)
            }
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.preserveSourceBackgroundColor = true; settings.preserveSourceTextColor = true
            var maximumBytes = 0
            for pass in 0..<4 {
                let revision = page * 5 + pass + 1
                let width = CGFloat(430 + pass * 3)
                let payload = BrowserPageImageOverlayRenderer.layoutPayload(
                    items: ReaderTranslationRegion.overlayItems(regions, imageSize: source.size), imageSize: source.size,
                    sourceRect: CGRect(x: 0, y: 0, width: width, height: width * source.size.height / source.size.width),
                    settings: settings, targetLanguage: fixture.target, viewport: web.bounds.size)
                _ = try await web.evaluateJavaScript("globalThis.retired=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay=\"root\"] canvas')];true")
                let result = try await web.callAsyncJavaScript(BrowserPageImageOverlayRenderer.renderScript,
                    arguments: ["revision": revision, "session": "memory-soak", "items": payload,
                        "appearance": ["minimumReadableFontSize": 1, "opacity": 1, "preserveSourceBackgroundColor": true, "preserveSourceTextColor": true]],
                    in: nil, contentWorld: .page) as? [String: Any]
                #expect(result?["status"] as? String == "committed")
                let audit = try #require(try await web.evaluateJavaScript("""
                (()=>{const c=globalThis.__aidokuSourceCleanupV1.last;
                  return {bytes:c?.bytes||0,actual:[...(c?.entries.values()||[])].reduce((n,e)=>n+(e.restored?.rgba?.byteLength||0)+(e.restored?.layoutSafe?.byteLength||0)+(e.output?.data?.byteLength||0),0),
                    retired:retired.length,released:retired.every(c=>c.width===0&&c.height===0),
                    roots:document.querySelectorAll('[data-aidoku-image-ocr-overlay="root"]').length};})()
                """) as? [String: Any])
                let bytes = try #require(audit["bytes"] as? Int)
                #expect(bytes == audit["actual"] as? Int)
                #expect(bytes <= 4 * 1_024 * 1_024)
                #expect(audit["released"] as? Bool == true)
                #expect(audit["roots"] as? Int == 1)
                maximumBytes = max(maximumBytes, bytes)
                retiredCount += audit["retired"] as? Int ?? 0
            }
            _ = try await web.evaluateJavaScript("globalThis.retired=[...document.querySelectorAll('[data-aidoku-image-ocr-overlay=\"root\"] canvas')];globalThis.retiredCache=globalThis.__aidokuSourceCleanupV1.last;true")
            let revision = page * 5 + 5
            let script = page.isMultiple(of: 2) ? BrowserPageImageOverlayRenderer.clearScript : BrowserPageImageOverlayRenderer.renderScript
            _ = try await web.callAsyncJavaScript(script, arguments: ["revision": revision, "session": "memory-soak", "items": []], in: nil, contentWorld: .page)
            let released = try await web.evaluateJavaScript("retired.every(c=>c.width===0&&c.height===0)&&!globalThis.__aidokuSourceCleanupV1.last&&retiredCache.entries.size===0&&retiredCache.bytes===0") as? Bool
            #expect(released == true)
            _ = try await web.evaluateJavaScript("globalThis.retired=null;globalThis.retiredCache=null")
            try await Task.sleep(for: .milliseconds(100))
            var info = task_vm_info_data_t()
            var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
            let status = withUnsafeMutablePointer(to: &info) { pointer in
                pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                    task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
                }
            }
            #expect(status == KERN_SUCCESS)
            rows.append(["page": page, "unixTime": Date().timeIntervalSince1970, "fixture": fixture.name, "footprintMiB": Double(info.phys_footprint) / 1_048_576, "cachePeakBytes": maximumBytes])
        }
        if diagnostic {
            var phases: [[String: Any]] = []
            for phase in ["idle", "source-removed", "document-reset"] {
                if phase == "source-removed" {
                    _ = try await web.callAsyncJavaScript(ReaderTranslationOverlayView.backgroundScript,
                        arguments: ["revision": pageCount + 1, "source": "", "fit": "contain"], in: nil, contentWorld: .page)
                } else if phase == "document-reset" {
                    web.loadHTMLString("<html><body></body></html>", baseURL: nil)
                    for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
                }
                let audit = try #require(try await web.evaluateJavaScript("""
                (()=>({elements:document.querySelectorAll('*').length,canvases:document.querySelectorAll('canvas').length,
                  overlays:document.querySelectorAll('[data-aidoku-image-ocr-overlay]').length,
                  images:document.images.length,cleanupBytes:globalThis.__aidokuSourceCleanupV1?.last?.bytes||0}))()
                """) as? [String: Any])
                #expect(audit["canvases"] as? Int == 0)
                #expect(audit["overlays"] as? Int == 0)
                #expect(audit["cleanupBytes"] as? Int == 0)
                phases.append(["phase": phase, "unixTime": Date().timeIntervalSince1970, "DOM": audit])
                try JSONSerialization.data(withJSONObject: phases, options: [.prettyPrinted, .sortedKeys])
                    .write(to: Self.directory.appendingPathComponent("memory-phases.json"), options: .atomic)
                print("MEMORY_PHASE \(phase) \(Date().timeIntervalSince1970)")
                try await Task.sleep(for: .seconds(60))
            }
        }
        #expect(retiredCount > 100)
        let early = rows[10..<20].compactMap { $0["footprintMiB"] as? Double }.reduce(0,+) / 10
        let late = rows[(pageCount - 10)..<pageCount].compactMap { $0["footprintMiB"] as? Double }.reduce(0,+) / 10
        #expect(late - early < 64, "Warm app footprint should settle across repeated rendering")
        try JSONSerialization.data(withJSONObject: ["rows": rows, "retiredCanvases": retiredCount,
            "warmGrowthMiB": late - early, "scope": "App footprint only; WebKit processes sampled separately by host. No OCR/provider."], options: [.prettyPrinted, .sortedKeys])
            .write(to: Self.directory.appendingPathComponent("memory-soak.json"))
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func realPageComparison() async throws {
        struct Fixture: Decodable { let name: String; let image: String; let regions: String; let target: String }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        let baseline = try String(contentsOf: Self.directory.appendingPathComponent("baseline.js"), encoding: .utf8)
        let output = Self.directory.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.makeKeyAndVisible()
        defer { window.isHidden = true }
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.image))
            let source = try #require(UIImage(data: data))
            let regionsData = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.regions))
            let regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: regionsData).map(\.region)
            let size = CGSize(width: 430, height: 430 * source.size.height / source.size.width)
            for mode in ["before", "after", "boxes", "ocr"] {
                let web = WKWebView(frame: CGRect(origin: .zero, size: size))
                web.scrollView.contentInsetAdjustmentBehavior = .never
                window.rootViewController?.view.addSubview(web)
                defer { web.removeFromSuperview() }
                web.loadHTMLString("<meta name='viewport' content='width=device-width,initial-scale=1'><style>body{margin:0}img{display:block;width:100%}</style><img id='reader-source-image' src='data:image/png;base64,\(data.base64EncodedString())'>", baseURL: nil)
                for _ in 0..<500 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
                _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()", arguments: [:], in: nil, contentWorld: .page)
                var settings = ReaderTranslationSettings.defaultOverlay
                settings.opacity = 1; settings.preserveSourceTextColor = true; settings.preserveSourceBackgroundColor = mode != "boxes"
                let renderer = BrowserPageImageOverlayRenderer { web, script, arguments in
                    try await BrowserPageImageOverlayRenderer.evaluateJavaScript(web, mode == "before" ? baseline : script, arguments)
                }
                let renderedRegions = mode == "ocr" ? regions.map { region in var copy = region; copy.translation = nil; return copy } : regions
                renderer.render(on: web, items: ReaderTranslationRegion.overlayItems(renderedRegions, imageSize: source.size), imageSize: source.size, sourceRect: CGRect(origin: .zero, size: size), settings: settings, targetLanguage: fixture.target)
                for _ in 0..<1000 where renderer.lastDiagnostic == nil { try await Task.sleep(for: .milliseconds(20)) }
                #expect(renderer.lastDiagnostic?.outcome == .committed)
                let audit = try #require(try await web.evaluateJavaScript("""
                (()=>({root:{...document.querySelector('[data-aidoku-image-ocr-overlay="root"]').dataset},
                  items:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>({
                    ...n.dataset,text:n.textContent,x:n.offsetLeft,y:n.offsetTop,width:n.offsetWidth,height:n.offsetHeight,
                    font:getComputedStyle(n).fontSize,stroke:getComputedStyle(n).webkitTextStrokeWidth})),
                  plates:JSON.stringify([...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-readability-panel"]')]
                    .map(n=>{const r=n.getBoundingClientRect();return [n.dataset.aidokuRegion,r.x,r.y,r.width,r.height];})),
                  blur:document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-blur"],[data-aidoku-image-ocr-overlay="source-readability-blur"]').length}))()
                """) as? [String: Any])
                if mode == "after" || mode == "ocr" {
                    #expect(audit["blur"] as? Int == 0)
                    if fixture.name.hasPrefix("halo-regression-") {
                        #expect((audit["items"] as? [[String: Any]])?.count == regions.count)
                    }
                    for node in try #require(audit["items"] as? [[String: Any]]) {
                        if node["sourceTextColor"] as? String == "preserved" {
                            let changed = node["sourceAppliedTextRGB"] as? String != node["sourceSampledTextRGB"] as? String
                            #expect(node["sourceTextColorAdjusted"] as? String == (changed ? "true" : "false"))
                        }
                        if fixture.name.hasPrefix("palette-accuracy-") {
                            #expect(node["captionSurface"] as? String == "observed")
                            #expect(node["sourceAppliedTextRGB"] as? String == node["sourceSampledTextRGB"] as? String,
                                "Preserve neutral ink as well as chromatic ink")
                            let rgb = (node["sourceAppliedBackgroundRGB"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
                            #expect(rgb.count == 3)
                            if fixture.name.contains("translucent") {
                                #expect(rgb.count == 3 && rgb[2] < 244, "Do not replace translucent backing with its brightest mode")
                            }
                            if fixture.name.contains("neutral") {
                                let ink = (node["sourceAppliedTextRGB"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
                                if node["aidokuRegion"] as? String == "0" {
                                    #expect(ink.count == 3 && ink[0] > ink[1] + 60 && ink[0] > ink[2] + 90,
                                        "Downsampling must not wash the orange core into a pale halo tint")
                                } else {
                                    #expect(ink.count == 3 && ink.allSatisfy { $0 < 80 }, "Dark source ink must remain dark")
                                }
                            }
                        }
                        if fixture.name.hasPrefix("observed-") {
                            #expect(node["captionSurface"] as? String == "observed")
                            let rgb = (node["sourceAppliedBackgroundRGB"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
                            let ink = (node["sourceAppliedTextRGB"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
                            #expect(rgb.count == 3 && ink.count == 3)
                            if node["text"] as? String == "성인향" {
                                #expect(rgb.allSatisfy { $0 < 40 })
                                #expect(ink.count == 3 && ink[0] > 180 && ink[1] > 150 && ink[2] < 150)
                            } else if node["text"] as? String == "루나틱" {
                                #expect(ink.allSatisfy { $0 < 40 })
                            } else if fixture.name == "observed-art-strip" {
                                #expect(rgb.contains { $0 < 210 }, "Do not invent a white panel over artwork")
                            }
                        }
                        if fixture.name.hasPrefix("halo-regression-") {
                            let rgb = (node["sourceAppliedBackgroundRGB"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
                            let ink = (node["sourceAppliedTextRGB"] as? String ?? "").split(separator: ",").compactMap { Int($0) }
                            #expect(rgb.count == 3 && ink.count == 3)
                            if fixture.name.contains("orange") {
                                #expect(ink.count == 3 && ink[0] > 180 && ink[1] < 150 && ink[2] < 70, "Every orange source caption retains its chromatic ink")
                            } else {
                                #expect(rgb.contains { $0 < 200 }, "A white glyph halo is not a backing panel")
                                let text = node["text"] as? String ?? ""
                                if text.hasPrefix("それは") || text == "그렇게 생각했어." {
                                    #expect(ink.count == 3 && ink[0] > ink[1] + 35 && ink[0] > ink[2] + 45,
                                        "The orange caption over artwork must not become white or gray")
                                }
                            }
                        }
                        #expect(node["sourceStrokeColor"] as? String == "none")
                        #expect(node["sourceAppliedStrokeRGB"] as? String == "")
                        #expect(node["stroke"] as? String == "0px")
                    }
                }
                try JSONSerialization.data(withJSONObject: audit, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("\(fixture.name)-\(mode).json"))
                _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
                let image = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<UIImage, Error>) in
                    web.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
                try #require(image.pngData()).write(to: output.appendingPathComponent("\(fixture.name)-\(mode).png"))
            }
        }
    }
}
