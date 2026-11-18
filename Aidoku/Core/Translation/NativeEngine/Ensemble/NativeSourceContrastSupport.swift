import Foundation

/// Local RGB contrast at source resolution. No detector geometry, labels or page IDs.
enum NativeSourceContrastSupport {
    /// Exact per-channel median with replicated image borders, matching the
    /// diagnostic medianBlur. Query only RF-supported, non-erased source pixels.
    static func contains(rgb: [UInt8], width: Int, height: Int, x: Int, y: Int,
                         radius: Int, minimumContrast: Int = 24) -> Bool? {
        guard width > 0, height > 0, width <= 16_777_216 / height,
              rgb.count == width * height * 3, (0..<width).contains(x), (0..<height).contains(y),
              (1...7).contains(radius), (1...255).contains(minimumContrast) else { return nil }
        let side = 2 * radius + 1, middle = side * side / 2
        let center = (y * width + x) * 3
        for channel in 0..<3 {
            var histogram = [Int](repeating: 0, count: 256)
            for dy in -radius...radius {
                let row = min(height - 1, max(0, y + dy)) * width
                for dx in -radius...radius {
                    let column = min(width - 1, max(0, x + dx))
                    histogram[Int(rgb[(row + column) * 3 + channel])] += 1
                }
            }
            var cumulative = 0
            for value in 0..<256 {
                cumulative += histogram[value]
                if cumulative > middle {
                    if abs(Int(rgb[center + channel]) - value) >= minimumContrast { return true }
                    break
                }
            }
        }
        return false
    }
}
