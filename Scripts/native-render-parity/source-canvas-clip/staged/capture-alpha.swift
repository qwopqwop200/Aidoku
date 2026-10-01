import AppKit
import WebKit
import Foundation
let layers = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1]))) as! [String: Any]
let actual = (layers["masks"] as! [[String: Any]])[0]["png"] as! String
let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
let inputs = try String(data: JSONSerialization.data(withJSONObject: ["actual": actual]), encoding: .utf8)!
final class Capture: NSObject, WKNavigationDelegate {
    var finished = false; var error: Error?
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) {
        let js = "const inputs=" + inputs + ";" + #"""
        const records=[];
        const make=(id,x,y,w,h,actual=false)=>{
            const n=document.createElement('canvas');n.width=actual?412:20;n.height=actual?527:20;
            Object.assign(n.style,{position:'absolute',left:x+'px',top:y+'px',width:w+'px',height:h+'px'});
            const c=n.getContext('2d');
            if(!actual){const d=c.createImageData(20,20);for(let y=0;y<20;y++)for(let x=0;x<20;x++){
                const i=(y*20+x)*4;d.data[i]=23+x*9;d.data[i+1]=17+y*10;d.data[i+2]=201;d.data[i+3]=((x+y)%5<2||x<3)?0:255;}c.putImageData(d,0,0);}
            else c.drawImage(document.getElementById('actual'),0,0,n.width,n.height);
            document.body.appendChild(n);const r=n.getBoundingClientRect();records.push({id,used:[r.x,r.y,r.width,r.height],width:n.width,height:n.height,png:n.toDataURL()});
        };
        make('binary',10,10,93,77);make('overlap',49,31,71,93);make('actual-mask',135,7,91,121,true);
        records
        """#
        view.evaluateJavaScript(js) { result, error in
            if let error { self.error=error;self.finished=true;return }
            do { try JSONSerialization.data(withJSONObject: result!, options: [.sortedKeys]).write(to: output.appendingPathComponent("web.json")) }
            catch { self.error=error;self.finished=true;return }
            self.snapshot(view,index:0)
        }
    }
    func snapshot(_ view: WKWebView,index:Int) {
        guard index<2 else { finished=true;return }
        view.evaluateJavaScript("document.body.style.background='" + (index==0 ? "transparent" : "rgb(41,65,87)") + "'") { _,error in
            if let error { self.error=error;self.finished=true;return }
            let config=WKSnapshotConfiguration();config.rect=view.bounds;config.snapshotWidth=320
            view.takeSnapshot(with:config) { image,error in
                if let error { self.error=error;self.finished=true;return }
                guard let cg=image?.cgImage(forProposedRect:nil,context:nil,hints:nil),let png=NSBitmapImageRep(cgImage:cg).representation(using:.png,properties:[:]) else { self.error=NSError(domain:"snapshot",code:1);self.finished=true;return }
                do { try png.write(to:output.appendingPathComponent("web-\(index).png")) }
                catch { self.error=error;self.finished=true;return }
                self.snapshot(view,index:index+1)
            }
        }
    }
}
let app=NSApplication.shared
let view=WKWebView(frame:CGRect(x:0,y:0,width:320,height:160));view.setValue(false,forKey:"drawsBackground")
let window=NSWindow(contentRect:view.frame,styleMask:.borderless,backing:.buffered,defer:false);window.contentView=view
let capture=Capture();view.navigationDelegate=capture
view.loadHTMLString("<html><body style='margin:0;background:transparent'><img id='actual' style='display:none' src='" + actual + "'></body></html>",baseURL:nil)
let deadline=Date().addingTimeInterval(45)
while !capture.finished && Date()<deadline { RunLoop.current.run(until:Date().addingTimeInterval(0.02)) }
precondition(capture.finished);if let error=capture.error { throw error }
