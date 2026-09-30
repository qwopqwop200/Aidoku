import Foundation
import Testing
import WebKit
@testable import Aidoku

@Suite(.serialized) @MainActor
struct ReaderHarmonicKernelParityTests {
    @Test func embeddedWASMMatchesJavaScriptFallbackInWebKit() async throws {
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 64, height: 64))
        webView.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        let deadline = Date().addingTimeInterval(10)
        while webView.isLoading && Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!webView.isLoading, "WebKit must finish loading before parity checks")
        let scripts = try JSONSerialization.data(withJSONObject: [
            BrowserSourceTextColor.script, BrowserSourcePanelRestoration.script
        ])
        let encoded = try #require(String(data: scripts, encoding: .utf8))
        let result = try await webView.evaluateJavaScript("""
        (() => {
          const scripts=\(encoded);
          const native=new Function(scripts[0]+scripts[1]+';return {fill:aidokuHarmonicFill,available:!!aidokuPixelKernels(1024)};')();
          if(!native.available)throw Error('WASM must be active');
          const fallback=new Function(scripts[1]+';return aidokuHarmonicFill;')();
          let seed=173,cases=0;
          const random=()=>{seed^=seed<<13;seed^=seed>>>17;seed^=seed<<5;return seed>>>0;};
          for(let sample=0;sample<64;sample++){
            const w=8+random()%33,h=8+random()%33,n=w*h;
            const pixels=new Uint8ClampedArray(n*4),blocked=new Uint8Array(n),paint=new Uint8Array(n),indices=[];
            for(let i=0;i<n;i++){
              pixels.set([random()%256,random()%256,random()%256,255],i*4);
              blocked[i]=sample%4===0||random()%5===0?1:0;
            }
            for(let y=1;y<h-1;y++)for(let x=1;x<w-1;x++)
              if(sample%4===1||random()%3!==0){indices.push(y*w+x);paint[y*w+x]=1;}
            if(sample%2)for(let i=indices.length-1;i>0;i--){const j=random()%(i+1);[indices[i],indices[j]]=[indices[j],indices[i]];}
            const queue=Int32Array.from(indices);
            for(const accelerated of [false,true]){
              const expected=pixels.slice(),actual=pixels.slice();
              fallback(expected,w,n,queue,queue.length,blocked,paint,accelerated);
              native.fill(actual,w,n,queue,queue.length,blocked,paint,accelerated);
              for(let k=0;k<actual.length;k++)if(actual[k]!==expected[k])
                throw Error('RGBA mismatch sample='+sample+' byte='+k+' accelerated='+accelerated);
              cases++;
            }
          }
          return cases;
        })()
        """)
        #expect((result as? NSNumber)?.intValue == 128)
    }
}
