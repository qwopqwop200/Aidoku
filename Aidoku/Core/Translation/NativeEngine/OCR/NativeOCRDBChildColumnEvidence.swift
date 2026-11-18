import CoreGraphics
import Foundation

/// Recognition proposals measured from original high-confidence DB components.
/// These are independent of the lower-threshold erasure ownership polygons.
@available(iOS 18.0, *)
struct NativeOCRDBComponentRun: Codable, Equatable, Sendable {
    let y: Int
    let x: Int
    let count: Int
}

@available(iOS 18.0, *)
struct NativeOCRDetectorColumnEvidence: Codable, Equatable, Sendable {
    let polygons: [[CGPoint]]
    let provenance: String
    let threshold: Double
    let componentPixels: [Int]
    let meanProbabilities: [Double]
    let cellRuns: [[NativeOCRDBComponentRun]]
    let componentSeeds: [Int]
    let parentBoxIndex: Int
    let mapOriginX: Int
    let mapOriginY: Int
    let mapFullWidth: Int
    let mapFullHeight: Int
    let sourceWidth: Int
    let sourceHeight: Int
    var recognitionClearance: NativeOCRDBRecognitionClearance.Evidence? = nil
}

@available(iOS 18.0, *)
enum NativeOCRDBChildColumnEvidence {
    static func extract(map: NativeCoreMLDetectionMap, boxes: [NativeCoreMLDetectionBox],
                        sourceWidth: Int, sourceHeight: Int, geometry: NativeCoreMLDetectionMapGeometry,
                        cancellationCheck: () throws -> Void = {}) throws -> [NativeOCRDetectorColumnEvidence?] {
        var result = [NativeOCRDetectorColumnEvidence?](repeating: nil, count: boxes.count)
        guard sourceWidth > 0, sourceHeight > 0, boxes.count <= 4_096,
              geometry.fullWidth <= 4_194_304 / geometry.fullHeight,
              map.width <= geometry.fullWidth - geometry.originX,
              map.height <= geometry.fullHeight - geometry.originY else { return result }
        let sx = Double(sourceWidth) / Double(geometry.fullWidth)
        let sy = Double(sourceHeight) / Double(geometry.fullHeight)
        func local(_ polygon: [CGPoint]) -> [CGPoint] {
            polygon.map { CGPoint(x: Double($0.x) / sx - Double(geometry.originX),
                                  y: Double($0.y) / sy - Double(geometry.originY)) }
        }
        func bounds(_ polygon: [CGPoint]) -> CGRect {
            guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return .null }
            let xs = polygon.map(\.x), ys = polygon.map(\.y)
            return CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        }
        let polygons = boxes.map { local($0.polygon) }, bodies = polygons.map(bounds)
        let directions = [(1, 0), (-1, 0), (0, 1), (0, -1)]
        var budget = 262_144, admitted = 0
        for owner in boxes.indices {
            try cancellationCheck()
            if admitted == 2 { break }
            let body = bodies[owner]
            guard !body.isNull, body.width >= 12, body.height >= body.width * 1.5,
                  body.height <= body.width * 8, body.width <= 256 else { continue }
            // Upright original detection is mandatory; a bounding-box union is not evidence.
            guard polygons[owner].allSatisfy({ point in
                (abs(point.x - body.minX) <= 1 || abs(point.x - body.maxX) <= 1) &&
                (abs(point.y - body.minY) <= 1 || abs(point.y - body.maxY) <= 1)
            }) else { continue }
            let scope = body.integral.intersection(CGRect(x: 0, y: 0, width: map.width, height: map.height))
            guard !scope.isNull, scope == body.integral, scope.width * scope.height <= 65_536,
                  scope.width * scope.height <= CGFloat(budget) else { continue }
            let x0 = Int(scope.minX), y0 = Int(scope.minY), w = Int(scope.width), h = Int(scope.height)
            budget -= w * h
            var state = [UInt8](repeating: 0, count: w * h)
            for y in 0..<h {
                if y & 31 == 0 { try cancellationCheck() }
                for x in 0..<w {
                    let value = map.values[(y + y0) * map.width + x + x0]
                    if value.isFinite && value >= 0.9 { state[y * w + x] = 1 }
                }
            }
            struct Column {
                let rect: CGRect; let pixels: Int; let mean: Double
                let runs: [NativeOCRDBComponentRun]; let seed: Int
            }
            var columns: [Column] = []
            let neighbors = boxes.indices.filter { $0 != owner && bodies[$0].intersects(scope) }
            guard neighbors.count <= 64 else { continue }
            for seed in state.indices where state[seed] == 1 {
                var queue = [seed], cursor = 0, left = w, top = h, right = 0, bottom = 0
                var sum = 0.0, foreign = false, edge = false
                state[seed] = 2
                while cursor < queue.count {
                    if cursor & 1_023 == 0 { try cancellationCheck() }
                    let i = queue[cursor], x = i % w, y = i / w; cursor += 1
                    left = min(left, x); right = max(right, x); top = min(top, y); bottom = max(bottom, y)
                    sum += Double(map.values[(y + y0) * map.width + x + x0])
                    edge = edge || x == 0 || y == 0 || x == w - 1 || y == h - 1
                    let point = CGPoint(x: Double(x + x0) + 0.5, y: Double(y + y0) + 0.5)
                    foreign = foreign || neighbors.contains { bodies[$0].contains(point) }
                    for (dx, dy) in directions {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0, yy >= 0, xx < w, yy < h, state[yy * w + xx] == 1 {
                            state[yy * w + xx] = 2; queue.append(yy * w + xx)
                        }
                    }
                }
                let rect = CGRect(x: left + x0, y: top + y0, width: right - left + 1, height: bottom - top + 1)
                let density = Double(queue.count) / Double(rect.width * rect.height)
                guard !foreign, !edge, queue.count >= 24, rect.width >= 3,
                      rect.width <= body.width * 0.35, rect.height >= max(rect.width * 3, body.height * 0.3),
                      density >= 0.18, density <= 0.9 else { continue }
                queue.sort()
                var runs: [NativeOCRDBComponentRun] = []
                for pixel in queue {
                    let y = pixel / w + y0 + geometry.originY
                    let x = pixel % w + x0 + geometry.originX
                    if let last = runs.last, last.y == y, last.x + last.count == x {
                        runs[runs.count - 1] = .init(y: y, x: last.x, count: last.count + 1)
                    } else { runs.append(.init(y: y, x: x, count: 1)) }
                    if runs.count > 4_096 { break }
                }
                guard runs.count <= 4_096 else { continue }
                let seed = (queue[0] / w + y0 + geometry.originY) * geometry.fullWidth +
                    queue[0] % w + x0 + geometry.originX
                columns.append(.init(rect: rect, pixels: queue.count, mean: sum / Double(queue.count), runs: runs, seed: seed))
            }
            columns.sort { $0.rect.minX > $1.rect.minX }
            guard (2...3).contains(columns.count), let narrow = columns.map({ $0.rect.width }).min(),
                  columns.allSatisfy({ $0.rect.width <= narrow * 3 }),
                  zip(columns, columns.dropFirst()).allSatisfy({ a, b in
                      let gap = a.rect.minX - b.rect.maxX
                      let overlap = min(a.rect.maxY, b.rect.maxY) - max(a.rect.minY, b.rect.minY)
                      return gap >= max(2, narrow * 0.2) && gap <= narrow * 2 &&
                          overlap >= min(a.rect.height, b.rect.height) * 0.4
                  }) else { continue }
            guard columns.reduce(0, { $0 + $1.runs.count }) <= 4_096 else { continue }
            let childPolygons = columns.map { column -> [CGPoint] in
                let r = column.rect
                return [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
                        CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)].map {
                    CGPoint(x: (Double($0.x) + Double(geometry.originX)) * sx,
                            y: (Double($0.y) + Double(geometry.originY)) * sy)
                }
            }
            var evidence = NativeOCRDetectorColumnEvidence(polygons: childPolygons,
                provenance: "db-independent-child-components",
                threshold: 0.9, componentPixels: columns.map(\.pixels), meanProbabilities: columns.map(\.mean),
                cellRuns: columns.map(\.runs), componentSeeds: columns.map(\.seed), parentBoxIndex: owner,
                mapOriginX: geometry.originX, mapOriginY: geometry.originY,
                mapFullWidth: geometry.fullWidth, mapFullHeight: geometry.fullHeight,
                sourceWidth: sourceWidth, sourceHeight: sourceHeight)
            evidence.recognitionClearance = try NativeOCRDBRecognitionClearance.prove(map: map,
                parent: boxes[owner].polygon, columns: evidence,
                foreign: boxes.indices.filter { $0 != owner }.map { boxes[$0].polygon }, geometry: geometry,
                cancellationCheck: cancellationCheck)
            result[owner] = evidence
            admitted += 1
        }
        return result
    }
}
