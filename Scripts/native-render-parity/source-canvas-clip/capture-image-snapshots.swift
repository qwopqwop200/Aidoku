import AppKit
import WebKit
import Foundation
let input = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
final class Capture: NSObject, WKNavigationDelegate {
    var finished = false
    var error: Error?
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        let js = "const inputs=" + input + ";\n" + #"""
        const records=[];
        for(let i=0;i<inputs.length;i++) {
            const f=inputs[i], b=f.raw, p=document.createElement('div'), n=document.createElement('canvas');
            Object.assign(p.style,{position:'absolute',left:'200px',top:(i*160+10)+'px',width:'400px',height:'150px'});
            n.width=20; n.height=20;
            const context=n.getContext('2d');
            context.fillStyle='rgb('+(180+i*3)+',30,50)';context.fillRect(0,0,20,20);
            // Opaque four-quadrant interior proves that this is an image draw;
            // a solid nonwhite outer border makes destination edges measurable.
            for(let j=0;j<4;j++) {
                context.fillStyle=['#154070','#508020','#d08030','#7030a0'][j];
                context.fillRect(1+(j%2)*9,1+Math.floor(j/2)*9,9,9);
            }
            Object.assign(n.style,{position:'absolute',left:b[0]+'px',top:b[1]+'px',width:b[2]+'px',height:b[3]+'px'});
            p.appendChild(n);document.body.appendChild(p);
            const r=n.getBoundingClientRect(),pr=p.getBoundingClientRect();
            records.push({id:f.id,raw:b,used:[r.x,r.y,r.width,r.height],parent:[pr.x,pr.y],
                color:[180+i*3,30,50],deviceScale:devicePixelRatio,png:n.toDataURL('image/png')});
        }
        records
        """#
        view.evaluateJavaScript(js) { result, error in
            if let error { self.error = error; self.finished = true; return }
            do {
                try JSONSerialization.data(withJSONObject: result!, options: [.prettyPrinted, .sortedKeys])
                    .write(to: output.appendingPathComponent("web.json"))
            } catch { self.error = error; self.finished = true; return }
            let pdf = WKPDFConfiguration(); pdf.rect = view.bounds
            view.createPDF(configuration: pdf) { result in
                do { try result.get().write(to: output.appendingPathComponent("web.pdf")) }
                catch { self.error = error; self.finished = true; return }
                self.snapshot(view, index: 0)
            }
        }
    }
    func snapshot(_ view: WKWebView, index: Int) {
        guard index < 2 else { finished = true; return }
        let config = WKSnapshotConfiguration()
        config.rect = view.bounds
        config.snapshotWidth = NSNumber(value: [640,1280][index])
        view.takeSnapshot(with: config) { image, error in
            if let error { self.error = error; self.finished = true; return }
            guard let image, let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
                  let data = NSBitmapImageRep(cgImage: cgImage).representation(using: .png, properties: [:]) else {
                self.error = NSError(domain: "snapshot", code: 1); self.finished = true; return
            }
            do { try data.write(to: output.appendingPathComponent("snapshot-\(index).png")) }
            catch { self.error = error; self.finished = true; return }
            self.snapshot(view, index: index + 1)
        }
    }
}
let app = NSApplication.shared
let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 640, height: 1000))
let window = NSWindow(contentRect: view.frame, styleMask: .borderless, backing: .buffered, defer: false)
window.contentView = view
let capture = Capture(); view.navigationDelegate = capture
view.loadHTMLString("<html><body style='margin:0;background:white'></body></html>", baseURL: nil)
let deadline = Date().addingTimeInterval(45)
while !capture.finished && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
precondition(capture.finished)
if let error = capture.error { throw error }
