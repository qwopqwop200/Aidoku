import AppKit
import WebKit
import Foundation
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let script = #"""
  JSON.stringify([0,3,6].flatMap(pad=>[40,60,78,80,83.1,83.49,83.51,83.98,84,84.02,84.3,84.34,84.36,84.49,84.51,84.8,85,85.5].flatMap(width=>[false,true].map(hidden=>({pad,width:width+pad*2,hidden})))).map(a=>{
    const d=document.createElement('div');Object.assign(d.style,{position:'absolute',left:'0px',top:'0px',boxSizing:'border-box',width:a.width+'px',height:'100px',padding:a.pad+'px',display:'block',overflow:a.hidden?'hidden':'visible',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:'42.75px',lineHeight:'51.01611328125px',letterSpacing:'-.012em',whiteSpace:'pre-wrap',overflowWrap:'anywhere',wordBreak:'keep-all',textAlign:'center'});
    const span=document.createElement('span');Object.assign(span.style,{display:'block',width:'max-content',maxWidth:'100%',margin:'0 auto',whiteSpace:'nowrap'});span.textContent='달칵!';d.append(span);document.body.append(d);const range=document.createRange();range.selectNodeContents(span);const text=range.getBoundingClientRect();return {a,client:d.clientWidth,scroll:d.scrollWidth,boxWidth:d.getBoundingClientRect().width,spanWidth:span.getBoundingClientRect().width,spanX:span.getBoundingClientRect().x,text:[text.x,text.width],fit:d.scrollWidth<=d.clientWidth+.5};
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
