import CoreGraphics
import Foundation

/// The three separate late phases following joined-unit layout: a plate-free
/// readable floor, observed balloon clipping and text-only body centering.
enum NativeLateBalloonStages {
    struct Measurement {
        var ink: CGRect
        var scrollWidth: Double
        var clientWidth: Double
        var scrollHeight: Double
        var clientHeight: Double
    }
    struct FloorResult { var font: Double; var pitch: Double; var measured: Measurement }
    static func readableFloor(font: Double, pitch: Double, before: CGRect, frame: CGRect, neighbors: [CGRect],
        measure: (Double, Double) -> Measurement) -> FloorResult? {
        guard font >= 7.75, font < 8.5, valid(before), valid(frame) else { return nil }
        let ratio = pitch / font == 0 || !(pitch / font).isFinite ? 1.2 : pitch / font
        let oldPitch = pitch == 0 ? 1 : pitch
        let count = max(1, floor(Double(before.height) / oldPitch + 0.5)), target = 8.5, newPitch = target * ratio
        let after = measure(target, newPitch), ink = after.ink, gap = target * 0.35
        guard valid(ink), after.scrollWidth <= after.clientWidth + 1, after.scrollHeight <= after.clientHeight + 1,
              max(1, floor(Double(ink.height) / (newPitch == 0 ? 1 : newPitch) + 0.5)) == count,
              !neighbors.contains(where: { valid($0) && intersects(ink.insetBy(dx: -gap, dy: -gap), $0) }),
              ink.minX >= frame.minX, ink.maxX <= frame.maxX, ink.minY >= frame.minY, ink.maxY <= frame.maxY else { return nil }
        return .init(font: target, pitch: newPitch, measured: after)
    }

    static func centeredShift(ink: CGRect, center: CGPoint, font: Double, parent: CGRect?, neighbors: [CGRect],
        outside: (CGRect) -> Bool, measureShift: (CGPoint) -> CGRect) -> CGPoint? {
        guard valid(ink), center.x.isFinite, center.y.isFinite, font.isFinite else { return nil }
        let shift = CGPoint(x: center.x - ink.midX, y: center.y - ink.midY), pad = max(1.5, font * 0.12)
        let moved = ink.offsetBy(dx: shift.x, dy: shift.y), padded = moved.insetBy(dx: -pad, dy: -pad)
        guard !outside(padded), !neighbors.contains(where: { valid($0) && intersects(padded, $0) }) else { return nil }
        if let parent, padded.minX < parent.minX || padded.maxX > parent.maxX || padded.minY < parent.minY || padded.maxY > parent.maxY { return nil }
        let measured = measureShift(shift)
        guard abs(measured.minX - ink.minX - shift.x) <= 0.1, abs(measured.minY - ink.minY - shift.y) <= 0.1 else { return nil }
        return shift
    }

    struct ClipResult { let coverage: [CGRect]; let removedPixels: Int }
    static func clip(panel: CGRect, coverage: [CGRect], required: [CGRect], interior: CGRect,
        scale: Double, width: Int, height: Int, fill: [UInt8]) -> ClipResult? {
        guard valid(panel), panel.width >= 4, panel.height >= 4, valid(interior), scale.isFinite, scale > 0,
              width > 0, height > 0, width <= 3_000_000 / height, fill.count == width * height,
              !coverage.isEmpty, coverage.allSatisfy(valid) else { return nil }
        let colsValue = max(1, ceil(Double(panel.width) * scale)), rowsValue = max(1, ceil(Double(panel.height) * scale))
        guard colsValue * rowsValue <= 3_000_000 else { return nil }
        let cols = Int(colsValue), rows = Int(rowsValue)
        var kept = [UInt8](repeating: 0, count: cols * rows), before = 0, after = 0
        for j in 0..<rows { for i in 0..<cols {
            let cx = panel.minX + (Double(i) + 0.5) / scale, cy = panel.minY + (Double(j) + 0.5) / scale
            guard coverage.contains(where: { contains($0, x: cx, y: cy) }) else { continue }
            before += 1
            let sx = floor((cx - interior.minX) * scale), sy = floor((cy - interior.minY) * scale)
            let inside = sx >= 0 && sy >= 0 && sx < Double(width) && sy < Double(height) && fill[Int(sy) * width + Int(sx)] == 1
            if inside || required.contains(where: { contains($0, x: cx, y: cy) }) { kept[j * cols + i] = 1; after += 1 }
        } }
        guard before > 0, Double(after) < Double(before) * 0.97 else { return nil }
        struct Run { var left: Int; var right: Int; var top: Int; var end: Int }
        var runs: [Run] = [], previous: [Int] = []
        for j in 0..<rows {
            var current: [Int] = [], i = 0
            while i < cols {
                if kept[j * cols + i] == 0 { i += 1; continue }
                let a = i
                while i + 1 < cols && kept[j * cols + i + 1] != 0 { i += 1 }
                let b = i + 1
                if let match = previous.first(where: { runs[$0].left == a && runs[$0].right == b && runs[$0].end == j }) {
                    runs[match].end = j + 1; current.append(match)
                } else {
                    current.append(runs.count); runs.append(.init(left: a, right: b, top: j, end: j + 1))
                }
                i += 1
            }
            previous = current
        }
        guard !runs.isEmpty, runs.count <= 256 else { return nil }
        // aidokuSolidPanelCoverage deliberately returns a solid bounding plate.
        let boxes = runs.map { r in CGRect(x: panel.minX + Double(r.left) / scale, y: panel.minY + Double(r.top) / scale,
            width: Double(r.right - r.left) / scale, height: Double(r.end - r.top) / scale) }
        let solid = boxes.reduce(CGRect.null) { $0.union($1) }
        return .init(coverage: [solid], removedPixels: before - after)
    }

    private static func valid(_ r: CGRect) -> Bool { [r.origin.x,r.origin.y,r.size.width,r.size.height].allSatisfy(\.isFinite) && r.size.width > 0 && r.size.height > 0 }
    private static func intersects(_ a: CGRect, _ b: CGRect) -> Bool { a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY }
    private static func contains(_ r: CGRect, x: Double, y: Double) -> Bool { x >= r.minX && x <= r.maxX && y >= r.minY && y <= r.maxY }
}
