import AppKit
import WebKit
import Foundation

let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
final class ClipCapture: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        view.evaluateJavaScript(#"""
        const cases=[
          ['absolute-zero',10.578125,10.53125,'absolute',[[0,0,33.84375,59.359375]]],
          ['absolute-partial',150.25,10.375,'absolute',[[1.05131244659424,26.25,23.23075,29]]],
          ['relative-partial',300.25,10.375,'relative',[[1.05131244659424,26.25,23.23075,29]]],
          ['negative-local',10.578125,150.53125,'relative',[[-3.19001,-4.22001,40.12501,64.37501]]],
          ['absolute-union',150.25,150.375,'absolute',[[1.125,4.75,16.3501,24.1501],[14.625,27.375,18.8503,29.4003]]],
          ['relative-union',300.25,150.375,'relative',[[1.125,4.75,16.3501,24.1501],[14.625,27.375,18.8503,29.4003]]],
          ['percent-inset',10.578125,290.53125,'percent',[11.39001,3.19123,27.81234,12.031234]],
          ['pixel-inset',150.25,290.375,'pixels',[3.19001,5.37501,2.12503,1.99999]],
          ['negative-pixel-inset',300.25,290.375,'pixels',[-1.19001,5.37501,2.12503,-3.99999]],
          ['empty-inset',10.578125,390.53125,'pixels',[20,20,80,20]]
        ];
        const rows=[];
        for(const [id,x,y,kind,pieces] of cases){
          const p=document.createElement('div');
          Object.assign(p.style,{position:'absolute',left:x+'px',top:y+'px',width:'33.84375px',height:'82.453125px',
            backgroundColor:'rgb(62,53,41)',borderRadius:'3px'});
          document.body.append(p);
          const b=p.getBoundingClientRect();
          const isInset=kind==='percent'||kind==='pixels';
          const path=isInset?'':pieces.map(([l,t,w,h])=>kind==='absolute'
            ?`M ${l} ${t} H ${l+w} V ${t+h} H ${l} Z`
            :`M ${l} ${t} h ${w} v ${h} h ${-w} Z`).join(' ');
          p.style.clipPath=isInset?`inset(${pieces.map(x=>x+(kind==='percent'?'%':'px')).join(' ')})`:`path('${path}')`;
          rows.push({id,commands:kind,owner:[b.left,b.top,b.width,b.height],
            coverage:isInset?[]:pieces.map(([l,t,w,h])=>[b.left+l,b.top+t,w,h]),insets:isInset?pieces:[],path,computed:getComputedStyle(p).clipPath,
            deviceScale:devicePixelRatio});
        }
        rows
        """#) { result, error in
            if let error { self.error = error; self.finished = true; return }
            do {
                try JSONSerialization.data(withJSONObject: result!, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("web.json"))
            } catch { self.error = error; self.finished = true; return }
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: 420, height: 480)
            view.createPDF(configuration: configuration) { result in
                do { try result.get().write(to: output.appendingPathComponent("web.pdf")) }
                catch { self.error = error }
                self.finished = true
            }
        }
    }
}

let app = NSApplication.shared
let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 420, height: 480))
let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = view
let capture = ClipCapture()
view.navigationDelegate = capture
view.loadHTMLString("<html><head><meta charset='utf-8'></head><body style='margin:0;background:white'></body></html>", baseURL: nil)
let deadline = Date().addingTimeInterval(45)
while !capture.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
precondition(capture.finished)
if let error = capture.error { throw error }
