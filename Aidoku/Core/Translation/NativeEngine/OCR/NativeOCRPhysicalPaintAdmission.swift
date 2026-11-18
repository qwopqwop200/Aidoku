import Foundation

/// Terminal physical paint admission. Terminal, immutable-row selection only.
/// Runtime inputs are the current invocation's original CCs/paint observations,
/// RF all300 grid, raw RF primitives and exactly aligned frozen election scores.
/// It never loads a page/catalog, infers source ancestry or changes provenance.
@available(iOS 18.0, *)
enum NativeOCRPhysicalPaintAdmission {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias P = NativeOCRPhysicalPaintSupport
    typealias D = NativeOCRGeometryDeduplication
    static let environmentKey = "AIDOKU_OCR_PHYSICAL_PAINT_ADMISSION"

    struct Replacement: Codable, Equatable, Sendable {
        let inputIndex: Int
        let retainedWitnessIndex: Int
        let directPolygonIoU: Double
        let exactCCCellCover: Bool
        let outerStrokePreserved: Bool
    }
    struct Report: Codable, Equatable, Sendable {
        let inputCount: Int
        let referenceInventoryCount: Int
        let keptIndices: [Int]
        let replacements: [Replacement]
        let missingEvidenceKeptIndices: [Int]
        let minimumDirectPolygonIoU: Double
        let sourceFrameIdentity: String?
        var policy: String? = nil
        var sharedLine: NativeOCRSharedLineElection.Report? = nil
    }
    struct Result: Sendable {
        let output: G.Output
        let report: Report
    }
    private struct RunKey: Hashable {
        let x: Int
        let y: Int
        let count: Int
    }
    private struct ComponentKey: Hashable {
        let mapWidth: Int
        let mapHeight: Int
        let width: Int
        let height: Int
        let runs: [RunKey]
    }
    private struct MeasurementRole {
        var physical = false
        var halo = false
        var complete = false
    }

    private static func key(_ q: [G.Point]) -> [G.Point] {
        guard q.count == 4 else { return q }
        var best = q
        for winding in [q, Array(q.reversed())] {
            for start in 0..<4 {
                let candidate = Array(winding[start...]) + Array(winding[..<start])
                for i in 0..<4 where candidate[i] != best[i] {
                    if candidate[i].x < best[i].x || (candidate[i].x == best[i].x && candidate[i].y < best[i].y) {
                        best = candidate
                    }
                    break
                }
            }
        }
        return best
    }

