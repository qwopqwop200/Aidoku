import CoreGraphics
import Foundation

/// RF bounds the search, never joins DB owners. All proposals precede the first read.
@available(iOS 18.0, *)
enum NativeOCRIndependentLanes {
    static let policyVersion = "rf-independent-lanes-v3-phase-preserving-local-db085-rf0-weak0005-gap1-add0191-overlap0-pixels3"
    static let detectorThreshold = 0.85
    static let rfThreshold = 0.0
    static let weakThreshold = 0.005
    static let gapRatio = 1.0
    static let additionThreshold = 0.191
    static let laneOverlap = 0.0
    static let minimumPixels = 3

    struct Result {
        let boxes: [NativeCoreMLDetectionBox]
        let changed: Set<Int>
        let added: Set<Int>
    }

    private struct Rect {
        var v: [Double]
        subscript(_ i: Int) -> Double {
            get { v[i] }
            set { v[i] = newValue }
        }
        var area: Double { max(0, v[2] - v[0]) * max(0, v[3] - v[1]) }
        var valid: Bool { v.allSatisfy(\.isFinite) && area > 0 }
        var polygon: [CGPoint] {
            [CGPoint(x: v[0], y: v[1]), CGPoint(x: v[2], y: v[1]),
             CGPoint(x: v[2], y: v[3]), CGPoint(x: v[0], y: v[3])]
        }
        func scaled(_ s: [Double]) -> Self { .init(v: zip(v, s).map(*)) }
    }

    private static func bounds(_ polygon: [CGPoint]) -> Rect {
        .init(v: [polygon.map { Double($0.x) }.min() ?? 0,
                  polygon.map { Double($0.y) }.min() ?? 0,
                  polygon.map { Double($0.x) }.max() ?? 0,
                  polygon.map { Double($0.y) }.max() ?? 0])
    }

    private static func overlap(_ a: Rect, _ b: Rect) -> Double {
        max(0, min(a[2], b[2]) - max(a[0], b[0])) * max(0, min(a[3], b[3]) - max(a[1], b[1]))
    }

