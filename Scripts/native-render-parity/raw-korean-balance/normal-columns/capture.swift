import AppKit
import WebKit
import Foundation
import CoreFoundation
let fixtures = #"[{"id": "real1-2", "text": "이제부터 나, 처녀를 잃게 되는 거야…", "width": 30.359375, "height": 50, "pad": 2, "font": 7.02906976744186, "pitch": 9.375}, {"id": "real1-7", "text": "모... 모두가 보고 있는 앞에서 하는 건 싫은데……", "width": 30.5625, "height": 67, "pad": 2, "font": 8.162790697674419, "pitch": 9.741143}, {"id": "control-0", "text": "드디어 선생님이 왔다", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-0", "text": "드디어 선생님이 왔다", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-1", "text": "이것을 이렇게 나눠도 괜찮겠지요", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-1", "text": "이것을 이렇게 나눠도 괜찮겠지요", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-2", "text": "부, 부탁드립니다♡", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-2", "text": "부, 부탁드립니다♡", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-3", "text": "안녕, 세계! (그대는)「공녀」랍니다…", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-3", "text": "안녕, 세계! (그대는)「공녀」랍니다…", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-4", "text": "공녀  영식\t함께", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-4", "text": "공녀  영식\t함께", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-5", "text": "우리의 longword-unbroken punctuation: test", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-5", "text": "우리의 longword-unbroken punctuation: test", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-6", "text": "한글과English혼합 그리고日本語", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-6", "text": "한글과English혼합 그리고日本語", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-7", "text": "끝까지함께읽는아주긴한국어단어", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-7", "text": "끝까지함께읽는아주긴한국어단어", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-8", "text": "그대 공녀 그리고 영식", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-8", "text": "그대 공녀 그리고 영식", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-9", "text": "가​나다　라마", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-9", "text": "가​나다　라마", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-10", "text": "가⁠나다 나 다", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-10", "text": "가⁠나다 나 다", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-11", "text": "공녀 👩‍👧와 영식 🇰🇷", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-11", "text": "공녀 👩‍👧와 영식 🇰🇷", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-12", "text": "각나 과연 조판일까요", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-12", "text": "각나 과연 조판일까요", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-13", "text": "A/B—C-D 안녕･세계", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "control-13", "text": "A/B—C-D 안녕･세계", "width": 100, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "leading-collapsed", "text": "   공녀  영식과   함께", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "unsupported-lf", "text": "공녀\n영식", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "unsupported-bidi", "text": "공녀 שלום 영식", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}, {"id": "unsupported-bidi-control", "text": "공녀 ⁧영식⁩", "width": 65, "height": 600, "pad": 0, "font": 16, "pitch": 20}]"#
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
      const boxes=[...r.getClientRects()],box=boxes.find(b=>b.width>0&&b.height>0);
      const last=lines.at(-1);
      // A collapsed normal-whitespace range may have no painted rectangle.
      // Never invent a y=0 row from its empty getBoundingClientRect. Allocate
      // these source positions to the preceding visible row (or first row).
      if (!box) { if(last)last.end=end;offset=end;continue; }
      if(!last||Math.abs(last.y-box.y)>.5)lines.push({start:last?offset:0,end,y:box.y});else last.end=end;
      offset=end;
    }
    return lines.map(r=>[r.start,r.end-r.start]);
  }
  for(const a of fixtures){
    const text=a.text,d=document.createElement('div');d.lang='ko';
    Object.assign(d.style,{position:'absolute',left:'0',top:'0',boxSizing:'border-box',width:a.width+'px',height:(a.height||600)+'px',padding:a.pad+'px',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:a.font+'px',lineHeight:a.pitch+'px',letterSpacing:(a.font===16?'0':'-.012em'),whiteSpace:'normal',textWrap:'wrap',wordBreak:'normal',overflowWrap:'anywhere',lineBreak:'auto',display:'block',alignItems:'center',justifyContent:'center',textAlign:'center'});
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
let input=try JSONSerialization.jsonObject(with:Data(fixtures.utf8)) as! [[String:Any]]
var tokens:[[String:Any]]=[]
for fixture in input {
 let text=fixture["text"] as! String
 let cf=text as CFString
 let locale=CFLocaleCreate(nil,CFLocaleIdentifier("und" as CFString))
 let tokenizer=CFStringTokenizerCreate(nil,cf,CFRange(location:0,length:CFStringGetLength(cf)),kCFStringTokenizerUnitLineBreak,locale)
 var ends:[Int]=[]
 while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
  let range=CFStringTokenizerGetCurrentTokenRange(tokenizer);ends.append(range.location+range.length)
 }
 tokens.append(["text":text,"ends":ends,"locale":"und"])
}
let output:[String:Any]=["WKWebView":web,"CFStringTokenizer":tokens,"OS":ProcessInfo.processInfo.operatingSystemVersionString,
  "scope":"Two actual released-column descriptors plus bounded primary ASCII/CF controls and unsupported input checks with white-space normal/word-break normal/overflow-anywhere; original UTF16 ranges and Canvas substring advances, not pixel equivalence."]
try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
