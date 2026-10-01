import Testing
import UIKit
import CoreImage
import CoreVideo
import VideoToolbox
import CryptoKit

/// Public image-realization controls, not a claim of WebKit backend equivalence.
/// Exactly three source routes × two readback timings × two backgrounds.
@MainActor struct NativeSourceCanvasRealizationDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let placement = CGRect(x: 135, y: 7, width: 91, height: 121)
    private let sourceHash = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private struct Source { let image: CGImage; let context: CIContext?; let pixelBuffer: CVPixelBuffer? }
    private enum Failure: Error { case invalidSource, invalidPixels, invalidCapture, unavailableRoute(String) }

    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasRealizationDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 12, "count": 0, "complete": false, "pixelParityAsserted": false],
            to: output.appendingPathComponent("report.json"))
        let fixture = try #require(Bundle(for: RealizationFixtureBundle.self)
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
            for route in ["ci-normal", "ci-deferred", "cv-videotoolbox"] {
                for early in [true, false] {
                    let timing = early ? "read-before-display" : "read-after-two-display-ticks"
                    let name = background + "-" + route + "-" + timing
                    do {
                        let source = try makeSource(route: route, image: image, canonical: original)
                        let host = UIView(frame: page); host.isOpaque = background == "opaque"
                        host.backgroundColor = background == "opaque"
                            ? UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1) : .clear
                        root.addSubview(host); defer { host.removeFromSuperview() }
                        let paint = RealizationPaintView(frame: placement, image: source.image)
                        paint.isOpaque = false; paint.backgroundColor = .clear
                        paint.contentScaleFactor = window.screen.scale; host.addSubview(paint)
                        let base = output.appendingPathComponent(name, isDirectory: true)
                        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
                        var sourcePixels: Pixels?
                        // Do not inspect a deferred source before display on the
                        // late branch: that would erase the treatment itself.
                        if early { sourcePixels = try save(source.image, prefix: "source-realized", output: base) }
                        paint.phase = "display-before-source-readback"
                        host.setNeedsLayout(); paint.setNeedsDisplay()
                        guard await RealizationDisplayTicks().wait() else { throw Failure.invalidCapture }
                        let displayDraws = paint.observations.count
                        if !early { sourcePixels = try save(source.image, prefix: "source-realized", output: base) }
                        let canonical = try #require(sourcePixels)
                        let sourceMatches = canonical.width == original.width && canonical.height == original.height && canonical.bytes == original.bytes
                        paint.phase = "public-hierarchy-capture"
                        let format = UIGraphicsImageRendererFormat(); format.scale = window.screen.scale
                        format.preferredRange = .standard; format.opaque = background == "opaque"
                        var succeeded = false
                        let captured = UIGraphicsImageRenderer(size: page.size, format: format).image { _ in
                            succeeded = host.drawHierarchy(in: page, afterScreenUpdates: true)
                        }
                        let bytes = try save(try #require(captured.cgImage), prefix: "capture", output: base)
                        captures[name] = bytes
                        let dimensions = bytes.width == Int((page.width * window.screen.scale).rounded()) &&
                            bytes.height == Int((page.height * window.screen.scale).rounded())
                        if !sourceMatches { failures.append(name + ": source pixels changed; output is not a same-input minification control") }
                        if !succeeded || !dimensions || displayDraws == 0 { failures.append(name + ": invalid public display/capture control") }
                        let record: [String: Any] = ["name": name, "route": route, "background": background,
                            "sourceReadbackTiming": timing, "sourceCanonicalRGBAEqual": sourceMatches,
                            "sourceCanonicalRGBAHash": hash(canonical.bytes), "sourceMetadata": metadata(source.image),
                            "sourceHasIOSurfacePixelBuffer": source.pixelBuffer.map { CVPixelBufferGetIOSurface($0) != nil } ?? false,
                            "coreImageContext": source.context.map { String(describing: $0) } ?? "none",
                            "drawHierarchySucceeded": succeeded, "displayDrawInvocations": displayDraws,
                            "drawObservations": paint.observations, "captureDimensionsValid": dimensions,
                            "captureRGBAHash": hash(bytes.bytes), "captureSize": [bytes.width, bytes.height],
                            "screenScale": window.screen.scale, "sourcePlacement": rect(placement),
                            "viewport": rect(page), "publicCaptureIsWebKitEquivalent": false]
                        try writeJSON(record, to: base.appendingPathComponent("capture.json")); records.append(record)
                        // Keep source context/pixel-buffer resources alive until
                        // after both the displayed source and readback are done.
                        withExtendedLifetime(source) {}
                    } catch { failures.append(name + ": " + String(describing: error)) }
                }
            }
        }
        var comparisons: [[String: Any]] = []
        for background in ["transparent", "opaque"] {
            for route in ["ci-normal", "ci-deferred", "cv-videotoolbox"] {
                let before = background + "-" + route + "-read-before-display"
                let after = background + "-" + route + "-read-after-two-display-ticks"
                if let a = captures[before], let b = captures[after] {
                    var comparison = compare(a, b); comparison["background"] = background; comparison["route"] = route
                    comparisons.append(comparison)
                }
            }
        }
        try writeJSON(["expectedCount": 12, "count": records.count, "complete": records.count == 12,
            "sourceAndCaptureControlsPassed": records.count == 12 && failures.isEmpty,
            "pixelParityAsserted": false, "failures": failures, "reports": records, "timingComparisons": comparisons,
            "os": UIDevice.current.systemVersion, "fixturePNGHash": sourceHash,
            "scope": "Finite public source-image realization controls. No filters, LOD search, fitted weights, private API or WebKit change."],
            to: output.appendingPathComponent("report.json"))
        #expect(records.count == 12 && failures.isEmpty)
    }

    private func makeSource(route: String, image: CGImage, canonical: Pixels) throws -> Source {
        guard let space = CGColorSpace(name: CGColorSpace.sRGB) else { throw Failure.invalidSource }
        if route.hasPrefix("ci-") {
            // Identity image: no resize/filter, source and output are explicit
            // sRGB8. Only the public deferred creation flag varies.
            let context = CIContext(options: [.workingColorSpace: space, .outputColorSpace: space])
            let input = CIImage(cgImage: image, options: [.colorSpace: space])
            guard let result = context.createCGImage(input, from: input.extent, format: .RGBA8,
                colorSpace: space, deferred: route == "ci-deferred") else { throw Failure.unavailableRoute(route) }
            return Source(image: result, context: context, pixelBuffer: nil)
        }
        var pixelBuffer: CVPixelBuffer?
        let attributes: [String: Any] = [kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true]
        guard CVPixelBufferCreate(kCFAllocatorDefault, image.width, image.height, kCVPixelFormatType_32BGRA,
            attributes as CFDictionary, &pixelBuffer) == kCVReturnSuccess, let buffer = pixelBuffer,
            CVPixelBufferGetIOSurface(buffer) != nil else { throw Failure.unavailableRoute(route) }
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { throw Failure.unavailableRoute(route) }
        do {
            defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
            guard let address = CVPixelBufferGetBaseAddress(buffer) else { throw Failure.invalidPixels }
            let destination = address.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(buffer)
            canonical.bytes.withUnsafeBytes { raw in
                let input = raw.bindMemory(to: UInt8.self)
                for y in 0..<image.height { for x in 0..<image.width {
                    let a = (y * image.width + x) * 4, b = y * stride + x * 4
                    destination[b] = input[a + 2]; destination[b + 1] = input[a + 1]
                    destination[b + 2] = input[a]; destination[b + 3] = input[a + 3]
                } }
            }
        }
        CVBufferSetAttachment(buffer, kCVImageBufferCGColorSpaceKey, space, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferAlphaChannelModeKey,
            kCVImageBufferAlphaChannelMode_PremultipliedAlpha, .shouldPropagate)
        var result: CGImage?
        guard VTCreateCGImageFromCVPixelBuffer(buffer, options: nil, imageOut: &result) == noErr,
              let result else { throw Failure.unavailableRoute(route) }
        return Source(image: result, context: nil, pixelBuffer: buffer)
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
@MainActor private final class RealizationPaintView: UIView {
    private let source: CGImage
    var phase = "unassigned"
    var observations: [[String: Any]] = []
    init(frame: CGRect, image: CGImage) { source = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("Immutable diagnostic source required") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        observations.append(["phase": phase, "contextDimensions": [context.width, context.height],
            "contextBytesPerRow": context.bytesPerRow, "bitmapInfo": context.bitmapInfo.rawValue,
            "alphaInfo": context.alphaInfo.rawValue, "colorSpace": context.colorSpace?.name as String? ?? "nil",
            "interpolationQuality": context.interpolationQuality.rawValue, "dataAvailable": context.data != nil,
            "CTM": [context.ctm.a, context.ctm.b, context.ctm.c, context.ctm.d, context.ctm.tx, context.ctm.ty]])
        context.saveGState(); context.setShouldAntialias(false)
        context.translateBy(x: 0, y: bounds.height); context.scaleBy(x: 1, y: -1)
        context.draw(source, in: bounds); context.restoreGState()
    }
}
@MainActor private final class RealizationDisplayTicks: NSObject {
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
private final class RealizationFixtureBundle: NSObject {}
