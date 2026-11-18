import Foundation

/// Physical paint/component observations, appended to (never replacing) incumbents.
/// No recognizer, model execution, stored proposals, page routing or overlap-based
/// owner assignment. RF rectangles are not masks and are deliberately unused.
///
/// Direct original-array references may authenticate DB contact. A detached
/// same-paint continuation, outline Voronoi association, or query-rooted hole
/// remains UNKNOWN membership; none authorizes erasure or a rewritten seed.
@available(iOS 18.0, *)
enum NativeOCRSourcePaintColumnPartition {
    static let sourceBudgetEnvironmentKey = "AIDOKU_OCR_SOURCE_BUDGET_MODE"
    static var sourceBudgetV2Enabled: Bool {
        let mode = ProcessInfo.processInfo.environment[sourceBudgetEnvironmentKey]
        return NativeOCRSourcePaintGeometry.sourceFirstGeneration || mode == "v2" || mode == "source-first-v2"
    }
    static var sourceFirstV2Enabled: Bool {
        NativeOCRSourcePaintGeometry.sourceFirstGeneration
            || ProcessInfo.processInfo.environment[sourceBudgetEnvironmentKey] == "source-first-v2"
    }
    static let recoveryV3EnvironmentKey = "AIDOKU_OCR_GENERATION_RECOVERY_V3"
    static var recoveryV3Enabled: Bool {
        ProcessInfo.processInfo.environment[recoveryV3EnvironmentKey] == "1"
    }
    private typealias ROI = NativeOCRSourcePaintGeometry.PixelROI
    private typealias Query = NativeOCRSourcePaintGeometry.Query
    private typealias Measurement = NativeOCRSourcePaintGeometry.Measurement
    private typealias Original = NativeOCRSourceOwnedRailPartition.Original

    /// Opt-in producer arbitration for ONE serial generate() invocation. The
    /// caller must create a fresh ledger per immutable frame/original/RF bank
    /// and global producer plan;
    /// never share it across pages, frames, changed evidence or concurrent jobs.
    /// Keys describe exact producer inputs, not output-box similarity. A full
    /// ledger fails open. Legacy jobs retain counts only; v2 may also retain
    /// bounded scalar measurements for exact replay, never pixels or masks.
    final class GenerationLedger {
        private struct Key: Hashable {
            let family: String
            let owner: Int
            let polygon: [[Double]]
            let window: [Int]
        }
        private var completed: [Key: Int] = [:]
        private struct PhysicalKey: Hashable {
            let family: String
            let polygon: [[Double]]
            let window: [Int]
            let inputs: [Int]
            let replayPositive: Bool
        }
        private struct PhysicalResult {
            let count: Int
            let replay: [NativeOCRSourcePaintGeometry.Measurement]
        }
        private var physicalCompleted: [PhysicalKey: PhysicalResult] = [:]
        private let capacity: Int
        private let maximumPhysicalInputWords: Int
        let sourceBudgetV2Enabled: Bool
        let sourceFirstV2Enabled: Bool
        private(set) var skippedJobs = 0
        private(set) var retiredMeasurements = 0
        private(set) var skippedEmptyColumnJobs = 0
        private(set) var replayedColumnMeasurements = 0
        private(set) var reusedColumnTopologyStages = 0
        private(set) var skippedColumnBoundaryFits = 0
        private(set) var retainedPhysicalInputWords = 0
        private(set) var sourceFirstProducerJobs = 0
        private(set) var sourceFirstProducerJobsAvoided = 0
        private(set) var sourceFirstPaletteModesAttempted = 0
        private(set) var sourceFirstPaletteModesAvoided = 0

        init(capacity: Int = 4096,
             sourceBudgetV2Enabled: Bool = NativeOCRSourcePaintColumnPartition.sourceBudgetV2Enabled,
             sourceFirstV2Enabled: Bool = NativeOCRSourcePaintColumnPartition.sourceFirstV2Enabled,
             maximumPhysicalInputWords: Int = 262_144) {
            self.capacity = max(0, capacity)
            self.sourceBudgetV2Enabled = sourceBudgetV2Enabled || sourceFirstV2Enabled
            self.sourceFirstV2Enabled = sourceFirstV2Enabled
            self.maximumPhysicalInputWords = max(0, maximumPhysicalInputWords)
        }

        /// Column kernels have no query-local filtering after this closure.
        /// Empty results are deterministic only for this complete physical key;
        /// do not apply negative caching to generic run() clients in other files.
        func runColumn(family: String, polygon: [[Double]], window: [Int], inputs: [Int],
                       replayPositive: Bool = false,
                       _ body: () -> [NativeOCRSourcePaintGeometry.Measurement]) -> [NativeOCRSourcePaintGeometry.Measurement] {
            guard sourceBudgetV2Enabled else { return body() }
            let key = PhysicalKey(family: family, polygon: polygon, window: window,
                                  inputs: inputs, replayPositive: replayPositive)
            if let cached = physicalCompleted[key] {
                skippedJobs += 1
                if cached.count == 0 { skippedEmptyColumnJobs += 1 }
                if replayPositive {
                    replayedColumnMeasurements += cached.count
                    return cached.replay
                }
                retiredMeasurements += cached.count
                return []
            }
            let result = body()
            // Capacity exhaustion fails open. Bound run identities to ~2 MiB;
            // three-tone replay has at most one scalar measurement per key.
            if completed.count + physicalCompleted.count < capacity,
               inputs.count <= maximumPhysicalInputWords - retainedPhysicalInputWords,
               !replayPositive || result.count <= 1 {
                physicalCompleted[key] = PhysicalResult(count: result.count, replay: replayPositive ? result : [])
                retainedPhysicalInputWords += inputs.count
            }
            return result
        }

        fileprivate func topologyReused() { reusedColumnTopologyStages += 1 }
        fileprivate func boundaryFitSkipped() { skippedColumnBoundaryFits += 1 }
        fileprivate func producerStarted() { sourceFirstProducerJobs += 1 }
        fileprivate func producersAvoided(_ count: Int) { sourceFirstProducerJobsAvoided += count }
        fileprivate func paletteStarted() { sourceFirstPaletteModesAttempted += 1 }
        fileprivate func paletteAvoided(_ count: Int) { sourceFirstPaletteModesAvoided += count }

