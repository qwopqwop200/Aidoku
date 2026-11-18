import Foundation
import CoreGraphics

/// Runtime owned-cell centroid/rail/PCA producer, matching the cheaper Python v1.
/// No page/GT/catalog/text/confidence inputs, angle grid, image sampling or AABB fit.
/// The caller retains all originals/corrections/layouts and supplies these ONLY
/// to V3's explicit refinement input. V2 sourceLayout is never used for fits.
@available(iOS 18.0, *)
enum NativeOCROwnedAxisGeometry {
    typealias G = NativeOCRIndividualGeometryHypotheses

    struct RailFit: Codable, Equatable, Sendable {
        let slope: Double
        let intercept: Double
        let rms: Double
    }

    struct BandProof: Codable, Equatable, Sendable {
        let along: Double
        let centroidNormal: Double
        let leftNormal: Double
        let rightNormal: Double
        let cells: Int
    }

    /// Actual source/cell proof stays separate from the V3 emitter record.
    /// No process-global proof cache: page workers can call this concurrently.
    struct SourceProof: Codable, Equatable, Sendable {
        let producer: String
        let ownerID: String
        let originalDetectorIndex: Int
        let componentSeeds: [Int]
        let mapOriginX: Int
        let mapOriginY: Int
        let mapFullWidth: Int
        let mapFullHeight: Int
        let sourceWidth: Int
        let sourceHeight: Int
        let runCoordinateContract: String
        let originalPolygon: [G.Point]
        let ownedCells: Int
        let ownedSpanFraction: Double
        let normalWidth: Double
        let alongLength: Double
        let normalCellHalfExtent: Double
        let bands: [BandProof]
        let centroid: RailFit
        let rail: RailFit
        let left: RailFit
        let right: RailFit
        let pcaLocalAngleRadians: Double
        let centroidLocalAngleRadians: Double
        let appliedImageRotationRadians: Double
        let normalTranslationPixels: Double
        let axisDisagreementNormalPixels: [Double]
        let axisDisagreementTolerance: Double
        let freelyTranslatedAxisRMS: Double
        let fittedCentroidRMS: Double
        let residualImprovement: Double
        let requiredResidualImprovement: Double
    }

    struct Measurement: Codable, Equatable, Sendable {
        let refinement: G.Refinement
        let proof: SourceProof
    }

    /// Exact parent-requested call interface. Invoke only in explicit mode V3.
    static func refinements(
        requestID: String,
        originals: [NativeCoreMLDetectionBox],
        width: Int,
        height: Int
    ) -> [NativeOCRIndividualGeometryHypotheses.Refinement] {
        measurements(requestID: requestID, originals: originals, width: width, height: height)
            .map(\.refinement)
    }

    /// Host/stage capture may call this once and serialize proof while passing
    /// .map(\.refinement) to V3. No duplicate fit or mutable static state needed.
    static func measurements(
        requestID: String,
        originals: [NativeCoreMLDetectionBox],
        width: Int,
        height: Int
    ) -> [Measurement] {
        guard !requestID.isEmpty, width > 0, height > 0 else { return [] }
        var ownerCounts: [String: Int] = [:]
        for original in originals {
            if let seed = original.detectorSeedEvidence {
                ownerCounts[seed.ownerID, default: 0] += 1
            }
        }
        var result: [Measurement] = []
        for (index, original) in originals.enumerated() {
            guard let seed = original.detectorSeedEvidence,
                  ownerCounts[seed.ownerID] == 1,
                  // parentBoxIndex is the detector's pre-sort inventory. The
                  // immutable raw array position supplies output ancestry; the
                  // exact unique owner packet supplies its owned-cell evidence.
                  let value = measure(requestID: requestID, index: index,
                                      polygon: original.polygon, seed: seed,
                                      width: width, height: height) else { continue }
            result.append(value) // Exactly ONE fitted geometry per unique owner.
        }
        return result
    }

    private struct V {
        var x: Double
        var y: Double
        static func + (a: V, b: V) -> V { V(x: a.x + b.x, y: a.y + b.y) }
        static func - (a: V, b: V) -> V { V(x: a.x - b.x, y: a.y - b.y) }
        static func * (a: V, b: Double) -> V { V(x: a.x * b, y: a.y * b) }
        var length: Double { hypot(x, y) }
        func dot(_ other: V) -> Double { x * other.x + y * other.y }
        var point: G.Point { G.Point(x: x, y: y) }
    }

    private struct Sample {
        let t: Double
        let n: Double
    }

    private struct Basis {
        let q: [V]
        let center: V
        let normal: V
        let along: V
        let width: Double
        let length: Double

