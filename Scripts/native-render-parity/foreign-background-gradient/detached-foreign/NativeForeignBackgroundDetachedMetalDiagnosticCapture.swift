import Testing
import UIKit
import QuartzCore
import CryptoKit
@testable import Aidoku

/// Same four literal scenes as the original live foreign-background capture.
/// Reads immutable BUILD54 references; does not invoke WK or regenerate an oracle.
@MainActor
struct NativeForeignBackgroundDetachedMetalDiagnosticCapture {
    private let page = CGRect(x: 0, y: 0, width: 320, height: 160)
    private let scale: CGFloat = 3
    private let fixtureHash = "3b00f9835884ce5217141c1b71c2a606e59c460835442e90bfe22c7ee88cdb20"
    private struct Fill: Decodable { let position: [Double]; let size: [Double]; let color: [Double] }
    private struct Control: Decodable { let name: String; let originalOwner: [Double]; let finalOwner: [Double]; let base: [Double]; let layers: [Fill] }
    private struct Reference: Decodable {
        let control: Control; let png: String; let pngHash: String; let rgbaHash: String
        let domHash: String; let width: Int; let height: Int
    }
    private struct Manifest: Decodable { let source: String; let literalInputsHash: String; let records: [Reference] }
    private enum Failure: Error { case source, geometry, unsupportedPattern, transport }

