import CoreGraphics
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLDetectionMap: Equatable, Sendable {
    let width: Int
    let height: Int
    let values: [Float]
}

@available(iOS 18.0, *)
struct NativeCoreMLDBPostprocessConfiguration: Equatable, Sendable {
    // Manga profile: user-selected binarization 0.85; upstream box score and unclip.
    static let manga = NativeCoreMLDBPostprocessConfiguration(
        threshold: 0.85, boxThreshold: 0.25, unclipRatio: 1.4, maximumCandidates: 3_000
    )
    let threshold: Double
    let boxThreshold: Double
    let unclipRatio: Double
    let maximumCandidates: Int
}

/// DBNet postprocessing for PP-OCR detector output: 8-connected components,
/// convex hulls, minimum-area rectangles, the fast polygon score and DB unclip.
@available(iOS 18.0, *)
enum NativeCoreMLDBPostprocessor {
    private static let minimumBoxSide = 3.0

    /// 1 for finite values above `threshold`; the cutoff is the largest Float not above it,
    /// so `value > cutoff` is exactly `Double(value) > threshold`.
    private static func foregroundState(values: [Float], threshold: Double) -> [UInt8] {
        let rounded = Float(threshold)
        let cutoff = Double(rounded) > threshold ? rounded.nextDown : rounded
        let count = values.count
        return [UInt8](unsafeUninitializedCapacity: count) { state, initializedCount in
            values.withUnsafeBufferPointer { source in
                for index in 0..<count {
                    let value = source[index]
                    state[index] = value > cutoff && value < .infinity ? 1 : 0
                }
            }
            initializedCount = count
        }
    }

    private struct ForegroundSpan {
        let y: Int
        let left: Int
        let right: Int

        var pixelCount: Int { right - left + 1 }
    }

