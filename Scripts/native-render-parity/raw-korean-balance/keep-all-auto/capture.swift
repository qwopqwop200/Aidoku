import AppKit
import WebKit
import Foundation
import CoreFoundation
let fixtures = #"[{"text": "그대는 작은 글씨를 더 넓게 읽고 싶었지만 줄바꿈 규칙을 정확하게 이해하지 못한 것이랍니다 그래서 본 영애가 직접 조판을 검증하는 것이와요", "width": 75, "font": 16, "pitch": 20, "pad": 0}, {"text": "그대는 작은 글씨를 더 넓게 읽고 싶었지만 줄바꿈 규칙을 정확하게 이해하지 못한 것이랍니다 그래서 본 영애가 직접 조판을 검증하는 것이와요", "width": 100, "font": 16, "pitch": 20, "pad": 0}, {"text": "그대는 작은 글씨를 더 넓게 읽고 싶었지만 줄바꿈 규칙을 정확하게 이해하지 못한 것이랍니다 그래서 본 영애가 직접 조판을 검증하는 것이와요", "width": 120, "font": 16, "pitch": 20, "pad": 0}, {"text": "갈 때의 모습은 전라 상태인 편이 관찰하기 쉬우니까 말이야.", "width": 75, "font": 16, "pitch": 20, "pad": 0}, {"text": "갈 때의 모습은 전라 상태인 편이 관찰하기 쉬우니까 말이야.", "width": 100, "font": 16, "pitch": 20, "pad": 0}, {"text": "갈 때의 모습은 전라 상태인 편이 관찰하기 쉬우니까 말이야.", "width": 120, "font": 16, "pitch": 20, "pad": 0}, {"text": "   그대는  영식과   함께 원본의 공백을 보존하는 것이랍니다", "width": 75, "font": 16, "pitch": 20, "pad": 0}, {"text": "   그대는  영식과   함께 원본의 공백을 보존하는 것이랍니다", "width": 100, "font": 16, "pitch": 20, "pad": 0}, {"text": "   그대는  영식과   함께 원본의 공백을 보존하는 것이랍니다", "width": 120, "font": 16, "pitch": 20, "pad": 0}, {"text": "가나다 라마 그리고 영식은 함께 조판을 검증하는 것이와요", "width": 75, "font": 16, "pitch": 20, "pad": 0}, {"text": "가나다 라마 그리고 영식은 함께 조판을 검증하는 것이와요", "width": 100, "font": 16, "pitch": 20, "pad": 0}, {"text": "가나다 라마 그리고 영식은 함께 조판을 검증하는 것이와요", "width": 120, "font": 16, "pitch": 20, "pad": 0}, {"text": "끝까지함께읽는아주긴한국어단어 공녀 영식", "width": 75, "font": 16, "pitch": 20, "pad": 0}, {"text": "끝까지함께읽는아주긴한국어단어 공녀 영식", "width": 100, "font": 16, "pitch": 20, "pad": 0}, {"text": "끝까지함께읽는아주긴한국어단어 공녀 영식", "width": 120, "font": 16, "pitch": 20, "pad": 0}, {"text": "부, 부탁드립니다♡ 공녀 영식과 함께", "width": 75, "font": 16, "pitch": 20, "pad": 0}, {"text": "부, 부탁드립니다♡ 공녀 영식과 함께", "width": 100, "font": 16, "pitch": 20, "pad": 0}, {"text": "부, 부탁드립니다♡ 공녀 영식과 함께", "width": 120, "font": 16, "pitch": 20, "pad": 0}, {"font": 7.25, "pitch": 8.65185546875, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡", "id": "real7-16"}, {"font": 8.75, "pitch": 10.44189453125, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡", "id": "real7-16"}, {"font": 11, "pitch": 13.126953125, "width": 36.02, "height": 46.91729323308272, "pad": 3.01, "text": "부, 부탁드립니다♡", "id": "real7-16"}, {"id": "0", "text": "부... 부탁드립니다……", "width": 36.14, "height": 41.05263157894734, "paddingTop": 2, "paddingLeft": 2, "paddingRight": 2, "paddingBottom": 2, "font": 9.25, "pitch": 11.03857421875, "pad": 2}, {"id": "0", "text": "부... 부탁드립니다……", "width": 36.14, "height": 41.05263157894734, "paddingTop": 2, "paddingLeft": 2, "paddingRight": 2, "paddingBottom": 2, "font": 8.75, "pitch": 10.44189453125, "pad": 2}, {"id": "6", "text": "다음은 리제 씨의 처녀막 제거를 진행하겠습니다", "width": 50.88, "height": 47.40601503759399, "paddingTop": 2.561, "paddingLeft": 2.561, "paddingRight": 2.561, "paddingBottom": 2.561, "font": 7.5, "pitch": 8.9501953125, "pad": 2.561}, {"id": "6", "text": "다음은 리제 씨의 처녀막 제거를 진행하겠습니다", "width": 50.88, "height": 47.40601503759399, "paddingTop": 2.561, "paddingLeft": 2.561, "paddingRight": 2.561, "paddingBottom": 2.561, "font": 8.75, "pitch": 10.44189453125, "pad": 2.561}]"#
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false;var output:String?
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let body = #"""
  const fixtures=FIXTURES, output=[];
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
  for(const a of fixtures){
    const text=a.text,d=document.createElement('div');d.lang='ko';
    Object.assign(d.style,{position:'absolute',left:'0',top:'0',boxSizing:'border-box',width:a.width+'px',height:(a.height||600)+'px',padding:a.pad+'px',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:a.font+'px',lineHeight:a.pitch+'px',letterSpacing:(a.font===16?'0':'-.012em'),whiteSpace:'pre-wrap',textWrap:'wrap',wordBreak:'keep-all',overflowWrap:'anywhere',lineBreak:'auto',display:'flex',alignItems:'center',justifyContent:'center',textAlign:'center'});
    d.textContent=text;document.body.append(d);
    const auto=ranges(d,text);d.style.textWrap='balance';const balanced=ranges(d,text);
    const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');ctx.font='700 '+a.font+'px "Apple SD Gothic Neo"';ctx.letterSpacing=(a.font===16?0:-a.font*.012)+'px';
    const widths=[];
    for(let start=0;start<text.length;start++)for(let end=start+1;end<=text.length;end++)
      widths.push([start,end-start,ctx.measureText(text.slice(start,end)).width]);
    const used=v=>Math.trunc(Math.fround(v)*64)/64;
    output.push({input:a,text,width:d.getBoundingClientRect().width-used(a.pad)*2,auto,balanced,widths,font:a.font,tracking:a.font===16?0:-a.font*.012,canvasSpacing:ctx.letterSpacing});d.remove();
  }
  JSON.stringify(output)
  """#.replacingOccurrences(of:"FIXTURES",with:fixtures)
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
  "scope":"25 bounded actual keep-all/pre-wrap/anywhere ordinary auto+balance captures, including actual real7/real1 descriptors; original UTF16 ranges and Canvas substring advances, not pixel equivalence."]
try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
