import Testing
import UIKit
import CryptoKit

/// Original60 UIView source draw with asynchronous backing, detached from any
/// window. Public layer-tree capture, no private renderer or filter fitting.
@MainActor struct NativeSourceCanvasDetachedUIViewPaintDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let placement = CGRect(x: 135, y: 7, width: 91, height: 121)
    private let sourceHash = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    private enum Failure: Error { case invalidSource, invalidPixels, invalidCapture }
    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasDetachedUIViewPaintDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 2, "count": 0, "complete": false, "pixelParityAsserted": false],
            to: output.appendingPathComponent("report.json"))
        let fixture = try #require(Bundle(for: DetachedUIViewPaintFixtureBundle.self)
            .url(forResource: "NativeCanvasActual44Mask0", withExtension: "bin"))
        let encoded = try Data(contentsOf: fixture), image = try #require(UIImage(data: encoded)?.cgImage)
        guard hash(encoded) == sourceHash, image.width == 412, image.height == 527 else { throw Failure.invalidSource }
        let original = try pixels(image)
        try encoded.write(to: output.appendingPathComponent("immutable-source.png"))
        try original.bytes.write(to: output.appendingPathComponent("immutable-source.rgba"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let scale = scene.screen.scale
        var records: [[String: Any]] = [], failures: [String] = []
        for background in ["transparent", "opaque"] {
            let name = background + "-public-detached-uiview-paint"
            let base = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            do {
                let source = try save(image, prefix: "source-realized", output: base)
                let nativeHost = UIView(frame: page)
                nativeHost.isOpaque = background == "opaque"
                nativeHost.backgroundColor = background == "opaque"
                    ? UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1) : .clear
                let painter = DetachedUIKitSourcePaintView(frame: placement, image: image)
                painter.isOpaque = false; painter.backgroundColor = .clear; painter.contentScaleFactor = scale
                painter.layer.drawsAsynchronously = true
                nativeHost.addSubview(painter)
                let root = nativeHost.layer, layer = painter.layer
                painter.capturePhase = "detached-uiview-display"
                painter.setNeedsDisplay(); nativeHost.layoutIfNeeded(); layer.displayIfNeeded()
                let preparedInvocationCount = painter.observations.count
                let viewsDetached = nativeHost.window == nil && painter.window == nil && nativeHost.superview == nil
                painter.capturePhase = "detached-carenderer-capture"
                let originalAnchor = root.anchorPoint, originalPosition = root.position
                let originalBounds = root.bounds, originalTransform = root.transform
                let validDetachedInput = viewsDetached && root.superlayer == nil && root.bounds.origin == .zero && CATransform3DIsIdentity(root.transform)
                try writeJSON(["name": name, "background": background,
                    "detachedRootInputIdentityAndZeroBoundsOrigin": validDetachedInput,
                    "viewport": rect(page), "sourcePlacement": rect(placement), "screenScale": scale,
                    "sourceCanonicalRGBAHash": hash(source.bytes), "sourceMetadata": metadata(image),
                    "captureReturned": false], to: base.appendingPathComponent("attempt.json"))
                guard validDetachedInput else { throw Failure.invalidCapture }
                let capture = try await NativeDetachedLayerMetalCapture.capture(root: root, size: page.size, scale: scale)
                // Preserve actual GPU bytes and metadata before any transport or
                // geometry acceptance, including rejected captures.
                try capture.canonicalRGBA.write(to: base.appendingPathComponent("capture.rgba"))
                try writeJSON(["name": name, "background": background, "captureReturned": true,
                    "captureSize": [capture.width, capture.height], "rawByteCount": capture.canonicalRGBA.count,
                    "captureRGBAHash": hash(capture.canonicalRGBA), "renderer": capture.metadata],
                    to: base.appendingPathComponent("capture-raw.json"))
                let observations = painter.observations
                var drawReports: [[String: Any]] = []
                for (index, observation) in observations.enumerated() {
                    var metadata = observation.metadata
                    if let raw = observation.bytes {
                        let file = "delegate-backing-\(index).raw"
                        try raw.write(to: base.appendingPathComponent(file))
                        metadata["rawFile"] = file; metadata["rawSHA256"] = hash(raw)
                    }
                    drawReports.append(metadata)
                }
                try writeJSON(drawReports, to: base.appendingPathComponent("native-draw-contexts.json"))
                let flagMatches = layer.drawsAsynchronously && !drawReports.isEmpty
                    && drawReports.allSatisfy { ($0["actualDrawsAsynchronously"] as? Bool) == true }
                let transported = try save(capture.image, prefix: "capture-cgimage", output: base)
                guard let png = UIImage(cgImage: capture.image).pngData() else { throw Failure.invalidCapture }
                try png.write(to: base.appendingPathComponent("capture.png"))
                let sourceMatches = source.bytes == original.bytes && source.width == original.width && source.height == original.height
                let dimensions = capture.width == Int((page.width * scale).rounded()) && capture.height == Int((page.height * scale).rounded())
                let transportEqual = transported.bytes == capture.canonicalRGBA
                let visibility = visibleCapture(capture.canonicalRGBA, width: capture.width,
                    height: capture.height, scale: scale, background: background)
                let sourceVisible = original.bytes.enumerated().contains { $0.offset % 4 == 3 && $0.element != 0 }
                let detached = root.superlayer == nil, rootFrameMatches = root.frame == page
                let sourceFrameMatches = layer.frame == placement, anchorMatches = root.anchorPoint == originalAnchor
                let positionMatches = root.position == originalPosition, boundsMatches = root.bounds == originalBounds
                let transformMatches = CATransform3DEqualToTransform(root.transform, originalTransform)
                let restored = detached && rootFrameMatches && sourceFrameMatches && anchorMatches
                    && positionMatches && boundsMatches && transformMatches
                let record: [String: Any] = ["name": name, "background": background,
                    "sourceCanonicalRGBAEqual": sourceMatches, "sourceCanonicalRGBAHash": hash(source.bytes),
                    "sourceMetadata": metadata(image), "captureRGBAHash": hash(capture.canonicalRGBA),
                    "captureSize": [capture.width, capture.height], "captureDimensionsValid": dimensions,
                    "cgImageTransportEqualsGPUBytes": transportEqual, "detachedRootRestored": restored,
                    "detachedRootInputIdentityAndZeroBoundsOrigin": validDetachedInput,
                    "viewport": rect(page), "sourcePlacement": rect(placement), "screenScale": scale,
                    "drawsAsynchronously": layer.drawsAsynchronously, "everyDrawFlagMatches": flagMatches,
                    "drawInvocationCount": observations.count, "preparedDrawInvocationCount": preparedInvocationCount,
                    "drawInvocationsDuringCapture": observations.count - preparedInvocationCount,
                    "sourceViewsDetachedFromWindow": viewsDetached,
                    "hostContentScaleFactor": nativeHost.contentScaleFactor,
                    "sourceContentScaleFactor": painter.contentScaleFactor,
                    "sourceRasterizationScale": layer.rasterizationScale,
                    "sourceShouldRasterize": layer.shouldRasterize,
                    "sourceGeometryFlipped": layer.isGeometryFlipped,
                    "hostGeometryFlipped": root.isGeometryFlipped,
                    "contentsGravity": layer.contentsGravity.rawValue, "contentsScale": layer.contentsScale,
                    "minificationFilter": layer.minificationFilter.rawValue,
                    "magnificationFilter": layer.magnificationFilter.rawValue,
                    "minificationFilterBias": layer.minificationFilterBias,
                    "sourceContainsVisiblePixels": sourceVisible,
                    "captureSourceDrawingPresent": visibility.drawingPixels > 0,
                    "captureSourceDrawingPixelCount": visibility.drawingPixels,
                    "captureMaskNonzeroAlphaPixelCount": visibility.alphaPixels,
                    "backgroundSentinelRGBA": visibility.sentinel,
                    "backgroundSentinelExpectedRGBA": background == "opaque" ? [41,65,87,255] : [0,0,0,0],
                    "backgroundSentinelPassed": visibility.sentinelPassed,
                    "rootDetachedAfterCapture": detached, "rootFrameRestored": rootFrameMatches,
                    "sourceFrameRestored": sourceFrameMatches, "rootAnchorRestored": anchorMatches,
                    "rootPositionRestored": positionMatches, "rootBoundsRestored": boundsMatches,
                    "rootTransformRestored": transformMatches,
                    "sourceReadback": "Canonical source before GPU capture", "renderer": capture.metadata,
                    "publicCaptureIsWebKitEquivalent": false]
                try writeJSON(record, to: base.appendingPathComponent("capture.json"))
                records.append(record)
                if !sourceMatches || !dimensions || !transportEqual || !restored || !sourceVisible
                    || visibility.drawingPixels == 0 || !visibility.sentinelPassed || !flagMatches {
                    failures.append(name + ": invalid source/geometry/transport/drawing/background control")
                }
            } catch {
                let failure = String(describing: error)
                try writeJSON(["name": name, "failure": failure, "captureAcceptancePassed": false],
                    to: base.appendingPathComponent("failure.json"))
                failures.append(name + ": " + failure)
            }
        }
        try writeJSON(["expectedCount": 2, "count": records.count, "complete": records.count == 2,
            "sourceAndCaptureControlsPassed": records.count == 2 && failures.isEmpty,
            "pixelParityAsserted": false, "reports": records, "failures": failures,
            "fixturePNGHash": sourceHash, "os": UIDevice.current.systemVersion,
            "scope": "Two unchanged mask backgrounds with exact60 UIView draw(_:) and drawsAsynchronously=true, no window attachment; prepared UIView.layer passed to public CARenderer shared helper; no privateSPI/filter changes."],
            to: output.appendingPathComponent("report.json"))
        #expect(records.count == 2 && failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
    /// Presence and a known outside-source background sentinel establish actual
    /// painting, not WebKit pixel parity. Blank GPU output must fail completeness.
    private func visibleCapture(_ bytes: Data, width: Int, height: Int, scale: CGFloat,
                                background: String) -> (drawingPixels: Int, alphaPixels: Int, sentinel: [Int], sentinelPassed: Bool) {
        let expected: [UInt8] = background == "opaque" ? [41,65,87,255] : [0,0,0,0]
        guard width == Int((page.width * scale).rounded()), height == Int((page.height * scale).rounded()),
              bytes.count == width * height * 4 else { return (0,0,[],false) }
        return bytes.withUnsafeBytes { storage in
            let rgba = storage.bindMemory(to: UInt8.self)
            let sentinel = (0..<4).map { Int(rgba[$0]) }
            var drawing = 0, alpha = 0
            let x0 = Int((placement.minX * scale).rounded()), x1 = Int((placement.maxX * scale).rounded())
            let y0 = Int((placement.minY * scale).rounded()), y1 = Int((placement.maxY * scale).rounded())
            for y in y0..<y1 { for x in x0..<x1 {
                let offset = (y * width + x) * 4
                if rgba[offset + 3] != 0 { alpha += 1 }
                if background == "transparent" {
                    if rgba[offset + 3] != 0 { drawing += 1 }
                } else if (0..<4).contains(where: { rgba[offset + $0] != expected[$0] }) { drawing += 1 }
            } }
            return (drawing, alpha, sentinel, sentinel == expected.map(Int.init))
        }
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
private final class DetachedUIViewPaintFixtureBundle: NSObject {}

@MainActor private final class DetachedUIKitSourcePaintView: UIView {
    struct Observation { let metadata: [String: Any]; let bytes: Data? }
    private let source: CGImage
    var observations: [Observation] = []
    var capturePhase = "unassigned"
    init(frame: CGRect, image: CGImage) { source = image; super.init(frame: frame) }
    required init?(coder: NSCoder) { fatalError("test view requires immutable source image") }
    override func draw(_ rect: CGRect) {
        guard let context = UIGraphicsGetCurrentContext() else { return }
        let ctm = context.ctm
        var metadata: [String: Any] = ["phase": capturePhase, "actualDrawsAsynchronously": layer.drawsAsynchronously, "dirtyRect": values(rect), "viewFrame": values(frame),
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