        init?(_ polygon: [CGPoint]) {
            let q = polygon.map { V(x: Double($0.x), y: Double($0.y)) }
            guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
            let turns = (0..<4).map { i -> Double in
                let a = q[(i + 1) % 4] - q[i]
                let b = q[(i + 2) % 4] - q[(i + 1) % 4]
                return a.x * b.y - a.y * b.x
            }
            guard turns.allSatisfy({ $0 > 0 }) || turns.allSatisfy({ $0 < 0 }) else { return nil }
            let first = q[1] - q[0]
            let other = q[3] - q[0]
            let vector = first.length >= other.length
                ? first + (q[2] - q[3]) : other + (q[2] - q[1])
            guard vector.length > 0, vector.length.isFinite else { return nil }
            let along = vector * (1 / vector.length)
            let normal = V(x: along.y, y: -along.x)
            let center = V(x: q.reduce(0) { $0 + $1.x } / 4,
                           y: q.reduce(0) { $0 + $1.y } / 4)
            let ns = q.map { ($0 - center).dot(normal) }
            let ts = q.map { ($0 - center).dot(along) }
            let width = ns.max()! - ns.min()!
            let length = ts.max()! - ts.min()!
            guard width > 0, length > 0, width.isFinite, length.isFinite else { return nil }
            self.q = q
            self.center = center
            self.normal = normal
            self.along = along
            self.width = width
            self.length = length
        }
    }

    private static func median(_ values: [Double]) -> Double {
        let a = values.sorted()
        let n = a.count
        return n.isMultiple(of: 2) ? (a[n / 2 - 1] + a[n / 2]) / 2 : a[n / 2]
    }

    private static func fit(_ points: [Sample], span: Double) -> RailFit? {
        var slopes: [Double] = []
        for i in points.indices {
            for j in points.indices where j > i {
                let dx = points[j].t - points[i].t
                if abs(dx) >= span * 0.20 {
                    slopes.append((points[j].n - points[i].n) / dx)
                }
            }
        }
        guard !slopes.isEmpty else { return nil }
        let slope = median(slopes)
        let intercept = median(points.map { $0.n - slope * $0.t })
        let square = points.reduce(0.0) { sum, p in
            let r = p.n - slope * p.t - intercept
            return sum + r * r
        }
        let rms = sqrt(square / Double(points.count))
        guard slope.isFinite, intercept.isFinite, rms.isFinite else { return nil }
        return RailFit(slope: slope, intercept: intercept, rms: rms)
    }

