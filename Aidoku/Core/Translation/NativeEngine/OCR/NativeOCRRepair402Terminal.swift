import Foundation
import CoreGraphics

// Source-only nominations. No Measurement construction, ownership assignment,
// native admission, source/frame reread, transcript, GT, or case routing.
enum NativeOCRRepair402Terminal {
    typealias K = NativeOCRSharedBoundary396
    private struct Component {
        let pixels: [Int]
        let colour: SIMD3<Int>
        let anchors: Int
        let n0: CGFloat, n1: CGFloat, a0: CGFloat, a1: CGFloat
        let clipped: Bool
        let contrast: [[Int]]
    }
    private struct Vote {
        var db = Set<Int>() // Array positions, not assumed unique detector ordinals.
        var rf = Set<Int>() // Array positions, not assumed unique RF query IDs.
        var witnesses: [[String: Any]] = []
    }

    static func generate(actualOld old: [CGPoint], basis f: K.Basis,
                         nativeW mw: CGFloat, evidence e: K.Evidence) -> K.Output {
        let family = "repair402-terminal-extension"
        func none(_ status: String) -> K.Output {
            .init(proposals: [], receipt: ["family": family, "status": status,
                "admissionGranted": false, "nativeAdmissionSuiteRun": false])
        }
        let r = e.rgba, w = r.width, h = r.height
        guard w > 2, h > 2, w <= 600_000 / h, r.bytesPerRow >= 4 * w,
              h <= Int.max / r.bytesPerRow, r.bytes.count == h * r.bytesPerRow,
              e.body.count == w * h, old.count == 4,
              old.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              [r.origin.x, r.origin.y, f.origin.x, f.origin.y,
               f.normal.x, f.normal.y, f.along.x, f.along.y, mw].allSatisfy({ $0.isFinite }),
              mw > 0, mw < 100_000,
              abs(hypot(f.normal.x, f.normal.y) - 1) < 1e-6,
              abs(hypot(f.along.x, f.along.y) - 1) < 1e-6,
              abs(f.normal.x * f.along.x + f.normal.y * f.along.y) < 1e-6,
              e.detectors.count <= 64, e.rf.count <= 160,
              e.nativeCellCenters.count <= 600_000,
              e.nativeCellCenters.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return none("invalid-bounded-source-input") }
        let turns = (0..<4).map { i -> CGFloat in
            let a = old[i], b = old[(i + 1) % 4], c = old[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard turns.allSatisfy({ $0 > 1e-8 }) || turns.allSatisfy({ $0 < -1e-8 })
        else { return none("nonconvex-actual-old") }
        func insideCapture(_ p: CGPoint) -> Bool {
            p.x >= r.origin.x && p.x <= r.origin.x + CGFloat(w) &&
            p.y >= r.origin.y && p.y <= r.origin.y + CGFloat(h)
        }
        guard old.allSatisfy(insideCapture) else { return none("old-outside-actual-capture") }
        let ccw = turns[0] > 0
        var normals: [CGPoint] = [], planes: [CGFloat] = []
        for i in 0..<4 {
            let a = old[i], b = old[(i + 1) % 4], dx = b.x - a.x, dy = b.y - a.y
            let length = hypot(dx, dy)
            let n = ccw ? CGPoint(x: dy / length, y: -dx / length)
                        : CGPoint(x: -dy / length, y: dx / length)
            normals.append(n); planes.append(n.x * a.x + n.y * a.y)
        }
        func world(_ i: Int) -> CGPoint {
            CGPoint(x: r.origin.x + CGFloat(i % w) + 0.5,
                    y: r.origin.y + CGFloat(i / w) + 0.5)
        }
        func project(_ p: CGPoint) -> CGPoint {
            let x = p.x - f.origin.x, y = p.y - f.origin.y
            return CGPoint(x: x * f.normal.x + y * f.normal.y,
                           y: x * f.along.x + y * f.along.y)
        }
        func rgb(_ i: Int) -> SIMD3<Int> {
            let k = (i / w) * r.bytesPerRow + (i % w) * 4
            return SIMD3(Int(r.bytes[k]), Int(r.bytes[k + 1]), Int(r.bytes[k + 2]))
        }
        func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
            max(abs(a.x - b.x), abs(a.y - b.y), abs(a.z - b.z))
        }
        func index(_ x: Int, _ y: Int) -> Int? {
            x >= 0 && x < w && y >= 0 && y < h ? y * w + x : nil
        }
        func witness(_ i: Int) -> [String: Any] {
            let p = world(i), c = rgb(i)
            return ["actualLocalPixelIndex": i, "center": [Double(p.x), Double(p.y)],
                    "RGB": [c.x, c.y, c.z], "rootGGBody": e.body[i] != 0,
                    "nativeRootCell": e.privateAt(p),
                    "outsideActualOld": !K.contains(old, p), "ownershipClaimed": false]
        }
        func runs(_ pixels: [Int]) -> [[Int]] {
            var result: [[Int]] = []
            for i in pixels.sorted() {
                if let last = result.last, last[0] == i / w, last[1] + last[2] == i % w {
                    result[result.count - 1][2] += 1
                } else { result.append([i / w, i % w, 1]) }
            }
            return result
        }
        let pp = old.map(project), n0 = pp.map(\.x).min()!, n1 = pp.map(\.x).max()!
        let a0 = pp.map(\.y).min()!, a1 = pp.map(\.y).max()!
        let nr = (abs(f.normal.x) + abs(f.normal.y)) * 0.5
        let ar = (abs(f.along.x) + abs(f.along.y)) * 0.5
        let card = [(-1, 0), (1, 0), (0, -1), (0, 1)]
        let dirs = card + [(-1, -1), (1, -1), (-1, 1), (1, 1)]
        // The complete captured pixels, not detector rectangles, are segmented.
        // Bounded reference distance prevents unbounded colour-gradient flooding.
        var labels = [Int](repeating: -1, count: w * h)
        for i in labels.indices where r.bytes[(i / w) * r.bytesPerRow + (i % w) * 4 + 3] != 255 {
            labels[i] = -2
        }
        var components: [Component] = []
        for seed in labels.indices where labels[seed] == -1 {
            guard components.count < 20_000 else { return none("RGB-component-budget-exceeded") }
            let id = components.count, reference = rgb(seed)
            var pixels = [seed], cursor = 0, anchors = 0
            labels[seed] = id
            while cursor < pixels.count {
                let i = pixels[cursor]; cursor += 1
                let p = world(i)
                if e.body[i] != 0 && K.contains(old, p) && e.privateAt(p) { anchors += 1 }
                for (dx, dy) in dirs {
                    guard let j = index(i % w + dx, i / w + dy), labels[j] == -1,
                          distance(rgb(j), reference) <= 32, distance(rgb(i), rgb(j)) <= 24
                    else { continue }
                    labels[j] = id; pixels.append(j)
                }
            }
            var loN = CGFloat.infinity, hiN = -CGFloat.infinity
            var loA = CGFloat.infinity, hiA = -CGFloat.infinity
            var clipped = false, contrast: [[Int]] = []
            for i in pixels {
                let p = project(world(i))
                loN = min(loN, p.x - nr); hiN = max(hiN, p.x + nr)
                loA = min(loA, p.y - ar); hiA = max(hiA, p.y + ar)
                for (dx, dy) in card {
                    guard let j = index(i % w + dx, i / w + dy), labels[j] != -2
                    else { clipped = true; continue }
                    if contrast.count < 12, labels[j] != id,
                       let k = index(i % w + 2 * dx, i / w + 2 * dy), labels[k] != -2,
                       distance(rgb(i), rgb(j)) >= 40, distance(rgb(j), rgb(k)) <= 16 {
                        contrast.append([i, j, k])
                    }
                }
            }
            components.append(.init(pixels: pixels, colour: reference, anchors: anchors,
                n0: loN, n1: hiN, a0: loA, a1: hiA, clipped: clipped, contrast: contrast))
        }
        func compact(_ id: Int) -> Bool {
            let c = components[id]
            return !c.clipped && c.pixels.count >= 3 && c.pixels.count <= 200_000 &&
                c.n1 - c.n0 <= 2 * mw && c.a1 - c.a0 <= 4 * mw &&
                (c.n0 + c.n1) * 0.5 >= n0 - 0.3 * mw &&
                (c.n0 + c.n1) * 0.5 <= n1 + 0.3 * mw
        }
        // Root anchors must be both authentic GG pixels and original private cells.
        let roots = components.indices.filter {
            compact($0) && components[$0].anchors >= 2 && components[$0].contrast.count >= 3
        }
        guard !roots.isEmpty else { return none("no-finite-contrast-root-GG-private-component") }
        guard roots.count <= 256 else { return none("root-component-budget-exceeded") }
        // No palette constraint: independently supported terminal ink may change colour.
        let eligible = components.indices.filter { compact($0) && components[$0].contrast.count >= 3 }
        let potential = Array(eligible.sorted { l, r in
            let x = components[l], y = components[r]
            let dx = max(0, max(a0 - x.a1, x.a0 - a1))
            let dy = max(0, max(a0 - y.a1, y.a0 - a1))
            return dx == dy ? l < r : dx < dy
        }.prefix(768))
        let candidates = Set(roots).union(potential)
        let validRF = e.rf.indices.filter {
            let v = e.rf[$0]
            return v.confidence.isFinite && v.confidence >= 0.5 && v.confidence <= 1 &&
                v.bounds.count == 4 && v.bounds.allSatisfy({ $0.isFinite }) &&
                v.bounds[0] < v.bounds[2] && v.bounds[1] < v.bounds[3]
        }
        var votes: [Int: Vote] = [:], queries = 0, queryLimitReached = false
        for id in candidates.sorted() {
            let pixels = components[id].pixels, count = min(32, pixels.count)
            var vote = Vote()
            for k in 0..<count {
                let i = pixels[k * (pixels.count - 1) / max(1, count - 1)], p = world(i)
                var db: [Int] = [], rf: [Int] = []
                for d in e.detectors.indices {
                    if queries >= 2_000_000 { queryLimitReached = true; break }
                    queries += 1
                    if e.detectors[d].cells.contains(p) { vote.db.insert(d); db.append(d) }
                }
                for v in validRF where e.rf[v].contains(p) { vote.rf.insert(v); rf.append(v) }
                if (!db.isEmpty || !rf.isEmpty) && vote.witnesses.count < 4 {
                    var value = witness(i)
                    value["actualDetectorArrayPositions"] = db
                    value["RFArrayPositions"] = rf
                    vote.witnesses.append(value)
                }
            }
            votes[id] = vote
        }
        let rootRF = roots.reduce(into: Set<Int>()) { $0.formUnion(votes[$1]?.rf ?? []) }
        let rootDB = roots.reduce(into: Set<Int>()) { $0.formUnion(votes[$1]?.db ?? []) }
        let hasRootDetector = rootDB.contains { e.detectors[$0].nativeRoot }
        func independentlyCorroborated(_ id: Int) -> Bool {
            guard let v = votes[id] else { return false }
            let sharedRF = !v.rf.intersection(rootRF).isEmpty
            let sharedDB = !v.db.intersection(rootDB).isEmpty
            let exactRoot = v.db.contains { e.detectors[$0].nativeRoot }
            // All votes sample real CC pixels. RF is corroboration, never foreground.
            return (sharedRF && (sharedDB || (hasRootDetector && !v.db.isEmpty))) ||
                   (exactRoot && !v.rf.isEmpty && !rootRF.isEmpty)
        }
        // Actual cardinal contacts allow finite fill/rim recovery. An RF box or
        // a hull never supplies contact pixels. Long enclosure/border CCs fail compact.
        var contacts: [Int: [Int: Int]] = [:], contactWitnesses: [Int: [[Int]]] = [:]
        var contactEdges = 0
        for id in candidates.sorted() {
            for i in components[id].pixels {
                for (dx, dy) in card {
                    guard let j = index(i % w + dx, i / w + dy), labels[j] >= 0,
                          labels[j] != id, compact(labels[j]) else { continue }
                    let other = labels[j]
                    if contacts[id]?[other] == nil {
                        contactEdges += 1
                        guard contactEdges <= 100_000 else { return none("contact-edge-budget-exceeded") }
                    }
                    contacts[id, default: [:]][other, default: 0] += 1
                    if contactWitnesses[other, default: []].count < 4 {
                        contactWitnesses[other, default: []].append([i, j])
                    }
                }
            }
        }
        var associated = Set(roots), links: [[String: Any]] = []
        // Large internal gaps are allowed only with independent RF/DB evidence.
        // The bound is the captured source, not the inherited endpoint +/- nativeW.
        for hop in 1...16 {
            var additions: [Int] = []
            for id in potential where !associated.contains(id) && independentlyCorroborated(id) {
                let c = components[id]
                let parent = associated.sorted().first { other in
                    let p = components[other]
                    let gap = max(0, max(c.a0 - p.a1, p.a0 - c.a1))
                    let centerDistance = abs(c.n0 + c.n1 - p.n0 - p.n1) * 0.5
                    return gap <= 3 * mw && centerDistance <= 0.65 * mw
                }
                guard let parent = parent else { continue }
                additions.append(id)
                links.append(["componentID": id, "parentComponentID": parent, "hop": hop,
                    "colourEqualityRequired": false, "RFDBPixelCorroborated": true,
                    "sourceTerminalOwnershipProven": false])
            }
            if additions.isEmpty { break }
            associated.formUnion(additions)
        }
        func withContour(_ base: Set<Int>) -> Set<Int> {
            var result = base, frontier = base
            for _ in 0..<3 {
                var added = Set<Int>()
                for parent in frontier.sorted() {
                    for id in (contacts[parent] ?? [:]).keys.sorted()
                    where contacts[parent]![id]! >= 3 && !result.contains(id) {
                        // Contact is evidence of adjacency, not private ownership.
                        added.insert(id)
                    }
                }
                if added.isEmpty { break }
                result.formUnion(added); frontier = added
            }
            return result
        }
        let rootSet = Set(roots), contour = withContour(associated)
        // Three endpoint modes, with and without lateral completion, plus the
        // root-only connected envelope: at most seven raw proposals, no padding.
        var choices: [(String, Set<Int>, Int, Bool)] = []
        for mode in [1, 2, 3] {
            choices.append(("continuation-cap\(mode)", associated, mode, false))
            choices.append(("continuation-contour-cap\(mode)", contour, mode, true))
        }
        choices.append(("root-connected-envelope", withContour(rootSet), 3, true))
        var proposals: [K.Proposal] = [], seen = Set<String>(), used = Set<Int>()
        var invalid = 0
        for (name, ids, mode, lateral) in choices {
            var target = planes, extrema = [Int](repeating: -1, count: 4)
            for id in ids.sorted() {
                for i in components[id].pixels {
                    let p = world(i)
                    for edge in 0..<4 {
                        let n = normals[edge], alignment = n.x * f.along.x + n.y * f.along.y
                        let isAlong = abs(alignment) >= 0.7071067811865476
                        let allowed = isAlong ? (alignment < 0 ? mode & 1 != 0 : mode & 2 != 0) : lateral
                        guard allowed else { continue }
                        // Project the actual unit pixel square, not an arbitrary margin.
                        let support = n.x * p.x + n.y * p.y + (abs(n.x) + abs(n.y)) * 0.5
                        if support > target[edge] { target[edge] = support; extrema[edge] = i }
                    }
                }
            }
            guard zip(target, planes).contains(where: { $0.0 - $0.1 > 0.01 }) else { continue }
            var q: [CGPoint] = []
            for edge in 0..<4 {
                let previous = (edge + 3) % 4, a = normals[previous], b = normals[edge]
                let u = target[previous], v = target[edge], det = a.x * b.y - a.y * b.x
                if abs(det) < 1e-8 { break }
                q.append(CGPoint(x: (u * b.y - a.y * v) / det, y: (a.x * v - u * b.x) / det))
            }
            guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite && insideCapture($0) }),
                  old.allSatisfy({ K.contains(q, $0) }) else { invalid += 1; continue }
            let qturns = (0..<4).map { i -> CGFloat in
                let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
                return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
            }
            guard ccw ? qturns.allSatisfy({ $0 > 1e-8 }) : qturns.allSatisfy({ $0 < -1e-8 })
            else { invalid += 1; continue }
            let key = q.map { String(format: "%.8f,%.8f", Double($0.x), Double($0.y)) }.joined(separator: ";")
            guard seen.insert(key).inserted else { continue }
            let bodyLoss = labels.indices.filter {
                e.body[$0] != 0 && K.contains(old, world($0)) && !K.contains(q, world($0))
            }
            let cellLoss = e.nativeCellCenters.filter { K.contains(old, $0) && !K.contains(q, $0) }
            let addedBody = labels.indices.filter {
                e.body[$0] != 0 && !K.contains(old, world($0)) && K.contains(q, world($0))
            }
            let selected = ids.sorted()
            let peer = selected.reduce(into: Set<Int>()) { result, id in
                result.formUnion((votes[id]?.db ?? []).filter { !e.detectors[$0].nativeRoot })
            }
            let rec: [String: Any] = [
                "family": family, "operator": name, "actualOld": old.map { [Double($0.x), Double($0.y)] },
                "signedEdgePlaneChanges": zip(target, planes).map { Double($0.0 - $0.1) },
                "edgeActualSupport": extrema.map { $0 >= 0 ? witness($0) : ["edgeUnchanged": true] },
                "sourceSupportComponentIDs": selected, "actualOldEnclosed": true,
                "originalEdgeDirectionsPreserved": true, "arbitraryPaddingUsed": false,
                "newlyExcludedOriginalGGBodyPixels": bodyLoss.count,
                "newlyExcludedActualNativeCellCenters": cellLoss.count,
                "GGBodyLossWitnesses": bodyLoss.prefix(4).map(witness),
                "nativeCellLossWitnesses": cellLoss.prefix(4).map { [Double($0.x), Double($0.y)] },
                "previouslyOutsideOldGGBodyNowIncluded": addedBody.count,
                "newGGBodyWitnesses": addedBody.prefix(4).map(witness),
                "otherDetectorEvidenceArrayPositions": peer.sorted(),
                "RFAndDBAreNotForegroundMasks": true, "privateFootprintMutated": false,
                "detachedAssociationIsSourceCorroboratedNotOwnership": true,
                "completeForegroundPreservationClaimed": false, "admissionGranted": false,
                "nativeAdmissionSuiteRun": false, "runtimeSelection": false]
            proposals.append(.init(suffix: "terminal402-" + name, polygon: q, receipt: rec,
                obligations: ["actual-native-all-member-whole-dense-GG-semantic-admission-required",
                    "new-peer-or-foreign-acquisition-and-retained-peer-check-required",
                    "detached-terminal-and-quote-association-requires-native-verdict",
                    "captured-window-is-not-global-completeness", "no-erasure-authority",
                    "preexisting-overextent-and-axis-error-not-corrected"]))
            used.formUnion(ids)
        }
        let supports: [[String: Any]] = used.sorted().map { id in
            let c = components[id], vote = votes[id] ?? Vote()
            return ["componentID": id, "actualLocalRunsYXCount": runs(c.pixels),
                "actualPixelCount": c.pixels.count, "actualGGPrivateAnchors": c.anchors,
                "RGB": [c.colour.x, c.colour.y, c.colour.z],
                "projectedActualCellBounds": [Double(c.n0), Double(c.a0), Double(c.n1), Double(c.a1)],
                "contrastActualPixels": c.contrast.map { $0.map(witness) },
                "actualContactPixels": (contactWitnesses[id] ?? []).map { $0.map(witness) },
                "RFDBActualPixelVotes": vote.witnesses,
                "detectorArrayPositions": vote.db.sorted(), "RFArrayPositions": vote.rf.sorted(),
                "clippedAtCapture": c.clipped, "sourceOwnershipClaimed": false]
        }
        return .init(proposals: proposals, receipt: [
            "family": family, "status": proposals.isEmpty ? "no-supported-outward-change" : "source-only-extension-nominations",
            "sourceSupportComponents": supports, "sourceTerminalLinks": links,
            "actualRGBComponents": components.count, "rootComponents": roots.count,
            "eligibleComponents": eligible.count, "sampledComponents": potential.count,
            "potentialTruncated": eligible.count > potential.count,
            "clippedComponentsUnresolved": components.filter { $0.clipped }.count,
            "detectorQueries": queries, "detectorQueryLimitReached": queryLimitReached,
            "invalidOrOutsideCaptureGeometry": invalid, "proposals": proposals.count,
            "maxRawProposals": 7, "originalBasisRetained": true,
            "RFRectanglesAreNotMasks": true, "nativeRootMeansOriginalSparseCellSubset": true,
            "nativeAdmissionSuiteRun": false, "admissionGranted": false,
            "completeForegroundPreservationClaimed": false, "ownershipChanged": false])
    }
}
