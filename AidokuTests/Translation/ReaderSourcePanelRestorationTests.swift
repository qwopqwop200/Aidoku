import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSourcePanelRestorationTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("MangaQuality") }

    @Test func restorationRequiresReplacementDisplay() throws {
        var settings = ReaderTranslationSettings.defaultOverlay
        func eligible(_ translation: String?) throws -> Bool {
            let item = BrowserOverlayItem(rect: CGRect(x: 30, y: 30, width: 80, height: 200),
                sourceText: "テストです", translatedText: translation, confidence: 1, sourceOrientation: .vertical)
            let payload = try #require(BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
                imageSize: CGSize(width: 300, height: 400), sourceRect: CGRect(x: 0, y: 0, width: 300, height: 400),
                settings: settings, targetLanguage: "ko", viewport: CGSize(width: 300, height: 400)).first)
            return payload["sourcePanelRestorationEligible"] as? Bool == true
        }
        #expect(try eligible(nil) == true)
        #expect(try eligible("시험이랍니다") == true)
        settings.mode = .originalAndTranslation
        #expect(try eligible("시험이랍니다") == false)
    }

    @Test func reconstructionPreservesUnmaskedPixelsAndRejectsUnsafeInputs() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let result = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=96,h=180,rgba=new Uint8ClampedArray(w*h*4);
        for(let y=0;y<h;y++)for(let x=0;x<w;x++)rgba.set([190+y/4,188+y/4,194+y/4,255],(y*w+x)*4);
        // Independent dark letter-like shapes with a white outline.
        for(let y=30;y<150;y+=30)for(let yy=y;yy<y+17;yy++)for(let x=35;x<57;x++)
          if(x<40||yy<y+4||yy>=y+13)rgba.set([8,8,8,255],(yy*w+x)*4);
        // A neighboring panel rule must stay black without bleeding into the fill.
        for(let y=0;y<h;y++)rgba.set([0,0,0,255],(y*w+65)*4);
        const palette={foreground:[8,8,8],background:[210,208,214],stroke:[255,255,255]};
        const before=rgba.slice();
        const output=aidokuRestoreSourcePanel(rgba,w,h,[32,26,30,130],palette);
        if(!output)return {accepted:false};
        let changedOutside=0,remainingInk=0;
        for(let i=0;i<w*h;i++){
          if(rgba[i*4]!==before[i*4])changedOutside++;
          if(i%w===65&&output.rgba[i*4+3])changedOutside++;
          const x=i%w,y=i/w|0;
          if((x<20||x>72||y<12||y>176)&&output.rgba[i*4+3])changedOutside++;
          if(x!==65&&before[i*4]<100&&(!output.rgba[i*4+3]||output.rgba[i*4]<140))remainingInk++;
        }
        const alpha=rgba.slice();alpha[3]=0;
        const rounded=rgba.slice();for(let q=3;q<rounded.length;q+=4)rounded[q]=254;
        const translucent=rgba.slice();translucent[3]=128;
        return {accepted:true,changedOutside,remainingInk,
          roundedAlphaAccepted:aidokuRestoreSourcePanel(rounded,w,h,[32,26,30,130],palette)!==null,
          translucentRejected:aidokuRestoreSourcePanel(translucent,w,h,[32,26,30,130],palette)===null,
          alphaRejected:aidokuRestoreSourcePanel(alpha,w,h,[32,26,30,130],palette)===null,
          darkRejected:aidokuRestoreSourcePanel(rgba,w,h,[32,26,30,130],{...palette,background:[20,20,20]})===null,
          budgetRejected:aidokuRestoreSourcePanel(new Uint8ClampedArray(512*512*4),512,512,[24,24,60,300],palette)===null};
        """, arguments: [:], in: nil, contentWorld: .page)
        let audit = try #require(result as? [String: Any])
        #expect(audit["accepted"] as? Bool == true)
        #expect(audit["changedOutside"] as? Int == 0)
        #expect(audit["remainingInk"] as? Int == 0)
        for key in ["alphaRejected", "roundedAlphaAccepted", "translucentRejected", "darkRejected", "budgetRejected"] { #expect(audit[key] as? Bool == true) }
    }

    @Test func coloredCaptionKeepsItsPanelAndRemovesInkWithMissingPalette() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let raw = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=180,h=90,p=new Uint8ClampedArray(w*h*4),ink=[];
        for(let i=0;i<w*h;i++)p.set([0,0,0,255],i*4);
        for(let y=14;y<76;y++)for(let x=14;x<164;x++)p.set([255,222,70,255],(y*w+x)*4);
        for(let x=24;x<145;x+=34)for(let y=28;y<60;y++)for(let xx=x;xx<x+22;xx++)if(xx<x+5||y<33||y>=55){
          const i=y*w+xx;p.set([0,0,0,255],i*4);ink.push(i);
        }
        const before=p.slice(),out=aidokuSoftenSourceGlyphs(p,w,h,[10,10,160,70],{background:[0,0,0]},false);
        return {accepted:!!out,flat:out?.flatCaption,
          clean:!!out&&ink.every(i=>out.rgba[i*4+3]===255&&out.rgba[i*4]>245&&out.rgba[i*4+1]>210&&out.rgba[i*4+2]<80),
          border:!!out&&Array.from({length:w},(_,x)=>x).every(i=>out.rgba[i*4+3]===0),
          unchanged:p.every((v,i)=>v===before[i]),foreground:out?.inferredForeground};
        """, arguments: [:], in: nil, contentWorld: .page)
        let result = try #require(raw as? [String: Any])
        for key in ["accepted", "flat", "clean", "border", "unchanged"] { #expect(result[key] as? Bool == true, "\(key)") }
        let foreground = try #require(result["foreground"] as? [Int])
        #expect(foreground.allSatisfy { $0 < 40 })
    }

    @Test func observedInkColorsRestoreOnLightAndDarkBackgrounds() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(20)
        while web.isLoading || web.url == nil {
            if Date() > deadline { throw URLError(.timedOut) }
            try await Task.sleep(for: .milliseconds(20))
        }
        let result = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const cases=[];
        const colors=[[0,0,0],[255,255,255],[230,85,35],[35,170,70],[35,75,225],
          [155,55,195],[220,190,35],[120,125,130],[190,205,222]];
        for(const bg of [[220,224,230],[28,32,40]])for(const fg of colors)for(const outlined of [false,true]){
          const w=96,h=180,rgba=new Uint8ClampedArray(w*h*4),ink=[];
          const stroke=outlined?(Math.min(...fg)>170?[30,30,30]:[255,255,255]):null;
          for(let i=0;i<w*h;i++)rgba.set([...bg,255],i*4);
          for(let y=30;y<150;y+=30){
            if(stroke)for(let yy=y-2;yy<y+19;yy++)for(let x=33;x<59;x++)rgba.set([...stroke,255],(yy*w+x)*4);
            for(let yy=y;yy<y+17;yy++)for(let x=35;x<57;x++)if(x<40||yy<y+4||yy>=y+13){
              const i=yy*w+x;rgba.set([...fg,255],i*4);ink.push(i);
            }
          }
          // A frame-connected contrasting rule is outside the OCR-owned glyphs.
          for(let y=0;y<h;y++)rgba.set([240,40,180,255],(y*w+82)*4);
          const before=rgba.slice(),out=aidokuRestoreSourcePanel(rgba,w,h,[32,26,30,130],
            {foreground:fg,background:bg,stroke,confidence:{foreground:1,background:1}});
          const clean=Boolean(out)&&ink.every(i=>out.rgba[i*4+3]===255&&bg.every((v,c)=>Math.abs(v-out.rgba[i*4+c])<=3));
          const intact=Boolean(out)&&rgba.every((v,i)=>v===before[i])&&Array.from({length:h},(_,y)=>y*w+82).every(i=>out.rgba[i*4+3]===0);
          cases.push({name:JSON.stringify({bg,fg,outlined}),clean,intact});
        }
        return cases;
        """, arguments: [:], in: nil, contentWorld: .page)
        let cases = try #require(result as? [[String: Any]])
        #expect(cases.count == 36)
        for row in cases {
            #expect(row["clean"] as? Bool == true, "\(row["name"] ?? "")")
            #expect(row["intact"] as? Bool == true, "\(row["name"] ?? "")")
        }
    }

    @Test func suppressedRubyRetainsInkThroughArchiveWithoutMovingBody() throws {
        guard #available(iOS 18.0, *) else { return }
        func line(_ text: String, _ rect: CGRect) -> NativeCoreMLOCRLine {
            NativeCoreMLOCRLine(polygon: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
                text: text, score: 0.99, orientation: .vertical, orientationIsEstimated: true)
        }
        let body = line("世界だなって", CGRect(x: 192, y: 873, width: 33, height: 146))
        let ruby = line("わたし", CGRect(x: 218, y: 877, width: 16, height: 50))
        let detached = line("わたし", CGRect(x: 90, y: 877, width: 16, height: 50))
        for input in [[body, ruby, detached], [detached, ruby, body]] {
            let merged = NativeOCRTextLineMerger.merge(input, imageWidth: 1000, imageHeight: 1400)
            let row = try #require(merged.first { $0.text == "世界《わたし》だなって" })
            #expect(row.boundingRect == CGRect(x: 192, y: 873, width: 33, height: 146))
            #expect(row.auxiliaryInkRects == [CGRect(x: 218, y: 877, width: 16, height: 50)])
            #expect(merged.count == 2)
            #expect(try JSONDecoder().decode(PaddleOCRLine.self, from: JSONEncoder().encode(row)) == row)
        }
        var region = ReaderTranslationRegion(id: "ruby", rect: CGRect(x: 0.192, y: 0.623, width: 0.033, height: 0.104),
            source: "世界", translation: "세상")
        region.auxiliaryInkRects = [CGRect(x: 0.218, y: 0.626, width: 0.016, height: 0.036)]
        let archive = try ReaderTranslationRegionArchive([region])
        let restored = try ReaderTranslationRegionArchive.regions(base: archive.base, variant: archive.variant)
        #expect(restored == [region])
        let item = try #require(restored.first).overlayItem(index: 0, imageSize: CGSize(width: 1000, height: 1400))
        #expect(item.auxiliaryInkRects.count == 1)
        let payload = try #require(BrowserPageImageOverlayRenderer.layoutPayload(items: [item],
            imageSize: CGSize(width: 1000, height: 1400), sourceRect: CGRect(x: 0, y: 0, width: 430, height: 602),
            settings: ReaderTranslationSettings.defaultOverlay, targetLanguage: "ko", viewport: CGSize(width: 430, height: 602)).first)
        #expect((payload["auxiliaryInkRects"] as? [[CGFloat]])?.count == 1)
    }

    @Test func companionInkRequiresOwnershipAndOutlinedLeadingRule() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let result = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=160,h=260,rgba=new Uint8ClampedArray(w*h*4),b=[60,100,30,125];
        for(let i=0;i<w*h;i++)rgba.set([200,198,205,255],i*4);
        const box=(x,y,ww,hh,c)=>{for(let yy=y;yy<y+hh;yy++)for(let xx=x;xx<x+ww;xx++)rgba.set([...c,255],(yy*w+xx)*4);};
        for(let y=104;y<220;y+=30)box(66,y,15,10,[8,8,8]);
        box(96,113,6,9,[8,8,8]);box(96,131,6,9,[8,8,8]);box(102,142,1,1,[8,8,8]); // owned ruby
        box(83,104,1,1,[8,8,8]);box(87,218,1,1,[8,8,8]);
        box(129,113,6,9,[8,8,8]); // neighboring unrelated ink
        box(71,50,9,50,[255,255,255]);box(74,54,2,44,[8,8,8]);
        const palette={foreground:[8,8,8],background:[200,198,205],stroke:[255,255,255]};
        const baseline=aidokuRestoreSourcePanel(rgba,w,h,b,palette);
        const fixed=aidokuRestoreSourcePanel(rgba,w,h,b,palette,{auxiliary:[[94,110,10,34]],leadingRule:true});
        const dark=rgba.slice();for(let i=0;i<w*h;i++)for(let c=0;c<3;c++)dark[i*4+c]=255-dark[i*4+c];
        const inverse=aidokuRestoreSourcePanel(dark,w,h,b,{foreground:[247,247,247],background:[55,57,50],stroke:[0,0,0]},
          {auxiliary:[[94,110,10,34]],leadingRule:true});
        const painted=(r,x,y)=>r?.rgba[(y*w+x)*4+3]===255;
        box(71,50,9,50,[200,198,205]);box(74,54,2,44,[8,8,8]);
        const noOutline=aidokuRestoreSourcePanel(rgba,w,h,b,palette,{leadingRule:true});
        return {accepted:!!fixed,removesBodyFragment:painted(fixed,83,104),preservesIsolatedSpeck:!painted(fixed,87,218),removesTinyRuby:painted(fixed,102,142),removesWhiteRuby:painted(inverse,98,116),
          darkFill:inverse?.rgba[(116*w+98)*4]<115,inversePreservesNeighbor:!painted(inverse,131,116),bodyOnlyLeavesRuby:!painted(baseline,98,116),bodyOnlyLeavesDash:!painted(baseline,74,70),
          removesRuby:painted(fixed,98,116),removesDash:painted(fixed,74,70),preservesNeighbor:!painted(fixed,131,116),
          preservesUnoutlinedLine:!painted(noOutline,74,70)};
        """, arguments: [:], in: nil, contentWorld: .page)
        let audit = try #require(result as? [String: Bool])
        for (key, passed) in audit { #expect(passed, "\(key)") }
    }

    @Test func detachedRubyEdgeRequiresNearbyOwnedInkAndNoDrawing() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let value = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=130,h=230,p=new Uint8ClampedArray(w*h*4),b=[40,25,40,180];
        for(let i=0;i<w*h;i++)p.set([220,220,220,255],i*4);
        const box=(x,y,ww,hh)=>{for(let yy=y;yy<y+hh;yy++)for(let xx=x;xx<x+ww;xx++)p.set([8,8,8,255],(yy*w+xx)*4);};
        for(let y=35;y<190;y+=30)box(72,y,11,9);
        box(84,38,2,2); // Outside the body tolerance, two pixels from an owned core.
        box(86,155,1,1); // No nearby owned core.
        const palette={foreground:[8,8,8],background:[220,220,220]};
        const fixed=aidokuRestoreSourcePanel(p,w,h,b,palette,{vertical:true});
        const horizontal=aidokuRestoreSourcePanel(p,w,h,b,palette);
        const painted=(r,x,y)=>r?.rgba[(y*w+x)*4+3]===255;
        box(88,0,1,h); // Adjacent illustration rules veto fringe ownership.
        const drawing=aidokuRestoreSourcePanel(p,w,h,b,palette,{vertical:true});
        return {removed:painted(fixed,84,38),horizontalPreserved:!painted(horizontal,84,38),
          isolatedPreserved:!painted(fixed,86,155),drawingPreserved:!painted(drawing,84,38)&&!painted(drawing,88,38)};
        """, arguments: [:], in: nil, contentWorld: .page)
        for (key, passed) in try #require(value as? [String: Bool]) { #expect(passed, "\(key)") }
    }

    @Test func trappedPocketsPreserveArtWithoutDiscardingRecoverableText() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let value = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=130,h=240,p=new Uint8ClampedArray(w*h*4);
        for(let i=0;i<w*h;i++)p.set([220,220,220,255],i*4);
        const box=(x,y,ww,hh,c=8)=>{for(let yy=y;yy<y+hh;yy++)for(let xx=x;xx<x+ww;xx++)p.set([c,c,c,255],(yy*w+xx)*4);};
        for(let y=30;y<210;y+=30)box(30,y,12,10);
        // Connected frame encloses a tiny ambiguous ink island.
        box(85,0,1,150);box(85,100,16,1);box(101,100,1,50);box(85,149,17,1);
        box(92,110,6,30,175);box(94,120,2,2);
        const b=[24,24,85,190],palette={foreground:[8,8,8],background:[220,220,220]};
        const r=aidokuRestoreSourcePanel(p,w,h,b,palette);
        const fringe=p.slice();
        for(let y=0;y<h;y++){
          fringe.set([8,8,8,255],(y*w+45)*4);
          fringe.set([170,170,170,255],(y*w+44)*4);
        }
        fringe.set([170,170,170,255],(35*w+42)*4);
        const f=aidokuRestoreSourcePanel(fringe,w,h,b,palette,{protectArtMargin:true});
        const fringeCleared=f?.rgba[(35*w+42)*4+3]===255&&f.rgba[(35*w+42)*4]>200;
        const artEdgePreserved=f?.rgba[(35*w+44)*4+3]===0&&f.rgba[(35*w+45)*4+3]===0;
        const supported=p.slice();
        for(let y=60;y<66;y++)for(let x=74;x<79;x++)supported.set([8,8,8,255],(y*w+x)*4);
        for(let x=79;x<85;x++)supported.set([170,170,170,255],(62*w+x)*4);
        const art=aidokuRestoreSourcePanel(supported,w,h,b,palette,{protectArtMargin:true});
        const connectedTipPreserved=art?.rgba[(62*w+75)*4+3]===0&&art.rgba[(62*w+81)*4+3]===0;
        const supportedBodyCleared=art?.rgba[(64*w+35)*4+3]===255;
        const painted=(x,y)=>r?.rgba[(y*w+x)*4+3]===255;
        let artChanged=0;
        for(let y=110;y<140;y++)for(let x=92;x<98;x++)if(painted(x,y))artChanged++;
        box(92,120,6,8); // Too much stranded ink must reject restoration.
        return {accepted:!!r,fringeCleared,artEdgePreserved,connectedTipPreserved,supportedBodyCleared,bodyCleared:painted(34,34),artChanged,retained:r?.preservedCore,
          densePocketRejected:aidokuRestoreSourcePanel(p,w,h,b,palette)===null};
        """, arguments: [:], in: nil, contentWorld: .page)
        let audit = try #require(value as? [String: Any])
        #expect(audit["accepted"] as? Bool == true)
        #expect(audit["bodyCleared"] as? Bool == true)
        #expect(audit["fringeCleared"] as? Bool == true)
        #expect(audit["artEdgePreserved"] as? Bool == true)
        #expect(audit["connectedTipPreserved"] as? Bool == true)
        #expect(audit["supportedBodyCleared"] as? Bool == true)
        #expect(audit["artChanged"] as? Int == 0)
        #expect(audit["retained"] as? Int == 4)
        #expect(audit["densePocketRejected"] as? Bool == true)
    }

    @Test func rubyContinuationRequiresClearRingAndBoundedSameColumn() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let value = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=160,h=260,p=new Uint8ClampedArray(w*h*4);
        for(let i=0;i<w*h;i++)p.set([200,200,200,255],i*4);
        const box=(x,y,ww,hh)=>{for(let yy=y;yy<y+hh;yy++)for(let xx=x;xx<x+ww;xx++)p.set([8,8,8,255],(yy*w+xx)*4);};
        for(let y=45;y<200;y+=40)box(50,y,16,8);
        for(let y=45;y<=95;y+=25)box(84,y,5,7);
        box(85,123,2,9);box(85,130,8,2);box(85,185,5,7);
        const b=[40,30,40,190],palette={foreground:[8,8,8],background:[200,200,200]},auxiliary=[[78,35,18,70]];
        const enabled=aidokuRestoreSourcePanel(p,w,h,b,palette,{auxiliary,vertical:true});
        const disabled=aidokuRestoreSourcePanel(p,w,h,b,palette,{auxiliary});
        const split=p.slice();
        for(let y=120;y<140;y++)for(let x=78;x<96;x++)split.set([200,200,200,255],(y*w+x)*4);
        for(const [x,y] of [[81,125],[82,125],[81,126],[82,126],[90,125],[91,125]])
          split.set([8,8,8,255],(y*w+x)*4);
        const partial=aidokuRestoreSourcePanel(split,w,h,b,palette,{auxiliary,vertical:true});
        box(94,0,1,h); // A drawing rule intersects the required clear outer ring.
        const adjacent=aidokuRestoreSourcePanel(p,w,h,b,palette,{auxiliary,vertical:true});
        const painted=(r,x,y)=>r?.rgba[(y*w+x)*4+3]===255;
        return {accepted:!!enabled,partialRubyCleared:painted(partial,90,125),cleared:painted(enabled,85,126),noOrientationPreserved:!painted(disabled,85,126),
          distantPreserved:!painted(enabled,86,187),nearRulePreserved:!painted(adjacent,85,126),rulePreserved:!painted(adjacent,94,128)};
        """, arguments: [:], in: nil, contentWorld: .page)
        for (key, passed) in try #require(value as? [String: Bool]) { #expect(passed, "\(key)") }
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("spatial-panel-replay.json").path)))
    func realPanelReplay() async throws {
        struct Fixture: Decodable { let image: String; let regions: String; let name: String; let target: String; let freshOCR: Bool?; let sourceColorSequence: Bool?; let requiredRestoredIDs: [String]?; let requiredSurfaceFitIDs: [String]? }
        let fixtures = try JSONDecoder().decode([Fixture].self, from: Data(contentsOf: Self.directory.appendingPathComponent("spatial-panel-replay.json")))
        let output = Self.directory.appendingPathComponent("spatial-panel-results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let host = UIWindow(windowScene: scene)
        host.rootViewController = UIViewController()
        host.makeKeyAndVisible()
        defer { host.isHidden = true }
        for fixture in fixtures {
            let data = try Data(contentsOf: Self.directory.appendingPathComponent(fixture.image))
            let source = try #require(UIImage(data: data))
            let backgroundData = fixture.sourceColorSequence == true
                ? try #require(ReaderTranslationBackgroundImage.prepare(source).pngData()) : data
            var regions = try JSONDecoder().decode([ReaderTranslationStoredRegion].self, from: Data(contentsOf: Self.directory.appendingPathComponent(fixture.regions))).map(\.region)
            if fixture.freshOCR == true, #available(iOS 18.0, *) {
                let reference = regions
                var native = try await ReaderOCRService.shared.recognize(image: #require(source.cgImage), configuration: ReaderOCRConfiguration())
                var pairs: [(score: CGFloat, native: Int, reference: Int)] = []
                for (i, region) in native.enumerated() {
                    for (j, sample) in reference.enumerated() {
                        let common = region.rect.intersection(sample.rect)
                        guard !common.isNull else { continue }
                        let area = common.width * common.height
                        let score = area / (region.rect.width * region.rect.height + sample.rect.width * sample.rect.height - area)
                        if score >= 0.35 { pairs.append((score, i, j)) }
                    }
                }
                var usedNative: Set<Int> = [], usedReference: Set<Int> = []
                for pair in pairs.sorted(by: { $0.score > $1.score }) {
                    guard !usedNative.contains(pair.native), !usedReference.contains(pair.reference) else { continue }
                    native[pair.native].translation = reference[pair.reference].translation
                    usedNative.insert(pair.native); usedReference.insert(pair.reference)
                }
                // Unmatched OCR is retained as source preview, never silently
                // counted as successful translated-ink removal.
                regions = native
                #expect(!usedNative.isEmpty)
                try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init)).write(to: output.appendingPathComponent("\(fixture.name)-native-regions.json"))
            }
            if fixture.name.hasPrefix("panel-exact"), #available(iOS 18.0, *) {
                let translations = Dictionary(uniqueKeysWithValues: regions.map { ($0.source, $0.translation) })
                let native = try await ReaderOCRService.shared.recognize(image: #require(source.cgImage),
                    configuration: ReaderOCRConfiguration())
                regions = native.compactMap { value in
                    guard let translation = translations[value.source] else { return nil }
                    var result = value; result.translation = translation; return result
                }
                #expect(regions.count == 4)
                if fixture.name == "panel-exact-2" { #expect(regions.contains { !$0.auxiliaryInkRects.isEmpty }) }
                try JSONEncoder().encode(regions.map(ReaderTranslationStoredRegion.init)).write(to: output.appendingPathComponent("\(fixture.name)-native-regions.json"))
            }
            let size = CGSize(width: 430, height: 430 * source.size.height / source.size.width)
            let web = WKWebView(frame: CGRect(origin: .zero, size: size))
            web.scrollView.contentInsetAdjustmentBehavior = .never
            host.rootViewController?.view.addSubview(web)
            defer { web.removeFromSuperview() }
            web.loadHTMLString("""
            <meta name="viewport" content="width=device-width,initial-scale=1"><style>body{margin:0}img{display:block;width:100%}</style>
            <img id="reader-source-image" src="data:image/png;base64,\(backgroundData.base64EncodedString())">
            """, baseURL: nil)
            for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
            _ = try await web.callAsyncJavaScript("await document.getElementById('reader-source-image').decode()", arguments: [:], in: nil, contentWorld: .page)
            func snapshot() async throws -> UIImage {
                _ = try await web.callAsyncJavaScript("await new Promise(r=>requestAnimationFrame(()=>requestAnimationFrame(r)))", arguments: [:], in: nil, contentWorld: .page)
                return try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: nil) { image, error in
                        if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: error ?? URLError(.cannotDecodeContentData)) }
                    }
                }
            }
            var settings = ReaderTranslationSettings.defaultOverlay
            settings.opacity = 1
            settings.preserveSourceTextColor = true
            settings.preserveSourceBackgroundColor = true
            var beforeLayout: [[String: Any]]?
            for mode in (fixture.sourceColorSequence == true ? ["before", "after", "translated", "off"] : fixture.freshOCR == true ? ["before", "after"] : ["before", "body-only", "after", "off"]) {
                settings.preserveSourceBackgroundColor = mode != "off"
                let renderer = BrowserPageImageOverlayRenderer { web, script, arguments in
                    var script = mode == "before" ? script.replacingOccurrences(of: "!appearance?.preserveSourceBackgroundColor || !item.sourcePanelRestorationEligible", with: "true || !item.sourcePanelRestorationEligible") : script
                    if mode == "before", fixture.sourceColorSequence == true {
                        let baseline = try String(contentsOf: Self.directory.appendingPathComponent("source-surface-baseline.js"), encoding: .utf8)
                        script = script.replacingOccurrences(of: BrowserSourceTextColor.script, with: baseline)
                    }
                    let isolated = mode == "body-only" ? script
                        .replacingOccurrences(of: "const auxiliary=(options.auxiliary||[])", with: "const auxiliary=[]")
                        .replacingOccurrences(of: "if(options.leadingRule&&", with: "if(false&&")
                        .replacingOccurrences(of: "options.auxiliary?.length", with: "false")
                        .replacingOccurrences(of: "spatial-panel-v9", with: "spatial-panel-body-only") : script
                    if mode == "after", fixture.name == "comic-0474" {
                        try isolated.write(to: output.appendingPathComponent("caption-render.js"), atomically: true, encoding: .utf8)
                        try JSONSerialization.data(withJSONObject: arguments).write(to: output.appendingPathComponent("caption-arguments.json"))
                    }
                    return try await BrowserPageImageOverlayRenderer.evaluateJavaScript(web, isolated, arguments)
                }
                var displayedRegions = regions
                if mode == "translated", fixture.sourceColorSequence == true {
                    for index in [1,2,4,5] where displayedRegions.indices.contains(index) {
                        displayedRegions[index].translation = "번역된 문장 확인"
                    }
                }
                renderer.render(on: web, items: ReaderTranslationRegion.overlayItems(fixture.freshOCR == true ? displayedRegions.filter { $0.translation != nil } : displayedRegions, imageSize: source.size), imageSize: source.size, sourceRect: CGRect(origin: .zero, size: size), settings: settings, targetLanguage: fixture.target)
                for _ in 0..<600 where renderer.lastDiagnostic == nil { try await Task.sleep(for: .milliseconds(20)) }
                #expect(renderer.lastDiagnostic?.outcome == .committed)
                let result = try await web.evaluateJavaScript("""
                (()=>({root:{...document.querySelector('[data-aidoku-image-ocr-overlay="root"]').dataset},
                  items:[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="item"]')].map(n=>({
                    ...n.dataset,text:n.textContent,background:getComputedStyle(n).backgroundColor,opacity:getComputedStyle(n).opacity,
                    x:n.offsetLeft,y:n.offsetTop,width:n.offsetWidth,height:n.offsetHeight})),
                  restored:document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-panel-restoration"]').length}))()
                """)
                var report = try #require(result as? [String: Any])
                if fixture.name.hasPrefix("panel-exact") || fixture.name == "comic-0474" {
                    let probes = fixture.name == "comic-0474" ? [[721,780],[722,789],[721,845],[720,855]] : fixture.name == "panel-exact-2" ? [[357,538],[358,555],[367,554],[365,563],[358,583]] : [[1074,288]]
                    let coverage = try await web.callAsyncJavaScript("""
                    const im=document.getElementById('reader-source-image'), frame=im.getBoundingClientRect();
                    return probes.map(([x,y])=>[...document.querySelectorAll('[data-aidoku-image-ocr-overlay="source-panel-restoration"]')].some(c=>{
                      const r=c.getBoundingClientRect(),cx=(frame.left+x/im.naturalWidth*frame.width-r.left)*c.width/r.width,
                        cy=(frame.top+y/im.naturalHeight*frame.height-r.top)*c.height/r.height;
                      if(cx<0||cy<0||cx>=c.width||cy>=c.height)return false;
                      const p=c.getContext('2d').getImageData(Math.round(cx),Math.round(cy),1,1).data;
                      return p[3]===255&&Math.min(p[0],p[1],p[2])>140;
                    }));
                    """, arguments: ["probes": probes], in: nil, contentWorld: .page)
                    report["companionPixelCoverage"] = coverage
                    if mode == "after" { #expect((coverage as? [Bool])?.allSatisfy { $0 } == true) }
                }
                if mode == "after", let required = fixture.requiredRestoredIDs {
                    let root = try #require(report["root"] as? [String: String])
                    let data = try #require(root["panelRestorationAudit"]?.data(using: .utf8))
                    let entries = try #require(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
                    let accepted = Set(entries.filter { $0["accepted"] as? Bool == true }.compactMap { $0["id"] as? String })
                    #expect(Set(required).isSubset(of: accepted), "Previously restored captions must remain restored: \(fixture.name)")
                }
                let rows = try #require(report["items"] as? [[String: Any]])
                if (mode == "after" || mode == "translated"), fixture.sourceColorSequence == true {
                    #expect(rows.count == regions.count)
                    #expect(rows.allSatisfy { $0["opacity"] as? String == "1" })
                    for id in ["1","5"] {
                        let row = try #require(rows.first { $0["aidokuRegion"] as? String == id })
                        #expect(row["sourceBackgroundColor"] as? String == "observed-surface")
                    }
                    let red = try #require(rows.first { $0["aidokuRegion"] as? String == "2" })
                    let rgb = try #require(red["sourceAppliedTextRGB"] as? String).split(separator: ",").compactMap { Int($0) }
                    #expect(rgb.count == 3 && rgb[0] > 180 && rgb[1] < 140 && rgb[2] < 130)
                    if mode == "translated" { #expect(red["text"] as? String == "번역된 문장 확인") }
                    else { #expect(red["text"] as? String == regions[2].source) }
                }
                if mode == "after", let required = fixture.requiredSurfaceFitIDs {
                    let fitted = Set(rows.filter { $0["sourcePanelTextFit"] as? String == "inside" }.compactMap { $0["aidokuRegion"] as? String })
                    #expect(Set(required).isSubset(of: fitted), "Restored text must fit the surviving balloon: \(fixture.name)")
                }
                let keys = ["aidokuRegion", "text", "x", "y", "width", "height"]
                let layout = rows.map { row in row.filter { keys.contains($0.key) } }
                if mode == "before" { beforeLayout = layout }
                if mode == "after", let beforeLayout { #expect(NSArray(array: layout).isEqual(to: beforeLayout)) }
                if mode == "before" || mode == "off" { #expect(report["restored"] as? Int == 0) }
                if mode == "after", fixture.name.hasPrefix("panel-exact") {
                    #expect(report["restored"] as? Int == rows.count)
                }
                try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("\(fixture.name)-\(mode).json"))
                let rendered = try await snapshot().pngData()
                try rendered?.write(to: output.appendingPathComponent("\(fixture.name)-\(mode).png"))
                renderer.cancelPendingRender()
            }
        }
    }
}
