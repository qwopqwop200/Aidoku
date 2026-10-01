import Testing
import UIKit
import WebKit
import CoreText
import CryptoKit
@testable import Aidoku

/// A separate actual-iOS font/paint gate. macOS font observations cannot establish
/// an iOS defect. Captures production typography once for each original CSS scene.
@MainActor
struct NativeHanPDFPaintParityCapture {
    func run() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        window.makeKeyAndVisible()
        window.frame = CGRect(x: 0, y: 0, width: 390, height: 700)
        defer { window.isHidden = true }
        let view = WKWebView(frame: window.bounds)
        view.overrideUserInterfaceStyle = .light
        let host = try #require(window.rootViewController?.view)
        host.frame = window.bounds
        host.insertSubview(view, at: 0)
        defer { view.stopLoading(); view.removeFromSuperview() }
        let waiter = HanPaintNavigationWaiter()
        try await waiter.load(in: view)
        let directory = URL.documentsDirectory.appendingPathComponent("NativeHanPDFPaintParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: ["passed": false, "expectedCount": 3, "reports": []] as [String: Any])
            .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        let text = "天地玄黄宇宙洪荒"
        var reports: [[String: Any]] = []
        var failures: [String] = []
        for tracking in [-1, 0, 1] {
            let output = directory.appendingPathComponent(String(tracking), isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let script = "document.body.replaceChildren(); await document.fonts.ready; return " + Self.captureScript
            let raw = try await view.callAsyncJavaScript(script, arguments: ["tracking": tracking], in: nil, contentWorld: .page)
            let webGeometry = try #require(raw as? String)
            try Data(webGeometry.utf8).write(to: output.appendingPathComponent("web-layout.json"))
            let configuration = WKPDFConfiguration()
            configuration.rect = CGRect(x: 0, y: 0, width: 390, height: 700)
            let webPDF: Data = try await withCheckedThrowingContinuation { continuation in
                view.createPDF(configuration: configuration) { continuation.resume(with: $0) }
            }
            let style = NativeTranslationTypography.Style(fontName: "PingFangSC-Semibold", fontScript: "han",
                fontSize: 20, bold: true, vertical: true, tracking: CGFloat(tracking), lineHeight: 24,
                alignsToTop: false, strictLineBreak: true)
            let layout = NativeTranslationTypography.layout(text: text, in: CGSize(width: 94, height: 154), style: style)
            #expect(layout.shapedText == text)
            #expect(layout.visibleUTF16Range == NSRange(location: 0, length: (text as NSString).length))
            let nativeCapture = try NativeTranslationPDFCapture.capture(bounds: CGRect(x: 0, y: 0, width: 390, height: 700),
                pixels: CGSize(width: 780, height: 1400), deviceScale: view.window?.screen.scale ?? 1) { context in
                context.setFillColor(CGColor(gray: 1, alpha: 1))
                context.fill(CGRect(x: 0, y: 0, width: 390, height: 700))
                NativeTranslationTypography.draw(layout: layout, in: context, at: CGPoint(x: 3, y: 3),
                                                 pixelSnapScale: view.window?.screen.scale ?? 1)
            }
            let nativePDF = nativeCapture.data
            try webPDF.write(to: output.appendingPathComponent("web.pdf"))
            try nativePDF.write(to: output.appendingPathComponent("native.pdf"))
            let web = try raster(webPDF), native = try raster(nativePDF)
            try web.bytes.write(to: output.appendingPathComponent("web.rgba"))
            try native.bytes.write(to: output.appendingPathComponent("native.rgba"))
            try #require(UIImage(cgImage: web.image).pngData()).write(to: output.appendingPathComponent("web.png"))
            try #require(UIImage(cgImage: native.image).pngData()).write(to: output.appendingPathComponent("native.png"))
            var changed = 0, delta = 0, darkWeb = 0, darkNative = 0
            let left = [UInt8](web.bytes), right = [UInt8](native.bytes)
            #expect(left.count == 780 * 1400 * 4 && left.count == right.count)
            for pixel in stride(from: 0, to: left.count, by: 4) {
                if left[pixel..<pixel+4] != right[pixel..<pixel+4] { changed += 1 }
                if left[pixel] < 128 { darkWeb += 1 }
                if right[pixel] < 128 { darkNative += 1 }
                for channel in 0..<4 { delta = max(delta, abs(Int(left[pixel+channel]) - Int(right[pixel+channel]))) }
            }
            #expect(darkWeb > 0 && darkNative > 0)
            let nativeGeometry: [String: Any] = ["lineCount": layout.lineCount,
                "lineAdvances": NativeTranslationTypography.verticalLineAdvances(layout: layout),
                "coreTextRows": NativeTranslationTypography.diagnosticRuns(layout: layout),
                "rangeBounds": layout.rangeBounds.map { [$0.minX+3, $0.minY+3, $0.width, $0.height] },
                "glyphBounds": layout.glyphBounds.map { [$0.minX+3, $0.minY+3, $0.width, $0.height] },
                "rawText": text, "tracking": tracking, "fontName": "PingFangSC-Semibold", "fontSize": 20, "pitch": 24]
            try JSONSerialization.data(withJSONObject: nativeGeometry, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("native-layout.json"))
            let webResources = HanPaintPDFResources.capture(webPDF, into: output, prefix: "web")
            let nativeResources = HanPaintPDFResources.capture(nativePDF, into: output, prefix: "native")
            #expect(!webResources.isEmpty && !nativeResources.isEmpty)
            #expect((webResources + nativeResources).allSatisfy { $0["error"] == nil && $0["ToUnicode"] != nil })
            let resourceReport: [String: Any] = ["web": webResources,
                "native": nativeResources,
                "namedFontLookupControl": fontLookupControl(text: text),
                "primaryMetricControls": primaryMetricControls()]
            try JSONSerialization.data(withJSONObject: resourceReport, options: [.prettyPrinted, .sortedKeys])
                .write(to: output.appendingPathComponent("font-resources.json"))
            reports.append(["tracking": tracking, "pixels": 780*1400, "changedPixels": changed,
                            "maxChannelDelta": delta, "webDarkPixels": darkWeb, "nativeDarkPixels": darkNative])
            if changed != 0 { failures.append("tracking \(tracking): \(changed) decoded RGBA pixels differ") }
            let summary: [String: Any] = ["scope": "actual-iOS production typography vs original scoped CSS; no macOS inference",
                "os": UIDevice.current.systemVersion, "device": UIDevice.current.model,
                "screenScale": view.window?.screen.scale ?? 1, "rawText": text, "reports": reports,
                "passed": reports.count == 3 && failures.isEmpty]
            try JSONSerialization.data(withJSONObject: summary, options: [.prettyPrinted, .sortedKeys])
                .write(to: directory.appendingPathComponent("report.json"), options: .atomic)
        }
        #expect(reports.count == 3)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    private func raster(_ bytes: Data) throws -> (image: CGImage, bytes: Data) {
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        let document = try #require(CGPDFDocument(provider)), page = try #require(document.page(at: 1))
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB))
        let context = try #require(CGContext(data: nil, width: 780, height: 1400, bitsPerComponent: 8, bytesPerRow: 780*4,
            space: space, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 780, height: 1400))
        context.scaleBy(x: 2, y: 2); context.drawPDFPage(page)
        return (try #require(context.makeImage()), Data(bytes: try #require(context.data), count: 780*1400*4))
    }

    /// An explicit separate public-font lookup control, not a claim that this is
    /// the private font instance inside the production layout or WK process.
    private func fontLookupControl(text: String) -> [String: Any] {
        let base = CTFontCreateWithName("PingFangSC-Semibold" as CFString, 20, nil)
        let value = NSAttributedString(string: text, attributes: [NSAttributedString.Key(kCTFontAttributeName as String): base,
            NSAttributedString.Key(kCTVerticalFormsAttributeName as String): true])
        let line = CTLineCreateWithAttributedString(value)
        var records: [[String: Any]] = []
        for run in CTLineGetGlyphRuns(line) as! [CTRun] {
            let attributes = CTRunGetAttributes(run) as NSDictionary
            let font = attributes[kCTFontAttributeName] as! CTFont
            var glyphs = [CGGlyph](repeating: 0, count: CTRunGetGlyphCount(run))
            CTRunGetGlyphs(run, CFRange(location: 0, length: 0), &glyphs)
            let paths: [[String: Any]] = glyphs.map { glyph in
                var commands: [[String: Any]] = []
                CTFontCreatePathForGlyph(font, glyph, nil)?.applyWithBlock { element in
                    let value = element.pointee
                    let count: Int
                    switch value.type {
                    case .moveToPoint, .addLineToPoint: count = 1
                    case .addQuadCurveToPoint: count = 2
                    case .addCurveToPoint: count = 3
                    case .closeSubpath: count = 0
                    @unknown default: count = 0
                    }
                    commands.append(["kind": value.type.rawValue, "points": (0..<count).map { [value.points[$0].x, value.points[$0].y] }])
                }
                return ["glyph": glyph, "commands": commands]
            }
            records.append(["postScriptName": CTFontCopyPostScriptName(font) as String,
                "graphicsFontName": CTFontCopyGraphicsFont(font, nil).postScriptName.map { $0 as String } ?? "",
                "glyphCount": CTFontGetGlyphCount(font), "URL": String(describing: CTFontCopyAttribute(font, kCTFontURLAttribute)),
                "descriptor": String(describing: CTFontDescriptorCopyAttributes(CTFontCopyFontDescriptor(font))), "paths": paths])
        }
        return ["scope": "separate named-font/CoreText-run lookup control", "runs": records]
    }

    private func primaryMetricControls() -> [[String: Any]] {
        [("PingFangSC-Semibold", [19.0, 20.0, 20.5, 21.0]), ("HiraginoSans-W8", [10.5, 20.0])].flatMap { name, sizes in
            sizes.map { size in
                let font = CTFontCreateWithName(name as CFString, CGFloat(size), nil)
                let uiFont = UIFont(name: name, size: CGFloat(size))
                return ["requestedName": name, "size": size, "selectedName": CTFontCopyPostScriptName(font) as String,
                    "ascent": CTFontGetAscent(font), "descent": CTFontGetDescent(font), "leading": CTFontGetLeading(font),
                    "uiAscent": uiFont.map { Double($0.ascender) } as Any? ?? NSNull(),
                    "uiDescent": uiFont.map { Double(-$0.descender) } as Any? ?? NSNull()]
            }
        }
    }

    private static let captureScript = #"""
