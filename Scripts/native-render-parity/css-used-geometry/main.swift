import AppKit
import WebKit
import Foundation
final class Delegate: NSObject, WKNavigationDelegate {
    let view: WKWebView
    var complete = false
    init(view: WKWebView) { self.view = view }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        webView.evaluateJavaScript("JSON.stringify([[-1.01,-3.99,51.58,182.325,4.79],[284.26,253.475,51.58,182.325,4.79],[10.1409774436,400.8270676692,59.3796992481,76.3627819549,3],[0.0079,0.0155,31.999,33.001,0.999],[0.0236,0.0309,2.3,4.9,0.0149],[0,0,42.265624999999986,81.140625,3],[0,0,42.2656249,81.140625,3],[0,0,42.265624,81.140625,3],[0,0,42.26562,81.140625,3]].map(a=>{let d=document.createElement('div');Object.assign(d.style,{position:'absolute',left:a[0]+'px',top:a[1]+'px',width:a[2]+'px',height:a[3]+'px',padding:a[4]+'px',boxSizing:'border-box'});document.body.append(d);let child=document.createElement('div');child.style.height='100%';d.append(child);let cr=child.getBoundingClientRect();let r=d.getBoundingClientRect(),c=getComputedStyle(d);let q=x=>Math.trunc(Math.fround(x)*64)/64;return {input:a,outer:[r.x,r.y,r.width,r.height],padding:parseFloat(c.paddingLeft),content:[cr.x,cr.y,cr.width,cr.height],computedWidth:c.width,expectedOuter:[q(a[0]),q(a[1]),q(a[2]),q(a[3])],expectedContent:[q(a[0])+q(a[4]),q(a[1])+q(a[4]),q(a[2])-2*q(a[4]),q(a[3])-2*q(a[4])]}}))") { value, error in
            if let error { print(error);self.complete=true;return }
            print(value ?? "nil")
            guard let json = value as? String,
                  let data = json.data(using: .utf8),
                  let rows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { fatalError("Missing DOM geometry") }
            for row in rows {
                precondition(row["outer"] as? [Double] == row["expectedOuter"] as? [Double])
                precondition(row["content"] as? [Double] == row["expectedContent"] as? [Double])
            }
            print("{\"cases\":\(rows.count),\"passed\":true,\"scope\":\"Actual WebKit CSS-used border-box and individual padding values, including negative origins and Float32 boundary parsing\"}")
            self.complete = true
        }
    }
}
let app = NSApplication.shared
let view = WKWebView(frame:NSRect(x:0,y:0,width:390,height:536))
let window = NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate(view:view);view.navigationDelegate=delegate
view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:white}#t{position:absolute;left:30px;top:40px;width:180px;height:24px;font-family:'Apple SD Gothic Neo';font-size:20px;font-weight:700;line-height:24px;letter-spacing:-.24px;text-align:center;color:black;-webkit-text-stroke:1px rgb(255,0,0);paint-order:stroke fill;text-shadow:0 0 2px rgb(255,0,0);white-space:pre-wrap;display:flex;align-items:center;justify-content:center}</style></head><body><div id='t'>가나다</div></body></html>",baseURL:nil)
let deadline = Date().addingTimeInterval(30)
while !delegate.complete && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
precondition(delegate.complete,"WK glow capture incomplete")