    private static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted()
        guard !sorted.isEmpty else { return 0 }
        let position = Double(sorted.count - 1) * fraction
        let lo = Int(floor(position)), hi = Int(ceil(position))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (position - Double(lo))
    }

    private static func runs(_ active: [Bool]) -> [Range<Int>] {
        var result: [Range<Int>] = [], start: Int?
        for i in 0...active.count {
            if i < active.count && active[i] {
                if start == nil { start = i }
            } else if let first = start {
                result.append(first..<i); start = nil
            }
        }
        return result
    }

    private static func smooth(_ profile: [Double], radius requested: Int) -> [Double] {
        let radius = min(max(0, requested), max(0, (profile.count - 1) / 2))
        guard radius > 0 else { return profile }
        let weight = 1 / Double(2 * radius + 1)
        return profile.indices.map { x in
            var sum = 0.0
            for offset in -radius...radius where profile.indices.contains(x + offset) {
                sum += profile[x + offset] * weight
            }
            return sum
        }
    }

    static func refine(boxes: [NativeCoreMLDetectionBox], layout: NativeRFDETRLayoutResult?,
                       probability: NativeMainEnsembleOCRProbability.Sample?, width: Int, height: Int,
                       cancellationCheck: () throws -> Void = {}) throws -> Result {
        guard NativeOCRDirectionGeometry.enabled("lanes"), let layout, let probability else {
            return try axisRefine(boxes: boxes, layout: layout, probability: probability,
                                  width: width, height: height, cancellationCheck: cancellationCheck)
        }
        // Preserve the calibrated detector-cell phase and pitch in the local
        // raster. Arbitrary ROI ceil/rescale used to move even upright cell
        // boundaries by a pixel, changing crops and downstream connectivity.
        func gcd(_ a: Int, _ b: Int) -> Int { var x=a, y=b; while y != 0 { (x,y)=(y,x%y) }; return x }
        guard probability.width > 0, probability.height > 0 else {
            return .init(boxes:boxes,changed:[],added:[])
        }
        let spacing = CGSize(width:CGFloat(width)/CGFloat(probability.width),
                             height:CGFloat(height)/CGFloat(probability.height))
        let lattice = CGSize(width:width/gcd(width,probability.width),
                             height:height/gcd(height,probability.height))
        func sameAxis(_ polygon: [CGPoint], _ frame: NativeOCRDirectionGeometry.Frame) -> Bool {
            guard let q=NativeOCRDirectionGeometry.readingQuad(polygon,vertical:true),
                  let own=NativeOCRDirectionGeometry.Frame(q) else { return false }
            return abs(own.along.x*frame.along.x+own.along.y*frame.along.y) >= 1-0.000000000001
        }
        func reliableAxis(_ polygon:[CGPoint]) -> NativeOCRDirectionGeometry.Frame? {
            guard let q=NativeOCRDirectionGeometry.readingQuad(polygon,vertical:true),
                  let own=NativeOCRDirectionGeometry.Frame(q),own.rect.height >= own.rect.width*3 else { return nil }
            return own
        }
        var contextFrames:[Int:[NativeOCRDirectionGeometry.Frame]]=[:]
        let scoped = layout.primitives.flatMap { p -> [(NativeRFDETRLayoutPrimitive,NativeOCRDirectionGeometry.Window)] in
            guard p.semanticClass == .text || p.semanticClass == .soundEffect else { return [] }
            var frames=NativeOCRDirectionAdapters.scopeFrames(p.sourceBounds,boxes:boxes,probability:probability)
            if NativeOCRDirectionGeometry.enabled("mixedDirections") {
                // Cluster membership is not a crop coordinate system. Measure
                // each existing owner's endpoints in its OWN exact axis; a
                // nearby long column must not flatten a smaller tilted glyph.
                frames=[]
                for b in boxes.sorted(by:{ NativeOCRDirectionGeometry.area($0.polygon) > NativeOCRDirectionGeometry.area($1.polygon) }) {
                    guard b.score >= 0.25, NativeOCRDirectionAdapters.coverage(b.polygon,by:p) >= 0.6,
                          let own=reliableAxis(b.polygon),
                          !frames.contains(where:{sameAxis(b.polygon,$0)}) else { continue }
                    frames.append(own)
                }
                var contexts:[NativeOCRDirectionGeometry.Frame]=[]
                for f in frames where !contexts.contains(where:{ NativeOCRDirectionGeometry.compatible(f.quad,with:$0) }) {
                    contexts.append(f)
                }
                contextFrames[p.queryID]=contexts
                if frames.isEmpty {
                    if NativeOCRDirectionGeometry.enabled("unanchored"),
                       let evidence=NativeOCRDirectionAdapters.evidenceFrame(p.sourceBounds,probability:probability) {
                        frames=[evidence];contextFrames[p.queryID]=[evidence]
                    }
                }
            }
            return frames.compactMap { f in
                let world = boxes.reduce(p.sourceBounds) { bounds,box in
                    let b=NativeOCRDirectionGeometry.bounds(box.polygon)
                    return b.intersects(p.sourceBounds) ? bounds.union(b) : bounds
                }
                // Coprime source/map sizes can make an exact lattice larger
                // than the raster budget. Keep the bounded LOCAL kernel then;
                // never fall back to a screen-axis recovery or drop the scope.
                guard let w = NativeOCRDirectionGeometry.Window(frame:f,world:world,lattice:lattice) ??
                    NativeOCRDirectionGeometry.Window(frame:f,world:world) else { return nil }
                return (p,w)
            }
        }
        // Missing direction evidence means abstain, never screen-axis fallback.
        var result = boxes, changed = Set<Int>(), added = Set<Int>()
        for (p,w) in scoped.sorted(by: { $0.0.confidence > $1.0.confidence }) {
            try cancellationCheck()
            guard let map = NativeOCRDirectionAdapters.probability(probability, window: w,
                support:NativeOCRDirectionGeometry.enabled("rfShape") ? NativeOCRDirectionAdapters.support(p) : nil,
                preserving:boxes.map(\.polygon),spacing:spacing) else { continue }
            let local = try axisRefine(boxes: boxes.map { NativeOCRDirectionAdapters.box($0,map:w.project) },
                layout: NativeOCRDirectionAdapters.layout(layout,primitives:[p],window:w), probability: map,
                width:w.width,height:w.height,cancellationCheck:cancellationCheck,
                eligible:NativeOCRDirectionGeometry.enabled("mixedDirections") ? Set(boxes.indices.filter {
                    if reliableAxis(boxes[$0].polygon) != nil { return sameAxis(boxes[$0].polygon,w.frame) }
                    // A single glyph's outline is not a writing baseline. A
                    // short dot/kana fragment may follow ONE independently
                    // measured neighboring column axis, but never choose among
                    // conflicting directions merely from its own silhouette.
                    guard let contexts=contextFrames[p.queryID],contexts.count == 1 else { return false }
                    return sameAxis(contexts[0].quad,w.frame)
                }) : nil)
            for i in local.changed where !changed.contains(i) {
                if NativeOCRDirectionGeometry.enabled("mixedDirections"), reliableAxis(boxes[i].polygon) != nil,
                   !NativeOCRDirectionGeometry.compatible(boxes[i].polygon,with:w.frame) { continue }
                let restored=NativeOCRDirectionAdapters.box(local.boxes[i],map:w.restore)
                if NativeOCRDirectionGeometry.enabled("mixedDirections"),
                   let own=reliableAxis(boxes[i].polygon) {
                    // Direction-cluster tolerance is not permission to
                    // rotate the owner's quad. Transfer only endpoint growth.
                    let target=own.bounds(restored.polygon), r=own.rect
                    let upper=max(0,r.minY-target.minY), lower=max(0,target.maxY-r.maxY)
                    let polygon=boxes[i].polygon.map { point -> CGPoint in
                        let delta=own.project(point).y < r.midY ? -upper : lower
                        return CGPoint(x:point.x+own.along.x*delta,y:point.y+own.along.y*delta)
                    }
                    result[i] = .init(polygon:polygon,score:boxes[i].score,erasurePolygons:boxes[i].erasurePolygons,
                        recognitionPolygon:boxes[i].recognitionPolygon,isThinFinePrintRecovery:boxes[i].isThinFinePrintRecovery,
                        finePrintRetryPolygons:boxes[i].finePrintRetryPolygons,
                        recognitionColumnEvidence:boxes[i].recognitionColumnEvidence,detectorSeedEvidence:boxes[i].detectorSeedEvidence)
                } else { result[i]=restored }
                changed.insert(i)
            }
            for i in local.added.sorted() {
                let proposed = NativeOCRDirectionAdapters.box(local.boxes[i],map:w.restore)
                if NativeOCRDirectionGeometry.enabled("rfShape"), NativeOCRDirectionAdapters.coverage(proposed.polygon,by:p) < 0.9 { continue }
                let r = w.frame.bounds(proposed.polygon)
                guard !result.contains(where: { b in
                    let other = w.frame.bounds(b.polygon), overlap = r.intersection(other)
                    return !overlap.isNull && overlap.width*overlap.height > min(r.width*r.height,other.width*other.height)*0.05
                }) else { continue }
                added.insert(result.count); result.append(proposed)
            }
        }
        return .init(boxes:result,changed:changed,added:added)
    }

    static func axisRefine(boxes: [NativeCoreMLDetectionBox], layout: NativeRFDETRLayoutResult?,
                           probability: NativeMainEnsembleOCRProbability.Sample?, width: Int, height: Int,
                           cancellationCheck: () throws -> Void = {}, eligible:Set<Int>? = nil) throws -> Result {
        let unchanged = Result(boxes: boxes, changed: [], added: [])
        guard width > 0, height > 0, let layout, let map = probability,
              layout.sourceWidth == width, layout.sourceHeight == height,
              map.sourceWidth == width, map.sourceHeight == height,
              map.width > 0, map.height > 0, map.width <= 2_048, map.height <= 2_048,
              map.width == map.resizedWidth, map.height == map.resizedHeight,
              map.region == CGRect(x: 0, y: 0, width: map.width, height: map.height),
              map.values.count == map.width * map.height else { return unchanged }
        let originals = boxes.map { bounds($0.polygon) }
        guard originals.allSatisfy(\.valid) else { return unchanged }
        let scale = [Double(map.width) / Double(width), Double(map.height) / Double(height),
                     Double(map.width) / Double(width), Double(map.height) / Double(height)]
        let inverse = scale.map { 1 / $0 }
        let originalMap = originals.map { $0.scaled(scale) }
        var result = boxes, additions: [NativeCoreMLDetectionBox] = [], changed = Set<Int>()
        let scopes = layout.primitives.enumerated().filter {
            ($0.element.semanticClass == .text || $0.element.semanticClass == .soundEffect)
                && $0.element.confidence.isFinite && Double($0.element.confidence) >= rfThreshold
        }.sorted {
            if $0.element.confidence != $1.element.confidence { return $0.element.confidence > $1.element.confidence }
            if $0.element.queryID != $1.element.queryID { return $0.element.queryID < $1.element.queryID }
            return $0.offset < $1.offset
        }
        for entry in scopes {
            try cancellationCheck()
            let scope = entry.element.sourceBounds
            guard [scope.minX, scope.minY, scope.maxX, scope.maxY].allSatisfy(\.isFinite) else { continue }
            let rf = Rect(v: [max(0, Double(scope.minX)), max(0, Double(scope.minY)),
                              min(Double(width), Double(scope.maxX)), min(Double(height), Double(scope.maxY))])
            guard rf.valid else { continue }
            let members = originals.indices.filter { eligible?.contains($0) != false &&
                (entry.element.supportPolygon == nil ? overlap(originals[$0], rf) / max(1, originals[$0].area)
                    : Double(NativeOCRDirectionAdapters.coverage(boxes[$0].polygon,by:entry.element))) >= 0.6 }
            let ratios = members.map { (originals[$0][3] - originals[$0][1]) / (originals[$0][2] - originals[$0][0]) }
            let vertical = ratios.isEmpty ? rf[3] - rf[1] >= rf[2] - rf[0] : percentile(ratios, 0.5) >= 1.2
            let cross0 = vertical ? 0 : 1, cross1 = cross0 + 2
            let along0 = vertical ? 1 : 0, along1 = along0 + 2
            let rm = rf.scaled(scale)
            let x0 = max(0, Int(floor(rm[0]))), y0 = max(0, Int(floor(rm[1])))
            let x1 = min(map.width, Int(ceil(rm[2]))), y1 = min(map.height, Int(ceil(rm[3])))
            guard x1 > x0, y1 > y0 else { continue }
            let rows = vertical ? y1 - y0 : x1 - x0
            let columns = vertical ? x1 - x0 : y1 - y0
            let offsetCross = vertical ? x0 : y0, offsetAlong = vertical ? y0 : x0
            func value(_ row: Int, _ column: Int) -> Float {
                let x = vertical ? x0+column : x0+row, y = vertical ? y0+row : y0+column
                if let support=entry.element.supportPolygon,
                   !NativeOCRDirectionGeometry.contains(support,CGPoint(x:(CGFloat(x)+0.5)*CGFloat(width)/CGFloat(map.width),
                       y:(CGFloat(y)+0.5)*CGFloat(height)/CGFloat(map.height))),
                   !boxes.contains(where: { NativeOCRDirectionGeometry.contains($0.polygon,
                       CGPoint(x:(CGFloat(x)+0.5)*CGFloat(width)/CGFloat(map.width),
                               y:(CGFloat(y)+0.5)*CGFloat(height)/CGFloat(map.height))) }) { return 0 }
                return vertical ? map.values[(y0 + row) * map.width + x0 + column]
                    : map.values[(y0 + column) * map.width + x0 + row]
            }
            let thicknesses = members.map { originalMap[$0][cross1] - originalMap[$0][cross0] }
            let thickness = thicknesses.isEmpty ? max(3, Double(min(rows, columns)) / 8) : percentile(thicknesses, 0.5)
            var weak = [UInt8](repeating: 0, count: rows * columns)
            var profile = [Double](repeating: 0, count: columns)
            for y in 0..<rows {
                if y & 63 == 0 { try cancellationCheck() }
                for x in 0..<columns where value(y, x) > Float(weakThreshold) {
                    weak[y * columns + x] = 1; profile[x] += 1
                }
            }
            profile = smooth(profile, radius: Int(max(1, thickness * 0.08)))
            let positive = profile.filter { $0 > 0 }
            guard !positive.isEmpty else { continue }
            let gate = max(1, percentile(positive, 0.75) * 0.15)
            let lanes = runs(profile.map { $0 >= gate })
            for i in members where !changed.contains(i) {
                let anchor = originalMap[i]
                let c0 = max(0, Int(floor(anchor[cross0] - Double(offsetCross))))
                let c1 = min(columns, Int(ceil(anchor[cross1] - Double(offsetCross))))
                guard c1 > c0 else { continue }
                let start = max(0, anchor[along0] - Double(offsetAlong))
                let end = min(Double(rows), anchor[along1] - Double(offsetAlong))
                guard end > start else { continue }
                var limit0 = 0.0, limit1 = Double(rows)
                for j in members where i != j {
                    let peer = originalMap[j]
                    guard min(anchor[cross1], peer[cross1]) - max(anchor[cross0], peer[cross0]) > 0 else { continue }
                    if peer[along1] <= anchor[along0] {
                        limit0 = max(limit0, (peer[along1] + anchor[along0]) / 2 - Double(offsetAlong))
                    }
                    if peer[along0] >= anchor[along1] {
                        limit1 = min(limit1, (peer[along0] + anchor[along1]) / 2 - Double(offsetAlong))
                    }
                }
                var supported: [Int] = []
                for y in 0..<rows {
                    var count = 0
                    for x in c0..<c1 { count += Int(weak[y * columns + x]) }
                    if Double(count) >= max(1, Double(c1 - c0) * 0.08) { supported.append(y) }
                }
                let pitch = max(2, anchor[cross1] - anchor[cross0])
                var first = start, last = end
                for y in supported.reversed() where Double(y) < start {
                    if Double(y) < limit0 || first - Double(y) > pitch * gapRatio { break }
                    first = Double(y)
                }
                for y in supported where Double(y) >= end {
                    if Double(y + 1) > limit1 || Double(y) - last > pitch * gapRatio { break }
                    last = Double(y + 1)
                }
                var q = anchor
                q[along0] = min(anchor[along0], max(Double(offsetAlong) + limit0, Double(offsetAlong) + first))
                q[along1] = max(anchor[along1], min(Double(offsetAlong) + limit1, Double(offsetAlong) + last))
                let proposal = q.scaled(inverse)
                guard proposal.area > originals[i].area + 1 else { continue }
                if entry.element.supportPolygon != nil,
                   !NativeOCRDirectionAdapters.supportsExpansion(proposal.polygon,preserving:boxes[i].polygon,
                       by:entry.element) { continue }
                guard !originals.indices.contains(where: { j in
                    j != i && overlap(proposal, originals[j]) > overlap(originals[i], originals[j]) + 1
                }) else { continue }
                let old = boxes[i]
                result[i] = .init(polygon: proposal.polygon, score: old.score,
                    erasurePolygons: old.erasurePolygons, detectorSeedEvidence: old.detectorSeedEvidence)
                changed.insert(i)
            }
            for lane in lanes where lane.count >= 2 {
                let c0 = lane.lowerBound, c1 = lane.upperBound
                let lane0 = Double(c0 + offsetCross), lane1 = Double(c1 + offsetCross)
                guard !members.contains(where: { i in
                    let r = originalMap[i]
                    return max(0, min(lane1, r[cross1]) - max(lane0, r[cross0]))
                        / max(1e-9, min(lane1 - lane0, r[cross1] - r[cross0])) > laneOverlap
                }) else { continue }
                var active = [Bool](repeating: false, count: rows)
                for y in 0..<rows {
                    var count = 0
                    for x in c0..<c1 { count += Int(weak[y * columns + x]) }
                    active[y] = Double(count) >= max(1, Double(c1 - c0) * 0.08)
                }
                var segments: [Range<Int>] = []
                for run in runs(active) {
                    if let last = segments.last, Double(run.lowerBound - last.upperBound) <= max(2, Double(c1 - c0) * gapRatio) {
                        segments[segments.count - 1] = last.lowerBound..<run.upperBound
                    } else { segments.append(run) }
                }
                for segment in segments {
                    try cancellationCheck()
                    var pixels = 0, sum = 0.0
                    for y in segment { for x in c0..<c1 {
                        pixels += Int(weak[y * columns + x]); sum += Double(value(y, x))
                    } }
                    guard pixels >= minimumPixels else { continue }
                    let mean = Double(Float(sum / Double(segment.count * (c1 - c0))))
                    guard mean >= additionThreshold else { continue }
                    var q = Rect(v: [0, 0, 0, 0])
                    q[cross0] = lane0; q[cross1] = lane1
                    q[along0] = Double(segment.lowerBound + offsetAlong)
                    q[along1] = Double(segment.upperBound + offsetAlong)
                    let margin = max(1, Double(min(c1 - c0, segment.count)) * 0.15)
                    q[0] = max(0, q[0] - margin); q[1] = max(0, q[1] - margin)
                    q[2] = min(Double(map.width), q[2] + margin); q[3] = min(Double(map.height), q[3] + margin)
                    let candidate = q.scaled(inverse)
                    if entry.element.supportPolygon != nil,
                       NativeOCRDirectionAdapters.coverage(candidate.polygon,by:entry.element) < 0.9 { continue }
                    let existing = (result + additions).map { bounds($0.polygon) }
                    guard !existing.contains(where: { overlap(candidate, $0) > min(candidate.area, $0.area) * 0.05 }) else { continue }
                    additions.append(.init(polygon: candidate.polygon, score: mean))
                }
            }
        }
        return .init(boxes: result + additions, changed: changed,
            added: Set(boxes.count..<(boxes.count + additions.count)))
    }
}
