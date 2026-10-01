import CoreGraphics
import Foundation
@testable import Aidoku

/// Test-only evidence for a matched, opaque, standalone rotated panel. This
/// certifies only individual high-delta contour pixels; the caller must retain
/// its complete-image color budget and account for every other changed pixel.
enum NativeFinalExportPanelContourAcceptance {
    struct Evidence {
        let certifiedPixels: [Int]
        let report: [String: Any]
    }

    static func evaluate(reference: [UInt8], actual: [UInt8], width: Int, height: Int,
                         scale: Double, nativeCard: [String: Any], webLayers: [[String: Any]]) -> Evidence? {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384, scale.isFinite, scale > 0, scale <= 4,
              Float(scale).isFinite, Float(scale) > 0, Float(1 / scale).isFinite, Float(1 / scale) > 0 else { return nil }
        let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = pixels.multipliedReportingOverflow(by: 4)
        guard !overflow, !byteOverflow, pixels <= 12_000_000, reference.count == bytes, actual.count == bytes,
              let id = nativeCard["id"] as? String,
              nativeCard["sourceBackgroundKind"] as? String == "rotated-panel",
              nativeCard["hidden"] as? Bool == false, nativeCard["removed"] as? Bool == false,
              nativeCard["drawsPanel"] as? Bool == false,
              let foreign = nativeCard["foreignFills"] as? [Any], foreign.isEmpty,
              let backings = nativeCard["backings"] as? [Any], backings.isEmpty,
              let panels = nativeCard["panels"] as? [[String: Any]], panels.count == 1,
              let panel = panels.first, panel["overflowClip"] as? Bool == false,
              panel["sourceBridgeClipped"] as? Bool == false,
              let frame = rect(panel["rect"]), let cardFrame = rect(nativeCard["rect"]), frame == cardFrame,
              let coverage = panel["coverage"] as? [[Double]], coverage.count == 1, rect(coverage[0]) == frame,
              let rgb = panel["background"] as? [Int], rgb.count == 3, rgb.allSatisfy({ (0...255).contains($0) }),
              let radius = panel["radius"] as? Double, radius.isFinite, radius > 0,
              radius * 2 <= min(frame.width, frame.height),
              let angle = nativeCard["rotation"] as? Double, angle.isFinite, angle != 0,
              let nativeInk = rect(nativeCard["ink"]) else { return nil }
        let matching = webLayers.filter { $0["id"] as? String == id && $0["kind"] as? String == "source-rotated-panel" }
        let items = webLayers.filter { $0["id"] as? String == id && $0["kind"] as? String == "item" }
        guard matching.count == 1, items.count == 1, let web = matching.first, let item = items.first,
              web["parentKind"] as? String == "root", web["childElementCount"] as? Int == 0,
              let style = web["style"] as? [String: Any], let webFrame = cssRect(style),
              let webInk = dictionaryRect(item["ink"]), let webBounds = dictionaryRect(web["rect"]),
              style["display"] as? String == "block", style["overflow"] as? String == "visible",
              style["backgroundImage"] as? String == "none", number(style["opacity"]) == 1,
              style["scale"] as? String == "none", style["rotate"] as? String == "none",
              style["translate"] as? String == "none", cssNumber(style["borderRadius"]) == radius,
              color(style["backgroundColor"]) == rgb,
              close(frame, webFrame, tolerance: 1 / 64),
              let matrix = components(style["transform"], prefix: "matrix(", suffix: ")"), matrix.count == 6,
              abs(matrix[0] - cos(angle)) <= 0.000001, abs(matrix[1] - sin(angle)) <= 0.000001,
              abs(matrix[2] + sin(angle)) <= 0.000001, abs(matrix[3] - cos(angle)) <= 0.000001,
              matrix[4] == 0, matrix[5] == 0,
              let origin = (style["transformOrigin"] as? String)?.split(separator: " ").map({ cssNumber(String($0)) }),
              origin.count == 2, let ox = origin[0], let oy = origin[1],
              abs(ox - webFrame.width / 2) <= 0.000001, abs(oy - webFrame.height / 2) <= 0.000001,
              clearClip(style["clipPath"], size: webFrame.size) else { return nil }
        let transform = CGAffineTransform(translationX: frame.midX, y: frame.midY)
            .rotated(by: angle).translatedBy(x: -frame.midX, y: -frame.midY)
        guard close(frame.applying(transform), webBounds, tolerance: 1 / 64) else { return nil }
        let coordinates = [frame.minX, frame.minY, frame.maxX, frame.maxY, frame.width, frame.height, radius]
        let physicalLimit = Double(max(width, height))
        guard frame.minX >= 0, frame.minY >= 0, frame.maxX <= Double(width) / scale,
              frame.maxY <= Double(height) / scale, coordinates.allSatisfy({ $0.isFinite && Float($0).isFinite && ($0 * scale).isFinite
            && abs($0 * scale) <= physicalLimit }) else { return nil }
        let original = NativeTranslationPDFCapture.roundedPath(frame, radius: radius, deviceScale: scale)
        var mutableTransform = transform
        guard let path = original.copy(using: &mutableTransform), let contour = flattened(path, scale: scale) else { return nil }
        let bounds = path.boundingBoxOfPath.insetBy(dx: -1 / scale, dy: -1 / scale)
        guard bounds.minX >= 0, bounds.minY >= 0, bounds.maxX * scale < Double(width),
              bounds.maxY * scale < Double(height) else { return nil }
        let x0 = Int(floor(bounds.minX * scale)), y0 = Int(floor(bounds.minY * scale))
        let x1 = Int(ceil(bounds.maxX * scale)), y1 = Int(ceil(bounds.maxY * scale))
        let (area, areaOverflow) = (x1 - x0).multipliedReportingOverflow(by: y1 - y0)
        guard !areaOverflow, area > 0, area <= 262_144 else { return nil }
        let text = nativeInk.union(webInk).insetBy(dx: -1 / scale, dy: -1 / scale)
        var referenceMaterial = 0, actualMaterial = 0, certified: [Int] = [], maximumDistance = 0.0
        for y in y0..<y1 {
            for x in x0..<x1 {
                let pixel = y * width + x, offset = pixel * 4
                guard reference[offset + 3] == 255, actual[offset + 3] == 255 else { return nil }
                var difference = 0, referenceDistance = 0, actualDistance = 0
                for channel in 0..<3 {
                    difference = max(difference, abs(Int(reference[offset + channel]) - Int(actual[offset + channel])))
                    referenceDistance = max(referenceDistance, abs(Int(reference[offset + channel]) - rgb[channel]))
                    actualDistance = max(actualDistance, abs(Int(actual[offset + channel]) - rgb[channel]))
                }
                if referenceDistance <= 8 { referenceMaterial += 1 }
                if actualDistance <= 8 { actualMaterial += 1 }
                guard difference > 16 else { continue }
                let point = CGPoint(x: Double(x) + 0.5, y: Double(y) + 0.5)
                guard !text.contains(CGPoint(x: point.x / scale, y: point.y / scale)) else { continue }
                let distance = distanceToContour(point, contour)
                guard distance <= 1 else { continue }
                guard difference <= 32, compatibleBlend(reference, actual, offset: offset, fill: rgb) else { return nil }
                certified.append(pixel); maximumDistance = max(maximumDistance, distance)
            }
        }
        // A one-pixel thickness change is not antialiasing. Match the large
        // constant-color material independently of the edge's channel maximum.
        guard !certified.isEmpty, referenceMaterial > area / 2,
              abs(actualMaterial - referenceMaterial) <= max(2, referenceMaterial / 1000) else { return nil }
        return Evidence(certifiedPixels: certified, report: ["kind": "matched-rounded-panel-contour", "id": id,
            "certifiedHighDeltaPixels": certified.count, "maximumContourDistancePixels": maximumDistance,
            "panelEdgeChannelDeltaLimit": 32,
            "referenceMaterialPixels": referenceMaterial, "actualMaterialPixels": actualMaterial,
            "matchingFill": rgb, "radius": radius, "rotation": angle,
            "opaqueStandalonePanel": true, "matchingShapeWithinCSSLayoutUnit": true])
    }

