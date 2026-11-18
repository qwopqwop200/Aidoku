import CoreGraphics
import Foundation

/// Sampling-only access to authentic v2 cells. Never replaces a detector's ownership evidence.
@available(iOS 18.0, *)
enum NativeOCRResidualEvidenceForwarding {
    typealias Evidence = NativeOCRDetectorSeedEvidence
    struct Plan {
        let evidence: [Evidence] // Exact original objects, including unchanged ambiguous/candidate roles.
        let componentsByOwner: [String: [Evidence.Component]]
        let allowedCells: Set<Int> // Authentic cell indices only, not filled polygons or probability synthesis.
        let sourceIndex: Int
        let polygon: [CGPoint]
        let mapWidth: Int
        let mapHeight: Int
        fileprivate init(evidence: [Evidence], componentsByOwner: [String: [Evidence.Component]], allowedCells: Set<Int>,
                         sourceIndex: Int, polygon: [CGPoint], mapWidth: Int, mapHeight: Int) {
            self.evidence = evidence; self.componentsByOwner = componentsByOwner; self.allowedCells = allowedCells
            self.sourceIndex = sourceIndex; self.polygon = polygon; self.mapWidth = mapWidth; self.mapHeight = mapHeight
        }
    }
    struct Assessment {
        let plan: Plan?
        let reason: String
        let checkedCells: Int
        let excludedForeignCells: Int
    }