        func run(family: String, owner: Int = -1, polygon: [[Double]], window: [Int],
                 _ body: () -> [NativeOCRSourcePaintGeometry.Measurement]) -> [NativeOCRSourcePaintGeometry.Measurement] {
            let key = Key(family: family, owner: owner, polygon: polygon, window: window)
            if let count = completed[key] {
                skippedJobs += 1
                retiredMeasurements += count
                return []
            }
            let result = body()
            // Commit only offers returned to the wrapper, after local validity
            // filtering. A rejected first query cannot suppress a later offer.
            if !result.isEmpty && completed.count + physicalCompleted.count < capacity { completed[key] = result.count }
            return result
        }
    }

    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI,
                        query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original],
                        rf: [NativeOCRSourceContext50V2.Primitive],
                        generationLedger: GenerationLedger? = nil) -> [NativeOCRSourcePaintGeometry.Measurement] {
        guard roi.width > 2, roi.height > 2, roi.width <= 1_500_000 / roi.height,
              roi.rgb.count == roi.width * roi.height * 3, basis(query.polygon) != nil else { return [] }
        if recoveryV3Enabled {
            let recovered = recoverNormal(roi: roi, query: query, originals: originals)
            if !recovered.isEmpty { return recovered }
        }
        if let generationLedger, generationLedger.sourceFirstV2Enabled {
            return sourceFirst(roi: roi, query: query, originals: originals, ledger: generationLedger)
        }
        var outputs = closedPaint(roi: roi, query: query.polygon, generationLedger: generationLedger)
        // sourceIndex is an observation identity, NOT a raw-array index. Even
        // an in-range corrected sourceIndex establishes no raw ancestry.
        var indices = Array(Set(query.sourceMembers)).sorted()
        if indices.isEmpty {
            // Exact coordinate equality (allowing vertex rotation/reversal),
            // with UNIQUE original identity. No tolerance or nearest-box match.
            let exact = originals.indices.filter { sameQuad(originals[$0].polygon, query.polygon) }
            if exact.count == 1 { indices = exact }
        }
        // Invalid explicit lineage cannot be silently reduced to a partial owner.
        guard indices.allSatisfy({ originals.indices.contains($0) }) else { return outputs }
        for index in indices {
            let original = originals[index]
            guard let seed = original.detectorSeedEvidence, valid(seed, roi: roi),
                  let b = basis(original.polygon) else { continue }
            // Other independently observed raw owners remain barriers, including
            // another member of the same query. Membership is never inferred by IoU.
            let foreign = originals.indices.filter { $0 != index }.compactMap { i -> NativeOCRDetectorSeedEvidence? in
                guard let s = originals[i].detectorSeedEvidence, valid(s, roi: roi),
                      s.sourceWidth == seed.sourceWidth, s.sourceHeight == seed.sourceHeight else { return nil }
                return s
            }
            if let tile = tile(roi, polygon: original.polygon, normalMargin: 0, alongMargin: 0) {
                outputs += once(generationLedger, family: "column.outlined", owner: index,
                                polygon: original.polygon, tile: tile, seed: seed, foreign: foreign) {
                    outlinedColumns(tile, b: b, seed: seed, foreign: foreign)
                }
            }
            if NativeOCRSourcePaintGeometry.shouldGenerate("db-owned-three-tone-rim-voronoi-envelope-v1"),
               let tile = tile(roi, polygon: original.polygon, normalMargin: 0.6 * b.width,
                               alongMargin: 0.6 * b.width) {
                if generationLedger?.sourceBudgetV2Enabled == true {
                    // Replay identical observations to every query: the wrapper
                    // still needs its own reservation/validity/reference context.
                    outputs += once(generationLedger, family: "column.three-tone", owner: index,
                                    polygon: original.polygon, tile: tile, seed: seed, foreign: foreign,
                                    replayPositive: true) {
                        threeToneRim(tile, polygon: original.polygon, b: b, seed: seed, foreign: foreign)
                    }
                } else {
                    outputs += threeToneRim(tile, polygon: original.polygon, b: b, seed: seed, foreign: foreign)
                }
            }
            let xs = original.polygon.map { $0[0] }, ys = original.polygon.map { $0[1] }
            if let tile = window(roi, left: xs.min()! - 0.15 * (xs.max()! - xs.min()!),
                                 top: ys.min()! - 0.15 * (ys.max()! - ys.min()!),
                                 right: xs.max()! + 0.15 * (xs.max()! - xs.min()!),
                                 bottom: ys.max()! + 0.15 * (ys.max()! - ys.min()!)) {
                outputs += once(generationLedger, family: "column.unit-spine", owner: index,
                                polygon: original.polygon, tile: tile, seed: seed, foreign: foreign) {
                    unitSpine(tile, polygon: original.polygon, b: b, seed: seed, foreign: foreign)
                }
            }
        }
        // Every distinct qualifying physical layer is returned. Shared wrapper counts
        // observations and handles exact geometric duplicates, without a GT rank.
        return outputs
    }

    /// Opt-in, single physical refit. The caller may pass the already measured
    /// primary and replace it BEFORE emission; this API never schedules queries.
    /// No cache is shared with v2: uncertain run barriers and primary geometry
    /// are additional read inputs. RF rectangles cannot certify stroke membership.
    static func recoverNormal(roi: NativeOCRSourcePaintGeometry.PixelROI,
                              query: NativeOCRSourcePaintGeometry.Query,
                              originals: [NativeOCRSourceOwnedRailPartition.Original],
                              primary: NativeOCRSourcePaintGeometry.Measurement? = nil)
        -> [NativeOCRSourcePaintGeometry.Measurement] {
        let mechanism = "db-contact-unit-consensus-normal-recovery-v3"
        guard recoveryV3Enabled, NativeOCRSourcePaintGeometry.shouldGenerate(mechanism),
              roi.width > 2, roi.height > 2, roi.width <= 1_500_000 / roi.height,
              roi.rgb.count == 3 * roi.width * roi.height else { return [] }
        let explicit = Array(Set(query.sourceMembers))
        let exact = originals.indices.filter { sameQuad(originals[$0].polygon, query.polygon) }
        let members = explicit.isEmpty ? exact : explicit
        // A group is not one physical owner. Never pick its first sourceIndex.
        guard members.count == 1, let owner = members.first, originals.indices.contains(owner),
              let seed = originals[owner].detectorSeedEvidence, valid(seed, roi: roi),
              let b = basis(originals[owner].polygon),
              let t = tile(roi, polygon: originals[owner].polygon,
                           normalMargin: 0.5 * b.width, alongMargin: 0.5 * b.width),
              Double(t.count) <= 0.15 * Double(seed.sourceWidth) * Double(seed.sourceHeight),
              let (threshold, _, _) = otsu(t.gray, three: false) else { return [] }
        let sx = Double(seed.sourceWidth) / Double(seed.mapFullWidth)
        let sy = Double(seed.sourceHeight) / Double(seed.mapFullHeight)
        let normalCell = abs(b.n.x) * sx + abs(b.n.y) * sy
        let alongCell = abs(b.a.x) * sx + abs(b.a.y) * sy
        let db = raster(t, [seed])
        var barrier = [Bool](repeating: false, count: t.count)
        func block(_ evidence: NativeOCRDetectorSeedEvidence) {
            func runs(_ component: NativeOCRDetectorSeedEvidence.Component) {
                for r in component.runs {
                    let l = max(0, Int(floor(Double(r.x) * sx)) - t.x)
                    let right = min(t.w, Int(ceil(Double(r.x + r.count) * sx)) - t.x)
                    let top = max(0, Int(floor(Double(r.y) * sy)) - t.y)
                    let bottom = min(t.h, Int(ceil(Double(r.y + 1) * sy)) - t.y)
                    if right > l && bottom > top {
                        for y in top..<bottom { for x in l..<right { barrier[y * t.w + x] = true } }
                    }
                }
            }
            for c in evidence.components { runs(c) }
            for c in evidence.ambiguousComponents ?? [] { runs(c) }
            for c in evidence.candidateComponents ?? [] { runs(c.component) }
        }
        for i in originals.indices where i != owner {
            guard let foreign = originals[i].detectorSeedEvidence else { continue }
            guard foreign.isValid, foreign.ownershipVersion == 2, foreign.completeCCScan == true,
                  foreign.sourceWidth == seed.sourceWidth, foreign.sourceHeight == seed.sourceHeight,
                  foreign.mapFullWidth == seed.mapFullWidth, foreign.mapFullHeight == seed.mapFullHeight else { return [] }
            block(foreign)
        }
        // Choose one polarity from private measured DB contact BEFORE launching
        // CC work. A tie is unknown, not permission for two phase variants.
        var low = 0, high = 0
        for i in db.indices where db[i] && !barrier[i] {
            if t.gray[i] <= threshold { low += 1 } else { high += 1 }
        }
        guard low != high else { return [] }
        let bright = high > low
        let cc = components(t.gray.map { bright ? $0 > threshold : $0 <= threshold }, w: t.w, h: t.h)
        var parts = cc.parts.dropFirst().filter { c in
            !c.border && c.pixels.contains { db[$0] && !barrier[$0] }
                && !c.pixels.contains { barrier[$0] }
        }
        guard !parts.isEmpty else { return [] }
        // A persistent transverse empty strip separates physical support modes.
        // Each mode has its own DB contacts. Only a uniquely strongest mode may
        // nominate the one boundary; tied columns remain unresolved.
        struct Mode { var parts: [Component]; var low: Double; var high: Double; var hits: Int }
        let ordered = parts.sorted { l, r in
            l.pixels.map { t.point($0).dot(b.n) }.min()! < r.pixels.map { t.point($0).dot(b.n) }.min()!
        }
        var modes = [Mode]()
        for c in ordered {
            let spans = c.pixels.map { t.point($0).dot(b.n) }
            let l = spans.min()!, h = spans.max()!, hits = c.pixels.filter { db[$0] }.count
            if let last = modes.last, l <= last.high + normalCell {
                modes[modes.count - 1].parts.append(c)
                modes[modes.count - 1].high = max(last.high, h)
                modes[modes.count - 1].hits += hits
            } else { modes.append(Mode(parts: [c], low: l, high: h, hits: hits)) }
        }
        if modes.count > 1 {
            let ranked = modes.sorted { $0.hits > $1.hits }
            guard ranked[0].hits > ranked[1].hits else { return [] }
            parts = ranked[0].parts
        }
        struct Unit { var pixels: [Int]; var low: Double; var high: Double }
        var units = [Unit]()
        for c in parts.sorted(by: {
            $0.pixels.map { t.point($0).dot(b.a) }.min()! < $1.pixels.map { t.point($0).dot(b.a) }.min()!
        }) {
            let spans = c.pixels.map { t.point($0).dot(b.a) }, l = spans.min()!, h = spans.max()!
            if let last = units.last, l <= last.high + alongCell {
                units[units.count - 1].pixels += c.pixels
                units[units.count - 1].high = max(last.high, h)
            } else { units.append(Unit(pixels: c.pixels, low: l, high: h)) }
        }
        guard units.count >= 2 else { return [] }
        let anchors = units.map { u -> P in
            let hits = u.pixels.filter { db[$0] }
            return P(x: median(hits.map { t.point($0).dot(b.a) }),
                     y: median(hits.map { t.point($0).dot(b.n) }))
        }
        var slopes = [Double]()
        for i in anchors.indices { for j in (i + 1)..<anchors.count {
            let delta = anchors[j].x - anchors[i].x
            if delta > alongCell { slopes.append((anchors[j].y - anchors[i].y) / delta) }
        } }
        guard !slopes.isEmpty else { return [] }
        let slope = median(slopes), norm = sqrt(1 + slope * slope)
        guard abs(slope) <= tan(10 * Double.pi / 180) else { return [] }
        let a = b.a.plus(b.n.times(slope)).times(1 / norm)
        let n = b.n.minus(b.a.times(slope)).times(1 / norm)
        let halfNormal = 0.5 * (abs(n.x) + abs(n.y)), halfAlong = 0.5 * (abs(a.x) + abs(a.y))
        // Equal physical units vote once, irrespective of dark-pixel density.
        // Outermost deciles retain irregular outer strokes without letting one
        // large attached patch dominate the canonical transverse boundary.
        let left = units.map { $0.pixels.map { t.point($0).dot(n) }.min()! - halfNormal }.sorted()
        let right = units.map { $0.pixels.map { t.point($0).dot(n) }.max()! + halfNormal }.sorted()
        let nl = left[Int(floor(0.1 * Double(left.count - 1)))]
        let nh = right[Int(ceil(0.9 * Double(right.count - 1)))]
        let support = units.flatMap { $0.pixels }
        let observedAlong = support.map { t.point($0).dot(a) }
        let rawAlong = originals[owner].polygon.map { P(x: $0[0], y: $0[1]).dot(a) }
        let al = min(rawAlong.min()!, observedAlong.min()! - halfAlong)
        let ah = max(rawAlong.max()!, observedAlong.max()! + halfAlong)
        let reference = primary?.polygon ?? originals[owner].polygon
        guard basis(reference) != nil else { return [] }
        let referenceNormal = reference.map { P(x: $0[0], y: $0[1]).dot(n) }
        let referenceAlong = reference.map { P(x: $0[0], y: $0[1]).dot(a) }
        let changed = abs(nl - referenceNormal.min()!) > normalCell
            || abs(nh - referenceNormal.max()!) > normalCell
            || abs(al - referenceAlong.min()!) > alongCell || abs(ah - referenceAlong.max()!) > alongCell
        guard changed else { return [] }
        let q = corners(n: n, a: a, nl: nl, nh: nh, al: al, ah: ah)
        guard q.allSatisfy({ $0[0] >= Double(t.x) && $0[0] <= Double(t.x + t.w)
            && $0[1] >= Double(t.y) && $0[1] <= Double(t.y + t.h) }) else { return [] }
        return [observation(q, layer: bright ? "private-DB-bright-unit-consensus" : "private-DB-dark-unit-consensus",
            mechanism: mechanism, diagnostics: ["recoveryV3": 1, "unitCount": Double(units.count),
                "physicalNormalModes": Double(modes.count), "phaseDBHits": Double(max(low, high)),
                "observedSupportPixels": Double(support.count), "axisSlopeDelta": slope,
                "normalWidth": nh - nl, "sourceOnlyPolarityVote": 1, "maxRecoveryOffers": 1,
                "detectorAlongPreserved": 1, "completeOuterRimCertified": 0])]
    }

    /// Experimental source-first producer budget, not a late candidate selector.
    /// One actual original source contributes at most ONE new column boundary;
    /// its unchanged original detector observation is the caller's fallback.
    /// Stop before invoking later pixel producers or allocating their variants.
    private static func sourceFirst(roi: ROI, query: Query, originals: [Original],
                                    ledger: GenerationLedger) -> [Measurement] {
        var indices = Array(Set(query.sourceMembers)).sorted()
        if indices.isEmpty {
            let exact = originals.indices.filter { sameQuad(originals[$0].polygon, query.polygon) }
            if exact.count == 1 { indices = exact }
        }
        guard indices.allSatisfy({ originals.indices.contains($0) }) else { return [] }
        var outputs = [Measurement]()
        for index in indices {
            let original = originals[index]
            guard let seed = original.detectorSeedEvidence, valid(seed, roi: roi),
                  let b = basis(original.polygon) else { continue }
            let foreign = originals.indices.filter { $0 != index }.compactMap { i -> NativeOCRDetectorSeedEvidence? in
                guard let value = originals[i].detectorSeedEvidence, valid(value, roi: roi),
                      value.sourceWidth == seed.sourceWidth, value.sourceHeight == seed.sourceHeight else { return nil }
                return value
            }
            // Cache the cascade's EMPTY result too: every read input below is
            // source-local and exact. No source/query ID serves as ownership.
            let xs = original.polygon.map { $0[0] }, ys = original.polygon.map { $0[1] }
            func requested(_ normal: Double, _ along: Double) -> [Int] {
                let q = corners(n: b.n, a: b.a, nl: b.nl-normal, nh: b.nh+normal,
                                al: b.al-along, ah: b.ah+along)
                return windowIdentity(roi, left: q.map { $0[0] }.min()!, top: q.map { $0[1] }.min()!,
                                      right: q.map { $0[0] }.max()!, bottom: q.map { $0[1] }.max()!)
            }
            // Only window identities/availability are formed here, not pixels.
            // A larger enclosing ROI can reuse identical actual producer windows.
            let spineWindow = windowIdentity(roi, left: xs.min()!-0.15*(xs.max()!-xs.min()!),
                                              top: ys.min()!-0.15*(ys.max()!-ys.min()!),
                                              right: xs.max()!+0.15*(xs.max()!-xs.min()!),
                                              bottom: ys.max()!+0.15*(ys.max()!-ys.min()!))
            let bounds = requested(0.6*b.width, 0.6*b.width) + requested(b.width, 0.8*b.width) + spineWindow
            outputs += ledger.runColumn(family: "column.source-first-v2", polygon: original.polygon,
                                        window: bounds, inputs: physicalInputs(seed: seed, foreign: foreign),
                                        replayPositive: true) {
                if NativeOCRSourcePaintGeometry.shouldGenerate("db-owned-three-tone-rim-voronoi-envelope-v1"),
                   let t = tile(roi, polygon: original.polygon, normalMargin: 0.6*b.width, alongMargin: 0.6*b.width) {
                    ledger.producerStarted()
                    let result = threeToneRim(t, polygon: original.polygon, b: b, seed: seed, foreign: foreign)
                    if !result.isEmpty {
                        ledger.producersAvoided(3) // closed paint, outlined split, unit spine.
                        return result
                    }
                }
                ledger.producerStarted()
                let closed: [Measurement]
                if let t = tile(roi, polygon: original.polygon, normalMargin: b.width, alongMargin: 0.8*b.width) {
                    // Do not nest a retire-on-hit ledger inside this replayable
                    // cascade: that would make the result depend on prior jobs.
                    closed = closedPaintPixels(t, query: original.polygon, b: b, ledger: ledger)
                } else { closed = [] }
                if !closed.isEmpty {
                    ledger.producersAvoided(2) // outlined split and unit spine.
                    return closed
                }
                // The multi-column Cartesian producer is deliberately not
                // invoked in this experiment; source originals remain intact.
                ledger.producersAvoided(1)
                guard let t = window(roi, left: xs.min()! - 0.15*(xs.max()!-xs.min()!),
                                     top: ys.min()! - 0.15*(ys.max()!-ys.min()!),
                                     right: xs.max()! + 0.15*(xs.max()!-xs.min()!),
                                     bottom: ys.max()! + 0.15*(ys.max()!-ys.min()!)) else { return [] }
                ledger.producerStarted()
                return unitSpine(t, polygon: original.polygon, b: b, seed: seed, foreign: foreign)
            }
        }
        return outputs
    }

    private struct P {
        var x: Double, y: Double
        func dot(_ p: P) -> Double { x * p.x + y * p.y }
        func plus(_ p: P) -> P { P(x: x + p.x, y: y + p.y) }
        func minus(_ p: P) -> P { P(x: x - p.x, y: y - p.y) }
        func times(_ s: Double) -> P { P(x: x * s, y: y * s) }
        var length: Double { hypot(x, y) }
    }
    private struct Basis {
        let a: P, n: P
        let nl: Double, nh: Double, al: Double, ah: Double
        var width: Double { nh - nl }
    }
    private struct Tile {
        let w: Int, h: Int, x: Int, y: Int
        let rgb: [Double], gray: [Int]
        var count: Int { w * h }
        func point(_ i: Int) -> P { P(x: Double(x + i % w) + 0.5, y: Double(y + i / w) + 0.5) }
    }
    private static func once(_ ledger: GenerationLedger?, family: String, owner: Int = -1,
                             polygon: [[Double]], tile: Tile,
                             seed: NativeOCRDetectorSeedEvidence? = nil,
                             foreign: [NativeOCRDetectorSeedEvidence] = [], replayPositive: Bool = false,
                             _ body: () -> [Measurement]) -> [Measurement] {
        guard let ledger else { return body() }
        if ledger.sourceBudgetV2Enabled {
            return ledger.runColumn(family: family, polygon: polygon,
                                    window: [tile.x, tile.y, tile.w, tile.h],
                                    inputs: physicalInputs(seed: seed, foreign: foreign),
                                    replayPositive: replayPositive, body)
        }
        return ledger.run(family: family, owner: owner, polygon: polygon,
                          window: [tile.x, tile.y, tile.w, tile.h], body)
    }

    /// Exact read-set of raster() and unitSpine's DB-center projection. Metadata
    /// validation occurs before this key; owner IDs, source indices and probability
    /// summaries are not read by those kernels. Preserve ordered runs and every
    /// scale/barrier input, with lengths so concatenations cannot alias.
    private static func physicalInputs(seed: NativeOCRDetectorSeedEvidence?,
                                       foreign: [NativeOCRDetectorSeedEvidence]) -> [Int] {
        var words = [Int]()
        func append(_ value: NativeOCRDetectorSeedEvidence) {
            words += [value.sourceWidth, value.sourceHeight, value.mapFullWidth, value.mapFullHeight,
                      value.components.count]
            for component in value.components {
                words.append(component.runs.count)
                for run in component.runs { words += [run.y, run.x, run.count] }
            }
        }
        words.append(seed == nil ? 0 : 1)
        if let seed { append(seed) }
        words.append(foreign.count)
        for value in foreign { append(value) }
        return words
    }

    private struct Component {
        var pixels: [Int] = []
        var border = false
    }
    private struct Components {
        let labels: [Int], parts: [Component]
    }
    private static func basis(_ q: [[Double]]) -> Basis? {
        guard q.count == 4, q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
        let p = q.map { P(x: $0[0], y: $0[1]) }
        let edges = (0..<4).map { p[($0+1)%4].minus(p[$0]) }
        guard edges.allSatisfy({ $0.length > 0 }), var a = edges.max(by: { $0.length < $1.length }) else { return nil }
        a = a.times(1/a.length)
        if a.y < 0 || (a.y == 0 && a.x < 0) { a = a.times(-1) }
        let n = P(x: a.y, y: -a.x)
        let ns = p.map { $0.dot(n) }, ts = p.map { $0.dot(a) }
        guard ns.max()! > ns.min()!, ts.max()! > ts.min()! else { return nil }
        return Basis(a: a, n: n, nl: ns.min()!, nh: ns.max()!, al: ts.min()!, ah: ts.max()!)
    }
    private static func corners(n: P, a: P, nl: Double, nh: Double, al: Double, ah: Double) -> [[Double]] {
        [(nl,al),(nh,al),(nh,ah),(nl,ah)].map { u,v in
            let p = n.times(u).plus(a.times(v)); return [p.x,p.y]
        }
    }
    private static func sameQuad(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        guard a.count == 4, b.count == 4,
              (a+b).allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return false }
        for reverse in [false,true] { for offset in 0..<4 {
            if (0..<4).allSatisfy({ i in
                let j = (offset + (reverse ? 4-i : i)) % 4
                return a[i][0] == b[j][0] && a[i][1] == b[j][1]
            }) { return true }
        } }
        return false
    }
    private static func tile(_ roi: ROI, polygon: [[Double]], normalMargin: Double, alongMargin: Double) -> Tile? {
        guard let b = basis(polygon) else { return nil }
        let q = corners(n: b.n, a: b.a, nl: b.nl-normalMargin, nh: b.nh+normalMargin,
                        al: b.al-alongMargin, ah: b.ah+alongMargin)
        return window(roi, left: q.map{$0[0]}.min()!, top: q.map{$0[1]}.min()!,
                      right: q.map{$0[0]}.max()!, bottom: q.map{$0[1]}.max()!)
    }
    /// Metadata-only counterpart of window(). The leading availability tag
    /// prevents a clipped/missing context from aliasing a complete pixel job.
    private static func windowIdentity(_ roi: ROI, left: Double, top: Double, right: Double, bottom: Double) -> [Int] {
        let l = floor(left), t = floor(top), r = ceil(right), b = ceil(bottom)
        guard [l,t,r,b].allSatisfy(\.isFinite), r > l, b > t,
              l >= Double(roi.originX), t >= Double(roi.originY),
              r <= Double(roi.originX + roi.width), b <= Double(roi.originY + roi.height) else { return [0] }
        let w = Int(r-l), h = Int(b-t)
        guard w > 2, h > 2, w <= 1_000_000 / h else { return [0] }
        return [1, Int(l), Int(t), w, h]
    }
    private static func window(_ roi: ROI, left: Double, top: Double, right: Double, bottom: Double) -> Tile? {
        // Requested source context is part of the mechanism's evidence contract.
        // Missing any requested pixel abstains, including image-edge clipping;
        // a smaller tile must never silently change palette/rim conventions.
        let l = floor(left), t = floor(top), r = ceil(right), b = ceil(bottom)
        guard [l,t,r,b].allSatisfy(\.isFinite), r > l, b > t,
              l >= Double(roi.originX), t >= Double(roi.originY),
              r <= Double(roi.originX + roi.width), b <= Double(roi.originY + roi.height) else { return nil }
        let x = Int(l), y = Int(t), w = Int(r-l), h = Int(b-t)
        guard w > 2, h > 2, w <= 1_000_000 / h else { return nil }
        var rgb = [Double](); rgb.reserveCapacity(w*h*3)
        var gray = [Int](); gray.reserveCapacity(w*h)
        for yy in y..<(y+h) { for xx in x..<(x+w) {
            let (red,green,blue) = roi.pixel(x: xx-roi.originX, y: yy-roi.originY)
            rgb.append(red); rgb.append(green); rgb.append(blue)
            gray.append(Int((0.299*red + 0.587*green + 0.114*blue).rounded()))
        } }
        return Tile(w: w,h: h,x: x,y: y,rgb: rgb,gray: gray)
    }
    private static func valid(_ s: NativeOCRDetectorSeedEvidence, roi: ROI) -> Bool {
        s.isValid && s.ownershipVersion == 2 && s.completeCCScan == true && !s.components.isEmpty &&
            (s.ambiguousComponents ?? []).isEmpty && (s.candidateComponents ?? []).isEmpty &&
            roi.originX >= 0 && roi.originY >= 0 && roi.originX + roi.width <= s.sourceWidth &&
            roi.originY + roi.height <= s.sourceHeight
    }
    private static func raster(_ t: Tile, _ seeds: [NativeOCRDetectorSeedEvidence]) -> [Bool] {
        var mask = [Bool](repeating: false, count: t.count)
        for s in seeds {
            let sx = Double(s.sourceWidth)/Double(s.mapFullWidth), sy = Double(s.sourceHeight)/Double(s.mapFullHeight)
            for c in s.components { for run in c.runs {
                // Runs already occupy FULL detector coordinates. mapOrigin is
                // metadata, never an additional translation.
                let l = max(0,Int(floor(Double(run.x)*sx))-t.x)
                let r = min(t.w,Int(ceil(Double(run.x+run.count)*sx))-t.x)
                let top = max(0,Int(floor(Double(run.y)*sy))-t.y)
                let bottom = min(t.h,Int(ceil(Double(run.y+1)*sy))-t.y)
                if r > l && bottom > top { for y in top..<bottom { for x in l..<r { mask[y*t.w+x] = true } } }
            } }
        }
        return mask
    }
    private static func components(_ mask: [Bool], w: Int, h: Int, diagonal: Bool = true) -> Components {
        var labels = [Int](repeating: 0,count: mask.count), parts = [Component()]
        for start in mask.indices where mask[start] && labels[start] == 0 {
            let id = parts.count
            var c = Component(pixels: [start], border: false), head = 0
            labels[start] = id
            while head < c.pixels.count {
                let i = c.pixels[head]; head += 1
                let x = i%w, y = i/w
                if x == 0 || y == 0 || x == w-1 || y == h-1 { c.border = true }
                for dy in -1...1 { for dx in -1...1 {
                    if (dx == 0 && dy == 0) || (!diagonal && dx != 0 && dy != 0) { continue }
                    let xx = x+dx, yy = y+dy
                    if xx >= 0 && yy >= 0 && xx < w && yy < h {
                        let j = yy*w+xx
                        if mask[j] && labels[j] == 0 { labels[j] = id; c.pixels.append(j) }
                    }
                } }
            }
            parts.append(c)
        }
        return Components(labels: labels, parts: parts)
    }
    private static func median(_ values: [Double]) -> Double {
        guard !values.isEmpty else { return 0 }
        let v = values.sorted(), m = v.count/2
        return v.count%2 == 0 ? (v[m-1]+v[m])/2 : v[m]
    }
    private static func inside(_ p: P, _ q: [[Double]]) -> Bool {
        var positive = false, negative = false
        for i in 0..<4 {
            let a = q[i], b = q[(i+1)%4]
            let cross = (b[0]-a[0])*(p.y-a[1]) - (b[1]-a[1])*(p.x-a[0])
            positive = positive || cross > 0; negative = negative || cross < 0
        }
        return !(positive && negative)
    }
    private static func envelope(_ pixels: [Int], _ t: Tile, n: P, a: P) -> [[Double]]? {
        guard !pixels.isEmpty else { return nil }
        var nl = Double.greatestFiniteMagnitude, nh = -nl, al = nl, ah = -nl
        for i in pixels {
            let p = t.point(i), u = p.dot(n), v = p.dot(a)
            nl = min(nl,u); nh = max(nh,u); al = min(al,v); ah = max(ah,v)
        }
        let hn = 0.5*(abs(n.x)+abs(n.y)), ha = 0.5*(abs(a.x)+abs(a.y))
        return corners(n: n,a: a,nl: nl-hn,nh: nh+hn,al: al-ha,ah: ah+ha)
    }
    private static func touchesBorder(_ pixels: [Int], _ t: Tile) -> Bool {
        pixels.contains { i in i%t.w == 0 || i%t.w == t.w-1 || i/t.w == 0 || i/t.w == t.h-1 }
    }
    private static func observation(_ polygon: [[Double]], layer: String, mechanism: String,
                                    diagnostics: [String: Double]) -> Measurement {
        var d = diagnostics
        d["detachedMembershipUnknown"] = 1; d["outputPadding"] = 0
        d["RFMaskUsed"] = 0; d["recognizerUsed"] = 0; d["originalEvidenceRewritten"] = 0
        return Measurement(polygon: polygon, layer: layer, mechanism: mechanism, diagnostics: d)
    }

    // Exact squared Euclidean distance transform, separable lower parabolas.
    // Finite sentinel avoids NaNs for an absent competing paint class.
    private static func distances(_ mask: [Bool], _ t: Tile) -> [Double] {
        let infinity = 1e20
        func transform(_ f: [Double]) -> [Double] {
            let sites = f.indices.filter { f[$0] < infinity }
            guard let first = sites.first else { return [Double](repeating: infinity,count: f.count) }
            var v = [first], z = [-Double.greatestFiniteMagnitude, Double.greatestFiniteMagnitude]
            for q in sites.dropFirst() {
                var k = v.count-1
                var s = ((f[q]+Double(q*q))-(f[v[k]]+Double(v[k]*v[k])))/Double(2*(q-v[k]))
                while k > 0 && s <= z[k] {
                    v.removeLast(); z.removeLast(); k -= 1
                    s = ((f[q]+Double(q*q))-(f[v[k]]+Double(v[k]*v[k])))/Double(2*(q-v[k]))
                }
                z[z.count-1] = s; v.append(q); z.append(Double.greatestFiniteMagnitude)
            }
            var k = 0, out = [Double](repeating: 0,count: f.count)
            for q in f.indices {
                while k+1 < v.count && z[k+1] < Double(q) { k += 1 }
                let delta = q-v[k]; out[q] = Double(delta*delta)+f[v[k]]
            }
            return out
        }
        var out = [Double](repeating: infinity,count: t.count)
        for y in 0..<t.h {
            let row = transform((0..<t.w).map { mask[y*t.w+$0] ? 0 : infinity })
            for x in 0..<t.w { out[y*t.w+x] = row[x] }
        }
        for x in 0..<t.w {
            let col = transform((0..<t.h).map { out[$0*t.w+x] })
            for y in 0..<t.h { out[y*t.w+x] = col[y] }
        }
        return out
    }
    private static func steps(_ mask: [Bool], _ t: Tile, radius: Int) -> [Int] {
        var d = [Int](repeating: -1,count: t.count), queue = [Int](), head = 0
        for i in mask.indices where mask[i] { d[i] = 0; queue.append(i) }
        while head < queue.count {
            let i = queue[head]; head += 1
            if d[i] >= radius { continue }
            let x = i%t.w, y = i/t.w
            for dy in -1...1 { for dx in -1...1 {
                let xx = x+dx, yy = y+dy
                if xx >= 0 && yy >= 0 && xx < t.w && yy < t.h {
                    let j = yy*t.w+xx
                    if d[j] < 0 { d[j] = d[i]+1; queue.append(j) }
                }
            } }
        }
        return d
    }
    private static func otsu(_ gray: [Int], three: Bool) -> (Int, Int, [Double])? {
        var hist = [Double](repeating: 0,count: 256)
        for g in gray { hist[g] += 1 }
        var mass = hist, moment = hist
        for i in 0..<256 {
            moment[i] *= Double(i)
            if i > 0 { mass[i] += mass[i-1]; moment[i] += moment[i-1] }
        }
        var best = -Double.greatestFiniteMagnitude, lo = -1, hi = -1
        for a in 1..<254 {
            let ends = three ? Array((a+1)..<255) : [255]
            for b in ends {
                let weights = three ? [mass[a],mass[b]-mass[a],mass[255]-mass[b]] : [mass[a],mass[255]-mass[a]]
                let sums = three ? [moment[a],moment[b]-moment[a],moment[255]-moment[b]] : [moment[a],moment[255]-moment[a]]
                if weights.contains(where: { $0 <= 0 }) { continue }
                let score = zip(sums,weights).reduce(0) { $0 + $1.0*$1.0/$1.1 }
                if score > best { best = score; lo = a; hi = b }
            }
        }
        guard lo >= 0 else { return nil }
        let means: [Double]
        if three {
            means = [moment[lo]/mass[lo],(moment[hi]-moment[lo])/(mass[hi]-mass[lo]),
                     (moment[255]-moment[hi])/(mass[255]-mass[hi])]
        } else { means = [moment[lo]/mass[lo],(moment[255]-moment[lo])/(mass[255]-mass[lo])] }
        return (lo,hi,means)
    }

    /// Repeated physically independent dark columns and a FINITE measured white
    /// shell. Empty core strips establish columns; bbox overlap never splits them.
    private static func outlinedColumns(_ t: Tile, b: Basis, seed: NativeOCRDetectorSeedEvidence,
                                        foreign: [NativeOCRDetectorSeedEvidence]) -> [Measurement] {
        guard abs(b.a.x) <= 0.05, b.ah-b.al >= 1.5*b.width else { return [] }
        let dark = (0..<t.count).map { max(t.rgb[3*$0],max(t.rgb[3*$0+1],t.rgb[3*$0+2])) < 140 }
        let white = (0..<t.count).map { min(t.rgb[3*$0],min(t.rgb[3*$0+1],t.rgb[3*$0+2])) > 210 }
        var spans = [(Int,Int)](), start: Int?
        for x in 0...t.w {
            let active = x < t.w && (0..<t.h).contains { dark[$0*t.w+x] }
            if active && start == nil { start = x }
            if !active, let l = start { spans.append((l,x)); start = nil }
        }
        guard spans.count >= 2 else { return [] }
        let budget = min(32,max(2,Int(ceil(b.width/4))))
        let global = steps(dark,t,radius: budget)
        var peak = 0.0, radius: Int?
        for r in 1...budget {
            let shell = global.indices.filter { global[$0] == r }
            if shell.isEmpty { break }
            let fraction = Double(shell.filter { white[$0] }.count)/Double(shell.count)
            if peak >= 0.5 && fraction < 0.1 { radius = r-1; break }
            peak = max(peak,fraction)
        }
        guard let radius, radius > 0 else { return [] }
        let db = raster(t,[seed]), barriers = raster(t,foreign)
        var out = [Measurement]()
        for (l,r) in spans {
            let core = dark.indices.filter { dark[$0] && $0%t.w >= l && $0%t.w < r }
            guard let top = core.map({$0/t.w}).min(), let bottom = core.map({$0/t.w}).max(),
                  l > 0, r < t.w, top > 0, bottom < t.h-1,
                  Double(bottom-top+1)/Double(r-l) >= 2.5,
                  !core.contains(where: { barriers[$0] }) else { continue }
            let hits = core.filter { db[$0] }.count
            guard Double(hits)/Double(core.count) >= 0.05 else { continue }
            var mask = [Bool](repeating: false,count: t.count)
            for i in core { mask[i] = true }
            let local = steps(mask,t,radius: radius)
            let support = local.indices.filter { local[$0] >= 0 && local[$0] == global[$0] && (dark[$0] || white[$0]) }
            guard !touchesBorder(support,t), let q = envelope(support,t,n: P(x: 1,y: 0),a: P(x: 0,y: 1)) else { continue }
            out.append(observation(q,layer: "dark-core-observed-white-shell",mechanism: "source-outlined-stroke-column-partition-v1",
                diagnostics: ["corePixels":Double(core.count),"DBCorePixels":Double(hits),"measuredRimRadius":Double(radius),
                              "observedCoreIntervals":Double(spans.count),"observedPaintPixels":Double(support.count),
                              "outlineTiesAreNonexclusive":1]))
        }
        return out.count >= 2 ? out : []
    }

    /// Independent three-tone owner/rim observation; surrounding dark CCs are
    /// competitors even when they have no DB owner. Ties stay unassigned.
    private static func threeToneRim(_ t: Tile, polygon: [[Double]], b: Basis,
                                     seed: NativeOCRDetectorSeedEvidence,
                                     foreign: [NativeOCRDetectorSeedEvidence]) -> [Measurement] {
        guard min(abs(b.a.x),abs(b.a.y)) <= sin(5*Double.pi/180),
              let (low,high,means) = otsu(t.gray,three: true), means[1]-means[0] >= 16, means[2]-means[1] >= 16 else { return [] }
        let db = raster(t,[seed]), barrier = raster(t,foreign)
        let cc = components(t.gray.map{$0 <= low},w: t.w,h: t.h)
        var own = [Bool](repeating: false,count: t.count), ids = Set<Int>()
        for id in cc.parts.indices.dropFirst() {
            let p = cc.parts[id].pixels
            guard p.contains(where: { db[$0] && !barrier[$0] }),
                  Double(p.filter { inside(t.point($0),polygon) }.count) > 0.5*Double(p.count),
                  !p.contains(where: { barrier[$0] }) else { continue }
            ids.insert(id); for i in p { own[i] = true }
        }
        guard !ids.isEmpty else { return [] }
        let others = cc.labels.map { $0 != 0 && !ids.contains($0) }
        let ownD = distances(own,t), otherD = distances(others,t)
        let rimCC = components(t.gray.map{$0 > high},w: t.w,h: t.h)
        let near = steps(own,t,radius: 1)
        var rimIDs = Set<Int>()
        for i in near.indices where near[i] >= 0 && rimCC.labels[i] > 0 { rimIDs.insert(rimCC.labels[i]) }
        let rim = own.indices.filter { rimIDs.contains(rimCC.labels[$0]) && ownD[$0] < otherD[$0] }
        let support = own.indices.filter { own[$0] || (rimIDs.contains(rimCC.labels[$0]) && ownD[$0] < otherD[$0]) }
        guard !rim.isEmpty, !touchesBorder(support,t),
              let q = envelope(support,t,n: P(x: 1,y: 0),a: P(x: 0,y: 1)) else { return [] }
        return [observation(q,layer: "DB-contact-dark-core-nearest-bright-rim",mechanism: "db-owned-three-tone-rim-voronoi-envelope-v1",
            diagnostics: ["darkThreshold":Double(low),"brightThreshold":Double(high),"darkComponents":Double(ids.count),
                          "darkPixels":Double(own.filter{$0}.count),"brightPixels":Double(rim.count),"rimComponents":Double(rimIDs.count)])]
    }

    /// Equal-unit robust spine: each physical unit supplies ONE DB-median
    /// anchor, irrespective of pixel area. Detector projections supply both
    /// longitudinal ends; no measured short unit can truncate the detector.
    private static func unitSpine(_ t: Tile, polygon: [[Double]], b: Basis,
                                  seed: NativeOCRDetectorSeedEvidence,
                                  foreign: [NativeOCRDetectorSeedEvidence]) -> [Measurement] {
        guard let (threshold,_,_) = otsu(t.gray,three: false) else { return [] }
        let db = raster(t,[seed]), barrier = raster(t,foreign)
        let sx = Double(seed.sourceWidth)/Double(seed.mapFullWidth), sy = Double(seed.sourceHeight)/Double(seed.mapFullHeight)
        var cells = [P]()
        for c in seed.components { for r in c.runs { for x in r.x..<(r.x+r.count) {
            cells.append(P(x: (Double(x)+0.5)*sx,y: (Double(r.y)+0.5)*sy))
        } } }
        guard cells.count >= 3 else { return [] }
        var certified = [Measurement]()
        struct Unit { var pixels: [Int]; var low: Double; var high: Double }
        for bright in [false,true] {
            let layer = bright ? "equal-units-above-otsu" : "equal-units-below-otsu"
            guard NativeOCRSourcePaintGeometry.shouldGenerate(
                "db-owned-equal-unit-spine-robust-normal-span-preserve-detector-along-v1/" + layer) else { continue }
            let mask = t.gray.map { bright ? $0 > threshold : $0 <= threshold }
            let cc = components(mask,w: t.w,h: t.h)
            let parts = cc.parts.dropFirst().filter { c in
                !c.border && c.pixels.count >= 3 && c.pixels.contains{db[$0]} && !c.pixels.contains{barrier[$0]}
            }
            guard !parts.isEmpty else { continue }
            var selected = [Bool](repeating: false,count: t.count)
            for c in parts { for i in c.pixels { selected[i] = true } }
            let dist = distances(selected.map{!$0},t)
            let diameter = 2*median(selected.indices.filter{selected[$0]}.map{sqrt(dist[$0])})
            var sorted = parts.map { c -> Unit in
                let ts = c.pixels.map{t.point($0).dot(b.a)}
                return Unit(pixels: c.pixels,low: ts.min()!,high: ts.max()!)
            }
            sorted.sort { $0.low < $1.low }
            var units = [Unit]()
            for c in sorted {
                if let last = units.last, c.low-last.high <= diameter {
                    units[units.count-1].pixels += c.pixels
                    units[units.count-1].high = max(last.high,c.high)
                } else { units.append(c) }
            }
            guard (3...12).contains(units.count) else { continue }
            var anchors = [P]()
            for unit in units {
                let support = cells.filter { let v = $0.dot(b.a); return v >= unit.low-sy/2 && v <= unit.high+sy/2 }
                if support.isEmpty { break }
                anchors.append(P(x: median(support.map{$0.dot(b.a)}),y: median(support.map{$0.dot(b.n)})))
            }
            guard anchors.count == units.count else { continue }
            var slopes = [Double]()
            for i in anchors.indices { for j in (i+1)..<anchors.count {
                if anchors[j].x-anchors[i].x > diameter { slopes.append((anchors[j].y-anchors[i].y)/(anchors[j].x-anchors[i].x)) }
            } }
            guard !slopes.isEmpty else { continue }
            let slope = median(slopes), norm = sqrt(1+slope*slope)
            guard abs(slope) <= tan(10*Double.pi/180) else { continue }
            let intercept = median(anchors.map{$0.y-slope*$0.x})
            let a = b.a.plus(b.n.times(slope)).times(1/norm), n = b.n.minus(b.a.times(slope)).times(1/norm)
            let spans = units.map { u -> Double in
                let p = u.pixels.map{t.point($0).dot(n)}; return p.max()!-p.min()!
            }
            let cellExtent = abs(n.x)*sx+abs(n.y)*sy
            let width = median(spans)+cellExtent, center = intercept/norm
            let detectorAlong = polygon.map{P(x:$0[0],y:$0[1]).dot(a)}
            let low = detectorAlong.min()!, high = detectorAlong.max()!
            let inkAlong = units.flatMap{$0.pixels}.map{t.point($0).dot(a)}
            guard inkAlong.max()!-inkAlong.min()! >= 0.75*(high-low) else { continue }
            let q = corners(n: n,a: a,nl: center-width/2,nh: center+width/2,al: low,ah: high)
            certified.append(observation(q,layer: layer,
                mechanism: "db-owned-equal-unit-spine-robust-normal-span-preserve-detector-along-v1",
                diagnostics: ["otsuThreshold":Double(threshold),"unitCount":Double(units.count),"ownedCells":Double(cells.count),
                              "normalWidth":width,"cellNormalExtent":cellExtent,"axisSlopeDelta":slope,
                              "strokeDiameter":diameter,"detectorAlongPreserved":1,"measuredOverhangMayBeOmitted":1]))
        }
        // This mechanism's evidence policy requires a uniquely certified phase,
        // not a GT-ranked choice between two equally plausible spine hypotheses.
        return certified.count == 1 ? certified : []
    }

    private struct PaintRGB {
        let r: Double, g: Double, b: Double
        func difference(_ other: PaintRGB) -> Double {
            max(abs(r-other.r),max(abs(g-other.g),abs(b-other.b)))
        }
    }
    /// Lossless source-cell identity, scoped to ONE tile and projection basis.
    /// Equal envelopes, paint colors, query parents or DB contact are insufficient:
    /// detached/neighbor support and proper subsets must remain separate offers.
    /// At most eight palette modes retain one bit/cell each (not eight Int lists).
    private struct PaintSupportKey: Hashable {
        let words: [UInt64]
        init(_ selected: [Int], cellCount: Int) {
            var bits = [UInt64](repeating: 0, count: (cellCount+63)/64)
            for cell in selected { bits[cell/64] |= UInt64(1) << (cell%64) }
            words = bits
        }
        init(mask: [Bool]) {
            var bits = [UInt64](repeating: 0, count: (mask.count+63)/64)
            for cell in mask.indices where mask[cell] { bits[cell/64] |= UInt64(1) << (cell%64) }
            words = bits
        }
    }
    /// Exact order statistics for integer source channels. Even populations keep
    /// the original average of the two middle samples, including half-integers.
    private static func paintMedian(_ histogram: [Int], offset: Int, length: Int, count: Int) -> Double {
        let lower = (count-1)/2, upper = count/2
        var cumulative = 0, low = 0, foundLow = false
        for value in 0..<length {
            cumulative += histogram[offset+value]
            if !foundLow && cumulative > lower { low = value; foundLow = true }
            if cumulative > upper { return Double(low+value)/2 }
        }
        return 0 // Only called with a nonempty, exactly counted histogram.
    }
    private static func paintMedianColor(_ pixels: [Int], _ t: Tile) -> PaintRGB {
        var hist = [Int](repeating: 0,count: 3*256)
        for i in pixels {
            let j = 3*i
            hist[Int(t.rgb[j])] += 1
            hist[256+Int(t.rgb[j+1])] += 1
            hist[512+Int(t.rgb[j+2])] += 1
        }
        return PaintRGB(r: paintMedian(hist,offset: 0,length: 256,count: pixels.count),
                        g: paintMedian(hist,offset: 256,length: 256,count: pixels.count),
                        b: paintMedian(hist,offset: 512,length: 256,count: pixels.count))
    }
    private struct PaintEdge {
        let x: Double, y: Double, dx: Double, dy: Double
    }
    private static func paintInside(_ p: P, edges: [PaintEdge]) -> Bool {
        var positive = false, negative = false
        for e in edges {
            // Identical arithmetic order to inside(_:_:); no reassociation.
            let cross = e.dx*(p.y-e.y)-e.dy*(p.x-e.x)
            positive = positive || cross > 0; negative = negative || cross < 0
        }
        return !(positive && negative)
    }

    /// Query-rooted closed paint layers do NOT require invented DB membership.
    /// Actual enclosed cores, including foreign cores, partition touching paint.
    /// Distinct measured supports from all enclosing colors are returned; palette bins only identify
    /// photometric modes, never output coordinates or bounding-box offsets.
    private static func closedPaint(roi: ROI, query: [[Double]], generationLedger: GenerationLedger?) -> [Measurement] {
        guard let b = basis(query), let t = tile(roi,polygon: query,normalMargin: b.width,alongMargin: 0.8*b.width) else { return [] }
        return once(generationLedger, family: "column.closed-paint", polygon: query, tile: t) {
            closedPaintPixels(t, query: query, b: b, ledger: generationLedger)
        }
    }

    private static func closedPaintPixels(_ t: Tile, query: [[Double]], b: Basis,
                                          ledger: GenerationLedger? = nil) -> [Measurement] {
        let edges = (0..<4).map { i in
            let a = query[i], q = query[(i+1)%4]
            return PaintEdge(x: a[0],y: a[1],dx: q[0]-a[0],dy: q[1]-a[1])
        }
        // Exact integral histogram of each 16-wide RGB palette bin: no pixel
        // index lists, no per-pixel RGB vectors, no per-channel sorting. Each
        // channel needs only its 16 possible integer offsets in that bin.
        var counts = [Int](repeating: 0,count: 4096)
        var hist = [Int](repeating: 0,count: 4096*48)
        for i in 0..<t.count where paintInside(t.point(i),edges: edges) {
            let j = 3*i, r = Int(t.rgb[j]), g = Int(t.rgb[j+1]), blue = Int(t.rgb[j+2])
            let key = (r/16)*256+(g/16)*16+blue/16, base = key*48
            counts[key] += 1
            hist[base+r%16] += 1; hist[base+16+g%16] += 1; hist[base+32+blue%16] += 1
        }
        let ordered = counts.indices.filter { counts[$0] > 0 }.sorted { l,r in
            let a = counts[l], b = counts[r]
            return a == b ? l < r : a > b
        }
        var palette = [PaintRGB]()
        for key in ordered {
            let base = key*48, count = counts[key]
            let c = PaintRGB(
                r: Double((key/256)*16)+paintMedian(hist,offset: base,length: 16,count: count),
                g: Double(((key/16)%16)*16)+paintMedian(hist,offset: base+16,length: 16,count: count),
                b: Double((key%16)*16)+paintMedian(hist,offset: base+32,length: 16,count: count))
            if palette.contains(where:{c.difference($0) < 32}) { continue }
            palette.append(c)
            if palette.count == 8 { break }
        }
        var out = [Measurement]()
        var seenSupports = [PaintSupportKey]()
        // The two CC jobs read ONLY this exact binary mask, dimensions and
        // fixed 8/4 connectivity. Colors/query/AA-mixture processing still run
        // independently; equal masks do not imply equal complete measurements.
        let reuseTopology = ledger?.sourceBudgetV2Enabled == true && t.count <= 16_384
        var topology = [PaintSupportKey: (Components, Components)]()
        let sourceFirst = ledger?.sourceFirstV2Enabled == true
        let enabledModes = sourceFirst ? palette.indices.filter {
            NativeOCRSourcePaintGeometry.shouldGenerate("source.closed-paint-core-voronoi-envelope.v1/closed-enclosing-paint-mode-\($0)")
        } : []
        var attemptedModes = 0
        for (mode,color) in palette.enumerated() {
            let layer = "closed-enclosing-paint-mode-\(mode)"
            // Keep the complete palette for AA mixtures of observed colors.
            // Only geometry processing for the disabled mode is retired.
            guard NativeOCRSourcePaintGeometry.shouldGenerate(
                "source.closed-paint-core-voronoi-envelope.v1/" + layer) else { continue }
            if sourceFirst {
                // The full palette is still used for actual AA mixtures below.
                // Only TWO dominant observed paint layers may launch geometry.
                if attemptedModes == 2 {
                    ledger?.paletteAvoided(max(0, enabledModes.count-attemptedModes))
                    break
                }
                attemptedModes += 1
                ledger?.paletteStarted()
            }
            var mask = [Bool](repeating: false,count: t.count)
            for i in 0..<t.count {
                let j = 3*i
                mask[i] = max(abs(t.rgb[j]-color.r),max(abs(t.rgb[j+1]-color.g),abs(t.rgb[j+2]-color.b))) <= 32
            }
            let paint: Components, holes: Components
            let maskKey = reuseTopology ? PaintSupportKey(mask: mask) : nil
            if let maskKey, let cached = topology[maskKey] {
                paint = cached.0; holes = cached.1
                ledger?.topologyReused()
            } else {
                paint = components(mask,w: t.w,h: t.h)
                // Four-connected complement is the topological dual of the
                // eight-connected paint boundary. Border regions are not holes.
                holes = components(mask.map{!$0},w: t.w,h: t.h,diagonal: false)
                // At most two tile-local topology pairs of <=16,384 cells;
                // no source bitmap persists beyond this physical invocation.
                if let maskKey, topology.count < 2 { topology[maskKey] = (paint, holes) }
            }
            var roots = [Bool](repeating: false,count: t.count), foreign = roots
            var rootOwners = [Bool](repeating: false,count: paint.parts.count), rootAlong = [Double](), rootCount = 0
            for hole in holes.parts.dropFirst() where !hole.border {
                let c = paintMedianColor(hole.pixels,t)
                if c.difference(color) < 32 { continue }
                var contacts = [Int](repeating: 0,count: paint.parts.count), touched = [Int]()
                for i in hole.pixels {
                    let x = i%t.w, y = i/t.w
                    for direction in 0..<4 {
                        let dx = direction == 0 ? -1 : (direction == 1 ? 1 : 0)
                        let dy = direction == 2 ? -1 : (direction == 3 ? 1 : 0)
                        let xx = x+dx, yy = y+dy
                        if xx >= 0 && yy >= 0 && xx < t.w && yy < t.h {
                            let id = paint.labels[yy*t.w+xx]
                            if id > 0 {
                                if contacts[id] == 0 { touched.append(id) }
                                contacts[id] += 1
                            }
                        }
                    }
                }
                guard var owner = touched.first else { continue }
                for id in touched.dropFirst() {
                    if contacts[id] > contacts[owner] || (contacts[id] == contacts[owner] && id < owner) { owner = id }
                }
                let center = hole.pixels.reduce(P(x: 0,y: 0)){$0.plus(t.point($1))}.times(1/Double(hole.pixels.count))
                let u = center.dot(b.n), v = center.dot(b.a)
                if u >= b.nl && u <= b.nh && v >= b.al-0.8*b.width && v <= b.ah+0.8*b.width {
                    rootCount += 1; rootOwners[owner] = true; rootAlong.append(v)
                    for i in hole.pixels { roots[i] = true }
                } else { for i in hole.pixels { foreign[i] = true } }
            }
            guard rootCount >= 2, rootAlong.max()!-rootAlong.min()! >= b.width else { continue }
            // Exact late-censor rejection: with no foreign core, root distances
            // are finite and < the empty-foreign 1e20 sentinel. A rooted paint
            // component touching the tile border is therefore entirely strong;
            // weak/reached support cannot remove that border pixel.
            if paint.parts.indices.dropFirst().contains(where: { rootOwners[$0] && paint.parts[$0].border })
                && !foreign.contains(true) { continue }
            let rootD = distances(roots,t), foreignD = distances(foreign,t)
            var strong = [Bool](repeating: false,count: t.count), strongCount = 0
            for i in 0..<t.count where rootOwners[paint.labels[i]] && rootD[i] < foreignD[i] {
                strong[i] = true; strongCount += 1
            }
            guard strongCount > 0 else { continue }
            let strongD = distances(strong,t), search = max(1,0.25*b.width)
            var weak = strong
            // Only actual source pixels that fit a mixture of TWO observed
            // palette colors may extend AA support; no mask dilation output.
            for background in palette {
                let dr = color.r-background.r, dg = color.g-background.g, db = color.b-background.b
                // Preserve the old left-fold order (including the initial zero).
                let den = ((0.0+dr*dr)+dg*dg)+db*db
                if den < 32*32 { continue }
                for i in 0..<t.count where !weak[i] && strongD[i] <= search*search && rootD[i] < foreignD[i] {
                    let j = 3*i, red = t.rgb[j], green = t.rgb[j+1], blue = t.rgb[j+2]
                    let deltaR = red-background.r, deltaG = green-background.g, deltaB = blue-background.b
                    let dot = ((0.0+deltaR*dr)+deltaG*dg)+deltaB*db
                    let alpha = max(0,min(1,dot/den))
                    if alpha < 0.1 { continue }
                    let errorR = abs(red-(background.r+alpha*dr))
                    let errorG = abs(green-(background.g+alpha*dg))
                    let errorB = abs(blue-(background.b+alpha*db))
                    if max(errorR,max(errorG,errorB)) <= 8 { weak[i] = true }
                }
            }
            let aa = components(weak,w: t.w,h: t.h)
            var reached = [Bool](repeating: false,count: aa.parts.count)
            for i in strong.indices where strong[i] { reached[aa.labels[i]] = true }
            let selected = aa.labels.indices.filter { aa.labels[$0] > 0 && reached[aa.labels[$0]] }
            guard !touchesBorder(selected,t) else { continue }
            let support = PaintSupportKey(selected, cellCount: t.count)
            if ledger?.sourceBudgetV2Enabled == true, seenSupports.contains(support) {
                ledger?.boundaryFitSkipped()
                continue
            }
            guard let q = envelope(selected,t,n: b.n,a: b.a) else { continue }
            // Two photometric modes can recover exactly the same physical cells.
            // Keep the first mode, as the wrapper's exact-geometry dedup already
            // does. This never selects between different terminal/normal bounds
            // and never promotes query-rooted paint into certified membership.
            if seenSupports.contains(support) { continue }
            seenSupports.append(support)
            out.append(observation(q,layer: layer,mechanism: "source.closed-paint-core-voronoi-envelope.v1",
                diagnostics: ["rootedClosedHoles":Double(rootCount),"observedPaintPixels":Double(selected.count),
                              "strongPaintPixels":Double(strongCount),"observedRed":color.r,"observedGreen":color.g,
                              "observedBlue":color.b,"authenticatedDBMembership":0,"nearestCoreAssociationOnly":1]))
            if sourceFirst {
                // First physically valid boundary is canonical. Subsequent
                // layer masks, CCs, distance transforms and fits never run.
                ledger?.paletteAvoided(max(0, enabledModes.count-attemptedModes))
                break
            }
        }
        return out
    }
}
