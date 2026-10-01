import AppKit
import WebKit
import Foundation
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let script = #"""
  JSON.stringify([{"font": 7.25, "pitch": 8.65185546875, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 7.5, "pitch": 8.9501953125, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 7.75, "pitch": 9.24853515625, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 8.0, "pitch": 9.546875, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 8.25, "pitch": 9.84521484375, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 8.5, "pitch": 10.1435546875, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 8.75, "pitch": 10.44189453125, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 9.0, "pitch": 10.740234375, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 9.25, "pitch": 11.03857421875, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 9.5, "pitch": 11.3369140625, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 9.75, "pitch": 11.63525390625, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 10.0, "pitch": 11.93359375, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 10.25, "pitch": 12.23193359375, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 10.5, "pitch": 12.5302734375, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 10.75, "pitch": 12.82861328125, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}, {"font": 11.0, "pitch": 13.126953125, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡"}].map(a=>{
  const d=document.createElement('div'); d.lang='ko';Object.assign(d.style,{position:'absolute',left:'0px',top:'0px',width:a.width+'px',height:a.height+'px',boxSizing:'border-box',overflow:'visible',display:'flex',alignItems:'center',justifyContent:'center',padding:a.pad+'px',margin:'0',border:'0',fontFamily:"'Apple SD Gothic Neo','Noto Sans CJK KR','Noto Sans KR',-apple-system,BlinkMacSystemFont,sans-serif",fontWeight:'700',fontSize:a.font+'px',lineHeight:a.pitch+'px',letterSpacing:'-.012em',textAlign:'center',whiteSpace:'pre-wrap',overflowWrap:'anywhere',wordBreak:'keep-all',textWrap:'balance',lineBreak:'auto',direction:'ltr',unicodeBidi:'plaintext',contain:'layout style',webkitTextSizeAdjust:'none'}); d.textContent=a.text;document.body.append(d);
  const chars=[];for(let k=0;k<a.text.length;k++){const r=document.createRange();r.setStart(d.firstChild,k);r.setEnd(d.firstChild,k+1);let q=r.getBoundingClientRect();chars.push({k,ch:a.text[k],rect:[q.x,q.y,q.width,q.height]});}return {a,scroll:[d.scrollWidth,d.scrollHeight],client:[d.clientWidth,d.clientHeight],fit:d.scrollWidth<=d.clientWidth+.5&&d.scrollHeight<=d.clientHeight+.5,chars};}))
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
