import Testing
import UIKit
import WebKit
import CryptoKit
@testable import Aidoku

/// Capture/source completeness only. Pixel and interior differences remain
/// descriptive; the existing four foreign-background assertions are unchanged.
@MainActor
struct NativeConstantGradientBackendDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let frame = CGRect(x: 20, y: 20, width: 96, height: 96)
    private let interior = CGRect(x: 22, y: 22, width: 92, height: 92)
    private let colors: [(String, [CGFloat])] = [("red", [220,30,40]), ("blue", [30,40,220])]
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private enum Failure: Error { case invalidSource, invalidCapture, invalidPixels }

    func run() async throws {
        let directory = URL.documentsDirectory.appendingPathComponent("NativeConstantGradientBackendDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try json(["expectedCount": 12, "count": 0, "originalExpectedCount": 8, "offscreenExpectedCount": 4, "passed": false, "pixelParityAsserted": false, "reports": []],
                 to: directory.appendingPathComponent("report.json"))
        let source: [String: Any] = ["colors": colors.map { ["name": $0.0, "RGB": $0.1] as [String: Any] },
            "page": values(page), "gradientFrame": values(frame), "borderFreeInterior": values(interior),
            "backgroundRGB": [41,65,87], "gradientStops": [0,1], "colorComponents": "Float(RGB/255) promoted to CGFloat; alpha 1",
            "source": "literal CSS linear-gradient(rgb, rgb), no border or radius; no inferred expected geometry"]
        let sourceData = try JSONSerialization.data(withJSONObject: source, options: [.sortedKeys])
        try sourceData.write(to: directory.appendingPathComponent("literal-source.json"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let originalKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light
        window.frame = page; window.backgroundColor = .clear; window.makeKeyAndVisible(); window.frame = page
        defer { window.isHidden = true; originalKey?.makeKey() }
        let host = try #require(window.rootViewController?.view)
        host.frame = page; host.backgroundColor = .clear
        let web = WKWebView(frame: page)
        web.overrideUserInterfaceStyle = .light; web.isOpaque = true
        web.backgroundColor = UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1)
        web.underPageBackgroundColor = web.backgroundColor!; web.scrollView.backgroundColor = web.backgroundColor
        web.scrollView.contentInsetAdjustmentBehavior = .never
        host.addSubview(web)
        defer { web.stopLoading(); web.removeFromSuperview() }
        let waiter = ConstantGradientNavigationWaiter(); try await waiter.load(in: web)
        var reports: [[String: Any]] = [], comparisons: [[String: Any]] = [], failures: [String] = []
        for (name, rgb) in colors {
            let output = directory.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            var reference: Pixels?
            do {
                let returned = try await web.callAsyncJavaScript(Self.script, arguments: ["rgb": rgb.map { Double($0) }],
                    in: nil, contentWorld: .page)
                let text = try #require(returned as? String)
                let dom = try #require(try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
                try Data(text.utf8).write(to: output.appendingPathComponent("web-dom.json"))
                let valid = (dom["usedFrame"] as? [Double]) == values(frame) && (dom["sourceRGB"] as? [Double]) == rgb.map { Double($0) } &&
                    (dom["borderRadius"] as? String) == "0px" && (dom["borderWidth"] as? String) == "0px"
                #expect(valid)
                guard valid else { throw Failure.invalidSource }
                let configuration = WKSnapshotConfiguration(); configuration.rect = page; configuration.snapshotWidth = 320
                let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: configuration) { image, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: Failure.invalidCapture) }
                    }
                }
                let observed = try save(try #require(snapshot.cgImage), name: "web", output: output)
                reference = observed
                reports.append(try record(observed, scene: name, mode: "web", metadata: ["viewport": viewport(web),
                    "UIImageScale": snapshot.scale, "UIImageOrientation": snapshot.imageOrientation.rawValue], output: output))
            } catch { failures.append("\(name)/web: \(error)") }
            do {
                let cpu = try cpuImage(rgb: rgb, scale: window.screen.scale)
                let observed = try save(cpu.image, name: "cpu-bitmap", output: output)
                reports.append(try record(observed, scene: name, mode: "cpu-bitmap", metadata: cpu.metadata, output: output))
                if let reference { comparisons.append(compare(reference, observed, scene: name, mode: "cpu-bitmap")) }
            } catch { failures.append("\(name)/cpu-bitmap: \(error)") }
            web.isHidden = true
            for mode in ["ui-view-draw", "ca-gradient-layer"] {
                let nativeHost = UIView(frame: page)
                nativeHost.isOpaque = true; nativeHost.backgroundColor = UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1)
                host.addSubview(nativeHost)
                let drawing: ConstantGradientPaintView?
                let gradientLayer: CAGradientLayer?
                if mode == "ui-view-draw" {
                    let view = ConstantGradientPaintView(frame: frame, rgb: rgb)
                    view.isOpaque = false; view.backgroundColor = .clear; view.contentScaleFactor = window.screen.scale
                    nativeHost.addSubview(view); drawing = view; gradientLayer = nil
                    view.phase = "onscreen-display"; view.setNeedsDisplay(); view.layer.displayIfNeeded()
                } else {
                    let layer = CAGradientLayer()
                    layer.frame = frame; layer.contentsScale = window.screen.scale
                    layer.type = .axial; layer.startPoint = CGPoint(x: 0.5, y: 0); layer.endPoint = CGPoint(x: 0.5, y: 1)
                    layer.locations = [0,1]; layer.colors = [ConstantGradientPaintView.color(rgb), ConstantGradientPaintView.color(rgb)]
                    nativeHost.layer.addSublayer(layer); gradientLayer = layer; drawing = nil
                    layer.setNeedsDisplay(); layer.displayIfNeeded()
                }
                do {
                    drawing?.phase = "public-drawHierarchy"
                    let format = UIGraphicsImageRendererFormat(); format.scale = window.screen.scale
                    format.preferredRange = .standard; format.opaque = true
                    var captured = false, hierarchyContext: [String: Any] = [:]
                    let image = UIGraphicsImageRenderer(size: page.size, format: format).image { value in
                        hierarchyContext = ConstantGradientPaintView.contextMetadata(value.cgContext)
                        captured = nativeHost.drawHierarchy(in: page, afterScreenUpdates: true)
                    }
                    let observed = try save(try #require(image.cgImage), name: mode, output: output)
                    var info: [String: Any] = ["drawHierarchySucceeded": captured, "hierarchyCaptureContext": hierarchyContext,
                        "hostLayer": layerMetadata(nativeHost.layer), "sourceRGB": rgb,
                        "declaredSRGBComponents": ConstantGradientPaintView.color(rgb).components ?? [],
                        "declaredCGColorSpace": ConstantGradientPaintView.color(rgb).colorSpace?.name as String? ?? "nil"]
                    if let drawing {
                        info["ownViewFrame"] = values(drawing.frame); info["ownLayer"] = layerMetadata(drawing.layer)
                        var observations: [[String: Any]] = []
                        for (index, entry) in drawing.observations.enumerated() {
                            var metadata = entry.metadata
                            if let data = entry.raw {
                                let file = "ui-view-own-backing-\(index).raw"; try data.write(to: output.appendingPathComponent(file))
                                metadata["rawFile"] = file; metadata["rawHash"] = hash(data)
                            }
                            observations.append(metadata)
                        }
                        info["drawContexts"] = observations
                        #expect(!observations.isEmpty)
                        if observations.isEmpty { failures.append("\(name)/\(mode): draw callback absent") }
                    }
                    if let layer = gradientLayer {
                        info["gradientLayer"] = layerMetadata(layer)
                        info["gradientStartPoint"] = [layer.startPoint.x,layer.startPoint.y]
                        info["gradientEndPoint"] = [layer.endPoint.x,layer.endPoint.y]
                        info["gradientLocations"] = layer.locations ?? []
                        info["gradientType"] = layer.type.rawValue
                        info["colorSpaceInterpretation"] = "declared CGColor stops are sRGB Float-promoted components; private CA working/compositing space is unobserved"
                    }
                    #expect(captured)
                    if !captured { failures.append("\(name)/\(mode): hierarchy capture failed") }
                    reports.append(try record(observed, scene: name, mode: mode, metadata: info, output: output))
                    if let reference { comparisons.append(compare(reference, observed, scene: name, mode: mode)) }
                    if let gradient = gradientLayer {
                        // Public render(in:) on the very same attached host/layer
                        // after the original hierarchy capture; no recapture is
                        // substituted for its offscreen output.
                        do {
                            let painted = try offscreenImage(layer: nativeHost.layer, gradient: gradient,
                                scale: window.screen.scale, mode: "ca-layer-render-attached", attached: nativeHost.window != nil)
                            let offscreen = try save(painted.image, name: "ca-layer-render-attached", output: output)
                            reports.append(try record(offscreen, scene: name, mode: "ca-layer-render-attached", metadata: painted.metadata, output: output))
                            if let reference { comparisons.append(compare(reference, offscreen, scene: name, mode: "ca-layer-render-attached")) }
                        } catch { failures.append("\(name)/ca-layer-render-attached: \(error)") }
                    }
                } catch { failures.append("\(name)/\(mode): \(error)") }
                gradientLayer?.removeFromSuperlayer(); drawing?.removeFromSuperview(); nativeHost.removeFromSuperview()
            }
            do {
                let detachedRoot = CALayer(); detachedRoot.frame = page; detachedRoot.bounds = page
                detachedRoot.backgroundColor = ConstantGradientPaintView.color([41,65,87])
                let child = CAGradientLayer(); child.frame = frame; child.contentsScale = window.screen.scale
                child.type = .axial; child.startPoint = CGPoint(x: 0.5, y: 0); child.endPoint = CGPoint(x: 0.5, y: 1)
                child.locations = [0,1]; child.colors = [ConstantGradientPaintView.color(rgb),ConstantGradientPaintView.color(rgb)]
                detachedRoot.addSublayer(child)
                defer { child.removeFromSuperlayer() }
                detachedRoot.displayIfNeeded(); child.displayIfNeeded()
                let painted = try offscreenImage(layer: detachedRoot, gradient: child, scale: window.screen.scale,
                    mode: "ca-layer-render-detached", attached: false)
                let observed = try save(painted.image, name: "ca-layer-render-detached", output: output)
                reports.append(try record(observed, scene: name, mode: "ca-layer-render-detached", metadata: painted.metadata, output: output))
                if let reference { comparisons.append(compare(reference, observed, scene: name, mode: "ca-layer-render-detached")) }
            } catch { failures.append("\(name)/ca-layer-render-detached: \(error)") }
            web.isHidden = false
        }
        let dimensionsValid = reports.allSatisfy { ($0["width"] as? Int) == Int(page.width * window.screen.scale) && ($0["height"] as? Int) == Int(page.height * window.screen.scale) }
        #expect(dimensionsValid)
        if !dimensionsValid { failures.append("captured dimensions differ from actual screen-scale page") }
        let offscreenCount = reports.filter { ($0["mode"] as? String)?.hasPrefix("ca-layer-render-") == true }.count
        let originalCount = reports.count - offscreenCount
        try json(["expectedCount": 12, "count": reports.count, "passed": originalCount == 8 && offscreenCount == 4 && failures.isEmpty,
            "originalExpectedCount": 8, "originalCount": originalCount, "offscreenExpectedCount": 4, "offscreenCount": offscreenCount,
            "pixelParityAsserted": false, "scope": "public constant-gradient backing-route observations; diagnostic success is not native render equivalence",
            "sourceHash": hash(sourceData), "scriptHash": hash(Data(Self.script.utf8)), "screenScale": window.screen.scale,
            "gradientFrame": values(frame), "borderFreeInterior": values(interior), "canonicalRGBA": "sRGB premultiplied RGBA8",
            "reports": reports, "descriptiveComparisons": comparisons, "failures": failures], to: directory.appendingPathComponent("report.json"))
        #expect(originalCount == 8)
        #expect(offscreenCount == 4)
        #expect(reports.count == 12)
        #expect(failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
    private func offscreenImage(layer: CALayer, gradient: CAGradientLayer, scale: CGFloat,
                                mode: String, attached: Bool) throws -> (image: CGImage, metadata: [String: Any]) {
        let width = Int(page.width * scale), height = Int(page.height * scale)
        let context = try #require(CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(height)); context.scaleBy(x: scale, y: -scale)
        context.clear(page)
        layer.render(in: context)
        var metadata: [String: Any] = ["consumer": "public CALayer.render(in: CGContext)", "mode": mode,
            "attachedToWindow": attached, "rootHasSuperlayer": layer.superlayer != nil,
            "rootLayer": layerMetadata(layer), "gradientLayer": layerMetadata(gradient),
            "gradientType": gradient.type.rawValue, "gradientLocations": gradient.locations ?? [],
            "gradientStartPoint": [gradient.startPoint.x,gradient.startPoint.y],
            "gradientEndPoint": [gradient.endPoint.x,gradient.endPoint.y], "CGContext": ConstantGradientPaintView.contextMetadata(context),
            "windowOrDrawHierarchyCallInPainter": false,
            "colorSpaceInterpretation": "declared CGColor stops sRGB Float-promoted; offscreen CGContext explicit sRGB RGBA8; private CA working color space unobserved"]
        metadata["declaredStops"] = (gradient.colors ?? []).map { value -> [String: Any] in
            let color = value as! CGColor
            return ["colorSpace": color.colorSpace?.name as String? ?? "nil", "components": color.components ?? []]
        }
        if let data = context.data { metadata["rawBackingHash"] = hash(Data(bytes: data, count: context.bytesPerRow * context.height)) }
        return (try #require(context.makeImage()), metadata)
    }
    private func cpuImage(rgb: [CGFloat], scale: CGFloat) throws -> (image: CGImage, metadata: [String: Any]) {
        let w = Int(page.width * scale), h = Int(page.height * scale)
        let context = try #require(CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        context.translateBy(x: 0, y: CGFloat(h)); context.scaleBy(x: scale, y: -scale)
        context.setFillColor(ConstantGradientPaintView.color([41,65,87])); context.fill(page)
        let gradient = try #require(ConstantGradientPaintView.gradient(rgb))
        context.saveGState(); context.clip(to: frame); context.translateBy(x: frame.minX, y: frame.minY)
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: frame.height), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
        context.restoreGState()
        var metadata = ConstantGradientPaintView.contextMetadata(context)
        metadata["constructor"] = "CGGradientCreateWithColorComponents, Float-promoted sRGB components, locations 0/1"
        if let data = context.data { metadata["rawBackingHash"] = hash(Data(bytes: data, count: context.bytesPerRow * context.height)) }
        return (try #require(context.makeImage()), metadata)
    }
    private func record(_ pixels: Pixels, scene: String, mode: String, metadata: [String: Any], output: URL) throws -> [String: Any] {
        let region = scaledInterior(pixels)
        let interiorBytes = crop(pixels, region: region)
        try interiorBytes.write(to: output.appendingPathComponent(mode + "-interior.rgba"))
        let report: [String: Any] = ["scene": scene, "mode": mode, "width": pixels.width, "height": pixels.height,
            "RGBAHash": hash(pixels.bytes), "interiorPixelRect": values(region), "interiorHash": hash(interiorBytes),
            "interiorPalette": palette(interiorBytes), "metadata": metadata]
        try json(report, to: output.appendingPathComponent(mode + "-capture.json")); return report
    }
    private func compare(_ a: Pixels, _ b: Pixels, scene: String, mode: String) -> [String: Any] {
        guard a.width == b.width && a.height == b.height else { return ["scene": scene,"mode": mode,"exactRGBA": false,"dimensionMismatch": true] }
        func difference(_ x: Data, _ y: Data) -> [String: Any] {
            var count = 0, maximum = 0
            x.withUnsafeBytes { lhs in y.withUnsafeBytes { rhs in
                let left = lhs.bindMemory(to: UInt8.self), right = rhs.bindMemory(to: UInt8.self)
                for p in stride(from: 0, to: x.count, by: 4) {
                    var changed = false
                    for c in 0..<4 { let d = abs(Int(left[p+c])-Int(right[p+c])); maximum = max(maximum,d); changed = changed || d != 0 }
                    if changed { count += 1 }
                }
            } }
            return ["exactRGBA": count == 0,"changedPixels": count,"maxChannelDelta": maximum]
        }
        return ["scene": scene,"mode": mode,"fullPage": difference(a.bytes,b.bytes),
            "borderFreeInterior": difference(crop(a,region:scaledInterior(a)),crop(b,region:scaledInterior(b))),
            "pixelAcceptance": "none; descriptive only"]
    }
    private func scaledInterior(_ p: Pixels) -> CGRect {
        let scale = CGFloat(p.width) / page.width
        return CGRect(x: interior.minX * scale, y: interior.minY * scale, width: interior.width * scale, height: interior.height * scale)
    }
    private func crop(_ p: Pixels, region: CGRect) -> Data {
        var bytes = Data()
        for y in Int(region.minY)..<Int(region.maxY) {
            let start = (y * p.width + Int(region.minX)) * 4
            bytes.append(p.bytes.subdata(in: start..<(start + Int(region.width) * 4)))
        }
        return bytes
    }
    private func palette(_ data: Data) -> [[String: Any]] {
        var values: [String:Int] = [:]
        data.withUnsafeBytes { source in
            let bytes = source.bindMemory(to: UInt8.self)
            for i in stride(from: 0, to: data.count, by: 4) { values["\(bytes[i]),\(bytes[i+1]),\(bytes[i+2]),\(bytes[i+3])",default:0] += 1 }
        }
        return values.keys.sorted().map { ["RGBA": $0,"count": values[$0]!] }
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        let pointer = try #require(context.data)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return .init(width: image.width, height: image.height, bytes: Data(bytes: pointer, count: image.width * image.height * 4))
    }
    private func save(_ image: CGImage, name: String, output: URL) throws -> Pixels {
        let png = try #require(UIImage(cgImage: image).pngData())
        try png.write(to: output.appendingPathComponent(name + ".png"))
        let p = try pixels(image); try p.bytes.write(to: output.appendingPathComponent(name + ".rgba")); return p
    }
    private func viewport(_ web: WKWebView) -> [String: Any] {
        ["bounds": values(web.bounds),"contentInset": [web.scrollView.contentInset.top,web.scrollView.contentInset.right,web.scrollView.contentInset.bottom,web.scrollView.contentInset.left],
         "adjustedContentInset": [web.scrollView.adjustedContentInset.top,web.scrollView.adjustedContentInset.right,web.scrollView.adjustedContentInset.bottom,web.scrollView.adjustedContentInset.left],
         "contentOffset": [web.scrollView.contentOffset.x,web.scrollView.contentOffset.y]]
    }
    private func layerMetadata(_ layer: CALayer) -> [String: Any] {
        ["frame": values(layer.frame),"bounds": values(layer.bounds),"contentsScale": layer.contentsScale,
         "rasterizationScale": layer.rasterizationScale,"shouldRasterize": layer.shouldRasterize,"contentsFormat": layer.contentsFormat.rawValue,
         "opaque": layer.isOpaque,"opacity": layer.opacity,"cornerRadius": layer.cornerRadius,"masksToBounds": layer.masksToBounds]
    }
    private func values(_ r: CGRect) -> [Double] { [r.minX,r.minY,r.width,r.height] }
    private func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
    private func json(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.prettyPrinted]).write(to: url, options: .atomic)
    }
    private static let script = #"""
    document.body.replaceChildren();document.documentElement.style.background='rgb(41,65,87)';document.body.style.background='rgb(41,65,87)';
    const div=document.createElement('div'),color='rgb('+rgb.join(',')+')';
    Object.assign(div.style,{position:'absolute',left:'20px',top:'20px',width:'96px',height:'96px',border:'0',borderRadius:'0px',padding:'0',
      backgroundImage:'linear-gradient('+color+','+color+')',backgroundPosition:'0px 0px',backgroundSize:'96px 96px',backgroundRepeat:'no-repeat'});
    document.body.appendChild(div);await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const r=div.getBoundingClientRect(),s=getComputedStyle(div);
    return JSON.stringify({sourceRGB:rgb,usedFrame:[r.x,r.y,r.width,r.height],backgroundImage:s.backgroundImage,
      backgroundSize:s.backgroundSize,backgroundPosition:s.backgroundPosition,backgroundRepeat:s.backgroundRepeat,
      borderRadius:s.borderRadius,borderWidth:s.borderWidth,devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,
      visualViewport:visualViewport&&{width:visualViewport.width,height:visualViewport.height,scale:visualViewport.scale}});
    """#
}

@MainActor private final class ConstantGradientPaintView: UIView {
    struct Observation { let metadata: [String: Any]; let raw: Data? }
    let rgb: [CGFloat]; var phase = "unassigned"; var observations: [Observation] = []
    init(frame: CGRect, rgb: [CGFloat]) { self.rgb = rgb; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("immutable source gradient required") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext(), let gradient = Self.gradient(rgb) else { return }
        var metadata = Self.contextMetadata(context)
        metadata["phase"] = phase; metadata["dirtyRect"] = [rect.minX,rect.minY,rect.width,rect.height]
        metadata["constructor"] = "CGGradientCreateWithColorComponents, Float-promoted sRGB components, locations 0/1"
        context.saveGState(); context.clip(to: bounds)
        context.drawLinearGradient(gradient, start: .zero, end: CGPoint(x: 0, y: bounds.height), options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
        context.restoreGState()
        let count = context.bytesPerRow * context.height
        let data = count > 0 && count <= 4_000_000 ? context.data.map { Data(bytes: $0,count:count) } : nil
        observations.append(.init(metadata: metadata,raw:data))
    }
    static func components(_ rgb: [CGFloat]) -> [CGFloat] { rgb.map { CGFloat(Float($0 / 255)) } + [1] }
    static func color(_ rgb: [CGFloat]) -> CGColor { CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: components(rgb))! }
    static func gradient(_ rgb: [CGFloat]) -> CGGradient? {
        let stop = components(rgb)
        return CGGradient(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, colorComponents: stop + stop, locations: [0,1], count: 2)
    }
    static func contextMetadata(_ c: CGContext) -> [String: Any] {
        ["width": c.width,"height": c.height,"bitsPerComponent": c.bitsPerComponent,"bitsPerPixel": c.bitsPerPixel,
         "bytesPerRow": c.bytesPerRow,"bitmapInfo": c.bitmapInfo.rawValue,"alphaInfo": c.alphaInfo.rawValue,
         "colorSpace": c.colorSpace?.name as String? ?? "nil","dataAvailable": c.data != nil,
         "interpolationQuality": c.interpolationQuality.rawValue,"CTM": [c.ctm.a,c.ctm.b,c.ctm.c,c.ctm.d,c.ctm.tx,c.ctm.ty]]
    }
}
@MainActor private final class ConstantGradientNavigationWaiter: NSObject, WKNavigationDelegate {
    private var continuation: CheckedContinuation<Void, Error>?
    func load(in web: WKWebView) async throws {
        web.navigationDelegate = self
        try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            web.loadHTMLString("<html><head><meta name='viewport' content='width=device-width,initial-scale=1'>" +
                "<style>html,body{margin:0;background:rgb(41,65,87)}</style></head><body></body></html>", baseURL: nil)
        }
    }
    func webView(_ web: WKWebView, didFinish navigation: WKNavigation!) { continuation?.resume(); continuation=nil }
    func webView(_ web: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing:error);continuation=nil }
    func webView(_ web: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing:error);continuation=nil }
}
