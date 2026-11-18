import CoreGraphics
import Foundation

/// Original DB foreground clearance for recognition context only. It conveys
/// neither source erasure authority nor a claim of complete recognized text.
@available(iOS 18.0, *)
enum NativeOCRDBRecognitionClearance {
    struct Evidence: Codable, Equatable, Sendable {
        let polygons: [[CGPoint]]
        let provenance: String
        let threshold: Double
        let ownedComponentPixels: Int
        let supportedCells: [Int]
        let parentBoxIndex: Int
        /// Explicit original-DB clearance limit per right-to-left column.
        /// Missing legacy values retain the original 0.24 context policy.
        var maximumPaddingFractions: [Double]? = nil
    }

    static func prove(map: NativeCoreMLDetectionMap, parent: [CGPoint],
                      columns: NativeOCRDetectorColumnEvidence, foreign: [[CGPoint]],
                      geometry: NativeCoreMLDetectionMapGeometry,
                      cancellationCheck: () throws -> Void = {}) throws -> Evidence? {
        guard columns.provenance == "db-independent-child-components", columns.threshold == 0.9,
              (2...3).contains(columns.polygons.count), columns.cellRuns.count == columns.polygons.count,
              columns.componentSeeds.count == columns.polygons.count,
              columns.componentPixels.count == columns.polygons.count,
              columns.sourceWidth > 0, columns.sourceHeight > 0,
              geometry.fullWidth <= 4_194_304 / geometry.fullHeight,
              map.width <= geometry.fullWidth - geometry.originX,
              map.height <= geometry.fullHeight - geometry.originY,
              foreign.count <= 4_096,
              columns.mapFullWidth == geometry.fullWidth, columns.mapFullHeight == geometry.fullHeight,
              columns.mapOriginX == geometry.originX, columns.mapOriginY == geometry.originY else { return nil }
        let sx = Double(columns.sourceWidth) / Double(geometry.fullWidth)
        let sy = Double(columns.sourceHeight) / Double(geometry.fullHeight)
        func bounds(_ polygon: [CGPoint]) -> CGRect? {
            guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let xs = polygon.map(\.x), ys = polygon.map(\.y)
            let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
            guard r.width > 0, r.height > 0 else { return nil }
            return r
        }
        guard let body = bounds(parent), foreign.allSatisfy({ bounds($0) != nil }) else { return nil }
        let children = columns.polygons.compactMap(bounds)
        guard children.count == columns.polygons.count,
              children.allSatisfy({ body.contains($0) }) else { return nil }
        func corridor(index: Int, fraction: Double) -> CGRect? {
            let child = children[index]
            let left = index + 1 < children.count ? (child.minX + children[index + 1].maxX) / 2 : body.minX
            let right = index > 0 ? (child.maxX + children[index - 1].minX) / 2 : body.maxX
            let pad = max(1, child.width * fraction)
            let rect = CGRect(x: max(left, child.minX - pad), y: body.minY,
                width: min(right, child.maxX + pad) - max(left, child.minX - pad), height: body.height)
            return rect.contains(child) && body.contains(rect) ? rect : nil
        }
        let localBody = CGRect(x: body.minX / sx - Double(geometry.originX),
            y: body.minY / sy - Double(geometry.originY), width: body.width / sx, height: body.height / sy)
        let scope = localBody.insetBy(dx: -16, dy: -16).integral
            .intersection(CGRect(x: 0, y: 0, width: map.width, height: map.height))
        guard !scope.isNull, !scope.isEmpty, scope.width * scope.height <= 65_536 else { return nil }
        let x0 = Int(scope.minX), y0 = Int(scope.minY), w = Int(scope.width), h = Int(scope.height)
        func contains(_ point: CGPoint, _ polygon: [CGPoint]) -> Bool {
            var inside = false, previous = polygon.count - 1
            for index in polygon.indices {
                let a = polygon[index], b = polygon[previous]
                if (a.y > point.y) != (b.y > point.y),
                   point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
                previous = index
            }
            return inside
        }
        let sourceScope = CGRect(x: (scope.minX + Double(geometry.originX)) * sx,
            y: (scope.minY + Double(geometry.originY)) * sy, width: scope.width * sx, height: scope.height * sy)
        let peers = foreign.filter { polygon in
            guard let r = bounds(polygon) else { return false }
            return r.intersects(sourceScope)
        }
        guard peers.count <= 64 else { return nil }
        var labels = [Int32](repeating: 0, count: w * h)
        struct Component { let count: Int; let edge: Bool; let externalStrong: Bool }
        var components = [Component(count: 0, edge: false, externalStrong: false)]
        var queue: [Int] = []
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        for seed in labels.indices where labels[seed] == 0 {
            if seed & 1_023 == 0 { try cancellationCheck() }
            let value = map.values[(seed / w + y0) * map.width + seed % w + x0]
            guard value.isFinite else { return nil }
            if value < 0.15 { continue }
            guard components.count <= 4_096 else { return nil }
            let label = Int32(components.count)
            queue.removeAll(keepingCapacity: true); queue.append(seed); labels[seed] = label
            var cursor = 0, edge = false, externalStrong = false
            while cursor < queue.count {
                if cursor & 1_023 == 0 { try cancellationCheck() }
                let pixel = queue[cursor], x = pixel % w, y = pixel / w; cursor += 1
                edge = edge || x == 0 || y == 0 || x == w - 1 || y == h - 1
                let v = map.values[(y + y0) * map.width + x + x0]
                let point = CGPoint(x: (Double(x + x0 + geometry.originX) + 0.5) * sx,
                    y: (Double(y + y0 + geometry.originY) + 0.5) * sy)
                externalStrong = externalStrong || v >= 0.9 &&
                    (!body.contains(point) || peers.contains(where: { contains(point, $0) }))
                for (dx, dy) in directions {
                    let xx = x + dx, yy = y + dy
                    guard xx >= 0, yy >= 0, xx < w, yy < h else { continue }
                    let next = yy * w + xx
                    if labels[next] != 0 { continue }
                    let probability = map.values[(yy + y0) * map.width + xx + x0]
                    guard probability.isFinite else { return nil }
                    if probability >= 0.15 { labels[next] = label; queue.append(next) }
                }
            }
            components.append(.init(count: queue.count, edge: edge, externalStrong: externalStrong))
        }
        var owned = Set<Int32>()
        for (i, runs) in columns.cellRuns.enumerated() {
            guard runs.count <= 4_096, let first = runs.first,
                  columns.componentPixels[i] > 0, columns.componentPixels[i] <= 65_536,
                  first.y >= 0, first.y < geometry.fullHeight, first.x >= 0, first.x < geometry.fullWidth,
                  columns.componentSeeds[i] == first.y * geometry.fullWidth + first.x else { return nil }
            var count = 0, expected: Int32?
            var previous: NativeOCRDBComponentRun?
            for run in runs {
                guard run.count > 0, run.count <= w, run.y >= y0 + geometry.originY,
                      run.y < y0 + geometry.originY + h,
                      run.x >= x0 + geometry.originX, run.x <= x0 + geometry.originX + w - run.count else { return nil }
                if let previous {
                    guard run.y > previous.y || run.y == previous.y && run.x >= previous.x + previous.count else { return nil }
                }
                guard count <= columns.componentPixels[i] - run.count else { return nil }
                previous = run
                for offset in 0..<run.count {
                    let x = run.x + offset - geometry.originX, y = run.y - geometry.originY
                    let probability = map.values[y * map.width + x]
                    let label = labels[(y - y0) * w + x - x0]
                    guard probability.isFinite, probability >= 0.9, label > 0 else { return nil }
                    if let expected, expected != label { return nil }
                    expected = label; count += 1
                }
            }
            guard count == columns.componentPixels[i], let label = expected,
                  !components[Int(label)].edge, !components[Int(label)].externalStrong else { return nil }
            owned.insert(label)
        }
        func supportedCount(_ corridor: CGRect) throws -> Int? {
            let mapped = CGRect(x: corridor.minX / sx - Double(geometry.originX),
                y: corridor.minY / sy - Double(geometry.originY), width: corridor.width / sx, height: corridor.height / sy).integral
            guard scope.contains(mapped) else { return nil }
            var count = 0
            // Cover entire intersecting DB cells, including the fractional crop edge.
            for y in Int(mapped.minY)..<Int(mapped.maxY) {
                if y & 31 == 0 { try cancellationCheck() }
                for x in Int(mapped.minX)..<Int(mapped.maxX) {
                    let value = map.values[y * map.width + x]
                    guard value.isFinite else { return nil }
                    if value >= 0.15 {
                        guard owned.contains(labels[(y - y0) * w + x - x0]) else { return nil }
                        count += 1
                    }
                }
            }
            return count >= 24 ? count : nil
        }
        var corridors: [CGRect] = [], supported: [Int] = [], maximumFractions: [Double] = []
        for index in children.indices {
            // Wider recognition context is optional and independently cleared
            // for each column. A foreign/unknown component in the wider corridor
            // never authorizes its removal: retry the unchanged narrow policy.
            var selected = false
            for fraction in [0.6, 0.24] {
                guard let candidate = corridor(index: index, fraction: fraction),
                      let count = try supportedCount(candidate) else { continue }
                corridors.append(candidate); supported.append(count); maximumFractions.append(fraction)
                selected = true
                break
            }
            guard selected else { return nil }
        }
        return .init(polygons: corridors.map { r in
            [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
             CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
        }, provenance: "original-db-closed-component-recognition-clearance-v1", threshold: 0.15,
            ownedComponentPixels: owned.reduce(0) { $0 + components[Int($1)].count },
            supportedCells: supported, parentBoxIndex: columns.parentBoxIndex, maximumPaddingFractions: maximumFractions)
    }
}
