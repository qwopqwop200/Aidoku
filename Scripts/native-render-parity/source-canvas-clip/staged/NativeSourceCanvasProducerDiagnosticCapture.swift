import Testing
import UIKit
import WebKit
import CryptoKit

/// Six producer/readback observations. Control/source completeness is asserted;
/// cross-mode pixel equality is descriptive, separate from the strict alpha gate.
@MainActor
struct NativeSourceCanvasProducerDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let sourceHash = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
    private enum Failure: Error { case invalidSource, invalidCapture, invalidPixels }
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    func run() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasProducerDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 6, "count": 0, "passed": false, "pixelParityAsserted": false,
                       "reports": []], to: directory.appendingPathComponent("report.json"))
        let bundle = Bundle(for: SourceCanvasProducerFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "NativeCanvasActual44Mask0", withExtension: "bin"))
        let source = try Data(contentsOf: url), image = try #require(UIImage(data: source)?.cgImage)
        let fixtureValid = hash(source) == sourceHash && image.width == 412 && image.height == 527
        try writeJSON(["expectedSHA256": sourceHash, "actualSHA256": hash(source), "bytes": source.count,
                       "decodedDimensions": [image.width, image.height], "sourceValid": fixtureValid],
                      to: directory.appendingPathComponent("fixture-provenance.json"))
        #expect(fixtureValid)
        guard fixtureValid else { throw Failure.invalidSource }
        try source.write(to: directory.appendingPathComponent("immutable-actual44-mask0.png"))
        let sourcePixels = try pixels(image)
        try sourcePixels.bytes.write(to: directory.appendingPathComponent("immutable-actual44-mask0.rgba"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .clear; window.frame = page; window.makeKeyAndVisible(); window.frame = page
        defer { window.isHidden = true }
        let host = try #require(window.rootViewController?.view); host.frame = page; host.backgroundColor = .clear
        let web = WKWebView(frame: page)
        web.overrideUserInterfaceStyle = .light; web.isOpaque = false; web.backgroundColor = .clear
        web.underPageBackgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        host.addSubview(web); defer { web.stopLoading(); web.removeFromSuperview() }
        let waiter = SourceCanvasProducerNavigationWaiter(); try await waiter.load(in: web)
        var reports: [[String: Any]] = [], failures: [String] = [], comparisons: [[String: Any]] = []
        for background in ["transparent", "opaque"] {
            let output = directory.appendingPathComponent(background, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var captures: [String: Pixels] = [:]
            for mode in ["A-draw-before", "B-draw-after", "C-put-before"] {
                do {
                    let raw = try await web.callAsyncJavaScript(Self.script,
                        arguments: ["background": background, "mode": mode,
                                    "originalPNG": "data:image/png;base64," + source.base64EncodedString()],
                        in: nil, contentWorld: .page)
                    guard let json = raw as? String,
                          let dom = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                          let encoded = dom["png"] as? String, let comma = encoded.firstIndex(of: ","),
                          let canvasPNG = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                          let canvasImage = UIImage(data: canvasPNG)?.cgImage else { throw Failure.invalidCapture }
                    try Data(json.utf8).write(to: output.appendingPathComponent(mode + "-dom.json"))
                    try canvasPNG.write(to: output.appendingPathComponent(mode + "-source-canvas.png"))
                    let canvasPixels = try pixels(canvasImage)
                    try canvasPixels.bytes.write(to: output.appendingPathComponent(mode + "-source-canvas.rgba"))
                    let sourceMatches = canvasPixels.width == 412 && canvasPixels.height == 527 && canvasPixels.bytes == sourcePixels.bytes
                    var conversionMatches: Any = NSNull()
                    if mode == "C-put-before" {
                        guard let text = dom["convertedRGBA"] as? String, let converted = Data(base64Encoded: text) else { throw Failure.invalidCapture }
                        try converted.write(to: output.appendingPathComponent(mode + "-conversion.rgba"))
                        conversionMatches = converted == sourcePixels.bytes
                        if converted != sourcePixels.bytes { failures.append("\(background)/\(mode): offscreen conversion changed canonical binary-alpha source") }
                    }
                    if !sourceMatches { failures.append("\(background)/\(mode): target source buffer changed") }
                    let configuration = WKSnapshotConfiguration(); configuration.rect = page; configuration.snapshotWidth = 320
                    let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                        web.takeSnapshot(with: configuration) { result, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let result { continuation.resume(returning: result) }
                            else { continuation.resume(throwing: Failure.invalidCapture) }
                        }
                    }
                    let captured = try save(try #require(snapshot.cgImage), prefix: mode, output: output)
                    captures[mode] = captured
                    let dimensionsValid = captured.width == Int((page.width * window.screen.scale).rounded()) &&
                        captured.height == Int((page.height * window.screen.scale).rounded())
                    if !dimensionsValid { failures.append("\(background)/\(mode): invalid capture dimensions") }
                    let record: [String: Any] = ["background": background, "mode": mode,
                        "width": captured.width, "height": captured.height, "dimensionsValid": dimensionsValid,
                        "UIImageScale": snapshot.scale, "UIImageOrientation": snapshot.imageOrientation.rawValue,
                        "RGBAHash": hash(captured.bytes), "sourceCanonicalRGBAEqual": sourceMatches,
                        "sourceCanonicalRGBAHash": hash(canvasPixels.bytes), "conversionCanonicalRGBAEqual": conversionMatches,
                        "canvasPNGHash": hash(canvasPNG), "contextAttributes": dom["contextAttributes"] ?? NSNull(),
                        "readbackTiming": dom["readbackTiming"] ?? NSNull(), "producer": dom["producer"] ?? NSNull(),
                        "events": dom["events"] ?? NSNull(), "viewport": viewport(web, window: window)]
                    reports.append(record); try writeJSON(record, to: output.appendingPathComponent(mode + "-capture.json"))
                } catch { failures.append("\(background)/\(mode): \(error)") }
            }
            if let a = captures["A-draw-before"] {
                for mode in ["B-draw-after", "C-put-before"] { if let b = captures[mode] {
                    var comparison = compare(a, b); comparison["background"] = background
                    comparison["referenceMode"] = "A-draw-before"; comparison["comparedMode"] = mode
                    comparison["scope"] = "descriptive only; no pixel acceptance assertion"
                    comparisons.append(comparison)
                } }
            }
        }
        try writeJSON(["expectedCount": 6, "count": reports.count, "passed": reports.count == 6 && failures.isEmpty,
            "pixelParityAsserted": false, "scope": "producer/readback timing observations; strict alpha4 unchanged",
            "originalMaskPNGHash": sourceHash, "canvasFrame": [135, 7, 91, 121], "intrinsicCanvasSize": [412, 527],
            "sourceCanonicalRGBAHash": hash(sourcePixels.bytes), "screenScale": window.screen.scale,
            "os": UIDevice.current.systemVersion, "reports": reports, "descriptiveComparisons": comparisons,
            "failures": failures], to: directory.appendingPathComponent("report.json"))
        #expect(reports.count == 6)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
    private func viewport(_ view: WKWebView, window: UIWindow) -> [String: Any] {
        ["bounds": rectValues(view.bounds), "screenScale": window.screen.scale,
         "safeArea": [view.safeAreaInsets.top, view.safeAreaInsets.right, view.safeAreaInsets.bottom, view.safeAreaInsets.left],
         "contentInset": [view.scrollView.contentInset.top, view.scrollView.contentInset.right, view.scrollView.contentInset.bottom, view.scrollView.contentInset.left],
         "adjustedContentInset": [view.scrollView.adjustedContentInset.top, view.scrollView.adjustedContentInset.right, view.scrollView.adjustedContentInset.bottom, view.scrollView.adjustedContentInset.left],
         "contentOffset": [view.scrollView.contentOffset.x, view.scrollView.contentOffset.y], "view": layerMetadata(view)]
    }
    private func layerMetadata(_ view: UIView) -> [String: Any] {
        ["frame": rectValues(view.frame), "bounds": rectValues(view.bounds), "contentScaleFactor": view.contentScaleFactor,
         "layerFrame": rectValues(view.layer.frame), "layerBounds": rectValues(view.layer.bounds),
         "contentsScale": view.layer.contentsScale, "rasterizationScale": view.layer.rasterizationScale,
         "shouldRasterize": view.layer.shouldRasterize, "opaque": view.isOpaque]
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: image.width * 4, space: space,
                                      bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw Failure.invalidPixels }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return .init(width: image.width, height: image.height, bytes: Data(bytes: data, count: image.width * image.height * 4))
    }
    private func save(_ image: CGImage, prefix: String, output: URL) throws -> Pixels {
        guard let png = UIImage(cgImage: image).pngData() else { throw Failure.invalidCapture }
        try png.write(to: output.appendingPathComponent(prefix + ".png"))
        let result = try pixels(image); try result.bytes.write(to: output.appendingPathComponent(prefix + ".rgba"))
        return result
    }
    private func compare(_ web: Pixels, _ native: Pixels) -> [String: Any] {
        guard web.width == native.width, web.height == native.height else {
            return ["exactRGBA": false, "webSize": [web.width, web.height], "nativeSize": [native.width, native.height]]
        }
        var changed = 0, maximum = 0
        web.bytes.withUnsafeBytes { a in native.bytes.withUnsafeBytes { b in
            let lhs = a.bindMemory(to: UInt8.self), rhs = b.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: web.bytes.count, by: 4) {
                var differs = false
                for c in 0..<4 { let d = abs(Int(lhs[offset + c]) - Int(rhs[offset + c])); maximum = max(maximum, d); differs = differs || d != 0 }
                if differs { changed += 1 }
            }
        } }
        return ["exactRGBA": changed == 0, "changedPixels": changed, "maxChannelDelta": maximum,
                "webRGBAHash": hash(web.bytes), "nativeRGBAHash": hash(native.bytes)]
    }
    private func rectValues(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func writeJSON(_ value: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
    private static let script = #"""
    if(!['A-draw-before','B-draw-after','C-put-before'].includes(mode))throw new Error('unknown producer control');
    document.body.replaceChildren();document.documentElement.style.background='transparent';
    document.body.style.background=background==='opaque'?'rgb(41,65,87)':'transparent';
    const events=[],mark=label=>events.push({label,time:performance.now()});
    const image=new Image();image.src=originalPNG;await image.decode();mark('source-image-decoded');
    let convertedRGBA=null,conversionAttributes=null;
    if(mode==='C-put-before'){
      const conversion=document.createElement('canvas');conversion.width=412;conversion.height=527;
      const read=conversion.getContext('2d',{willReadFrequently:true});read.drawImage(image,0,0,412,527);
      convertedRGBA=read.getImageData(0,0,412,527);conversionAttributes=read.getContextAttributes?.()??null;
      mark('offscreen-conversion-getImageData-complete');
    }
    const canvas=document.createElement('canvas');canvas.width=412;canvas.height=527;
    Object.assign(canvas.style,{position:'absolute',left:'135px',top:'7px',width:'91px',height:'121px'});
    const context=canvas.getContext('2d');
    if(convertedRGBA)context.putImageData(convertedRGBA,0,0);else context.drawImage(image,0,0,412,527);
    mark('target-populated');document.body.appendChild(canvas);mark('target-appended');
    let png;
    if(mode!=='B-draw-after'){png=canvas.toDataURL('image/png');mark('target-toDataURL-before-RAF');}
    await new Promise(resolve=>requestAnimationFrame(()=>{mark('RAF-1');requestAnimationFrame(()=>{mark('RAF-2');resolve();});}));
    if(mode==='B-draw-after'){png=canvas.toDataURL('image/png');mark('target-toDataURL-after-RAF');}
    const r=canvas.getBoundingClientRect(),style=getComputedStyle(canvas);
    const binary64=bytes=>{let text='';for(let i=0;i<bytes.length;i+=16384)text+=String.fromCharCode(...bytes.subarray(i,i+16384));return btoa(text);};
    return JSON.stringify({mode,background,png,used:[r.x,r.y,r.width,r.height],intrinsic:[canvas.width,canvas.height],
      contextAttributes:context.getContextAttributes?.()??null,conversionAttributes,
      convertedRGBA:convertedRGBA?binary64(convertedRGBA.data):null,events,
      readbackTiming:mode==='B-draw-after'?'after-two-RAF':'synchronous-before-RAF',RAFCount:2,
      producer:convertedRGBA?'putImageData':'drawImage',
      imageSmoothingEnabled:context.imageSmoothingEnabled,imageSmoothingQuality:context.imageSmoothingQuality,
      computedStyle:{left:style.left,top:style.top,width:style.width,height:style.height,transform:style.transform,transformOrigin:style.transformOrigin},
      devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
      visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}
private final class SourceCanvasProducerFixtureBundle: NSObject {}
@MainActor private final class SourceCanvasProducerNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(in view: WKWebView) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>" +
                "<style>html,body{margin:0;background:transparent}</style></head><body></body></html>", baseURL: nil)
        }
    }
    func webView(_ view: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation = nil }
    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        continuation?.resume(throwing: error); continuation = nil
    }
}
