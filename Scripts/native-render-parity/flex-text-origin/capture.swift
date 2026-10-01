import AppKit
import WebKit
import Foundation
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let script = #"""
  JSON.stringify([42.75,20,8.5].flatMap(font=>[183.1875,100.015625,70,55.234375].flatMap(width=>['달칵!','달칵!\n안녕','안녕 세상 함께 출발하자'].map(text=>({font,width,text})))).map(a=>{
    const d=document.createElement('div');Object.assign(d.style,{position:'absolute',left:'41px',top:'0px',width:a.width+'px',height:'200px',display:'flex',alignItems:'center',justifyContent:'center',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:a.font+'px',lineHeight:a.font*1.2+'px',letterSpacing:'-.012em',whiteSpace:'pre-wrap',overflowWrap:'anywhere',wordBreak:'keep-all',textAlign:'center'});d.textContent=a.text;document.body.append(d);
    const scalarRows=new Map();for(let i=0;i<d.firstChild.length;i++){if(/\s/.test(d.firstChild.textContent[i]))continue;const q=document.createRange();q.setStart(d.firstChild,i);q.setEnd(d.firstChild,i+1);const b=Array.from(q.getClientRects()).filter(r=>r.width>0).at(-1);if(!b)continue;let row=scalarRows.get(b.y)||{x:b.x,y:b.y,right:b.right,start:i,end:i+1};row.end=i+1;scalarRows.set(b.y,row)};const nonspaceRows=Array.from(scalarRows.values()).map(a=>{const q=document.createRange();q.setStart(d.firstChild,a.start);q.setEnd(d.firstChild,a.end);const rr=Array.from(q.getClientRects()).filter(r=>r.width>0&&r.y===a.y);const r=rr.at(-1);return {x:r.x,y:r.y,right:r.right,text:d.textContent.slice(a.start,a.end)}});const range=document.createRange();range.selectNodeContents(d);const rects=Array.from(range.getClientRects()).map(r=>({x:r.x,y:r.y,width:r.width,height:r.height}));const c=document.createElement('canvas').getContext('2d');c.font=`700 ${a.font}px 'Apple SD Gothic Neo'`;c.letterSpacing=getComputedStyle(d).letterSpacing;const maxContent=Math.max(...a.text.split('\n').map(t=>c.measureText(t).width));const childWidth=Math.min(a.width,Math.ceil(Math.fround(maxContent)*64)/64);const outer=Math.trunc((a.width-childWidth)*32)/64;return {a,maxContent,childWidth,rects,nonspaceRows,rowMeasured:nonspaceRows.map(r=>({text:r.text,width:c.measureText(r.text).width,actualX:rects.find(q=>q.y===r.y&&q.width>0)?.x,predictedX:41+outer+Math.max(0,(childWidth-c.measureText(r.text).width)/2)}))};
  }))
  """#
  view.evaluateJavaScript(script){ value,error in
    guard let json=value as? String else {fatalError(String(describing:error))}
    print(json);self.complete=true
  }
 }
}
let view=WKWebView(frame:NSRect(x:0,y:0,width:500,height:700))
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate();view.navigationDelegate=delegate;view.loadHTMLString("<html><style>body{margin:0}</style><body></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(30)
while !delegate.complete && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
precondition(delegate.complete)