    private static func measure(
        requestID: String, index: Int, polygon: [CGPoint],
        seed: NativeOCRDetectorSeedEvidence, width: Int, height: Int
    ) -> Measurement? {
        guard seed.isValid, seed.completeCCScan == true,
              (seed.candidateComponents ?? []).isEmpty,
              (seed.ambiguousComponents ?? []).isEmpty,
              !seed.components.isEmpty,
              seed.sourceWidth == width, seed.sourceHeight == height,
              let b = Basis(polygon), b.length / b.width >= 3 else { return nil }

        let sx = Double(width) / Double(seed.mapFullWidth)
        let sy = Double(height) / Double(seed.mapFullHeight)
        var observations: [Sample] = []
        observations.reserveCapacity(seed.components.reduce(0) { $0 + $1.pixelCount })
        for component in seed.components {
            for run in component.runs {
                // IMPORTANT: x/y are ALREADY full detector-grid coordinates.
                // seed.mapOriginX/Y constrain validity only. Never add them.
                let y = (Double(run.y) + 0.5) * sy
                for x in run.x..<(run.x + run.count) {
                    let rel = V(x: (Double(x) + 0.5) * sx, y: y) - b.center
                    observations.append(Sample(t: rel.dot(b.along), n: rel.dot(b.normal)))
                }
            }
        }
        guard observations.count >= 16 else { return nil }
        let low = observations.map(\.t).min()!
        let high = observations.map(\.t).max()!
        let span = high - low
        guard span > 0, span / b.length >= 0.60 else { return nil }
        var bands = Array(repeating: [Sample](), count: 16)
        for p in observations {
            let bucket = min(15, max(0, Int(16 * (p.t - low) / span)))
            bands[bucket].append(p)
        }
        var centroids: [Sample] = [], rails: [Sample] = []
        var lefts: [Sample] = [], rights: [Sample] = []
        var bandProof: [BandProof] = []
        for band in bands where band.count >= 3 {
            let t = band.reduce(0.0) { $0 + $1.t } / Double(band.count)
            let n = band.reduce(0.0) { $0 + $1.n } / Double(band.count)
            let left = band.map(\.n).min()!, right = band.map(\.n).max()!
            centroids.append(Sample(t: t, n: n))
            rails.append(Sample(t: t, n: (left + right) / 2))
            lefts.append(Sample(t: t, n: left)); rights.append(Sample(t: t, n: right))
            bandProof.append(BandProof(along: t, centroidNormal: n,
                                       leftNormal: left, rightNormal: right, cells: band.count))
        }
        guard centroids.count >= 8,
              let centroid = fit(centroids, span: span), let rail = fit(rails, span: span),
              let left = fit(lefts, span: span), let right = fit(rights, span: span) else { return nil }

        let mt = observations.reduce(0.0) { $0 + $1.t } / Double(observations.count)
        let mn = observations.reduce(0.0) { $0 + $1.n } / Double(observations.count)
        var tt = 0.0, nn = 0.0, tn = 0.0
        for p in observations {
            tt += (p.t - mt) * (p.t - mt)
            nn += (p.n - mn) * (p.n - mn)
            tn += (p.t - mt) * (p.n - mn)
        }
        let pcaAngle = 0.5 * atan2(2 * tn, tt - nn)
        let angle = atan(centroid.slope)
        let cell = 0.5 * (abs(b.normal.x) * sx + abs(b.normal.y) * sy)
        let tolerance = 0.25 * b.width + 2 * cell
        let disagreement = [pcaAngle, atan(rail.slope), atan(left.slope), atan(right.slope)]
            .map { abs(tan($0 - angle)) * span }
        let shift = (centroid.intercept + rail.intercept) / 2
        // Selected v1 policy: compare fitted axis to the best parallel old axis,
        // then apply the one jointly measured centroid/rail position as well.
        let fixed = median(centroids.map(\.n))
        let oldRMS = sqrt(centroids.reduce(0.0) { sum, p in
            sum + (p.n - fixed) * (p.n - fixed)
        } / Double(centroids.count))
        let improvement = oldRMS - centroid.rms
        let required = 0.15 * cell
        guard disagreement.allSatisfy({ $0.isFinite && $0 <= tolerance }),
              abs(centroid.intercept - rail.intercept) <= 0.25 * b.width + 2 * cell,
              max(centroid.rms, rail.rms) <= 0.20 * b.width,
              improvement >= required, abs(shift) <= 0.35 * b.width else { return nil }

        let target = b.along + b.normal * centroid.slope
        guard target.length > 0, target.length.isFinite else { return nil }
        let direction = target * (1 / target.length)
        let turn = atan2(b.along.x * direction.y - b.along.y * direction.x,
                         b.along.dot(direction))
        let cosine = cos(turn), sine = sin(turn), translation = b.normal * shift
        let fitted = b.q.map { p -> V in
            let d = p - b.center
            return V(x: b.center.x + cosine * d.x - sine * d.y + translation.x,
                     y: b.center.y + sine * d.x + cosine * d.y + translation.y)
        }
        guard fitted.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            $0.x >= 0 && $0.y >= 0 && $0.x <= Double(width) && $0.y <= Double(height) }) else { return nil }

        let record = G.Record(requestID: requestID, sourceIndex: index,
                              sourceParent: seed.parentBoxIndex, sourceMembers: [index],
                              alternativeID: "owned-axis/\(index)", origin: .sourceRefinement,
                              originalDetectorIndex: index, polygon: fitted.map(\.point))
        let proof = SourceProof(
            producer: "full-angle-owned-centroid-rail-PCA-v1", ownerID: seed.ownerID,
            originalDetectorIndex: index, componentSeeds: seed.components.map(\.seed),
            mapOriginX: seed.mapOriginX, mapOriginY: seed.mapOriginY,
            mapFullWidth: seed.mapFullWidth, mapFullHeight: seed.mapFullHeight,
            sourceWidth: width, sourceHeight: height,
            runCoordinateContract: "full-detector-grid; origin is validation only",
            originalPolygon: b.q.map(\.point), ownedCells: observations.count,
            ownedSpanFraction: span / b.length, normalWidth: b.width, alongLength: b.length,
            normalCellHalfExtent: cell, bands: bandProof, centroid: centroid, rail: rail,
            left: left, right: right, pcaLocalAngleRadians: pcaAngle,
            centroidLocalAngleRadians: angle, appliedImageRotationRadians: turn,
            normalTranslationPixels: shift, axisDisagreementNormalPixels: disagreement,
            axisDisagreementTolerance: tolerance, freelyTranslatedAxisRMS: oldRMS,
            fittedCentroidRMS: centroid.rms, residualImprovement: improvement,
            requiredResidualImprovement: required)
        return Measurement(refinement: G.Refinement(head: .axis, record: record), proof: proof)
    }
}
