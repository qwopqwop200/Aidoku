import CoreGraphics
import Foundation

/// Reuses the RF result already obtained beside OCR. Does not own a detector,
/// file cache, RGB sampler or content admission policy.
enum NativeMainRFRegionAdapter {
    enum Failure: Error {
        case invalidSourceGeometry
        case sourceIdentityMismatch
    }

    struct Report {
        let regions: [Ensemble100RFRegion]
        let sourceIdentity: String
        let audit: [[String: Any]]
    }

    /// Parent's evidence-store lookup MUST use the identity of the same upright
    /// original pixels used to construct the Ensemble100Page. This overload
    /// preserves the fixed main API; use the checked overload at other callers.
    static func regions(from result: NativeRFDETRLayoutResult) throws -> [Ensemble100RFRegion] {
        try report(from: result).regions
    }

    /// Strong pixel binding for callers that have not already performed the
    /// identity-keyed store lookup. Reuses the existing canonical RGB decoder.
    static func regions(from result: NativeRFDETRLayoutResult, original: CGImage) throws -> [Ensemble100RFRegion] {
        try regions(from: result, source: NativeRFDETRSourceImage.decode(original))
    }

    /// Avoids another decode when the canonical original RGB buffer is shared.
    static func regions(from result: NativeRFDETRLayoutResult, source: NativeRFDETRSourceImage) throws -> [Ensemble100RFRegion] {
        guard source.width == result.sourceWidth, source.height == result.sourceHeight,
              source.identity == result.imageIdentity else { throw Failure.sourceIdentityMismatch }
        return try regions(from: result)
    }

    /// Explicit renderer-only opt-in. Existing regions()/report() callers,
    /// including source construction and removal-mask evidence, stay incumbent
    /// even when the process requests SIMPLE rendering geometry.
    static func rendererRegions(from result: NativeRFDETRLayoutResult, source: NativeRFDETRSourceImage) throws -> [Ensemble100RFRegion] {
        guard source.width == result.sourceWidth, source.height == result.sourceHeight,
              source.identity == result.imageIdentity else { throw Failure.sourceIdentityMismatch }
        return try rendererReport(from: result).regions
    }

    static func rendererReport(from result: NativeRFDETRLayoutResult) throws -> Report {
        try report(from: result, balloonDomainPolicy: NativeRFDETRBalloonDomainPolicy.configured())
    }

