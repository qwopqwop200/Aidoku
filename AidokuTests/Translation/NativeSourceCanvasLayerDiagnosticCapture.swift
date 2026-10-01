import Testing
import UIKit
import CryptoKit

/// Four public on-screen CALayer.contents controls. Stock minification filters
/// only; source identity and display/capture completeness are asserted.
@MainActor struct NativeSourceCanvasLayerDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let placement = CGRect(x: 135, y: 7, width: 91, height: 121)
    private let sourceHash = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private enum Failure: Error { case invalidSource, invalidPixels, invalidCapture }
    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasLayerDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 4, "count": 0, "complete": false, "pixelParityAsserted": false],
            to: output.appendingPathComponent("report.json"))
        let fixture = try #require(Bundle(for: LayerDiagnosticFixtureBundle.self)
            .url(forResource: "NativeCanvasActual44Mask0", withExtension: "bin"))
        let encoded = try Data(contentsOf: fixture), image = try #require(UIImage(data: encoded)?.cgImage)
        guard hash(encoded) == sourceHash, image.width == 412, image.height == 527 else { throw Failure.invalidSource }
        let original = try pixels(image)
        try encoded.write(to: output.appendingPathComponent("immutable-source.png"))
        try original.bytes.write(to: output.appendingPathComponent("immutable-source.rgba"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene); window.rootViewController = UIViewController()
        window.overrideUserInterfaceStyle = .light; window.frame = page; window.backgroundColor = .clear
        window.makeKeyAndVisible(); window.frame = page; defer { window.isHidden = true }
        let root = try #require(window.rootViewController?.view); root.frame = page; root.backgroundColor = .clear
        var records: [[String: Any]] = [], captures: [String: Pixels] = [:], failures: [String] = []
        for background in ["transparent", "opaque"] {
            for (filterName, filter) in [("linear", CALayerContentsFilter.linear), ("trilinear", .trilinear)] {
                let name = background + "-" + filterName
                do {
                    let host = UIView(frame: page); host.isOpaque = background == "opaque"
                    host.backgroundColor = background == "opaque"
                        ? UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1) : .clear
                    root.addSubview(host); defer { host.removeFromSuperview() }
                    let layer = CALayer()
                    let defaultMinificationFilter = layer.minificationFilter.rawValue
                    CATransaction.begin(); CATransaction.setDisableActions(true)
                    layer.frame = placement; layer.contentsGravity = .resize
                    layer.contentsScale = window.screen.scale; layer.contents = image
                    layer.minificationFilter = filter
                    host.layer.addSublayer(layer); CATransaction.commit()
                    guard await LayerDiagnosticDisplayTicks().wait() else { throw Failure.invalidCapture }
                    let format = UIGraphicsImageRendererFormat(); format.scale = window.screen.scale
                    format.preferredRange = .standard; format.opaque = background == "opaque"
                    var succeeded = false
                    let captured = UIGraphicsImageRenderer(size: page.size, format: format).image { _ in
                        succeeded = host.drawHierarchy(in: page, afterScreenUpdates: true)
                    }
                    let base = output.appendingPathComponent(name, isDirectory: true)
                    try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                    let actualSource = try save(image, prefix: "source-realized", output: base)
                    let bytes = try save(try #require(captured.cgImage), prefix: "capture", output: base)
                    let sameSource = actualSource.bytes == original.bytes && actualSource.width == original.width && actualSource.height == original.height
                    let dimensions = bytes.width == Int((page.width * window.screen.scale).rounded()) &&
                        bytes.height == Int((page.height * window.screen.scale).rounded())
                    let geometry = layer.frame == placement && layer.bounds.size == placement.size &&
                        host.bounds == page && layer.contentsGravity == .resize && layer.contentsScale == window.screen.scale
                    if !sameSource || !dimensions || !geometry || !succeeded { failures.append(name + ": invalid source/geometry/capture control") }
                    captures[name] = bytes
                    let record: [String: Any] = ["name": name, "background": background,
                        "minificationFilter": layer.minificationFilter.rawValue,
                        "defaultMinificationFilter": defaultMinificationFilter,
                        "magnificationFilter": layer.magnificationFilter.rawValue,
                        "minificationFilterBias": layer.minificationFilterBias,
                        "contentsGravity": layer.contentsGravity.rawValue, "contentsScale": layer.contentsScale,
                        "contentsRect": rect(layer.contentsRect), "contentsCenter": rect(layer.contentsCenter),
                        "frame": rect(layer.frame), "bounds": rect(layer.bounds),
                        "rasterizationScale": layer.rasterizationScale, "shouldRasterize": layer.shouldRasterize,
                        "allowsEdgeAntialiasing": layer.allowsEdgeAntialiasing, "opaque": layer.isOpaque,
                        "sourceReadback": "Canonical source read before first native display; contents source unchanged",
                        "sourceMetadata": metadata(image), "sourceCanonicalRGBAEqual": sameSource,
                        "sourceCanonicalRGBAHash": hash(actualSource.bytes), "captureRGBAHash": hash(bytes.bytes),
                        "drawHierarchySucceeded": succeeded, "captureDimensionsValid": dimensions,
                        "geometryValid": geometry, "captureSize": [bytes.width, bytes.height],
                        "screenScale": window.screen.scale, "viewport": rect(page), "sourcePlacement": rect(placement),
                        "publicCaptureIsWebKitEquivalent": false, "displayTicks": 2]
                    try writeJSON(record, to: base.appendingPathComponent("capture.json")); records.append(record)
                } catch { failures.append(name + ": " + String(describing: error)) }
            }
        }
        var comparisons: [[String: Any]] = []
        for background in ["transparent", "opaque"] {
            if let a = captures[background + "-linear"], let b = captures[background + "-trilinear"] {
                var comparison = compare(a, b); comparison["background"] = background
                comparisons.append(comparison)
            }
        }
        try writeJSON(["expectedCount": 4, "count": records.count, "complete": records.count == 4,
            "sourceAndCaptureControlsPassed": records.count == 4 && failures.isEmpty,
            "pixelParityAsserted": false, "failures": failures, "reports": records,
            "filterComparisons": comparisons, "os": UIDevice.current.systemVersion,
            "fixturePNGHash": sourceHash, "scope": "Public on-screen CALayer.contents with stock linear/trilinear minification; no LOD/bias/filter fitting or private API."],
            to: output.appendingPathComponent("report.json"))
        #expect(records.count == 4 && failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
    private func pixels(_ image: CGImage) throws -> Pixels {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                bytesPerRow: image.width * 4, space: space,
                bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue),
              let data = context.data else { throw Failure.invalidPixels }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Pixels(width: image.width, height: image.height, bytes: Data(bytes: data, count: image.width * image.height * 4))
    }
    private func save(_ image: CGImage, prefix: String, output: URL) throws -> Pixels {
        guard let png = UIImage(cgImage: image).pngData() else { throw Failure.invalidCapture }
        try png.write(to: output.appendingPathComponent(prefix + ".png"))
        let result = try pixels(image); try result.bytes.write(to: output.appendingPathComponent(prefix + ".rgba"))
        return result
    }
    private func metadata(_ image: CGImage) -> [String: Any] {
        ["width": image.width, "height": image.height, "bitsPerComponent": image.bitsPerComponent,
         "bitsPerPixel": image.bitsPerPixel, "bytesPerRow": image.bytesPerRow, "alphaInfo": image.alphaInfo.rawValue,
         "bitmapInfo": image.bitmapInfo.rawValue, "colorSpace": image.colorSpace?.name as String? ?? "nil",
         "shouldInterpolate": image.shouldInterpolate]
    }
    private func compare(_ a: Pixels, _ b: Pixels) -> [String: Any] {
        guard a.width == b.width, a.height == b.height else { return ["dimensionsEqual": false] }
        var count = 0, maximum = 0
        a.bytes.withUnsafeBytes { ar in b.bytes.withUnsafeBytes { br in
            let aa = ar.bindMemory(to: UInt8.self), bb = br.bindMemory(to: UInt8.self)
            for i in Swift.stride(from: 0, to: a.bytes.count, by: 4) {
                var differs = false
                for c in 0..<4 { let delta = abs(Int(aa[i + c]) - Int(bb[i + c])); maximum = max(maximum, delta); differs = differs || delta != 0 }
                if differs { count += 1 }
            }
        } }
        return ["changedPixels": count, "maxChannelDelta": maximum, "exactRGBA": count == 0]
    }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private func writeJSON(_ value: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
@MainActor private final class LayerDiagnosticDisplayTicks: NSObject {
    private var link: CADisplayLink?, continuation: CheckedContinuation<Bool, Never>?, count = 0
    func wait() async -> Bool {
        await withCheckedContinuation { continuation in
            self.continuation = continuation
            let link = CADisplayLink(target: self, selector: #selector(tick)); self.link = link
            link.add(to: .main, forMode: .common)
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.finish(false) }
        }
    }
    @objc private func tick() {
        count += 1
        guard count == 2 else { return }
        finish(true)
    }
    private func finish(_ passed: Bool) {
        link?.invalidate(); link = nil
        let result = continuation; continuation = nil; result?.resume(returning: passed)
    }
}
private final class LayerDiagnosticFixtureBundle: NSObject {}
