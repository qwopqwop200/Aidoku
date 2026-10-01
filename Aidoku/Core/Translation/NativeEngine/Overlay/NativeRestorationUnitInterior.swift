import CoreGraphics
import Foundation

extension NativeTranslationRestoration {
    /// Joined source boxes own only their measured balloon and member lettering.
    /// The native contour's spans define exactly the same sampled fill as the browser.
    static func clipUnitInterior(item: NativeTranslationLayoutItem, prepared: NativeSpatialSourceCrop.Prepared, imageSize: CGSize,
                                 repaired: inout NativeRestorationPixels, frame: CGRect? = nil, detached: Bool = false,
                                 slantedProof: NativeSlantedRestoration.ProofRaster? = nil) -> Bool {
        // The browser applies joined-unit clipping only to ordinary spatial
        // proposals. Rectified and detached proposals retain their own quad proof.
        guard slantedProof == nil && !detached else { return true }
        let members = item.unitMemberRects, b = item.sourceBounds
        let f = frame.map { [$0.minX, $0.minY, $0.width, $0.height] } ?? item.sourceFrame
        guard members.count >= 2, members.count <= 8, b.count == 4, f.count == 4,
              f.allSatisfy(\.isFinite), f[2] > 0, f[3] > 0, let interior = item.balloonInterior,
              interior.rect.count == 4, interior.rect.allSatisfy(\.isFinite), interior.rect[2] > 0, interior.rect[3] > 0,
              interior.spans.count >= 2, interior.spans.count.isMultiple(of: 2), interior.spans.allSatisfy(\.isFinite),
              members.allSatisfy({ r in r.count == 4 && r.allSatisfy(\.isFinite) && r[2] > 0 && r[3] > 0 &&
                  r[0] >= b[0] - 0.0001 && r[1] >= b[1] - 0.0001 && r[0] + r[2] <= b[0] + b[2] + 0.0001 &&
                  r[1] + r[3] <= b[1] + b[3] + 0.0001 }) else { return true }
        let r = interior.rect
        let left = f[0] + r[0] * f[2], top = f[1] + r[1] * f[3], width = r[2] * f[2], height = r[3] * f[3]
        let k = min(2, sqrt(250_000 / max(1, Double(width * height))))
        let w = Int(ceil(Double(width) * k)), h = Int(ceil(Double(height) * k))
        guard w >= 8, h >= 8 else { return true }
        let bands = interior.spans.count / 2
        var fill = [UInt8](repeating: 0, count: w * h), area = 0
        for y in 0..<h {
            let band = min(bands - 1, Int(floor((Double(y) + 0.5) / Double(h) * Double(bands))))
            let l = interior.spans[band * 2], rr = interior.spans[band * 2 + 1]
            guard l >= 0, rr > l else { continue }
            let x0 = max(0, Int(ceil((Double(f[0]) + l * Double(f[2]) - Double(left)) * k - 0.5)))
            let x1 = min(w, Int(floor((Double(f[0]) + rr * Double(f[2]) - Double(left)) * k - 0.5)) + 1)
            if x1 > x0 { for x in x0..<x1 { fill[y * w + x] = 1; area += 1 } }
        }
        guard area > 0 else { return true }
        let iw = imageSize.width, ih = imageSize.height
        let memberPixels = members.map { r in CGRect(x: (r[0] * iw - prepared.crop.minX) * prepared.sx,
            y: (r[1] * ih - prepared.crop.minY) * prepared.sy, width: r[2] * iw * prepared.sx, height: r[3] * ih * prepared.sy) }
        var leftInk = 0
        for yy in 0..<repaired.height {
            let cy = f[1] + (prepared.crop.minY + (CGFloat(yy) + 0.5) / prepared.sy) / ih * f[3]
            let fy = Int(floor(Double(cy - top) * k))
            for xx in 0..<repaired.width {
                let cx = f[0] + (prepared.crop.minX + (CGFloat(xx) + 0.5) / prepared.sx) / iw * f[2]
                let fx = Int(floor(Double(cx - left) * k))
                if fx >= 0 && fy >= 0 && fx < w && fy < h && fill[fy * w + fx] != 0 { continue }
                let i = yy * repaired.width + xx
                repaired.layoutSafe?[i] = 0
                if memberPixels.contains(where: { CGFloat(xx) + 0.5 >= $0.minX && CGFloat(xx) + 0.5 <= $0.maxX &&
                    CGFloat(yy) + 0.5 >= $0.minY && CGFloat(yy) + 0.5 <= $0.maxY }) {
                    if repaired.rgba[i * 4 + 3] == 0 && Int(prepared.pixels.rgba[i * 4]) +
                        Int(prepared.pixels.rgba[i * 4 + 1]) + Int(prepared.pixels.rgba[i * 4 + 2]) < 384 { leftInk += 1 }
                    continue
                }
                repaired.rgba[i * 4 + 3] = 0
            }
        }
        return Double(leftInk) <= max(24, Double(repaired.count) * 0.002)
    }
}
