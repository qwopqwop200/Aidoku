import Foundation

/// source55-v1 extraction from caller-owned evidence only. No labels, IDs, image decoding,
/// recognition, or pipeline hooks. Invalid/incomplete evidence returns nil for fail-open scoring.
enum NativeOCRPremergeCandidateFeatures {
    struct Point: Codable, Equatable, Sendable {
        let x: Double
        let y: Double
    }
    struct DetectorBox: Codable, Sendable {
        let polygon: [Point]
        let score: Double
    }
    struct MaskRun: Codable, Sendable {
        let y: Int
        let x0: Int
        let x1: Int
    }
    /// Positive native RF cells, compressed by row. This is a model-grid area
    /// measurement, not source-image pixels or bilinearly expanded mask gold.
    struct RFMask: Codable, Sendable {
        let sourceWidth: Int
        let sourceHeight: Int
        let side: Int
        let runs: [MaskRun]

        init?(sourceWidth: Int, sourceHeight: Int, side: Int, logits: [Float]) {
            guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 16_384, sourceHeight <= 16_384,
                  (1...256).contains(side), logits.count == side * side,
                  logits.allSatisfy(\.isFinite) else { return nil }
            self.sourceWidth = sourceWidth; self.sourceHeight = sourceHeight; self.side = side
            var spans: [MaskRun] = []
            for y in 0..<side {
                var x = 0
                while x < side {
                    if logits[y * side + x] <= 0 { x += 1; continue }
                    let start = x
                    while x < side && logits[y * side + x] > 0 { x += 1 }
                    spans.append(.init(y: y, x0: start, x1: x))
                }
            }
            self.runs = spans
        }

