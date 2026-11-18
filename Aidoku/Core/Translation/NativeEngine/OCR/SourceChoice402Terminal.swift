import Foundation
import CoreGraphics

// A source nomination only. The score is evidence strength in [0,1], not
// recognition probability, global completeness, ownership, or native admission.
enum SourceChoice402Terminal {
    typealias K = NativeOCRSharedBoundary396
    private struct Component {
        let id: Int
        let pixels: [Int]
        let anchors: Int
        let closed: Bool
        let contrast: Int
        let votes: [[String: Any]]
        let rf: Set<Int>
        let db: Set<Int>
        let contacts: [[[String: Any]]]
    }
    private static func number(_ value: Any?) -> Double? {
        guard let x = value as? NSNumber, x.doubleValue.isFinite else { return nil }
        return x.doubleValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let x = number(value), x >= 0, x < Double(Int.max), x.rounded() == x else { return nil }
        return Int(x)
    }
    private static func point(_ value: Any?) -> CGPoint? {
        guard let v = value as? [Any], v.count == 2,
              let x = number(v[0]), let y = number(v[1]) else { return nil }
        return CGPoint(x: x, y: y)
    }
    private static func area(_ q: [CGPoint]) -> Double {
        abs((0..<4).reduce(0.0) { z, i in
            let p = q[i], n = q[(i + 1) % 4]
            return z + Double(p.x * n.y - p.y * n.x)
        }) * 0.5
    }

