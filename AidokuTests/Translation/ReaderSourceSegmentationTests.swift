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

}
