import AppKit
import WebKit
import Foundation
let fixtures = try! String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false;var output:String?
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!) {
  let body = #"""
const fixtures=FIXTURES, output=[];
for(const a of fixtures){
 const d=document.createElement('div');d.lang='ko';
 Object.assign(d.style,{position:'absolute',left:'0',top:'0',width:a.width+'px',padding:'0',margin:'0',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:a.font+'px',lineHeight:a.pitch+'px',letterSpacing:'normal',whiteSpace:a.whiteSpace||'pre-line',wordBreak:'keep-all',overflowWrap:a.overflow,textWrap:a.balances?'balance':'wrap',display:'block',textAlign:'left'});
 d.textContent=a.text;document.body.appendChild(d);const tn=d.firstChild, glyphs=[];
 for(let start=0;start<a.text.length;){
  const scalar=String.fromCodePoint(a.text.codePointAt(start)),end=start+scalar.length,r=document.createRange();r.setStart(tn,start);r.setEnd(tn,end);
  const rects=[...r.getClientRects()].map(q=>({x:q.x,y:q.y,width:q.width,height:q.height}));
  glyphs.push({start,length:scalar.length,scalar,rects});start=end;
 }
 output.push({input:a,height:d.getBoundingClientRect().height,scrollWidth:d.scrollWidth,clientWidth:d.clientWidth,glyphs,computed:{whiteSpace:getComputedStyle(d).whiteSpace,wordBreak:getComputedStyle(d).wordBreak,overflowWrap:getComputedStyle(d).overflowWrap}});d.remove();
}
JSON.stringify(output)
"""#.replacingOccurrences(of:"FIXTURES",with:fixtures)
  view.evaluateJavaScript(body){value,error in guard let json=value as? String else {fatalError(String(describing:error))};self.output=json;self.complete=true}
 }
}
let app=NSApplication.shared
let configuration=WKWebViewConfiguration();configuration.websiteDataStore = .nonPersistent()
let view=WKWebView(frame:NSRect(x:0,y:0,width:500,height:600),configuration:configuration)
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate();view.navigationDelegate=delegate
view.loadHTMLString("<html><head><meta charset='utf-8'></head><body style='margin:0'></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(50)
while !delegate.complete && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
precondition(delegate.complete,"WebKit capture timed out")
try Data(delegate.output!.utf8).write(to:URL(fileURLWithPath:CommandLine.arguments[2]))
