import Testing
import UIKit
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct ReaderSourceSegmentationTests {
    private nonisolated static var directory: URL { URL.documentsDirectory.appendingPathComponent("SegmentationQuality") }

    @Test func coloredOuterAntialiasRampDoesNotBecomeProtectedArtwork() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let raw = try await web.callAsyncJavaScript(BrowserSourcePanelRestoration.script + """
        const w=180,h=110,bg=[80,160,80],fg=[210,82,172],stroke=[245,245,245];
        const p=new Uint8ClampedArray(w*h*4),labels=new Uint8Array(w*h);
        for(let i=0;i<w*h;i++)p.set([...bg,255],i*4);
        for(let k=0;k<4;k++)for(let y=34;y<70;y++)for(let x=25+k*34;x<48+k*34;x++){
          if(x>=31+k*34&&y>=40&&y<64)continue;
          for(let dy=-3;dy<=3;dy++)for(let dx=-3;dx<=3;dx++){
            const i=(y+dy)*w+x+dx;
            const outer=Math.max(Math.abs(dx),Math.abs(dy))===3;
            p.set([...(outer?stroke.map((v,c)=>(v+bg[c])/2):stroke),255],i*4);labels[i]=1;
          }
        }
        for(let k=0;k<4;k++)for(let y=34;y<70;y++)for(let x=25+k*34;x<48+k*34;x++){
          if(x>=31+k*34&&y>=40&&y<64)continue;p.set([...fg,255],(y*w+x)*4);
        }
        // Unowned illustration of the same color still has frame connectivity.
        for(let y=0;y<h;y++)p.set([...fg,255],(y*w+171)*4);
        const before=p.slice(),out=aidokuRestoreSourcePanel(p,w,h,[22,30,132,44],
          {foreground:fg,background:bg,stroke,confidence:{foreground:1,background:1,stroke:1}}, {readabilityGate:true});
        let missed=0,changedArt=0,error=0,ink=0;
        for(let i=0;i<w*h;i++){
          if(labels[i]){ink++;if(out?.rgba[i*4+3]!==255)missed++;else for(let c=0;c<3;c++)error+=Math.abs(out.rgba[i*4+c]-bg[c]);}
          if(i%w===171&&out?.rgba[i*4+3])changedArt++;
        }
        return {accepted:!!out,missed,changedArt,mae:error/Math.max(1,ink*3),immutable:p.every((v,i)=>v===before[i])};
        """, arguments: [:], in: nil, contentWorld: .page)
        let result = try #require(raw as? [String: Any])
        #expect(result["accepted"] as? Bool == true)
        #expect(result["missed"] as? Int == 0)
        #expect(result["changedArt"] as? Int == 0)
        #expect(result["immutable"] as? Bool == true)
        #expect((result["mae"] as? Double ?? 999) <= 2)
    }

    @Test(.enabled(if: FileManager.default.fileExists(atPath: directory.appendingPathComponent("fixtures.json").path)))
    func actualCanvasReplaysKnownBackgroundsAndCorpus() async throws {
        let files = try JSONDecoder().decode([String].self, from: Data(contentsOf: Self.directory.appendingPathComponent("fixtures.json")))
        let previousColors = try String(contentsOf: Self.directory.appendingPathComponent("baseline-color.js"), encoding: .utf8)
        let previousRestoration = try String(contentsOf: Self.directory.appendingPathComponent("baseline-restoration.js"), encoding: .utf8)
        let output = Self.directory.appendingPathComponent("results")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading { try await Task.sleep(for: .milliseconds(20)) }
        let factory = """
        return {sample:aidokuSourceColorSampler,display:aidokuSourceDisplayInk,restore:aidokuRestoreSourcePanel};
        """
        _ = try await web.evaluateJavaScript("globalThis.beforeSegmentation=(()=>{\(previousColors)\n\(previousRestoration)\n\(factory)})();void 0;")
        _ = try await web.evaluateJavaScript("globalThis.afterSegmentation=(()=>{\(BrowserSourceTextColor.script)\n\(BrowserSourcePanelRestoration.script)\n\(factory)})();void 0;")
        var reports: [[String: Any]] = []
        for file in files {
            let json = try String(contentsOf: Self.directory.appendingPathComponent(file), encoding: .utf8)
            let raw = try await web.callAsyncJavaScript("""
            const f=JSON.parse(input),image=new Image();image.src=f.image;await image.decode();
            const canvas=document.createElement('canvas');canvas.width=f.w;canvas.height=f.h;
            const ctx=canvas.getContext('2d',{willReadFrequently:true});ctx.drawImage(image,0,0);
            const pixels=ctx.getImageData(0,0,f.w,f.h).data,before=pixels.slice();
            let clean=null,labels=null;
            for(const key of ['clean','labels'])if(f[key]){
              const img=new Image();img.src=f[key];await img.decode();ctx.clearRect(0,0,f.w,f.h);ctx.drawImage(img,0,0);
              const values=ctx.getImageData(0,0,f.w,f.h).data;if(key==='clean')clean=values;else labels=values;
            }
            const report={id:f.id,category:f.category,oracle:!!clean},outputs=[];
            for(const [name,api] of [['before',beforeSegmentation],['after',afterSegmentation]]){
              const budget={pixels:393216,detailPixels:98304};
              const sampler=api.sample(image,true,'ocr',budget),palette=sampler.sample(f.b.map((v,i)=>v/(i%2?f.h:f.w)));
              const start=performance.now(),restored=api.restore(pixels,f.w,f.h,f.b,palette,
                {readabilityGate:true,vertical:f.vertical||false,sampleScale:f.scale||1,auxiliary:f.auxiliary||[]});
              const ms=performance.now()-start,color=api.display(palette);outputs.push(restored);
              const row={accepted:!!restored,color,pixels:sampler.stats.pixels,ms,method:restored?.method||null};
              if(clean){let ink=0,erased=0,error=0;
                for(let i=0;i<f.w*f.h;i++)if(labels[i*4]>=32&&Math.max(...[0,1,2].map(c=>Math.abs(pixels[i*4+c]-clean[i*4+c])))>=12){
                  ink++;const painted=restored?.rgba[i*4+3]===255;erased+=painted;
                  for(let c=0;c<3;c++)error+=Math.abs((painted?restored.rgba:pixels)[i*4+c]-clean[i*4+c]);
                }
                row.recall=erased/ink;row.mae=error/(ink*3);
                row.colorError=color?Math.max(...color.map((v,c)=>Math.abs(v-f.foreground[c]))):255;
              }
              report[name]=row;
            }
            report.immutable=pixels.every((v,i)=>v===before[i]);
            if(f.capture){
              const sheet=document.createElement('canvas');sheet.width=f.w*3;sheet.height=f.h+48;const context=sheet.getContext('2d');
              context.fillStyle='#dedede';context.fillRect(0,0,sheet.width,sheet.height);context.font='14px sans-serif';
              for(let k=0;k<3;k++){
                const composite=pixels.slice(),out=outputs[k-1];
                if(out)for(let i=0;i<f.w*f.h;i++)if(out.rgba[i*4+3])for(let c=0;c<3;c++)composite[i*4+c]=out.rgba[i*4+c];
                context.putImageData(new ImageData(composite,f.w,f.h),k*f.w,24);
                context.fillStyle='#111';context.fillText(['Original','Before','After'][k],k*f.w+4,17);
                if(k){const color=report[k===1?'before':'after'].color;context.fillStyle=color?'rgb('+color.join(',')+')':'#000';context.fillText('Color sample',k*f.w+4,sheet.height-5);}
              }
              report.snapshot=sheet.toDataURL('image/png').split(',')[1];
            }
            return report;
            """, arguments: ["input": json], in: nil, contentWorld: .page)
            var report = try #require(raw as? [String: Any])
            #expect(report["immutable"] as? Bool == true)
            let after = try #require(report["after"] as? [String: Any])
            #expect((after["pixels"] as? Int ?? Int.max) <= 393_216)
            if let png = report.removeValue(forKey: "snapshot") as? String, let data = Data(base64Encoded: png) {
                try data.write(to: output.appendingPathComponent(file.replacingOccurrences(of: ".json", with: ".png")))
            }
            reports.append(report)
        }
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("audit.json"))
        #expect(reports.count == files.count && !reports.isEmpty)
    }
}
