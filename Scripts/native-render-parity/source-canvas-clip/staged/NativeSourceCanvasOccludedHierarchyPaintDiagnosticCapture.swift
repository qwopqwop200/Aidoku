import Testing
import UIKit
import CryptoKit

/// Four original60 public hierarchy captures with window-associated hosts hidden
/// by an owned clipped ancestor or an owned alpha-zero ancestor. No window is created.
@MainActor struct NativeSourceCanvasOccludedHierarchyPaintDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let placement = CGRect(x: 135, y: 7, width: 91, height: 121)
    private let sourceHash = "47f099e191058326fdb65f659e2726c209834a77021955c4b23151f652c04e4d"
    private enum Failure: Error { case invalidSource, invalidCapture, invalidPixels }
    private struct Pixels { let width: Int; let height: Int; let bytes: Data }
    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeSourceCanvasOccludedHierarchyPaintDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try writeJSON(["expectedCount": 4, "count": 0, "complete": false, "pixelParityAsserted": false],
            to: output.appendingPathComponent("report.json"))
        let fixture = try #require(Bundle(for: OccludedHierarchyFixtureBundle.self)
            .url(forResource: "NativeCanvasActual44Mask0", withExtension: "bin"))
        let encoded = try Data(contentsOf: fixture), image = try #require(UIImage(data: encoded)?.cgImage)
        guard hash(encoded) == sourceHash, image.width == 412, image.height == 527 else { throw Failure.invalidSource }
        let original = try pixels(image)
        try encoded.write(to: output.appendingPathComponent("immutable-source.png"))
        try original.bytes.write(to: output.appendingPathComponent("immutable-source.rgba"))
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }.flatMap(\.windows)
        let window = try #require(windows.first(where: { $0.isKeyWindow && !$0.isHidden && $0.alpha > 0 })
            ?? windows.first(where: { !$0.isHidden && $0.alpha > 0 && $0.rootViewController != nil }))
        let rootView = try #require(window.rootViewController?.view)
        guard rootView.window === window, rootView.bounds.width > 0, rootView.bounds.height > 0 else { throw Failure.invalidCapture }
        let scale = window.screen.scale
        let originalWindow = windowMetadata(window)
        let originalRoot = ancestorMetadata(rootView)
        var records: [[String: Any]] = [], failures: [String] = []
        for route in ["clipped-outside", "ancestor-alpha-zero"] { for background in ["transparent", "opaque"] {
            let flag = true
            try Task.checkCancellation()
            let name = background + "-" + route + "-hierarchy-async-true"
            let base = output.appendingPathComponent(name, isDirectory: true)
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
            let priorSubviews = rootView.subviews.map(ObjectIdentifier.init)
            let ancestor = UIView(frame: route == "clipped-outside" ? CGRect(x: 0, y: 0, width: 1, height: 1) : page)
            ancestor.backgroundColor = .clear
            ancestor.isOpaque = false
            ancestor.clipsToBounds = route == "clipped-outside"
            ancestor.alpha = route == "ancestor-alpha-zero" ? 0 : 1
            let nativeHost = UIView(frame: page)
            if route == "clipped-outside" { nativeHost.frame.origin = CGPoint(x: 2, y: 2) }
            ancestor.addSubview(nativeHost)
            rootView.addSubview(ancestor)
            defer { ancestor.removeFromSuperview() }
            nativeHost.isOpaque = background == "opaque"
            nativeHost.backgroundColor = background == "opaque"
                ? UIColor(red: 41 / 255, green: 65 / 255, blue: 87 / 255, alpha: 1) : .clear
            nativeHost.overrideUserInterfaceStyle = .light
            let native = OccludedHierarchySourcePaintView(frame: placement, image: image)
            native.isOpaque = false; native.backgroundColor = .clear; native.contentScaleFactor = scale
            native.layer.drawsAsynchronously = flag
            nativeHost.addSubview(native)
            do {
                let source = try save(image, prefix: "source-realized", output: base)
                native.capturePhase = "occluded-window-associated-display"
                native.setNeedsDisplay(); nativeHost.layoutIfNeeded(); native.layer.displayIfNeeded()
                let preparedDrawInvocationCount = native.observations.count
                let windowAssociatedBefore = nativeHost.window === window && native.window === window && ancestor.window === window
                let ancestorBefore = ancestorMetadata(ancestor)
                let hostBefore = layerMetadata(nativeHost)
                let noVisiblePixelsBefore = noVisiblePixels(route: route, ancestor: ancestor, host: nativeHost)
                native.capturePhase = "public-drawHierarchy"
                let format = UIGraphicsImageRendererFormat()
                format.scale = scale; format.preferredRange = .standard; format.opaque = background == "opaque"
                var hierarchySucceeded = false
                let rendered = UIGraphicsImageRenderer(size: page.size, format: format).image { _ in
                    hierarchySucceeded = nativeHost.drawHierarchy(in: page, afterScreenUpdates: true)
                }
                let captured = try save(try #require(rendered.cgImage), prefix: "capture", output: base)
                var drawReports: [[String: Any]] = []
                for (index, observation) in native.observations.enumerated() {
                    var metadata = observation.metadata
                    if let raw = observation.bytes {
                        let file = "native-own-backing-\(index).raw"
                        try raw.write(to: base.appendingPathComponent(file))
                        metadata["rawFile"] = file; metadata["rawSHA256"] = hash(raw)
                    }
                    drawReports.append(metadata)
                }
                try writeJSON(drawReports, to: base.appendingPathComponent("native-draw-contexts.json"))
                let sourceMatches = source.width == original.width && source.height == original.height && source.bytes == original.bytes
                let dimensions = captured.width == Int((page.width * scale).rounded()) && captured.height == Int((page.height * scale).rounded())
                let visibility = visibleCapture(captured, scale: scale, background: background)
                let flagRetained = native.layer.drawsAsynchronously == flag
                let callbackFlagMatches = !drawReports.isEmpty && drawReports.allSatisfy { ($0["actualDrawsAsynchronously"] as? Bool) == flag }
                let windowAssociatedAfter = nativeHost.window === window && native.window === window && ancestor.window === window
                let ancestorAfter = ancestorMetadata(ancestor)
                let noVisiblePixelsAfter = noVisiblePixels(route: route, ancestor: ancestor, host: nativeHost)
                let existingWindowUnchanged = NSDictionary(dictionary: originalWindow).isEqual(to: windowMetadata(window))
                let rootModelUnchanged = NSDictionary(dictionary: originalRoot).isEqual(to: ancestorMetadata(rootView))
                ancestor.removeFromSuperview()
                let cleanupRestoredHierarchy = priorSubviews == rootView.subviews.map(ObjectIdentifier.init)
                    && nativeHost.window == nil && native.window == nil && ancestor.superview == nil
                let valid = sourceMatches && dimensions && hierarchySucceeded && !drawReports.isEmpty
                    && visibility.drawing > 0 && visibility.sentinelPassed && flagRetained && callbackFlagMatches
                    && windowAssociatedBefore && windowAssociatedAfter && noVisiblePixelsBefore && noVisiblePixelsAfter
                    && existingWindowUnchanged && rootModelUnchanged && cleanupRestoredHierarchy
                let record: [String: Any] = ["name": name, "background": background,
                    "occlusionRoute": route,
                    "windowAssociatedBeforeCapture": windowAssociatedBefore,
                    "windowAssociatedAfterCapture": windowAssociatedAfter,
                    "noVisiblePixelsBeforeCapture": noVisiblePixelsBefore,
                    "noVisiblePixelsAfterCapture": noVisiblePixelsAfter,
                    "ancestorBeforeCapture": ancestorBefore, "ancestorAfterCapture": ancestorAfter,
                    "hostBeforeCapture": hostBefore, "hostAfterCapture": layerMetadata(nativeHost),
                    "existingWindowBeforeCapture": originalWindow, "existingWindowAfterCapture": windowMetadata(window),
                    "existingWindowUnchanged": existingWindowUnchanged, "rootModelUnchanged": rootModelUnchanged,
                    "cleanupRestoredHierarchy": cleanupRestoredHierarchy,
                    "existingVisibleWindowSelection": "foregroundActive existing key window, otherwise existing visible rooted window; no makeKey or window creation",
                    "requestedDrawsAsynchronously": flag, "actualDrawsAsynchronously": native.layer.drawsAsynchronously,
                    "requestedFlagRetained": flagRetained, "everyDrawCallbackFlagMatches": callbackFlagMatches,
                    "sourceCanonicalRGBAEqual": sourceMatches, "sourceCanonicalRGBAHash": hash(source.bytes),
                    "sourceMetadata": imageMetadata(image), "captureRGBAHash": hash(captured.bytes),
                    "captureSize": [captured.width, captured.height], "captureDimensionsValid": dimensions,
                    "drawHierarchySucceeded": hierarchySucceeded, "drawInvocationCount": drawReports.count,
                    "preparedDrawInvocationCount": preparedDrawInvocationCount,
                    "capturePhaseDrawInvocationCount": native.observations.count - preparedDrawInvocationCount,
                    "drawHierarchyTriggeredSourceDraw": native.observations.count > preparedDrawInvocationCount,
                    "routeClassification": native.observations.count > preparedDrawInvocationCount
                        ? "Source draw callback observed during public hierarchy capture; captured pixels may reflect redraw, not the earlier prepared backing."
                        : "No additional source draw callback during public hierarchy capture; occluded window-associated hierarchy backing implementation still unexposed.",
                    "captureSourceDrawingPixelCount": visibility.drawing, "backgroundSentinelRGBA": visibility.sentinel,
                    "backgroundSentinelPassed": visibility.sentinelPassed, "controlValid": valid,
                    "viewport": rect(page), "sourcePlacement": rect(placement), "screenScale": scale,
                    "UIImageScale": rendered.scale, "UIImageOrientation": rendered.imageOrientation.rawValue,
                    "ownView": layerMetadata(native), "hostView": layerMetadata(nativeHost),
                    "captureWait": "Exact60 layer.displayIfNeeded then public drawHierarchy(afterScreenUpdates:true), on window-associated host with explicitly invisible owned ancestor",
                    "publicCaptureIsWebKitEquivalent": false]
                try writeJSON(record, to: base.appendingPathComponent("capture.json")); records.append(record)
                if !valid { failures.append(name + ": invalid source/geometry/drawing/background/flag control") }
            } catch {
                let failure = String(describing: error)
                try writeJSON(["name": name, "failure": failure, "captureAcceptancePassed": false],
                    to: base.appendingPathComponent("failure.json"))
                failures.append(name + ": " + failure)
            }
        } }
        try writeJSON(["expectedCount": 4, "count": records.count, "complete": records.count == 4,
            "sourceAndCaptureControlsPassed": records.count == 4 && failures.isEmpty,
            "pixelParityAsserted": false, "reports": records, "failures": failures,
            "fixturePNGHash": sourceHash, "os": UIDevice.current.systemVersion,
            "scope": "Exact60 UIView draw(_:) and public drawHierarchy API, literal drawsAsynchronously=true, two backgrounds and two window-associated but invisible ancestor routes; unchanged source/geometry/quality and active window."],
            to: output.appendingPathComponent("report.json"))
        #expect(records.count == 4 && failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }
    private func noVisiblePixels(route: String, ancestor: UIView, host: UIView) -> Bool {
        if route == "ancestor-alpha-zero" { return ancestor.alpha == 0 }
        return ancestor.clipsToBounds && ancestor.alpha == 1 && !ancestor.bounds.intersects(host.frame)
    }
    private func ancestorMetadata(_ view: UIView) -> [String: Any] {
        ["frame": rect(view.frame), "bounds": rect(view.bounds), "alpha": view.alpha,
            "clipsToBounds": view.clipsToBounds, "hidden": view.isHidden,
            "transform": [view.transform.a, view.transform.b, view.transform.c, view.transform.d, view.transform.tx, view.transform.ty],
            "windowAssociated": view.window != nil]
    }
    private func windowMetadata(_ window: UIWindow) -> [String: Any] {
        ["bounds": rect(window.bounds), "frame": rect(window.frame), "alpha": window.alpha,
            "hidden": window.isHidden, "isKeyWindow": window.isKeyWindow, "windowLevel": window.windowLevel.rawValue,
            "screenScale": window.screen.scale]
    }
    private func layerMetadata(_ view: UIView) -> [String: Any] {
        ["frame": rect(view.frame), "bounds": rect(view.bounds), "contentScaleFactor": view.contentScaleFactor,
            "layerFrame": rect(view.layer.frame), "layerBounds": rect(view.layer.bounds),
            "contentsScale": view.layer.contentsScale, "rasterizationScale": view.layer.rasterizationScale,
            "shouldRasterize": view.layer.shouldRasterize, "opaque": view.isOpaque,
            "drawsAsynchronously": view.layer.drawsAsynchronously]
    }
    private func imageMetadata(_ image: CGImage) -> [String: Any] {
        ["width": image.width, "height": image.height, "bitsPerComponent": image.bitsPerComponent,
            "bitsPerPixel": image.bitsPerPixel, "bytesPerRow": image.bytesPerRow,
            "bitmapInfo": image.bitmapInfo.rawValue, "alphaInfo": image.alphaInfo.rawValue,
            "colorSpace": image.colorSpace?.name as String? ?? "nil", "shouldInterpolate": image.shouldInterpolate]
    }
    private func visibleCapture(_ captured: Pixels, scale: CGFloat, background: String) -> (drawing: Int, sentinel: [Int], sentinelPassed: Bool) {
        let expected: [UInt8] = background == "opaque" ? [41,65,87,255] : [0,0,0,0]
        guard captured.width == Int((page.width * scale).rounded()), captured.height == Int((page.height * scale).rounded()),
            captured.bytes.count == captured.width * captured.height * 4 else { return (0,[],false) }
        return captured.bytes.withUnsafeBytes { storage in
            let rgba = storage.bindMemory(to: UInt8.self), width = captured.width
            let sentinel = (0..<4).map { Int(rgba[$0]) }
            var drawing = 0
            for y in Int((placement.minY * scale).rounded())..<Int((placement.maxY * scale).rounded()) {
                for x in Int((placement.minX * scale).rounded())..<Int((placement.maxX * scale).rounded()) {
                    let i = (y * width + x) * 4
                    if background == "transparent" { if rgba[i+3] != 0 { drawing += 1 } }
                    else if (0..<4).contains(where: { rgba[i+$0] != expected[$0] }) { drawing += 1 }
                }
            }
            return (drawing,sentinel,sentinel == expected.map(Int.init))
        }
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
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func rect(_ value: CGRect) -> [CGFloat] { [value.minX, value.minY, value.width, value.height] }
    private func writeJSON(_ value: Any, to file: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: file, options: .atomic)
    }
}
@MainActor private final class OccludedHierarchySourcePaintView: UIView {
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
private final class OccludedHierarchyFixtureBundle: NSObject {}