    static func decode(
        map: NativeCoreMLDetectionMap, sourceWidth: Int, sourceHeight: Int,
        configuration: NativeCoreMLDBPostprocessConfiguration, cancellationCheck: () throws -> Void = {}
    ) throws -> [NativeCoreMLDetectionBox] {
        guard sourceWidth > 0, sourceHeight > 0 else { return [] }
        // 0 = background, 1 = unvisited foreground, 2 = visited foreground.
        var state = foregroundState(values: map.values, threshold: configuration.threshold)

        // Queue horizontal runs; scanning adjacent rows one pixel past each end keeps 8-connectivity.
        var queue: [ForegroundSpan] = []
        queue.reserveCapacity(256)
        // The convex hull of raster pixels only needs each row's extreme pixels.
        var rowMinimumX = [Int](repeating: map.width, count: map.height)
        var rowMaximumX = [Int](repeating: -1, count: map.height)
        var touchedRows: [Int] = []
        touchedRows.reserveCapacity(min(map.height, 256))
        var hullCandidates: [CGPoint] = []
        hullCandidates.reserveCapacity(min(map.height * 2, 512))
        var boxes: [NativeCoreMLDetectionBox] = []
        var candidateComponents = 0
        scan: for y in 0..<map.height {
            if y & 31 == 0 { try cancellationCheck() }
            let row = y * map.width
            var nextSeedX = 0
            while nextSeedX < map.width {
                let start = row + nextSeedX
                let offset = state.withUnsafeBufferPointer { buffer -> Int? in
                    let base = UnsafeRawPointer(buffer.baseAddress!)
                    guard let next = memchr(base + start, 1, map.width - nextSeedX) else { return nil }
                    return base.distance(to: UnsafeRawPointer(next))
                }
                guard let offset else { break }
                let x = offset - row
                nextSeedX = x + 1
                if candidateComponents >= configuration.maximumCandidates { break scan }
                candidateComponents += 1
                queue.removeAll(keepingCapacity: true)
                touchedRows.removeAll(keepingCapacity: true)
                let firstSpan = consumeForegroundSpan(
                    startingAtX: x, y: y, width: map.width, state: &state,
                    rowMinimumX: &rowMinimumX, rowMaximumX: &rowMaximumX, touchedRows: &touchedRows
                )
                queue.append(firstSpan)
                var cursor = 0
                var componentPixelCount = firstSpan.pixelCount
                while cursor < queue.count {
                    if cursor & 1_023 == 0 { try cancellationCheck() }
                    let span = queue[cursor]
                    cursor += 1
                    for nextY in stride(from: span.y - 1, through: span.y + 1, by: 2)
                    where nextY >= 0 && nextY < map.height {
                        var nextX = max(0, span.left - 1)
                        let scanEnd = min(map.width - 1, span.right + 1)
                        while nextX <= scanEnd {
                            let next = nextY * map.width + nextX
                            guard state[next] == 1 else {
                                nextX += 1
                                continue
                            }
                            let nextSpan = consumeForegroundSpan(
                                startingAtX: nextX, y: nextY, width: map.width, state: &state,
                                rowMinimumX: &rowMinimumX, rowMaximumX: &rowMaximumX, touchedRows: &touchedRows
                            )
                            queue.append(nextSpan)
                            componentPixelCount += nextSpan.pixelCount
                            nextX = nextSpan.right + 1
                        }
                    }
                }

                // PaddleOCR.js discards contours with fewer than four points.
                guard componentPixelCount >= 4 else {
                    resetRowExtrema(touchedRows, minimumX: &rowMinimumX, maximumX: &rowMaximumX, emptyMinimum: map.width)
                    continue
                }
                hullCandidates.removeAll(keepingCapacity: true)
                for row in touchedRows {
                    let minimumX = rowMinimumX[row]
                    let maximumX = rowMaximumX[row]
                    hullCandidates.append(CGPoint(x: minimumX, y: row))
                    if maximumX != minimumX {
                        hullCandidates.append(CGPoint(x: maximumX, y: row))
                    }
                }
                resetRowExtrema(touchedRows, minimumX: &rowMinimumX, maximumX: &rowMaximumX, emptyMinimum: map.width)
                guard let minimum = minimumRectangle(points: hullCandidates) else { continue }
                guard minimum.minimumSide >= minimumBoxSide else { continue }
                let score = try boxScore(map: map, polygon: minimum.orderedBox, cancellationCheck: cancellationCheck)
                guard score >= configuration.boxThreshold,
                      boxes.count < configuration.maximumCandidates else { continue }
                try cancellationCheck()
                guard let expanded = minimum.expanded(unclipRatio: configuration.unclipRatio),
                      expanded.minimumSide >= minimumBoxSide + 2 else { continue }
                let polygon = expanded.orderedBox.map { point in
                    CGPoint(
                        x: clampedRounded(Double(point.x) * Double(sourceWidth) / Double(map.width), maximum: sourceWidth),
                        y: clampedRounded(Double(point.y) * Double(sourceHeight) / Double(map.height), maximum: sourceHeight)
                    )
                }
                boxes.append(NativeCoreMLDetectionBox(polygon: polygon, score: score))
            }
        }
        sortReadingOrder(&boxes)
        return boxes
    }

    private static func consumeForegroundSpan(
        startingAtX startX: Int,
        y: Int,
        width: Int,
        state: inout [UInt8],
        rowMinimumX: inout [Int],
        rowMaximumX: inout [Int],
        touchedRows: inout [Int]
    ) -> ForegroundSpan {
        let rowOffset = y * width
        var left = startX
        while left > 0, state[rowOffset + left - 1] == 1 { left -= 1 }
        var right = startX
        while right + 1 < width, state[rowOffset + right + 1] == 1 { right += 1 }
        for x in left...right { state[rowOffset + x] = 2 }
        if rowMaximumX[y] < 0 {
            touchedRows.append(y)
            rowMinimumX[y] = left
            rowMaximumX[y] = right
        } else {
            rowMinimumX[y] = min(rowMinimumX[y], left)
            rowMaximumX[y] = max(rowMaximumX[y], right)
        }
        return ForegroundSpan(y: y, left: left, right: right)
    }

    private static func resetRowExtrema(_ rows: [Int], minimumX: inout [Int], maximumX: inout [Int], emptyMinimum: Int) {
        for row in rows {
            minimumX[row] = emptyMinimum
            maximumX[row] = -1
        }
    }

    private struct MinimumRectangle {
        let center: CGPoint
        let width: Double
        let height: Double
        let angle: Double
        let orderedBox: [CGPoint]

