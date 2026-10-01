import Testing
import UIKit
import WebKit
import CryptoKit
@testable import Aidoku

/// Calls the production native compositor from a real worker. The two flat
/// controls retain immutable53 A captures; the asymmetric PMA prefix is a new,
/// literal WebKit differential, never a replacement for those references.
@MainActor struct NativeSourceCanvasHierarchyParityCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let placement = CGRect(x: 135, y: 7, width: 91, height: 121)
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private enum Failure: Error { case invalidSource, invalidCapture, invalidPixels }

    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasHierarchyParity", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try write(["expectedCount": 3, "count": 0, "passed": false], to: output.appendingPathComponent("report.json"))
        let bundle = Bundle(for: HierarchyParityFixtureBundle.self)
        let sourceURL = try #require(bundle.url(forResource: "NativeCanvasActual44Mask0", withExtension: "bin"))
        let sourcePNG = try Data(contentsOf: sourceURL)
        guard hash(sourcePNG) == "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d",
              let source = UIImage(data: sourcePNG)?.cgImage, source.width == 412, source.height == 527 else { throw Failure.invalidSource }
        let original = try pixels(source)
        let referencesURL = try #require(bundle.url(forResource: "NativeCanvasHierarchy53References", withExtension: "bin"))
        let referenceBytes = try Data(contentsOf: referencesURL)
        guard hash(referenceBytes) == "996f9f303c79da135a94d36141fdd3aec945e45eb5e3046f807cfca8c6568b41",
              let references = try JSONSerialization.jsonObject(with: referenceBytes) as? [String: [String: String]] else { throw Failure.invalidSource }
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousKey = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIViewController(); window.overrideUserInterfaceStyle = .light
        window.backgroundColor = .clear; window.frame = page; window.makeKeyAndVisible(); window.frame = page
        defer { window.isHidden = true; previousKey?.makeKey() }
        let host = try #require(window.rootViewController?.view); host.frame = page; host.backgroundColor = .clear
        let web = WKWebView(frame: page)
        web.overrideUserInterfaceStyle = .light; web.isOpaque = false; web.backgroundColor = .clear
        web.underPageBackgroundColor = .clear; web.scrollView.backgroundColor = .clear
        web.scrollView.contentInsetAdjustmentBehavior = .never
        host.addSubview(web); defer { web.stopLoading(); web.removeFromSuperview() }
        let waiter = HierarchyParityNavigationWaiter(); try await waiter.load(in: web)
        let scale = window.screen.scale
        var records: [[String: Any]] = [], failures: [String] = []
        for name in ["transparent", "opaque", "asymmetric-pma"] {
            let directory = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let prefix = try makePrefix(name: name, scale: scale)
                let prefixPixels = try save(prefix, name: "prefix", directory: directory)
                let prefixPNG = try #require(UIImage(cgImage: prefix).pngData())
                let raw = try await web.callAsyncJavaScript(Self.script, arguments: ["background": name,
                    "originalPNG": "data:image/png;base64," + sourcePNG.base64EncodedString(),
                    "prefixPNG": "data:image/png;base64," + prefixPNG.base64EncodedString()], in: nil, contentWorld: .page)
                let json = try #require(raw as? String)
                let dom = try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
                try Data(json.utf8).write(to: directory.appendingPathComponent("web-dom.json"))
                let encoded = try #require(dom["png"] as? String), comma = try #require(encoded.firstIndex(of: ","))
                let canvasPNG = try #require(Data(base64Encoded: String(encoded[encoded.index(after: comma)...])))
                let canvasImage = try #require(UIImage(data: canvasPNG)?.cgImage)
                let canvas = try save(canvasImage, name: "web-source", directory: directory)
                let sourceEqual = canvas.width == original.width && canvas.height == original.height && canvas.bytes == original.bytes
                let configuration = WKSnapshotConfiguration(); configuration.rect = page; configuration.snapshotWidth = 320
                let snapshot: UIImage = try await withCheckedThrowingContinuation { continuation in
                    web.takeSnapshot(with: configuration) { image, error in
                        if let error { continuation.resume(throwing: error) }
                        else if let image { continuation.resume(returning: image) }
                        else { continuation.resume(throwing: Failure.invalidCapture) }
                    }
                }
                let reference = try save(try #require(snapshot.cgImage), name: "web", directory: directory)
                let request = NativeSourceCanvasHierarchyCompositor.Request(prefix: prefix, source: source,
                    viewport: page.size, scale: scale, sourceFrame: placement)
                let job = Task.detached {
                    let worker = Self.isWorkerThread()
                    let image = try NativeSourceCanvasHierarchyCompositor.compose(request)
                    return (image, worker)
                }
                let (result, worker) = try await withTaskCancellationHandler(operation: { try await job.value }, onCancel: { job.cancel() })
                let native = try save(try #require(result), name: "native", directory: directory)
                var record = compare(reference, native)
                record["name"] = name; record["workerWasOffMain"] = worker
                record["sourceCanonicalEqual"] = sourceEqual; record["sourceHash"] = hash(original.bytes)
                record["prefixHash"] = hash(prefixPixels.bytes); record["screenScale"] = scale
                record["prefixPattern"] = name == "asymmetric-pma" ? "two columns by three rows; PMA alpha64/173/192" : name
                var immutableWebEqual = true
                if let frozen = references[name], let text = frozen["png"], let bytes = Data(base64Encoded: text),
                   hash(bytes) == frozen["sha256"], let image = UIImage(data: bytes)?.cgImage {
                    try bytes.write(to: directory.appendingPathComponent("immutable53-web.png"))
                    let originalReference = try pixels(image)
                    record["nativeVsImmutable53"] = compare(originalReference, native)
                    record["freshWebVsImmutable53"] = compare(originalReference, reference)
                    immutableWebEqual = originalReference.bytes == reference.bytes
                } else if name != "asymmetric-pma" { throw Failure.invalidSource }
                let acceptance = NativeSourceCanvasResamplingAcceptance.assess(reference: reference.bytes, candidate: native.bytes,
                    width: native.width, height: native.height, frames: [placement], outputScale: scale, mode: .sourceDraw)
                let controls = NativeSourceCanvasResamplingAcceptance.negativeControls(reference: reference.bytes, candidate: native.bytes,
                    prefix: prefixPixels.bytes, width: native.width, height: native.height,
                    frames: [placement], outputScale: scale, mode: .sourceDraw)
                record["nativeResamplingAcceptance"] = acceptance.report
                record["negativeControlsRejected"] = controls
                let passed = sourceEqual && worker && immutableWebEqual && native.width == reference.width
                    && native.height == reference.height && acceptance.accepted
                    && controls.count == 4 && controls.values.allSatisfy { $0 }
                record["passed"] = passed
                try write(record, to: directory.appendingPathComponent("comparison.json")); records.append(record)
                if !passed { failures.append(name + ": native sampling/source/worker/oracle/control mismatch") }
            } catch {
                failures.append(name + ": " + String(describing: error))
                try write(["error": String(describing: error)], to: directory.appendingPathComponent("failure.json"))
            }
        }
        try write(["expectedCount": 3, "count": records.count, "passed": records.count == 3 && failures.isEmpty,
            "reports": records, "failures": failures, "screenScale": scale, "os": UIDevice.current.systemVersion,
            "scope": "native worker source sampler; exact source/oracle/geometry/outside footprint; bounded source-only resampling; raw strict RGBA retained"],
            to: output.appendingPathComponent("report.json"))
        #expect(records.count == 3 && failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    nonisolated private static func isWorkerThread() -> Bool { !Thread.isMainThread }

    private func makePrefix(name: String, scale: CGFloat) throws -> CGImage {
        let width = Int(page.width * scale), height = Int(page.height * scale)
        var bytes = Data(count: width * height * 4)
        bytes.withUnsafeMutableBytes { storage in
            let values = storage.bindMemory(to: UInt8.self)
            for y in 0..<height { for x in 0..<width {
                let color: [UInt8]
                if name == "transparent" { color = [0,0,0,0] }
                else if name == "opaque" { color = [41,65,87,255] }
                else {
                    let colors: [[UInt8]] = [[20,7,50,64],[130,4,30,173],[8,112,39,192],
                                             [47,1,9,64],[17,145,66,173],[181,28,12,192]]
                    color = colors[min(2, y * 3 / height) + (x < width / 2 ? 0 : 3)]
                }
                let offset = (y * width + x) * 4
                for channel in 0..<4 { values[offset + channel] = color[channel] }
            } }
        }
        let provider = try #require(CGDataProvider(data: bytes as CFData))
        return try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
            bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)),
            provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
            let data = context.data else { throw Failure.invalidPixels }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, height: image.height, bytes: Data(bytes: data, count: image.width * image.height * 4))
    }
    private func save(_ image: CGImage, name: String, directory: URL) throws -> Pixels {
        try #require(UIImage(cgImage: image).pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        let result = try pixels(image); try result.bytes.write(to: directory.appendingPathComponent(name + ".rgba"))
        return result
    }
    private func compare(_ left: Pixels, _ right: Pixels) -> [String: Any] {
        guard left.width == right.width, left.height == right.height else { return ["exactRGBA": false, "dimensionsEqual": false] }
        var changed = 0, maximum = 0
        left.bytes.withUnsafeBytes { a in right.bytes.withUnsafeBytes { b in
            let lhs = a.bindMemory(to: UInt8.self), rhs = b.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: lhs.count, by: 4) {
                var different = false
                for channel in 0..<4 { let delta = abs(Int(lhs[index + channel]) - Int(rhs[index + channel])); maximum = max(maximum, delta); different = different || delta != 0 }
                if different { changed += 1 }
            }
        } }
        return ["exactRGBA": changed == 0, "changedPixels": changed, "maxChannelDelta": maximum,
            "webRGBAHash": hash(left.bytes), "nativeRGBAHash": hash(right.bytes), "width": left.width, "height": left.height]
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func write(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted,.sortedKeys]).write(to: url, options: .atomic)
    }
    // Original53 A producer/readback sequence. The new literal prefix is an image
    // below the canvas only for the third case; the two historical inputs remain unchanged.
    private static let script = #"""
    document.body.replaceChildren();document.documentElement.style.background='transparent';
    document.body.style.background=background==='opaque'?'rgb(41,65,87)':'transparent';
    if(background==='asymmetric-pma'){
      const prefix=new Image();prefix.src=prefixPNG;await prefix.decode();
      Object.assign(prefix.style,{position:'absolute',left:'0px',top:'0px',width:'320px',height:'160px'});
      document.body.appendChild(prefix);
    }
    const image=new Image();image.src=originalPNG;await image.decode();
    const canvas=document.createElement('canvas');canvas.width=412;canvas.height=527;
    Object.assign(canvas.style,{position:'absolute',left:'135px',top:'7px',width:'91px',height:'121px'});
    const context=canvas.getContext('2d');context.drawImage(image,0,0,412,527);
    document.body.appendChild(canvas);const png=canvas.toDataURL('image/png');
    await new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)));
    const r=canvas.getBoundingClientRect();
    return JSON.stringify({background,png,used:[r.x,r.y,r.width,r.height],intrinsic:[canvas.width,canvas.height],
      devicePixelRatio,innerWidth,innerHeight,scrollX,scrollY,readbackTiming:'synchronous-before-RAF',
      contextAttributes:context.getContextAttributes?.()??null,imageSmoothingEnabled:context.imageSmoothingEnabled,
      imageSmoothingQuality:context.imageSmoothingQuality});
    """#
}
private final class HierarchyParityFixtureBundle: NSObject {}
@MainActor private final class HierarchyParityNavigationWaiter: NSObject, WKNavigationDelegate {
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
    func webView(_ view: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
    func webView(_ view: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { continuation?.resume(throwing: error); continuation = nil }
}
