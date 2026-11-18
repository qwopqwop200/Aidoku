import CoreGraphics
import Foundation

/// Source-owner color modes only; not an erasure mask or a contrast replacement palette.
enum NativeOriginalInkPrediction {
    static func foreground(owner: CGRect, frame: CGRect, source: CGImage,
                           reader: NativeSourcePixelReader, sourceBackground: [Double],
                           remainingPixels: inout Int) throws -> [Double]? {
        guard let projection = NativeTextBoxSourceProjection.project(owner, frame: frame,
            sourceSize: CGSize(width: source.width, height: source.height)),
            sourceBackground.count == 3, sourceBackground.allSatisfy({ $0.isFinite && (0...255).contains($0) }) else { return nil }
        let left = max(0, Int(floor(projection.minX))), top = max(0, Int(floor(projection.minY)))
        let right = min(source.width, Int(ceil(projection.maxX))), bottom = min(source.height, Int(ceil(projection.maxY)))
        let width = right - left, height = bottom - top
        guard width > 0, height > 0, width <= 4_194_304 / height else { return nil }
        if remainingPixels != .max { remainingPixels = max(0, remainingPixels - width * height) }
        let rgba = try reader.read(x: Double(left), y: Double(top), sourceWidth: Double(width),
            sourceHeight: Double(height), width: width, height: height)
        var modes: [UInt32: Int] = [:]
        for y in 0..<height {
            try Task.checkCancellation()
            for x in 0..<width {
                let offset = (y * width + x) * 4
                guard rgba[offset + 3] >= 250 else { continue }
                let rgb = [Double(rgba[offset]), Double(rgba[offset + 1]), Double(rgba[offset + 2])]
                // Separate the independently observed source surface component.
                // Selected endpoints are actual original RGBs, never boosted to black/white.
                guard zip(rgb, sourceBackground).map({ abs($0 - $1) }).max()! > 12 else { continue }
                let key = UInt32(rgba[offset]) << 16 | UInt32(rgba[offset + 1]) << 8 | UInt32(rgba[offset + 2])
                modes[key, default: 0] += 1
            }
        }
        guard let best = modes.max(by: { a, b in a.value == b.value ? a.key > b.key : a.value < b.value }),
              best.value >= 6 else { return nil }
        return [Double((best.key >> 16) & 255), Double((best.key >> 8) & 255), Double(best.key & 255)]
    }
}