    private static func rect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Double], a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
    private static func dictionaryRect(_ value: Any?) -> CGRect? {
        guard let d = value as? [String: Double], let x = d["x"], let y = d["y"], let w = d["width"], let h = d["height"] else { return nil }
        return rect([x, y, w, h])
    }
    private static func number(_ value: Any?) -> Double? {
        guard let s = value as? String, let v = Double(s), v.isFinite else { return nil }; return v
    }
    private static func cssNumber(_ value: Any?) -> Double? {
        guard let s = value as? String, s.hasSuffix("px") else { return nil }; return number(String(s.dropLast(2)))
    }
    private static func cssRect(_ style: [String: Any]) -> CGRect? {
        guard let x = cssNumber(style["left"]), let y = cssNumber(style["top"]),
              let w = cssNumber(style["width"]), let h = cssNumber(style["height"]) else { return nil }; return rect([x, y, w, h])
    }
    private static func close(_ a: CGRect, _ b: CGRect, tolerance: Double) -> Bool {
        zip([a.minX,a.minY,a.width,a.height], [b.minX,b.minY,b.width,b.height]).allSatisfy { abs($0 - $1) <= tolerance }
    }
    private static func components(_ value: Any?, prefix: String, suffix: String) -> [Double]? {
        guard let s = value as? String, s.hasPrefix(prefix), s.hasSuffix(suffix) else { return nil }
        let parts = s.dropFirst(prefix.count).dropLast(suffix.count).split(separator: ",")
        let result = parts.compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        return result.count == parts.count && result.allSatisfy(\.isFinite) ? result : nil
    }
    private static func color(_ value: Any?) -> [Int]? {
        guard let values = components(value, prefix: "rgb(", suffix: ")"), values.count == 3,
              values.allSatisfy({ $0.rounded() == $0 && (0...255).contains($0) }) else { return nil }; return values.map(Int.init)
    }
    private static func clearClip(_ value: Any?, size: CGSize) -> Bool {
        guard let s = value as? String else { return false }
        if s == "none" { return true }
        guard s.hasPrefix("polygon("), s.hasSuffix(")") else { return false }
        let vertices = s.dropFirst(8).dropLast().split(separator: ",").compactMap { token -> CGPoint? in
            let pair = token.split(whereSeparator: \.isWhitespace)
            guard pair.count == 2, let x = cssNumber(String(pair[0])), let y = cssNumber(String(pair[1])) else { return nil }
            return CGPoint(x: x, y: y)
        }
        guard vertices.count == 4 else { return false }
        for point in [CGPoint.zero, CGPoint(x: size.width, y: 0), CGPoint(x: size.width, y: size.height), CGPoint(x: 0, y: size.height)] {
            var sign = 0.0
            for i in 0..<4 {
                let a = vertices[i], b = vertices[(i + 1) % 4]
                let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
                guard cross.isFinite, abs(cross) > 0.000001 else { return false }
                if sign == 0 { sign = cross } else if cross * sign < 0 { return false }
            }
        }
        return true
    }
    private static func flattened(_ path: CGPath, scale: Double) -> [CGPoint]? {
        var points: [CGPoint] = [], current = CGPoint.zero, first = CGPoint.zero, valid = true
        path.applyWithBlock { pointer in
            let e = pointer.pointee
            switch e.type {
            case .moveToPoint: current = e.points[0]; first = current; points.append(current)
            case .addLineToPoint: current = e.points[0]; points.append(current)
            case .addCurveToPoint:
                let a = current, b = e.points[0], c = e.points[1], end = e.points[2]
                for i in 1...32 {
                    let t = Double(i) / 32, u = 1 - t
                    points.append(CGPoint(x: u*u*u*a.x + 3*u*u*t*b.x + 3*u*t*t*c.x + t*t*t*end.x,
                        y: u*u*u*a.y + 3*u*u*t*b.y + 3*u*t*t*c.y + t*t*t*end.y))
                }
                current = end
            case .closeSubpath: points.append(first); current = first
            default: valid = false
            }
        }
        guard valid, points.count >= 4, points.count <= 256, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let physical = points.map { CGPoint(x: $0.x * scale, y: $0.y * scale) }
        return physical.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) ? physical : nil
    }
    private static func distanceToContour(_ p: CGPoint, _ contour: [CGPoint]) -> Double {
        var best = Double.infinity
        for i in 1..<contour.count {
            let a = contour[i - 1], b = contour[i], dx = b.x - a.x, dy = b.y - a.y, squared = dx*dx + dy*dy
            guard squared > 0 else { continue }
            let t = min(1, max(0, ((p.x - a.x)*dx + (p.y - a.y)*dy) / squared))
            best = min(best, hypot(p.x - a.x - t*dx, p.y - a.y - t*dy))
        }
        return best
    }
    private static func compatibleBlend(_ reference: [UInt8], _ actual: [UInt8], offset: Int, fill: [Int]) -> Bool {
        var a = (0..<3).map { Double(Int(actual[offset + $0]) - fill[$0]) }
        var b = (0..<3).map { Double(Int(reference[offset + $0]) - fill[$0]) }
        var aa = a.reduce(0.0) { $0 + $1*$1 }; let bb = b.reduce(0.0) { $0 + $1*$1 }
        if aa > bb { swap(&a, &b); aa = bb }
        if aa == 0 { return true }
        let denominator = b.reduce(0.0) { $0 + $1*$1 }
        guard denominator > 0 else { return false }
        let fraction = zip(a,b).reduce(0.0) { $0 + $1.0*$1.1 } / denominator
        return fraction >= 0 && fraction <= 1 && zip(a,b).allSatisfy { abs($0 - fraction*$1) <= 2 }
    }
}
