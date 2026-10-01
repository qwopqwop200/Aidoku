import CoreGraphics
import Foundation

/// A source quad can exclude drawing still inside its axis-aligned OCR bounds.
/// This proof qualifies body glyphs only. It cannot paint, change safe pixels,
/// or certify complete erasure of the surrounding OCR rectangle.
struct NativeObservedGlyphOwnership {
    let body: [UInt8]
    let auxiliary: [UInt8]
    let separateAuxiliary: [UInt8]
    private let auxiliaryRects: [CGRect]

    static func make(width: Int, height: Int, box: CGRect, polygon: [CGPoint], auxiliary: [CGRect]) -> Self? {
        guard width > 0, height > 0, width <= 262_144 / height, polygon.count == 4, auxiliary.count <= 32,
              [box.minX, box.minY, box.width, box.height].allSatisfy(\.isFinite), box.width > 0, box.height > 0,
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                  $0.x <= CGFloat(width) && $0.y <= CGFloat(height) }) else { return nil }
        // Reject crossed/degenerate quads before using the shared pixel-center rasterizer.
        var sign: CGFloat = 0
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % 4], c = polygon[(i + 2) % 4]
            let cross = (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            guard cross.isFinite, cross != 0, sign == 0 || (sign > 0) == (cross > 0) else { return nil }
            sign = cross
        }
        let left = polygon.map(\.x).min()!, right = polygon.map(\.x).max()!
        let top = polygon.map(\.y).min()!, bottom = polygon.map(\.y).max()!
        // The quad must describe this OCR box, not a smaller convenient region.
        guard abs(left - box.minX) <= 0.5, abs(right - box.maxX) <= 0.5,
              abs(top - box.minY) <= 0.5, abs(bottom - box.maxY) <= 0.5,
              let body = NativeSourceGlyphSegmentation.geometryMask(width: width, height: height, polygons: [polygon], margin: 1),
              body.core.contains(1) else { return nil }
        var auxiliaryMask = [UInt8](repeating: 0, count: width * height), separate = auxiliaryMask
        for rect in auxiliary {
            guard [rect.minX, rect.minY, rect.width, rect.height].allSatisfy(\.isFinite), rect.width > 0, rect.height > 0,
                  rect.minX >= 0, rect.minY >= 0, rect.maxX <= CGFloat(width), rect.maxY <= CGFloat(height) else { return nil }
            let points = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                          CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]
            guard let mask = NativeSourceGlyphSegmentation.geometryMask(width: width, height: height, polygons: [points], margin: 1),
                  mask.core.contains(1) else { return nil }
            let redundant = mask.core.indices.allSatisfy { mask.core[$0] == 0 || body.core[$0] != 0 }
            for i in mask.mask.indices where mask.mask[i] != 0 {
                auxiliaryMask[i] = 1
                // A body-contained OCR erasure polygon is not a second ruby line.
                if !redundant { separate[i] = 1 }
            }
        }
        return Self(body: body.mask, auxiliary: auxiliaryMask, separateAuxiliary: separate, auxiliaryRects: auxiliary)
    }

    /// The exact supplied auxiliary rectangles must already be raster-proven
    /// inside the retained source quad, not merely inside its bounding box.
    func certifiesRedundantAuxiliary(_ rectangles: [CGRect]) -> Bool {
        rectangles == auxiliaryRects && !separateAuxiliary.contains(1)
    }

    func certifiesBodyGlyphs(protectedInk: [UInt8], frameInk: [UInt8]) -> Bool {
        guard protectedInk.count == body.count, frameInk.count == body.count,
              auxiliary.count == body.count, separateAuxiliary.count == body.count else { return false }
        for i in body.indices {
            if frameInk[i] != 0 && separateAuxiliary[i] != 0 { return false }
            if protectedInk[i] != 0 && frameInk[i] == 0 && (body[i] != 0 || auxiliary[i] != 0) { return false }
        }
        return true
    }
}
