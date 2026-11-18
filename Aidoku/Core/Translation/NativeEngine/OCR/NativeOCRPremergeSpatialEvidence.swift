import Foundation

/// RF hypothesis and model-mask measurements only. No source raster, shape,
/// text content, target inventory, page ID or learned per-image state enters it.
struct NativeOCRPremergeSpatialEvidence: Sendable {
    typealias F = NativeOCRPremergeCandidateFeatures
    struct Query: Codable, Sendable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
        let probabilities: [Double]
        var queryID: Int? = nil
    }
    static let featureNames = ["rawTextSupport", "rawSFXSupport", "rawTextShare",
        "maskTextOnlyCoverage", "maskSFXOnlyCoverage", "maskConflictCoverage", "maskTextSFXUnionCoverage",
        "maskSFXShare", "maskTextShare", "maskSFXConfidenceMean", "balloonInteriorCoverage",
        "balloonBoundaryCoverage", "frameInteriorCoverage", "frameBoundaryCoverage"]
    private let width: Int
    private let height: Int
    private let queries: [Query]
    private let grids: [[Double]]
    private let boundaries: [[Bool]]
    private static let side = 162

    init?(width: Int, height: Int, primitives: [F.RFPrimitive], queries: [Query]) {
        guard width > 0, height > 0, width <= 16_384, height <= 16_384,
              queries.count == 300, primitives.count <= 160,
              queries.allSatisfy({ q in
                  [q.x, q.y, q.width, q.height].allSatisfy { $0.isFinite && abs($0) <= 1e7 } &&
                  q.width >= 0 && q.height >= 0 && q.probabilities.count == 5 &&
                  q.probabilities.allSatisfy { $0.isFinite && (0...1).contains($0) }
              }) else { return nil }
        let side = Self.side
        var grids = Array(repeating: Array(repeating: 0.0, count: side * side), count: 4)
        for primitive in primitives {
            guard (0..<4).contains(primitive.semanticClass), primitive.confidence.isFinite,
                  (0...1).contains(primitive.confidence), let mask = primitive.mask, mask.isValid,
                  mask.side == side, mask.sourceWidth == width, mask.sourceHeight == height else { return nil }
            grids[primitive.semanticClass].withUnsafeMutableBufferPointer { grid in
                for run in mask.runs {
                    let row = run.y * side
                    for i in (row + run.x0)..<(row + run.x1) {
                        grid[i] = max(grid[i], primitive.confidence)
                    }
                }
            }
        }
        var boundaries = Array(repeating: Array(repeating: false, count: side * side), count: 2)
        for c in 2..<4 {
            for y in 0..<side {
                for x in 0..<side where grids[c][y * side + x] > 0 {
                    boundaries[c - 2][y * side + x] = x == 0 || y == 0 || x == side - 1 || y == side - 1 ||
                        grids[c][y * side + max(0, x - 1)] == 0 || grids[c][y * side + min(side - 1, x + 1)] == 0 ||
                        grids[c][max(0, y - 1) * side + x] == 0 || grids[c][min(side - 1, y + 1) * side + x] == 0
                }
            }
        }
        self.width = width; self.height = height; self.queries = queries
        self.grids = grids; self.boundaries = boundaries
    }

    func extract(polygon: [F.Point]) -> [Double]? {
        guard (3...64).contains(polygon.count), polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let area = F.rfPolygonArea(polygon)
        guard area > 1e-9 else { return nil }
        var left = polygon[0].x, right = left, top = polygon[0].y, bottom = top
        for point in polygon.dropFirst() {
            left = min(left, point.x); right = max(right, point.x)
            top = min(top, point.y); bottom = max(bottom, point.y)
        }
        var text = 0.0, sfx = 0.0
        for q in queries where q.width > 0 && q.height > 0 {
            // Coverage is at most one, so neither score can improve its maximum here.
            guard q.probabilities[0] > text || q.probabilities[1] > sfx else { continue }
            guard q.x <= right, q.x + q.width >= left, q.y <= bottom, q.y + q.height >= top else { continue }
            let coverage = min(1, F.rfRectangleOverlap(polygon, x: q.x, y: q.y, width: q.width, height: q.height) / area)
            text = max(text, q.probabilities[0] * coverage)
            sfx = max(sfx, q.probabilities[1] * coverage)
        }
        let side = Self.side, sx = Double(width) / Double(Self.side), sy = Double(height) / Double(Self.side)
        func low(_ value: Double, _ scale: Double) -> Int { Int(max(0, min(Double(side), floor(value / scale)))) }
        func high(_ value: Double, _ scale: Double) -> Int { Int(max(0, min(Double(side), ceil(value / scale)))) }
        let x0 = low(left, sx), x1 = high(right, sx)
        let y0 = low(top, sy), y1 = high(bottom, sy)
        var textOnly = 0.0, sfxOnly = 0.0, conflict = 0.0, union = 0.0, sfxArea = 0.0, sfxMass = 0.0
        var balloon = 0.0, balloonEdge = 0.0, frame = 0.0, frameEdge = 0.0
        if x0 < x1 && y0 < y1 {
            var strips = [[F.Point]?](repeating: nil, count: x1 - x0)
            var lower: [F.Point] = [], clipped: [F.Point] = []
            for y in y0..<y1 {
                for x in x0..<x1 {
                    let i = y * side + x
                    if grids.allSatisfy({ $0[i] == 0 }) { continue }
                    let column = x - x0
                    if strips[column] == nil {
                        strips[column] = F.rfColumnClip(polygon, x: Double(x) * sx, width: sx)
                    }
                    let a = F.rfColumnOverlap(strips[column]!, y: Double(y) * sy, height: sy,
                                              lower: &lower, clipped: &clipped)
                    let t = grids[0][i] > 0, s = grids[1][i] > 0
                    if t || s { union += a }
                    if t && !s { textOnly += a }
                    if s && !t { sfxOnly += a }
                    if t && s { conflict += a }
                    if s { sfxArea += a; sfxMass += a * grids[1][i] }
                    if grids[2][i] > 0 { balloon += a }
                    if boundaries[0][i] { balloonEdge += a }
                    if grids[3][i] > 0 { frame += a }
                    if boundaries[1][i] { frameEdge += a }
                }
            }
        }
        let result = [text, sfx, text / max(1e-12, text + sfx), textOnly / area, sfxOnly / area,
            conflict / area, union / area, sfxOnly / max(1e-12, union), textOnly / max(1e-12, union),
            sfxMass / max(1e-12, sfxArea), balloon / area, balloonEdge / area, frame / area, frameEdge / area]
        guard result.allSatisfy(\.isFinite) else { return nil }
        return result.map { max(0, min(1, $0)) }
    }
}
