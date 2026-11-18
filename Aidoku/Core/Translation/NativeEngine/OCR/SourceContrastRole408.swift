import Foundation
import CoreGraphics

// Independent408 observation only; original405 is not modified or linked.
// No polygon generation/clamp, ownership, erasure or admission.
// Consumers must not replace unknown pixels with a whole-component/hull fill.
enum SourceContrastRole408 {
    typealias K = NativeOCRSharedBoundary396
    enum SeedMode: String {
        // Original native membership nominates candidate CCs. Actual bilateral
        // source RGB contrast is still required before any positive role.
        case originalNativeSupport
        case legacyGGNativeIntersectionDiagnostic
    }
    enum Role: UInt8 {
        case unknown = 0, fill = 1, rimOrAA = 2, unoutlinedPositive = 3
        case conflicting = 4, stableOutside = 5, stableRimCore = 6, aaTransition = 7
    }
    enum Kind: String { case outlined, unoutlinedPositive }
    struct PixelWitness {
        let localIndex: Int
        let center: CGPoint
        let rgb: [Int]
        let rootGG: Bool
        let actualNativeRootCell: Bool
        let detectorArrayPositions: [Int]
        let nativeRootDetectorArrayPositions: [Int]
        let rfArrayPositions: [Int]
    }
    struct Side {
        let path: [Int]
        let fill: [Int]
        let rimOrAA: [Int]
        let stableRim: [Int]
        let outside: [Int]
        let unoutlined: Bool
    }
    struct Row {
        let componentID: Int
        let along: CGFloat
        let kind: Kind
        let seed: Int
        let low: Side
        let high: Side
        let witnesses: [PixelWitness]
    }
    struct ComponentRole {
        let componentID: Int
        let actualPixelCount: Int
        let nativeGGAnchorCount: Int
        let nativeModelSupportCount: Int
        let actualNativeCellCentersInCapture: Int
        let directlyRooted: Bool
        let connectedRootComponentID: Int?
        let actualContactPairs: [[Int]]
        let closedAtCapture: Bool
        let outlinedRows: Int
        let unoutlinedRows: Int
        let observedRimRows: Int
        let role: Role
        // Evidence summary, NOT authority to assign the role to unsampled pixels.
        let sampledPixelRolesOnly: Bool
    }
    struct Output {
        let roles: [UInt8] // Actual local pixel indices, including stride-free row width.
        let rows: [Row]
        let components: [ComponentRole]
        let receipt: [String: Any]
        func role(atActualLocalPixelIndex i: Int) -> Role {
            guard roles.indices.contains(i) else { return .unknown }
            return Role(rawValue: roles[i]) ?? .unknown
        }
        func isPositiveFill(atActualLocalPixelIndex i: Int) -> Bool {
            let r = role(atActualLocalPixelIndex: i)
            return r == .fill || r == .unoutlinedPositive
        }
        func isPositiveVisualSupport(atActualLocalPixelIndex i: Int) -> Bool {
            let r = role(atActualLocalPixelIndex: i)
            return r == .fill || r == .unoutlinedPositive || r == .stableRimCore || r == .aaTransition || r == .rimOrAA
        }
        // Caller supplies actual newly recovered GG indices, not a bbox/hull.
        // This exposes source evidence only; even a positive result does not
        // authorize a whole edge, erase a rim, or bypass404/native guards.
        func recoveredSupport(actualLocalPixelIndices indices: [Int]) -> [String: Any] {
            let unique = Set(indices)
            guard unique.allSatisfy({ roles.indices.contains($0) }) else {
                return ["status": "invalid-recovered-indices", "positiveFillEvidence": false,
                        "wholeEdgeExpansionAuthorized": false]
            }
            let fill = unique.filter { isPositiveFill(atActualLocalPixelIndex: $0) }
            let rim = unique.filter {
                let r = role(atActualLocalPixelIndex: $0)
                return r == .rimOrAA || r == .stableRimCore || r == .aaTransition
            }
            let rimCore = unique.filter { role(atActualLocalPixelIndex: $0) == .stableRimCore }
            let aa = unique.filter { role(atActualLocalPixelIndex: $0) == .aaTransition }
            let visual = unique.filter { isPositiveVisualSupport(atActualLocalPixelIndex: $0) }
            let conflicts = unique.filter { role(atActualLocalPixelIndex: $0) == .conflicting }
            let outside = unique.filter { role(atActualLocalPixelIndex: $0) == .stableOutside }
            let unknown = unique.filter { role(atActualLocalPixelIndex: $0) == .unknown }
            let supportedRows = rows.filter { row in
                (row.low.fill + row.high.fill).contains { unique.contains($0) && isPositiveFill(atActualLocalPixelIndex: $0) }
            }
            let groups = Dictionary(grouping: supportedRows, by: { $0.componentID })
            let repeated = groups.values.contains { group in
                let positions = group.map(\.along).sorted()
                var distinct: [CGFloat] = []
                for p in positions { if distinct.last.map({ p - $0 >= 1 }) ?? true { distinct.append(p) } }
                return distinct.count >= 3 && distinct.last! - distinct.first! >= 3
            }
            let visualRows = rows.filter { row in
                (row.low.fill + row.high.fill + row.low.rimOrAA + row.high.rimOrAA).contains {
                    unique.contains($0) && isPositiveVisualSupport(atActualLocalPixelIndex: $0)
                }
            }
            let visualGroups = Dictionary(grouping: visualRows, by: { $0.componentID })
            let repeatedVisual = visualGroups.values.contains { group in
                let positions = group.map(\.along).sorted()
                var distinct: [CGFloat] = []
                for p in positions { if distinct.last.map({ p - $0 >= 1 }) ?? true { distinct.append(p) } }
                return distinct.count >= 3 && distinct.last! - distinct.first! >= 3
            }
            return ["status": "observed-recovered-pixel-roles", "uniqueRecoveredPixels": unique.count,
                "positiveFillPixels": fill.count, "rimOrAAPixels": rim.count,
                "validatedStableRimCorePixels": rimCore.count, "validatedAATransitionPixels": aa.count,
                "positiveVisualSupportPixels": visual.count,
                "conflictingPixels": conflicts.count, "stableOutsidePixels": outside.count,
                "unknownPixels": unknown.count, "positiveFillEvidence": fill.count >= 3 && repeated,
                "positiveFillFraction": Double(fill.count) / Double(max(1, unique.count)),
                "positiveVisualSupportEvidence": visual.count >= 3 && repeatedVisual,
                "positiveVisualSupportFraction": Double(visual.count) / Double(max(1, unique.count)),
                "supportedSourceRows": supportedRows.count,
                "supportedVisualRows": visualRows.count,
                "weakRimOrUnknownAloneIsNewFillEvidence": false,
                "wholeEdgeExpansionAuthorized": false, "erasureAuthority": "none",
                "admissionGranted": false]
        }
    }
    private struct CC {
        let pixels: [Int]
        let anchors: Int
        let nativeSupport: Int
        let closed: Bool
        let n0: CGFloat, n1: CGFloat
    }
    private struct Phase { let pixels: [Int]; let colour: SIMD3<Int> }