(()=>{
 const jobs=[{"script": "han", "text": "天地玄黄宇宙洪荒", "font": 20, "pitch": 24, "width": 100, "height": 160, "pads": [3, 3, 3, 3], "clips": false, "balanced": false, "tracking": tracking}];
 return JSON.stringify(jobs.map(a=>{
 const node=document.createElement('div'),item={clipsText:a.clips,balancedColumn:a.balanced};
 const x=0,y=0,scrollX=0,scrollY=0,width=a.width,height=a.height,fontSize=a.font,lineHeight=a.pitch;
 const paddingTop=a.pads[0],paddingRight=a.pads[1],paddingBottom=a.pads[2],paddingLeft=a.pads[3];
 const vertical=true,wrappingScript=a.script==='korean'?'korean':'cjk',displayedText=a.text;
 const fontFamily=a.script==='japanese'?"'Hiragino Sans','YuGothic','Noto Sans CJK JP',-apple-system,BlinkMacSystemFont,sans-serif":a.script==='han'?"'PingFang SC','PingFang TC','Noto Sans CJK SC',-apple-system,BlinkMacSystemFont,sans-serif":"'Apple SD Gothic Neo','Noto Sans CJK KR','Noto Sans KR',-apple-system,BlinkMacSystemFont,sans-serif";
 const surfaceGradient=null,surface='255,255,255',opacity=1,sampledBackground=null,veil='255,255,255',veilAlpha=.42,foreground='0,0,0';
        Object.assign(node.style, {
          position: 'absolute',
          zIndex: '2',
          left: `${x + scrollX}px`,
          top: `${y + scrollY}px`,
          width: `${width}px`, height: `${height}px`,
          boxSizing: 'border-box',
          overflow: Boolean(item.clipsText) ? 'hidden' : 'visible',
          display: 'flex', alignItems: 'center', justifyContent: 'center',
          padding: `${paddingTop}px ${paddingRight}px ` +
            `${paddingBottom}px ${paddingLeft}px`,
          margin: '0', borderRadius: '6px',
          border: '0',
          backgroundColor: surfaceGradient ? 'transparent' : `rgba(${surface},${opacity})`,
          backgroundImage: surfaceGradient || (sampledBackground ? 'none' :
            `linear-gradient(rgba(${veil},${veilAlpha}),` +
            `rgba(${veil},${veilAlpha}))`),
          color: `rgb(${foreground})`,
          fontFamily,
          fontWeight: vertical ? '800' : '700',
          fontSize: `${fontSize}px`,
          lineHeight: `${Math.max(fontSize, lineHeight)}px`,
          letterSpacing:`${a.tracking}px`, textAlign: 'center',
          webkitTextStroke: '0px transparent', paintOrder: 'normal',
          textShadow: 'none',
          boxShadow: 'none',
          backdropFilter: 'none', webkitBackdropFilter: 'none',
          webkitTextSizeAdjust: 'none', textSizeAdjust: 'none',
          contain: 'layout style',
          whiteSpace: 'pre-wrap', overflowWrap: 'anywhere',
          wordBreak: wrappingScript === 'korean' ? 'keep-all' : 'normal',
          // Balance short Korean dialogue without changing its words or card.
          // The cloned measurement node uses the same policy during font fitting.
          textWrap: !vertical && wrappingScript === 'korean' &&
            displayedText.length <= 180 && !/[\\r\\n]/.test(displayedText)
              ? 'balance' : 'wrap',
          lineBreak: wrappingScript === 'cjk' ? 'strict' : 'auto',
          hyphens: wrappingScript === 'word' ? 'auto' : 'manual',
          direction: wrappingScript === 'rightToLeft' ? 'rtl' : 'ltr',
          unicodeBidi: 'plaintext',
          writingMode: vertical ? 'vertical-rl' : 'horizontal-tb',
          textOrientation: 'mixed'
        });
 if(item.balancedColumn)node.style.alignItems='flex-start';
 node.textContent=a.text;document.body.append(node);
 const c=getComputedStyle(node),r=node.getBoundingClientRect(),range=document.createRange();range.selectNodeContents(node);
 const lines=Array.from(range.getClientRects(),r=>[r.x,r.y,r.width,r.height]);
 const chars=[];for(let i=0;i<a.text.length;i++){range.setStart(node.firstChild,i);range.setEnd(node.firstChild,i+1);let rr=range.getBoundingClientRect();chars.push([a.text[i],rr.x,rr.y,rr.width,rr.height]);}
 const clone=node.cloneNode(false),child=document.createElement('span');child.textContent=a.text;clone.append(child);document.body.append(clone);const childBox=child.getBoundingClientRect();const itemBox=[childBox.x,childBox.y,childBox.width,childBox.height];clone.remove();
 // Read-only primary-font observations; the unattached canvas never changes page paint.
 const canvas=document.createElement('canvas'),ctx=canvas.getContext('2d');ctx.font=`800 ${a.font}px ${fontFamily}`;ctx.fontKerning='auto';ctx.textBaseline='alphabetic';ctx.textAlign='left';
 const fontMetrics=text=>{const m=ctx.measureText(text);return {requested:ctx.font,fontBoundingBoxAscent:m.fontBoundingBoxAscent,fontBoundingBoxDescent:m.fontBoundingBoxDescent,emHeightAscent:m.emHeightAscent,emHeightDescent:m.emHeightDescent,actualBoundingBoxAscent:m.actualBoundingBoxAscent,actualBoundingBoxDescent:m.actualBoundingBoxDescent,width:m.width};};
 const canvasFontMetrics=fontMetrics(a.text),canvasSingleGlyphFontMetrics=fontMetrics('天');
 const primaryMetricControls=[['han',fontFamily,[19,20,20.5,21],'天地玄黄宇宙洪荒'],['japanese',"'Hiragino Sans','YuGothic','Noto Sans CJK JP',-apple-system,BlinkMacSystemFont,sans-serif",[10.5,20],'日本語']].flatMap(([script,family,sizes,text])=>sizes.map(size=>{ctx.font=`800 ${size}px ${family}`;return {script,size,text,...fontMetrics(text)};}));
 const result={a,itemBox,client:[node.clientWidth,node.clientHeight],scroll:[node.scrollWidth,node.scrollHeight],box:[r.x,r.y,r.width,r.height],padding:[c.paddingTop,c.paddingRight,c.paddingBottom,c.paddingLeft].map(parseFloat),font:c.font,pitch:parseFloat(c.lineHeight),lines,chars,canvasFontMetrics,canvasSingleGlyphFontMetrics,primaryMetricControls};return result;
 }));})()

