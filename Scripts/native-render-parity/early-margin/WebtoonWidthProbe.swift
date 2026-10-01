import AppKit
import WebKit
import CoreText
import Foundation
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
 let script = #"""
 JSON.stringify([7.5,11.25].flatMap(size=>['안녕하세요, 세계 여러분!','안녕하세요, ','안녕하세요,','안녕',' ', ',', '!'].map(text=>{
 const c=document.createElement('canvas').getContext('2d');c.font=`700 ${size}px "Apple SD Gothic Neo", "Noto Sans CJK KR", "Noto Sans KR", -apple-system, BlinkMacSystemFont, sans-serif`;
 const d=document.createElement('div');Object.assign(d.style,{font:c.font,width:'max-content',whiteSpace:'pre',letterSpacing:'-.012em'});d.textContent=text;document.body.append(d);const range=document.createRange();range.selectNodeContents(d);return {size,text,font:c.font,width:c.measureText(text).width,range:range.getBoundingClientRect().width};
 })))
 """#
 view.evaluateJavaScript(script){value,error in
 guard let json=value as? String else {fatalError(String(describing:error))};print("WEB",json);self.complete=true
 }
 }
}
let view=WKWebView(frame:NSRect(x:0,y:0,width:500,height:700));let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate();view.navigationDelegate=delegate;view.loadHTMLString("<html><body></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(30)
while !delegate.complete && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))};precondition(delegate.complete)
var rows:[[String:Any]]=[]
for size in [7.5,11.25] {
 let f=CTFontCreateWithName("AppleSDGothicNeo-Bold" as CFString,size,nil)
 for text in ["안녕하세요, 세계 여러분!","안녕하세요, ","안녕하세요,","안녕"," ",",","!"] {
 let line=CTLineCreateWithAttributedString(NSAttributedString(string:text,attributes:[NSAttributedString.Key(kCTFontAttributeName as String):f]));let runs=CTLineGetGlyphRuns(line) as! [CTRun]
 rows.append(["text":text,"size":size,"width":CTLineGetTypographicBounds(line,nil,nil,nil),"runs":runs.map {run in let font=(CTRunGetAttributes(run) as NSDictionary)[kCTFontAttributeName] as! CTFont;return ["font":CTFontCopyPostScriptName(font) as String,"width":CTRunGetTypographicBounds(run,CFRange(location:0,length:0),nil,nil,nil)] as [String:Any]}])
 }
}
print("CT",String(data:try JSONSerialization.data(withJSONObject:rows,options:[.sortedKeys]),encoding:.utf8)!)