    static func assess(evidence e: K.Evidence, basis f: K.Basis, nativeW mw: CGFloat,
                       seedMode: SeedMode = .originalNativeSupport) -> Output {
        let r = e.rgba, w = r.width, h = r.height
        func empty(_ status: String, _ count: Int = 0) -> Output {
            .init(roles: [UInt8](repeating: Role.unknown.rawValue, count: count), rows: [], components: [],
                receipt: ["family": "source-contrast-role408", "status": status,
                    "geometryProduced": false, "ownershipClaimed": false, "admissionGranted": false,
                    "erasureAuthority": "none", "sourceCompletenessClaimed": false])
        }
        guard w > 2, h > 2, w <= 600_000 / h, w <= Int.max / 4,
              r.bytesPerRow >= w * 4, r.bytesPerRow <= Int.max / h,
              r.bytes.count == h * r.bytesPerRow, e.body.count == w * h,
              mw.isFinite, mw > 0, mw < 100_000,
              [r.origin, f.origin, f.normal, f.along].allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              abs(hypot(f.normal.x, f.normal.y) - 1) < 1e-6,
              abs(hypot(f.along.x, f.along.y) - 1) < 1e-6,
              abs(f.normal.x * f.along.x + f.normal.y * f.along.y) < 1e-6,
              e.detectors.count <= 64, e.rf.count <= 160,
              e.nativeCellCenters.count <= 600_000,
              e.nativeCellCenters.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              e.rf.allSatisfy({ $0.bounds.count == 4 && $0.bounds.allSatisfy({ $0.isFinite }) && $0.confidence.isFinite })
        else { return empty("invalid-bounded-source-input") }
        func world(_ i: Int) -> CGPoint {
            CGPoint(x: r.origin.x + CGFloat(i % w) + 0.5, y: r.origin.y + CGFloat(i / w) + 0.5)
        }
        func projected(_ p: CGPoint) -> CGPoint {
            let x = p.x - f.origin.x, y = p.y - f.origin.y
            return .init(x: x * f.normal.x + y * f.normal.y, y: x * f.along.x + y * f.along.y)
        }
        func rgb(_ i: Int) -> SIMD3<Int> {
            let k = (i / w) * r.bytesPerRow + (i % w) * 4
            return .init(Int(r.bytes[k]), Int(r.bytes[k + 1]), Int(r.bytes[k + 2]))
        }
        // Only relative RGB differences. No luminance, white/black palette or
        // brightness ordering determines fill/rim/outside. Complement inversion
        // leaves every colour-distance predicate unchanged.
        func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
            max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
        }
        func mean(_ pixels: [Int]) -> SIMD3<Int> {
            var red = 0, green = 0, blue = 0
            for i in pixels { let c = rgb(i); red += c.x; green += c.y; blue += c.z }
            let count = max(1, pixels.count)
            return .init(red / count, green / count, blue / count)
        }
        func normalSpan(_ pixels: [Int]) -> CGFloat {
            guard !pixels.isEmpty else { return 0 }
            let n = pixels.map { projected(world($0)).x }
            return n.max()! - n.min()! + abs(f.normal.x) + abs(f.normal.y)
        }
        func exteriorPrefix(_ pixels: [Int], _ minimumSpan: CGFloat) -> [Int]? {
            var prefix: [Int] = []
            for i in pixels {
                prefix.append(i)
                if prefix.count >= 3 && normalSpan(prefix) >= minimumSpan { return prefix }
            }
            return nil
        }
        func index(_ x: Int, _ y: Int) -> Int? {
            x >= 0 && x < w && y >= 0 && y < h ? y * w + x : nil
        }
        let cardinal = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        let around = cardinal + [(-1, -1), (-1, 1), (1, -1), (1, 1)]
        var labels = [Int](repeating: -1, count: w * h)
        for i in labels.indices where r.bytes[(i / w) * r.bytesPerRow + (i % w) * 4 + 3] != 255 {
            labels[i] = -2
        }
        var cc: [CC] = []
        for seed in labels.indices where labels[seed] == -1 {
            guard cc.count < 20_000 else { return empty("CC-budget-exhausted", w * h) }
            let id = cc.count, reference = rgb(seed)
            var pixels = [seed], cursor = 0, anchors = 0, nativeSupport = 0
            labels[seed] = id
            while cursor < pixels.count {
                let i = pixels[cursor]; cursor += 1
                // Membership nominates a seed; it is never an ink/background label.
                if e.privateAt(world(i)) {
                    nativeSupport += 1
                    if e.body[i] != 0 { anchors += 1 }
                }
                for (dx, dy) in around {
                    guard let j = index(i % w + dx, i / w + dy), labels[j] == -1,
                          distance(rgb(j), reference) <= 20, distance(rgb(i), rgb(j)) <= 16 else { continue }
                    labels[j] = id; pixels.append(j)
                }
            }
            var closed = true, n0 = CGFloat.infinity, n1 = -CGFloat.infinity
            for i in pixels {
                let p = projected(world(i)); n0 = min(n0, p.x); n1 = max(n1, p.x)
                for (dx, dy) in cardinal {
                    if let j = index(i % w + dx, i / w + dy) {
                        if labels[j] == -2 { closed = false }
                    } else { closed = false }
                }
            }
            cc.append(.init(pixels: pixels, anchors: anchors, nativeSupport: nativeSupport, closed: closed, n0: n0, n1: n1))
        }
        let roots = Set(cc.indices.filter {
            let supported = seedMode == .originalNativeSupport ? cc[$0].nativeSupport >= 2 : cc[$0].anchors >= 2
            return cc[$0].closed && supported && cc[$0].n1 - cc[$0].n0 <= 2.5 * mw
        })
        guard !roots.isEmpty, roots.count <= 256 else { return empty("no-bounded-original-model-supported-seed-CC", w * h) }
        var nativeCenterCounts: [Int: Int] = [:]
        for p in e.nativeCellCenters {
            let x = floor(p.x - r.origin.x), y = floor(p.y - r.origin.y)
            if x >= 0, x < CGFloat(w), y >= 0, y < CGFloat(h) {
                let id = labels[Int(y) * w + Int(x)]
                if id >= 0 { nativeCenterCounts[id, default: 0] += 1 }
            }
        }
        // Literal source-pixel contacts, not rectangle overlap or colour similarity.
        // Two contact hops link candidate phases to actual original support;
        // neither these contacts nor GG/native membership identifies ink.
        var rootedBy: [Int: Int] = [:], contactPairs: [Int: [[Int]]] = [:]
        for id in roots { rootedBy[id] = id }
        var reached = roots, frontier = roots
        for _ in 0..<2 {
            var contacts: [Int: [[Int]]] = [:], parents: [Int: Int] = [:]
            for parent in frontier.sorted() {
                for i in cc[parent].pixels {
                    for (dx, dy) in cardinal {
                        guard let j = index(i % w + dx, i / w + dy), labels[j] >= 0 else { continue }
                        let id = labels[j]
                        guard !reached.contains(id), cc[id].closed, cc[id].pixels.count >= 3,
                              cc[id].n1 - cc[id].n0 <= 2.5 * mw else { continue }
                        if contacts[id, default: []].count < 8 { contacts[id, default: []].append([i, j]); parents[id] = parent }
                    }
                }
            }
            let added = Set(contacts.keys.filter { contacts[$0]!.count >= 3 })
            for id in added {
                rootedBy[id] = rootedBy[parents[id]!]!
                contactPairs[id] = contacts[id]!
            }
            reached.formUnion(added); frontier = added
            if added.isEmpty { break }
            guard reached.count <= 512 else { return empty("root-contact-budget-exhausted", w * h) }
        }
        var queries = 0, exhausted = false
        let rayLimit = min(256, max(16, Int(ceil(mw * 2)) + 12))
        let maxTransition = min(24, max(4, Int(ceil(mw * 0.35))))
        func sample(_ p: CGPoint) -> Int? {
            queries += 1
            if queries > 3_000_000 { exhausted = true; return nil }
            let x = floor(p.x - r.origin.x), y = floor(p.y - r.origin.y)
            guard x >= 0, x < CGFloat(w), y >= 0, y < CGFloat(h),
                  let i = index(Int(x), Int(y)), labels[i] >= 0 else { return nil }
            return i
        }
        func side(_ seed: Int, _ id: Int, _ sign: CGFloat) -> Side? {
            let p = world(seed)
            var path = [seed], last = seed
            for step in 1...rayLimit {
                guard let i = sample(.init(x: p.x + f.normal.x * sign * CGFloat(step) * 0.75,
                                          y: p.y + f.normal.y * sign * CGFloat(step) * 0.75)) else { break }
                if i != last { path.append(i); last = i }
            }
            var fill: [Int] = []
            for i in path {
                if labels[i] != id { break }
                fill.append(i)
            }
            guard !fill.isEmpty, fill.count < path.count else { return nil }
            let rest = Array(path.dropFirst(fill.count))
            var phases: [Phase] = []
            var start = 0
            while start < rest.count {
                let reference = rgb(rest[start]); var end = start + 1
                while end < rest.count && distance(reference, rgb(rest[end])) <= 16 && distance(rgb(rest[end - 1]), rgb(rest[end])) <= 12 { end += 1 }
                phases.append(.init(pixels: Array(rest[start..<end]), colour: reference)); start = end
            }
            guard let first = phases.firstIndex(where: { $0.pixels.count >= 2 }),
                  normalSpan(phases[..<first].flatMap { $0.pixels }) <= CGFloat(maxTransition) else { return nil }
            let fillColour = mean(fill)
            let exteriorNeeded = max(CGFloat(6), mw * 0.4)
            let maxRimCore = min(CGFloat(24), max(CGFloat(2), ceil(mw * 0.45)))
            let maxEnvelope = max(CGFloat(4), ceil(mw * 0.75) + 2)
            var outlinedBest: (strength: Int, side: Side)?
            var ambiguousNearFillRecurrence = false
            // Seek a finite, local intermediate CORE and a genuine exterior.
            // Stable exterior must contrast with BOTH fill and rim. Never skip
            // a same-fill neighbour and relabel its foreground as background.
            for rimIndex in first..<phases.count {
                let rim = phases[rimIndex]
                let beforePixels = phases[..<rimIndex].flatMap { $0.pixels }
                let before = normalSpan(beforePixels)
                if before > CGFloat(maxTransition) { break }
                guard rim.pixels.count >= 2, normalSpan(rim.pixels) <= maxRimCore,
                      distance(fillColour, mean(rim.pixels)) >= 32 else { continue }
                if rimIndex + 1 >= phases.count { continue }
                for outsideIndex in (rimIndex + 1)..<phases.count {
                    let outside = phases[outsideIndex]
                    let between = normalSpan(phases[(rimIndex + 1)..<outsideIndex].flatMap { $0.pixels })
                    if between > CGFloat(maxTransition) { break }
                    if outside.pixels.count >= 2 && distance(fillColour, mean(outside.pixels)) < 32 {
                        if before + normalSpan(rim.pixels) + between <= maxEnvelope {
                            ambiguousNearFillRecurrence = true
                        }
                        break // foreground-colour recurrence is not exterior.
                    }
                    guard let stableOutside = exteriorPrefix(outside.pixels, exteriorNeeded),
                          distance(fillColour, mean(outside.pixels)) >= 32,
                          distance(mean(rim.pixels), mean(outside.pixels)) >= 32 else { continue }
                    let outsideStart = rest.firstIndex(of: outside.pixels[0])!
                    let transition = Array(rest[..<outsideStart])
                    guard normalSpan(transition) <= maxEnvelope else { break }
                    guard !transition.contains(where: { labels[$0] == id }) else { break }
                    // Native/DB/GG may overlap this measured outside plateau.
                    // They are seed/context evidence, never a foreground veto.
                    let candidate = Side(path: Array(path.prefix(fill.count + outsideStart + stableOutside.count)),
                        fill: fill, rimOrAA: transition, stableRim: rim.pixels,
                        outside: stableOutside, unoutlined: false)
                    // The stable rim CORE has strong contrast to BOTH sides.
                    // Prefer it over an intermediate AA plateau; no brightness
                    // direction or fixed white/black colour is used.
                    let contrast = min(distance(fillColour, mean(rim.pixels)),
                                       distance(mean(rim.pixels), mean(outside.pixels)))
                    let strength = contrast * 1024 + min(32, rim.pixels.count)
                    if outlinedBest == nil || strength > outlinedBest!.strength {
                        outlinedBest = (strength, candidate)
                    }
                }
            }
            if let best = outlinedBest { return best.side }
            if ambiguousNearFillRecurrence { return nil }
            // Accept the nearest long stable contrasting exterior LOCALLY.
            // A distant speech-balloon border or later glyph does not invalidate
            // the already measured plateau. Do not require the last ray phase.
            let plateau = phases[first].pixels
            guard let stableOutside = exteriorPrefix(plateau, exteriorNeeded),
                  distance(fillColour, mean(plateau)) >= 32 else { return nil }
            let plateauStart = rest.firstIndex(of: plateau[0])!
            return .init(path: Array(path.prefix(fill.count + plateauStart + stableOutside.count)), fill: fill,
                rimOrAA: [], stableRim: [], outside: stableOutside, unoutlined: true)
        }

