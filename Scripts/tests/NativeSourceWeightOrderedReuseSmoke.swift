import Foundation

private typealias R = NativeSourceWeightOrderedObservationReuse

@main
private enum Smoke {
    static func main() throws {
        let request = UUID()
        func binding(requestID: UUID? = nil, owner: Int = 1, source: String = "source-a",
                     geometry: String = "bbox-only", prior: Double = 40, em: Double = 42,
                     angle: Double = 0.25) -> R.Binding {
            .init(requestID: requestID ?? request, ownerIndex: owner, sourceIdentity: source,
                  geometryMode: geometry, priorBits: prior.bitPattern, emBits: em.bitPattern,
                  angleBits: angle.bitPattern)
        }
        func bytes(_ row: [String: Any]) throws -> Data {
            try JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes])
        }
        func measured(_ em: Double, fixture: Int) -> [String: Any] {
            let vector: [Double] = [-0.0, .pi, .leastNormalMagnitude, em]
            switch fixture {
            case 0: return ["words": [["templateFit": 0.88, "orderedGlyphs": ["glyphs": [["templateFit": 0.9]]]]],
                            "sourceEM": em, "raw": vector, "available": true]
            case 1: return ["words": [[String: Any]](), "sourceEM": em, "raw": vector]
            case 2: return ["sourceEM": em, "raw": vector] // missing words stays missing
            default: return ["words": [["templateFit": NSNull()]], "sourceEM": em, "raw": vector]
            }
        }
        var checks = 0
        for fixture in 0..<4 {
            let nominal = measured(42, fixture: fixture)
            let stored = R.Recorded(binding: binding(), observation: nominal)
            var annotated = nominal
            annotated["expectedGlyphCounts"] = [1]
            annotated["outlineWitnessed"] = true
            precondition(stored.observation["expectedGlyphCounts"] == nil)
            var oldCalls = 1, newCalls = 1 // the existing ordered measurement
            for factor in [0.0, -0.5, 0.5, -1.0, 1.0] {
                let em = 42 + factor * 2
                let old = measured(em, fixture: fixture); oldCalls += 1
                let actual: [String: Any]
                if let reused = R.observation(stored, binding: binding(em: em), factor: factor, ordered: true) {
                    actual = reused
                } else { actual = measured(em, fixture: fixture); newCalls += 1 }
                let oldBytes = try bytes(old), newBytes = try bytes(actual)
                precondition(oldBytes == newBytes)
                let oldVector = old["raw"] as! [Double], newVector = actual["raw"] as! [Double]
                precondition(zip(oldVector, newVector).allSatisfy { $0.bitPattern == $1.bitPattern })
            }
            precondition(oldCalls == 6 && newCalls == 5)
            checks += 1
        }
        let stored = R.Recorded(binding: binding(), observation: measured(42, fixture: 0))
        let mismatches = [binding(requestID: UUID()), binding(owner: 2), binding(source: "source-b"),
                          binding(geometry: "original-members"), binding(prior: Double(40).nextUp),
                          binding(em: Double(42).nextUp), binding(angle: Double(0.25).nextUp)]
        for mismatch in mismatches {
            precondition(R.observation(stored, binding: mismatch, factor: 0, ordered: true) == nil)
            checks += 1
        }
        precondition(R.observation(stored, binding: binding(), factor: 0, ordered: false) == nil); checks += 1
        precondition(R.observation(stored, binding: binding(), factor: 0.5, ordered: true) == nil); checks += 1
        precondition(R.observation(nil, binding: binding(), factor: 0, ordered: true) == nil); checks += 1
        print("PASS nominal ordered reuse: \(checks) checks;20 old/new observations bit-exact;usable/empty/missing/unusable preserved;request/owner/source/member-vs-bbox/EM/prior/angle isolated")
    }
}
