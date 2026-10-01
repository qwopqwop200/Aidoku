import AppKit
import WebKit
import Foundation
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let script = #"""
  JSON.stringify([false,true].map(overflow=>{
   const d=document.createElement('div');Object.assign(d.style,{position:'absolute',left:'10px',top:'20px',width:'100px',height:'100px',fontFamily:'Apple SD Gothic Neo',fontSize:'8.75px',fontWeight:700,lineHeight:'10.5px',letterSpacing:'-.012em',whiteSpace:'normal',wordBreak:'keep-all',textAlign:'center'});
   for(const [x,y,w,h,text] of [[3,4,20,80,'가'],[30,10,overflow?5:20,40,'안녕하세요']]){const c=document.createElement('div');Object.assign(c.style,{position:'absolute',left:x+'px',top:y+'px',width:w+'px',height:h+'px',whiteSpace:'nowrap'});c.textContent=text;d.append(c)}document.body.append(d);const r=document.createRange();r.selectNodeContents(d);const box=r.getBoundingClientRect();return {overflow,whole:[box.x,box.y,box.width,box.height],rects:[...r.getClientRects()].map(b=>[b.x,b.y,b.width,b.height])};
  }))
  """#
  view.evaluateJavaScript(script){value,error in guard let json=value as? String else {fatalError(String(describing:error))};print(json);self.complete=true}
 }
}
let view=WKWebView(frame:NSRect(x:0,y:0,width:500,height:700))
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate();view.navigationDelegate=delegate;view.loadHTMLString("<html><style>body{margin:0}</style><body></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(30)
while !delegate.complete && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
precondition(delegate.complete)
