// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

@available(iOS 18.0, *)
struct NativeCoreMLDetectionMap: Equatable, Sendable {
    let width: Int
    let height: Int
    let values: [Float]

    init(width: Int, height: Int, values: [Float]) {
        precondition(width > 0 && height > 0)
        let count = width.multipliedReportingOverflow(by: height)
        precondition(!count.overflow && values.count == count.partialValue)
        self.width = width
        self.height = height
        self.values = values
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLDBPostprocessConfiguration: Equatable, Sendable {
    static let production = NativeCoreMLDBPostprocessConfiguration(
        threshold: 0.3,
        boxThreshold: 0.6,
        unclipRatio: 1.5,
        maximumCandidates: 3_000
    )
    static let compact = NativeCoreMLDBPostprocessConfiguration(
        threshold: 0.3,
        boxThreshold: 0.6,
        unclipRatio: 1.5,
        maximumCandidates: 1_000
    )
    static let tiny = NativeCoreMLDBPostprocessConfiguration(
        threshold: 0.2,
        boxThreshold: 0.4,
        unclipRatio: 1.4,
        maximumCandidates: 3_000
    )

    let threshold: Double
    let boxThreshold: Double
    let unclipRatio: Double
    let maximumCandidates: Int

    init(
        threshold: Double,
        boxThreshold: Double,
        unclipRatio: Double,
        maximumCandidates: Int
    ) {
        precondition((0 ... 1).contains(threshold))
        precondition((0 ... 1).contains(boxThreshold))
        precondition(unclipRatio > 0 && unclipRatio.isFinite)
        precondition(maximumCandidates > 0)
        self.threshold = threshold
        self.boxThreshold = boxThreshold
        self.unclipRatio = unclipRatio
        self.maximumCandidates = maximumCandidates
    }
}

@available(iOS 18.0, *)
struct NativeCoreMLDBPostprocessResult: Equatable, Sendable {
    let boxes: [NativeCoreMLDetectionBox]
    let candidateComponents: Int
}

/// Locates a materialized probability-map window inside the detector's full
/// active output. Full-frame callers use the default identity geometry; dirty
/// OCR can decode a smaller map while preserving the exact source coordinate
/// transform used by full DB postprocessing.
@available(iOS 18.0, *)
struct NativeCoreMLDetectionMapGeometry: Equatable, Sendable {
    let originX: Int
    let originY: Int
    let fullWidth: Int
    let fullHeight: Int

    init(originX: Int, originY: Int, fullWidth: Int, fullHeight: Int) {
        precondition(originX >= 0 && originY >= 0)
        precondition(fullWidth > 0 && fullHeight > 0)
        precondition(originX < fullWidth && originY < fullHeight)
        self.originX = originX
        self.originY = originY
        self.fullWidth = fullWidth
        self.fullHeight = fullHeight
    }
}

/// Native DBNet postprocessing for PP-OCR detector output.
/// It uses 8-connected binary components, convex hulls, minimum-area
/// rectangles, the fast polygon score, and the DB unclip distance. The mask
/// and score thresholds intentionally use the production overrides rather
/// than the lower values embedded in the upstream inference YAML.
@available(iOS 18.0, *)
enum NativeCoreMLDBPostprocessor {
    private static let minimumBoxSide = 3.0

    // Split a rejected weakly connected component once, with row-bounded
    // hull storage and cancellable scans. Callers opt in for validated models.
    private static func splitWeakBridge(
        _ spans: [ForegroundSpan], map: NativeCoreMLDetectionMap,
        threshold: Double, cancellationCheck: () throws -> Void
    ) throws -> [(MinimumRectangle, Double, Int?)]? {
        guard !spans.isEmpty else { return nil }
        var x0 = map.width, x1 = -1, y0 = map.height, y1 = -1
        var total = 0
        for (index, span) in spans.enumerated() {
            if index & 1_023 == 0 { try cancellationCheck() }
            x0 = min(x0, span.left); x1 = max(x1, span.right)
            y0 = min(y0, span.y); y1 = max(y1, span.y)
            total += span.pixelCount
        }
        let width = x1 - x0 + 1, height = y1 - y0 + 1
        guard Double(height) >= Double(width) * 1.15 else { return nil }
        var diff = [Int](repeating: 0, count: width + 1)
        for (index, span) in spans.enumerated() {
            if index & 1_023 == 0 { try cancellationCheck() }
            diff[span.left - x0] += 1
            diff[span.right - x0 + 1] -= 1
        }
        var count = [Int](repeating: 0, count: width)
        var n = 0
        for i in 0..<width {
            if i & 1_023 == 0 { try cancellationCheck() }
            n += diff[i]; count[i] = n
        }
        var best: Range<Int>?, start: Int?
        for i in 0...width {
            if i & 1_023 == 0 { try cancellationCheck() }
            let low = i < width && Double(count[i]) <= Double(height) * 0.12
            if low && start == nil { start = i }
            if !low, let begin = start {
                let band = begin..<i
                if begin > 0 && i < width && (best == nil || band.count > best!.count) { best = band }
                start = nil
            }
        }
        guard let band = best, Double(band.count) >= Double(width) * 0.15,
              Double(band.count) <= Double(width) * 0.5 else { return nil }
        let cut = (band.lowerBound + band.upperBound) / 2
        guard (count[..<cut].max() ?? 0) >= Int(Double(height) * 0.45),
              (count[(cut + 1)...].max() ?? 0) >= Int(Double(height) * 0.45) else { return nil }
        var results: [(MinimumRectangle, Double, Int?)] = []
        for side in 0..<2 {
            try cancellationCheck()
            var minimumX = [Int](repeating: map.width, count: height)
            var maximumX = [Int](repeating: -1, count: height)
            var pixels = 0
            for (index, span) in spans.enumerated() {
                if index & 1_023 == 0 { try cancellationCheck() }
                let left = side == 0 ? span.left : max(span.left, x0 + cut + 1)
                let right = side == 0 ? min(span.right, x0 + cut - 1) : span.right
                if left <= right {
                    let row = span.y - y0
                    minimumX[row] = min(minimumX[row], left)
                    maximumX[row] = max(maximumX[row], right)
                    pixels += right - left + 1
                }
            }
            var points: [CGPoint] = []
            points.reserveCapacity(height * 2)
            for row in 0..<height {
                if row & 1_023 == 0 { try cancellationCheck() }
                guard maximumX[row] >= 0 else { continue }
                points.append(CGPoint(x: minimumX[row], y: row + y0))
                if minimumX[row] != maximumX[row] {
                    points.append(CGPoint(x: maximumX[row], y: row + y0))
                }
            }
            try cancellationCheck()
            guard Double(pixels) >= Double(total) * 0.25,
                  let rect = minimumRectangle(points: points), rect.minimumSide >= minimumBoxSide else { return nil }
            try cancellationCheck()
            let score = try boxScore(map: map, polygon: rect.orderedBox, cancellationCheck: cancellationCheck)
            guard score >= threshold else { return nil }
            results.append((rect, score, side == 0 ? x0 + cut : -(x0 + cut)))
        }
        return results
    }

    private struct ForegroundSpan {
        let y: Int
        let left: Int
        let right: Int

        var pixelCount: Int { right - left + 1 }
    }

    static func decode(
        map: NativeCoreMLDetectionMap,
        sourceWidth: Int,
        sourceHeight: Int,
        geometry: NativeCoreMLDetectionMapGeometry? = nil,
        configuration: NativeCoreMLDBPostprocessConfiguration = .production,
        allowsWeakBridgeSplit: Bool = false,
        cancellationCheck: () throws -> Void = {}
    ) throws -> NativeCoreMLDBPostprocessResult {
        guard sourceWidth > 0, sourceHeight > 0 else {
            return NativeCoreMLDBPostprocessResult(
                boxes: [],
                candidateComponents: 0
            )
        }
        let resolvedGeometry = geometry ?? NativeCoreMLDetectionMapGeometry(
            originX: 0,
            originY: 0,
            fullWidth: map.width,
            fullHeight: map.height
        )
        precondition(resolvedGeometry.originX + map.width
            <= resolvedGeometry.fullWidth)
        precondition(resolvedGeometry.originY + map.height
            <= resolvedGeometry.fullHeight)
        // 0 = background, 1 = unvisited foreground, 2 = visited foreground.
        // The old implementation kept equally sized `mask` and `visited`
        // arrays. A single byte of state preserves the exact threshold and
        // 8-connectivity semantics while halving the full-map scratch storage.
        var state = [UInt8](repeating: 0, count: map.values.count)
        for index in map.values.indices {
            let value = map.values[index]
            if value.isFinite, Double(value) > configuration.threshold {
                state[index] = 1
            }
        }

        // Queue horizontal runs rather than every foreground pixel. Dense text
        // components commonly collapse from thousands of queue entries to a
        // few dozen rows, and adjacent-row scanning preserves exact
        // 8-connectivity by extending the overlap one pixel on each side.
        var queue: [ForegroundSpan] = []
        queue.reserveCapacity(256)
        // The convex hull of a set of raster pixels is completely determined
        // by the left-most and right-most pixel on each occupied row. Keeping
        // those extrema avoids collecting and sorting every contour pixel.
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
            for x in 0..<map.width {
                let start = y * map.width + x
                guard state[start] == 1 else { continue }
                if candidateComponents >= configuration.maximumCandidates {
                    break scan
                }
                candidateComponents += 1
                queue.removeAll(keepingCapacity: true)
                touchedRows.removeAll(keepingCapacity: true)
                let firstSpan = consumeForegroundSpan(
                    startingAtX: x,
                    y: y,
                    width: map.width,
                    state: &state,
                    rowMinimumX: &rowMinimumX,
                    rowMaximumX: &rowMaximumX,
                    touchedRows: &touchedRows
                )
                queue.append(firstSpan)
                var cursor = 0
                var componentPixelCount = firstSpan.pixelCount
                while cursor < queue.count {
                    if cursor & 1_023 == 0 { try cancellationCheck() }
                    let span = queue[cursor]
                    cursor += 1
                    for nextY in [span.y - 1, span.y + 1]
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
                                startingAtX: nextX,
                                y: nextY,
                                width: map.width,
                                state: &state,
                                rowMinimumX: &rowMinimumX,
                                rowMaximumX: &rowMaximumX,
                                touchedRows: &touchedRows
                            )
                            queue.append(nextSpan)
                            componentPixelCount += nextSpan.pixelCount
                            // The whole run is now visited, including any part
                            // extending beyond this span's overlap window.
                            nextX = nextSpan.right + 1
                        }
                    }
                }

                // OpenCV's CHAIN_APPROX_SIMPLE contours with fewer than four
                // points are discarded by PaddleOCR.js.
                guard componentPixelCount >= 4 else {
                    resetRowExtrema(
                        touchedRows,
                        minimumX: &rowMinimumX,
                        maximumX: &rowMaximumX,
                        emptyMinimum: map.width
                    )
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
                resetRowExtrema(
                    touchedRows,
                    minimumX: &rowMinimumX,
                    maximumX: &rowMaximumX,
                    emptyMinimum: map.width
                )
                guard let minimum = minimumRectangle(points: hullCandidates),
                      minimum.minimumSide >= minimumBoxSide
                else {
                    continue
                }
                let score = try boxScore(map: map, polygon: minimum.orderedBox, cancellationCheck: cancellationCheck)
                let parts: [(MinimumRectangle, Double, Int?)]
                if score >= configuration.boxThreshold {
                    parts = [(minimum, score, nil)]
                } else if allowsWeakBridgeSplit,
                          boxes.count + 2 <= configuration.maximumCandidates,
                          let split = try splitWeakBridge(
                              queue, map: map, threshold: configuration.boxThreshold,
                              cancellationCheck: cancellationCheck
                          ) {
                    parts = split
                } else {
                    continue
                }
                for (minimum, score, splitCell) in parts {
                    guard boxes.count < configuration.maximumCandidates else { break }
                    try cancellationCheck()
                    guard let expanded = minimum.expanded(
                        unclipRatio: configuration.unclipRatio
                    ), expanded.minimumSide >= minimumBoxSide + 2
                    else {
                        continue
                    }
                    let polygon = expanded.orderedBox.map { point in
                        let boundedX: CGFloat
                        if let splitCell {
                            boundedX = splitCell >= 0
                                ? min(point.x, CGFloat(splitCell))
                                : max(point.x, CGFloat(-splitCell))
                        } else {
                            boundedX = point.x
                        }
                        return CGPoint(
                            x: clampedRounded(
                                (Double(boundedX)
                                    + Double(resolvedGeometry.originX))
                                    * Double(sourceWidth)
                                    / Double(resolvedGeometry.fullWidth),
                                maximum: sourceWidth
                            ),
                            y: clampedRounded(
                                (Double(point.y)
                                    + Double(resolvedGeometry.originY))
                                    * Double(sourceHeight)
                                    / Double(resolvedGeometry.fullHeight),
                                maximum: sourceHeight
                            )
                        )
                    }
                    boxes.append(NativeCoreMLDetectionBox(
                        polygon: polygon,
                        score: score
                    ))
                }
            }
        }
        sortReadingOrder(&boxes)
        return NativeCoreMLDBPostprocessResult(
            boxes: boxes,
            candidateComponents: candidateComponents
        )
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
        while left > 0, state[rowOffset + left - 1] == 1 {
            left -= 1
        }
        var right = startX
        while right + 1 < width, state[rowOffset + right + 1] == 1 {
            right += 1
        }
        for x in left...right {
            state[rowOffset + x] = 2
        }
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