        func compatible(_ low: Side, _ high: Side) -> Bool {
            guard low.unoutlined == high.unoutlined,
                  distance(mean(low.outside), mean(high.outside)) <= 24,
                  distance(mean(low.fill), mean(high.fill)) <= 20 else { return false }
            if !low.unoutlined {
                guard distance(mean(low.stableRim), mean(high.stableRim)) <= 24,
                      abs(normalSpan(low.rimOrAA) - normalSpan(high.rimOrAA)) <= max(3, max(normalSpan(low.rimOrAA), normalSpan(high.rimOrAA)) / 2)
                else { return false }
            }
            return true
        }
        var witnessQueries = 0, rfQueries = 0
        func proof(_ i: Int) -> PixelWitness {
            let p = world(i), c = rgb(i)
            var db: [Int] = [], rf: [Int] = []
            for d in e.detectors.indices {
                witnessQueries += 1
                if witnessQueries + rfQueries > 2_000_000 { exhausted = true; break }
                if e.detectors[d].cells.contains(p) { db.append(d) }
            }
            for v in e.rf.indices {
                rfQueries += 1
                if witnessQueries + rfQueries > 2_000_000 { exhausted = true; break }
                if e.rf[v].confidence >= 0.4 && e.rf[v].contains(p) { rf.append(v) }
            }
            return .init(localIndex: i, center: p, rgb: [c.x, c.y, c.z], rootGG: e.body[i] != 0,
                actualNativeRootCell: e.privateAt(p), detectorArrayPositions: db,
                nativeRootDetectorArrayPositions: db.filter { e.detectors[$0].nativeRoot }, rfArrayPositions: rf)
        }
        var rows: [Row] = [], outlined: [Int: [Int]] = [:], unoutlined: [Int: [Int]] = [:]
        var rimRows: [Int: Set<Int>] = [:]
        for id in reached.sorted() {
            let c = cc[id], midpoint = (c.n0 + c.n1) * 0.5
            // Original pixels closest to the CC's center in each actual source
            // row. Both rays start from precisely the same seed/along position.
            var rowSeeds: [Int: Int] = [:]
            for i in c.pixels {
                let p = projected(world(i)), key = Int(floor(p.y / 1.5))
                if let previous = rowSeeds[key] {
                    let prev = projected(world(previous))
                    if abs(p.x - midpoint) < abs(prev.x - midpoint) { rowSeeds[key] = i }
                } else { rowSeeds[key] = i }
            }
            let keys = rowSeeds.keys.sorted(), count = min(32, keys.count)
            for k in 0..<count {
                guard rows.count < 4096 else { return empty("row-budget-exhausted", w * h) }
                let key = keys[k * (keys.count - 1) / max(1, count - 1)], seed = rowSeeds[key]!
                guard let low = side(seed, id, -1), let high = side(seed, id, 1), compatible(low, high) else { continue }
                let rowIndex = rows.count, kind: Kind = low.unoutlined ? .unoutlinedPositive : .outlined
                let indices = Array(Set(low.path + high.path)).sorted()
                let witnesses = indices.map(proof)
                rows.append(.init(componentID: id, along: projected(world(seed)).y, kind: kind,
                    seed: seed, low: low, high: high, witnesses: witnesses))
                if kind == .outlined {
                    outlined[id, default: []].append(rowIndex)
                    for pixel in low.rimOrAA + high.rimOrAA { rimRows[labels[pixel], default: []].insert(rowIndex) }
                } else { unoutlined[id, default: []].append(rowIndex) }
            }
        }
        guard !exhausted else { return empty("source-query-budget-exhausted-abstain", w * h) }
        // Repeated bilateral evidence must be on distinct source rows; one
        // attractive gradient/white channel is never sufficient.
        func repeated(_ indices: [Int]) -> Bool {
            let coordinates = indices.map { rows[$0].along }.sorted()
            guard coordinates.count >= 3 else { return false }
            var selected: [CGFloat] = []
            for v in coordinates { if selected.last.map({ v - $0 >= 1.0 }) ?? true { selected.append(v) } }
            return selected.count >= 3 && selected.last! - selected.first! >= 3
        }
        let fillIDs = Set(reached.filter { repeated(outlined[$0] ?? []) })
        let bareCandidates = Set(reached.filter { repeated(unoutlined[$0] ?? []) })
        // Only rim observations from a repeated positive interior count. Local
        // direct-contrast observations on the cap of a connected rim are NOT
        // stronger than explicit repeated interior->rim->outside observations.
        // Suppress their bare-fill promotion, retain witnessed real rim support.
        var positiveRimRows: [Int: Set<Int>] = [:]
        for (id, indices) in rimRows {
            positiveRimRows[id] = Set(indices.filter { fillIDs.contains(rows[$0].componentID) })
        }
        let rimIDs = Set(positiveRimRows.keys.filter { repeated(Array(positiveRimRows[$0]!)) })
        let bareIDs = bareCandidates.subtracting(rimIDs)
        let conflicts = fillIDs.intersection(rimIDs)
        var roles = [UInt8](repeating: Role.unknown.rawValue, count: w * h)
        func mark(_ i: Int, _ role: Role) {
            let old = Role(rawValue: roles[i]) ?? .unknown
            if conflicts.contains(labels[i]) { roles[i] = Role.conflicting.rawValue; return }
            if old == .unknown || old == role { roles[i] = role.rawValue }
            else { roles[i] = Role.conflicting.rawValue }
        }
        for row in rows {
            let positive = row.kind == .outlined ? fillIDs.contains(row.componentID) : bareIDs.contains(row.componentID)
            guard positive else { continue }
            let fillRole: Role = row.kind == .outlined ? .fill : .unoutlinedPositive
            for i in row.low.fill + row.high.fill where labels[i] == row.componentID { mark(i, fillRole) }
            if row.kind == .outlined {
                let core = Set(row.low.stableRim + row.high.stableRim)
                for i in row.low.rimOrAA + row.high.rimOrAA where rimIDs.contains(labels[i]) {
                    mark(i, core.contains(i) ? .stableRimCore : .aaTransition)
                }
            }
            for i in row.low.outside + row.high.outside { mark(i, .stableOutside) }
        }
        let reported = reached.union(rimIDs)
        let components: [ComponentRole] = reported.sorted().map { id in
            let role: Role = conflicts.contains(id) ? .conflicting : fillIDs.contains(id) ? .fill :
                bareIDs.contains(id) ? .unoutlinedPositive : rimIDs.contains(id) ? .rimOrAA : .unknown
            return .init(componentID: id, actualPixelCount: cc[id].pixels.count, nativeGGAnchorCount: cc[id].anchors,
                nativeModelSupportCount: cc[id].nativeSupport,
                actualNativeCellCentersInCapture: nativeCenterCounts[id] ?? 0,
                directlyRooted: roots.contains(id), connectedRootComponentID: rootedBy[id],
                actualContactPairs: contactPairs[id] ?? [], closedAtCapture: cc[id].closed,
                outlinedRows: (outlined[id] ?? []).count, unoutlinedRows: (unoutlined[id] ?? []).count,
                observedRimRows: positiveRimRows[id]?.count ?? 0, role: role, sampledPixelRolesOnly: true)
        }
        let counts = Dictionary(grouping: roles, by: { $0 }).mapValues { $0.count }
        return .init(roles: roles, rows: rows, components: components,
            receipt: ["family": "source-contrast-role408", "status": "source-role-observations-only",
                "RGBAWidth": w, "RGBAHeight": h, "basisRetained": true, "RGBComponents": cc.count,
                "seedMode": seedMode.rawValue, "GGForegroundMandatory": seedMode == .legacyGGNativeIntersectionDiagnostic,
                "nativeMembershipIsForeground": false, "GGMembershipIsForeground": false,
                "rootedComponents": roots.count, "rootConnectedComponents": reached.count,
                "originalNativeCellCentersProvided": e.nativeCellCenters.count,
                "bilateralRows": rows.count,
                "positiveFillComponents": fillIDs.union(bareIDs).subtracting(conflicts).count,
                "outlinedFillComponents": fillIDs.subtracting(conflicts).count,
                "unoutlinedPositiveComponents": bareIDs.subtracting(conflicts).count,
                "observedRimComponents": rimIDs.subtracting(conflicts).count,
                "localBareRimCapPromotionsSuppressed": bareCandidates.intersection(rimIDs).count,
                "conflictingComponents": conflicts.count, "rolePixelCounts": counts.map { ["role": Int($0.key), "count": $0.value] },
                "rayQueries": queries, "detectorQueries": witnessQueries, "RFQueries": rfQueries,
                "minimumRepeatedRows": 3, "wholeComponentRolePropagation": false,
                "GGBodyAloneIsFill": false, "nativeFootprintAloneIsFill": false,
                "localExteriorIgnoresFarPhaseChanges": true,
                "minimumLocalExteriorSourceSpan": Double(max(CGFloat(6), mw * 0.4)),
                "phaseWidthsMeasuredInSourceBasis": true,
                "backgroundCanOverlapNativeOrGG": true,
                "outlinedExteriorMustContrastWithFillAndRim": true,
                "ambiguousNearFillRecurrenceAbstains": true,
                "stableRimCoreDistinctFromAATransition": true,
                "absoluteBrightnessRuleUsed": false, "RFOrDBRectangleUsedAsMask": false,
                "noOutlineImpliesRim": false, "unknownMeansBackground": false,
                "geometryProduced": false, "ownershipClaimed": false, "admissionGranted": false,
                "erasureAuthority": "none", "sourceCompletenessClaimed": false,
                "consumerObligation": "Use separate positive fill and positive visual support features. Validated real rim/AA may support a visual bbox but is not body fill. Membership is only seed/context. Unknown is not background. No geometry/ownership authority or bypass of404/native guards."])
    }
}
