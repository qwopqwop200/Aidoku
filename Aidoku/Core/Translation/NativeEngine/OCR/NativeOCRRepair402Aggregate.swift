import Foundation
import CoreGraphics

/// Source-only shared repair menu. Native admission and selection are separate.
enum NativeOCRRepair402Aggregate {
    typealias K = NativeOCRSharedBoundary396
    typealias PrivateRLE = K.PrivateRLE
    typealias Detector = K.Detector
    typealias RF = K.RF
    typealias Evidence = K.Evidence
    typealias Basis = K.Basis
    typealias Output = K.Output
    static let maximumOffers = 128

    static func generate(actualOld: [CGPoint], basis: Basis, nativeW: CGFloat, evidence: Evidence) -> Output {
        let started = Date()
        let nodes: [(String, Output)] = [
            ("source396", K.generate(actualOld: actualOld, basis: basis, nativeW: nativeW, evidence: evidence)),
            ("terminal402", NativeOCRRepair402Terminal.generate(actualOld: actualOld, basis: basis, nativeW: nativeW, evidence: evidence)),
            ("outline402", NativeOCRRepair402Outline.generate(actualOld: actualOld, basis: basis, nativeW: nativeW, evidence: evidence)),
            ("normal402", NativeOCRRepair402Normal.generate(actualOld: actualOld, basis: basis, nativeW: nativeW, evidence: evidence)),
            ("along402", NativeOCRRepair402Along.generate(actualOld: actualOld, basis: basis, nativeW: nativeW, evidence: evidence)),
            ("axis402", NativeOCRRepair402Axis.generate(actualOld: actualOld, basis: basis, nativeW: nativeW, evidence: evidence)),
            ("peer402", NativeOCRRepair402Peer.generate(actualOld: actualOld, basis: basis, nativeW: nativeW, evidence: evidence))
        ]
        var seen = Set<String>(), proposals: [K.Proposal] = [], invalid = 0, duplicate = 0, omitted = 0
        var receipts: [[String: Any]] = []
        let rounds = nodes.map { $0.1.proposals.count }.max() ?? 0
        // Round robin gives each independent common mechanism a bounded opportunity.
        // Exact cyclic/winding duplicate identity never changes any original vertex.
        for round in 0..<rounds {
            for (family, output) in nodes where output.proposals.indices.contains(round) {
                let offer = output.proposals[round], q = offer.polygon
                guard valid(q, rgba: evidence.rgba) else { invalid += 1; continue }
                let key = exactKey(q)
                guard seen.insert(key).inserted else { duplicate += 1; continue }
                guard proposals.count < maximumOffers else { omitted += 1; continue }
                var receipt = offer.receipt
                receipt["originalProducer"] = family
                receipt["sourceOnly"] = true
                receipt["actualCurrentPrior"] = actualOld.map { [Double($0.x), Double($0.y)] }
                receipt["nativeAdmissionSuiteRun"] = false
                receipt["admissionGranted"] = false
                receipt["ownershipChanged"] = false
                proposals.append(.init(suffix: family + "-" + offer.suffix, polygon: q, receipt: receipt,
                    obligations: offer.obligations + ["actual-native-admission-required", "source-geometry-is-not-ownership"]))
            }
        }
        for (name, output) in nodes {
            receipts.append(["family": name, "offered": output.proposals.count, "receipt": output.receipt])
        }
        return .init(proposals: proposals, receipt: ["family": "source-repair402", "sourceOnly": true,
            "actualCurrentPrior": actualOld.map { [Double($0.x), Double($0.y)] },
            "operatorReceipts": receipts, "proposalCount": proposals.count, "maximumOffers": maximumOffers,
            "exactGeometryDuplicates": duplicate, "invalidSourceGeometry": invalid, "budgetOmitted": omitted,
            "verticesSnappedOrAltered": false, "nativeAdmissionSuiteRun": false,
            "admissionGranted": false, "ownershipChanged": false, "GTRead": false,
            "seconds": Date().timeIntervalSince(started)])
    }
    private static func valid(_ q: [CGPoint], rgba: K.RGBA) -> Bool {
        guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
            $0.x >= rgba.origin.x && $0.y >= rgba.origin.y &&
            $0.x <= rgba.origin.x + CGFloat(rgba.width) && $0.y <= rgba.origin.y + CGFloat(rgba.height) }) else { return false }
        let turns = q.indices.map { i -> CGFloat in
            let a = q[i], b = q[(i + 1) % 4], c = q[(i + 2) % 4]
            return (b.x-a.x)*(c.y-b.y) - (b.y-a.y)*(c.x-b.x)
        }
        return turns.allSatisfy { $0 > 1e-8 } || turns.allSatisfy { $0 < -1e-8 }
    }
    private static func exactKey(_ q: [CGPoint]) -> String {
        let vertices = q.map { String(Double($0.x).bitPattern, radix: 16) + "," + String(Double($0.y).bitPattern, radix: 16) }
        var keys: [String] = []
        for sequence in [vertices, Array(vertices.reversed())] {
            for shift in 0..<4 { keys.append((0..<4).map { sequence[($0+shift)%4] }.joined(separator: ";")) }
        }
        return keys.min()!
    }
}
