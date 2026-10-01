import AppKit
import WebKit
import Foundation
final class Delegate: NSObject, WKNavigationDelegate {
    var complete = false
    let script: String
    let output: URL
    init(script: String, output: URL) { self.script = script; self.output = output }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        view.evaluateJavaScript(script) { value,error in
            guard let string=value as? String else {fatalError(String(describing:error))}
            try! Data(string.utf8).write(to:self.output)
            self.complete=true
        }
    }
}
let app=NSApplication.shared
let script=try String(contentsOfFile:CommandLine.arguments[1],encoding:.utf8)
let view=WKWebView(frame:NSRect(x:0,y:0,width:390,height:700))
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let delegate=Delegate(script:script,output:URL(fileURLWithPath:CommandLine.arguments[2]));view.navigationDelegate=delegate
view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:white}</style></head><body></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(40)
while !delegate.complete && Date()<deadline {RunLoop.current.run(until:Date().addingTimeInterval(0.02))}
precondition(delegate.complete,"Vertical WK capture incomplete")
