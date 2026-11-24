import CoreGraphics
import Foundation

/// The restored (text-free) pixels of one page region S7 changed, copied before S10 paints over them.
/// With the placed text they rebuild the page over its source (`ReaderTranslationPagePatches`).
struct PipelineBackgroundPatch: Sendable {
    /// Page pixels, top-left origin.
    var rect: CGRect
    /// Canonical page bytes (`PipelinePageRaster` layout) of `rect`.
    var rgba: [UInt8]

    /// Region grid cell: one JPEG MCU, so a stored patch edge never splits a block.
    private static let tile = 16
    /// Inclusive tile range.
    private struct Box { var x0: Int, y0: Int, x1: Int, y1: Int }

    /// Bounding boxes of the 8-connected groups of tiles holding a removed pixel (S7 writes only those),
    /// merged while they overlap.
    static func regions(removal: [UInt8], width: Int, height: Int) -> [CGRect] {
        guard width > 0, height > 0, removal.count == width * height else { return [] }
        let columns = (width + tile - 1) / tile, rows = (height + tile - 1) / tile
        var marked = [Bool](repeating: false, count: columns * rows)
        let zeros = [UInt8](repeating: 0, count: width)
        removal.withUnsafeBytes { mask in
            guard let base = mask.baseAddress else { return }
            for y in 0..<height where memcmp(base + y * width, zeros, width) != 0 {
                let row = (y / tile) * columns
                for column in 0..<columns where !marked[row + column] {
                    let x = column * tile
                    marked[row + column] = memcmp(base + y * width + x, zeros, min(tile, width - x)) != 0
                }
            }
        }
        var boxes: [Box] = []
        var stack: [Int] = []
        for start in marked.indices where marked[start] {
            var box = Box(x0: start % columns, y0: start / columns, x1: start % columns, y1: start / columns)
            marked[start] = false
            stack.append(start)
            while let index = stack.popLast() {
                let x = index % columns, y = index / columns
                box = Box(x0: min(box.x0, x), y0: min(box.y0, y), x1: max(box.x1, x), y1: max(box.y1, y))
                for ny in max(0, y - 1)...min(rows - 1, y + 1) {
                    for nx in max(0, x - 1)...min(columns - 1, x + 1) where marked[ny * columns + nx] {
                        marked[ny * columns + nx] = false
                        stack.append(ny * columns + nx)
                    }
                }
            }
            boxes.append(box)
        }
        var merged = true
        while merged {
            merged = false
            outer: for first in boxes.indices {
                for second in boxes.indices where second > first {
                    let a = boxes[first], b = boxes[second]
                    guard a.x0 <= b.x1, b.x0 <= a.x1, a.y0 <= b.y1, b.y0 <= a.y1 else { continue }
                    boxes[first] = Box(x0: min(a.x0, b.x0), y0: min(a.y0, b.y0), x1: max(a.x1, b.x1), y1: max(a.y1, b.y1))
                    boxes.remove(at: second)
                    merged = true
                    break outer
                }
            }
        }
        return boxes.map { box in
            let x = box.x0 * tile, y = box.y0 * tile
            return CGRect(x: x, y: y, width: min(width, (box.x1 + 1) * tile) - x, height: min(height, (box.y1 + 1) * tile) - y)
        }
    }

    /// Copies `regions` out of canonical page bytes.
    static func capture(_ regions: [CGRect], from pixels: [UInt8], width: Int) -> [PipelineBackgroundPatch] {
        regions.map { rect in
            let x = Int(rect.minX), y = Int(rect.minY), w = Int(rect.width), h = Int(rect.height)
            var rgba = [UInt8](repeating: 0, count: w * h * 4)
            pixels.withUnsafeBytes { page in
                rgba.withUnsafeMutableBytes { patch in
                    for row in 0..<h {
                        (patch.baseAddress! + row * w * 4).copyMemory(from: page.baseAddress! + ((y + row) * width + x) * 4, byteCount: w * 4)
                    }
                }
            }
            return PipelineBackgroundPatch(rect: rect, rgba: rgba)
        }
    }
}