        var isValid: Bool {
            guard sourceWidth > 0, sourceHeight > 0, sourceWidth <= 16_384, sourceHeight <= 16_384,
                  (1...256).contains(side), runs.count <= side * ((side + 1) / 2) else { return false }
            var previousY = -1, previousEnd = -1
            for run in runs {
                guard run.y >= 0, run.y < side, run.x0 >= 0, run.x1 <= side, run.x0 < run.x1,
                      run.y > previousY || (run.y == previousY && run.x0 >= previousEnd) else { return false }
                previousY = run.y; previousEnd = run.x1
            }
            return true
        }
    }
    struct RFPrimitive: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let confidence: Double
        let semanticClass: Int
        var mask: RFMask? = nil
        var queryID: Int? = nil
    }
    /// A fresh raw decode of this exact final polygon. Tokens intentionally do not enter this schema.
    struct FreshRecognition: Codable, Sendable {
        let polygon: [Point]
        let text: String
        let confidence: Double
    }
    /// Top-left origin, interleaved 8-bit RGB or RGBA, original encoded sRGB (no linearization).
    /// A source window may be supplied instead of the whole frame; it must contain all required
    /// bilinear neighbors after original-frame BORDER_REPLICATE clamping. No crop-edge replication.
    struct RGBBuffer: Sendable {
        let width: Int
        let height: Int
        let bytesPerRow: Int
        let bytesPerPixel: Int
        let bytes: [UInt8]
        let frameWidth: Int
        let frameHeight: Int
        let originX: Int
        let originY: Int

        init?(width: Int, height: Int, bytesPerRow: Int? = nil, bytes: [UInt8], bytesPerPixel: Int = 3,
              frameWidth: Int? = nil, frameHeight: Int? = nil, originX: Int = 0, originY: Int = 0) {
            let fullWidth = frameWidth ?? width, fullHeight = frameHeight ?? height
            guard (bytesPerPixel == 3 || bytesPerPixel == 4),
                  width > 0, height > 0, fullWidth > 0, fullHeight > 0,
                  fullWidth <= 1_000_000, fullHeight <= 1_000_000,
                  originX >= 0, originY >= 0, width <= fullWidth, height <= fullHeight,
                  originX <= fullWidth - width, originY <= fullHeight - height else { return nil }
            let row = bytesPerRow ?? width * bytesPerPixel
            let required = row.multipliedReportingOverflow(by: height)
            guard row >= width * bytesPerPixel, !required.overflow, bytes.count >= required.partialValue else { return nil }
            self.width = width
            self.height = height
            self.bytesPerRow = row
            self.bytesPerPixel = bytesPerPixel
            self.bytes = bytes
            self.frameWidth = fullWidth
            self.frameHeight = fullHeight
            self.originX = originX
            self.originY = originY
        }
    }

    /// Checked once for a page's immutable original DET inventory, not per REC packet.
    struct DetectorInventory: Sendable {
        fileprivate let boxes: [DetectorBox]
        fileprivate let valid: Bool
    }

    static func prepareDetectorInventory(_ boxes: [DetectorBox]) -> DetectorInventory {
        .init(boxes: boxes, valid: boxes.count <= 100_000 &&
            boxes.allSatisfy { valid($0.polygon) && confidence($0.score) })
    }

    /// Source55 slots 8–12 without building unrelated RF or recognition features.
    static func detectorHead(polygon: [Point], baseline: [Point]?, inventory: DetectorInventory,
                             recognitionConfidence: Double) -> [Double]? {
        let reference = baseline ?? polygon
        guard inventory.valid, valid(polygon), valid(reference), confidence(recognitionConfidence) else { return nil }
        return detectorHeadValues(polygon: polygon, reference: reference, polygonArea: area(polygon), boxes: inventory.boxes)
    }

    private static func detectorHeadValues(polygon: [Point], reference: [Point], polygonArea: Double,
                                           boxes: [DetectorBox]) -> [Double] {
        var selected: DetectorBox?
        var best = -Double.infinity
        for detector in boxes {
            let overlap = iou(reference, detector.polygon)
            if overlap > best { best = overlap; selected = detector } // Python max keeps the first tie.
        }
        guard let selected, best >= 0.3 else { return Array(repeating: 0, count: 5) }
        let intersection = intersection(polygon, selected.polygon)
        return [1, selected.score, best, iou(polygon, selected.polygon), intersection / max(1e-12, polygonArea)]
    }

    static func extract(polygon: [Point], baseline: [Point]?, detectorBoxes: [DetectorBox],
                        rfPrimitives: [RFPrimitive], recognition: FreshRecognition?, frame: RGBBuffer? = nil,
                        signalsOnly: Bool = false, useRFMaskOverlap: Bool = false) -> [Double]? {
        let reference = baseline ?? polygon
        guard valid(polygon), valid(reference), detectorBoxes.count <= 100_000, rfPrimitives.count <= 100_000,
              let recognition, recognition.polygon == polygon, confidence(recognition.confidence),
              detectorBoxes.allSatisfy({ valid($0.polygon) && confidence($0.score) }),
              rfPrimitives.allSatisfy({ primitive in
                  [primitive.x, primitive.y, primitive.width, primitive.height].allSatisfy { $0.isFinite && abs($0) <= 1e7 }
                    && primitive.width > 0 && primitive.height > 0 && confidence(primitive.confidence)
                    && (0...3).contains(primitive.semanticClass)
              }) else { return nil }
        let polygonArea = area(polygon)
        let maskPolygon = useRFMaskOverlap ? MaskPolygon(validated: polygon, area: polygonArea) : nil
        var values = Array(repeating: 0.0, count: 8)
        var fullBasis: Basis?
        if !signalsOnly {
            guard let frame, let basis = basis(polygon) else { return nil }
            fullBasis = basis
            let short = basis.high.x - basis.low.x, long = basis.high.y - basis.low.y
            let diagonal = hypot(Double(frame.frameWidth), Double(frame.frameHeight))
            values = [log(max(1e-9, short)), log(max(1e-9, long)), log(max(1e-9, long / short)),
                      polygonArea / (Double(frame.frameWidth) * Double(frame.frameHeight)),
                      2 * basis.axis.x * basis.axis.y, basis.axis.x * basis.axis.x - basis.axis.y * basis.axis.y,
                      short / diagonal, long / diagonal]
        }
        values += detectorHeadValues(polygon: polygon, reference: reference, polygonArea: polygonArea, boxes: detectorBoxes)
        for semanticClass in 0..<4 {
            var maxima = [0.0, 0, 0, 0]
            for primitive in rfPrimitives where primitive.semanticClass == semanticClass {
                let overlap: Double
                let supportArea: Double
                if let maskPolygon {
                    // Missing/invalid semantic masks never become negative evidence.
                    guard let mask = primitive.mask, mask.isValid else { return nil }
                    overlap = maskPolygon.intersection(withValidated: mask)
                    let sx = Double(mask.sourceWidth) / Double(mask.side)
                    let sy = Double(mask.sourceHeight) / Double(mask.side)
                    supportArea = mask.runs.reduce(0) { $0 + Double($1.x1 - $1.x0) * sx * sy }
                } else {
                    overlap = rectangleIntersection(polygon, primitive)
                    supportArea = primitive.width * primitive.height
                }
                let coverage = min(1, overlap / max(1e-12, polygonArea))
                let features = [primitive.confidence * coverage, coverage,
                                overlap / max(1e-12, polygonArea + supportArea - overlap),
                                coverage >= 0.5 ? primitive.confidence : 0]
                for index in 0..<4 { maxima[index] = max(maxima[index], features[index]) }
            }
            values += maxima
        }
        if signalsOnly {
            // Emptiness is validity, not a length/script/token feature. No pixel reads.
            let nonempty = recognition.text.unicodeScalars.contains {
                !$0.properties.isWhitespace && !(0x1C...0x1F).contains($0.value)
            }
            values += [1, nonempty ? recognition.confidence : 0] + Array(repeating: 0.0, count: 24)
        } else {
            guard let frame, let rec = recognitionFeatures(recognition), let fullBasis,
                  let pixel = pixels(frame, fullBasis) else { return nil }
            values += rec + pixel
        }
        guard values.count == 55, values.allSatisfy(\.isFinite) else { return nil }
        return values
    }

    /// fresh-rec-all14729/pipeline.py: NFKC, Python scalar (not grapheme) counts,
    /// Python isspace/isdigit, no stale tokens, and all three same-polygon association fields = 1.
    static func recognitionFeatures(_ recognition: FreshRecognition) -> [Double]? {
        guard confidence(recognition.confidence), recognition.text.utf8.count <= 1_000_000 else { return nil }
        let scalars = recognition.text.precomposedStringWithCompatibilityMapping
            .precomposedStringWithCanonicalMapping.unicodeScalars.filter {
            !$0.properties.isWhitespace && !(0x1C...0x1F).contains($0.value)
        }
        let length = scalars.count, denominator = Double(max(1, length))
        var counts: [UInt32: Int] = [:], order: [UInt32] = []
        for scalar in scalars {
            if counts[scalar.value] == nil { order.append(scalar.value) }
            counts[scalar.value, default: 0] += 1
        }
        func fraction(_ predicate: (Unicode.Scalar) -> Bool) -> Double {
            Double(scalars.filter(predicate).count) / denominator
        }
        var entropy = 0.0
        for scalar in order {
            let probability = Double(counts[scalar]!) / denominator
            entropy -= probability * log(probability)
        }
        entropy /= max(1, log(Double(max(2, length))))
        let punctuation = !scalars.isEmpty && scalars.allSatisfy { $0 == "?" || $0 == "!" }
        return [1, length > 0 ? recognition.confidence : 0, log1p(Double(length)),
                fraction { (0x3040...0x309F).contains($0.value) },
                fraction { (0x30A0...0x30FF).contains($0.value) },
                fraction { (0x3400...0x9FFF).contains($0.value) },
                fraction { (65...90).contains($0.value) || (97...122).contains($0.value) },
                fraction { $0.properties.numericType == .decimal || $0.properties.numericType == .digit },
                fraction { isPunctuation($0.properties.generalCategory) },
                Double(counts.values.max() ?? 0) / denominator, entropy,
                0, 0, 0, length == 0 ? 1 : 0, punctuation ? 1 : 0,
                fraction { isSymbol($0.properties.generalCategory) }, 1, 1, 1]
    }

    private static func confidence(_ value: Double) -> Bool { value.isFinite && (0...1).contains(value) }
    private static func isPunctuation(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation,
             .initialPunctuation, .finalPunctuation, .otherPunctuation: return true
        default: return false
        }
    }
    private static func isSymbol(_ category: Unicode.GeneralCategory) -> Bool {
        switch category {
        case .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol: return true
        default: return false
        }
    }
    private static func signedArea(_ polygon: [Point]) -> Double {
        polygon.indices.reduce(0) { sum, index in
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            return sum + (a.x * b.y - b.x * a.y)
        } / 2
    }
    private static func area(_ polygon: [Point]) -> Double { abs(signedArea(polygon)) }
    private static func cross(_ a: Point, _ b: Point, _ p: Point) -> Double {
        (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x)
    }
    private static func valid(_ polygon: [Point]) -> Bool {
        guard (3...64).contains(polygon.count),
              polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite && abs($0.x) <= 1e7 && abs($0.y) <= 1e7 }),
              area(polygon) > 1e-9 else { return false }
        let sign = signedArea(polygon) > 0 ? 1.0 : -1.0
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            guard hypot(b.x - a.x, b.y - a.y) > 1e-9 else { return false }
            // Every vertex must lie inside every oriented edge (also rejects self-intersection).
            for point in polygon where sign * cross(a, b, point) < -1e-8 { return false }
        }
        return true
    }
    private struct Basis {
        let center: Point
        let axis: Point
        let normal: Point
        let low: Point
        let high: Point
    }
    private static func basis(_ polygon: [Point]) -> Basis? {
        var axis = Point(x: 0, y: 0), longest = -Double.infinity
        for index in polygon.indices {
            let a = polygon[index], b = polygon[(index + 1) % polygon.count]
            let length = hypot(b.x - a.x, b.y - a.y)
            if length > longest { longest = length; axis = Point(x: b.x - a.x, y: b.y - a.y) }
        }
        let norm = sqrt(axis.x * axis.x + axis.y * axis.y)
        guard norm > 0 else { return nil }
        axis = Point(x: axis.x / norm, y: axis.y / norm)
        if axis.y < 0 || (axis.y == 0 && axis.x < 0) { axis = Point(x: -axis.x, y: -axis.y) }
        let normal = Point(x: axis.y, y: -axis.x)
        let center = Point(x: polygon.map(\.x).reduce(0, +) / Double(polygon.count),
                           y: polygon.map(\.y).reduce(0, +) / Double(polygon.count))
        let projections = polygon.map { p in
            Point(x: (p.x - center.x) * normal.x + (p.y - center.y) * normal.y,
                  y: (p.x - center.x) * axis.x + (p.y - center.y) * axis.y)
        }
        let low = Point(x: projections.map(\.x).min()!, y: projections.map(\.y).min()!)
        let high = Point(x: projections.map(\.x).max()!, y: projections.map(\.y).max()!)
        guard high.x > low.x, high.y > low.y else { return nil }
        return Basis(center: center, axis: axis, normal: normal, low: low, high: high)
    }

    // Double-precision convex clipping. Unlike OpenCV's intersectConvexConvex float32
    // implementation, this avoids geometric cancellation; compare with explicit tolerance.
    private static func intersection(_ polygon: [Point], _ clip: [Point]) -> Double {
        var result = polygon
        let sign = signedArea(clip) > 0 ? 1.0 : -1.0
        for index in clip.indices {
            let a = clip[index], b = clip[(index + 1) % clip.count]
            let input = result
            result = []
            if input.isEmpty { return 0 }
            for index in input.indices {
                let p = input[index], q = input[(index + 1) % input.count]
                let dp = sign * cross(a, b, p), dq = sign * cross(a, b, q)
                if dp >= 0 { result.append(p) }
                if (dp >= 0) != (dq >= 0) {
                    let t = dp / (dp - dq)
                    result.append(Point(x: p.x + t * (q.x - p.x), y: p.y + t * (q.y - p.y)))
                }
            }
        }
        return area(result)
    }
    private static func iou(_ a: [Point], _ b: [Point]) -> Double {
        let overlap = intersection(a, b)
        return overlap / max(1e-12, area(a) + area(b) - overlap)
    }
    /// Preserve prepare.py's axis-clipping order and inside convention for RF rectangles.
    private static func rectangleIntersection(_ polygon: [Point], _ rect: RFPrimitive) -> Double {
        let strip = rfColumnClip(polygon, x: rect.x, width: rect.width)
        var lower: [Point] = [], clipped: [Point] = []
        return rfColumnOverlap(strip, y: rect.y, height: rect.height, lower: &lower, clipped: &clipped)
    }

    /// Every cell in a mask-grid column shares the first two clipping planes.
    static func rfColumnClip(_ polygon: [Point], x: Double, width: Double) -> [Point] {
        var left: [Point] = [], strip: [Point] = []
        clip(polygon, vertical: true, edge: x, sign: -1, into: &left)
        clip(left, vertical: true, edge: x + width, sign: 1, into: &strip)
        return strip
    }

    static func rfColumnOverlap(_ strip: [Point], y: Double, height: Double,
                                lower: inout [Point], clipped: inout [Point]) -> Double {
        clip(strip, vertical: false, edge: y, sign: -1, into: &lower)
        clip(lower, vertical: false, edge: y + height, sign: 1, into: &clipped)
        return area(clipped)
    }

    private static func clip(_ input: [Point], vertical: Bool, edge: Double, sign: Double, into result: inout [Point]) {
        result.removeAll(keepingCapacity: true)
        guard var a = input.first else { return }
        var da = sign * ((vertical ? a.x : a.y) - edge)
        for next in 1...input.count {
            let b = input[next == input.count ? 0 : next]
            let db = sign * ((vertical ? b.x : b.y) - edge)
            if da <= 0 { result.append(a) }
            if (da <= 0) != (db <= 0) {
                let t = da / (da - db)
                result.append(Point(x: a.x + t * (b.x - a.x), y: a.y + t * (b.y - a.y)))
            }
            a = b; da = db
        }
    }

    /// Shared geometric seam for supplementary RF spatial evidence. These are
    /// polygon/mask overlaps, not source-image pixel or bbox-shape predictors.
    static func rfRectangleOverlap(_ polygon: [Point], x: Double, y: Double, width: Double, height: Double) -> Double {
        rectangleIntersection(polygon, .init(x: x, y: y, width: width, height: height, confidence: 1, semanticClass: 0))
    }
    static func rfPolygonArea(_ polygon: [Point]) -> Double { area(polygon) }
    static func polygonOverlap(_ first: [Point], _ second: [Point]) -> (iou: Double, firstCoverage: Double, secondCoverage: Double)? {
        guard valid(first), valid(second) else { return nil }
        let a = area(first), b = area(second)
        let overlap = max(0, min(intersection(first, second), min(a, b)))
        return (overlap / max(1e-12, a + b - overlap), overlap / a, overlap / b)
    }
    static func rfMaskOverlap(_ polygon: [Point], mask: RFMask) -> Double? {
        guard mask.isValid, let footprint = MaskPolygon(polygon) else { return nil }
        return footprint.coverage(withValidated: mask)
    }

    /// Each immutable OCR footprint is tested against several prevalidated RF masks.
    struct MaskPolygon {
        private let polygon: [Point]
        private let area: Double
        private let left, right, top, bottom: Double

        init?(_ polygon: [Point]) {
            guard NativeOCRPremergeCandidateFeatures.valid(polygon) else { return nil }
            self.init(validated: polygon, area: NativeOCRPremergeCandidateFeatures.area(polygon))
        }

        fileprivate init(validated polygon: [Point], area: Double) {
            self.polygon = polygon
            self.area = area
            var left = polygon[0].x, right = left, top = polygon[0].y, bottom = top
            for point in polygon.dropFirst() {
                left = min(left, point.x); right = max(right, point.x)
                top = min(top, point.y); bottom = max(bottom, point.y)
            }
            self.left = left; self.right = right; self.top = top; self.bottom = bottom
        }

        func coverage(withValidated mask: RFMask) -> Double {
            intersection(withValidated: mask) / max(1e-12, area)
        }

        fileprivate func intersection(withValidated mask: RFMask) -> Double {
            let sx = Double(mask.sourceWidth) / Double(mask.side), sy = Double(mask.sourceHeight) / Double(mask.side)
            let runs = mask.runs
            var low = 0, high = runs.count
            while low < high {
                let mid = low + (high - low) / 2
                if Double(runs[mid].y) * sy + sy <= top { low = mid + 1 } else { high = mid }
            }
            var overlap = 0.0
            var previousStart = -1, previousEnd = -1
            var strip: [Point] = [], lower: [Point] = [], clipped: [Point] = []
            for run in runs[low...] {
                let y = Double(run.y) * sy
                if y >= bottom { break }
                let x = Double(run.x0) * sx, width = Double(run.x1 - run.x0) * sx
                guard x < right, x + width > left else { continue }
                if previousStart != run.x0 || previousEnd != run.x1 {
                    strip = rfColumnClip(polygon, x: x, width: width)
                    previousStart = run.x0; previousEnd = run.x1
                }
                overlap += rfColumnOverlap(strip, y: y, height: sy, lower: &lower, clipped: &clipped)
            }
            return min(area, max(0, overlap))
        }
    }

    private static func pixels(_ frame: RGBBuffer, _ basis: Basis) -> [Double]? {
        var patch = [[Double]]()
        patch.reserveCapacity(2048)
        let stepU = (basis.high.x - basis.low.x) / 31, stepV = (basis.high.y - basis.low.y) / 63
        for row in 0..<64 {
            let v = row == 63 ? basis.high.y : basis.low.y + Double(row) * stepV
            for column in 0..<32 {
                let u = column == 31 ? basis.high.x : basis.low.x + Double(column) * stepU
                let x = basis.center.x + u * basis.normal.x + v * basis.axis.x
                let y = basis.center.y + u * basis.normal.y + v * basis.axis.y
                // OpenCV maps first cast to float32, then cvRound(coord * INTER_TAB_SIZE).
                let fixedX = Int((Float(x) * 32).rounded(.toNearestOrEven))
                let fixedY = Int((Float(y) * 32).rounded(.toNearestOrEven))
                let ix = fixedX >> 5, iy = fixedY >> 5, fx = fixedX & 31, fy = fixedY & 31
                let weights = [(32 - fx) * (32 - fy), fx * (32 - fy), (32 - fx) * fy, fx * fy]
                var rgb = [0.0, 0, 0]
                for (neighbor, delta) in [(0, (0, 0)), (1, (1, 0)), (2, (0, 1)), (3, (1, 1))] {
                    let sx = min(frame.frameWidth - 1, max(0, ix + delta.0)) - frame.originX
                    let sy = min(frame.frameHeight - 1, max(0, iy + delta.1)) - frame.originY
                    guard sx >= 0, sy >= 0, sx < frame.width, sy < frame.height else { return nil }
                    let offset = sy * frame.bytesPerRow + sx * frame.bytesPerPixel
                    for channel in 0..<3 { rgb[channel] += Double(weights[neighbor] * Int(frame.bytes[offset + channel])) }
                }
                // OpenCV uint8 INTER_LINEAR uses fixed-point half-up output rounding.
                patch.append(rgb.map { floor(($0 + 512) / 1024) / 255 })
            }
        }
        let gray = patch.map { ($0[0] + $0[1] + $0[2]) / 3 }
        var border = Array(patch[0..<32]) + Array(patch[(63 * 32)..<(64 * 32)])
        border += (0..<64).map { patch[$0 * 32] }
        border += (0..<64).map { patch[$0 * 32 + 31] }
        let background = (0..<3).map { channel -> Double in
            let sorted = border.map { $0[channel] }.sorted()
            return (sorted[95] + sorted[96]) / 2
        }
        func standardDeviation(_ values: [Double]) -> Double {
            let mean = values.reduce(0, +) / Double(values.count)
            return sqrt(values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / Double(values.count))
        }
        var gradient = 0.0
        for row in 0..<63 { for column in 0..<32 { gradient += abs(gray[(row + 1) * 32 + column] - gray[row * 32 + column]) } }
        for row in 0..<64 { for column in 0..<31 { gradient += abs(gray[row * 32 + column + 1] - gray[row * 32 + column]) } }
        var contrast = 0, saturation = 0.0
        var histogram = Array(repeating: 0, count: 16)
        for (index, rgb) in patch.enumerated() {
            let difference = (0..<3).map { abs(rgb[$0] - background[$0]) }.max()!
            if difference > 32.0 / 255 { contrast += 1 }
            saturation += rgb.max()! - rgb.min()!
            histogram[min(15, Int(gray[index] * 16))] += 1
        }
        var entropy = 0.0
        for count in histogram where count > 0 {
            let probability = Double(count) / 2048
            entropy -= probability * log(probability)
        }
        let borderGray = border.map { ($0[0] + $0[1] + $0[2]) / 3 }
        return [standardDeviation(gray), gradient / Double(63 * 32 + 64 * 31), Double(contrast) / 2048,
                saturation / 2048, standardDeviation(borderGray), entropy / log(16)]
    }
}
