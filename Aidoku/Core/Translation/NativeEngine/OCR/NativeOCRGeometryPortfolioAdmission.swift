import Foundation

/// A direct polygon cover before representative election. The caller must retain
/// the full input as representative referenceInventory. This saves candidate
/// processing, not detector inference or physical geometry measurement.
enum NativeOCRGeometryPortfolioAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias D = NativeOCRGeometryDeduplication

    /// Same-frame detector and observed recognition overlap agreement.
    /// These values do not imply text ownership or fresh candidate recognition.
    struct Evidence: Sendable {
        let detectorAgreement: Double
        let recognitionAgreement: Double
    }
    struct Configuration: Codable, Equatable, Sendable {
        var baseOverlap = 0.9
        var protectionOverlap = 0.9
        var evidenceTolerance = 0.0
    }
    struct Replacement: Codable, Equatable, Sendable {
        let inputIndex: Int
        let representativeIndex: Int
        let polygonIoU: Double
        let requiredOverlap: Double
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        let keptIndices: [Int]
        let referenceInventoryCount: Int
        let configuration: Configuration
        let replacements: [Replacement]
        let missingEvidenceKeptIndices: [Int]
    }
    struct Result: Sendable {
        let output: G.Output
        let report: Report
        var keptIndices: [Int] { report.keptIndices }
    }
    enum Failure: Error { case invalidConfiguration }

    static let environmentKey = "AIDOKU_OCR_GEOMETRY_PORTFOLIO_POLICY"

    /// Default off. The immutable bank must also be passed to the subsequent
    /// representative election; this helper never substitutes a reduced bank.
    static func configured(_ input: G.Output, referenceInventory: G.Output,
                           context: NativeOCRGeometryRepresentativeSelection.Context,
                           environment: [String: String] = ProcessInfo.processInfo.environment) throws -> Result? {
        guard let path = environment[environmentKey], !path.isEmpty else { return nil }
        let configuration = try JSONDecoder().decode(Configuration.self,
            from: Data(contentsOf: URL(fileURLWithPath: path)))
        return try apply(input, referenceInventory: referenceInventory, context: context, configuration: configuration)
    }

    static func apply(_ input: G.Output, referenceInventory: G.Output,
                      context: NativeOCRGeometryRepresentativeSelection.Context,
                      configuration: Configuration = .init()) throws -> Result {
        // The full bank is intentionally not mutated or returned as compact evidence.
        // A missing measurement abstains instead of manufacturing a zero score.
        guard !referenceInventory.individuals.isEmpty, !context.detectors.isEmpty, !context.recognition.isEmpty else {
            return try apply(input, evidence: Array(repeating: nil, count: input.individuals.count),
                configuration: configuration, referenceInventoryCount: referenceInventory.individuals.count)
        }
        let detectors = context.detectors.map { D.Shape($0.polygon) }
        let recognition = context.recognition.map { D.Shape($0.polygon) }
        let measured: [Evidence?] = input.individuals.map { row in
            guard row.bboxConfidence != nil,
                  context.detectors.allSatisfy({ $0.confidence.isFinite && $0.confidence >= 0 && $0.confidence <= 1 }),
                  context.recognition.allSatisfy({ $0.confidence.isFinite && $0.confidence >= 0 && $0.confidence <= 1 }) else { return nil }
            let shape = D.Shape(row.polygon)
            var detector = 0.0, observed = 0.0
            for j in detectors.indices {
                detector = max(detector, D.intersectionIoU(shape, detectors[j], minimum: 0) * context.detectors[j].confidence)
            }
            for j in recognition.indices {
                observed = max(observed, D.intersectionIoU(shape, recognition[j], minimum: 0) * context.recognition[j].confidence)
            }
            return .init(detectorAgreement: detector, recognitionAgreement: observed)
        }
        return try apply(input, evidence: measured, configuration: configuration,
            referenceInventoryCount: referenceInventory.individuals.count)
    }

    static func apply(_ input: G.Output, evidence: [Evidence?],
                      configuration c: Configuration = .init(), referenceInventoryCount: Int? = nil) throws -> Result {
        guard [c.baseOverlap, c.protectionOverlap].allSatisfy({ $0.isFinite && $0 > 0 && $0 <= 1 }),
              c.evidenceTolerance.isFinite, c.evidenceTolerance >= 0,
              evidence.count == input.individuals.count else { throw Failure.invalidConfiguration }
        let rows = input.individuals, n = rows.count
        if n == 0 { return .init(output: input, report: .init(inputCount: 0, keptIndices: [],
            referenceInventoryCount: referenceInventoryCount ?? 0, configuration: c,
            replacements: [], missingEvidenceKeptIndices: [])) }
        let shapes = rows.map { D.Shape($0.polygon) }
        // Explicit immutable members only. Parent and source indices do not
        // certify ownership. Unknown lineage makes no positive ownership claim.
        let members = rows.map { Set($0.provenance.flatMap(\.sourceMembers)) }
        let families = rows.map { row in
            Set(row.provenance.map { record -> String in
                let parts = record.alternativeID.split(separator: "/")
                if parts.first == "source-paint", parts.count > 3 { return String(parts[3]) }
                return parts.first.map(String.init) ?? ""
            })
        }
        let names = Set(families.flatMap { $0 }).sorted()
        var overlap = Array(repeating: Array(repeating: 0.0, count: n), count: n)
        for i in 0..<n {
            for j in i..<n where members[i].isEmpty || members[j].isEmpty || members[i] == members[j] {
                let value = D.intersectionIoU(shapes[i], shapes[j], minimum: 0)
                overlap[i][j] = value; overlap[j][i] = value
            }
        }
        var consensus = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            var total = 0.0, count = 0
            for name in names {
                var vote = 0.0
                for j in 0..<n where families[j].contains(name) { vote = max(vote, overlap[i][j]) }
                total += pow(vote, 4)
                if vote > 0.3 { count += 1 }
            }
            consensus[i] = min(1, total / Double(max(1, count)))
        }
        func valid(_ index: Int) -> Bool {
            guard let e = evidence[index], let bbox = rows[index].bboxConfidence else { return false }
            return [bbox, e.detectorAgreement, e.recognitionAgreement].allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 1 }
        }
        let eligible = (0..<n).map(valid)
        var radius = Array(repeating: 2.0, count: n)
        var quality = Array(repeating: 0.0, count: n)
        for i in 0..<n {
            guard eligible[i], let e = evidence[i], let bbox = rows[i].bboxConfidence else { continue }
            var protected = false
            for value in [e.detectorAgreement, e.recognitionAgreement].indices {
                let own = value == 0 ? e.detectorAgreement : e.recognitionAgreement
                guard own > 0.3 else { continue }
                let better = (0..<n).contains { j in
                    guard eligible[j], overlap[i][j] >= c.protectionOverlap, let other = evidence[j] else { return false }
                    let score = value == 0 ? other.detectorAgreement : other.recognitionAgreement
                    return score > own + c.evidenceTolerance
                }
                if !better { protected = true }
            }
            // Weak observed agreement cannot justify compressing the boundary
            // alternatives that the later frozen election uses as competitors.
            // Preserve those alternatives as well as the independent source
            // terminal/paint observations; neither condition asserts ownership.
            if e.detectorAgreement < 0.5 || e.recognitionAgreement < 0.8 {
                radius[i] = 2
                continue
            }
            let uncertainty = 0.01 * (1 - e.recognitionAgreement) + 0.01 * (1 - consensus[i])

            radius[i] = c.baseOverlap + uncertainty
            if protected { radius[i] = max(radius[i], 0.955) }
            // Keep independent observed and model-generated anchor boundaries.
            if families[i].contains(where: { $0 == "original" || $0 == "corrected" || $0.hasPrefix("learned-boundary")
                || $0 == "source-chromatic-paint" || $0 == "owned-outlined-fill-endpoint-completion-v1" }) {
                radius[i] = 2
            }
            quality[i] = 0.45 * consensus[i] + 0.2 * bbox + 0.15 * e.detectorAgreement
                + 0.15 * e.recognitionAgreement
        }
        var cover = Array(repeating: [Int](), count: n)
        var reverse = Array(repeating: [Int](), count: n)
        for i in 0..<n {
            for j in 0..<n where i == j || (eligible[i] && eligible[j] && overlap[i][j] >= radius[j]) {
                cover[i].append(j); reverse[j].append(i)
            }
        }
        var alive = Array(repeating: true, count: n), gain = cover.map(\.count)
        var kept = [Int](), remaining = n
        var replacements = [Replacement]()
        while remaining > 0 {
            var winner = -1, best = -Double.infinity
            for i in 0..<n where alive[i] {
                let rank = Double(gain[i]) + 0.25 * quality[i]
                if rank > best { best = rank; winner = i }
            }
            kept.append(winner)
            for j in cover[winner] where alive[j] {
                if j != winner {
                    replacements.append(.init(inputIndex: j, representativeIndex: winner,
                        polygonIoU: overlap[winner][j], requiredOverlap: radius[j]))
                }
                alive[j] = false; remaining -= 1
                for i in reverse[j] { gain[i] -= 1 }
            }
        }
        kept.sort()
        return .init(output: G.selecting(input, indices: kept), report: .init(inputCount: n,
            keptIndices: kept, referenceInventoryCount: referenceInventoryCount ?? n, configuration: c,
            replacements: replacements.sorted { $0.inputIndex < $1.inputIndex },
            missingEvidenceKeptIndices: (0..<n).filter { !eligible[$0] }))
    }
}
