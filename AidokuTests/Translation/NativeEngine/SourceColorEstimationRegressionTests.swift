import Testing
import WebKit
@testable import Aidoku

@Suite(.serialized)
@MainActor
struct SourceColorEstimationRegressionTests {
    @Test func sourceColorSamplingPrefersOCRRegionEvidenceOverNearbyArtwork() async throws {
        let web = WKWebView()
        web.loadHTMLString("<html></html>", baseURL: nil)
        for _ in 0..<200 where web.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }

        let raw = try await web.callAsyncJavaScript(BrowserSourceTextColor.script + """
        const make=(w,h,color)=>{
          const pixels=new Uint8ClampedArray(w*h*4);
          for(let i=0;i<w*h;i++)pixels.set([...color,255],i*4);
          return pixels;
        };
        const fill=(pixels,w,x0,y0,x1,y1,color)=>{
          for(let y=y0;y<y1;y++)for(let x=x0;x<x1;x++)
            pixels.set([...color,255],(y*w+x)*4);
        };
        const estimate=(pixels,w,h,inner)=>{
          const seed=aidokuSourceSurfaceSeed(pixels,w,h,inner);
          let result=aidokuEstimateSourceColors(
            pixels,w,h,seed?.key??null,seed?.color??null,inner,Boolean(seed)
          );
          if(result&&seed&&Array.isArray(result.background)){
            const delta=Math.max(...result.background.map((value,channel)=>
              Math.abs(value-seed.color[channel])));
            if(delta<=24){
              result.background=seed.color;
              result.confidence.background=Math.max(
                result.confidence?.background||0,seed.confidence
              );
            }
          }
          return aidokuRecoverSourcePanel(pixels,w,h,inner,result);
        };

        const artCase=(()=>{
          const w=112,h=80,background=[244,240,232],foreground=[72,68,64],art=[8,8,8];
          const pixels=make(w,h,background),inner=[45,18,28,44];
          for(const x of [49,56,63]){
            fill(pixels,w,x,24,x+3,57,foreground);
            fill(pixels,w,x-1,24,x+4,27,foreground);
          }
          for(const x of [12,19]){
            fill(pixels,w,x,22,x+3,54,art);
            fill(pixels,w,x-1,22,x+4,25,art);
          }
          return estimate(pixels,w,h,inner);
        })();

        const rimCase=(()=>{
          const w=96,h=96,outer=[112,52,48],background=[184,202,218],foreground=[18,20,24];
          const pixels=make(w,h,outer),inner=[38,20,20,56];
          fill(pixels,w,3,3,93,93,background);
          for(const x of [41,47,53]){
            fill(pixels,w,x,26,x+3,66,foreground);
            fill(pixels,w,x-1,26,x+4,29,foreground);
          }
          return estimate(pixels,w,h,inner);
        })();

        const captionCase=(()=>{
          const w=96,h=64,outer=[235,235,235],background=[55,90,145],foreground=[250,250,250];
          const pixels=make(w,h,outer),inner=[33,17,30,30];
          fill(pixels,w,30,14,66,50,background);
          for(const x of [38,46,54]){
            fill(pixels,w,x,21,x+3,44,foreground);
            fill(pixels,w,x-1,21,x+5,24,foreground);
          }
          return estimate(pixels,w,h,inner);
        })();

        return {artCase,rimCase,captionCase};
        """, arguments: [:], in: nil, contentWorld: .page)

        let result = try #require(raw as? [String: Any])
        func rgb(_ object: Any?, _ key: String) throws -> [Int] {
            let row = try #require(object as? [String: Any])
            return try #require(row[key] as? [Int])
        }

        #expect(try rgb(result["artCase"], "foreground") == [72, 68, 64])
        #expect(try rgb(result["rimCase"], "foreground") == [18, 20, 24])
        #expect(try rgb(result["rimCase"], "background") == [184, 202, 218])
        #expect(try rgb(result["captionCase"], "foreground") == [250, 250, 250])
        #expect(try rgb(result["captionCase"], "background") == [55, 90, 145])
    }
}
