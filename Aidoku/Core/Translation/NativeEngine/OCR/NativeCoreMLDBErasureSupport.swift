import CoreGraphics
import Foundation

@available(iOS 18.0, *)
extension NativeCoreMLDBPostprocessor {
    /// Read weak detector probability only as erasure evidence. Recognition
    /// quadrilaterals, scores, candidate admission and reading order stay exact.
    /// A bounded, one-step near-component join recovers detached punctuation
    /// without allowing a chain of unrelated weak components across the page.
    static func addingErasureSupport(
        map: NativeCoreMLDetectionMap, boxes: [NativeCoreMLDetectionBox], sourceWidth: Int, sourceHeight: Int,
        geometry: NativeCoreMLDetectionMapGeometry? = nil, cancellationCheck: () throws -> Void = {}
    ) throws -> [NativeCoreMLDetectionBox] {
        func check() throws { try Task.checkCancellation(); try cancellationCheck() }
        try check()
        guard sourceWidth > 0, sourceHeight > 0, !boxes.isEmpty, boxes.count <= 4_096 else { return boxes }
        let geometry = geometry ?? .init(originX: 0, originY: 0, fullWidth: map.width, fullHeight: map.height)
        guard geometry.originX + map.width <= geometry.fullWidth, geometry.originY + map.height <= geometry.fullHeight else { return boxes }
        let scaleX = Double(sourceWidth) / Double(geometry.fullWidth)
        let scaleY = Double(sourceHeight) / Double(geometry.fullHeight)
        let localPolygons = boxes.map { box in box.polygon.map {
            CGPoint(x: Double($0.x) / scaleX - Double(geometry.originX), y: Double($0.y) / scaleY - Double(geometry.originY))
        } }
        let localBounds = localPolygons.map { polygon -> CGRect in
            guard polygon.count >= 3, polygon.count <= 32, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return .null }
            let xs = polygon.map(\.x), ys = polygon.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let page = CGRect(x: 0, y: 0, width: map.width, height: map.height)
        var pageBudget = 2_000_000
        var supported = boxes
        for index in boxes.indices.prefix(4_096) {
            try check()
            let body = localBounds[index]
            guard !body.isNull, body.width > 0, body.height > 0 else { continue }
            let margin = min(24, max(4, ceil(min(body.width, body.height) * 0.5)))
            let scope = body.insetBy(dx: -margin, dy: -margin).integral.intersection(page)
            guard !scope.isNull, !scope.isEmpty, scope.width * scope.height <= 65_536,
                  scope.width * scope.height <= CGFloat(pageBudget) else { continue }
            let x0 = Int(scope.minX), y0 = Int(scope.minY), width = Int(scope.width), height = Int(scope.height)
            pageBudget -= width * height
            let neighbors = localBounds.indices.filter { $0 != index && localBounds[$0].intersects(scope) }
            var state = [UInt8](repeating: 0, count: width * height)
            for y in 0..<height {
                if y & 31 == 0 { try check() }
                for x in 0..<width {
                    let value = map.values[(y + y0) * map.width + x + x0]
                    guard value.isFinite, value >= 0.15 else { continue }
                    let point = CGPoint(x: CGFloat(x + x0) + 0.5, y: CGFloat(y + y0) + 0.5)
                    let own = Self.erasureContains(point, polygon: localPolygons[index])
                    if !own && neighbors.contains(where: { localBounds[$0].contains(point) && Self.erasureContains(point, polygon: localPolygons[$0]) }) { continue }
                    state[y * width + x] = 1
                }
            }
            struct Component {
                let points: [Int]
                let bounds: CGRect
                let rooted: Bool
            }
            var components: [Component] = []
            for seed in state.indices where state[seed] == 1 {
                if seed & 1_023 == 0 { try check() }
                var queue = [seed], cursor = 0, left = width, top = height, right = -1, bottom = -1, rooted = false
                state[seed] = 2
                while cursor < queue.count {
                    if cursor & 1_023 == 0 { try check() }
                    let pixel = queue[cursor]; cursor += 1
                    let x = pixel % width, y = pixel / width
                    left = min(left, x); top = min(top, y); right = max(right, x); bottom = max(bottom, y)
                    if Self.erasureContains(CGPoint(x: CGFloat(x + x0) + 0.5, y: CGFloat(y + y0) + 0.5), polygon: localPolygons[index]) { rooted = true }
                    for yy in max(0, y - 1)...min(height - 1, y + 1) { for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        let next = yy * width + xx
                        if state[next] == 1 { state[next] = 2; queue.append(next) }
                    } }
                }
                guard queue.count >= 2 else { continue }
                components.append(.init(points: queue, bounds: CGRect(x: left, y: top, width: right - left + 1, height: bottom - top + 1), rooted: rooted))
            }
            let rooted = components.filter(\.rooted)
            guard !rooted.isEmpty else { continue }
            let radius = min(4, max(2, Int(ceil(min(body.width, body.height) * 0.12))))
            var proximity = [UInt8](repeating: 0, count: width * height)
            for component in rooted { for (offset, pixel) in component.points.enumerated() {
                if offset & 1_023 == 0 { try check() }
                let x = pixel % width, y = pixel / width
                for yy in max(0, y - radius)...min(height - 1, y + radius) { for xx in max(0, x - radius)...min(width - 1, x + radius) {
                    proximity[yy * width + xx] = 1
                } }
            } }
            let admitted = components.filter { component in
                component.rooted || (component.points.count <= 4_096 && component.points.contains { proximity[$0] != 0 })
            }
            var evidence = boxes[index].erasurePolygons
            for component in admitted.prefix(64) {
                try check()
                let crop = component.bounds.offsetBy(dx: CGFloat(x0), dy: CGFloat(y0))
                let source = CGRect(x: (Double(crop.minX) + Double(geometry.originX)) * scaleX,
                    y: (Double(crop.minY) + Double(geometry.originY)) * scaleY,
                    width: Double(crop.width) * scaleX, height: Double(crop.height) * scaleY)
                let polygon = [CGPoint(x: source.minX, y: source.minY), CGPoint(x: source.maxX, y: source.minY),
                               CGPoint(x: source.maxX, y: source.maxY), CGPoint(x: source.minX, y: source.maxY)]
                if !evidence.contains(polygon) { evidence.append(polygon) }
            }
            supported[index] = .init(polygon: boxes[index].polygon, score: boxes[index].score, erasurePolygons: Array(evidence.prefix(64)))
        }
        try check()
        return supported
    }

    private static func erasureContains(_ point: CGPoint, polygon: [CGPoint]) -> Bool {
        guard polygon.count >= 3 else { return false }
        var inside = false, previous = polygon.count - 1
        for index in polygon.indices {
            let a = polygon[index], b = polygon[previous]
            if (a.y > point.y) != (b.y > point.y), point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            previous = index
        }
        return inside
    }
}
