import Testing
import UIKit
import CryptoKit

/// Two detached GPU captures compared descriptively with immutable actual BUILD56 WK outputs.
/// Completeness/source assertions do not assert native/WebKit pixel equivalence.
@MainActor
struct NativeDetachedGradientMetalDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let frame = CGRect(x: 20, y: 20, width: 96, height: 96)
    private enum Failure: Error { case invalidSource, invalidCapture }
    private struct Control {
        let name: String; let rgb: [CGFloat]; let pngHash: String; let rgbaHash: String
    }
    private let controls = [
        Control(name: "Red", rgb: [220,30,40],
            pngHash: "69c5b246bf9de9411b672ade31734ff40b51f3de75c8048453815a603e25cfa2",
            rgbaHash: "29045ce6342433fdecb081015541f72b07e7866c2d7ce422c59d05de51affe74"),
        Control(name: "Blue", rgb: [30,40,220],
            pngHash: "3b16591e1f92895287587f73ed5ca958a2c2acc99866ad2a6d17c1a4a7cacbb5",
            rgbaHash: "1944e325538ee83e06d277308f472f45c4c388b4c5fda79324d2ccd3a0a25e54")
    ]

    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeDetachedGradientMetalDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try json(["expectedCount": 2, "count": 0, "passed": false, "pixelParityAsserted": false, "reports": []],
            to: output.appendingPathComponent("report.json"))
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let scale = scene.screen.scale
        // Immutable reference observation is exactly DPR3. Other DPRs require a fresh separate reference.
        guard scale == 3 else { throw Failure.invalidSource }
        let bundle = Bundle(for: DetachedGradientMetalFixtureBundle.self)
        var reports: [[String: Any]] = [], failures: [String] = []
        for control in controls {
            try Task.checkCancellation()
            let directory = output.appendingPathComponent(control.name.lowercased(), isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                let resource = "NativeGradientActual56" + control.name
                let file = try #require(bundle.url(forResource: resource, withExtension: "bin"))
                let referencePNG = try Data(contentsOf: file)
                let sourceImage = try #require(UIImage(data: referencePNG)?.cgImage)
                let reference = try pixels(sourceImage)
                let valid = hash(referencePNG) == control.pngHash && hash(reference) == control.rgbaHash &&
                    sourceImage.width == 960 && sourceImage.height == 480
                let provenance: [String: Any] = ["reference": "immutable actual BUILD56 WK capture",
                    "resource": resource + ".bin", "sourceHash": hash(referencePNG), "expectedSourceHash": control.pngHash,
                    "RGBAHash": hash(reference), "expectedRGBAHash": control.rgbaHash, "dimensions": [sourceImage.width, sourceImage.height],
                    "sourceValid": valid, "sourceFrameCSS": rect(frame), "sourcePageCSS": rect(page), "sourceDPR": 3]
                try json(provenance, to: directory.appendingPathComponent("reference-provenance.json"))
                #expect(valid)
                guard valid else { throw Failure.invalidSource }
                try referencePNG.write(to: directory.appendingPathComponent("web-reference.png"))
                try reference.write(to: directory.appendingPathComponent("web-reference.rgba"))

                let root = CALayer(); root.bounds = page; root.frame = page; root.contentsScale = scale
                root.backgroundColor = color([41,65,87])
                let gradient = CAGradientLayer(); gradient.frame = frame; gradient.contentsScale = scale
                gradient.type = .axial; gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
                gradient.locations = [0,1]; gradient.colors = [color(control.rgb),color(control.rgb)]
                root.addSublayer(gradient)
                defer { gradient.removeFromSuperlayer() }
                let originalAnchor = root.anchorPoint, originalPosition = root.position
                let inputValid = root.bounds == page && root.bounds.origin == .zero && CATransform3DIsIdentity(root.transform) &&
                    root.superlayer == nil && gradient.frame == frame && gradient.locations == [0,1]
                #expect(inputValid)
                guard inputValid else { throw Failure.invalidSource }
                try json(["source": provenance, "rootIdentityInputAttested": inputValid,
                    "captureReturned": false, "sourceRGB": control.rgb, "declaredGradientFrame": rect(frame)],
                    to: directory.appendingPathComponent("capture-attempt.json"))
                let capture = try await NativeDetachedLayerMetalCapture.capture(root: root, size: page.size, scale: scale)
                let restored = root.superlayer == nil && root.anchorPoint == originalAnchor && root.position == originalPosition &&
                    CATransform3DIsIdentity(root.transform) && root.bounds == page
                let opaque = capture.canonicalRGBA.enumerated().allSatisfy { $0.offset % 4 != 3 || $0.element == 255 }
                let dimensions = capture.width == 960 && capture.height == 480
                // Preserve actual GPU bytes/metadata before any acceptance or image-transport guard.
                try capture.canonicalRGBA.write(to: directory.appendingPathComponent("native-detached-metal.rgba"))
                try json(["source": provenance, "captureReturned": true, "width": capture.width, "height": capture.height,
                    "RGBAHash": hash(capture.canonicalRGBA), "renderer": capture.metadata,
                    "guards": ["rootRestored": restored, "opaque": opaque, "dimensions": dimensions]],
                    to: directory.appendingPathComponent("capture.json"))
                let png = try #require(UIImage(cgImage: capture.image).pngData())
                try png.write(to: directory.appendingPathComponent("native-detached-metal.png"))
                let decodedCapture = try #require(UIImage(data: png)?.cgImage)
                let transportExact = try pixels(decodedCapture) == capture.canonicalRGBA
                var metadata = capture.metadata
                metadata["rootIdentityInputAttested"] = inputValid; metadata["rootModelRestored"] = restored
                metadata["PNGDecodedRGBAEqualsTextureReadback"] = transportExact
                metadata["sourceRGB"] = control.rgb; metadata["declaredGradientFrame"] = rect(frame)
                metadata["declaredComponents"] = color(control.rgb).components ?? []
                metadata["declaredColorSpace"] = color(control.rgb).colorSpace?.name as String? ?? "nil"
                metadata["gradientType"] = gradient.type.rawValue
                metadata["gradientStartPoint"] = [gradient.startPoint.x,gradient.startPoint.y]
                metadata["gradientEndPoint"] = [gradient.endPoint.x,gradient.endPoint.y]
                metadata["gradientLocations"] = gradient.locations ?? []
                metadata["orientationControl"] = "asymmetric y:20..116 gradient within y:0..160 page; no postcapture flip"
                let comparison: [String: Any] = ["fullPage": difference(reference,capture.canonicalRGBA),
                    "borderFreeInterior": difference(interior(reference),interior(capture.canonicalRGBA)),
                    "pixelAcceptance": "none; descriptive only"]
                let report: [String: Any] = ["scene": control.name.lowercased(), "mode": "detached-ca-renderer-metal",
                    "width": capture.width, "height": capture.height, "RGBAHash": hash(capture.canonicalRGBA),
                    "PNGHash": hash(png), "metadata": metadata, "comparison": comparison, "source": provenance,
                    "guards": ["rootRestored": restored, "opaque": opaque, "dimensions": dimensions, "PNGTransportExact": transportExact]]
                try json(report, to: directory.appendingPathComponent("capture.json")); reports.append(report)
                #expect(restored && opaque && dimensions && transportExact)
                guard restored, opaque, dimensions, transportExact else { throw Failure.invalidCapture }
            } catch { failures.append("\(control.name): \(error)") }
        }
        try json(["expectedCount": 2, "count": reports.count, "passed": reports.count == 2 && failures.isEmpty,
            "pixelParityAsserted": false, "scope": "public detached CARenderer diagnostic only; immutable actual WK reference, no new oracle",
            "screenScale": scale, "reports": reports, "failures": failures], to: output.appendingPathComponent("report.json"))
        #expect(reports.count == 2 && failures.isEmpty)
    }

    private func color(_ rgb: [CGFloat]) -> CGColor {
        CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: rgb.map { CGFloat(Float($0 / 255)) } + [1])!
    }
    private func pixels(_ image: CGImage) throws -> Data {
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue))
        let pointer = try #require(context.data)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: pointer, count: image.width * image.height * 4)
    }
    private func interior(_ data: Data) -> Data {
        var result = Data()
        for y in 66..<342 { let offset = (y * 960 + 66) * 4; result.append(data.subdata(in: offset..<(offset + 276 * 4))) }
        return result
    }
    private func difference(_ a: Data, _ b: Data) -> [String: Any] {
        guard a.count == b.count else { return ["exactRGBA": false, "dimensionMismatch": true] }
        var changedPixels = 0, changedBytes = 0, maximum = 0
        a.withUnsafeBytes { lhs in b.withUnsafeBytes { rhs in
            let left = lhs.bindMemory(to: UInt8.self), right = rhs.bindMemory(to: UInt8.self)
            for p in stride(from: 0, to: a.count, by: 4) {
                var changed = false
                for c in 0..<4 {
                    let delta = abs(Int(left[p+c]) - Int(right[p+c])); maximum = max(maximum,delta)
                    if delta > 0 { changed = true; changedBytes += 1 }
                }
                if changed { changedPixels += 1 }
            }
        } }
        return ["exactRGBA": changedPixels == 0, "changedPixels": changedPixels,
            "changedBytes": changedBytes, "maxChannelDelta": maximum]
    }
    private func rect(_ v: CGRect) -> [CGFloat] { [v.minX,v.minY,v.width,v.height] }
    private func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x",$0) }.joined() }
    private func json(_ value: Any, to url: URL) throws {
        try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys,.prettyPrinted]).write(to: url, options: .atomic)
    }
}
private final class DetachedGradientMetalFixtureBundle: NSObject {}
