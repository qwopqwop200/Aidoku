import CoreGraphics
import Foundation

/// Original-pixel evidence in the incoming quad's own frame. No reads, GT,
/// image identities or world-axis special cases participate in the measurement.
@available(iOS 18.0, *)
enum NativeOCRSourceComponentMeasurements {
    struct Scope {
        let rect: CGRect
        let confidence: Double
    }
    struct Component {
        let colour: SIMD3<Int>
        let pixels: Int
        let ownedPixels: Int
        let foreignPixels: Int
        let insidePixels: Int
        let bounds: CGRect
        let center: CGPoint
        let hull: [CGPoint]
    }
    struct Measurement {
        let index: Int
        let polygon: [CGPoint]
        let origin: CGPoint
        let normal: CGPoint
        let along: CGPoint
        let rect: CGRect
        var status = "unmeasured"
        var left: CGFloat = 0
        var top: CGFloat = 0
        var step: CGFloat = 1
        var columns = 0
        var rows = 0
        var palettes: [SIMD3<Int>] = []
        var components: [Component] = []
        var privateHull: [CGPoint] = []
        var guardPoints: [CGPoint] = []
        var privateSamples = 0
        var privateObservation: NativeOCRPrivateObservation.Retained?
        var associatedOwners: [String] = []
        var provisionalOwners: [String] = []
        var rejections: [String: Int] = [:]
        var score: Double = 1
        var kind = "detector"
        var hasInk = false
        var scopes: [Scope] = []
        func project(_ point: CGPoint) -> CGPoint {
            let x = point.x - origin.x, y = point.y - origin.y
            return .init(x: x * normal.x + y * normal.y, y: x * along.x + y * along.y)
        }
        func restore(_ point: CGPoint) -> CGPoint {
            .init(x: origin.x + point.x * normal.x + point.y * along.x,
                  y: origin.y + point.x * normal.y + point.y * along.y)
        }
        var json: [String: Any] {
            func pair(_ p: CGPoint) -> [Double] { [Double(p.x), Double(p.y)] }
            func rect(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.maxX), Double(r.maxY)] }
            return ["sourceIndex": index, "polygon": polygon.map { ["x": Double($0.x), "y": Double($0.y)] },
                "origin": pair(origin), "basis": [[Double(normal.x), Double(along.x)], [Double(normal.y), Double(along.y)]],
                "bounds": rect(self.rect), "width": Double(self.rect.width), "height": Double(self.rect.height),
                "status": status, "left": Double(left), "top": Double(top), "step": Double(step), "shape": [rows, columns],
                "palettes": palettes.map { [$0.x, $0.y, $0.z] },
                "components": components.map { c -> [String: Any] in
                    ["colour": [c.colour.x, c.colour.y, c.colour.z], "pixels": c.pixels, "ownedPixels": c.ownedPixels,
                     "foreignPixels": c.foreignPixels, "insidePixels": c.insidePixels, "bounds": rect(c.bounds),
                     "center": pair(c.center), "hull": c.hull.map { p in
                        [Int(((p.x - left) / step - 0.5).rounded()), Int(((p.y - top) / step - 0.5).rounded())]
                     }]
                }, "privateHull": privateHull.map(pair), "privateSamples": privateSamples,
                "guardHull": NativeOCRSourceComponentMeasurements.convexHull(guardPoints).map(pair),
                "associatedOwners": associatedOwners, "provisionalOwners": provisionalOwners,
                "rejections": rejections, "sourceScore": score, "sourceKind": kind, "hasSourceInkProof": hasInk,
                "RFTextScopes": scopes.map { rect($0.rect) + [$0.confidence] }]
        }
    }

    final class Context {
        let originals: [NativeCoreMLDetectionBox]
        let prepared: [NativeCoreMLDetectionBox]
        let groups: [Int: [Int]]
        let scopes: [Scope]
        let supportViews: [Int: [NativeOCRDetectorSeedEvidence]]
        let provisionalPlans: [Int: NativeOCRResidualEvidenceForwarding.Plan]
        let associationViews: [Int: [NativeOCRDetectorSeedEvidence]]
        let frameProvider: () -> NativeOCRRGBAFrame?
        private var loaded = false
        private var frame: NativeOCRRGBAFrame?
        private var gridWidth = 0
        private var gridHeight = 0
        private var aggregate: [UInt8] = []

        init(originals: [NativeCoreMLDetectionBox], prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]],
             scopes: [Scope], frameProvider: @escaping () -> NativeOCRRGBAFrame?,
             supportViews: [Int: [NativeOCRDetectorSeedEvidence]] = [:],
             associationViews: [Int: [NativeOCRDetectorSeedEvidence]] = [:],
             provisionalPlans: [Int: NativeOCRResidualEvidenceForwarding.Plan] = [:]) {
            self.provisionalPlans = provisionalPlans
            self.originals = originals; self.prepared = prepared; self.groups = groups
            self.scopes = scopes; self.frameProvider = frameProvider; self.supportViews = supportViews; self.associationViews = associationViews
        }

        func metadata(index: Int, polygon: [CGPoint], hasInk: Bool = false) -> Measurement? {
            guard polygon.count == 4 else { return nil }
            let e1 = CGPoint(x: polygon[1].x - polygon[0].x, y: polygon[1].y - polygon[0].y)
            let e3 = CGPoint(x: polygon[3].x - polygon[0].x, y: polygon[3].y - polygon[0].y)
            let edge = hypot(e1.x, e1.y) >= hypot(e3.x, e3.y) ? e1 : e3
            let length = hypot(edge.x, edge.y)
            guard length > 0 else { return nil }
            let along = CGPoint(x: edge.x / length, y: edge.y / length)
            let normal = CGPoint(x: along.y, y: -along.x)
            let origin = CGPoint(x: polygon.map(\.x).reduce(0, +) / 4, y: polygon.map(\.y).reduce(0, +) / 4)
            let local = polygon.map { p -> CGPoint in
                let x = p.x - origin.x, y = p.y - origin.y
                return .init(x: x * normal.x + y * normal.y, y: x * along.x + y * along.y)
            }
            let rect = CGRect(x: local.map(\.x).min()!, y: local.map(\.y).min()!,
                width: local.map(\.x).max()! - local.map(\.x).min()!,
                height: local.map(\.y).max()! - local.map(\.y).min()!)
            var result = Measurement(index: index, polygon: polygon, origin: origin, normal: normal, along: along, rect: rect)
            result.score = prepared.indices.contains(index) ? prepared[index].score : 1
            result.kind = index >= prepared.count ? "independent" : groups[index] != nil ? "group" : "detector"
            result.hasInk = hasInk; result.scopes = scopes
            return result
        }

        /// A recovered RGB column can be supported by existing detector components
        /// without owning a new detector index. Retain original owner IDs and cell runs;
        /// this view never changes the original ownership inventory.
        func associatedEvidence(_ measurement: Measurement) -> [NativeOCRDetectorSeedEvidence] {
            guard measurement.kind == "independent" else { return [] }
            var result: [NativeOCRDetectorSeedEvidence] = []
            for box in originals {
                guard let e = box.detectorSeedEvidence, e.isValid, !e.components.isEmpty else { continue }
                let sx = CGFloat(e.sourceWidth) / CGFloat(e.mapFullWidth)
                let sy = CGFloat(e.sourceHeight) / CGFloat(e.mapFullHeight)
                let chosen = e.components.filter { component in
                    var inside = 0, sum: CGFloat = 0
                    for run in component.runs { for x in run.x..<(run.x + run.count) {
                        let world = CGPoint(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy)
                        let local = measurement.project(world)
                        if NativeOCRSourceComponentMeasurements.contains(measurement.polygon, world) {
                            inside += 1; sum += local.x
                        }
                    }}
                    return inside >= 8 && inside * 2 >= component.pixelCount &&
                        abs(sum / CGFloat(max(1, inside)) - measurement.rect.midX) <= measurement.rect.width * 0.3
                }
                guard !chosen.isEmpty else { continue }
                result.append(.init(ownerID: e.ownerID, parentBoxIndex: e.parentBoxIndex, provenance: e.provenance,
                    threshold: e.threshold, mapOriginX: e.mapOriginX, mapOriginY: e.mapOriginY,
                    mapFullWidth: e.mapFullWidth, mapFullHeight: e.mapFullHeight,
                    sourceWidth: e.sourceWidth, sourceHeight: e.sourceHeight, components: chosen,
                    sourceProbabilityROI: e.sourceProbabilityROI, ownershipVersion: e.ownershipVersion,
                    completeCCScan: e.completeCCScan, ambiguousComponents: e.ambiguousComponents,
                    candidateComponents: e.candidateComponents))
            }
            return result
        }
        func measure(index: Int, polygon: [CGPoint], hasInk: Bool = false,
                     capturePrivateObservation: Bool = false, captureDensePrivateFootprint: Bool = false) -> Measurement? {
            guard var result = metadata(index: index, polygon: polygon, hasInk: hasInk) else { return nil }
            let rect = result.rect
            guard min(rect.width, rect.height) >= 5 else { result.status = "too-small"; return result }
            let members = groups[index] ?? [index]
            var evidence = members.compactMap { i -> NativeOCRDetectorSeedEvidence? in
                guard originals.indices.contains(i), let e = originals[i].detectorSeedEvidence,
                      e.isValid, !e.components.isEmpty else { return nil }
                return e
            }
            let nativeEvidence = evidence
            var samplingPlan: NativeOCRResidualEvidenceForwarding.Plan?
            if let plan = provisionalPlans[index], plan.sourceIndex == index, plan.polygon == polygon,
               plan.evidence.allSatisfy({ e in originals.contains(where: { $0.detectorSeedEvidence == e }) }) {
                samplingPlan = plan
                evidence = plan.evidence
                result.provisionalOwners = plan.evidence.map(\.ownerID)
            } else if let views = supportViews[index], !views.isEmpty, views.allSatisfy({ $0.isValid }) {
                evidence = views
                result.provisionalOwners = views.map(\.ownerID)
            }
            if evidence.isEmpty, result.kind == "independent" {
                evidence = associationViews[index] ?? associatedEvidence(result)
                result.associatedOwners = evidence.map(\.ownerID)
            }
            guard let first = evidence.first else { result.status = "no-private-source"; return result }
            if !loaded { frame = frameProvider(); loaded = true }
            guard let frame, first.sourceWidth == frame.width, first.sourceHeight == frame.height else {
                result.status = "source-image-mismatch"; return result
            }
            let mw = first.mapFullWidth, mh = first.mapFullHeight
            guard mw > 0, mh > 0, mw <= 16_777_216 / mh,
                  evidence.allSatisfy({ $0.mapFullWidth == mw && $0.mapFullHeight == mh &&
                      $0.sourceWidth == frame.width && $0.sourceHeight == frame.height }) else {
                result.status = "mixed-source-grid"; return result
            }
            if aggregate.isEmpty {
                gridWidth = mw; gridHeight = mh; aggregate = [UInt8](repeating: 0, count: mw * mh)
                for box in originals {
                    guard let e = box.detectorSeedEvidence, e.isValid, e.mapFullWidth == mw, e.mapFullHeight == mh else { continue }
                    for c in e.components { for r in c.runs {
                        for x in r.x..<(r.x + r.count) { aggregate[r.y * mw + x] = 1 }
                    }}
                }
            }
            guard gridWidth == mw, gridHeight == mh else { result.status = "mixed-source-grid"; return result }
            // Provisional sampling must never acquire cells privately owned by an
            // external source. This does not alter the original owner inventory.
            var nativeCells = Set<Int>()
            if !result.provisionalOwners.isEmpty {
                var allowed = nativeEvidence
                if result.kind == "independent" {
                    let references = Set(result.provisionalOwners)
                    allowed = originals.compactMap(\.detectorSeedEvidence).filter { references.contains($0.ownerID) && $0.isValid }
                }
                for e in allowed { for c in e.components { for r in c.runs {
                    for x in r.x..<(r.x + r.count) { nativeCells.insert(r.y * mw + x) }
                }}}
            }
            var owned = [UInt8](repeating: 0, count: mw * mh), ownedCells: [Int] = []
            for e in evidence { for c in samplingPlan?.componentsByOwner[e.ownerID] ?? e.components { for r in c.runs { for x in r.x..<(r.x + r.count) {
                let cell = r.y * mw + x
                if let plan = samplingPlan, !plan.allowedCells.contains(cell) { continue }
                if !result.provisionalOwners.isEmpty, aggregate[cell] != 0, !nativeCells.contains(cell) { continue }
                if owned[cell] == 0 { owned[cell] = 1; ownedCells.append(cell) }
            }}}}
            guard ownedCells.count >= 4 else { result.status = "insufficient-private-cells"; return result }
            let left = rect.minX - rect.width * 0.15, top = rect.minY - rect.height * 0.15
            let right = rect.maxX + rect.width * 0.15, bottom = rect.maxY + rect.height * 0.15
            let step = max(1, (right - left) / 300, (bottom - top) / 1800)
            let columns = Int(ceil((right - left) / step)), rows = Int(ceil((bottom - top) / step))
            guard columns > 0, rows > 0, columns <= 600_000 / rows else { result.status = "roi-budget"; return result }
            result.left = left; result.top = top; result.step = step; result.columns = columns; result.rows = rows
            let count = columns * rows
            var rgb = [UInt8](repeating: 255, count: count * 3), flags = [UInt8](repeating: 0, count: count)
            let sx = CGFloat(frame.width) / CGFloat(mw), sy = CGFloat(frame.height) / CGFloat(mh)
            var strong = 0
            for y in 0..<rows { for x in 0..<columns {
                let local = CGPoint(x: left + (CGFloat(x) + 0.5) * step, y: top + (CGFloat(y) + 0.5) * step)
                let world = result.restore(local), p = y * columns + x
                if local.x >= rect.minX && local.x <= rect.maxX && local.y >= rect.minY && local.y <= rect.maxY { flags[p] |= 4 }
                guard world.x >= 0, world.y >= 0, world.x < CGFloat(frame.width), world.y < CGFloat(frame.height) else { continue }
                let ix = min(frame.width - 1, Int(floor(world.x + 1e-7)))
                let iy = min(frame.height - 1, Int(floor(world.y + 1e-7)))
                let offset = iy * frame.bytesPerRow + ix * 4
                rgb[p * 3] = frame.bytes[offset]; rgb[p * 3 + 1] = frame.bytes[offset + 1]; rgb[p * 3 + 2] = frame.bytes[offset + 2]
                let mx = min(mw - 1, Int(floor(world.x / sx + 1e-7))), my = min(mh - 1, Int(floor(world.y / sy + 1e-7)))
                let cell = my * mw + mx
                if owned[cell] != 0 { flags[p] |= 1 } else if aggregate[cell] != 0 { flags[p] |= 2 }
                if flags[p] & 5 == 5 { strong += 1 }
            }}
            guard strong >= 4 else { result.status = "no-private-source-in-roi"; return result }
            var edges = [UInt8](repeating: 0, count: count)
            func reflected(_ i: Int, _ size: Int) -> Int { size <= 1 ? 0 : i < 0 ? -i : i >= size ? size * 2 - i - 2 : i }
            for y in 0..<rows { for x in 0..<columns {
                let xm = reflected(x - 1, columns), xp = reflected(x + 1, columns)
                let ym = reflected(y - 1, rows), yp = reflected(y + 1, rows)
                for c in 0..<3 {
                    let a = Int(rgb[(ym * columns + xm) * 3 + c]), b = Int(rgb[(ym * columns + x) * 3 + c])
                    let d = Int(rgb[(ym * columns + xp) * 3 + c]), e = Int(rgb[(y * columns + xm) * 3 + c])
                    let f = Int(rgb[(y * columns + xp) * 3 + c]), g = Int(rgb[(yp * columns + xm) * 3 + c])
                    let h = Int(rgb[(yp * columns + x) * 3 + c]), j = Int(rgb[(yp * columns + xp) * 3 + c])
                    if max(abs(-a + d - 2 * e + 2 * f - g + j), abs(-a - 2 * b - d + g + 2 * h + j)) > 144 {
                        edges[y * columns + x] = 1; break
                    }
                }
            }}
            var histogram = [Int](repeating: 0, count: 512), samples = 0
            for y in 0..<rows { for x in 0..<columns where flags[y * columns + x] & 5 == 5 {
                var edge = false
                for yy in max(0, y - 1)...min(rows - 1, y + 1) {
                    for xx in max(0, x - 1)...min(columns - 1, x + 1) where edges[yy * columns + xx] != 0 { edge = true }
                }
                if edge {
                    let p = (y * columns + x) * 3
                    let code = Int(rgb[p] / 32) * 64 + Int(rgb[p + 1] / 32) * 8 + Int(rgb[p + 2] / 32)
                    histogram[code] += 1; samples += 1
                }
            }}
            guard samples >= 4 else { result.status = "no-source-contrast"; return result }
            let order = histogram.indices.sorted { histogram[$0] == histogram[$1] ? $0 < $1 : histogram[$0] > histogram[$1] }
            for code in order {
                if histogram[code] < 3 { break }
                let colour = SIMD3(code / 64 * 32 + 16, (code / 8) % 8 * 32 + 16, code % 8 * 32 + 16)
                if result.palettes.allSatisfy({ colourDistance(colour, $0) > 40 }) { result.palettes.append(colour) }
                if result.palettes.count >= 6 { break }
            }
            let nominal = rect.width / step, minimumArea = max(2, Int(0.001 * nominal * nominal))
            var queue: [Int] = []
            for colour in result.palettes {
                var mask = [UInt8](repeating: 0, count: count)
                for p in 0..<count {
                    if max(abs(Int(rgb[p * 3]) - colour.x), abs(Int(rgb[p * 3 + 1]) - colour.y),
                           abs(Int(rgb[p * 3 + 2]) - colour.z)) <= 24 { mask[p] = 1 }
                }
                for seed in 0..<count where mask[seed] != 0 {
                    queue.removeAll(keepingCapacity: true); queue.append(seed); mask[seed] = 0
                    var cursor = 0, x0 = columns, y0 = rows, x1 = 0, y1 = 0, own = 0, foreign = 0, inside = 0
                    var sumX = 0, sumY = 0, open = false
                    while cursor < queue.count {
                        let p = queue[cursor]; cursor += 1; let x = p % columns, y = p / columns
                        x0 = min(x0, x); x1 = max(x1, x); y0 = min(y0, y); y1 = max(y1, y)
                        sumX += x; sumY += y
                        if flags[p] & 1 != 0 { own += 1 }; if flags[p] & 2 != 0 { foreign += 1 }; if flags[p] & 4 != 0 { inside += 1 }
                        if x == 0 || x == columns - 1 || y == 0 || y == rows - 1 { open = true }
                        for yy in max(0, y - 1)...min(rows - 1, y + 1) {
                            for xx in max(0, x - 1)...min(columns - 1, x + 1) {
                                let next = yy * columns + xx
                                if mask[next] != 0 { mask[next] = 0; queue.append(next) }
                            }
                        }
                    }
                    let w = x1 - x0 + 1, h = y1 - y0 + 1, area = queue.count
                    let fill = Double(area) / Double(w * h)
                    var reason: String?
                    if open { reason = "open" }
                    else if area < minimumArea { reason = "tiny" }
                    else if CGFloat(w) > nominal * 1.7 || CGFloat(h) > nominal * 2.2 { reason = "outside-glyph-scale" }
                    else if fill < 0.08 { reason = "too-sparse" }
                    else if fill > 0.88 && CGFloat(area) > 0.35 * nominal * nominal && CGFloat(min(w, h)) > nominal * 0.4 {
                        reason = "solid-background"
                    }
                    else if Double(foreign) > max(1, Double(area) * 0.1) { reason = "foreign-owner" }
                    if let reason { result.rejections[reason, default: 0] += 1; continue }
                    let bounds = CGRect(x: left + CGFloat(x0) * step, y: top + CGFloat(y0) * step,
                        width: CGFloat(w) * step, height: CGFloat(h) * step)
                    if result.components.contains(where: { max(abs($0.bounds.minX - bounds.minX), abs($0.bounds.minY - bounds.minY),
                        abs($0.bounds.maxX - bounds.maxX), abs($0.bounds.maxY - bounds.maxY)) < step * 1.1 }) { continue }
                    var rowMin = [Int](repeating: columns, count: h), rowMax = [Int](repeating: -1, count: h)
                    for p in queue { let y = p / columns - y0, x = p % columns; rowMin[y] = min(rowMin[y], x); rowMax[y] = max(rowMax[y], x) }
                    var boundary: [CGPoint] = []
                    for y in 0..<h where rowMax[y] >= 0 {
                        boundary.append(.init(x: CGFloat(rowMin[y]), y: CGFloat(y + y0)))
                        boundary.append(.init(x: CGFloat(rowMax[y]), y: CGFloat(y + y0)))
                    }
                    let hull = convexHull(boundary).map { CGPoint(x: left + ($0.x + 0.5) * step, y: top + ($0.y + 0.5) * step) }
                    result.components.append(.init(colour: colour, pixels: area, ownedPixels: own, foreignPixels: foreign,
                        insidePixels: inside, bounds: bounds,
                        center: .init(x: left + (CGFloat(sumX) / CGFloat(area) + 0.5) * step,
                                      y: top + (CGFloat(sumY) / CGFloat(area) + 0.5) * step), hull: hull))
                }
            }
            var privatePoints: [CGPoint] = []
            var privateCapture: NativeOCRPrivateObservation.State? = capturePrivateObservation ? .init() : nil
            for cell in ownedCells {
                let world = CGPoint(x: (CGFloat(cell % mw) + 0.5) * sx, y: (CGFloat(cell / mw) + 0.5) * sy)
                let p = result.project(world)
                if p.x >= rect.minX - 1e-6 && p.x <= rect.maxX + 1e-6 && p.y >= rect.minY - 1e-6 && p.y <= rect.maxY + 1e-6 {
                    let rounded = CGPoint(x: CGFloat(Float(p.x)), y: CGFloat(Float(p.y)))
                    privatePoints.append(rounded)
                    privateCapture?.append(floatRoundedLocal: rounded, origin: result.origin,
                        normal: result.normal, along: result.along) { x, y in
                        guard x >= 0, y >= 0, x < frame.width, y < frame.height else { return nil }
                        let offset = y * frame.bytesPerRow + x * 4
                        return SIMD4(frame.bytes[offset], frame.bytes[offset + 1],
                                     frame.bytes[offset + 2], frame.bytes[offset + 3])
                    }
                }
                if contains(polygon, world) { result.guardPoints.append(world) }
            }
            result.privateHull = convexHull(privatePoints); result.privateSamples = privatePoints.count
            result.privateObservation = privateCapture?.retained
            if captureDensePrivateFootprint, result.privateObservation != nil {
                result.privateObservation?.footprint = .init(width: mw, height: mh,
                    scaleX: sx, scaleY: sy, cells: Set(ownedCells))
            }
            result.status = "measured"
            return result
        }
    }

    static func colourDistance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int { max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z)) }
    static func convexHull(_ input: [CGPoint]) -> [CGPoint] {
        let points = input.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard points.count > 2 else { return points }
        func cross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint) -> CGFloat {
            (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x)
        }
        var lower: [CGPoint] = [], upper: [CGPoint] = []
        for p in points {
            while lower.count >= 2 && cross(lower[lower.count - 2], lower[lower.count - 1], p) <= 0 { lower.removeLast() }
            lower.append(p)
        }
        for p in points.reversed() {
            while upper.count >= 2 && cross(upper[upper.count - 2], upper[upper.count - 1], p) <= 0 { upper.removeLast() }
            upper.append(p)
        }
        lower.removeLast(); upper.removeLast(); return lower + upper
    }
    static func contains(_ polygon: [CGPoint], _ point: CGPoint, tolerance: CGFloat = 0) -> Bool {
        var positive = false, negative = false
        for i in polygon.indices {
            let a = polygon[i], b = polygon[(i + 1) % polygon.count]
            let c = (b.x - a.x) * (point.y - a.y) - (b.y - a.y) * (point.x - a.x)
            if c > 1e-7 { positive = true }; if c < -1e-7 { negative = true }
        }
        if !positive || !negative { return true }
        guard tolerance > 0 else { return false }
        return polygon.indices.contains { i in
            let a = polygon[i], b = polygon[(i + 1) % polygon.count], dx = b.x - a.x, dy = b.y - a.y
            let length = dx * dx + dy * dy
            let t = length > 0 ? max(0, min(1, ((point.x - a.x) * dx + (point.y - a.y) * dy) / length)) : 0
            return hypot(point.x - a.x - t * dx, point.y - a.y - t * dy) <= tolerance
        }
    }
}
