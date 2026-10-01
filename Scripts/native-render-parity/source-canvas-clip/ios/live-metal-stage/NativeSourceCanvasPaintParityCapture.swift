import Testing
import UIKit
import WebKit
import CryptoKit
@testable import Aidoku

/// Serialized by the caller. This observes the iOS backend; macOS canvas
/// destination bounds are evidence to investigate, not an iOS pixel oracle.
@MainActor
struct NativeSourceCanvasPaintParityCapture {
    private let page = CGRect(x: 0, y: 0, width: 640, height: 1000)
    private enum Failure: Error { case invalidCapture, invalidSource, invalidPixels }
    private struct Captured {
        let name: String
        let bounds: CGRect
        let pdf: Bool
        let width: Int
        let height: Int
    }
    private struct Pixels {
        let width: Int
        let height: Int
        let bytes: Data
    }

    func run() async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light
        window.frame = page
        window.makeKeyAndVisible()
        window.frame = page
        defer { window.isHidden = true }
        let host = try #require(window.rootViewController?.view)
        host.frame = page
        let view = WKWebView(frame: page)
        view.overrideUserInterfaceStyle = .light
        // Match the frozen reader: DOM coordinates and live snapshots must
        // share the same viewport, without automatic safe-area translation.
        view.scrollView.contentInsetAdjustmentBehavior = .never
        host.insertSubview(view, at: 0)
        defer { view.stopLoading(); view.removeFromSuperview() }
        let waiter = SourceCanvasPaintNavigationWaiter()
        try await waiter.load(in: view)
        let directory = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasPaintParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var reports: [[String: Any]] = [], failures: [String] = []
        try writeJSON(["passed": false, "scope": "actual iOS WK PDF and live canvas vs production SourcePatch", "reports": []],
                      to: directory.appendingPathComponent("report.json"))
        for sceneName in ["original-six", "negative-global", "negative-global-half"] {
            let output = directory.appendingPathComponent(sceneName, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            do {
                let inputs: String
                switch sceneName {
                case "original-six": inputs = Self.originalInputs
                case "negative-global": inputs = Self.negativeInput
                default: inputs = Self.negativeHalfInput
                }
                try Data(inputs.utf8).write(to: output.appendingPathComponent("inputs.json"))
                let raw = try await view.callAsyncJavaScript(Self.script, arguments: ["inputJSON": inputs],
                                                            in: nil, contentWorld: .page)
                guard let json = raw as? String, let document = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let records = document["records"] as? [[String: Any]] else { throw Failure.invalidCapture }
                try Data(json.utf8).write(to: output.appendingPathComponent("web-dom-and-saved-masks.json"))
                let viewport: [String: Any] = ["windowFrame": rectValues(window.frame), "viewFrame": rectValues(view.frame),
                    "viewBounds": rectValues(view.bounds), "scrollViewBounds": rectValues(view.scrollView.bounds),
                    "safeAreaInsets": insetValues(view.safeAreaInsets), "contentInset": insetValues(view.scrollView.contentInset),
                    "adjustedContentInset": insetValues(view.scrollView.adjustedContentInset),
                    "contentInsetAdjustmentBehavior": view.scrollView.contentInsetAdjustmentBehavior.rawValue,
                    "contentOffset": [view.scrollView.contentOffset.x, view.scrollView.contentOffset.y],
                    "innerWidth": document["innerWidth"] ?? NSNull(), "innerHeight": document["innerHeight"] ?? NSNull(),
                    "visualViewport": document["visualViewport"] ?? NSNull(), "devicePixelRatio": document["devicePixelRatio"] ?? NSNull()]
                try writeJSON(viewport, to: output.appendingPathComponent("capture-viewport.json"))
                if view.scrollView.adjustedContentInset != .zero || view.scrollView.contentOffset != .zero {
                    failures.append("\(sceneName): capture scroll inset/offset differs from frozen zero-adjustment viewport")
                }
                var patches: [NativeTranslationRenderer.SourcePatch] = [], sourceReports: [[String: Any]] = []
                for record in records {
                    guard let id = record["id"] as? String, let url = record["png"] as? String,
                          let comma = url.firstIndex(of: ","), let png = Data(base64Encoded: String(url[url.index(after: comma)...])),
                          let image = UIImage(data: png)?.cgImage,
                          let values = record["raw"] as? [Double], values.count == 4,
                          let parent = record["parent"] as? [Double], parent.count == 2,
                          let used = record["used"] as? [Double], used.count == 4 else { throw Failure.invalidSource }
                    try png.write(to: output.appendingPathComponent("source-\(id).png"))
                    let rawRect = CGRect(x: values[0], y: values[1], width: values[2], height: values[3])
                    let nativeRect = NativeTranslationRenderer.usedRect(rawRect).offsetBy(dx: parent[0], dy: parent[1])
                    // The literal controls deliberately apply no clipPath. The
                    // input's clip is provenance only; saved masks retain the
                    // unmodified toDataURL bitmap and DOM-used fractional rect.
                    patches.append(.init(image: image, rect: nativeRect))
                    let source = try pixels(image)
                    try source.bytes.write(to: output.appendingPathComponent("source-\(id).rgba"))
                    sourceReports.append(["id": id, "savedMaskFrame": used, "nativeDOMFrame": rectValues(nativeRect),
                        "sourcePNGHash": hash(png), "sourceRGBAHash": hash(source.bytes),
                        "sourceWidth": source.width, "sourceHeight": source.height,
                        "appliedClipPath": "none", "opaqueRGBA": source.bytes.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 }])
                }
                try writeJSON(sourceReports, to: output.appendingPathComponent("source-provenance.json"))
                var captures: [Captured] = []
                // Save every original WK capture before evaluating native
                // comparisons or asserting a pixel gate.
                let pdfBounds = sceneName == "negative-global"
                    ? [("pdf", page), ("pdf-negative-crop", CGRect(x: -3.75, y: -2.25, width: 132.5, height: 128.5))]
                    : [("pdf", page)]
                for (name, bounds) in pdfBounds {
                    do {
                        let configuration = WKPDFConfiguration(); configuration.rect = bounds
                        let data: Data = try await withCheckedThrowingContinuation { continuation in
                            view.createPDF(configuration: configuration) { continuation.resume(with: $0) }
                        }
                        let file = output.appendingPathComponent("web-\(name).pdf")
                        try data.write(to: file)
                        let media = try pdfMediaBox(data)
                        let width = Int(media.width * 2), height = Int(media.height * 2)
                        let image = try NativeTranslationPDFCapture.rasterize(data: data, pixels: CGSize(width: width, height: height))
                        _ = try save(image, prefix: "web-\(name)", output: output)
                        try writeJSON(["requestedRect": rectValues(bounds), "mediaBox": rectValues(media), "PDFHash": hash(data),
                                       "rasterWidth": width, "rasterHeight": height], to: output.appendingPathComponent("web-\(name)-capture.json"))
                        captures.append(.init(name: name, bounds: bounds, pdf: true, width: width, height: height))
                    } catch { failures.append("\(sceneName)/\(name) capture: \(error)") }
                }
                // At DPR3, the largest request is1920×3000 (5.76MP).
                // Two observed scales retain the rounding/interpolation control
                // without allocating a23MP snapshot.
                for requested in [320, 640] {
                    let name = "live-\(requested)"
                    do {
                        let configuration = WKSnapshotConfiguration()
                        configuration.rect = page; configuration.snapshotWidth = NSNumber(value: requested)
                        let image: UIImage = try await withCheckedThrowingContinuation { continuation in
                            view.takeSnapshot(with: configuration) { image, error in
                                if let error { continuation.resume(throwing: error) }
                                else if let image { continuation.resume(returning: image) }
                                else { continuation.resume(throwing: Failure.invalidCapture) }
                            }
                        }
                        guard let cgImage = image.cgImage else { throw Failure.invalidCapture }
                        let rgba = try save(cgImage, prefix: "web-\(name)", output: output)
                        try writeJSON(["requestedSnapshotWidth": requested, "width": rgba.width, "height": rgba.height,
                            "actualOutputScale": Double(rgba.width) / page.width, "UIImageScale": image.scale,
                            "UIImageOrientation": image.imageOrientation.rawValue, "screenScale": window.screen.scale],
                            to: output.appendingPathComponent("web-\(name)-capture.json"))
                        captures.append(.init(name: name, bounds: page, pdf: false, width: rgba.width, height: rgba.height))
                    } catch { failures.append("\(sceneName)/\(name) capture: \(error)") }
                }
                var liveBacking: CGImage?
                for captured in captures {
                    do {
                        let native: Pixels = try autoreleasepool {
                            let nativeImage: CGImage
                            if captured.pdf {
                                let capture = try NativeTranslationPDFCapture.capture(bounds: captured.bounds,
                                    pixels: CGSize(width: captured.width, height: captured.height), deviceScale: window.screen.scale) { context in
                                    paint(patches, in: context)
                                }
                                try capture.data.write(to: output.appendingPathComponent("native-\(captured.name).pdf"))
                                nativeImage = capture.image
                            } else {
                                if liveBacking == nil {
                                    let format = UIGraphicsImageRendererFormat()
                                    // Paint the real production canvas path at the
                                    // screen backing scale before snapshot reduction.
                                    format.scale = window.screen.scale
                                    format.preferredRange = .standard; format.opaque = true
                                    let renderer = UIGraphicsImageRenderer(size: page.size, format: format)
                                    var bitmap: [String: Any] = [:]
                                    guard let backing = renderer.image(actions: {
                                        bitmap = bitmapMetadata($0.cgContext)
                                        paint(patches, in: $0.cgContext, usesLiveTextureSampling: true)
                                    }).cgImage else {
                                        throw Failure.invalidPixels
                                    }
                                    liveBacking = backing
                                    _ = try save(backing, prefix: "native-live-backing", output: output)
                                    try writeJSON(["screenScale": window.screen.scale, "width": backing.width,
                                        "height": backing.height, "pageBounds": rectValues(page), "CGContext": bitmap,
                                        "scope": "actual production SourcePatch page at screen scale before snapshot resize"],
                                        to: output.appendingPathComponent("native-live-backing-capture.json"))
                                }
                                guard let backing = liveBacking else { throw Failure.invalidPixels }
                                if backing.width == captured.width && backing.height == captured.height {
                                    nativeImage = backing
                                } else {
                                    // This is a whole-page snapshot resize. It must
                                    // not replace source-canvas paint at the screen scale.
                                    nativeImage = try NativeCanvasTextureResampler.resample(image: backing,
                                        outputPixelSize: CGSize(width: captured.width, height: captured.height))
                                }
                            }
                            return try save(nativeImage, prefix: "native-\(captured.name)", output: output)
                        }
                        let webBytes = try Data(contentsOf: output.appendingPathComponent("web-\(captured.name).rgba"))
                        let web = Pixels(width: captured.width, height: captured.height, bytes: webBytes)
                        var comparison = compare(web, native)
                        comparison["scene"] = sceneName; comparison["mode"] = captured.name
                        comparison["webPNGHash"] = hash(try Data(contentsOf: output.appendingPathComponent("web-\(captured.name).png")))
                        comparison["nativePNGHash"] = hash(try Data(contentsOf: output.appendingPathComponent("native-\(captured.name).png")))
                        comparison["devicePixelRatio"] = document["devicePixelRatio"]
                        comparison["outputScale"] = Double(captured.width) / captured.bounds.width
                        if !captured.pdf, let backing = liveBacking {
                            comparison["nativeLiveBackingSize"] = [backing.width, backing.height]
                            comparison["nativeLiveBackingScale"] = window.screen.scale
                            comparison["nativeSnapshotWholePageResize"] = backing.width != captured.width || backing.height != captured.height
                            comparison["nativeLivePath"] = "production SourcePatch at screen scale, then production Float Metal page resize"
                        }
                        comparison["paintBounds"] = paintBounds(web, native, records: records, capture: captured)
                        reports.append(comparison)
                        try writeJSON(comparison, to: output.appendingPathComponent("comparison-\(captured.name).json"))
                        if comparison["exactRGBA"] as? Bool != true {
                            failures.append("\(sceneName)/\(captured.name): \(comparison["changedPixels"] ?? "dimension mismatch") pixels differ")
                        }
                    } catch { failures.append("\(sceneName)/\(captured.name) native comparison: \(error)") }
                }
            } catch { failures.append("\(sceneName): \(error)") }
        }
        try writeJSON(["scope": "actual iOS WK PDF/live vs actual production SourcePatch; no macOS pixel inference",
            "os": UIDevice.current.systemVersion, "device": UIDevice.current.model, "screenScale": window.screen.scale,
            "savedMaskSemantics": "raw toDataURL PNG plus DOM-used rect; no clipping or destination snapping",
            "decodedPixelFormat": "sRGB premultiplied RGBA8 in CGImage/PNG row order",
            "expectedComparisonCount": 10, "reports": reports, "failures": failures,
            "passed": reports.count == 10 && failures.isEmpty], to: directory.appendingPathComponent("report.json"))
        #expect(reports.count == 10)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    private func paint(_ patches: [NativeTranslationRenderer.SourcePatch], in context: CGContext,
                       usesLiveTextureSampling: Bool = false) {
        UIGraphicsPushContext(context); defer { UIGraphicsPopContext() }
        // HTML's white page background covers the entire requested capture.
        // A negative PDF crop still has white outside the layout viewport;
        // fill its actual user-space clip rather than leaving transparent strips.
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(context.boundingBoxOfClipPath)
        for patch in patches {
            NativeTranslationRenderer.drawSourcePatch(patch, context: context, usesLiveTextureSampling: usesLiveTextureSampling)
        }
    }
    private func save(_ image: CGImage, prefix: String, output: URL) throws -> Pixels {
        guard let png = UIImage(cgImage: image).pngData() else { throw Failure.invalidCapture }
        try png.write(to: output.appendingPathComponent(prefix + ".png"))
        let result = try pixels(image)
        try result.bytes.write(to: output.appendingPathComponent(prefix + ".rgba"))
        return result
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        let width = image.width, height = image.height
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                  space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let bytes = context.data else { throw Failure.invalidPixels }
        // Match the established image-parity reader: no UIKit flip on CGImage rows.
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return .init(width: width, height: height, bytes: Data(bytes: bytes, count: width * height * 4))
    }
    private func pdfMediaBox(_ data: Data) throws -> CGRect {
        guard let provider = CGDataProvider(data: data as CFData), let document = CGPDFDocument(provider),
              let page = document.page(at: 1) else { throw Failure.invalidCapture }
        return page.getBoxRect(.mediaBox)
    }
    private func compare(_ web: Pixels, _ native: Pixels) -> [String: Any] {
        guard web.width == native.width, web.height == native.height, web.bytes.count == native.bytes.count else {
            return ["exactRGBA": false, "webSize": [web.width, web.height], "nativeSize": [native.width, native.height]]
        }
        var changed = 0, changedBytes = 0, delta = 0
        var minX = web.width, minY = web.height, maxX = -1, maxY = -1
        web.bytes.withUnsafeBytes { left in native.bytes.withUnsafeBytes { right in
            let lhs = left.bindMemory(to: UInt8.self), rhs = right.bindMemory(to: UInt8.self)
            for pixel in 0..<(web.width * web.height) {
                var differs = false
                for channel in 0..<4 {
                    let i = pixel * 4 + channel
                    if lhs[i] != rhs[i] { differs = true; changedBytes += 1; delta = max(delta, abs(Int(lhs[i]) - Int(rhs[i]))) }
                }
                if differs {
                    changed += 1; minX = min(minX, pixel % web.width); maxX = max(maxX, pixel % web.width)
                    minY = min(minY, pixel / web.width); maxY = max(maxY, pixel / web.width)
                }
            }
        } }
        return ["exactRGBA": changed == 0, "pixels": web.width * web.height, "width": web.width, "height": web.height,
            "changedPixels": changed, "changedBytes": changedBytes, "maxChannelDelta": delta,
            "differenceBounds": changed == 0 ? [] : [minX, minY, maxX - minX + 1, maxY - minY + 1],
            "webRGBAHash": hash(web.bytes), "nativeRGBAHash": hash(native.bytes)]
    }
    private func paintBounds(_ web: Pixels, _ native: Pixels, records: [[String: Any]], capture: Captured) -> [[String: Any]] {
        let integral = capture.pdf ? NativeTranslationPDFCapture.integralCaptureRect(capture.bounds) : capture.bounds
        let sx = Double(web.width) / integral.width, sy = Double(web.height) / integral.height
        return records.compactMap { record in
            guard let used = record["used"] as? [Double], used.count == 4, let id = record["id"] as? String else { return nil }
            let frame = CGRect(x: used[0], y: used[1], width: used[2], height: used[3])
            let region = CGRect(x: (frame.minX - integral.minX) * sx - 3, y: (frame.minY - integral.minY) * sy - 3,
                                width: frame.width * sx + 6, height: frame.height * sy + 6)
            return ["id": id, "DOMFrame": used, "webNonwhiteBounds": nonwhite(web, region: region),
                    "nativeNonwhiteBounds": nonwhite(native, region: region)]
        }
    }
    private func nonwhite(_ pixels: Pixels, region: CGRect) -> [Int] {
        // Clamping is essential for negative global origins; outside-image
        // memory/black padding must never become fabricated painted pixels.
        let left = max(0, min(pixels.width, Int(floor(region.minX))))
        let top = max(0, min(pixels.height, Int(floor(region.minY))))
        let right = max(0, min(pixels.width, Int(ceil(region.maxX))))
        let bottom = max(0, min(pixels.height, Int(ceil(region.maxY))))
        guard right > left, bottom > top else { return [] }
        var minX = pixels.width, minY = pixels.height, maxX = -1, maxY = -1
        pixels.bytes.withUnsafeBytes { buffer in
            let bytes = buffer.bindMemory(to: UInt8.self)
            for y in top..<bottom { for x in left..<right {
                let i = (y * pixels.width + x) * 4
                if bytes[i] != 255 || bytes[i + 1] != 255 || bytes[i + 2] != 255 {
                    minX = min(minX, x); minY = min(minY, y); maxX = max(maxX, x); maxY = max(maxY, y)
                }
            } }
        }
        return maxX < 0 ? [] : [minX, minY, maxX - minX + 1, maxY - minY + 1]
    }
    private func bitmapMetadata(_ context: CGContext) -> [String: Any] {
        ["width": context.width, "height": context.height, "bitsPerComponent": context.bitsPerComponent,
         "bitsPerPixel": context.bitsPerPixel, "bytesPerRow": context.bytesPerRow,
         "bitmapInfo": context.bitmapInfo.rawValue, "alphaInfo": context.alphaInfo.rawValue,
         "colorSpace": context.colorSpace?.name as String? ?? "nil", "dataAvailable": context.data != nil,
         "CTM": [context.ctm.a, context.ctm.b, context.ctm.c, context.ctm.d, context.ctm.tx, context.ctm.ty]]
    }
    private func insetValues(_ insets: UIEdgeInsets) -> [CGFloat] { [insets.top, insets.right, insets.bottom, insets.left] }
    private func rectValues(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func writeJSON(_ value: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }

    private static let originalInputs = #"""
    [{"id":"positive-captured","raw":[162.55462184873952,212.3529411764706,67.5126050420168,86.35714285714286],"clip":[0.009,0.019,200.009,300.019]},
    {"id":"negative-captured","raw":[-20.009,-10.019,100.009,99.989],"clip":[0.009,0.019,200.009,300.019]},
    {"id":"half-positive","raw":[10.25,10.25,100.25,99.25],"clip":[11.75,11.75,97.25,96.25]},
    {"id":"half-negative","raw":[-20.25,-10.25,100.25,99.25],"clip":[-18.75,-8.75,97.25,96.25]},
    {"id":"sub-layout-unit-insets","raw":[12.0007,15.0008,20.0009,30.001],"clip":[12.0037,15.0048,19.9949,29.991]},
    {"id":"used-width-exhausted","raw":[10,10,0.019,5],"clip":[10.018,10,1,5]}]
    """#
    private static let negativeInput = #"[{"id":"negative-global","raw":[-10.25,-10.25,100.25,99.25],"parent":[0,0]}]"#
    private static let negativeHalfInput = #"[{"id":"negative-global-half","raw":[-10.5,-10.5,100.25,99.25],"parent":[0,0]}]"#
    private static let script = #"""
    document.body.replaceChildren();
    const inputs=JSON.parse(inputJSON),records=[];
    for(let i=0;i<inputs.length;i++) {
        const f=inputs[i],b=f.raw,p=document.createElement('div'),n=document.createElement('canvas');
        const parent=f.parent||[200,i*160+10];
        Object.assign(p.style,{position:'absolute',left:parent[0]+'px',top:parent[1]+'px',width:'400px',height:'150px'});
        n.width=20;n.height=20;const context=n.getContext('2d');
        context.fillStyle='rgb('+(180+i*3)+',30,50)';context.fillRect(0,0,20,20);
        for(let j=0;j<4;j++) {
            context.fillStyle=['#154070','#508020','#d08030','#7030a0'][j];
            context.fillRect(1+(j%2)*9,1+Math.floor(j/2)*9,9,9);
        }
        Object.assign(n.style,{position:'absolute',left:b[0]+'px',top:b[1]+'px',width:b[2]+'px',height:b[3]+'px'});
        p.appendChild(n);document.body.appendChild(p);
        const r=n.getBoundingClientRect(),pr=p.getBoundingClientRect();
        records.push({id:f.id,raw:b,used:[r.x,r.y,r.width,r.height],parent:[pr.x,pr.y],color:[180+i*3,30,50],
            deviceScale:devicePixelRatio,opacity:getComputedStyle(n).opacity,clipPath:getComputedStyle(n).clipPath,
            png:n.toDataURL('image/png')});
    }
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    return JSON.stringify({records,devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
        visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}

@MainActor
private final class SourceCanvasPaintNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(in view: WKWebView) async throws {
        view.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            // Only the iOS viewport wrapper differs from the macOS capture.
            // Literal parents/canvases/patterns remain identical and viewport
            // geometry is saved rather than assuming a particular device DPR.
            view.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>" +
                "<style>html,body{margin:0;background:white}</style></head><body></body></html>", baseURL: nil)
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