        var minimumSide: Double { min(width, height) }

        func expanded(unclipRatio: Double) -> MinimumRectangle? {
            let area = width * height
            let perimeter = 2 * (width + height)
            guard area > 0, perimeter > 0 else { return nil }
            let distance = area * unclipRatio / perimeter
            return NativeCoreMLDBPostprocessor.makeRectangle(
                center: center, width: width + 2 * distance, height: height + 2 * distance, angle: angle
            )
        }
    }

    private static func minimumRectangle(points: [CGPoint]) -> MinimumRectangle? {
        let hull = convexHull(points)
        guard hull.count >= 3 else { return nil }
        var best: MinimumRectangle?
        var bestArea = Double.infinity
        for index in hull.indices {
            let next = hull[(index + 1) % hull.count]
            let edgeX = Double(next.x - hull[index].x)
            let edgeY = Double(next.y - hull[index].y)
            guard edgeX != 0 || edgeY != 0 else { continue }
            let angle = atan2(edgeY, edgeX)
            let cosine = cos(angle)
            let sine = sin(angle)
            var minimumX = Double.infinity
            var maximumX = -Double.infinity
            var minimumY = Double.infinity
            var maximumY = -Double.infinity
            for point in hull {
                let x = Double(point.x)
                let y = Double(point.y)
                let rotatedX = x * cosine + y * sine
                let rotatedY = -x * sine + y * cosine
                minimumX = min(minimumX, rotatedX)
                maximumX = max(maximumX, rotatedX)
                minimumY = min(minimumY, rotatedY)
                maximumY = max(maximumY, rotatedY)
            }
            let width = maximumX - minimumX
            let height = maximumY - minimumY
            let area = width * height
            if area < bestArea - 0.000_001 {
                let rotatedCenterX = (minimumX + maximumX) * 0.5
                let rotatedCenterY = (minimumY + maximumY) * 0.5
                let center = CGPoint(
                    x: rotatedCenterX * cosine - rotatedCenterY * sine,
                    y: rotatedCenterX * sine + rotatedCenterY * cosine
                )
                best = makeRectangle(center: center, width: width, height: height, angle: angle)
                bestArea = area
            }
        }
        return best
    }

    private static func makeRectangle(center: CGPoint, width: Double, height: Double, angle: Double) -> MinimumRectangle {
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfWidth = width * 0.5
        let halfHeight = height * 0.5
        let localCorners = [(-halfWidth, -halfHeight), (halfWidth, -halfHeight), (halfWidth, halfHeight), (-halfWidth, halfHeight)]
        let corners = localCorners.map { localX, localY in
            CGPoint(
                x: Double(center.x) + localX * cosine - localY * sine,
                y: Double(center.y) + localX * sine + localY * cosine
            )
        }
        return MinimumRectangle(center: center, width: width, height: height, angle: angle, orderedBox: orderQuad(corners))
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = sortedByXThenY(points)
        var unique: [CGPoint] = []
        unique.reserveCapacity(sorted.count)
        for point in sorted {
            if let last = unique.last, abs(last.x - point.x) <= 0.000_001, abs(last.y - point.y) <= 0.000_001 {
                continue
            }
            unique.append(point)
        }
        guard unique.count > 2 else { return unique }
        // Monotone chain: each half drops its final point, the other half's first.
        func chain<Points: Sequence>(_ points: Points) -> [CGPoint] where Points.Element == CGPoint {
            var hull: [CGPoint] = []
            for point in points {
                while hull.count >= 2, cross(hull[hull.count - 2], hull[hull.count - 1], point) <= 0 {
                    hull.removeLast()
                }
                hull.append(point)
            }
            hull.removeLast()
            return hull
        }
        return chain(unique) + chain(unique.reversed())
    }

    private static func sortedByXThenY(_ points: [CGPoint]) -> [CGPoint] {
        points.sorted {
            if abs($0.x - $1.x) > 0.000_001 { return $0.x < $1.x }
            return $0.y < $1.y
        }
    }

    private static func cross(_ origin: CGPoint, _ left: CGPoint, _ right: CGPoint) -> Double {
        Double(left.x - origin.x) * Double(right.y - origin.y)
            - Double(left.y - origin.y) * Double(right.x - origin.x)
    }

