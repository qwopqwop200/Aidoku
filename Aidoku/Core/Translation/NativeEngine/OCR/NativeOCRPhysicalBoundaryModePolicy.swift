import Foundation

/// Two physical body contracts plus separately measured outer-shell/continuation
/// uncertainty. These are declarations from live pixel-geometry producers, not
/// semantic labels, a learned classifier, source ownership, or a proposal budget.
@available(iOS 18.0, *)
enum NativeOCRPhysicalBoundaryModePolicy {
    typealias P = NativeOCRPhysicalPaintSupport
    struct Role {
        var contracts = Set<String>()
        var nonexclusivePartition = false
        var extentContract: String { contracts.isEmpty ? "unknown" : contracts.sorted().joined(separator: "+") }
        var boundaryMode: String {
            let contract = extentContract
            if contract.contains("complete-source-ink") { return "complete" }
            if contract.contains("measured-outer-shell") { return "shell" }
            if contract == "internal-ink-mass" || contract == "measured-normal-fixed-endpoints" { return "inner-body" }
            if ["measured-collinear-chain", "closed-paint-envelope", "fixed-normal-measured-endpoints"].contains(contract) { return "outer-body" }
            return contract
        }
    }
    private static func key(_ q: [P.Point]) -> [P.Point] {
        guard q.count == 4 else { return q }
        var best = q
        for winding in [q, Array(q.reversed())] {
            for start in 0..<4 {
                let candidate = Array(winding[start...]) + Array(winding[..<start])
                for i in 0..<4 where candidate[i] != best[i] {
                    if candidate[i].x < best[i].x || (candidate[i].x == best[i].x && candidate[i].y < best[i].y) { best = candidate }
                    break
                }
            }
        }
        return best
    }
    static func roles(candidates: [P.Candidate], measurements: [NativeOCRSourcePaintGeometry.Measurement]) -> [Role] {
        var bank: [[P.Point]: Role] = [:]
        for m in measurements {
            guard m.polygon.count == 4, m.polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { continue }
            let k = key(m.polygon.map { .init(x: $0[0], y: $0[1]) })
            let d = m.diagnostics
            var role = bank[k] ?? .init()
            let layer = m.layer.lowercased()
            let shell = ["rim", "halo", "stroke-uncertainty", "white-shell"].contains(where: layer.contains) || (d["measuredRimRadius"] ?? 0) > 0
            let partition = d["outlineTiesAreNonexclusive"] == 1
            let inheritedAlong = ["alongExtentPreserved", "detectorAlongPreserved", "longitudinalEndpointsFromQuery"].contains { d[$0] == 1 }
            let contract: String
            if m.terminalEvidence == .completeSourceInk {
                contract = "complete-source-ink"
            } else if shell {
                contract = "measured-outer-shell"
            } else if partition {
                contract = "nonexclusive-partition"
            } else if d["normalMassFraction"] != nil || d["completeVisibleInk"] == 0 {
                contract = "internal-ink-mass"
            } else if d["normalSidesPreserved"] == 1 {
                contract = "fixed-normal-measured-endpoints"
            } else if d["existingSourceEnvelopeIncluded"] == 1 {
                contract = "original-envelope-continuation"
            } else if inheritedAlong {
                contract = "measured-normal-fixed-endpoints"
            } else if d["nearestCoreAssociationOnly"] == 1 || (d["rootedClosedHoles"] ?? 0) > 0 {
                contract = "closed-paint-envelope"
            } else if d["actualPrivateHitPixels"] != nil {
                contract = "measured-collinear-chain"
            } else {
                contract = "unknown"
            }
            role.contracts.insert(contract)
            role.nonexclusivePartition = role.nonexclusivePartition || partition
            bank[k] = role
        }
        return candidates.map { bank[key($0.polygon)] ?? .init() }
    }
    static func select(bank: P.Bank, roles: [Role]) -> P.Output {
        let rows = bank.input.candidates
        guard roles.count == rows.count else {
            return .init(
                name: "physical-boundary-modes", kept: Array(rows.indices), replacements: [],
                missingEvidence: Array(rows.indices), cohorts: 0)
        }
        let order = rows.indices.sorted {
            let a = rows[$0].quality ?? -.infinity
            let b = rows[$1].quality ?? -.infinity
            return a == b ? $0 < $1 : a > b
        }
        var kept: [Int] = []
        var missing: [Int] = []
        var replacements: [P.Replacement] = []
        var retained: [P.Cohort: [Int]] = [:]
        var cohortIDs: [P.Cohort: Int] = [:]
        for i in order {
            guard let support = bank.support[i] else {
                kept.append(i)
                missing.append(i)
                continue
            }
            let c = rows[i]
            let role = roles[i]
            let key = P.Cohort(components: support.components, rfScope: support.rfScope)
            if cohortIDs[key] == nil { cohortIDs[key] = cohortIDs.count }
            var witness: Int?
            if c.physical && !role.nonexclusivePartition && role.extentContract != "unknown" {
                for j in retained[key, default: []] {
                    let w = rows[j]
                    guard w.physical, role.boundaryMode == roles[j].boundaryMode else { continue }
                    if c.completeInk && (!w.completeInk || !P.encloses(w.polygon, c.polygon)) { continue }
                    if c.halo && (!w.halo || !P.encloses(w.polygon, c.polygon)) { continue }
                    guard support.cells.isSubset(of: bank.support[j]!.cells) else { continue }
                    witness = j
                    break
                }
            }
            if let j = witness {
                replacements.append(
                    .init(
                        inputIndex: i, witnessIndex: j, cohort: cohortIDs[key]!,
                        haloPreserved: !c.halo || P.encloses(rows[j].polygon, c.polygon),
                        exactCCCellCover: support.cells.isSubset(of: bank.support[j]!.cells)))
            } else {
                kept.append(i)
                retained[key, default: []].append(i)
            }
        }
        return .init(
            name: "physical-boundary-modes", kept: kept.sorted(), replacements: replacements,
            missingEvidence: missing, cohorts: cohortIDs.count)
    }
}
