import CoreGraphics
import Foundation
import Testing
import UIKit
import WebKit
@testable import Aidoku

/// Actual iOS Canvas source transport. Small nonuniform sources exercise crop
/// phase separately from palette thresholds and final overlay rendering.
@Suite(.serialized) @MainActor struct NativeSourceSamplerCanvasTransportTests {
    @Test func sourceTransportMatchesIOSCanvasAcrossCropPhases() async throws {
        let window = UIWindow(frame: CGRect(x: 0, y: 0, width: 390, height: 700))
        let controller = UIViewController()
        window.rootViewController = controller
        window.isHidden = false
        let browser = WKWebView(frame: controller.view.bounds)
        controller.view.addSubview(browser)
        defer { browser.removeFromSuperview(); window.isHidden = true }
        browser.loadHTMLString("<!doctype html><html><body></body></html>", baseURL: nil)
        for _ in 0..<300 where browser.isLoading {
            try await Task.sleep(for: .milliseconds(20))
        }
        var captures: [[String: Any]] = []
        for (iw, ih) in [(72,74), (73,73), (74,72), (2380,1680), (2381,1679)] {
            for alpha in iw < 100 ? [false, true] : [false] {
                var pixels = [UInt8](repeating: 0, count: iw * ih * 4)
                for y in 0..<ih {
                    for x in 0..<iw {
                        let i = (y * iw + x) * 4
                        if alpha {
                            pixels[i] = x % 3 == 0 ? 255 : 0
                            pixels[i+1] = y % 3 == 0 ? 255 : 0
                            pixels[i+2] = (x+y) % 3 == 0 ? 255 : 0
                            pixels[i+3] = [64,128,192,255][(x + 3*y) % 4]
                        } else {
                            pixels[i] = UInt8((17*x + 31*y + x*y) % 256)
                            pixels[i+1] = UInt8((47*x + 13*y + 3*x*y) % 256)
                            pixels[i+2] = UInt8((7*x + 53*y + 5*x*y) % 256)
                            pixels[i+3] = 255
                        }
                    }
                }
                let provider = try #require(CGDataProvider(data: Data(pixels) as CFData))
                let original = try #require(CGImage(width: iw, height: ih, bitsPerComponent: 8, bitsPerPixel: 32,
                    bytesPerRow: iw * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue), provider: provider,
                    decode: nil, shouldInterpolate: false, intent: .defaultIntent))
                let png = try #require(UIImage(cgImage: original).pngData())
                let decoded = try #require(UIImage(data: png)?.cgImage)
                var queries: [[String: Any]] = iw < 100
                    ? [["id":"whole", "rect":[0,0,iw,ih], "size":[iw,ih]]]
                    : [["id":"raw-reference", "rect":[8,8,24,24], "size":[24,24]]]
                for ratio in [1,2,3] {
                    for x in [8,9] { for y in [8,9] {
                        queries.append(["id":"r\(ratio)-x\(x)-y\(y)", "rect":[x,y,24,24], "size":[24/ratio,24/ratio]])
                    }}
                }
                queries.append(["id":"anisotropic-24x25-to12x12", "rect":[8.0,9.0,24.0,25.0], "size":[12,12]])
                queries.append(["id":"anisotropic-24x24-to12x11", "rect":[9.0,8.0,24.0,24.0], "size":[12,11]])
                queries.append(["id":"same-Float32-scale", "rect":[8.0,9.0,24.0,24.0000005], "size":[12,12]])
                queries.append(["id":"near-equal-Float32-scale", "rect":[9.0,8.0,24.0,Double(Float(24).nextUp)], "size":[12,12]])
                // The existing source texture clamp remains observable at magnified
                // crop edges and fractional coordinates.
                queries.append(["id":"fractional-upsample", "rect":[8.25,9.5,9.5,10.25], "size":[19,21]])
                queries.append(["id":"right-bottom-clamp", "rect":[Double(iw-6),Double(ih-7),8.0,9.0], "size":[16,18]])
                let script = """
                const image=new Image();image.src='data:image/png;base64,'+png;await image.decode();
                const rows=[];
                for(const q of queries){const [x,y,sw,sh]=q.rect,[w,h]=q.size;
                  const canvas=document.createElement('canvas');canvas.width=w;canvas.height=h;
                  const context=canvas.getContext('2d',{willReadFrequently:true});
                  context.drawImage(image,x,y,sw,sh,0,0,w,h);
                  rows.push({id:q.id,rgba:Array.from(context.getImageData(0,0,w,h).data)});}
                return JSON.stringify({rows,userAgent:navigator.userAgent});
                """
                let value = try await browser.callAsyncJavaScript(script,
                    arguments:["png":png.base64EncodedString(), "queries":queries],in:nil,contentWorld:.page)
                let json = try #require(value as? String)
                let result = try #require(try JSONSerialization.jsonObject(with:Data(json.utf8)) as? [String:Any])
                let rows = try #require(result["rows"] as? [[String:Any]])
                for (query,row) in zip(queries,rows) {
                    let r = try #require(query["rect"] as? [NSNumber]).map(\.doubleValue)
                    let size = try #require(query["size"] as? [Int])
                    let native = try NativeSourcePixelReader.draw(image:decoded,x:r[0],y:r[1],sourceWidth:r[2],sourceHeight:r[3],width:size[0],height:size[1])
                    let web = try #require(row["rgba"] as? [UInt8])
                    let changed = native.indices.filter { native[$0] != web[$0] }
                    captures.append(["imageSize":[iw,ih],"alpha":alpha,"id":query["id"]!,"rect":r,"size":size,
                        "changedBytes":changed.count,"maximumDelta":changed.map{abs(Int(native[$0])-Int(web[$0]))}.max() ?? 0,
                        "nativeRGBA":Data(native).base64EncodedString(),"webRGBA":Data(web).base64EncodedString(),"userAgent":result["userAgent"]!])
                    #expect(native == web, "source transport \(iw)x\(ih), alpha=\(alpha), \(query["id"]!)")
                }
            }
        }
        let directory = URL.documentsDirectory.appendingPathComponent("NativeRenderParity",isDirectory:true)
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        try JSONSerialization.data(withJSONObject:["scope":"Same PNG-decoded source, actual iOS Canvas versus production native reader; no palette or renderer policy.","rows":captures],options:[.sortedKeys,.prettyPrinted])
            .write(to:directory.appendingPathComponent("source-sampler-transport.json"))
    }
}