    /// Optional accounting API. A missing or unusable mask leaves the primitive
    /// present as a box with an EMPTY exterior; it never fabricates segmentation.
    static func report(from result: NativeRFDETRLayoutResult,
                       balloonDomainPolicy simple: NativeRFDETRBalloonDomainPolicy? = nil) throws -> Report {
        guard result.sourceWidth > 0, result.sourceHeight > 0,
              result.sourceWidth <= 16_384, result.sourceHeight <= 16_384,
              result.sourceWidth <= 16_777_216 / result.sourceHeight,
              !result.imageIdentity.isEmpty else { throw Failure.invalidSourceGeometry }
        var regions: [Ensemble100RFRegion] = [], audit: [[String: Any]] = []
        let primitives: [NativeRFDETRLayoutPrimitive]
        if let simple {
            primitives = result.primitives.filter { $0.semanticClass != .balloon } + (try simple.balloons(result))
        } else { primitives = result.primitives }
        for primitive in primitives {
            let confidence = primitive.confidence.isFinite && (0...1).contains(primitive.confidence)
                ? Double(primitive.confidence) : 0
            let box = validBox(primitive.normalizedBounds) ? primitive.normalizedBounds : .zero
            let maskThreshold: Float = primitive.semanticClass == .balloon ? (simple?.maskLogit ?? 0) : 0
            var record: [String: Any] = ["queryID": primitive.queryID,
                "classID": primitive.semanticClass.rawValue, "sourceIdentity": result.imageIdentity,
                "contourVerified": false, "modelEstimated": true]
            if primitive.semanticClass == .balloon, let simple {
                record["estimatedDomainPolicy"] = simple.cacheIdentity
                record["authority"] = "raw RF model estimate; not original-RGB/native-mask verification"
            }
            // Retain source-pixel evidence independently of polygon eligibility.
            // Capture the exact native bilinear sampler, including outside the box.
            let sourcePixelMask: Ensemble100RFSourcePixelMask?
            if let mask = primitive.mask, mask.queryID == primitive.queryID,
               mask.sourceWidth == result.sourceWidth, mask.sourceHeight == result.sourceHeight,
               mask.logits.count == NativeRFDETRLayoutResource.maskSide * NativeRFDETRLayoutResource.maskSide,
               mask.logits.allSatisfy(\.isFinite) {
                sourcePixelMask = Ensemble100RFSourcePixelMask(sourceIdentity: result.imageIdentity,
                    queryID: primitive.queryID, sourceWidth: result.sourceWidth, sourceHeight: result.sourceHeight,
                    sample: { mask.contains(sourceX: $0, sourceY: $1, decisionLogitThreshold: maskThreshold) })
            } else {
                sourcePixelMask = nil
            }
            func retainBox(_ reason: String) {
                regions.append(Ensemble100RFRegion(queryID: primitive.queryID,
                    classID: primitive.semanticClass.rawValue, confidence: confidence,
                    bounds: box, exterior: [], holes: [], sourcePixelMask: sourcePixelMask))
                record["status"] = reason
            }
            defer { audit.append(record) }
            guard confidence > 0, !box.isEmpty else { retainBox("invalid-confidence-or-box"); continue }
            // Actual RF taxonomy, never canonicalClassID. Text/SFX are boxes
            // for geometry even when source-pixel mask evidence is retained.
            guard primitive.semanticClass == .balloon || primitive.semanticClass == .frame else {
                retainBox("text-or-sfx-box-only")
                continue
            }
            guard let mask = primitive.mask else { retainBox("mask-unavailable-box-only"); continue }
            guard sourcePixelMask != nil else { retainBox("invalid-mask-box-only"); continue }
            guard let polygons = polygons(mask, decisionLogitThreshold: maskThreshold), !polygons.isEmpty else {
                retainBox("empty-or-topology-budget-mask-box-only")
                continue
            }
            for polygon in polygons {
                let xs = polygon.exterior.map(\.x), ys = polygon.exterior.map(\.y)
                let bounds = CGRect(x: xs.min()!, y: ys.min()!,
                    width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
                regions.append(Ensemble100RFRegion(queryID: primitive.queryID,
                    classID: primitive.semanticClass.rawValue, confidence: confidence,
                    bounds: bounds, exterior: polygon.exterior, holes: polygon.holes, sourcePixelMask: sourcePixelMask))
            }
            record["status"] = "native-mask-grid-contours"
            record["components"] = polygons.count
            record["holes"] = polygons.reduce(0) { $0 + $1.holes.count }
            record["authority"] = "thresholded native model-grid cell boundary; not source-pixel or glyph GT"
        }
        return Report(regions: regions, sourceIdentity: result.imageIdentity, audit: audit)
    }

    private static func validBox(_ box: CGRect) -> Bool {
        !box.isNull && !box.isInfinite && box.width > 0 && box.height > 0 &&
            [box.minX, box.minY, box.maxX, box.maxY].allSatisfy(\.isFinite)
    }

    private struct Polygon {
        let exterior: [CGPoint]
        var holes: [[CGPoint]]
        let area: Double
    }

    /// Trace directed cell edges with foreground on the right. A right-turn
    /// tie break separates diagonal components instead of joining their text.
    /// Native162 logits are converted to a cell-union model ESTIMATE; this is
    /// deliberately not claimed equivalent to source bilinear mask sampling.
    private static func polygons(_ mask: NativeRFDETRLayoutMask, decisionLogitThreshold: Float = 0) -> [Polygon]? {
        let side = NativeRFDETRLayoutResource.maskSide, stride = side + 1
        let cells = mask.logits.map { $0 > decisionLogitThreshold }
        var edges = [UInt8](repeating: 0, count: stride * stride)
        var edgeCount = 0
        func inside(_ x: Int, _ y: Int) -> Bool {
            x >= 0 && y >= 0 && x < side && y < side && cells[y * side + x]
        }
        func add(_ x: Int, _ y: Int, _ direction: Int) {
            edges[y * stride + x] |= UInt8(1 << direction)
            edgeCount += 1
        }
        for y in 0..<side {
            for x in 0..<side where inside(x, y) {
                if !inside(x, y - 1) { add(x, y, 0) }
                if !inside(x + 1, y) { add(x + 1, y, 1) }
                if !inside(x, y + 1) { add(x + 1, y + 1, 2) }
                if !inside(x - 1, y) { add(x, y + 1, 3) }
            }
        }
        let dx = [1, 0, -1, 0], dy = [0, 1, 0, -1]
        var rings: [([CGPoint], Double)] = [], vertexCount = 0
        for start in edges.indices {
            while edges[start] != 0 {
                guard rings.count < 512 else { return nil }
                var current = start
                var direction = (0..<4).first { edges[start] & UInt8(1 << $0) != 0 }!
                var vertices: [CGPoint] = []
                repeat {
                    guard edgeCount > 0, edges[current] & UInt8(1 << direction) != 0 else { return nil }
                    let x = current % stride, y = current / stride
                    vertices.append(CGPoint(x: Double(x) / Double(side), y: Double(y) / Double(side)))
                    edges[current] &= ~UInt8(1 << direction)
                    edgeCount -= 1
                    let nextX = x + dx[direction], nextY = y + dy[direction]
                    guard nextX >= 0, nextY >= 0, nextX <= side, nextY <= side else { return nil }
                    current = nextY * stride + nextX
                    if current == start { break }
                    let turns = [(direction + 1) % 4, direction, (direction + 3) % 4, (direction + 2) % 4]
                    guard let next = turns.first(where: { edges[current] & UInt8(1 << $0) != 0 }) else { return nil }
                    direction = next
                } while current != start
                let compact = corners(vertices)
                guard compact.count >= 4 else { return nil }
                vertexCount += compact.count
                guard compact.count <= 4096, vertexCount <= 8192 else { return nil }
                let area = signedArea(compact)
                guard abs(area) > 0 else { return nil }
                rings.append((compact, area))
            }
        }
        guard edgeCount == 0 else { return nil }
        var result = rings.filter { $0.1 > 0 }.map { Polygon(exterior: $0.0, holes: [], area: $0.1) }
        for (hole, area) in rings where area < 0 {
            // An interior point on the empty (left) side of this first edge.
            let a = hole[0], b = hole[1], length = hypot(b.x - a.x, b.y - a.y)
            let epsilon = 0.25 / Double(side)
            let point = CGPoint(x: (a.x + b.x) / 2 + (b.y - a.y) / length * epsilon,
                                y: (a.y + b.y) / 2 - (b.x - a.x) / length * epsilon)
            guard let owner = result.indices.filter({ contains(point, ring: result[$0].exterior) })
                .min(by: { result[$0].area < result[$1].area }) else { return nil }
            result[owner].holes.append(hole)
            guard result[owner].holes.count <= 128 else { return nil }
        }
        return result
    }

    private static func corners(_ ring: [CGPoint]) -> [CGPoint] {
        guard ring.count >= 3 else { return ring }
        return ring.indices.compactMap { i in
            let a = ring[(i + ring.count - 1) % ring.count], b = ring[i], c = ring[(i + 1) % ring.count]
            // Coordinates came from the same integer lattice, so comparing
            // equal x/y values loses no curvature or hole information.
            return (a.x == b.x && b.x == c.x) || (a.y == b.y && b.y == c.y) ? nil : b
        }
    }

    private static func signedArea(_ ring: [CGPoint]) -> Double {
        ring.indices.reduce(0) { sum, i in
            let a = ring[i], b = ring[(i + 1) % ring.count]
            return sum + (a.x * b.y - b.x * a.y) / 2
        }
    }

    private static func contains(_ point: CGPoint, ring: [CGPoint]) -> Bool {
        var inside = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > point.y) != (b.y > point.y),
               point.x < a.x + (b.x - a.x) * (point.y - a.y) / (b.y - a.y) { inside.toggle() }
        }
        return inside
    }
}
