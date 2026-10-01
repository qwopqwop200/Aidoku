import Testing
import UIKit
import WebKit
import CryptoKit
@testable import Aidoku

/// Bounded affine controls with literal source and CSS geometry. Sparse one-level
/// raster rounding may differ; dimensions, input pixels and layout remain exact.
@MainActor
struct NativeSourceCanvasTransformPaintParityCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    // Literal affine source controls. No production geometry is inferred from fixture IDs.
    private let transforms: [(String, [Double])] = [
        ("identity", [1, 0, 0, 1, 0, 0]),
        ("nonuniform", [0.9, 0, 0, 1.1, 0, 0]),
        ("fractional-origin", [1, 0, 0, 1, 0.25, 0.375]),
        ("rotation", [cos(0.035), sin(0.035), -sin(0.035), cos(0.035), 0, 0])
    ]
    private static let sourceRecipe: Data = {
        var rgba: [UInt8] = []
        rgba.reserveCapacity(20 * 20 * 4)
        for y in 0..<20 { for x in 0..<20 {
            rgba.append(contentsOf: [UInt8(23 + x * 9), UInt8(17 + y * 10), 201, 255])
        } }
        return Data(rgba)
    }()
    private let sourceRecipeHash = "ba555c281c4574a1edf76efe4ea1d60ecf485586f1474eed5bf4a778eb913e33"
    private enum Failure: Error { case invalidCapture, invalidSource, invalidPixels }
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private struct Capture { let name: String; let pixels: Pixels }

    func run() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasTransformPaintParity", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        // Freshness guard before resource loading/navigation: an interrupted
        // execution must never leave a previous successful report behind.
        try writeJSON(["expectedCount": 8, "count": 0, "passed": false, "reports": []],
                      to: directory.appendingPathComponent("report.json"))
        let recipeValid = hash(Self.sourceRecipe) == sourceRecipeHash
        #expect(recipeValid)
        guard recipeValid else { throw Failure.invalidSource }
        try Self.sourceRecipe.write(to: directory.appendingPathComponent("immutable-source-recipe.rgba"))
        try writeJSON(["recipe": "20x20 RGBA=(23+x*9,17+y*10,201,255)",
                       "dimensions": [20,20], "expectedRGBAHash": sourceRecipeHash,
                       "actualRGBAHash": hash(Self.sourceRecipe), "valid": recipeValid],
                      to: directory.appendingPathComponent("immutable-source-provenance.json"))
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
        let waiter = SourceCanvasTransformNavigationWaiter()
        try await waiter.load(in: view)
        var reports: [[String: Any]] = [], failures: [String] = []
        for (sceneName, affine) in transforms {
            let output = directory.appendingPathComponent(sceneName, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            do {
                let raw = try await view.callAsyncJavaScript(Self.script, arguments: ["matrix": affine], in: nil, contentWorld: .page)
                guard let json = raw as? String, let dom = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any],
                      let records = dom["records"] as? [[String: Any]], records.count == 2 else { throw Failure.invalidCapture }
                try Data(json.utf8).write(to: output.appendingPathComponent("web-dom-and-saved-masks.json"))
                guard records.compactMap({ $0["id"] as? String }) == ["positive", "negative"],
                      let observedMatrix = dom["matrix"] as? [Double], observedMatrix == affine else { throw Failure.invalidSource }
                try writeJSON(["bounds": rectValues(view.bounds), "safeArea": insetValues(view.safeAreaInsets),
                    "contentInset": insetValues(view.scrollView.contentInset), "adjustedContentInset": insetValues(view.scrollView.adjustedContentInset),
                    "contentOffset": [view.scrollView.contentOffset.x, view.scrollView.contentOffset.y],
                    "isOpaque": view.isOpaque, "sceneName": sceneName, "backgroundRGB": [41,65,87], "screenScale": window.screen.scale,
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
                    let recipeMatches = canvas.width == 20 && canvas.height == 20 && canvas.bytes == Self.sourceRecipe
                    let expectedRaw: [Double] = id == "positive" ? [10.25,10.5,93.25,77.75] : [-10.5,-10.5,100.25,99.25]
                    let rawMatches = (record["raw"] as? [Double]) == expectedRaw && f == expectedRaw
                    #expect(recipeMatches)
                    #expect(rawMatches)
                    guard recipeMatches, rawMatches else { throw Failure.invalidSource }
                    let input = canvasImage
                    let nativeInput = try pixels(input)
                    try nativeInput.bytes.write(to: output.appendingPathComponent("source-native-\(id).rgba"))
                    patches.append(.init(image: input, rect: CGRect(x: f[0], y: f[1], width: f[2], height: f[3])))
                    sourceReports.append(["id": id, "frame": f, "width": input.width, "height": input.height,
                        "canvasPNGHash": hash(png), "canvasRGBAHash": hash(canvas.bytes), "nativeInputRGBAHash": hash(nativeInput.bytes),
                        "nativeInputEqualsCanvasCanonical": nativeInput.bytes == canvas.bytes,
                        "immutableRecipeRGBAHash": sourceRecipeHash, "immutableRecipeMatches": recipeMatches,
                        "literalRawAndDOMRectMatches": rawMatches, "sourceBitmapInfo": input.bitmapInfo.rawValue,
                        "sourceColorSpace": input.colorSpace?.name as String? ?? "nil",
                        "sourceShouldInterpolate": input.shouldInterpolate, "affine": affine])
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
                    } catch { failures.append("\(sceneName)/\(name) capture: \(error)") }
                }
                let backing: CGImage = try autoreleasepool {
                    let format = UIGraphicsImageRendererFormat()
                    format.scale = window.screen.scale; format.preferredRange = .standard; format.opaque = true
                    let renderer = UIGraphicsImageRenderer(size: page.size, format: format)
                    var metadata: [String: Any] = [:]
                    guard let image = renderer.image(actions: { value in
                        let context = value.cgContext
                        metadata = bitmapMetadata(context)
                        do {
                            context.setFillColor(CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                components: [41.0 / 255, 65.0 / 255, 87.0 / 255, 1])!)
                            context.fill(context.boundingBoxOfClipPath)
                        }
                        let session = NativeCanvasTextureResampler.Session(); defer { session.close() }
                        context.saveGState()
                        defer { context.restoreGState() }
                        context.concatenate(CGAffineTransform(a: affine[0], b: affine[1], c: affine[2], d: affine[3], tx: affine[4], ty: affine[5]))
                        metadata["sourcePaintCTM"] = [context.ctm.a, context.ctm.b, context.ctm.c, context.ctm.d, context.ctm.tx, context.ctm.ty]
                        metadata["literalParentMatrix"] = affine
                        metadata["consumer"] = "production NativeTranslationRenderer.drawSourcePatch usesLiveTextureSampling:true"
                        metadata["opaqueAffineSamplingDeclared"] = true
                        metadata["branchInstrumentation"] = "none; guard classification is predicted from public CTM/geometry only"
                        metadata["predictedIntegralUniformGuard"] = patches.map { patch in
                            guard let frame = NativeSourceCanvasImageFrame.liveFrame(domRect: patch.rect) else { return false }
                            let m = context.ctm, size = CGSize(width: frame.width * m.a, height: frame.height * m.a)
                            let origin = context.convertToDeviceSpace(frame.origin)
                            return m.a.isFinite && m.a > 0 && m.b == 0 && m.c == 0 && abs(m.d) == m.a &&
                                [size.width,size.height,origin.x,origin.y].allSatisfy { $0.isFinite && $0.rounded(.towardZero) == $0 }
                        }
                        for patch in patches {
                            NativeTranslationRenderer.drawSourcePatch(patch, context: context,
                                usesLiveTextureSampling: true, canvasSession: session, allowsOpaqueAffineSampling: true)
                        }
                    }).cgImage else { throw Failure.invalidPixels }
                    try writeJSON(["screenScale": window.screen.scale, "width": image.width, "height": image.height,
                        "sceneName": sceneName, "backgroundRGB": [41,65,87], "CGContext": metadata], to: output.appendingPathComponent("native-live-backing-capture.json"))
                    _ = try save(image, prefix: "native-live-backing", output: output)
                    return image
                }
                for capture in captures {
                    do {
                        let native: Pixels = try autoreleasepool {
                            let image = backing.width == capture.pixels.width && backing.height == capture.pixels.height ? backing :
                                try NativeCanvasTextureResampler.resample(image: backing,
                                    outputPixelSize: CGSize(width: capture.pixels.width, height: capture.pixels.height))
                            return try save(image, prefix: "native-\(capture.name)", output: output)
                        }
                        var report = compare(capture.pixels, native)
                        report["sceneName"] = sceneName; report["backgroundRGB"] = [41,65,87]; report["mode"] = capture.name
                        report["screenScale"] = window.screen.scale; report["backingSize"] = [backing.width, backing.height]
                        report["nativeWholePageResize"] = backing.width != capture.pixels.width || backing.height != capture.pixels.height
                        report["webPNGHash"] = hash(try Data(contentsOf: output.appendingPathComponent("web-\(capture.name).png")))
                        report["nativePNGHash"] = hash(try Data(contentsOf: output.appendingPathComponent("native-\(capture.name).png")))
                        reports.append(report)
                        try writeJSON(report, to: output.appendingPathComponent("comparison-\(capture.name).json"))
                        if report["rasterAccepted"] as? Bool != true {
                            failures.append("\(sceneName)/\(capture.name): \(report["changedPixels"] ?? "dimension mismatch") pixels differ")
                        }
                    } catch { failures.append("\(sceneName)/\(capture.name) native: \(error)") }
                }
            } catch { failures.append("\(sceneName): \(error)") }
        }
        try writeJSON(["expectedCount": 8, "count": reports.count, "passed": reports.count == 8 && failures.isEmpty,
            "scope": "actual iOS opaque canvas with identical source/local CSS geometry/literal affine matrix; sparse one-level raster roundoff only",
            "allExactRGBA": reports.allSatisfy { $0["exactRGBA"] as? Bool == true },
            "rasterAcceptance": ["maximumChangedPixelFraction": 0.0001, "maximumChannelDelta": 1,
                "sameDimensionsRequired": true, "sameSourceAndGeometryRequired": true] as [String: Any],
            "os": UIDevice.current.systemVersion, "device": UIDevice.current.model, "screenScale": window.screen.scale,
            "sourceFrames": [[10.25, 10.5, 93.25, 77.75], [-10.5, -10.5, 100.25, 99.25]],
            "literalTransforms": transforms.map { ["name": $0.0, "matrix": $0.1] as [String: Any] },
            "immutableRecipeRGBAHash": sourceRecipeHash,
            "scopeLimit": "opaque enlargement and affine/clipping only; no alpha-over or large-mask minification claim",
            "reports": reports, "failures": failures], to: directory.appendingPathComponent("report.json"))
        #expect(reports.count == 8)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    private func bitmapMetadata(_ context: CGContext) -> [String: Any] {
        ["width": context.width, "height": context.height, "bitsPerComponent": context.bitsPerComponent,
         "bitsPerPixel": context.bitsPerPixel, "bytesPerRow": context.bytesPerRow, "bitmapInfo": context.bitmapInfo.rawValue,
         "alphaInfo": context.alphaInfo.rawValue, "colorSpace": context.colorSpace?.name as String? ?? "nil",
         "dataAvailable": context.data != nil, "interpolationQuality": context.interpolationQuality.rawValue, "CTM": [context.ctm.a, context.ctm.b, context.ctm.c, context.ctm.d, context.ctm.tx, context.ctm.ty]]
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
            return ["exactRGBA": false, "rasterAccepted": false, "webSize": [web.width, web.height], "nativeSize": [native.width, native.height]]
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
        let accepted = NativeSourceCanvasRasterAcceptance.accepts(referenceWidth: web.width, referenceHeight: web.height,
            actualWidth: native.width, actualHeight: native.height, changedPixels: changed, maximumChannelDelta: delta)
        return ["exactRGBA": changed == 0, "rasterAccepted": accepted,
            "width": web.width, "height": web.height, "changedPixels": changed,
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
    document.documentElement.style.background='rgb(41,65,87)';
    document.body.style.background='rgb(41,65,87)';
    const parent=document.createElement('div');
    Object.assign(parent.style,{position:'absolute',left:'0px',top:'0px',width:'320px',height:'160px',transformOrigin:'0px 0px',transform:'none'});
    document.body.appendChild(parent);const records=[];
    const make=(id,x,y,w,h)=>{
        const n=document.createElement('canvas');n.width=20;n.height=20;
        Object.assign(n.style,{position:'absolute',left:x+'px',top:y+'px',width:w+'px',height:h+'px'});
        const c=n.getContext('2d'),d=c.createImageData(20,20);
        for(let y=0;y<20;y++)for(let x=0;x<20;x++){
            const i=(y*20+x)*4;d.data[i]=23+x*9;d.data[i+1]=17+y*10;d.data[i+2]=201;d.data[i+3]=255;}
        c.putImageData(d,0,0);parent.appendChild(n);
        // Measure actual untransformed LayoutUnit geometry, before applying the
        // literal parent matrix. Native receives this local rect and same CTM.
        const r=n.getBoundingClientRect();records.push({id,raw:[x,y,w,h],used:[r.x,r.y,r.width,r.height],
            width:n.width,height:n.height,png:n.toDataURL('image/png')});
    };
    make('positive',10.25,10.5,93.25,77.75);make('negative',-10.5,-10.5,100.25,99.25);
    parent.style.transform='matrix('+matrix.join(',')+')';
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    for(let i=0;i<records.length;i++){
        const r=parent.children[i].getBoundingClientRect();records[i].transformedBounds=[r.x,r.y,r.width,r.height];
    }
    const p=parent.getBoundingClientRect(),style=getComputedStyle(parent);
    return JSON.stringify({records,matrix,parent:{bounds:[p.x,p.y,p.width,p.height],transform:style.transform,transformOrigin:style.transformOrigin},
        devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
        visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}

@MainActor private final class SourceCanvasTransformNavigationWaiter: NSObject, WKNavigationDelegate {
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
