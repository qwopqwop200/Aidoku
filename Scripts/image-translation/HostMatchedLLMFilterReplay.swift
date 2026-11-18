import Foundation

/// Explicit approximate reuse of EXISTING provider decisions. Never a fresh
/// provider inference or an exact HTTP-cache hit; never consults ground truth.
enum HostMatchedLLMFilterReplay {
    static let policyVersion = "same-image-one-to-one-or-filter-consensus-v2"
    struct Owner: Codable {
        let id: String
        let source: String
        /// Normalized [x,y,width,height], not a quad-equality requirement.
        let bounds: [Double]
        /// Content hashes of original accepted packets, not numeric indices.
        var memberSignatures: [String] = []
    }
    struct Candidate: Codable {
        let key: String
        let encodedImageSHA256: String
        let owner: Owner
        let keep: Bool
        let contentClass: String
        let translatedText: String?
        let provenance: [String: String]
    }
    struct Input: Codable {
        let encodedImageSHA256: String
        let owners: [Owner]
        let candidates: [Candidate]
    }
    struct Outcome: Encodable {
        let callerID: String
        let status: String
        let keep: Bool
        let contentClass: String?
        let confidence: Double?
        let matchedCandidateKey: String?
        let candidateKeys: [String]
        let approximateTargetForRenderQA: String?
        let provenance: [String: String]?
        let actualNewLLMInference: Bool = false
    }
    struct Result: Encodable {
        let policyVersion: String
        let outcomes: [Outcome]
        let providerCalls: Int = 0
        let semanticTranslationAccuracyProof: Bool = false
    }
    private struct Edge {
        let current: Int
        let old: Int
        let score: Double
    }
    static func normalizedText(_ text: String) -> [UInt32] {
        text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
            .filter { !CharacterSet.whitespacesAndNewlines.contains($0) && !CharacterSet.punctuationCharacters.contains($0) }
            .map(\.value)
    }
    static func textSimilarity(_ a: String, _ b: String) -> Double {
        let a = normalizedText(a), b = normalizedText(b)
        guard !a.isEmpty, !b.isEmpty, a.count <= 8192, b.count <= 8192 else { return 0 }
        if a == b { return 1 }
        var row = Array(0...b.count)
        for (i, ca) in a.enumerated() {
            var next = [i + 1] + Array(repeating: 0, count: b.count)
            for (j, cb) in b.enumerated() {
                next[j + 1] = min(next[j] + 1, row[j + 1] + 1, row[j] + (ca == cb ? 0 : 1))
            }
            row = next
        }
        return 1 - Double(row[b.count]) / Double(max(a.count, b.count))
    }
    static func overlap(_ a: [Double], _ b: [Double]) -> (iou: Double, containment: Double) {
        guard a.count == 4, b.count == 4, (a + b).allSatisfy(\.isFinite),
              a[2] > 0, a[3] > 0, b[2] > 0, b[3] > 0 else { return (0, 0) }
        let intersection = max(0, min(a[0] + a[2], b[0] + b[2]) - max(a[0], b[0]))
            * max(0, min(a[1] + a[3], b[1] + b[3]) - max(a[1], b[1]))
        let aa = a[2] * a[3], ba = b[2] * b[3]
        return (intersection / (aa + ba - intersection), intersection / min(aa, ba))
    }
    /// Union coverage, not summed overlap (duplicate old owners cannot inflate it).
    static func spatialCoverage(_ current: [Double], _ old: [[Double]]) -> Double {
        guard current.count == 4, current.allSatisfy(\.isFinite), current[2] > 0, current[3] > 0 else { return 0 }
        let clipped = old.compactMap { r -> [Double]? in
            guard r.count == 4, r.allSatisfy(\.isFinite), r[2] > 0, r[3] > 0 else { return nil }
            let x = max(current[0], r[0]), y = max(current[1], r[1])
            let right = min(current[0] + current[2], r[0] + r[2]), bottom = min(current[1] + current[3], r[1] + r[3])
            return right > x && bottom > y ? [x, y, right, bottom] : nil
        }
        let xs = Set(clipped.flatMap { [$0[0], $0[2]] }).sorted()
        guard xs.count >= 2 else { return 0 }
        var area = 0.0
        for index in 1..<xs.count {
            let left = xs[index - 1], right = xs[index]
            let intervals = clipped.filter { $0[0] < right && $0[2] > left }.map { ($0[1], $0[3]) }.sorted { $0.0 < $1.0 }
            var end = -Double.infinity, length = 0.0
            for (start, bottom) in intervals {
                length += max(0, bottom - max(start, end)); end = max(end, bottom)
            }
            area += (right - left) * length
        }
        return min(1, area / (current[2] * current[3]))
    }
    static func sourceCoverage(_ current: String, _ old: [String]) -> Double {
        let current = normalizedText(current)
        guard !current.isEmpty, current.count <= 8192 else { return 0 }
        var covered = Set<Int>()
        for source in old {
            let source = normalizedText(source)
            guard !source.isEmpty, source.count <= 8192 else { continue }
            if source.count >= current.count {
                if (0...(source.count - current.count)).contains(where: { Array(source[$0..<($0 + current.count)]) == current }) { return 1 }
            } else {
                for index in 0...(current.count - source.count) where Array(current[index..<(index + source.count)]) == source {
                    covered.formUnion(index..<(index + source.count))
                }
            }
        }
        return Double(covered.count) / Double(current.count)
    }
    static func replay(_ input: Input) -> Result {
        // Candidate keys identify deduplicated historical owners. Duplicate
        // keys or current IDs are an invalid contract, not silent fan-out.
        let validImage = input.encodedImageSHA256.count == 64
            && input.encodedImageSHA256.allSatisfy { $0.isHexDigit }
        let validIDs = Set(input.owners.map(\.id)).count == input.owners.count
            && Set(input.candidates.map(\.key)).count == input.candidates.count
        var edges: [Edge] = []
        var hazards = Set<Int>()
        var oldPotential: [Int: Set<Int>] = [:]
        var currentPotential: [Int: Set<Int>] = [:]
        if validImage && validIDs {
            for (i, current) in input.owners.enumerated() {
                for (j, candidate) in input.candidates.enumerated() where candidate.encodedImageSHA256 == input.encodedImageSHA256 {
                    let old = candidate.owner
                    let spatial = overlap(current.bounds, old.bounds)
                    let text = textSimilarity(current.source, old.source)
                    let a = Set(current.memberSignatures), b = Set(old.memberSignatures)
                    let lineage = a.isEmpty || b.isEmpty ? 0 : Double(a.intersection(b).count) / Double(a.union(b).count)
                    // Detect likely split/merge relationships before admitting
                    // edges. A fragment cannot inherit a parent's drop blindly.
                    let ca = String(String.UnicodeScalarView(normalizedText(current.source).compactMap(UnicodeScalar.init)))
                    let cb = String(String.UnicodeScalarView(normalizedText(old.source).compactMap(UnicodeScalar.init)))
                    let substring = !ca.isEmpty && !cb.isEmpty && (ca.contains(cb) || cb.contains(ca))
                    if spatial.containment >= 0.6 && (text >= 0.55 || substring || lineage >= 0.5) {
                        oldPotential[j, default: []].insert(i)
                        currentPotential[i, default: []].insert(j)
                    }
                    let eligible = (text >= 0.82 && spatial.iou >= 0.45)
                        || (lineage >= 0.8 && text >= 0.65 && spatial.iou >= 0.15)
                    if eligible {
                        // Keep even UNKNOWN/dissenting eligible candidates in
                        // consensus accounting; a lower score cannot hide them.
                        oldPotential[j, default: []].insert(i)
                        currentPotential[i, default: []].insert(j)
                    }
                    if eligible && ["dialogue", "narration", "story_text", "sfx", "background", "error"].contains(candidate.contentClass) {
                        edges.append(.init(current: i, old: j, score: 0.6 * text + 0.3 * spatial.iou + 0.1 * lineage))
                    }
                }
            }
        }
        for owners in oldPotential.values where owners.count > 1 { hazards.formUnion(owners) }
        for (i, owners) in currentPotential where owners.count > 1 { hazards.insert(i) }
        let byCurrent = Dictionary(grouping: edges, by: \.current)
        let byOld = Dictionary(grouping: edges, by: \.old)
        let outcomes = input.owners.enumerated().map { i, owner -> Outcome in
            let choices = (byCurrent[i] ?? []).sorted { $0.score > $1.score }
            var reason = validImage && validIDs ? "unknown_unmatched_failopen" : "unknown_invalid_contract_failopen"
            if hazards.contains(i) { reason = "unknown_split_merge_or_conflicting_history_failopen" }
            if !hazards.contains(i), let best = choices.first {
                let reverse = (byOld[best.old] ?? []).sorted { $0.score > $1.score }
                let margin = choices.count < 2 || best.score - choices[1].score >= 0.08
                let reverseMargin = reverse.count < 2 || best.score - reverse[1].score >= 0.08
                if reverse.first?.current == i && margin && reverseMargin {
                    let candidate = input.candidates[best.old]
                    return Outcome(callerID: owner.id, status: "matched_existing_LLM_filter_simulation",
                        keep: candidate.keep, contentClass: candidate.contentClass, confidence: best.score,
                        matchedCandidateKey: candidate.key, candidateKeys: choices.map { input.candidates[$0.old].key },
                        approximateTargetForRenderQA: candidate.translatedText, provenance: candidate.provenance)
                }
                reason = "unknown_ambiguous_one_to_one_failopen"
            }
            // A split/merge may reuse FILTER decisions only when every old
            // decision in its connected correspondence component agrees.
            // Targets never fan out or concatenate, even with unanimous roles.
            if validImage && validIDs, hazards.contains(i), let direct = currentPotential[i], !direct.isEmpty {
                var currents: Set<Int> = [i], old = Set<Int>(), changed = true
                while changed {
                    let oldCount = old.count, currentCount = currents.count
                    for c in currents { old.formUnion(currentPotential[c] ?? []) }
                    for o in old { currents.formUnion(oldPotential[o] ?? []) }
                    changed = old.count != oldCount || currents.count != currentCount
                }
                let candidates = old.sorted().map { input.candidates[$0] }
                let known = Set(["dialogue", "narration", "story_text", "sfx", "background", "error"])
                let decisions = Set(candidates.map(\.keep))
                let directCandidates = direct.sorted().map { input.candidates[$0] }
                let spatial = spatialCoverage(owner.bounds, directCandidates.map { $0.owner.bounds })
                let source = sourceCoverage(owner.source, directCandidates.map { $0.owner.source })
                if decisions.count == 1, candidates.allSatisfy({ known.contains($0.contentClass) }), spatial >= 0.65, source >= 0.8 {
                    let roles = Set(candidates.map(\.contentClass))
                    return Outcome(callerID: owner.id, status: "consensus_existing_LLM_filter_simulation",
                        keep: candidates[0].keep, contentClass: roles.count == 1 ? candidates[0].contentClass : nil,
                        confidence: min(source, spatial), matchedCandidateKey: nil, candidateKeys: candidates.map(\.key),
                        approximateTargetForRenderQA: nil,
                        provenance: ["kind": "existing-filter-only-connected-component-consensus", "translationReuse": "forbidden-for-consensus"])
                }
                reason = decisions.count > 1 ? "unknown_conflicting_filter_consensus_failopen" : "unknown_incomplete_filter_consensus_failopen"
            }
            return Outcome(callerID: owner.id, status: reason, keep: true, contentClass: nil,
                confidence: choices.first?.score, matchedCandidateKey: nil,
                candidateKeys: choices.map { input.candidates[$0.old].key },
                approximateTargetForRenderQA: nil, provenance: nil)
        }
        return Result(policyVersion: policyVersion, outcomes: outcomes)
    }
}