    func run() async throws {
        let output = URL.documentsDirectory.appendingPathComponent("NativeForeignBackgroundDetachedMetalDiagnostic", isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        try json(["expectedCount": 4, "count": 0, "complete": false, "pixelParityAsserted": true], to: output.appendingPathComponent("report.json"))
        let resource = try #require(Bundle(for: DetachedForeignFixtureBundle.self).url(forResource: "NativeForeign54References", withExtension: "bin"))
        let input = try Data(contentsOf: resource)
        guard hash(input) == fixtureHash else { throw Failure.source }
        let manifest = try JSONDecoder().decode(Manifest.self, from: input)
        guard manifest.records.count == 4 else { throw Failure.source }
        try input.write(to: output.appendingPathComponent("immutable-references.bin"))
        var reports: [[String: Any]] = [], failures: [String] = []
        for reference in manifest.records {
            let control = reference.control
            let directory = output.appendingPathComponent(control.name, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            do {
                try Task.checkCancellation()
                let png = try #require(Data(base64Encoded: reference.png))
                guard hash(png) == reference.pngHash else { throw Failure.source }
                let image = try #require(UIImage(data: png)?.cgImage), expected = try pixels(image)
                guard image.width == reference.width, image.height == reference.height,
                      reference.width == 960, reference.height == 480, hash(expected) == reference.rgbaHash else { throw Failure.source }
                try png.write(to: directory.appendingPathComponent("immutable-web.png"))
                try expected.write(to: directory.appendingPathComponent("immutable-web.rgba"))
                let (root, declarationRecords) = try makeTree(control)
                let originalFrame = root.frame, originalTransform = root.transform
                let originalPosition = root.position, originalAnchor = root.anchorPoint
                let capture = try await NativeDetachedLayerMetalCapture.capture(root: root, size: page.size, scale: scale)
                // Preserve raw output before guards, including blank/invalid captures.
                try capture.canonicalRGBA.write(to: directory.appendingPathComponent("detached-ca.rgba"))
                let nativePNG = try #require(UIImage(cgImage: capture.image).pngData())
                try nativePNG.write(to: directory.appendingPathComponent("detached-ca.png"))
                let transported = try pixels(capture.image)
                let opaque = stride(from: 3, to: capture.canonicalRGBA.count, by: 4).allSatisfy { capture.canonicalRGBA[$0] == 255 }
                let restored = root.superlayer == nil && root.frame == originalFrame && root.position == originalPosition && root.anchorPoint == originalAnchor && CATransform3DEqualToTransform(root.transform, originalTransform)
                let valid = capture.width == 960 && capture.height == 480 && transported == capture.canonicalRGBA && opaque && restored
                var record = difference(expected, capture.canonicalRGBA)
                record["scene"] = control.name; record["referencePNGHash"] = reference.pngHash
                record["referenceRGBAHash"] = reference.rgbaHash; record["referenceDOMHash"] = reference.domHash
                record["nativeRGBAHash"] = hash(capture.canonicalRGBA); record["nativePNGHash"] = hash(nativePNG)
                record["source"] = manifest.source; record["sourceLiteralInputsHash"] = manifest.literalInputsHash
                record["sourceOriginalOwner"] = control.originalOwner; record["sourceFinalOwner"] = control.finalOwner
                record["sourceLayers"] = control.layers.map { ["position": $0.position, "size": $0.size, "color": $0.color] }
                record["layerGraph"] = declarationRecords; record["renderer"] = capture.metadata
                record["guards"] = ["dimensionsAndTransportOpaqueRestored": valid, "opaque": opaque, "restored": restored]
                record["windowAttachment"] = false; record["wholePageResize"] = false
                record["referenceRegenerated"] = false; record["consumerScope"] = "public detached CA diagnostic, not production renderer"
                reports.append(record)
                try json(record, to: directory.appendingPathComponent("comparison.json"))
                if !valid || record["exactRGBA"] as? Bool != true { failures.append(control.name + ": " + String(describing: record["changedPixels"] ?? "invalid capture") + " changed pixels") }
            } catch is CancellationError { throw CancellationError() }
            catch { failures.append(control.name + ": " + String(describing: error)) }
        }
        try json(["expectedCount": 4, "count": reports.count, "complete": reports.count == 4,
                  "passed": reports.count == 4 && failures.isEmpty, "pixelParityAsserted": true,
                  "fixtureHash": fixtureHash, "screenReferenceScale": scale, "reports": reports, "failures": failures,
                  "scope": "Four unchanged positive/negative/moved/overlapping foreign-background scenes; immutable54 full RGBA, zero tolerance; no production promotion"], to: output.appendingPathComponent("report.json"))
        #expect(reports.count == 4 && failures.isEmpty, Comment(rawValue: failures.joined(separator: "\n")))
    }

    private func makeTree(_ control: Control) throws -> (CALayer, [[String: Any]]) {
        guard control.originalOwner.count == 4, control.finalOwner.count == 4 else { throw Failure.geometry }
        let owner = NativeTranslationRenderer.usedRect(rect(control.finalOwner))
        let paintedBorder = NativeTranslationPDFCapture.snappedRect(owner, deviceScale: scale)
        let root = CALayer(); root.frame = page; root.contentsScale = scale; root.isOpaque = true
        root.backgroundColor = try color([41,65,87])
        CATransaction.begin(); CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        let base = CALayer(); base.frame = paintedBorder; base.contentsScale = scale
        base.backgroundColor = try color(control.base); root.addSublayer(base)
        var records: [[String: Any]] = [["kind": "base", "usedOwner": values(owner), "paintedBorder": values(paintedBorder), "radius": 0, "color": control.base]]
        // CSS's first listed background is topmost; append it last to CA.
        for (sourceIndex, fill) in control.layers.enumerated().reversed() {
            guard fill.position.count == 2, fill.size.count == 2,
                  let geometry = NativeForeignBackgroundGradient.geometry(owner: owner,
                    position: CGPoint(x: fill.position[0], y: fill.position[1]),
                    size: CGSize(width: fill.size[0], height: fill.size[1]), deviceScale: scale) else { throw Failure.geometry }
            guard !geometry.usesPattern else { throw Failure.unsupportedPattern }
            // BackgroundPainter destination clip, then GradientImage's own tile bounds.
            let clip = CALayer(); clip.frame = geometry.destination; clip.contentsScale = scale; clip.masksToBounds = true
            let gradient = CAGradientLayer()
            gradient.frame = geometry.tile.offsetBy(dx: -geometry.destination.minX, dy: -geometry.destination.minY)
            gradient.contentsScale = scale; gradient.type = .axial
            gradient.startPoint = CGPoint(x: 0.5, y: 0); gradient.endPoint = CGPoint(x: 0.5, y: 1)
            let c = try color(fill.color); gradient.colors = [c,c]; gradient.locations = [0,1]
            clip.addSublayer(gradient); root.addSublayer(clip)
            records.append(["kind": "foreign-gradient", "sourceIndex": sourceIndex,
                "declaredPosition": fill.position, "declaredSize": fill.size, "color": fill.color,
                "destination": values(geometry.destination), "tile": values(geometry.tile),
                "gradientLocalFrame": values(gradient.frame), "destinationClip": true, "tileBoundsClip": true])
        }
        return (root, records)
    }
    private func color(_ rgb: [Double]) throws -> CGColor {
        guard rgb.count == 3, rgb.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }),
              let space = CGColorSpace(name: CGColorSpace.sRGB),
              let value = CGColor(colorSpace: space, components: rgb.map { CGFloat(Float($0 / 255)) } + [1]) else { throw Failure.source }
        return value
    }
    private func rect(_ a: [Double]) -> CGRect { CGRect(x:a[0],y:a[1],width:a[2],height:a[3]) }
    private func values(_ a: CGRect) -> [CGFloat] { [a.minX,a.minY,a.width,a.height] }
    private func hash(_ d: Data) -> String { SHA256.hash(data: d).map { String(format:"%02x",$0) }.joined() }
    private func json(_ v: Any, to url: URL) throws { try JSONSerialization.data(withJSONObject:v,options:[.sortedKeys,.prettyPrinted]).write(to:url,options:.atomic) }
    private func pixels(_ image: CGImage) throws -> Data {
        let c = try #require(CGContext(data:nil,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width*4,
            space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue))
        let pointer = try #require(c.data); c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height))
        return Data(bytes:pointer,count:image.width*image.height*4)
    }
    private func difference(_ a: Data, _ b: Data) -> [String: Any] {
        guard a.count == b.count else { return ["exactRGBA":false,"dimensionMismatch":true] }
        var pixels = 0, bytes = 0, maximum = 0
        a.withUnsafeBytes { lhs in b.withUnsafeBytes { rhs in
            let l=lhs.bindMemory(to:UInt8.self),r=rhs.bindMemory(to:UInt8.self)
            for p in stride(from:0,to:a.count,by:4) { var changed=false
                for c in 0..<4 { let d=abs(Int(l[p+c])-Int(r[p+c])); maximum=max(maximum,d); if d != 0 { changed=true; bytes += 1 } }
                if changed { pixels += 1 }
            }
        } }
        return ["exactRGBA":pixels==0,"changedPixels":pixels,"changedBytes":bytes,"maxChannelDelta":maximum]
    }
}
private final class DetachedForeignFixtureBundle: NSObject {}