    /// Call after RF semantic/final-cover/joint admission, with qualities mapped
    /// through that result's keptIndices. The original bbox-admitted reference
    /// bank stays alive and is NEVER replaced by this output.
    static func apply(
        _ input: G.Output, referenceInventory: G.Output?,
        originals: [NativeOCRSourceOwnedRailPartition.Original],
        paint: NativeOCRSourcePaintGeometry.Report?,
        primitives: [NativeOCRSourceContext50V2.Primitive],
        grid: NativeRFDETRSemanticGrid?,
        context: NativeOCRGeometryRepresentativeSelection.Context,
        frozenQualityScores: [Double?]?,
        boundaryModes: Bool = false,
        sharedLinePolicy: NativeOCRSharedLineElection.Policy? = nil,
        cancellationCheck: () throws -> Void = {}
    ) throws -> Result {
        try cancellationCheck()
        let rows = input.individuals
        func unchanged() -> Result {
            .init(
                output: input,
                report: .init(
                    inputCount: rows.count,
                    referenceInventoryCount: referenceInventory?.individuals.count ?? 0,
                    keptIndices: Array(rows.indices), replacements: [],
                    missingEvidenceKeptIndices: Array(rows.indices),
                    minimumDirectPolygonIoU: sharedLinePolicy != nil ? 0.5 : boundaryModes ? 0 : 0.85,
                    sourceFrameIdentity: paint?.sourceFrameIdentity,
                    policy: sharedLinePolicy != nil ? "shared-line-evidence" : boundaryModes ? "measured-boundary-modes" : "direct-cc-cover"))
        }
        guard let referenceInventory, let grid, grid.isValid,
            referenceInventory.individuals.count >= rows.count,
            let paint, paint.enabled, paint.sourceFrameEvidenceValid,
            paint.sourceFrameIdentity != nil,
            frozenQualityScores?.count == rows.count
        else { return unchanged() }
        var components: [P.Component] = []
        var componentIDs: [ComponentKey: Int] = [:]
        for original in originals {
            try cancellationCheck()
            guard let seed = original.detectorSeedEvidence, seed.isValid, seed.completeCCScan == true,
                seed.sourceWidth == grid.width, seed.sourceHeight == grid.height
            else { continue }
            for component in seed.components {
                let token = ComponentKey(
                    mapWidth: seed.mapFullWidth, mapHeight: seed.mapFullHeight,
                    width: seed.sourceWidth, height: seed.sourceHeight,
                    runs: component.runs.map { .init(x: $0.x, y: $0.y, count: $0.count) })
                guard componentIDs[token] == nil else { continue }
                let id = components.count
                componentIDs[token] = id
                components.append(
                    .init(
                        token: String(id), mapWidth: seed.mapFullWidth, mapHeight: seed.mapFullHeight,
                        sourceWidth: seed.sourceWidth, sourceHeight: seed.sourceHeight,
                        runs: component.runs.map { .init(x: $0.x, y: $0.y, count: $0.count) }))
            }
        }
        guard !components.isEmpty else { return unchanged() }
        var roles: [[G.Point]: MeasurementRole] = [:]
        for observation in paint.observations {
            try cancellationCheck()
            let measurement = observation.measurement
            guard measurement.polygon.count == 4,
                measurement.polygon.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) })
            else { continue }
            let k = key(measurement.polygon.map { .init(x: $0[0], y: $0[1]) })
            var role = roles[k] ?? .init()
            role.physical = true
            // Measured outer-shell uncertainty is geometric evidence, not a
            // source RGB feature or source/query ancestry assertion.
            let layer = measurement.layer.lowercased()
            role.halo =
                role.halo || ["rim", "halo", "stroke-uncertainty", "white-shell"].contains(where: layer.contains)
                || (measurement.diagnostics["measuredRimRadius"] ?? 0) > 0
            role.complete = role.complete || measurement.terminalEvidence == .completeSourceInk
            roles[k] = role
        }
        func agreement(_ q: [G.Point], _ evidence: [NativeOCRGeometryRepresentativeSelection.Evidence]) -> Double? {
            let valid = evidence.filter { $0.confidence.isFinite && (0...1).contains($0.confidence) }
            guard !valid.isEmpty else { return nil }
            return valid.reduce(0) { max($0, D.polygonIoU(q, $1.polygon) * $1.confidence) }
        }
        var candidates: [P.Candidate] = []
        for i in rows.indices {
            try cancellationCheck()
            let row = rows[i]
            let role = roles[key(row.polygon)] ?? .init()
            candidates.append(
                .init(
                    polygon: row.polygon.map { .init(x: $0.x, y: $0.y) },
                    quality: frozenQualityScores![i], bboxConfidence: row.bboxConfidence,
                    detector: agreement(row.polygon, context.detectors), recognition: agreement(row.polygon, context.recognition),
                    rfText: NativeOCRRFSemanticAdmission.means(row.polygon, grid: grid)[0],
                    physical: role.physical, halo: role.halo, completeInk: role.complete,
                    family: row.provenance.first?.alternativeID ?? ""))
        }
        let primitives = primitives.map { p in
            P.RF(
                canonicalClass: p.canonicalClass, confidence: p.confidence,
                polygon: p.polygon.map { .init(x: $0[0], y: $0[1]) })
        }
        let snapshot = P.Input(
            sourceSHA256: grid.imageIdentity ?? paint.sourceFrameIdentity!,
            fullReferenceSHA256: "live-immutable-reference-inventory",
            fullReferenceCount: referenceInventory.individuals.count,
            components: components, rf: primitives, rfAllQueries: 300,
            candidates: candidates, finalIndices: Array(rows.indices), admittedIndices: [], selectedIndices: [])
        let bank = P.Bank(snapshot)
        try cancellationCheck()
        if let sharedLinePolicy {
            let features = try NativeOCRLineAgreementFeatures.extract(input, referenceInventory: referenceInventory,
                context: context, grid: grid, frozenQualityScores: frozenQualityScores!, cancellationCheck: cancellationCheck)
            func observed(_ rows: [NativeOCRGeometryRepresentativeSelection.Evidence]) -> [NativeOCRSharedLineElection.Observation] {
                rows.map { .init(polygon: $0.polygon.map { .init(x: $0.x, y: $0.y) }, confidence: $0.confidence) }
            }
            let election = try NativeOCRSharedLineElection.select(bank: bank, features: features.rows, available: features.available,
                detectors: observed(context.detectors), recognition: observed(context.recognition), policy: sharedLinePolicy,
                cancellationCheck: cancellationCheck)
            return .init(output: G.selecting(input, indices: election.keptIndices), report: .init(inputCount: rows.count,
                referenceInventoryCount: referenceInventory.individuals.count, keptIndices: election.keptIndices,
                replacements: [], missingEvidenceKeptIndices: election.report.missingEvidenceKeptIndices,
                minimumDirectPolygonIoU: 0.5, sourceFrameIdentity: paint.sourceFrameIdentity,
                policy: "shared-line-evidence", sharedLine: election.report))
        }
        let selected: P.Output
        if boundaryModes {
            let roles = NativeOCRPhysicalBoundaryModePolicy.roles(candidates: candidates, measurements: paint.observations.map(\.measurement))
            selected = NativeOCRPhysicalBoundaryModePolicy.select(bank: bank, roles: roles)
        } else {
            selected = bank.select(indices: Array(rows.indices), minimumDirectOverlap: 0.85)
        }
        let replacements = selected.replacements.map { item in
            Replacement(
                inputIndex: item.inputIndex, retainedWitnessIndex: item.witnessIndex,
                directPolygonIoU: D.polygonIoU(rows[item.inputIndex].polygon, rows[item.witnessIndex].polygon),
                exactCCCellCover: item.exactCCCellCover, outerStrokePreserved: item.haloPreserved)
        }
        return .init(
            output: G.selecting(input, indices: selected.kept),
            report: .init(
                inputCount: rows.count,
                referenceInventoryCount: referenceInventory.individuals.count, keptIndices: selected.kept,
                replacements: replacements, missingEvidenceKeptIndices: selected.missingEvidence,
                minimumDirectPolygonIoU: boundaryModes ? 0 : 0.85, sourceFrameIdentity: paint.sourceFrameIdentity,
                policy: boundaryModes ? "measured-boundary-modes" : "direct-cc-cover"))
    }
}
