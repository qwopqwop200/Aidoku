import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WebKit

@MainActor final class CanvasProbe: NSObject, WKNavigationDelegate {
    let webView: WKWebView
    let fixtures: [[String: Any]]
    let output: URL
    var native: [[String: Any]] = []
    var timeout: Timer?
    init(output: URL) throws {
        self.output = output
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        webView = WKWebView(frame: NSRect(x: 0, y: 0, width: 400, height: 300), configuration: config)
        var fixtures: [[String: Any]] = []
        for pattern in 0..<6 {
            let w = pattern >= 4 ? 200 : 47, h = pattern >= 4 ? 300 : 39
            var rgba = [UInt8](repeating: 0, count: w*h*4)
            for y in 0..<h { for x in 0..<w {
                let i = (y*w+x)*4
                if pattern == 0 || pattern == 4 {
                    rgba[i] = UInt8((x*5+y*2)%256); rgba[i+1] = UInt8((x*2+y*6)%256); rgba[i+2] = UInt8((x*7+y*3)%256)
                } else if pattern == 1 {
                    let stroke = (x >= 9 && x <= 11 && y >= 7 && y <= 31) || (y >= 8 && y <= 10 && x >= 9 && x <= 34) || (x+y >= 42 && x+y <= 44)
                    rgba[i] = stroke ? 9 : 244;rgba[i+1] = stroke ? 38 : 238;rgba[i+2] = stroke ? 71 : 229
                } else {
                    rgba[i] = UInt8((x*31+y*17)%256);rgba[i+1] = UInt8((x*11+y*29)%256);rgba[i+2] = UInt8((x*23+y*7)%256)
                }
                rgba[i+3] = pattern < 2 || pattern == 4 ? 255 : pattern == 2 || pattern == 5 ? [UInt8(0),1,31,64,127,200,254,255][(x+y*3)%8] : 128
                if x < 5 && y < 5 {rgba[i] = 245;rgba[i+1] = 12;rgba[i+2] = 30}
                if x >= w-5 && y < 5 {rgba[i] = 13;rgba[i+1] = 237;rgba[i+2] = 40}
                if x < 5 && y >= h-5 {rgba[i] = 17;rgba[i+1] = 39;rgba[i+2] = 243}
                if x >= w-5 && y >= h-5 {rgba[i] = 231;rgba[i+1] = 219;rgba[i+2] = 18}
            } }
            let provider = CGDataProvider(data: Data(rgba) as CFData)!
            let source = CGImage(width: w, height: h, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: w*4,
                space: CGColorSpace(name: CGColorSpace.sRGB)!,
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue | CGBitmapInfo.byteOrder32Big.rawValue),
                provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)!
            let png = NSMutableData()
            let destination = CGImageDestinationCreateWithData(png, UTType.png.identifier as CFString, 1, nil)!
            CGImageDestinationAddImage(destination, source, nil)
            guard CGImageDestinationFinalize(destination),
                  let imageSource = CGImageSourceCreateWithData(png, nil),
                  let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) else {throw CocoaError(.fileReadCorruptFile)}
            let reader = NativeSourcePixelReader(image: image, threshold: 1)
            let crops: [(String, Double, Double, Double, Double, Int, Int)] = pattern >= 4 ? [("spatial-edge",0,0,64,174,57,156)] : [
                ("full",0,0,47,39,47,39), ("integer",7,5,23,19,23,19),
                ("cached-integer",9,11,19,13,19,13), ("corners",0,0,5,5,5,5),
                ("fractional",3.25,6.75,27.5,23.25,28,23), ("fractional-no-scale",3.5,6.5,21,17,21,17),
                ("downsample",0,0,47,39,16,13), ("upsample",4,3,21,19,63,57),
                ("scaled-axis",7,5,23,19,46,13), ("clipped",-3.5,-2.25,27,23,27,23),
                ("edge",40.25,31.75,13.5,10.5,20,16)
            ]
            for crop in crops {
                let (name,x,y,sw,sh,dw,dh)=crop
                let canvasWidth = pattern >= 4 ? 78 : dw, canvasHeight = pattern >= 4 ? 177 : dh
                let destX = pattern >= 4 ? 21 : 0, destY = pattern >= 4 ? 21 : 0
                let actual: [UInt8], direct: [UInt8]
                if pattern >= 4 {
                    let source = CGRect(x:x,y:y,width:sw,height:sh), destination = CGRect(x:destX,y:destY,width:dw,height:dh)
                    actual = NativeSpatialSourceCrop.edgePixels(image:image,source:source,destination:destination,width:canvasWidth,height:canvasHeight)!
                    direct = actual
                } else {
                    actual = try reader.read(x:x,y:y,sourceWidth:sw,sourceHeight:sh,width:dw,height:dh)
                    direct = try NativeSourcePixelReader.draw(image:image,x:x,y:y,sourceWidth:sw,sourceHeight:sh,width:dw,height:dh)
                }
                let key = "pattern\(pattern)/\(name)"
                fixtures.append(["name":key,"png":(png as Data).base64EncodedString(),"x":x,"y":y,"sw":sw,"sh":sh,"width":canvasWidth,"height":canvasHeight,"drawWidth":dw,"drawHeight":dh,"destX":destX,"destY":destY])
                native.append(["name":key,"rgba":actual,"direct":direct])
            }
            reader.release()
        }
        self.fixtures=fixtures
        super.init()
        webView.navigationDelegate=self
    }
    func start() {
        timeout=Timer.scheduledTimer(withTimeInterval:45,repeats:false) { _ in
            MainActor.assumeIsolated {FileHandle.standardError.write(Data("WebKit oracle timed out\n".utf8));exit(3)}
        }
        webView.loadHTMLString("<!doctype html><html><body></body></html>",baseURL:nil)
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        do {
            let encoded = String(data:try JSONSerialization.data(withJSONObject:fixtures),encoding:.utf8)!
            let code = """
              const rows=[];
              for(const f of \(encoded)) {
                const image=new Image();image.src='data:image/png;base64,'+f.png;await image.decode();
                const canvas=document.createElement('canvas');canvas.width=f.width;canvas.height=f.height;
                const context=canvas.getContext('2d',{willReadFrequently:true});
                context.drawImage(image,f.x,f.y,f.sw,f.sh,f.destX,f.destY,f.drawWidth,f.drawHeight);
                rows.push({name:f.name,rgba:Array.from(context.getImageData(0,0,f.width,f.height).data)});
              }
              return {rows,userAgent:navigator.userAgent,devicePixelRatio:devicePixelRatio};
              """
            webView.callAsyncJavaScript(code,arguments:[:],in:nil,in:.page) { [self] result in
                timeout?.invalidate()
                do {
                    let oracle=try result.get() as! [String:Any]
                    let record:[String:Any] = ["oracle":oracle["rows"]!,"native":native,"userAgent":oracle["userAgent"]!,"devicePixelRatio":oracle["devicePixelRatio"]!]
                    try JSONSerialization.data(withJSONObject:record,options:[.sortedKeys]).write(to:output)
                    print("Captured \(native.count) actual native/Canvas raster pairs")
                    exit(0)
                } catch {FileHandle.standardError.write(Data("WebKit evaluation failed: \(error)\n".utf8));exit(2)}
            }
        } catch {FileHandle.standardError.write(Data("Oracle setup failed: \(error)\n".utf8));exit(2)}
    }
}
@main struct Main {
    @MainActor static func main() throws {
        let application=NSApplication.shared
        application.setActivationPolicy(.prohibited)
        let probe=try CanvasProbe(output:URL(fileURLWithPath:CommandLine.arguments[1]))
        probe.start()
        withExtendedLifetime(probe) {application.run()}
    }
}
