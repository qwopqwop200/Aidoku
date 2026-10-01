import AppKit
import WebKit
import Foundation

let sizes = [7.02906976744186, 8.162790697674419, 6.125000111, 11.333333333333333,
             13.11111111111111, 20.00000149, 31.9999996, 64.123456789]
let strings = ["이제부터 나, 처녀를 잃게 되는 거야…", "ABCxyz012345.,;/— "]
let inputs = sizes.flatMap { size in strings.map { ["font":size,"text":$0] as [String:Any] } }
let fixtureJSON = String(data:try JSONSerialization.data(withJSONObject:inputs),encoding:.utf8)!
final class Delegate: NSObject, WKNavigationDelegate {
 var finished = false
 var result: Any?
 var pdf: Data?
 func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
  let script = #"""
  const fixtures=FIXTURES,output=[];
  for(let i=0;i<fixtures.length;i++){
    const a=fixtures[i],d=document.createElement('div');d.lang='ko';
    Object.assign(d.style,{position:'absolute',left:'20px',top:(i*85+20)+'px',width:'1500px',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:a.font+'px',lineHeight:'80px',letterSpacing:'0px',fontKerning:'none',whiteSpace:'nowrap'});
    d.textContent=a.text;document.body.appendChild(d);
    const range=document.createRange();range.selectNodeContents(d);const rect=range.getBoundingClientRect();
    const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');
    const variants={original:a.font,float32:Math.fround(a.font),inline:parseFloat(d.style.fontSize),computed:parseFloat(getComputedStyle(d).fontSize)};
    ctx.fontKerning='none';const metrics={};
    for(const [key,font] of Object.entries(variants)){
      ctx.font='700 '+font+'px "Apple SD Gothic Neo"';
      const m=ctx.measureText(a.text);
      metrics[key]={requestedFont:font,font:ctx.font,width:m.width,actualLeft:m.actualBoundingBoxLeft,actualRight:m.actualBoundingBoxRight,actualAscent:m.actualBoundingBoxAscent,actualDescent:m.actualBoundingBoxDescent,fontAscent:m.fontBoundingBoxAscent,fontDescent:m.fontBoundingBoxDescent};
    }
    output.push({input:a,inline:d.style.fontSize,computed:getComputedStyle(d).fontSize,range:{x:rect.x,y:rect.y,width:rect.width,height:rect.height},metrics});
  }
  output
  """#.replacingOccurrences(of:"FIXTURES",with:fixtureJSON)
  view.evaluateJavaScript(script){ value,error in
   guard let value else {fatalError(String(describing:error))}
   self.result=value
   let config=WKPDFConfiguration();config.rect=CGRect(x:0,y:0,width:1600,height:1400)
   view.createPDF(configuration:config){ result in
    self.pdf=try! result.get();self.finished=true
   }
  }
 }
}
let app=NSApplication.shared,view=WKWebView(frame:CGRect(x:0,y:0,width:1600,height:1400))
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate();view.navigationDelegate=delegate
view.loadHTMLString("<html><head><meta charset='utf-8'></head><body style='margin:0'></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(45)
while !delegate.finished && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
precondition(delegate.finished)
let out=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
try JSONSerialization.data(withJSONObject:["cases":delegate.result!,"OS":ProcessInfo.processInfo.operatingSystemVersionString],options:[.prettyPrinted,.sortedKeys]).write(to:out.appendingPathComponent("capture.json"))
try delegate.pdf!.write(to:out.appendingPathComponent("web-controls.pdf"))
