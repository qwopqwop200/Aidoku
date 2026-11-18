import Foundation
import CoreGraphics

/// Read-only original-pixel observation. No-veto is NOT native admission.
/// Private pixels must be authenticated by the caller; this helper does not
/// create ownership, resolve peer membership, or authorize erasure.
@available(iOS 18.0, *)
enum NativeOCRResidualTurningStrokeGuardHistogram {
    struct LocalRGBA {
        let bytes: [UInt8]
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let origin: CGPoint
    }
    struct Palette: Codable {
        let rgb: [Int]
        let sourceSeedBinCount: Int
        let bin: Int
    }
    struct Witness: Codable {
        let pixels: Int
        let solid2x2Blocks: Int
        let minorVariance: Double
        let sourceRGB: [Int]
        let sourceSeedBinCount: Int
        let bin: Int
        let sourceBounds: [Double]
        let normalSpan: Double
        let alongSpan: Double
    }
    struct Result: Codable {
        let decision: String
        let reason: String
        let palettes: [Palette]
        let witnesses: [Witness]
        let privateRGBSamples: Int
        let counts: [String: Int]
        let noVetoIsNotAdmission: Bool
        let ownershipMutated: Bool
        let erasureRights: String
    }

    static func assess(
        old: [CGPoint], new: [CGPoint], rgba: LocalRGBA,
        authenticatedPalettes: [Palette], privateRGBSampleCount: Int, frameOrigin: CGPoint,
        normal: CGPoint, along: CGPoint, sourceWidth: Double,
        inheritedNormalBounds: ClosedRange<Double>
    ) -> Result {
        func result(_ decision: String, _ reason: String, _ palettes: [Palette] = [],
                    _ witnesses: [Witness] = [], _ samples: Int = 0,
                    _ counts: [String: Int] = [:]) -> Result {
            .init(decision: decision, reason: reason, palettes: palettes,
                  witnesses: witnesses, privateRGBSamples: samples, counts: counts,
                  noVetoIsNotAdmission: true, ownershipMutated: false, erasureRights: "none")
        }
        let w = rgba.width, h = rgba.height, stride = rgba.bytesPerRow
        guard w > 0, h > 0, w <= Int.max / 4, stride >= w * 4,
              h <= Int.max / stride, rgba.bytes.count >= h * stride,
              w <= Int.max / h, old.count == 4, new.count == 4,
              sourceWidth.isFinite, sourceWidth > 0,
              (old + new + [rgba.origin, frameOrigin, normal, along]).allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else {
            return result("uncertain", "invalid-source-observation")
        }
        guard old.allSatisfy({ $0.x >= rgba.origin.x && $0.y >= rgba.origin.y
            && $0.x <= rgba.origin.x + Double(w) && $0.y <= rgba.origin.y + Double(h) }) else {
            return result("uncertain", "inherited-source-pixels-not-fully-observed")
        }
        func code(_ offset: Int) -> Int {
            Int(rgba.bytes[offset] / 8) * 1024
                + Int(rgba.bytes[offset + 1] / 8) * 32 + Int(rgba.bytes[offset + 2] / 8)
        }
        let sampleCount = privateRGBSampleCount
        guard sampleCount >= 4 else {
            return result("uncertain", "insufficient-authentic-private-colour-observation")
        }
        let palettes = authenticatedPalettes
        guard !palettes.isEmpty else {
            return result("uncertain", "no-repeated-private-colour-bin")
        }
        let size = w * h
        var oldMask = [Bool](repeating: false, count: size)
        var newMask = oldMask
        for y in 0..<h { for x in 0..<w {
            let point = CGPoint(x: rgba.origin.x + Double(x) + 0.5,
                                y: rgba.origin.y + Double(y) + 0.5)
            oldMask[y * w + x] = contains(old, point)
            newMask[y * w + x] = contains(new, point)
        }}
        var counts = ["matchingClosed": 0, "entirelyOldInside": 0,
                      "entirelyNewExcluded": 0, "alignedAndGlyphScale": 0]
        var witnesses: [Witness] = []
        for palette in palettes {
            var mask = [UInt8](repeating: 0, count: size)
            for y in 0..<h { for x in 0..<w {
                let offset = y * stride + x * 4
                if rgba.bytes[offset + 3] == 255 && code(offset) == palette.bin { mask[y * w + x] = 1 }
            }}
            var queue: [Int] = []
            for seed in 0..<size where mask[seed] != 0 {
                queue.removeAll(keepingCapacity: true)
                queue.append(seed); mask[seed] = 0
                var cursor = 0, open = false, affected = false
                var allOld = true, anyNew = false
                var x0 = w, y0 = h, x1 = 0, y1 = 0
                while cursor < queue.count {
                    let pixel = queue[cursor]; cursor += 1
                    let x = pixel % w, y = pixel / w
                    x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                    open = open || x == 0 || y == 0 || x == w - 1 || y == h - 1
                    affected = affected || (oldMask[pixel] && !newMask[pixel])
                    allOld = allOld && oldMask[pixel]; anyNew = anyNew || newMask[pixel]
                    for yy in max(0, y - 1)...min(h - 1, y + 1) {
                        for xx in max(0, x - 1)...min(w - 1, x + 1) {
                            let next = yy * w + xx
                            if mask[next] != 0 { mask[next] = 0; queue.append(next) }
                        }
                    }
                }
                guard affected, !open, queue.count >= 4 else { continue }
                counts["matchingClosed", default: 0] += 1
                guard allOld else { continue }
                counts["entirelyOldInside", default: 0] += 1
                guard !anyNew else { continue }
                counts["entirelyNewExcluded", default: 0] += 1
                // Row-major order matches the original-pixel Python observation.
                queue.sort()
                var points: [CGPoint] = []
                var n0 = Double.infinity, n1 = -Double.infinity
                var a0 = Double.infinity, a1 = -Double.infinity
                var sumX = 0.0, sumY = 0.0
                for pixel in queue {
                    let point = CGPoint(x: rgba.origin.x + Double(pixel % w) + 0.5 - frameOrigin.x,
                                        y: rgba.origin.y + Double(pixel / w) + 0.5 - frameOrigin.y)
                    points.append(point); sumX += point.x; sumY += point.y
                    let n = point.x * normal.x + point.y * normal.y
                    let a = point.x * along.x + point.y * along.y
                    n0 = min(n0, n); n1 = max(n1, n); a0 = min(a0, a); a1 = max(a1, a)
                }
                guard n0 >= inheritedNormalBounds.lowerBound - 0.15 * sourceWidth,
                      n1 <= inheritedNormalBounds.upperBound + 0.15 * sourceWidth,
                      max(n1 - n0 + 1, a1 - a0 + 1) <= 1.25 * sourceWidth else { continue }
                let meanX = sumX / Double(points.count), meanY = sumY / Double(points.count)
                var xx = 0.0, xy = 0.0, yy = 0.0
                for p in points {
                    let dx = p.x - meanX, dy = p.y - meanY
                    xx += dx * dx; xy += dx * dy; yy += dy * dy
                }
                xx /= Double(points.count); xy /= Double(points.count); yy /= Double(points.count)
                let minor = (xx + yy - hypot(xx - yy, 2 * xy)) / 2
                guard minor >= 0.25 else { continue }
                counts["alignedAndGlyphScale", default: 0] += 1
                let members = Set(queue)
                var blocks = 0
                for pixel in queue where pixel % w < w - 1 && pixel / w < h - 1 {
                    if members.contains(pixel + 1) && members.contains(pixel + w)
                        && members.contains(pixel + w + 1) { blocks += 1 }
                }
                witnesses.append(.init(pixels: queue.count, solid2x2Blocks: blocks,
                    minorVariance: minor, sourceRGB: palette.rgb,
                    sourceSeedBinCount: palette.sourceSeedBinCount, bin: palette.bin,
                    sourceBounds: [rgba.origin.x + Double(x0), rgba.origin.y + Double(y0),
                                   rgba.origin.x + Double(x1 + 1), rgba.origin.y + Double(y1 + 1)],
                    normalSpan: n1 - n0 + 1, alongSpan: a1 - a0 + 1))
            }
        }
        return result(witnesses.isEmpty ? "no-entire-closed-component-loss-observed" : "reject",
                      witnesses.isEmpty ? "no-qualifying-entire-component-loss" : "entire-authentic-palette-component-disappears",
                      palettes, witnesses, sampleCount, counts)
    }

    private static func contains(_ q: [CGPoint], _ point: CGPoint) -> Bool {
        var positive = true, negative = true
        for i in 0..<4 {
            let a = q[i], b = q[(i + 1) % 4]
            let cross = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            positive = positive && cross >= -1e-7
            negative = negative && cross <= 1e-7
        }
        return positive || negative
    }
}
