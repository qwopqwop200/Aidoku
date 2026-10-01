import AppKit
import WebKit
import Foundation
let input = try String(contentsOfFile: CommandLine.arguments[1],encoding:.utf8)
let helper = try String(contentsOfFile: CommandLine.arguments[2],encoding:.utf8)
let output = URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true)
final class Capture: NSObject, WKNavigationDelegate {
 var finished=false
 var error:Error?
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!) {
  let js=helper+"\nconst inputs="+input+";\n" + #"""
  const records=[];
  for(let i=0;i<inputs.length;i++){
    const f=inputs[i],b=f.raw,p=document.createElement('div'),n=document.createElement('canvas');
    Object.assign(p.style,{position:'absolute',left:'200px',top:(i*160+10)+'px',width:'400px',height:'150px'});
    n.width=20;n.height=20;n.getContext('2d').fillStyle='rgb('+(180+i*3)+',30,50)';n.getContext('2d').fillRect(0,0,20,20);
    const clip=aidokuCleanupClip(f.clip?{clip:f.clip}:null,...b);
    Object.assign(n.style,{position:'absolute',left:b[0]+'px',top:b[1]+'px',width:b[2]+'px',height:b[3]+'px',clipPath:clip});
    p.appendChild(n);document.body.appendChild(p);
    const r=n.getBoundingClientRect(),pr=p.getBoundingClientRect(),s=getComputedStyle(n);
    records.push({id:f.id,raw:b,clip:f.clip,requested:clip,computed:s.clipPath,
      used:[r.x-pr.x,r.y-pr.y,r.width,r.height],parent:[pr.x,pr.y],color:[180+i*3,30,50],deviceScale:devicePixelRatio,inline:n.style.clipPath,mask:{frame:[r.x-pr.x,r.y-pr.y,r.width,r.height],opacity:Number(s.opacity),png:n.toDataURL('image/png')}});
  }
  records
  """#
  view.evaluateJavaScript(js){result,error in
   if let error {self.error=error;self.finished=true;return}
   do {try JSONSerialization.data(withJSONObject:result!,options:[.prettyPrinted,.sortedKeys]).write(to:output.appendingPathComponent("web.json"))}
   catch {self.error=error;self.finished=true;return}
   let config=WKPDFConfiguration();config.rect=CGRect(x:0,y:0,width:640,height:2200)
   view.createPDF(configuration:config){result in
    do {try result.get().write(to:output.appendingPathComponent("web.pdf"))}
    catch {self.error=error}
    self.finished=true
   }
  }
 }
}
let app=NSApplication.shared,view=WKWebView(frame:CGRect(x:0,y:0,width:640,height:2200))
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let capture=Capture();view.navigationDelegate=capture
view.loadHTMLString("<html><head><meta charset='utf-8'></head><body style='margin:0;background:white'></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(45)
while !capture.finished && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
precondition(capture.finished)
if let error=capture.error {throw error}
