import CoreGraphics
import Foundation

/// Frozen7059–7090 larger-paper crop and proof. The enclosed-paper callback is
/// the complete production restore+finish operation, including donor policies.
enum NativeEarlyMarginPaper {
    struct Input {
        var imageSize: CGSize
        var frame: CGRect
        var bounds: [Double]
        var auxiliary: [[Double]] = []
        var otherBounds: [[Double]] = []
        var sourceFontSize: Double?
        var fontSize: Double
        var vertical = false
        var singleColumn = false
    }
    struct Repair {
        var rgba: [UInt8]
        var safe: [UInt8]
        var sourceErasureVerified: Bool
    }
    struct Result {
        var crop: CGRect
        var viewport: CGRect
        var core: [CGRect]
        var excluded: [CGRect]
        var original: [UInt8]
        var repair: Repair
        var luminance: [UInt8]
    }
    static func propose(_ input: Input, remaining: inout Int,
                        read: (CGRect, Int, Int) throws -> [UInt8],
                        enclosedPaper: ([UInt8], Int, Int, CGRect, [CGRect], [CGRect]) -> Repair?) -> Result? {
        let iw = Double(input.imageSize.width), ih = Double(input.imageSize.height), b = input.bounds
        guard iw.isFinite, ih.isFinite, iw > 0, ih > 0, iw <= 1_000_000, ih <= 1_000_000,
              b.count == 4, b.allSatisfy(\.isFinite), b[2] > 0, b[3] > 0,
              input.frame.width.isFinite, input.frame.width > 0,
              input.fontSize.isFinite, remaining >= 1_024 else { return nil }
        let bx = max(0, floor(b[0] * iw) - 96), by = max(0, floor(b[1] * ih) - 96)
        let br = min(iw, ceil((b[0] + b[2]) * iw) + 96), bb = min(ih, ceil((b[1] + b[3]) * ih) + 96)
        guard [bx, by, br, bb].allSatisfy(\.isFinite), br > bx, bb > by else { return nil }
        let w = Int(br - bx), h = Int(bb - by)
        guard w > 0, h > 0, w <= min(262_144, remaining) / h else { return nil }
        remaining -= w * h // Frozen source charges attempted reads and rejected repairs.
        let crop = CGRect(x: bx, y: by, width: Double(w), height: Double(h))
        guard let rgba = try? read(crop, w, h), rgba.count == w * h * 4 else { return nil }
        func local(_ a: [Double]) -> CGRect? {
            guard a.count == 4, a.allSatisfy(\.isFinite) else { return nil }
            return CGRect(x: a[0] * iw - bx, y: a[1] * ih - by, width: a[2] * iw, height: a[3] * ih)
        }
        let auxiliary = input.auxiliary.compactMap(local), excluded = input.otherBounds.compactMap(local)
        guard let primary = local(b), let repaired = enclosedPaper(rgba, w, h, primary, auxiliary, excluded),
              repaired.rgba.count == w * h * 4, repaired.safe.count == w * h else { return nil }
        let core = [primary] + auxiliary
        guard NativePartialSourceProof.outlineSourceResolved(safe: repaired.safe, width: w, height: h, core: core,
            erasureVerified: repaired.sourceErasureVerified, glyphsVerified: true, pixelRatio: iw / Double(input.frame.width)) else { return nil }
        let font = input.sourceFontSize.flatMap { $0 == 0 || $0.isNaN ? nil:$0 } ?? input.fontSize
        let glyph = max(4, font * iw / Double(input.frame.width))
        if input.vertical && !input.singleColumn && NativePartialSourceProof.hasAttachedLeadingInk(
            safe: repaired.safe, width: w, height: h, core: core, glyph: glyph) { return nil }
        if NativePartialSourceProof.hasLargePartialResidual(safe: repaired.safe, width: w, height: h,
            core: core, glyph: glyph, vertical: input.vertical) { return nil }
        let lookup = (0..<256).map { value -> Double in
            let v = Double(value) / 255
            return v <= 0.04045 ? v / 12.92:pow((v + 0.055) / 1.055, 2.4)
        }
        var luminance = [UInt8](repeating: 0, count: w * h)
        for i in 0..<w * h {
            // Canvas transport selects any painted RGB; it does not alpha blend.
            let p = repaired.rgba[i * 4 + 3] != 0 ? repaired.rgba:rgba
            let red = lookup[Int(p[i * 4])], green = lookup[Int(p[i * 4 + 1])], blue = lookup[Int(p[i * 4 + 2])]
            let value = 255 * (0.2126 * red + 0.7152 * green + 0.0722 * blue)
            luminance[i] = UInt8(floor(value + 0.5))
        }
        return Result(crop: crop,
            viewport: CGRect(x: Double(input.frame.minX) + bx / iw * Double(input.frame.width),
                y: Double(input.frame.minY) + by / ih * Double(input.frame.height),
                width: Double(w) / iw * Double(input.frame.width), height: Double(h) / ih * Double(input.frame.height)),
            core: core, excluded: excluded, original: rgba, repair: repaired, luminance: luminance)
    }
}
