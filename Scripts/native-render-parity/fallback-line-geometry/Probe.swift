import AppKit
import CoreText
import Foundation
import WebKit

@MainActor final class Probe: NSObject,WKNavigationDelegate {
    let view = WKWebView(frame:NSRect(x:0,y:0,width:1200,height:900))
    let output:URL
    var rows:[[String:Any]] = []
    var native:[[String:Any]] = []
    var timer:Timer?
    init(output:URL) {
        self.output = output
        super.init()
        view.navigationDelegate = self
        for script in ["japanese","korean"] { for font in [6.0,7,8.5,10,12,14,20,31.5] { for text in ["こんにちは世界\nこんにちは世界","안녕하세요 세계\n안녕하세요 세계","こんにちは世界\n안녕하세요 세계","日안本녕語하세世界요"] {
            let id = "\(script)-\(font)-\(rows.count)"
            let pitch = font*1.2
            rows.append(["id":id,"script":script,"font":font,"pitch":pitch,"text":text,"width":600,"height":150])
            let style = NativeTranslationTypography.Style(fontScript:script,fontSize:font,lineHeight:pitch,optimizesKoreanWrapping:false)
            let layout = NativeTranslationTypography.layout(text:text,in:CGSize(width:600,height:150),style:style)
            var record:[String:Any] = ["id":id,"ranges":layout.rangeBounds.map(box),"shape":layout.shapedText,"lineCount":layout.lineCount]
            let string = NativeTranslationTypography.attributedString(text:text,style:style)
            let primary = string.attribute(NSAttributedString.Key(kCTFontAttributeName as String),at:0,effectiveRange:nil) as! CTFont
            record["primary"] = metrics(primary)
            var zero:CGFloat = 0,p = CGFloat(floor(max(font,pitch))),align = CTTextAlignment.center
            let paragraph:CTParagraphStyle = withUnsafePointer(to:&zero) { z in withUnsafePointer(to:&p) { h in withUnsafePointer(to:&align) { a in
                let v = [CTParagraphStyleSetting(spec:.minimumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:h),
                         .init(spec:.maximumLineHeight,valueSize:MemoryLayout<CGFloat>.size,value:h),
                         .init(spec:.maximumLineSpacing,valueSize:MemoryLayout<CGFloat>.size,value:z),
                         .init(spec:.alignment,valueSize:MemoryLayout<CTTextAlignment>.size,value:a)]
                return CTParagraphStyleCreate(v,v.count)
            } } }
            let modified = NSMutableAttributedString(attributedString:string)
            modified.addAttribute(NSAttributedString.Key(kCTParagraphStyleAttributeName as String),value:paragraph,range:NSRange(location:0,length:modified.length))
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(modified),CFRange(location:0,length:0),CGPath(rect:CGRect(x:0,y:0,width:600,height:150),transform:nil),nil)
            let lines = CTFrameGetLines(frame)
            var origins = [CGPoint](repeating:.zero,count:CFArrayGetCount(lines));CTFrameGetLineOrigins(frame,CFRange(location:0,length:0),&origins)
            var nativeLines:[[String:Any]] = []
            for i in origins.indices {
                let line = unsafeBitCast(CFArrayGetValueAtIndex(lines,i),to:CTLine.self),runs = CTLineGetGlyphRuns(line)
                let range = CTLineGetStringRange(line)
                var faces:[[String:Any]] = []
                for r in 0..<CFArrayGetCount(runs) {
                    let run = unsafeBitCast(CFArrayGetValueAtIndex(runs,r),to:CTRun.self)
                    let attrs = CTRunGetAttributes(run) as NSDictionary
                    let face = attrs[kCTFontAttributeName] as! CTFont
                    var m = metrics(face)
                    let chars = CTRunGetStringRange(run);m["start"] = chars.location;m["length"] = chars.length
                    faces.append(m)
                }
                var ascent:CGFloat = 0,descent:CGFloat = 0,leading:CGFloat = 0
                CTLineGetTypographicBounds(line,&ascent,&descent,&leading)
                nativeLines.append(["topBaseline":150-origins[i].y,"start":range.location,"length":range.length,"ascent":ascent,"descent":descent,"leading":leading,"faces":faces])
            }
            record["noNaturalLeadingLines"] = nativeLines;native.append(record)
        } } }
    }
    func box(_ r:CGRect)->[Double] {[r.minX,r.minY,r.width,r.height]}
    func metrics(_ font:CTFont)->[String:Any] {
        ["face":CTFontCopyPostScriptName(font) as String,"size":CTFontGetSize(font),"ascent":CTFontGetAscent(font),"descent":CTFontGetDescent(font),"leading":CTFontGetLeading(font)]
    }
    func start() {
        timer = Timer.scheduledTimer(withTimeInterval:45,repeats:false) { _ in MainActor.assumeIsolated { () -> Void in exit(3) } }
        view.loadHTMLString("<!doctype html><html><body style='margin:0'></body></html>",baseURL:nil)
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        let input = String(data:try! JSONSerialization.data(withJSONObject:rows),encoding:.utf8)!
        let js = """
        const output=[];
        for(const f of \(input)) {
          const family=f.script==='japanese'?"'Hiragino Sans','YuGothic','Noto Sans CJK JP',-apple-system,BlinkMacSystemFont,sans-serif":"'Apple SD Gothic Neo','Noto Sans CJK KR','Noto Sans KR',-apple-system,BlinkMacSystemFont,sans-serif";
          function capture(markers) {
            const outer=document.createElement('div');Object.assign(outer.style,{position:'absolute',left:'0px',top:'0px',width:f.width+'px',height:f.height+'px',display:'flex',alignItems:'center',justifyContent:'center',fontFamily:family,fontWeight:'600',fontSize:f.font+'px',lineHeight:f.pitch+'px',letterSpacing:'-0.012em',textAlign:'center',whiteSpace:'pre-line'});
            const span=document.createElement('span');span.style.maxWidth='100%';outer.append(span);document.body.append(outer);
            if(markers) {f.text.split('\\n').forEach((row,i)=>{if(i)span.append(document.createTextNode('\\n'));span.append(document.createTextNode(row));const m=document.createElement('i');Object.assign(m.style,{display:'inline-block',width:'0px',height:'0px',verticalAlign:'baseline'});m.className='baseline';span.append(m);});} else span.textContent=f.text;
            const walker=document.createTreeWalker(span,NodeFilter.SHOW_TEXT),ranges=[];let t,offset=0;
            while(t=walker.nextNode()){let at=0;for(const scalar of t.data){const next=at+scalar.length;if(!/\\s/u.test(scalar)){const r=document.createRange();r.setStart(t,at);r.setEnd(t,next);const fragments=Array.from(r.getClientRects()).filter(x=>x.width>0&&x.height>0),b=fragments.at(-1)||r.getBoundingClientRect();ranges.push({scalar,start:offset+at,box:[b.x,b.y,b.width,b.height]});}at=next;}offset+=t.length;}
            const b=span.getBoundingClientRect(),baselines=Array.from(span.querySelectorAll('.baseline')).map(x=>x.getBoundingClientRect().top),result={ranges,span:[b.x,b.y,b.width,b.height],baselines,font:getComputedStyle(span).font,lineHeight:getComputedStyle(span).lineHeight};
            outer.remove();return result;
          }
          const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');ctx.font=`600 ${f.font}px ${family}`;const metrics=['日','안','A'].map(text=>{const m=ctx.measureText(text);return {text,ascent:m.fontBoundingBoxAscent,descent:m.fontBoundingBoxDescent,actualAscent:m.actualBoundingBoxAscent,actualDescent:m.actualBoundingBoxDescent,width:m.width};});
          output.push({id:f.id,input:f,plain:capture(false),marked:capture(true),canvas:metrics});
        }
        return {rows:output,userAgent:navigator.userAgent,dpr:devicePixelRatio};
        """
        view.callAsyncJavaScript(js,arguments:[:],in:nil,in:.page) { result in
            self.timer?.invalidate()
            do {
                let captured = try result.get() as! [String:Any]
                let record:[String:Any] = ["oracle":captured,"native":self.native]
                try JSONSerialization.data(withJSONObject:record,options:[.prettyPrinted,.sortedKeys]).write(to:self.output)
                print("Captured \(self.rows.count) actual WK/native fallback geometry pairs")
                exit(0)
            } catch {print(error);exit(2)}
        }
    }
}
@main struct Main {
    @MainActor static func main() {
        let app = NSApplication.shared;app.setActivationPolicy(.prohibited)
        let probe = Probe(output:URL(fileURLWithPath:CommandLine.arguments[1]));probe.start()
        withExtendedLifetime(probe){app.run()}
    }
}
