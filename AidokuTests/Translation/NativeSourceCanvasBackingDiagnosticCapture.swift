import Testing
import UIKit
import WebKit
import CryptoKit

/// Backing-route observations only. Equality is recorded, never asserted as
/// pixel acceptance; the independent four alpha controls remain the strict gate.
@MainActor
struct NativeSourceCanvasBackingDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let canvasFrame = CGRect(x: 135, y: 7, width: 91, height: 121)
    private let sourceHash = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
    private enum Failure: Error { case invalidSource, invalidCapture, invalidPixels }
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }

    func run() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasBackingDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 6, "count": 0, "passed": false, "pixelParityAsserted": false,
                       "reports": []], to: directory.appendingPathComponent("report.json"))
        let bundle = Bundle(for: SourceCanvasBackingFixtureBundle.self)
        let url = try #require(bundle.url(forResource: "NativeCanvasActual44Mask0", withExtension: "bin"))
        let source = try Data(contentsOf: url)
        let image = try #require(UIImage(data: source)?.cgImage)
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
        let host = try #require(window.rootViewController?.view)
        host.frame = page; host.backgroundColor = .clear
        let web = WKWebView(frame: page)
        web.overrideUserInterfaceStyle = .light; web.isOpaque = false; web.backgroundColor = .clear
        web.underPageBackgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        host.addSubview(web)
        defer { web.stopLoading(); web.removeFromSuperview() }
        let waiter = SourceCanvasBackingNavigationWaiter()
        try await waiter.load(in: web)
        var reports: [[String: Any]] = [], failures: [String] = [], comparisons: [[String: Any]] = []
        for background in ["transparent", "opaque"] {
            let output = directory.appendingPathComponent(background, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var webCaptures: [(String, Pixels)] = []
            for frequent in [false, true] {
                let name = frequent ? "web-read-frequently" : "web-default"
                do {
                    let raw = try await web.callAsyncJavaScript(Self.script,
                        arguments: ["background": background, "frequent": frequent,
                                    "originalPNG": "data:image/png;base64," + source.base64EncodedString()],
                        in: nil, contentWorld: .page)
                    guard let json = raw as? String,
                          let dom = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                          let encoded = dom["png"] as? String, let comma = encoded.firstIndex(of: ","),
                          let canvasPNG = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                          let canvasImage = UIImage(data: canvasPNG)?.cgImage else { throw Failure.invalidCapture }
                    try Data(json.utf8).write(to: output.appendingPathComponent(name + "-dom.json"))
                    try canvasPNG.write(to: output.appendingPathComponent(name + "-source-canvas.png"))
                    let canvasPixels = try pixels(canvasImage)
                    try canvasPixels.bytes.write(to: output.appendingPathComponent(name + "-source-canvas.rgba"))
                    let sourceMatches = canvasPixels.width == sourcePixels.width && canvasPixels.height == sourcePixels.height &&
                        canvasPixels.bytes == sourcePixels.bytes
                    #expect(sourceMatches)
                    if !sourceMatches { failures.append("\(background)/\(name): source buffer changed") }
                    let configuration = WKSnapshotConfiguration()
                    configuration.rect = page; configuration.snapshotWidth = 320
                    let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                        web.takeSnapshot(with: configuration) { result, error in
                            if let error { continuation.resume(throwing: error) }
                            else if let result { continuation.resume(returning: result) }
                            else { continuation.resume(throwing: Failure.invalidCapture) }
                        }
                    }
                    let captured = try save(try #require(snapshot.cgImage), prefix: name, output: output)
                    webCaptures.append((name, captured))
                    let record: [String: Any] = ["background": background, "mode": name, "requestedSnapshotWidth": 320,
                        "width": captured.width, "height": captured.height, "UIImageScale": snapshot.scale,
                        "UIImageOrientation": snapshot.imageOrientation.rawValue, "RGBAHash": hash(captured.bytes),
                        "sourceCanonicalRGBAEqual": sourceMatches, "canvasPNGHash": hash(canvasPNG),
                        "contextAttributes": dom["contextAttributes"] ?? NSNull(), "requestedReadFrequently": frequent,
                        "viewport": viewport(web, window: window)]
                    reports.append(record)
                    try writeJSON(record, to: output.appendingPathComponent(name + "-capture.json"))
                } catch { failures.append("\(background)/\(name): \(error)") }
            }
            // Native view owns the same CSS-sized backing; draw(_:) is invoked
            // through UIKit display/capture, not a CALayer.contents replacement.
            web.isHidden = true
            let nativeHost = UIView(frame: page)
            nativeHost.isOpaque = background == "opaque"
            nativeHost.backgroundColor = background == "opaque" ? UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1) : .clear
            host.addSubview(nativeHost)
            let native = SourceCanvasBackingPaintView(frame: canvasFrame, image: image)
            native.isOpaque = false; native.backgroundColor = .clear; native.contentScaleFactor = window.screen.scale
            nativeHost.addSubview(native)
            do {
                native.capturePhase = "onscreen-display"
                native.setNeedsDisplay(); nativeHost.layoutIfNeeded(); native.layer.displayIfNeeded()
                let onscreenDisplayInvocationCount = native.observations.count
                native.capturePhase = "public-drawHierarchy"
                let format = UIGraphicsImageRendererFormat()
                format.scale = window.screen.scale; format.preferredRange = .standard; format.opaque = background == "opaque"
                var hierarchySucceeded = false
                let rendered = UIGraphicsImageRenderer(size: page.size, format: format).image { _ in
                    hierarchySucceeded = nativeHost.drawHierarchy(in: page, afterScreenUpdates: true)
                }
                let captured = try save(try #require(rendered.cgImage), prefix: "native-view-hierarchy", output: output)
                var drawReports: [[String: Any]] = []
                for (index, observation) in native.observations.enumerated() {
                    var metadata = observation.metadata
                    if let raw = observation.bytes {
                        let file = "native-own-backing-\(index).raw"
                        try raw.write(to: output.appendingPathComponent(file))
                        metadata["rawFile"] = file; metadata["rawSHA256"] = hash(raw)
                    }
                    drawReports.append(metadata)
                }
                try writeJSON(drawReports, to: output.appendingPathComponent("native-draw-contexts.json"))
                let controlValid = hierarchySucceeded && !native.observations.isEmpty &&
                    captured.width == Int((page.width * window.screen.scale).rounded()) &&
                    captured.height == Int((page.height * window.screen.scale).rounded())
                #expect(controlValid)
                if !controlValid { failures.append("\(background)/native: public capture/source backing control invalid") }
                let record: [String: Any] = ["background": background, "mode": "native-view-hierarchy",
                    "width": captured.width, "height": captured.height, "UIImageScale": rendered.scale,
                    "RGBAHash": hash(captured.bytes), "drawHierarchySucceeded": hierarchySucceeded,
                    "controlValid": controlValid, "drawInvocationCount": native.observations.count,
                    "onscreenDisplayInvocationCount": onscreenDisplayInvocationCount,
                    "captureWait": "public drawHierarchy(afterScreenUpdates:true) after layer.displayIfNeeded",
                    "ownView": layerMetadata(native), "hostView": layerMetadata(nativeHost),
                    "screenScale": window.screen.scale, "sourceSHA256": sourceHash]
                reports.append(record)
                try writeJSON(record, to: output.appendingPathComponent("native-view-hierarchy-capture.json"))
                for (name, webPixels) in webCaptures {
                    var comparison = compare(webPixels, captured)
                    comparison["background"] = background; comparison["webMode"] = name
                    comparison["scope"] = "descriptive only; not an exact-pixel acceptance assertion"
                    comparisons.append(comparison)
                }
            } catch { failures.append("\(background)/native: \(error)") }
            nativeHost.removeFromSuperview(); web.isHidden = false
        }
        try writeJSON(["expectedCount": 6, "count": reports.count, "passed": reports.count == 6 && failures.isEmpty,
            "pixelParityAsserted": false, "scope": "source/control validation and actual iOS backing-route observations only",
            "originalMaskPNGHash": sourceHash, "canvasFrame": rectValues(canvasFrame), "intrinsicCanvasSize": [412, 527],
            "screenScale": window.screen.scale, "os": UIDevice.current.systemVersion,
            "reports": reports, "descriptiveComparisons": comparisons, "failures": failures],
            to: directory.appendingPathComponent("report.json"))
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
    document.body.replaceChildren(); document.documentElement.style.background='transparent';
    document.body.style.background=background==='opaque'?'rgb(41,65,87)':'transparent';
    const image=new Image();image.src=originalPNG;await image.decode();
    const canvas=document.createElement('canvas');canvas.width=412;canvas.height=527;
    Object.assign(canvas.style,{position:'absolute',left:'135px',top:'7px',width:'91px',height:'121px'});
    const context=frequent?canvas.getContext('2d',{willReadFrequently:true}):canvas.getContext('2d');
    context.drawImage(image,0,0,412,527);document.body.appendChild(canvas);
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const r=canvas.getBoundingClientRect();
    return JSON.stringify({png:canvas.toDataURL('image/png'),used:[r.x,r.y,r.width,r.height],
      intrinsic:[canvas.width,canvas.height],contextAttributes:context.getContextAttributes?.()??null,
      imageSmoothingEnabled:context.imageSmoothingEnabled,imageSmoothingQuality:context.imageSmoothingQuality,
      devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
      visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}

@MainActor private final class SourceCanvasBackingPaintView: UIView {
    struct Observation { let metadata: [String: Any]; let bytes: Data? }
    private let source: CGImage
    var observations: [Observation] = []
    var capturePhase = "unassigned"
    init(frame: CGRect, image: CGImage) { source = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("test view requires immutable source image") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let ctm = context.ctm
        var metadata: [String: Any] = ["phase": capturePhase, "dirtyRect": values(rect), "viewFrame": values(frame),
            "viewBounds": values(bounds), "layerFrame": values(layer.frame), "layerBounds": values(layer.bounds),
            "contentScaleFactor": contentScaleFactor, "contentsScale": layer.contentsScale,
            "rasterizationScale": layer.rasterizationScale, "width": context.width, "height": context.height,
            "bitsPerComponent": context.bitsPerComponent, "bitsPerPixel": context.bitsPerPixel,
            "bytesPerRow": context.bytesPerRow, "bitmapInfo": context.bitmapInfo.rawValue,
            "alphaInfo": context.alphaInfo.rawValue, "colorSpace": context.colorSpace?.name as String? ?? "nil",
            "dataAvailable": context.data != nil, "interpolationQualityBeforeDraw": context.interpolationQuality.rawValue,
            "imageEdgeAntialiasDuringDraw": false, "integerCSSDestinationUnchangedByDeviceRounding": true,
            "CTM": [ctm.a, ctm.b, ctm.c, ctm.d, ctm.tx, ctm.ty],
            "clip": values(context.boundingBoxOfClipPath), "sourceDimensions": [source.width, source.height]]
        context.saveGState()
        context.setShouldAntialias(false) // pinned GraphicsContextCG.cpp image-draw policy
        // UIImage/Canvas image orientation in UIKit's top-left user space;
        // leave the actual system interpolation quality unchanged.
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.draw(source, in: bounds)
        context.restoreGState()
        let byteCount = context.bytesPerRow * context.height
        let raw = byteCount > 0 && byteCount <= 6_144_000 ? context.data.map { Data(bytes: $0, count: byteCount) } : nil
        metadata["rawBytesAvailable"] = raw != nil; metadata["rawByteCount"] = raw?.count ?? 0
        observations.append(.init(metadata: metadata, bytes: raw))
    }
    private func values(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
}
private final class SourceCanvasBackingFixtureBundle: NSObject {}
@MainActor private final class SourceCanvasBackingNavigationWaiter: NSObject, WKNavigationDelegate {
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