"""#
}

@MainActor
private final class HanPaintNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(in view: WKWebView) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'><style>html,body{margin:0;background:white}</style></head><body></body></html>", baseURL: nil)
        }
    }
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}

private final class HanPaintFontKeySink { var names: [String] = [] }
private enum HanPaintPDFResources {
    static func capture(_ data: Data, into output: URL, prefix: String) -> [[String: Any]] {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1), let root = page.dictionary else { return [["error": "missing PDF page"]] }
        var resources: CGPDFDictionaryRef?, fonts: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(root, "Resources", &resources), let resources,
              CGPDFDictionaryGetDictionary(resources, "Font", &fonts), let fonts else { return [["error": "missing font resources"]] }
        let sink = HanPaintFontKeySink()
        CGPDFDictionaryApplyFunction(fonts, { key, _, info in
            guard let info else { return }
            Unmanaged<HanPaintFontKeySink>.fromOpaque(info).takeUnretainedValue().names.append(String(cString: key))
        }, Unmanaged.passUnretained(sink).toOpaque())
        return sink.names.sorted().enumerated().map { index, key in
            var font: CGPDFDictionaryRef?
            guard key.withCString({ CGPDFDictionaryGetDictionary(fonts, $0, &font) }), let font else { return ["error": "missing font dictionary"] }
            func name(_ dictionary: CGPDFDictionaryRef, _ key: String) -> String {
                var raw: UnsafePointer<CChar>?
                return key.withCString { CGPDFDictionaryGetName(dictionary, $0, &raw) } ? raw.map { String(cString: $0) } ?? "" : ""
            }
            var row: [String: Any] = ["resource": key, "baseFont": name(font, "BaseFont"), "subtype": name(font, "Subtype")]
            func stream(_ dictionary: CGPDFDictionaryRef, _ key: String, _ file: String) {
                var value: CGPDFStreamRef?
                guard key.withCString({ CGPDFDictionaryGetStream(dictionary, $0, &value) }), let value else { return }
                var format: CGPDFDataFormat = .raw
                guard let bytes = CGPDFStreamCopyData(value, &format) as Data? else { return }
                do { try bytes.write(to: output.appendingPathComponent(file)); row[key] = ["file": file, "bytes": bytes.count,
                        "SHA256": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()] }
                catch { row[key] = ["error": String(describing: error)] }
            }
            stream(font, "ToUnicode", "\(prefix)-font-\(index)-unicode.txt")
            var descendant = font, array: CGPDFArrayRef?, child: CGPDFDictionaryRef?
            if CGPDFDictionaryGetArray(font, "DescendantFonts", &array), let array,
               CGPDFArrayGetDictionary(array, 0, &child), let child { descendant = child }
            var descriptor: CGPDFDictionaryRef?
            if CGPDFDictionaryGetDictionary(descendant, "FontDescriptor", &descriptor), let descriptor {
                row["descriptorFontName"] = name(descriptor, "FontName")
                for format in ["FontFile", "FontFile2", "FontFile3"] {
                    stream(descriptor, format, "\(prefix)-font-\(index)-\(format).bin")
                }
            }
            return row
        }
    }
}