    static func preferred(output: K.Output, actualOld old: [CGPoint], basis f: K.Basis,
                          nativeW mw: CGFloat) -> (index: Int, score: Double, receipt: [String: Any])? {
        guard old.count == 4, output.proposals.count <= 8,
              old.allSatisfy({ $0.x.isFinite && $0.y.isFinite }), mw.isFinite, mw > 0,
              [f.origin.x, f.origin.y, f.normal.x, f.normal.y, f.along.x, f.along.y].allSatisfy({ $0.isFinite }),
              abs(hypot(f.normal.x, f.normal.y) - 1) < 1e-6,
              abs(hypot(f.along.x, f.along.y) - 1) < 1e-6,
              abs(f.normal.x * f.along.x + f.normal.y * f.along.y) < 1e-6,
              output.receipt["family"] as? String == "repair402-terminal-extension",
              output.receipt["potentialTruncated"] as? Bool == false,
              output.receipt["detectorQueryLimitReached"] as? Bool == false,
              let rows = output.receipt["sourceSupportComponents"] as? [[String: Any]],
              !rows.isEmpty, rows.count <= 20_000 else { return nil }
        let turns = (0..<4).map { i -> CGFloat in
            let a = old[i], b = old[(i + 1) % 4], c = old[(i + 2) % 4]
            return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x)
        }
        guard turns.allSatisfy({ $0 > 1e-8 }) || turns.allSatisfy({ $0 < -1e-8 }) else { return nil }
        let ccw = turns[0] > 0
        var normals: [CGPoint] = [], planes: [CGFloat] = []
        for i in 0..<4 {
            let a = old[i], b = old[(i + 1) % 4], dx = b.x - a.x, dy = b.y - a.y
            let len = hypot(dx, dy)
            let n = ccw ? CGPoint(x: dy / len, y: -dx / len) : CGPoint(x: -dy / len, y: dx / len)
            normals.append(n); planes.append(n.x * a.x + n.y * a.y)
        }
        // Decode existing source RLE coordinates using actual pixel witnesses.
        // No image is read and no rectangle is filled to manufacture pixels.
        var witnesses: [[String: Any]] = []
        for row in rows {
            witnesses += (row["contrastActualPixels"] as? [[[String: Any]]] ?? []).flatMap { $0 }
            witnesses += (row["actualContactPixels"] as? [[[String: Any]]] ?? []).flatMap { $0 }
            witnesses += row["RFDBActualPixelVotes"] as? [[String: Any]] ?? []
        }
        guard !witnesses.isEmpty, witnesses.count <= 600_000,
              let first = witnesses.first, let firstIndex = integer(first["actualLocalPixelIndex"]),
              let firstPoint = point(first["center"]) else { return nil }
        var stride: Int?
        for value in witnesses {
            guard let i = integer(value["actualLocalPixelIndex"]), let p = point(value["center"]) else { return nil }
            let dy = Double(p.y - firstPoint.y), dx = Double(p.x - firstPoint.x)
            guard abs(dy.rounded() - dy) < 1e-6, abs(dx.rounded() - dx) < 1e-6 else { return nil }
            if abs(dy) > 0.5 {
                let candidate = (Double(i) - Double(firstIndex) - dx) / dy
                guard candidate >= 3, candidate <= 200_000, abs(candidate.rounded() - candidate) < 1e-6 else { return nil }
                let width = Int(candidate.rounded())
                if let established = stride, established != width { return nil }
                stride = width
            }
        }
        guard let width = stride else { return nil }
        let origin = CGPoint(x: firstPoint.x - CGFloat(firstIndex % width) - 0.5,
                             y: firstPoint.y - CGFloat(firstIndex / width) - 0.5)
        func world(_ i: Int) -> CGPoint {
            CGPoint(x: origin.x + CGFloat(i % width) + 0.5, y: origin.y + CGFloat(i / width) + 0.5)
        }
        for value in witnesses {
            guard let i = integer(value["actualLocalPixelIndex"]), let p = point(value["center"]),
                  hypot(p.x - world(i).x, p.y - world(i).y) < 1e-6,
                  let rgb = value["RGB"] as? [Int], rgb.count == 3,
                  rgb.allSatisfy({ (0...255).contains($0) }) else { return nil }
        }
        var components: [Int: Component] = [:], owner: [Int: Int] = [:]
        for row in rows {
            guard let id = integer(row["componentID"]), components[id] == nil,
                  let count = integer(row["actualPixelCount"]), count > 0,
                  let runs = row["actualLocalRunsYXCount"] as? [[Int]],
                  let anchors = integer(row["actualGGPrivateAnchors"]), anchors <= count,
                  let clipped = row["clippedAtCapture"] as? Bool else { return nil }
            var pixels: [Int] = []
            for run in runs {
                guard run.count == 3, run[0] >= 0, run[1] >= 0, run[2] > 0,
                      run[2] <= width, run[1] <= width - run[2], run[0] <= (Int.max - width) / width,
                      pixels.count <= 600_000 - run[2], owner.count <= 600_000 - run[2] else { return nil }
                for x in run[1]..<(run[1] + run[2]) {
                    let i = run[0] * width + x
                    guard owner[i] == nil else { return nil }
                    owner[i] = id; pixels.append(i)
                }
            }
            guard pixels.count == count else { return nil }
            components[id] = .init(id: id, pixels: pixels, anchors: anchors, closed: !clipped,
                contrast: (row["contrastActualPixels"] as? [[[String: Any]]] ?? []).count,
                votes: row["RFDBActualPixelVotes"] as? [[String: Any]] ?? [],
                rf: Set(row["RFArrayPositions"] as? [Int] ?? []),
                db: Set(row["detectorArrayPositions"] as? [Int] ?? []),
                contacts: row["actualContactPixels"] as? [[[String: Any]]] ?? [])
        }
        let roots = components.values.filter { $0.closed && $0.contrast >= 3 && $0.anchors >= 2 }
        guard !roots.isEmpty else { return nil }
        var reached = Set(roots.map(\.id)), paths: [[String: Any]] = []
        var adjacency: [Int: [Int: Set<String>]] = [:]
        for c in components.values where c.closed {
            for pair in c.contacts where pair.count == 2 {
                guard let a = integer(pair[0]["actualLocalPixelIndex"]),
                      let b = integer(pair[1]["actualLocalPixelIndex"]), owner[b] == c.id,
                      let parent = owner[a], parent != c.id else { continue }
                let dx = abs(a % width - b % width), dy = abs(a / width - b / width)
                guard dx + dy == 1 else { continue }
                adjacency[parent, default: [:]][c.id, default: []].insert("\(a):\(b)")
            }
        }
        let links = output.receipt["sourceTerminalLinks"] as? [[String: Any]] ?? []
        for _ in 0..<32 {
            let before = reached.count
            for parent in reached.sorted() {
                for id in (adjacency[parent] ?? [:]).keys.sorted() where !reached.contains(id) {
                    guard (adjacency[parent]?[id]?.count ?? 0) >= 3 else { continue }
                    reached.insert(id); paths.append(["componentID": id, "parent": parent, "kind": "actual-cardinal-contact"])
                }
            }
            for link in links {
                guard link["RFDBPixelCorroborated"] as? Bool == true,
                      let id = integer(link["componentID"]), !reached.contains(id),
                      let parent = integer(link["parentComponentID"]), reached.contains(parent),
                      let c = components[id], c.closed, c.contrast >= 3,
                      !c.db.isEmpty, !c.rf.isEmpty,
                      c.votes.contains(where: { v in
                          guard let i = integer(v["actualLocalPixelIndex"]), owner[i] == id else { return false }
                          return !(v["actualDetectorArrayPositions"] as? [Int] ?? []).isEmpty &&
                                 !(v["RFArrayPositions"] as? [Int] ?? []).isEmpty
                      }) else { continue }
                reached.insert(id); paths.append(["componentID": id, "parent": parent, "kind": "generator-RFDB-link-with-joint-real-pixel-vote"])
            }
            if reached.count == before { break }
        }
        let credible = components.values.filter { reached.contains($0.id) && $0.closed }
        let outside = credible.flatMap(\.pixels).filter { !K.contains(old, world($0)) }
        guard outside.count >= 3 else { return nil }
        var best: (index: Int, score: Double, receipt: [String: Any])?
        var rejected: [[String: Any]] = []
        for (index, proposal) in output.proposals.enumerated() {
            func reject(_ reason: String) { rejected.append(["index": index, "reason": reason]) }
            let q = proposal.polygon, rec = proposal.receipt
            guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  rec["family"] as? String == "repair402-terminal-extension",
                  rec["actualOldEnclosed"] as? Bool == true,
                  rec["newlyExcludedOriginalGGBodyPixels"] as? Int == 0,
                  rec["newlyExcludedActualNativeCellCenters"] as? Int == 0,
                  let oldValues = rec["actualOld"] as? [Any], oldValues.count == 4,
                  oldValues.allSatisfy({ point($0) != nil }),
                  zip(oldValues.compactMap { point($0) }, old).allSatisfy({ hypot($0.0.x - $0.1.x, $0.0.y - $0.1.y) < 1e-6 }),
                  old.allSatisfy({ K.contains(q, $0) }),
                  let selected = rec["sourceSupportComponentIDs"] as? [Int],
                  selected.allSatisfy({ components[$0] != nil }),
                  let edgeSupport = rec["edgeActualSupport"] as? [[String: Any]], edgeSupport.count == 4
            else { reject("missing-or-inconsistent-source-receipt"); continue }
            var changes: [Double] = [], valid = true, edgeEvidence: [[String: Any]] = []
            for edge in 0..<4 {
                let n = normals[edge], a = q[edge], b = q[(edge + 1) % 4]
                let qa = n.x * a.x + n.y * a.y, qb = n.x * b.x + n.y * b.y
                let change = qa - planes[edge]
                if abs(qa - qb) > 1e-5 || change < -1e-6 { valid = false; break }
                changes.append(Double(max(0, change)))
                if change <= 0.01 { continue }
                let v = edgeSupport[edge]
                guard let i = integer(v["actualLocalPixelIndex"]), let id = owner[i],
                      selected.contains(id), reached.contains(id), let c = components[id], c.closed,
                      let p = point(v["center"]), hypot(p.x - world(i).x, p.y - world(i).y) < 1e-6,
                      abs(n.x * p.x + n.y * p.y + (abs(n.x) + abs(n.y)) * 0.5 - qa) < 1e-5
                else { valid = false; break }
                edgeEvidence.append(["edge": edge, "componentID": id, "actualLocalPixelIndex": i,
                    "outwardNativeW": Double(change / mw), "actualSupport": v])
            }
            guard valid, changes.contains(where: { $0 > 0.01 }) else { reject("changed-plane-lacks-reachable-real-pixel-support"); continue }
            let acquired = outside.filter { K.contains(q, world($0)) }
            let extentCoverage = Double(acquired.count) / Double(outside.count)
            guard acquired.count >= 3, extentCoverage >= 0.98 else { reject("observed-source-extent-left-out"); continue }
            let touched = components.values.filter { c in c.pixels.contains { i in !K.contains(old, world(i)) && K.contains(q, world(i)) } }
            let unknown = touched.filter { !reached.contains($0.id) }.reduce(0) { sum, c in
                sum + c.pixels.filter { !K.contains(old, world($0)) && K.contains(q, world($0)) }.count
            }
            let agreement = Double(acquired.count) / Double(acquired.count + unknown)
            guard agreement >= 0.98 else { reject("known-unassociated-new-pixels"); continue }
            let closure = touched.filter { reached.contains($0.id) }.allSatisfy { c in
                c.closed && c.pixels.allSatisfy { K.contains(q, world($0)) || K.contains(old, world($0)) }
            }
            guard closure else { reject("partially-enclosed-observed-component"); continue }
            let addedArea = area(q) - area(old)
            guard addedArea > 0, area(q).isFinite else { reject("invalid-positive-extension-area"); continue }
            let density = min(1, Double(acquired.count) / addedArea)
            // A supported long internal gap is allowed, but evidence cannot be
            // arbitrarily sparse in a huge acquired strip.
            guard density >= 0.01 else { reject("insufficient-source-pixels-for-added-area"); continue }
            let joint = touched.filter { c in reached.contains(c.id) && c.votes.contains { v in
                !(v["actualDetectorArrayPositions"] as? [Int] ?? []).isEmpty && !(v["RFArrayPositions"] as? [Int] ?? []).isEmpty
            } }.count
            let corroboration = Double(joint) / Double(max(1, touched.filter { reached.contains($0.id) }.count))
            let score = 0.30 * extentCoverage + 0.25 * agreement + 0.20 +
                        0.15 * corroboration + 0.10 * min(1, density / 0.15)
            let result: [String: Any] = [
                "policy": "source-choice402-terminal-v1", "proposalIndex": index, "score": score,
                "scoreMeaning": "normalized-observed-source-evidence-strength-not-probability",
                "components": ["observedSourceExtentCoverage": extentCoverage,
                    "knownNewPixelSupportAgreement": agreement, "finiteTouchedComponentClosure": 1.0,
                    "jointRFDBTouchedComponentFraction": corroboration, "newSourcePixelAreaDensity": density],
                "weights": ["extent": 0.30, "agreement": 0.25, "finiteClosure": 0.20, "RFDB": 0.15, "density": 0.10],
                "newObservedSourcePixels": acquired.count, "knownUnassociatedAcquiredPixels": unknown,
                "allCredibleObservedPixelsOutsideOld": outside.count,
                "sourceEdgeWitnesses": edgeEvidence, "sourceAssociationPaths": paths,
                "decodedActualSourceRLEWidth": width, "sourcePixelCoordinatesReconstructedFromReceipt": true,
                "completeForegroundPreservationClaimed": false, "globalCompletenessClaimed": false,
                "ownershipClaimed": false, "admissionGranted": false, "nativeAllGuardsStillRequired": true,
                "nominationOnly": true, "remainingObligations": proposal.obligations]
            if best == nil || score > best!.score + 1e-12 { best = (index, score, result) }
        }
        if var chosen = best {
            chosen.receipt["rejectedSourceNominations"] = rejected
            return chosen
        }
        return nil
    }
}
