import CoreGraphics
import Foundation

/// One original ROI traversal, not a query/result cache. No color-role decisions.
final class NativeSourceROIFeatures {
    struct Entry {
        let key: Int
        let count: Int
        let inside: Int
        let outside: Int
        let sum: [Double]
    }
    private let sourceRGBA: [UInt8]
    let width: Int
    let height: Int
    let box: CGRect
    let four: [Entry]
    let three: [Entry]
    let insideCount: Int
    let outsideCount: Int

    /// Retaining the Array forces a mutating caller to COW; equality is exact storage identity.
    func matches(rgba: [UInt8], width: Int, height: Int, box: CGRect) -> Bool {
        guard self.width == width, self.height == height, sourceRGBA.count == rgba.count,
              Double(self.box.origin.x).bitPattern == Double(box.origin.x).bitPattern,
              Double(self.box.origin.y).bitPattern == Double(box.origin.y).bitPattern,
              Double(self.box.width).bitPattern == Double(box.width).bitPattern,
              Double(self.box.height).bitPattern == Double(box.height).bitPattern else { return false }
        return sourceRGBA.withUnsafeBufferPointer { retained in
            rgba.withUnsafeBufferPointer { supplied in
                retained.baseAddress == supplied.baseAddress
            }
        }
    }

    init?(rgba: [UInt8], width: Int, height: Int, box: [Double]) {
        guard width > 0, height > 0, width <= 24_576 / height,
              rgba.count == width * height * 4, box.count == 4,
              box.allSatisfy(\.isFinite), box[2] > 0, box[3] > 0 else { return nil }
        self.sourceRGBA = rgba
        self.width = width; self.height = height
        let rect = CGRect(x: box[0], y: box[1], width: box[2], height: box[3])
        guard [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return nil }
        self.box = rect
        var c4 = [Int](repeating: 0, count: 4096), r4 = c4, g4 = c4, b4 = c4
        var c3 = [Int](repeating: 0, count: 512), r3 = c3, g3 = c3, b3 = c3, i3 = c3
        var order4: [Int] = [], order3: [Int] = [], inside = 0, outside = 0
        for y in 0..<height {
            let inY = Double(y) >= rect.minY && Double(y) < rect.maxY
            for x in 0..<width {
                let p = (y * width + x) * 4
                let red = Int(rgba[p]), green = Int(rgba[p + 1]), blue = Int(rgba[p + 2])
                let local = inY && Double(x) >= rect.minX && Double(x) < rect.maxX
                if local {
                    let key = (red >> 4) * 256 + (green >> 4) * 16 + (blue >> 4)
                    if c4[key] == 0 { order4.append(key) }
                    c4[key] += 1; r4[key] += red; g4[key] += green; b4[key] += blue
                }
                if rgba[p + 3] >= 128 {
                    let key = (red >> 5) * 64 + (green >> 5) * 8 + (blue >> 5)
                    if c3[key] == 0 { order3.append(key) }
                    c3[key] += 1; r3[key] += red; g3[key] += green; b3[key] += blue
                    if local { i3[key] += 1; inside += 1 } else { outside += 1 }
                }
            }
        }
        four = order4.map { Entry(key: $0, count: c4[$0], inside: c4[$0], outside: 0,
            sum: [Double(r4[$0]), Double(g4[$0]), Double(b4[$0])]) }
        three = order3.map { Entry(key: $0, count: c3[$0], inside: i3[$0], outside: c3[$0] - i3[$0],
            sum: [Double(r3[$0]), Double(g3[$0]), Double(b3[$0])]) }
        insideCount = inside; outsideCount = outside
    }
}
