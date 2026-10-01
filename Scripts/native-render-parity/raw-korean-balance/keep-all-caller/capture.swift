import AppKit
import WebKit
import Foundation
import CoreFoundation
let texts=["그대는 작은 글씨를 더 넓게 읽고 싶었지만 줄바꿈 규칙을 정확하게 이해하지 못한 것이랍니다 그래서 본 영애가 직접 조판을 검증하는 것이와요", "갈 때의 모습은 전라 상태인 편이 관찰하기 쉬우니까 말이야.", "   그대는  영식과   함께 원본의 공백을 보존하는 것이랍니다", "가나다\u{00A0}라마 그리고 영식은 함께 조판을 검증하는 것이와요", "끝까지함께읽는아주긴한국어단어 공녀 영식", "부, 부탁드립니다♡ 공녀 영식과 함께"]
let fixtureData=try JSONSerialization.data(withJSONObject:texts)
let encoded=String(data:fixtureData,encoding:.utf8)!
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false;var output:String?
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let body = #"""
  const texts=TEXTS, output=[];
  function ranges(d,text){
    const tn=d.firstChild,lines=[];
    for(let offset=0;offset<text.length;){
      const scalar=String.fromCodePoint(text.codePointAt(offset)),end=offset+scalar.length;
      const r=document.createRange();r.setStart(tn,offset);r.setEnd(tn,end);
      const boxes=[...r.getClientRects()],box=boxes.find(b=>b.width>0&&b.height>0)||boxes[0]||r.getBoundingClientRect();
      const last=lines.at(-1);
      if(!last||Math.abs(last.y-box.y)>.5)lines.push({start:offset,end,y:box.y});else last.end=end;
      offset=end;
    }
    return lines.map(r=>[r.start,r.end-r.start]);
  }
  for(const text of texts)for(const width of [75,100,120]){
    const d=document.createElement('div');d.lang='ko';
    Object.assign(d.style,{position:'absolute',left:'0',top:'0',width:width+'px',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:'16px',lineHeight:'20px',letterSpacing:'0',whiteSpace:'pre-wrap',textWrap:'wrap',wordBreak:'keep-all',overflowWrap:'anywhere',lineBreak:'auto'});
    d.textContent=text;document.body.append(d);
    const auto=ranges(d,text);d.style.textWrap='balance';const balanced=ranges(d,text);
    const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');ctx.font='700 16px "Apple SD Gothic Neo"';
    const widths=[];
    for(let start=0;start<text.length;start++)for(let end=start+1;end<=text.length;end++)
      widths.push([start,end-start,ctx.measureText(text.slice(start,end)).width]);
    output.push({text,width:d.getBoundingClientRect().width,auto,balanced,widths});d.remove();
  }
  JSON.stringify(output)
  """#.replacingOccurrences(of:"TEXTS",with:encoded)
  view.evaluateJavaScript(body){value,error in
   guard let json=value as? String else {fatalError(String(describing:error))}
   self.output=json;self.complete=true
  }
 }
}
let app=NSApplication.shared
let view=WKWebView(frame:NSRect(x:0,y:0,width:800,height:600))
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate();view.navigationDelegate=delegate
view.loadHTMLString("<html><head><meta charset='utf-8'></head><body style='margin:0'></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(55)
while !delegate.complete && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
precondition(delegate.complete)
let web=try JSONSerialization.jsonObject(with:Data(delegate.output!.utf8))
let output:[String:Any]=["WKWebView":web,"OS":ProcessInfo.processInfo.operatingSystemVersionString,
  "scope":"18 bounded actual keep-all/pre-wrap/anywhere ordinary auto+balance captures; original UTF16 ranges and Canvas substring advances, not pixel equivalence."]
try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