    static func assess(index: Int, polygon: [CGPoint], originals: [NativeCoreMLDetectionBox],
                       prepared: [NativeCoreMLDetectionBox], groups: [Int: [Int]]) -> Assessment {
        var checked = 0, excluded = 0
        func done(_ reason: String, _ plan: Plan? = nil) -> Assessment {
            .init(plan: plan, reason: reason, checkedCells: checked, excludedForeignCells: excluded)
        }
        guard prepared.indices.contains(index), originals.count <= 4096, valid(polygon) else { return done("unsupported-source") }
        let members = groups[index] ?? [index]
        guard !members.isEmpty, members.count <= 64, Set(members).count == members.count,
              members.allSatisfy({ originals.indices.contains($0) && valid(originals[$0].polygon) }) else { return done("invalid-members") }
        let evidence = members.compactMap { originals[$0].detectorSeedEvidence }
        guard evidence.count == members.count, let first = evidence.first,
              evidence.allSatisfy({ $0.isValid && $0.ownershipVersion == 2 && $0.completeCCScan == true && sameGrid($0, first) }) else {
            return done("missing-authentic-v2")
        }
        let owners = Set(evidence.map(\.ownerID)), memberSet = Set(members)
        guard owners.count == evidence.count else { return done("duplicate-owner") }
        let query = bounds(polygon), sx = CGFloat(first.sourceWidth) / CGFloat(first.mapFullWidth)
        let sy = CGFloat(first.sourceHeight) / CGFloat(first.mapFullHeight)
        let memberPolygons = members.map { (polygon: originals[$0].polygon, bounds: bounds(originals[$0].polygon)) }
        let peers = originals.indices.filter { !memberSet.contains($0) }
        guard peers.allSatisfy({ valid(originals[$0].polygon) }) else { return done("invalid-peer") }
        let foreignPolygons = peers.map { (polygon: originals[$0].polygon, bounds: bounds(originals[$0].polygon)) }.filter { overlaps($0.bounds, query) }
        var externalPrivate = Set<Int>(), knownOwners = Set<String>()
        var seen: [Int: Evidence.Component] = [:]
        // Validate authentic repeated CC identities before considering a sample.
        for (i, box) in originals.enumerated() {
            guard let e = box.detectorSeedEvidence else { continue }
            guard e.isValid, sameGrid(e, first) else { return done("mixed-or-invalid-inventory") }
            guard knownOwners.insert(e.ownerID).inserted else { return done("duplicate-inventory-owner") }
            for c in e.components + (e.ambiguousComponents ?? []) + (e.candidateComponents ?? []).map(\.component) {
                if let previous = seen[c.seed], previous != c { return done("contradictory-cc") }
                seen[c.seed] = c
                guard seen.count <= 16_384 else { return done("component-budget") }
            }
            guard !memberSet.contains(i) else { continue }
            guard !owners.contains(e.ownerID) else { return done("external-owner-alias") }
            for c in e.components { for run in c.runs {
                let y = (CGFloat(run.y) + 0.5) * sy
                guard y >= query.minY, y <= query.maxY else { continue }
                let lower = max(run.x, Int(floor(query.minX / sx)))
                let upper = min(run.x + run.count, Int(ceil(query.maxX / sx)))
                guard lower < upper else { continue }
                for x in lower..<upper {
                    checked += 1
                    guard checked <= 262_144 else { return done("cell-budget") }
                    externalPrivate.insert(run.y * first.mapFullWidth + x)
                }
            }}
        }
        let gridX0 = max(0, Int(floor(query.minX / sx))), gridX1 = min(first.mapFullWidth, Int(ceil(query.maxX / sx)))
        let gridY0 = max(0, Int(floor(query.minY / sy))), gridY1 = min(first.mapFullHeight, Int(ceil(query.maxY / sy)))
        guard gridX0 < gridX1, gridY0 < gridY1 else { return done("empty-query") }
        var components: [String: [Evidence.Component]] = [:], allowed = Set<Int>(), pointChecks = 0
        for e in evidence {
            // Unknown competitors are not resolved by proximity. Original role metadata is retained.
            let candidates = (e.candidateComponents ?? []).filter { $0.competingOwnerIDs.allSatisfy(knownOwners.contains) }.map(\.component)
            let all = e.components + (e.ambiguousComponents ?? []) + candidates
            for c in all {
                var local = Set<Int>()
                for run in c.runs where run.y >= gridY0 && run.y < gridY1 {
                    let lower = max(run.x, gridX0), upper = min(run.x + run.count, gridX1)
                    guard lower < upper else { continue }
                    for x in lower..<upper {
                        checked += 1
                        guard checked <= 262_144 else { return done("cell-budget") }
                        let cell = run.y * first.mapFullWidth + x
                        guard !externalPrivate.contains(cell) else { excluded += 1; continue }
                        let p = CGPoint(x: (CGFloat(x) + 0.5) * sx, y: (CGFloat(run.y) + 0.5) * sy)
                        pointChecks += 1
                        guard pointChecks <= 1_048_576 else { return done("point-budget") }
                        guard NativeOCRSourceComponentMeasurements.contains(polygon, p) else { continue }
                        var member = false
                        for q in memberPolygons where q.bounds.contains(p) {
                            pointChecks += 1
                            guard pointChecks <= 1_048_576 else { return done("point-budget") }
                            if NativeOCRSourceComponentMeasurements.contains(q.polygon, p) { member = true; break }
                        }
                        guard member else { continue }
                        var foreign = false
                        for q in foreignPolygons where q.bounds.contains(p) {
                            pointChecks += 1
                            guard pointChecks <= 1_048_576 else { return done("point-budget") }
                            if NativeOCRSourceComponentMeasurements.contains(q.polygon, p) { foreign = true; break }
                        }
                        if foreign { excluded += 1; continue }
                        local.insert(cell)
                    }
                }
                if !local.isEmpty {
                    components[e.ownerID, default: []].append(c) // Exact full original CC/run identity.
                    allowed.formUnion(local)
                }
            }
        }
        guard allowed.count >= 4 else { return done("insufficient-unique-source-cells") }
        return done("sampling-plan", .init(evidence: evidence, componentsByOwner: components, allowedCells: allowed,
                                           sourceIndex: index, polygon: polygon, mapWidth: first.mapFullWidth, mapHeight: first.mapFullHeight))
    }

    private static func sameGrid(_ a: Evidence, _ b: Evidence) -> Bool {
        a.mapOriginX == b.mapOriginX && a.mapOriginY == b.mapOriginY && a.mapFullWidth == b.mapFullWidth &&
            a.mapFullHeight == b.mapFullHeight && a.sourceWidth == b.sourceWidth && a.sourceHeight == b.sourceHeight
    }
    private static func valid(_ p: [CGPoint]) -> Bool {
        guard p.count == 4, p.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var turns: [CGFloat] = []
        for i in 0..<4 {
            let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
            turns.append((b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x))
        }
        return turns.allSatisfy({ $0 > 1e-8 }) || turns.allSatisfy({ $0 < -1e-8 })
    }
    private static func bounds(_ p: [CGPoint]) -> CGRect {
        .init(x: p.map(\.x).min()!, y: p.map(\.y).min()!, width: p.map(\.x).max()!-p.map(\.x).min()!, height: p.map(\.y).max()!-p.map(\.y).min()!)
    }
    private static func overlaps(_ a: CGRect, _ b: CGRect) -> Bool {
        a.minX <= b.maxX && b.minX <= a.maxX && a.minY <= b.maxY && b.minY <= a.maxY
    }
}
