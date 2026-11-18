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
    // Manga profile: user-selected binarization 0.85; upstream box score and unclip.
    static let manga = NativeCoreMLDBPostprocessConfiguration(
        threshold: 0.85,
        boxThreshold: 0.25,
        unclipRatio: 1.4,
        maximumCandidates: 3_000
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
    let minimumBoxSide: Double
    /// Components scoring in `recoveryBoxThreshold..<boxThreshold` (and not split into accepted
    /// parts) are kept as weak boxes. Their recognition must pass the pipeline's recovery gate
    /// (faint pencil / brush lettering); nil keeps the exact thresholded detector output.
    let recoveryBoxThreshold: Double?

    init(
        threshold: Double,
        boxThreshold: Double,
        unclipRatio: Double,
        maximumCandidates: Int,
        minimumBoxSide: Double = 3,
        recoveryBoxThreshold: Double? = nil
    ) {
        precondition((0 ... 1).contains(threshold))
        precondition((0 ... 1).contains(boxThreshold))
        precondition(unclipRatio > 0 && unclipRatio.isFinite)
        precondition(maximumCandidates > 0)
        precondition(minimumBoxSide.isFinite && minimumBoxSide >= 0)
        self.threshold = threshold
        self.boxThreshold = boxThreshold
        self.unclipRatio = unclipRatio
        self.maximumCandidates = maximumCandidates
        self.minimumBoxSide = minimumBoxSide
        self.recoveryBoxThreshold = recoveryBoxThreshold.map { min(max($0, 0), boxThreshold) }
    }

    func withRecoveryBoxThreshold(_ value: Double?) -> Self {
        Self(threshold: threshold, boxThreshold: boxThreshold, unclipRatio: unclipRatio,
             maximumCandidates: maximumCandidates, minimumBoxSide: minimumBoxSide, recoveryBoxThreshold: value)
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
    // Split a rejected weakly connected component once, with row-bounded
    // hull storage and cancellable scans. Callers opt in for validated models.
    private static func splitWeakBridge(
        _ spans: [ForegroundSpan], map: NativeCoreMLDetectionMap,
        threshold: Double, minimumBoxSide: Double, cancellationCheck: () throws -> Void
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

    /// Largest Float not above `threshold`. For every finite Float `value`,
    /// `Double(value) > threshold` is exactly `value > cutoff`: a Float above
    /// the cutoff is at least its successor, which exceeds `threshold` by
    /// construction. NaN thresholds stay NaN and therefore reject everything.
    static func foregroundCutoff(threshold: Double) -> Float {
        var cutoff = Float(threshold)
        if Double(cutoff) > threshold {
            cutoff = cutoff.nextDown
        }
        return cutoff
    }

    /// 1 for finite values strictly above `threshold`, otherwise 0. Equivalent
    /// to `value.isFinite && Double(value) > threshold` per element, but a
    /// branch-free Float comparison over contiguous storage.
    static func foregroundState(values: [Float], threshold: Double) -> [UInt8] {
        let cutoff = foregroundCutoff(threshold: threshold)
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
        map: NativeCoreMLDetectionMap,
        sourceWidth: Int,
        sourceHeight: Int,
        geometry: NativeCoreMLDetectionMapGeometry? = nil,
        configuration: NativeCoreMLDBPostprocessConfiguration = .production,
        allowsWeakBridgeSplit: Bool = false,
        allowsThinFinePrintRecovery: Bool = false,
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
        var state = foregroundState(
            values: map.values,
            threshold: configuration.threshold
        )

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
        // Keep rejected thin components separate from ordinary DB output.
        // A strong, already accepted horizontal neighbor must support them.
        var thinCandidates: [(rectangle: MinimumRectangle, score: Double)] = []
        let permitsThinRecovery = allowsThinFinePrintRecovery
            && configuration.minimumBoxSide == 3
            && Double(sourceWidth) / Double(resolvedGeometry.fullWidth) >= 1.5
            && Double(sourceHeight) / Double(resolvedGeometry.fullHeight) >= 1.5

        scan: for y in 0..<map.height {
            if y & 31 == 0 { try cancellationCheck() }
            let row = y * map.width
            var nextSeedX = 0
            while nextSeedX < map.width {
                // Search only this row of the current mutable state; visiting
                // a component may change later bytes before the next search.
                let start = row + nextSeedX
                let offset = state.withUnsafeBufferPointer { buffer -> Int? in
                    let base = UnsafeRawPointer(buffer.baseAddress!)
                    guard let next = memchr(base + start, 1, map.width - nextSeedX) else { return nil }
                    return base.distance(to: UnsafeRawPointer(next))
                }
                guard let offset else { break }
                let x = offset - row
                nextSeedX = x + 1
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
                    // Same order as `[y - 1, y + 1]` without allocating an
                    // array for every queued span.
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
                guard let minimum = minimumRectangle(points: hullCandidates) else { continue }
                if minimum.minimumSide < configuration.minimumBoxSide {
                    if permitsThinRecovery, thinCandidates.count < 64, minimum.minimumSide >= 1 {
                        let rectangleBounds = bounds(of: minimum.orderedBox)
                        // Evidence-backed tiny horizontal labels have two or
                        // three occupied rows, not isolated pixels or rules.
                        let rasterBounds = bounds(of: hullCandidates)
                        let rasterWidth = rasterBounds.width + 1
                        let rasterHeight = rasterBounds.height + 1
                        if (2...3).contains(rasterHeight), rasterWidth >= 7,
                           rectangleBounds.width >= rectangleBounds.height * 2,
                           componentPixelCount >= 8,
                           Double(componentPixelCount) / Double(rasterWidth * rasterHeight) >= 0.65 {
                            let score = try boxScore(map: map, polygon: minimum.orderedBox,
                                                     cancellationCheck: cancellationCheck)
                            if score >= max(0.45, configuration.boxThreshold) {
                                thinCandidates.append((minimum, score))
                            }
                        }
                    }
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
                              minimumBoxSide: configuration.minimumBoxSide,
                              cancellationCheck: cancellationCheck
                          ) {
                    parts = split
                } else if let recovery = configuration.recoveryBoxThreshold, score >= recovery {
                    parts = [(minimum, score, nil)]
                } else {
                    continue
                }
                for (minimum, score, splitCell) in parts {
                    guard boxes.count < configuration.maximumCandidates else { break }
                    try cancellationCheck()
                    guard let expanded = minimum.expanded(
                        unclipRatio: configuration.unclipRatio
                    ), expanded.minimumSide >= configuration.minimumBoxSide + 2
                    else {
                        continue
                    }
                    let polygon = expanded.orderedBox.map { point in
                        let boundedX: CGFloat
                        if let splitCell {
                            boundedX = splitCell >= 0 ? min(point.x, CGFloat(splitCell)) : max(point.x, CGFloat(-splitCell))
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
        if !thinCandidates.isEmpty {
            // Never allow newly recovered labels to become evidence for more
            // labels. Eight additions and 64 scored candidates bound work.
            let occupiedBounds = boxes.map { bounds(of: $0.polygon) }
            let supportingBounds = zip(boxes, occupiedBounds).compactMap { box, bounds -> CGRect? in
                box.score >= 0.6 && bounds.height > 0 && bounds.width >= bounds.height * 1.7 ? bounds : nil
            }
            var recovered = 0
            for candidate in thinCandidates {
                try cancellationCheck()
                guard recovered < 8, boxes.count < configuration.maximumCandidates else { break }
                let candidatePolygon = sourcePolygon(
                    candidate.rectangle.orderedBox, geometry: resolvedGeometry,
                    sourceWidth: sourceWidth, sourceHeight: sourceHeight
                )
                let candidateBounds = bounds(of: candidatePolygon)
                guard supportsThinFinePrint(candidateBounds, occupied: occupiedBounds,
                                            neighbors: supportingBounds) else { continue }
                guard let expanded = candidate.rectangle.expanded(unclipRatio: configuration.unclipRatio,
                                                                  minimumShortSide: 5) else { continue }
                let context = expanded.finePrintRecognitionContext().map {
                    sourcePolygon($0.orderedBox, geometry: resolvedGeometry,
                                  sourceWidth: sourceWidth, sourceHeight: sourceHeight)
                }
                boxes.append(NativeCoreMLDetectionBox(
                    polygon: sourcePolygon(expanded.orderedBox, geometry: resolvedGeometry,
                                           sourceWidth: sourceWidth, sourceHeight: sourceHeight),
                    score: candidate.score,
                    recognitionPolygon: context,
                    isThinFinePrintRecovery: true,
                    finePrintRetryPolygons: expanded.finePrintRetryContexts().map {
                        sourcePolygon($0.orderedBox, geometry: resolvedGeometry,
                                      sourceWidth: sourceWidth, sourceHeight: sourceHeight)
                    }
                ))
                recovered += 1
            }
        }
        sortReadingOrder(&boxes)
        return NativeCoreMLDBPostprocessResult(
            boxes: boxes,
            candidateComponents: candidateComponents
        )
    }

    private static func bounds(of polygon: [CGPoint]) -> CGRect {
        guard let first = polygon.first else { return .zero }
        var minimumX = first.x, maximumX = first.x, minimumY = first.y, maximumY = first.y
        for point in polygon.dropFirst() {
            minimumX = min(minimumX, point.x); maximumX = max(maximumX, point.x)
            minimumY = min(minimumY, point.y); maximumY = max(maximumY, point.y)
        }
        return CGRect(x: minimumX, y: minimumY, width: maximumX - minimumX, height: maximumY - minimumY)
    }

    private static func supportsThinFinePrint(_ candidate: CGRect, occupied: [CGRect], neighbors: [CGRect]) -> Bool {
        let center = CGPoint(x: candidate.midX, y: candidate.midY)
        if occupied.contains(where: { $0.contains(center) }) { return false }
        return neighbors.contains { neighbor in
            guard candidate.width <= neighbor.width * 2 else { return false }
            let overlap = max(0, min(candidate.maxX, neighbor.maxX) - max(candidate.minX, neighbor.minX))
            let gap = max(0, neighbor.minY - candidate.maxY, candidate.minY - neighbor.maxY)
            return overlap >= min(candidate.width, neighbor.width) * 0.2 && gap <= neighbor.height * 2
        }
    }

    private static func sourcePolygon(
        _ polygon: [CGPoint], geometry: NativeCoreMLDetectionMapGeometry, sourceWidth: Int, sourceHeight: Int
    ) -> [CGPoint] {
        polygon.map { point in
            CGPoint(
                x: clampedRounded((Double(point.x) + Double(geometry.originX))
                    * Double(sourceWidth) / Double(geometry.fullWidth), maximum: sourceWidth),
                y: clampedRounded((Double(point.y) + Double(geometry.originY))
                    * Double(sourceHeight) / Double(geometry.fullHeight), maximum: sourceHeight)
            )
        }
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

        /// Actual Core ML crops recover clipped prefixes/suffixes with two
        /// extra map pixels at either long edge. Narrow valid 氏名 labels
        /// regress to 民名 when padded, so their original crop stays exact.
        func finePrintRecognitionContext() -> MinimumRectangle? {
            guard max(width, height) / min(width, height) >= 2.5 else { return nil }
            return withLongSidePadding(2)
        }

        /// Narrow labels keep their successful original crop. Only an empty
        /// recognition may try these exact map-scaled, bounded contexts.
        func finePrintRetryContexts() -> [MinimumRectangle] {
            guard max(width, height) / min(width, height) < 2.5 else { return [] }
            return [withLongSidePadding(2), withLongSidePadding(2.5)]
        }

        private func withLongSidePadding(_ padding: Double) -> MinimumRectangle {
            NativeCoreMLDBPostprocessor.makeRectangle(
                center: center,
                width: width + (width >= height ? padding * 2 : 0),
                height: height + (height > width ? padding * 2 : 0),
                angle: angle
            )
        }

        func expanded(unclipRatio: Double, minimumShortSide: Double = 0) -> MinimumRectangle? {
            let area = width * height
            let perimeter = 2 * (width + height)
            guard area > 0, perimeter > 0 else { return nil }
            let distance = area * unclipRatio / perimeter
            let expandedWidth = max(width + 2 * distance, minimumShortSide)
            let expandedHeight = max(height + 2 * distance, minimumShortSide)
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
        if NativeOCRDirectionGeometry.enabled("dbquad") {
            // Minimum-area rectangle corner zero has no text-direction meaning.
            // Preserve the rotated shape, but normalize its untyped reading
            // basis before RF sampling and common recognizer canonicalization.
            return NativeOCRDirectionGeometry.readingQuad(points) ?? []
        }
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

    /// The same integer raster as boxScore, evaluated on final source quads.
    /// This post-correction score is distinct from the original pre-unclip score.
    /// Caller must verify all values are finite before calling.
    static func validatedFiniteCorrectedBoxScores(map: NativeCoreMLDetectionMap, sourceWidth: Int, sourceHeight: Int,
                                   polygons: [[CGPoint]], cancellationCheck: () throws -> Void = {}) throws -> [Double] {
        precondition(sourceWidth > 0 && sourceHeight > 0)
        let stride = map.width + 1
        let sums = try [Double](unsafeUninitializedCapacity: stride * map.height) { buffer, initialized in
            var offset = 0
            try map.values.withUnsafeBufferPointer { values in
                for y in 0..<map.height {
                    if y & 31 == 0 { try cancellationCheck() }
                    var prefix = 0.0
                    buffer[offset] = prefix
                    let input = y * map.width
                    for x in 0..<map.width {
                        prefix += Double(values[input + x])
                        buffer[offset + x + 1] = prefix
                    }
                    offset += stride
                    initialized = offset
                }
            }
        }
        return try polygons.map { source in
            try cancellationCheck()
            guard source.count == 4, source.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                abs($0.x) < 1e9 && abs($0.y) < 1e9 }) else { return 0 }
            let polygon = source.map { CGPoint(x: Double($0.x) * Double(map.width) / Double(sourceWidth),
                                               y: Double($0.y) * Double(map.height) / Double(sourceHeight)) }
            let minimumX = max(0, min(map.width-1, Int(floor(polygon.map(\.x).min()!))))
            let maximumX = max(0, min(map.width-1, Int(ceil(polygon.map(\.x).max()!))))
            let minimumY = max(0, min(map.height-1, Int(floor(polygon.map(\.y).min()!))))
            let maximumY = max(0, min(map.height-1, Int(ceil(polygon.map(\.y).max()!))))
            let raster = polygon.map { CGPoint(x: Int($0.x), y: Int($0.y)) }
            var sum = 0.0, count = 0
            for y in minimumY...maximumY {
                if (y-minimumY) & 31 == 0 { try cancellationCheck() }
                guard let span = inclusiveHorizontalSpan(y: y, polygon: raster,
                    minimumX: minimumX, maximumX: maximumX) else { continue }
                let i = y * stride
                sum += sums[i+span.upperBound+1] - sums[i+span.lowerBound]
                count += span.count
            }
            return count == 0 ? 0 : sum / Double(count)
        }
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

@available(iOS 18.0, *)
extension NativeCoreMLDBPostprocessor {
    static let alternateCellEnvelopeEnvironmentKey = "AIDOKU_DET_ALTERNATE_CELL_ENVELOPE"
    static let alternateCellEnvelopeEnabled =
        ProcessInfo.processInfo.environment[alternateCellEnvelopeEnvironmentKey] == "1"
    static let maximumAlternateCellEnvelopes = 8

    /// Offer one larger crop for each of at most eight narrow detector parents.
    /// Added area may touch, but cannot enter, another original or selected crop.
    /// The 128-row ceiling bounds footprint comparisons on unusually dense pages.
    static func alternateCellEnvelopes(
        polygons: [[CGPoint]], sourceWidth: Int, sourceHeight: Int, mapWidth: Int, mapHeight: Int,
        cancellationCheck: () throws -> Void = {}
    ) throws -> [Int: [CGPoint]] {
        typealias Geometry = NativeOCRGeometryDeduplication
        typealias Point = NativeOCRIndividualGeometryHypotheses.Point
        guard (1...128).contains(polygons.count), sourceWidth > 0, sourceHeight > 0,
              mapWidth > 0, mapHeight > 0 else { return [:] }

        let originals = polygons.map { polygon in
            Geometry.Shape(polygon.map { Point(x: Double($0.x), y: Double($0.y)) })
        }
        guard originals.allSatisfy({ $0.convex && $0.area.isFinite && $0.area > 0 }) else { return [:] }
        let pitchX = Double(sourceWidth) / Double(mapWidth)
        let pitchY = Double(sourceHeight) / Double(mapHeight)
        let gridScaleX = 1 / pitchX
        let gridScaleY = 1 / pitchY
        let margin = 1.5
        let areaTolerance = 1e-7
        let ranked = try originals.enumerated().compactMap { index, original -> (Int, Geometry.Shape, Double)? in
            try cancellationCheck()
            let grid = original.polygon.map { Point(x: $0.x * gridScaleX, y: $0.y * gridScaleY) }
            let edges = grid.indices.map { i in
                let next = grid[(i + 1) % grid.count]
                return Point(x: next.x - grid[i].x, y: next.y - grid[i].y)
            }
            let lengths = edges.map { sqrt($0.x * $0.x + $0.y * $0.y) }
            guard let shortest = lengths.min(), shortest > 0 else { return nil }
            let direction = edges[0].x * edges[1].y - edges[0].y * edges[1].x > 0 ? 1.0 : -1.0
            let normals = zip(edges, lengths).map { edge, length in
                Point(x: direction * edge.y / length, y: -direction * edge.x / length)
            }

            let expanded = grid.indices.compactMap { i -> Point? in
                let previous = normals[(i + grid.count - 1) % grid.count]
                let next = normals[i]
                let determinant = previous.x * next.y - previous.y * next.x
                guard determinant != 0 else { return nil }
                let dx = margin * (next.y - previous.y) / determinant
                let dy = margin * (previous.x - next.x) / determinant
                // Reject corners whose offset would require a bevel/spike.
                guard hypot(dx, dy) <= 5 * margin else { return nil }
                let x = (grid[i].x + dx) * pitchX
                let y = (grid[i].y + dy) * pitchY
                guard x >= 0, x <= Double(sourceWidth), y >= 0, y <= Double(sourceHeight) else { return nil }
                return Point(x: x, y: y)
            }
            let shape = Geometry.Shape(expanded)
            return shape.convex && shape.area > original.area ? (index, shape, shortest) : nil
        }.sorted { lhs, rhs in
            lhs.2 == rhs.2 ? lhs.0 < rhs.0 : lhs.2 < rhs.2
        }

        func overlap(_ first: Geometry.Shape, _ second: Geometry.Shape) -> Double {
            let iou = Geometry.intersectionIoU(first, second, minimum: 0)
            return iou * (first.area + second.area) / (1 + iou)
        }

        var selected: [(Int, Geometry.Shape)] = []
        for (index, expanded, _) in ranked {
            try cancellationCheck()
            let original = originals[index]
            guard originals.indices.allSatisfy({ peer in
                peer == index || overlap(expanded, originals[peer]) <= overlap(original, originals[peer]) + areaTolerance
            }), selected.allSatisfy({ peer in
                overlap(expanded, peer.1) <= overlap(original, originals[peer.0]) + areaTolerance
            }) else { continue }
            selected.append((index, expanded))
            if selected.count == maximumAlternateCellEnvelopes { break }
        }
        return Dictionary(uniqueKeysWithValues: selected.map { index, expanded in
            (index, expanded.polygon.map { CGPoint(x: $0.x, y: $0.y) })
        })
    }
}
