import CoreGraphics
import CryptoKit
import Foundation
import UIKit
import WebKit
@testable import Aidoku

/// Bounded source-only diagnostic. The frozen final renderer is never mutated:
/// its already decoded background is read on detached scratch canvases.
@MainActor enum NativeSourceCanvasPixelDiagnostic {
    static func capture(image: UIImage, webView: WKWebView, output: URL, fixtureID: String) async throws {
        if fixtureID == "real-comic-0025" {
            try await captureForced(image: image, webView: webView, output: output)
            return
        }
        guard fixtureID == "real-comic-0015" else { return }
        let input = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("web-layout.json"))) as! [[String: Any]]
        guard let item = input.first(where: { $0["id"] as? String == "7" }),
              let bounds = item["sourceBounds"] as? [Double], bounds.count == 4,
              let prepared = try ReaderTranslationBackgroundImage.prepare(image).cgImage else { throw DiagnosticError.invalidSource }
        let iw = Double(prepared.width), ih = Double(prepared.height)
        let margin = max(4, min(16, ceil(min(bounds[2] * iw, bounds[3] * ih) * 0.5)))
        let x = max(0, floor(bounds[0] * iw) - margin), y = max(0, floor(bounds[1] * ih) - margin)
        let sw = min(iw, ceil((bounds[0] + bounds[2]) * iw) + margin) - x
        let sh = min(ih, ceil((bounds[1] + bounds[3]) * ih) + margin) - y
        let scale = min(1, sqrt(24_576 / (sw * sh)))
        let width = max(1, Int(floor(sw * scale))), height = max(1, Int(floor(sh * scale)))
        guard width * height <= 24_576 else { throw DiagnosticError.invalidSource }
        let queries: [[String: Any]] = [
            ["id": "sampler-base", "rect": [x,y,sw,sh], "size": [width,height]],
            ["id": "source-top", "rect": [x,y,24.0,24.0], "size": [24,24]],
            ["id": "source-middle", "rect": [floor(x + sw / 2 - 12),floor(y + sh / 2 - 12),24.0,24.0], "size": [24,24]],
            ["id": "source-bottom", "rect": [x + sw - 24,y + sh - 24,24.0,24.0], "size": [24,24]]
        ]
        var native: [[UInt8]] = []
        for q in queries {
            let r = q["rect"] as! [Double], size = q["size"] as! [Int]
            native.append(try NativeSourcePixelReader.draw(image: prepared,x: r[0],y: r[1],sourceWidth: r[2],sourceHeight: r[3],width: size[0],height: size[1]))
        }
        let provider = CGDataProvider(data: Data(native[0]) as CFData)!
        let crop = CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: provider,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
        guard let png = UIImage(cgImage: crop).pngData() else { throw DiagnosticError.invalidSource }
        let script = """
        const image=document.getElementById('reader-source-image');
        if(!image?.complete||!image.naturalWidth)throw Error('frozen source image unavailable');
        const rows=[];
        for(const q of queries){const [x,y,sw,sh]=q.rect,[w,h]=q.size,c=document.createElement('canvas');c.width=w;c.height=h;
          const context=c.getContext('2d',{willReadFrequently:true});context.drawImage(image,x,y,sw,sh,0,0,w,h);
          rows.push({id:q.id,rgba:Array.from(context.getImageData(0,0,w,h).data)});}
        const roundtrip=new Image();roundtrip.src='data:image/png;base64,'+nativeCropPNG;await roundtrip.decode();
        const c=document.createElement('canvas');c.width=roundtrip.naturalWidth;c.height=roundtrip.naturalHeight;
        const context=c.getContext('2d',{willReadFrequently:true});context.drawImage(roundtrip,0,0);
        return JSON.stringify({sourceSize:[image.naturalWidth,image.naturalHeight],rows,
          roundtrip:Array.from(context.getImageData(0,0,c.width,c.height).data),userAgent:navigator.userAgent,dpr:devicePixelRatio});
        """
        let raw = try await webView.callAsyncJavaScript(script,arguments: ["queries": queries,"nativeCropPNG": png.base64EncodedString()],in: nil,contentWorld: ReaderTranslationDOM.contentWorld)
        guard let text = raw as? String, let captured = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
              let rows = captured["rows"] as? [[String: Any]], rows.count == queries.count,
              let roundtrip = captured["roundtrip"] as? [UInt8] else { throw DiagnosticError.invalidCapture }
        var result: [[String: Any]] = []
        for i in queries.indices {
            guard let rgba = rows[i]["rgba"] as? [UInt8] else { throw DiagnosticError.invalidCapture }
            var row = compare(native[i],rgba);row["id"] = queries[i]["id"];row["rect"] = queries[i]["rect"];row["size"] = queries[i]["size"]
            result.append(row)
        }
        let report: [String: Any] = ["fixture": fixtureID,"item": "7","bounds": bounds,"preparedSourceSize": [prepared.width,prepared.height],
            "webSourceSize": captured["sourceSize"]!,"preparedColorSpace": prepared.colorSpace?.name.map { $0 as String } as Any? ?? NSNull(),
            "preparedBitsPerComponent": prepared.bitsPerComponent,"preparedBitmapInfo": prepared.bitmapInfo.rawValue,
            "queryPixelTotal": width * height + 3 * 24 * 24,"rows": result,"nativeCropPNGRoundtrip": compare(native[0],roundtrip),
            "userAgent": captured["userAgent"]!,"dpr": captured["dpr"]!,
            "scope": "iOS prepared4MP UIImage CGImage versus existing frozen PNG source Canvas. Detached bounded source crops only; final renderer and source DOM stay untouched."]
        try JSONSerialization.data(withJSONObject: report,options: [.sortedKeys,.prettyPrinted]).write(to: output.appendingPathComponent("source-canvas-item-7.json"))
    }
    private static func captureForced(image: UIImage, webView: WKWebView, output: URL) async throws {
        let items = try JSONSerialization.jsonObject(with: Data(contentsOf: output.appendingPathComponent("web-layout.json"))) as! [[String: Any]]
        guard let prepared = try ReaderTranslationBackgroundImage.prepare(image).cgImage else { throw DiagnosticError.invalidSource }
        let iw = Double(prepared.width), ih = Double(prepared.height)
        // Each await compares one original forced crop. No full-page getImageData
        // or simultaneous native crop arrays are retained for this diagnostic.
        for id in ["4", "14"] {
            guard let item = items.first(where: { $0["id"] as? String == id }),
                  let bounds = item["sourceBounds"] as? [Double], bounds.count == 4,
                  let frame = item["sourceFrame"] as? [Double], frame.count == 4, frame[2] > 0 else { throw DiagnosticError.invalidSource }
            let sourceFont = (item["sourceFontSize"] as? NSNumber)?.doubleValue ?? 8
            let font = sourceFont == 0 || sourceFont.isNaN ? 8 : sourceFont
            let glyph = max(8, font * iw / frame[2]), pad = max(32, min(160, glyph * 2.5))
            let x = max(0, floor(bounds[0] * iw - pad)), y = max(0, floor(bounds[1] * ih - pad))
            let right = min(iw, ceil((bounds[0] + bounds[2]) * iw + pad))
            let bottom = min(ih, ceil((bounds[1] + bounds[3]) * ih + pad))
            let width = Int(right - x), height = Int(bottom - y)
            guard width > 0, height > 0, width * height * 4 <= 1_000_000 else { throw DiagnosticError.invalidSource }
            let native = try NativeSourcePixelReader.draw(image: prepared, x: x, y: y, sourceWidth: Double(width), sourceHeight: Double(height), width: width, height: height)
            let script = """
            const image=document.getElementById('reader-source-image');
            if(!image?.complete||!image.naturalWidth)throw Error('frozen source image unavailable');
            const c=document.createElement('canvas');c.width=width;c.height=height;
            const context=c.getContext('2d',{willReadFrequently:true});context.drawImage(image,x,y,width,height,0,0,width,height);
            return JSON.stringify({sourceSize:[image.naturalWidth,image.naturalHeight],rgba:Array.from(context.getImageData(0,0,width,height).data),userAgent:navigator.userAgent});
            """
            let raw = try await webView.callAsyncJavaScript(script, arguments: ["x": x,"y": y,"width": width,"height": height], in: nil, contentWorld: ReaderTranslationDOM.contentWorld)
            guard let text = raw as? String, let captured = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any],
                  let rgba = captured["rgba"] as? [UInt8] else { throw DiagnosticError.invalidCapture }
            var report = compare(native, rgba)
            report["fixture"] = "real-comic-0025"; report["item"] = id; report["sourceBounds"] = bounds
            report["sourceFrame"] = frame; report["sourceFont"] = font; report["glyph"] = glyph; report["padding"] = pad
            report["rect"] = [x,y,Double(width),Double(height)]; report["size"] = [width,height]
            report["preparedSourceSize"] = [prepared.width,prepared.height]; report["webSourceSize"] = captured["sourceSize"]
            report["userAgent"] = captured["userAgent"]
            report["scope"] = "Original forced crop scale1, same prepared source; detached scratch Canvas source-only byte diagnostic. No donor/restoration thresholds changed."
            try JSONSerialization.data(withJSONObject: report, options: [.sortedKeys,.prettyPrinted]).write(to: output.appendingPathComponent("source-canvas-forced-item-\(id).json"))
        }
    }

    private static func compare(_ native: [UInt8], _ web: [UInt8]) -> [String: Any] {
        guard native.count == web.count else { return ["exact": false,"nativeBytes": native.count,"webBytes": web.count] }
        let changed = native.indices.filter { native[$0] != web[$0] }
        return ["exact": changed.isEmpty,"bytes": native.count,"changedBytes": changed.count,"changedPixels": Set(changed.map { $0 / 4 }).count,
            "maximumDelta": changed.map { abs(Int(native[$0])-Int(web[$0])) }.max() ?? 0,
            "nativeSHA256": SHA256.hash(data: Data(native)).map { String(format: "%02x",$0) }.joined(),
            "webSHA256": SHA256.hash(data: Data(web)).map { String(format: "%02x",$0) }.joined(),
            "firstDifferences": Array(changed.prefix(24)).map { ["byte": $0,"pixel": $0 / 4,"channel": $0 % 4,"native": Int(native[$0]),"web": Int(web[$0])] },
            "nativeRGBA": Data(native).base64EncodedString(),"webRGBA": Data(web).base64EncodedString()]
    }
    private enum DiagnosticError: Error { case invalidSource, invalidCapture }
}
