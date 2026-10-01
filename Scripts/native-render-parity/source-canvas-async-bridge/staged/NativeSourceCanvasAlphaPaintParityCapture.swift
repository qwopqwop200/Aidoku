import Testing
import UIKit
import WebKit
import CryptoKit
@testable import Aidoku

/// Actual iOS alpha/overlap observations, kept separate from the original opaque
/// controls. Captures remain strict failures until the production path matches.
@MainActor
struct NativeSourceCanvasAlphaPaintParityCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let originalMaskHash = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
    private enum Failure: Error { case invalidCapture, invalidSource, invalidPixels }
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private struct Capture { let name: String; let pixels: Pixels }

    func run() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasAlphaPaintParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Freshness guard before resource loading/navigation: an interrupted
        // execution must never leave a previous successful report behind.
        try writeJSON(["expectedCount": 4, "count": 0, "passed": false, "reports": []],
                      to: directory.appendingPathComponent("report.json"))
        // Xcode's CopyPNG phase rewrites PNG resources as CgBI. This fixture
        // is raw PNG data under an unprocessed extension so byte provenance
        // remains the original immutable BUILD44 input.
        let bundle = Bundle(for: SourceCanvasAlphaFixtureBundle.self)
        let fixture = bundle.url(forResource: "NativeCanvasActual44Mask0", withExtension: "bin")
        let loaded = fixture.flatMap { try? Data(contentsOf: $0) }
        let decoded = loaded.flatMap { UIImage(data: $0)?.cgImage }
        let matchesHash = loaded.map { hash($0) == originalMaskHash } ?? false
        let matchesDimensions = decoded.map { $0.width == 412 && $0.height == 527 } ?? false
        let reason = fixture == nil ? "missing raw fixture resource" : loaded == nil ? "unreadable raw fixture resource" :
            !matchesHash ? "original PNG bytes changed" : decoded == nil ? "PNG payload decode failed" :
            !matchesDimensions ? "decoded PNG dimensions changed" : "none"
        let provenance: [String: Any] = ["resourceName": "NativeCanvasActual44Mask0.bin", "resourceFound": fixture != nil,
            "resourceRead": loaded != nil, "bundleIdentifier": bundle.bundleIdentifier ?? "nil",
            "expectedSHA256": originalMaskHash, "actualSHA256": loaded.map(hash) ?? "nil",
            "resourceBytes": loaded?.count ?? 0, "imageDecoded": decoded != nil,
            "expectedDimensions": [412, 527], "actualDimensions": decoded.map { [$0.width, $0.height] } ?? [],
            "rawBytesMatch": matchesHash, "dimensionsMatch": matchesDimensions, "failure": reason]
        try writeJSON(provenance, to: directory.appendingPathComponent("fixture-provenance.json"))
        guard matchesHash, matchesDimensions, let originalMask = loaded, let originalMaskImage = decoded else {
            try writeJSON(["expectedCount": 4, "count": 0, "passed": false, "reports": [], "failures": [reason],
                "fixture": provenance], to: directory.appendingPathComponent("report.json"))
            throw Failure.invalidSource
        }
        try originalMask.write(to: directory.appendingPathComponent("immutable-actual44-mask0.png"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .clear; window.frame = page; window.makeKeyAndVisible(); window.frame = page
        defer { window.isHidden = true }
        let host = try #require(window.rootViewController?.view)
        host.frame = page; host.backgroundColor = .clear
        let view = WKWebView(frame: page)
        view.overrideUserInterfaceStyle = .light; view.isOpaque = false; view.backgroundColor = .clear
        view.underPageBackgroundColor = .clear
        view.scrollView.backgroundColor = .clear; view.scrollView.contentInsetAdjustmentBehavior = .never
        host.insertSubview(view, at: 0)
        defer { view.stopLoading(); view.removeFromSuperview() }
        let waiter = SourceCanvasAlphaNavigationWaiter()
        try await waiter.load(in: view)
        var reports: [[String: Any]] = [], failures: [String] = []
        for background in ["transparent", "opaque"] {
            let output = directory.appendingPathComponent(background, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            do {
                let raw = try await view.callAsyncJavaScript(Self.script, arguments: ["background": background,
                    "originalPNG": "data:image/png;base64," + originalMask.base64EncodedString()], in: nil, contentWorld: .page)
                guard let json = raw as? String, let dom = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let records = dom["records"] as? [[String: Any]], records.count == 3 else { throw Failure.invalidCapture }
                try Data(json.utf8).write(to: output.appendingPathComponent("web-dom-and-saved-masks.json"))
                try writeJSON(["bounds": rectValues(view.bounds), "safeArea": insetValues(view.safeAreaInsets),
                    "contentInset": insetValues(view.scrollView.contentInset), "adjustedContentInset": insetValues(view.scrollView.adjustedContentInset),
                    "contentOffset": [view.scrollView.contentOffset.x, view.scrollView.contentOffset.y],
                    "isOpaque": view.isOpaque, "background": background, "screenScale": window.screen.scale,
                    "innerWidth": dom["innerWidth"] ?? NSNull(), "innerHeight": dom["innerHeight"] ?? NSNull(),
                    "visualViewport": dom["visualViewport"] ?? NSNull()], to: output.appendingPathComponent("capture-viewport.json"))
                var patches: [NativeTranslationRenderer.SourcePatch] = [], sourceReports: [[String: Any]] = []
                for record in records {
                    guard let id = record["id"] as? String, let encoded = record["png"] as? String,
                          let comma = encoded.firstIndex(of: ","), let png = Data(base64Encoded: String(encoded[encoded.index(after: comma)...])),
                          let canvasImage = UIImage(data: png)?.cgImage, let f = record["used"] as? [Double], f.count == 4 else {
                        throw Failure.invalidSource
                    }
                    try png.write(to: output.appendingPathComponent("source-canvas-\(id).png"))
                    let canvas = try pixels(canvasImage)
                    try canvas.bytes.write(to: output.appendingPathComponent("source-canvas-\(id).rgba"))
                    // The actual-mask native input is the unchanged BUILD44 PNG,
                    // not a new PNG chosen after observing WebKit's output.
                    let input = id == "actual-mask" ? originalMaskImage : canvasImage
                    let nativeInput = try pixels(input)
                    try nativeInput.bytes.write(to: output.appendingPathComponent("source-native-\(id).rgba"))
                    patches.append(.init(image: input, rect: CGRect(x: f[0], y: f[1], width: f[2], height: f[3])))
                    sourceReports.append(["id": id, "frame": f, "width": input.width, "height": input.height,
                        "canvasPNGHash": hash(png), "canvasRGBAHash": hash(canvas.bytes), "nativeInputRGBAHash": hash(nativeInput.bytes),
                        "nativeInputEqualsCanvasCanonical": nativeInput.bytes == canvas.bytes,
                        "originalMaskPNGHash": id == "actual-mask" ? originalMaskHash : "not-applicable"])
                }
                try writeJSON(sourceReports, to: output.appendingPathComponent("source-provenance.json"))
                var captures: [Capture] = []
                // Capture both real WK outputs before any native comparison.
                for requested in [160, 320] {
                    let name = "live-\(requested)"
                    do {
                        let configuration = WKSnapshotConfiguration()
                        configuration.rect = page; configuration.snapshotWidth = NSNumber(value: requested)
                        let result: UIImage = try await withCheckedThrowingContinuation { continuation in
                            view.takeSnapshot(with: configuration) { image, error in
                                if let error { continuation.resume(throwing: error) }
                                else if let image { continuation.resume(returning: image) }
                                else { continuation.resume(throwing: Failure.invalidCapture) }
                            }
                        }
                        guard let image = result.cgImage else { throw Failure.invalidCapture }
                        let captured = try save(image, prefix: "web-\(name)", output: output)
                        try writeJSON(["requestedSnapshotWidth": requested, "width": captured.width, "height": captured.height,
                            "actualOutputScale": Double(captured.width) / page.width, "UIImageScale": result.scale,
                            "UIImageOrientation": result.imageOrientation.rawValue], to: output.appendingPathComponent("web-\(name)-capture.json"))
                        captures.append(.init(name: name, pixels: captured))
                    } catch { failures.append("\(background)/\(name) capture: \(error)") }
                }
                let viewport = page.size, deviceScale = window.screen.scale
                let workerPatches = patches
                let job = Task.detached { () async throws -> (CGImage, Data, Int) in
                    let bitmap = try NativeTranslationRenderer.WorkerLiveBitmap(
                        pixels: CGSize(width: viewport.width * deviceScale, height: viewport.height * deviceScale),
                        bounds: CGRect(origin: .zero, size: viewport))
                    let session = NativeCanvasTextureResampler.Session()
                    defer { session.close(); bitmap.close() }
                    guard let context = bitmap.context else { throw Failure.invalidPixels }
                    var metadata = Self.bitmapMetadata(context)
                    metadata["canonicalBackingAccepted"] = bitmap.backing != nil
                    metadata["workerWasOffMain"] = Self.isWorkerThread()
                    #expect(bitmap.backing != nil)
                    NativeTranslationRenderer.withWorkerGraphicsContext(context) {
                        if background == "opaque" {
                            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                components: [41.0 / 255, 65.0 / 255, 87.0 / 255, 1])!)
                            context.fill(context.boundingBoxOfClipPath)
                        } else { context.clear(context.boundingBoxOfClipPath) }
                    }
                    var hierarchyPaints = 0
                    for patch in workerPatches {
                        try Task.checkCancellation()
                        if try await NativeTranslationRenderer.paintHierarchySourcePatch(patch,
                            context: context, backing: bitmap.backing, viewport: viewport) {
                            hierarchyPaints += 1
                        } else {
                            try Task.checkCancellation()
                            NativeTranslationRenderer.withWorkerGraphicsContext(context) {
                                NativeTranslationRenderer.drawSourcePatch(patch, context: context,
                                    usesLiveTextureSampling: true, canvasSession: session, canvasBacking: bitmap.backing)
                            }
                        }
                    }
                    try Task.checkCancellation()
                    guard let image = context.makeImage() else { throw Failure.invalidPixels }
                    return (image, try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys]), hierarchyPaints)
                }
                let (backing, metadataBytes, hierarchyPaints) = try await withTaskCancellationHandler(
                    operation: { try await job.value }, onCancel: { job.cancel() })
                #expect(hierarchyPaints == 1, "The unchanged real mask must exercise the actual async production minifier")
                let metadata = try JSONSerialization.jsonObject(with: metadataBytes)
                try writeJSON(["screenScale": deviceScale, "width": backing.width, "height": backing.height,
                    "background": background, "CGContext": metadata, "hierarchyPaints": hierarchyPaints],
                    to: output.appendingPathComponent("native-live-backing-capture.json"))
                _ = try save(backing, prefix: "native-live-backing", output: output)
                for capture in captures {
                    do {
                        let native: Pixels = try autoreleasepool {
                            let image = backing.width == capture.pixels.width && backing.height == capture.pixels.height ? backing :
                                try NativeCanvasTextureResampler.resample(image: backing,
                                    outputPixelSize: CGSize(width: capture.pixels.width, height: capture.pixels.height))
                            return try save(image, prefix: "native-\(capture.name)", output: output)
                        }
                        var report = compare(capture.pixels, native)
                        report["background"] = background; report["mode"] = capture.name
                        report["screenScale"] = window.screen.scale; report["backingSize"] = [backing.width, backing.height]
                        report["nativeWholePageResize"] = backing.width != capture.pixels.width || backing.height != capture.pixels.height
                        report["webPNGHash"] = hash(try Data(contentsOf: output.appendingPathComponent("web-\(capture.name).png")))
                        report["nativePNGHash"] = hash(try Data(contentsOf: output.appendingPathComponent("native-\(capture.name).png")))
                        reports.append(report)
                        try writeJSON(report, to: output.appendingPathComponent("comparison-\(capture.name).json"))
                        if report["exactRGBA"] as? Bool != true {
                            failures.append("\(background)/\(capture.name): \(report["changedPixels"] ?? "dimension mismatch") pixels differ")
                        }
                    } catch { failures.append("\(background)/\(capture.name) native: \(error)") }
                }
            } catch { failures.append("\(background): \(error)") }
        }
        try writeJSON(["expectedCount": 4, "count": reports.count, "passed": reports.count == 4 && failures.isEmpty,
            "scope": "actual iOS binary-alpha, overlap, unchanged BUILD44 mask vs experimental native live paint; zero tolerance",
            "os": UIDevice.current.systemVersion, "device": UIDevice.current.model, "screenScale": window.screen.scale,
            "originalMaskPNGHash": originalMaskHash, "sourceFrames": [[10, 10, 93, 77], [49, 31, 71, 93], [135, 7, 91, 121]],
            "reports": reports, "failures": failures], to: directory.appendingPathComponent("report.json"))
        #expect(reports.count == 4)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    nonisolated private static func isWorkerThread() -> Bool { !Thread.isMainThread }

    nonisolated private static func bitmapMetadata(_ context: CGContext) -> [String: Any] {
        ["width": context.width, "height": context.height, "bitsPerComponent": context.bitsPerComponent,
         "bitsPerPixel": context.bitsPerPixel, "bytesPerRow": context.bytesPerRow, "bitmapInfo": context.bitmapInfo.rawValue,
         "alphaInfo": context.alphaInfo.rawValue, "colorSpace": context.colorSpace?.name as String? ?? "nil",
         "dataAvailable": context.data != nil, "CTM": [context.ctm.a, context.ctm.b, context.ctm.c, context.ctm.d, context.ctm.tx, context.ctm.ty]]
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
                  space: space, bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
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
        guard web.width == native.width, web.height == native.height, web.bytes.count == native.bytes.count else {
            return ["exactRGBA": false, "webSize": [web.width, web.height], "nativeSize": [native.width, native.height]]
        }
        var changed = 0, changedBytes = 0, delta = 0
        web.bytes.withUnsafeBytes { lhs in native.bytes.withUnsafeBytes { rhs in
            let left = lhs.bindMemory(to: UInt8.self), right = rhs.bindMemory(to: UInt8.self)
            for p in stride(from: 0, to: web.bytes.count, by: 4) {
                var pixel = false
                for c in 0..<4 {
                    if left[p + c] != right[p + c] { pixel = true; changedBytes += 1; delta = max(delta, abs(Int(left[p + c]) - Int(right[p + c]))) }
                }
                if pixel { changed += 1 }
            }
        } }
        return ["exactRGBA": changed == 0, "width": web.width, "height": web.height, "changedPixels": changed,
            "changedBytes": changedBytes, "maxChannelDelta": delta, "webRGBAHash": hash(web.bytes), "nativeRGBAHash": hash(native.bytes)]
    }
    private func rectValues(_ rect: CGRect) -> [CGFloat] { [rect.minX, rect.minY, rect.width, rect.height] }
    private func insetValues(_ value: UIEdgeInsets) -> [CGFloat] { [value.top, value.right, value.bottom, value.left] }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func writeJSON(_ value: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
    private static let script = #"""
    document.body.replaceChildren();
    document.documentElement.style.background='transparent';
    document.body.style.background=background==='opaque'?'rgb(41,65,87)':'transparent';
    const actual=new Image();actual.src=originalPNG;await actual.decode();const records=[];
    const make=(id,x,y,w,h,isActual=false)=>{
        const n=document.createElement('canvas');n.width=isActual?412:20;n.height=isActual?527:20;
        Object.assign(n.style,{position:'absolute',left:x+'px',top:y+'px',width:w+'px',height:h+'px'});
        const c=n.getContext('2d');
        if(!isActual){const d=c.createImageData(20,20);for(let y=0;y<20;y++)for(let x=0;x<20;x++){
            const i=(y*20+x)*4;d.data[i]=23+x*9;d.data[i+1]=17+y*10;d.data[i+2]=201;
            d.data[i+3]=((x+y)%5<2||x<3)?0:255;}c.putImageData(d,0,0);}
        else c.drawImage(actual,0,0,n.width,n.height);
        document.body.appendChild(n);const r=n.getBoundingClientRect();records.push({id,used:[r.x,r.y,r.width,r.height],
            width:n.width,height:n.height,png:n.toDataURL('image/png')});
    };
    make('binary',10,10,93,77);make('overlap',49,31,71,93);make('actual-mask',135,7,91,121,true);
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    return JSON.stringify({records,background,devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
        visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}

private final class SourceCanvasAlphaFixtureBundle: NSObject {}
@MainActor private final class SourceCanvasAlphaNavigationWaiter: NSObject, WKNavigationDelegate {
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
