import CoreGraphics
import Foundation

/// Frozen clearShift crop occupancy search. This table is reused for a caption;
/// moving its frame still requires the full glyph and surface proof afterward.
enum NativeTypographyPlacementSearch {
    struct Table {
        let width: Int
        let height: Int
        let crop: CGRect
        let sx: CGFloat
        let sy: CGFloat
        private let sums: [Int32]

        init?(safe: [UInt8], width: Int, height: Int, crop: CGRect, obstacles: [CGRect]) {
            guard width > 0, height > 0, width <= 262_144 / height,
                  safe.count == width * height, crop.width > 0, crop.height > 0,
                  [crop.minX, crop.minY, crop.width, crop.height].allSatisfy(\.isFinite) else { return nil }
            self.width = width; self.height = height; self.crop = crop
            sx = CGFloat(width) / crop.width; sy = CGFloat(height) / crop.height
            var blocked = safe.map { Int32($0 == 0 ? 1 : 0) }
            for rect in obstacles {
                guard !rect.isNull, [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { continue }
                let left = max(0, min(width, Int(floor((rect.minX - 1 - crop.minX) * sx))))
                let top = max(0, min(height, Int(floor((rect.minY - 0.75 - crop.minY) * sy))))
                let right = max(0, min(width, Int(ceil((rect.maxX + 1 - crop.minX) * sx))))
                let bottom = max(0, min(height, Int(ceil((rect.maxY + 0.75 - crop.minY) * sy))))
                guard left < right, top < bottom else { continue }
                for y in top..<bottom { for x in left..<right { blocked[y * width + x] = 1 } }
            }
            var summed = [Int32](repeating: 0, count: (width + 1) * (height + 1))
            for y in 0..<height {
                var row: Int32 = 0
                for x in 0..<width {
                    row += blocked[y * width + x]
                    summed[(y + 1) * (width + 1) + x + 1] = summed[y * (width + 1) + x + 1] + row
                }
            }
            sums = summed
        }

        /// The source policy rounds pixel origins with Math.round and searches
        /// dy then dx; equal-distance ties keep the first encountered placement.
        func nearestShift(frame: CGRect, size: CGFloat, region: CGRect, reachGlyph: CGFloat) -> CGPoint? {
            guard size > 0, reachGlyph > 0,
                  [frame.minX, frame.minY, frame.maxX, frame.maxY, size, reachGlyph,
                   region.minX, region.minY, region.maxX, region.maxY].allSatisfy(\.isFinite) else { return nil }
            let mx = max(1, size * 0.1), my = max(0.75, size * 0.1)
            let left0 = (frame.minX - mx - crop.minX) * sx, top0 = (frame.minY - my - crop.minY) * sy
            let blockWidth = Int(ceil((frame.width + 2 * mx) * sx)) + 2
            let blockHeight = Int(ceil((frame.height + 2 * my) * sy)) + 2
            let leftBound = max(0, Int(ceil((region.minX - crop.minX) * sx)))
            let topBound = max(0, Int(ceil((region.minY - crop.minY) * sy)))
            let rightBound = min(width, Int(floor((region.maxX - crop.minX) * sx)))
            let bottomBound = min(height, Int(floor((region.maxY - crop.minY) * sy)))
            let reach = Int(floor(reachGlyph * 0.5 * sx + 0.5))
            let ox = Int(floor(left0 + 0.5)), oy = Int(floor(top0 + 0.5))
            guard reach <= 4096, blockWidth > 0, blockHeight > 0,
                  blockWidth <= rightBound - leftBound, blockHeight <= bottomBound - topBound else { return nil }
            var best: (dx: Int, dy: Int, distance: Int)?
            for dy in -reach...reach {
                for dx in -reach...reach {
                    let distance = dx * dx + dy * dy
                    if distance == 0 || best.map({ distance >= $0.distance }) == true { continue }
                    let left = ox + dx, top = oy + dy
                    if left < leftBound || top < topBound || left + blockWidth > rightBound || top + blockHeight > bottomBound { continue }
                    let stride = width + 1
                    let blocked = sums[(top + blockHeight) * stride + left + blockWidth]
                        - sums[top * stride + left + blockWidth] - sums[(top + blockHeight) * stride + left] + sums[top * stride + left]
                    if blocked != 0 { continue }
                    best = (dx, dy, distance)
                }
            }
            return best.map { CGPoint(x: CGFloat($0.dx) / sx, y: CGFloat($0.dy) / sy) }
        }
    }
}