    private static func resetRowExtrema(
        _ rows: [Int],
        minimumX: inout [Int],
        maximumX: inout [Int],
        emptyMinimum: Int
    ) {
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
            let expandedWidth = width + 2 * distance
            let expandedHeight = height + 2 * distance
            return NativeCoreMLDBPostprocessor.makeRectangle(
                center: center,
                width: expandedWidth,
                height: expandedHeight,
                angle: angle
            )
        }
    }

    private static func minimumRectangle(
        points: [CGPoint]
    ) -> MinimumRectangle? {
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
                best = makeRectangle(
                    center: center,
                    width: width,
                    height: height,
                    angle: angle
                )
                bestArea = area
            }
        }
        return best
    }

    private static func makeRectangle(
        center: CGPoint,
        width: Double,
        height: Double,
        angle: Double
    ) -> MinimumRectangle {
        let cosine = cos(angle)
        let sine = sin(angle)
        let halfWidth = width * 0.5
        let halfHeight = height * 0.5
        let localCorners = [
            (-halfWidth, -halfHeight),
            (halfWidth, -halfHeight),
            (halfWidth, halfHeight),
            (-halfWidth, halfHeight),
        ]
        let corners = localCorners.map { localX, localY in
            CGPoint(
                x: Double(center.x) + localX * cosine - localY * sine,
                y: Double(center.y) + localX * sine + localY * cosine
            )
        }
        return MinimumRectangle(
            center: center,
            width: width,
            height: height,
            angle: angle,
            orderedBox: orderQuad(corners)
        )
    }

    private static func convexHull(_ points: [CGPoint]) -> [CGPoint] {
        let sorted = points.sorted {
            if abs($0.x - $1.x) > 0.000_001 { return $0.x < $1.x }
            return $0.y < $1.y
        }
        var unique: [CGPoint] = []
        unique.reserveCapacity(sorted.count)
        for point in sorted {
            if let last = unique.last,
               abs(last.x - point.x) <= 0.000_001,
               abs(last.y - point.y) <= 0.000_001 {
                continue
            }
            unique.append(point)
        }
        guard unique.count > 2 else { return unique }
        var lower: [CGPoint] = []
        for point in unique {
            while lower.count >= 2,
                  cross(
                    lower[lower.count - 2],
                    lower[lower.count - 1],
                    point
                  ) <= 0 {
                lower.removeLast()
            }
            lower.append(point)
        }
        var upper: [CGPoint] = []
        for point in unique.reversed() {
            while upper.count >= 2,
                  cross(
                    upper[upper.count - 2],
                    upper[upper.count - 1],
                    point
                  ) <= 0 {
                upper.removeLast()
            }
            upper.append(point)
        }
        lower.removeLast()
        upper.removeLast()
        return lower + upper
    }

    private static func cross(
        _ origin: CGPoint,
        _ left: CGPoint,
        _ right: CGPoint
    ) -> Double {
        Double(left.x - origin.x) * Double(right.y - origin.y)
            - Double(left.y - origin.y) * Double(right.x - origin.x)
    }

    private static func orderQuad(_ points: [CGPoint]) -> [CGPoint] {
        precondition(points.count == 4)
        let sorted = points.sorted {
            if abs($0.x - $1.x) > 0.000_001 { return $0.x < $1.x }
            return $0.y < $1.y
        }
        let topLeft: CGPoint
        let bottomLeft: CGPoint
        if sorted[1].y > sorted[0].y {
            topLeft = sorted[0]
            bottomLeft = sorted[1]
        } else {
            topLeft = sorted[1]
            bottomLeft = sorted[0]
        }
        let topRight: CGPoint
        let bottomRight: CGPoint
        if sorted[3].y > sorted[2].y {
            topRight = sorted[2]
            bottomRight = sorted[3]
        } else {
            topRight = sorted[3]
            bottomRight = sorted[2]
        }
        return [topLeft, topRight, bottomRight, bottomLeft]
    }

    private static func boxScore(
        map: NativeCoreMLDetectionMap,
        polygon: [CGPoint],
        cancellationCheck: () throws -> Void = {}
    ) throws -> Double {
        let minimumX = max(
            0,
            min(map.width - 1, Int(floor(polygon.map(\.x).min() ?? 0)))
        )
        let maximumX = max(
            0,
            min(map.width - 1, Int(ceil(polygon.map(\.x).max() ?? 0)))
        )
        let minimumY = max(
            0,
            min(map.height - 1, Int(floor(polygon.map(\.y).min() ?? 0)))
        )
        let maximumY = max(
            0,
            min(map.height - 1, Int(ceil(polygon.map(\.y).max() ?? 0)))
        )
        // Preserve the legacy fast-score contract: polygon vertices are
        // truncated to integer coordinates before rasterization. The polygon
        // is a convex minimum-area rectangle, so each scan row has one
        // inclusive span. Computing the two edge intersections once per row
        // replaces four edge tests (and divisions) for every map pixel.
        let rasterPolygon = polygon.map {
            CGPoint(x: Int($0.x), y: Int($0.y))
        }
        var sum = 0.0
        var count = 0
        for y in minimumY...maximumY {
            if (y - minimumY) & 31 == 0 { try cancellationCheck() }
            guard let span = inclusiveHorizontalSpan(
                y: y,
                polygon: rasterPolygon,
                minimumX: minimumX,
                maximumX: maximumX
            ) else {
                continue
            }
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

#if DEBUG
    /// Deterministic parity seam for the OCRCoreML test target. Release builds
    /// keep the score implementation private to DB postprocessing.
    static func boxScoreForTesting(
        map: NativeCoreMLDetectionMap,
        polygon: [CGPoint]
    ) -> Double {
        try! boxScore(map: map, polygon: polygon)
    }
#endif

    private static func inclusiveHorizontalSpan(
        y: Int,
        polygon: [CGPoint],
        minimumX: Int,
        maximumX: Int
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
            let intersectionX = Double(first.x)
                + interpolation * Double(second.x - first.x)
            left = min(left, intersectionX)
            right = max(right, intersectionX)
        }
        guard left.isFinite, right.isFinite else { return nil }
        let firstX = max(minimumX, Int(ceil(left)))
        let lastX = min(maximumX, Int(floor(right)))
        guard firstX <= lastX else { return nil }
        return firstX...lastX
    }

    private static func clampedRounded(
        _ value: Double,
        maximum: Int
    ) -> CGFloat {
        CGFloat(min(max(Int(value.rounded()), 0), maximum))
    }

    private static func sortReadingOrder(
        _ boxes: inout [NativeCoreMLDetectionBox]
    ) {
        boxes.sort {
            let left = $0.polygon.first ?? .zero
            let right = $1.polygon.first ?? .zero
            if abs(left.y - right.y) > 0.000_001 {
                return left.y < right.y
            }
            return left.x < right.x
        }
        guard boxes.count > 1 else { return }
        for index in 0..<(boxes.count - 1) {
            var cursor = index
            while cursor >= 0 {
                let current = boxes[cursor]
                let next = boxes[cursor + 1]
                let currentStart = current.polygon.first ?? .zero
                let nextStart = next.polygon.first ?? .zero
                guard abs(nextStart.y - currentStart.y) < 10,
                      nextStart.x < currentStart.x
                else {
                    break
                }
                boxes.swapAt(cursor, cursor + 1)
                cursor -= 1
            }
        }
    }
}
