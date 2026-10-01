import AppKit
import WebKit
import Foundation
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let script = #"""
  JSON.stringify(['raw','spans','wrapper'].flatMap(mode=>['가','드디어 \n선생\n님이 \n왔다','안녕하세요, \n반갑습니다!','  가\t 나  \n다\u00a0라 '].flatMap(text=>[5.484375,23.1328125,51.5,85].flatMap(width=>['left','center','right'].map(align=>({mode,text,width,align}))))).map(a=>{
    const d=document.createElement('div');Object.assign(d.style,{position:'absolute',left:'0px',top:'0px',boxSizing:'border-box',width:a.width+'px',height:'150px',padding:'0px',display:a.mode==='spans'?'block':'flex',alignItems:'center',justifyContent:a.align==='left'?'flex-start':a.align==='right'?'flex-end':'center',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:'8.75px',lineHeight:'10.5px',letterSpacing:'-.012em',whiteSpace:'pre-wrap',overflowWrap:'anywhere',wordBreak:'keep-all',textAlign:a.align});
    let parent=d;if(a.mode==='wrapper'){parent=document.createElement('div');Object.assign(parent.style,{display:'block',width:'100%',flex:'0 0 auto'});d.append(parent)}
    if(a.mode==='raw')d.textContent=a.text;else for(const line of a.text.split('\n')){const s=document.createElement('span');Object.assign(s.style,{display:'block',width:'max-content',maxWidth:'100%',margin:'0 auto',whiteSpace:'nowrap'});s.textContent=line;parent.append(s)}
    document.body.append(d);const r=document.createRange();r.selectNodeContents(d);const whole=r.getBoundingClientRect();const children=[...parent.children].map(s=>{r.selectNodeContents(s);const t=r.getBoundingClientRect(),b=s.getBoundingClientRect();return {text:s.textContent,box:[b.x,b.y,b.width,b.height],textRange:[t.x,t.y,t.width,t.height]}});return {a,whole:[whole.x,whole.y,whole.width,whole.height],children,client:[d.clientWidth,d.clientHeight],scroll:[d.scrollWidth,d.scrollHeight]};
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
