import CoreGraphics
import Foundation

/// Bounded light-background components used only for conservative column merging.
enum ReaderTranslationEnclosedBackground {
    struct Input { let id: String; let text: String; let rect: CGRect }
    static func enclosedRegionGroups(in image: CGImage,
                                    candidateInputs candidates: [Input],
                                    coordinateSize: CGSize) -> [[String]] {
        guard coordinateSize.width > 0, coordinateSize.height > 0,
              coordinateSize.width.isFinite, coordinateSize.height.isFinite else { return [] }
        guard !candidates.isEmpty else { return [] }
        let scale = min(1, 512 / CGFloat(max(image.width, image.height)))
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        var pixels = [UInt8](repeating: 255, count: width * height)
        let rendered = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                                          bitsPerComponent: 8, bytesPerRow: width,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { return [] }
        var groups: [Int: [String]] = [:]
        for input in candidates.prefix(64) {
            guard !Task.isCancelled else { return [] }
            let rect = CGRect(x: input.rect.minX / coordinateSize.width * CGFloat(width),
                              y: input.rect.minY / coordinateSize.height * CGFloat(height),
                              width: input.rect.width / coordinateSize.width * CGFloat(width),
                              height: input.rect.height / coordinateSize.height * CGFloat(height))
            if let component = enclosed(rect, pixels: pixels, width: width, height: height) { groups[component, default: []].append(input.id) }
        }
        return groups.keys.sorted().map { groups[$0]! }
    }

    /// A tight gap between a multi-column block and its remaining column can
    /// stay inside a balloon whose outline is open or crossed by lettering.
    /// Require an almost entirely white bridge, rather than absence of a rule.
    static func hasClearVerticalBridge(in image: CGImage, left: CGRect, right: CGRect) -> Bool {
        let top = max(left.minY, right.minY), bottom = min(left.maxY, right.maxY)
        let font = min(left.width, right.width)
        guard bottom - top > font * 2 else { return false }
        let middle = (left.maxX + right.minX) / 2
        let sample = CGRect(x: middle - max(1, font * 0.06), y: top + font * 0.2,
            width: max(2, font * 0.12), height: bottom - top - font * 0.4).integral
        guard sample.minX >= 0, sample.minY >= 0, sample.maxX <= CGFloat(image.width),
              sample.maxY <= CGFloat(image.height), let crop = image.cropping(to: sample) else { return false }
        let width = 5, height = 48
        var pixels = [UInt8](repeating: 0, count: width * height)
        let drawn = pixels.withUnsafeMutableBytes { bytes -> Bool in
            guard let context = CGContext(data: bytes.baseAddress, width: width, height: height,
                bitsPerComponent: 8, bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            context.setFillColor(gray: 1, alpha: 1)
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { return false }
        let clearRows = (0..<height).filter { row in (0..<width).allSatisfy { pixels[row * width + $0] >= 225 } }.count
        return clearRows >= 47
    }

    private static func enclosed(_ rect: CGRect, pixels: [UInt8], width: Int, height: Int) -> Int? {
        guard rect.minX.isFinite, rect.minY.isFinite, rect.maxX.isFinite, rect.maxY.isFinite,
              rect.width > 0, rect.height > 0, rect.minX >= 0, rect.minY >= 0,
              rect.maxX < CGFloat(width), rect.maxY < CGFloat(height) else { return nil }
        let x0 = Int(floor(rect.minX)) - 2, y0 = Int(floor(rect.minY)) - 2
        let x1 = Int(ceil(rect.maxX)) + 2, y1 = Int(ceil(rect.maxY)) + 2
        guard x0 > 0, y0 > 0, x1 < width - 1, y1 < height - 1,
              x1 - x0 >= 6, y1 - y0 >= 6 else { return nil }
        var perimeter: [Int] = []
        for x in x0...x1 { perimeter.append(y0 * width + x); perimeter.append(y1 * width + x) }
        for y in (y0 + 1)..<y1 { perimeter.append(y * width + x0); perimeter.append(y * width + x1) }
        // Require background all around the lettering, not a small white hole
        // inside one glyph. An open/missing balloon boundary always abstains.
        guard let seed = perimeter.first(where: { pixels[$0] >= 235 }) else { return nil }
        var seen = [Bool](repeating: false, count: pixels.count)
        var queue = [seed]
        seen[seed] = true
        var cursor = 0, minX = width, maxX = 0, minY = height, maxY = 0
        let budget = min(pixels.count / 3, max(256, (x1 - x0) * (y1 - y0) * 12))
        while cursor < queue.count {
            guard !Task.isCancelled, queue.count <= budget else { return nil }
            let point = queue[cursor]; cursor += 1
            let x = point % width, y = point / width
            guard x > 0, y > 0, x < width - 1, y < height - 1 else { return nil }
            minX = min(minX, x); maxX = max(maxX, x)
            minY = min(minY, y); maxY = max(maxY, y)
            for next in [point - 1, point + 1, point - width, point + width] where !seen[next] && pixels[next] >= 235 {
                seen[next] = true
                queue.append(next)
            }
        }
        guard perimeter.filter({ seen[$0] }).count * 5 >= perimeter.count * 4,
              minX < x0, maxX > x1, minY < y0, maxY > y1,
              maxX - minX < width * 3 / 4, maxY - minY < height * 3 / 4 else { return nil }
        return queue.min()
    }
}
