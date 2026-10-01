import AppKit
import WebKit
import Foundation
import CoreFoundation
let texts=["드디어 선생님이 왔다", "이것을 이렇게 나눠도 괜찮겠지요", "부, 부탁드립니다♡", "안녕, 세계! (그대는)「공녀」랍니다…",
           "공녀  영식\t함께", "우리의 longword-unbroken punctuation: test", "한글과English혼합 그리고日本語", "끝까지함께읽는아주긴한국어단어", "그대\u{00A0}공녀 그리고 영식", "가\u{200B}나다\u{3000}라마", "가\u{2060}나다 나\u{202F}다", "공녀 👩‍👧와 영식 🇰🇷", "각나 과연 조판일까요", "A/B—C-D 안녕･세계"]
var tokens:[[String:Any]]=[]
for text in texts {
 for localeID in ["ko_KR","ko_KR@lb=normal","ko_KR@lb=strict","ko_KR@lb=loose","ko_KR@lw=phrase","en_US","und"] {
  let source=text as CFString,locale=CFLocaleCreate(nil,CFLocaleIdentifier(localeID as CFString))
  let tokenizer=CFStringTokenizerCreate(nil,source,CFRange(location:0,length:CFStringGetLength(source)),kCFStringTokenizerUnitLineBreak,locale)
  var ranges:[[Int]]=[]
  while CFStringTokenizerAdvanceToNextToken(tokenizer).rawValue != 0 {
   let range=CFStringTokenizerGetCurrentTokenRange(tokenizer)
   ranges.append([range.location,range.length])
  }
  tokens.append(["text":text,"locale":localeID,"ranges":ranges,"ends":ranges.map{$0[0]+$0[1]}])
 }
}
let fixtureData=try JSONSerialization.data(withJSONObject:texts)
let encoded=String(data:fixtureData,encoding:.utf8)!
final class Delegate:NSObject,WKNavigationDelegate {
 var complete=false;var output:String?
 func webView(_ view:WKWebView,didFinish navigation:WKNavigation!){
  let body = #"""
  const texts=TEXTS;
  const output=[];
  for(const text of texts)for(const wordBreak of ['normal','keep-all'])for(const overflowWrap of ['normal','anywhere']){
   const d=document.createElement('div');d.lang='ko';
   Object.assign(d.style,{position:'absolute',left:'0',top:'0',width:'200px',fontFamily:'Apple SD Gothic Neo',fontWeight:'700',fontSize:'16px',lineHeight:'20px',letterSpacing:'-.012em',whiteSpace:'pre-wrap',textWrap:'wrap',wordBreak,overflowWrap,lineBreak:'auto'});
   d.textContent=text;document.body.append(d);
   const tn=d.firstChild,canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');ctx.font='bold 16px "Apple SD Gothic Neo"';
   const widths=new Set([1,2,4,8,12,16,24,32,48,64,100,200,400]);
   for(let end=1;end<=text.length;end++){
    const w=ctx.measureText(text.slice(0,end)).width-end*.192;
    for(const off of [-.5,-.1,-.02,0,.02,.1,.5])if(w+off>0)widths.add(w+off);
   }
   const observations=[],ends=new Set();
   for(const width of [...widths].sort((a,b)=>a-b)){
    d.style.width=width+'px';const lines=[];
    for(let offset=0;offset<text.length;){
     const scalar=String.fromCodePoint(text.codePointAt(offset)),end=offset+scalar.length;
     const r=document.createRange();r.setStart(tn,offset);r.setEnd(tn,end);const fragments=[...r.getClientRects()];const box=fragments.find(r=>r.width>0&&r.height>0)||r.getBoundingClientRect();
     const last=lines.at(-1);
     if(!last||Math.abs(last.y-box.y)>.5)lines.push({start:offset,end,y:box.y});else last.end=end;
     offset=end;
    }
    for(const line of lines)ends.add(line.end);
    observations.push({width,usedWidth:d.getBoundingClientRect().width,lines:lines.map(r=>[r.start,r.end-r.start])});
   }
   output.push({text,wordBreak,overflowWrap,observedEnds:[...ends].sort((a,b)=>a-b),observations});d.remove();
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
let output:[String:Any]=["CFStringTokenizer":tokens,"WKWebView":web,"OS":ProcessInfo.processInfo.operatingSystemVersionString,
                      "scope":"Observed actual macOS WK greedy wrap ends across a bounded width sweep. Emergency-anywhere ends are not regular balance opportunities. A missing observed end is not proof of no legal opportunity."]
try JSONSerialization.data(withJSONObject:output,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:CommandLine.arguments[1]))