    private static func orderQuad(_ points: [CGPoint]) -> [CGPoint] {
        precondition(points.count == 4)
        let sorted = sortedByXThenY(points)
        let (topLeft, bottomLeft) = sorted[1].y > sorted[0].y ? (sorted[0], sorted[1]) : (sorted[1], sorted[0])
        let (topRight, bottomRight) = sorted[3].y > sorted[2].y ? (sorted[2], sorted[3]) : (sorted[3], sorted[2])
        return [topLeft, topRight, bottomRight, bottomLeft]
    }

    private static func boxScore(
        map: NativeCoreMLDetectionMap, polygon: [CGPoint], cancellationCheck: () throws -> Void
    ) throws -> Double {
        let minimumX = max(0, min(map.width - 1, Int(floor(polygon.map(\.x).min() ?? 0))))
        let maximumX = max(0, min(map.width - 1, Int(ceil(polygon.map(\.x).max() ?? 0))))
        let minimumY = max(0, min(map.height - 1, Int(floor(polygon.map(\.y).min() ?? 0))))
        let maximumY = max(0, min(map.height - 1, Int(ceil(polygon.map(\.y).max() ?? 0))))
        // Fast score: vertices truncated to integers; one inclusive span per row.
        let rasterPolygon = polygon.map { CGPoint(x: Int($0.x), y: Int($0.y)) }
        var sum = 0.0
        var count = 0
        for y in minimumY...maximumY {
            if (y - minimumY) & 31 == 0 { try cancellationCheck() }
            guard let span = inclusiveHorizontalSpan(
                y: y, polygon: rasterPolygon, minimumX: minimumX, maximumX: maximumX
            ) else { continue }
            for x in span {
                let value = map.values[y * map.width + x]
                if value.isFinite {
                    sum += Double(value)
                    count += 1
                }
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }

    private static func inclusiveHorizontalSpan(
        y: Int, polygon: [CGPoint], minimumX: Int, maximumX: Int
    ) -> ClosedRange<Int>? {
        let scanY = Double(y)
        var left = Double.infinity
        var right = -Double.infinity
        for index in polygon.indices {
            let first = polygon[index]
            let second = polygon[(index + 1) % polygon.count]
            let firstY = Double(first.y)
            let secondY = Double(second.y)
            let lowerY = min(firstY, secondY)
            let upperY = max(firstY, secondY)
            guard scanY >= lowerY, scanY <= upperY else { continue }
            if firstY == secondY {
                left = min(left, Double(first.x), Double(second.x))
                right = max(right, Double(first.x), Double(second.x))
                continue
            }
            let interpolation = (scanY - firstY) / (secondY - firstY)
            let intersectionX = Double(first.x) + interpolation * Double(second.x - first.x)
            left = min(left, intersectionX)
            right = max(right, intersectionX)
        }
        guard left.isFinite, right.isFinite else { return nil }
        let firstX = max(minimumX, Int(ceil(left)))
        let lastX = min(maximumX, Int(floor(right)))
        guard firstX <= lastX else { return nil }
        return firstX...lastX
    }

    private static func clampedRounded(_ value: Double, maximum: Int) -> CGFloat {
        CGFloat(min(max(Int(value.rounded()), 0), maximum))
    }

    private static func sortReadingOrder(_ boxes: inout [NativeCoreMLDetectionBox]) {
        boxes.sort {
            let left = $0.polygon.first ?? .zero
            let right = $1.polygon.first ?? .zero
            return abs(left.y - right.y) > 0.000_001 ? left.y < right.y : left.x < right.x
        }
        guard boxes.count > 1 else { return }
        for index in 0..<(boxes.count - 1) {
            var cursor = index
            while cursor >= 0 {
                let currentStart = boxes[cursor].polygon.first ?? .zero
                let nextStart = boxes[cursor + 1].polygon.first ?? .zero
                guard abs(nextStart.y - currentStart.y) < 10, nextStart.x < currentStart.x else { break }
                boxes.swapAt(cursor, cursor + 1)
                cursor -= 1
            }
        }
    }
}
