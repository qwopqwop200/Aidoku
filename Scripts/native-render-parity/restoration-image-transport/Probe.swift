import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

@MainActor final class TransportProbe: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let output: URL
    let fixtures: [[String:Any]]
    var native: [[String:Any]] = []
    var timeout: Timer?
    init(output: URL) throws {
        self.output = output
        let config = WKWebViewConfiguration(); config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame:NSRect(x:0,y:0,width:400,height:300),configuration:config)
        var fixtures: [[String:Any]] = []
        let w=17,h=13
        let queries: [(String,Int,Int,[Double],[Double]?)] = [
            ("identity",w,h,[0,0,Double(w),Double(h)],nil),
            ("upscale",34,26,[0,0,34,26],nil),
            ("downscale",9,7,[0,0,9,7],nil),
            ("white-scaled",41,27,[0,0,41,27],[255,255,255,255]),
            ("fractional-chroma",30,22,[1.25,2.75,23.5,16.25],[41,119,203,255])
        ]
        for pattern in 0..<4 {
            var rgba=[UInt8](repeating:0,count:w*h*4)
            for y in 0..<h { for x in 0..<w {
                let i=(y*w+x)*4
                rgba[i]=UInt8((x*17+y*31+19)%256);rgba[i+1]=UInt8((x*29+y*7+61)%256);rgba[i+2]=UInt8((x*11+y*23+101)%256)
                let alpha: UInt8 = pattern == 0 || pattern == 1 ? ((x+y)%3==0 ? 0 : 255) : pattern == 2 ? ((x+y)%4==0 ? 0 : 128) : [UInt8(0),1,31,64,127,128,200,254,255][(x+y*3)%9]
                rgba[i+3]=alpha
                if pattern==0 && alpha==0 {rgba[i]=0;rgba[i+1]=0;rgba[i+2]=0}
            } }
            fixtures.append(["pattern":pattern,"width":w,"height":h,"rgba":rgba,"queries":queries.map { q -> [String:Any] in
                ["name":q.0,"width":q.1,"height":q.2,"dest":q.3,"background":q.4 as Any? ?? NSNull()]
            }])
            for variant in ["production","straight-last","canonical-premultiplied"] {
                let source: CGImage
                if variant=="production" {source=NativeImageTransportProbe(width:w,height:h,rgba:rgba).image()!}
                else if variant=="straight-last" {source=StraightImageTransportProbe(width:w,height:h,rgba:rgba).image()!}
                else {
                    var premult=rgba
                    for i in stride(from:0,to:premult.count,by:4) {for channel in 0..<3 {premult[i+channel]=UInt8((Int(rgba[i+channel])*Int(rgba[i+3])+127)/255)}}
                    source=CanonicalImageTransportProbe(width:w,height:h,rgba:premult).image()!
                }
                let png=NSMutableData(),destination=CGImageDestinationCreateWithData(png,UTType.png.identifier as CFString,1,nil)!
                CGImageDestinationAddImage(destination,source,nil)
                guard CGImageDestinationFinalize(destination),let decodedSource=CGImageSourceCreateWithData(png,nil),let decoded=CGImageSourceCreateImageAtIndex(decodedSource,0,nil) else {throw CocoaError(.fileReadCorruptFile)}
                try (png as Data).write(to:output.deletingLastPathComponent().appendingPathComponent("pattern\(pattern)-\(variant).png"))
                for route in ["direct","png"] {for query in queries {
                    let image=route=="direct" ? source : decoded
                    native.append(["name":"pattern\(pattern)/\(route)/\(query.0)","variant":variant,"rgba":try Self.draw(image:image,width:query.1,height:query.2,destination:query.3,background:query.4)])
                }}
            }
        }
        self.fixtures=fixtures
        super.init();webView.navigationDelegate=self
    }
    static func draw(image:CGImage,width:Int,height:Int,destination:[Double],background:[Double]?) throws -> [UInt8] {
        var rgba=[UInt8](repeating:0,count:width*height*4)
        let success=rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let context=CGContext(data:bytes.baseAddress,width:width,height:height,bitsPerComponent:8,bytesPerRow:width*4,space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else {return false}
            context.interpolationQuality = .low
            if let background {context.setFillColor(CGColor(colorSpace:CGColorSpace(name:CGColorSpace.sRGB)!,components:background.map{$0/255})!);context.fill(CGRect(x:0,y:0,width:width,height:height))}
            context.draw(image,in:CGRect(x:destination[0],y:Double(height)-destination[1]-destination[3],width:destination[2],height:destination[3]))
            return true
        }
        guard success else {throw CocoaError(.coderInvalidValue)}
        for i in stride(from:0,to:rgba.count,by:4) {
            rgba.swapAt(i,i+2)
            if rgba[i+3]>0 && rgba[i+3]<255 {for c in 0..<3 {rgba[i+c]=UInt8(min(255,(Double(rgba[i+c])*255/Double(rgba[i+3])).rounded(.toNearestOrAwayFromZero)))}}
        }
        return rgba
    }
    func start() {
        timeout=Timer.scheduledTimer(withTimeInterval:45,repeats:false) { _ in MainActor.assumeIsolated {FileHandle.standardError.write(Data("WebKit transport oracle timed out\n".utf8));exit(3)} }
        webView.loadHTMLString("<!doctype html><html><body></body></html>",baseURL:nil)
    }
    func webView(_ webView:WKWebView,didFinish navigation:WKNavigation!) {
        do {
            let encoded=String(data:try JSONSerialization.data(withJSONObject:fixtures),encoding:.utf8)!
            let code="""
              const rows=[],pngs=[];
              for(const f of \(encoded)) {
                const source=document.createElement('canvas');source.width=f.width;source.height=f.height;
                const sourceContext=source.getContext('2d',{willReadFrequently:true});
                sourceContext.putImageData(new ImageData(new Uint8ClampedArray(f.rgba),f.width,f.height),0,0);
                const png=source.toDataURL('image/png');pngs.push({pattern:f.pattern,png});
                const decoded=new Image();decoded.src=png;await decoded.decode();
                for(const route of ['direct','png'])for(const q of f.queries) {
                  const canvas=document.createElement('canvas');canvas.width=q.width;canvas.height=q.height;
                  const context=canvas.getContext('2d',{willReadFrequently:true});
                  if(q.background){context.fillStyle='rgba('+q.background.slice(0,3).join(',')+','+(q.background[3]/255)+')';context.fillRect(0,0,q.width,q.height);}
                  context.drawImage(route==='direct'?source:decoded,...q.dest);
                  rows.push({name:'pattern'+f.pattern+'/'+route+'/'+q.name,rgba:Array.from(context.getImageData(0,0,q.width,q.height).data)});
                }
              }
              return {rows,pngs,userAgent:navigator.userAgent,devicePixelRatio};
              """
            webView.callAsyncJavaScript(code,arguments:[:],in:nil,in:.page) { [self] result in
                timeout?.invalidate()
                do {
                    let value=try result.get() as! [String:Any]
                    for png in value["pngs"] as! [[String:Any]] {
                        let base=(png["png"] as! String).split(separator:",",maxSplits:1)[1]
                        try Data(base64Encoded:String(base))!.write(to:output.deletingLastPathComponent().appendingPathComponent("pattern\(png["pattern"]!)-web.png"))
                    }
                    try JSONSerialization.data(withJSONObject:["oracle":value["rows"]!,"native":native,"userAgent":value["userAgent"]!,"devicePixelRatio":value["devicePixelRatio"]!],options:[.sortedKeys]).write(to:output)
                    print("Captured \(native.count) production/candidate raster transports versus actual Canvas")
                    exit(0)
                } catch {FileHandle.standardError.write(Data("WebKit transport failed: \(error)\n".utf8));exit(2)}
            }
        } catch {FileHandle.standardError.write(Data("Transport setup failed: \(error)\n".utf8));exit(2)}
    }
}
@main struct Main {
    @MainActor static func main() throws {
        let app=NSApplication.shared;app.setActivationPolicy(.prohibited)
        let probe=try TransportProbe(output:URL(fileURLWithPath:CommandLine.arguments[1]));probe.start()
        withExtendedLifetime(probe){app.run()}
    }
}
