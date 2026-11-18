import Foundation

/// Source-bound agreement features. The full reference bank must remain immutable
/// when emissions shrink. Producer families establish diversity, never ownership.
/// No RGB, absolute-shape classifier, source IDs, text content, GT, or file lookup.
enum NativeOCRLineAgreementFeatures {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias Rep = NativeOCRGeometryRepresentativeSelection
    typealias D = NativeOCRGeometryDeduplication

    static let names: [String] = [
        "bbox", "rfText", "rfSFX", "rfBalloon", "rfFrame", "detector", "observedRec", "quality",
        "consensusSecond", "consensusMean", "consensusCount80", "consensusCount90",
        "textTop25Mass", "textQ25", "textQ75", "sfxQ75", "balloonQ25"
    ]

    struct Result: Sendable {
        let rows: [[Double]]
        /// A false entry cannot authorize a caller to reject that input row.
        let available: [Bool]
    }

    private static func families(_ row: G.Individual) -> Set<String> {
        Set(row.provenance.map { record in
            let parts = record.alternativeID.split(separator: "/", omittingEmptySubsequences: false)
            if parts.first == "source-paint", parts.count > 3 { return String(parts[3]) }
            return parts.first.map(String.init) ?? ""
        })
    }

    private static func valid(_ shape: D.Shape) -> Bool {
        shape.convex && shape.area.isFinite && shape.area > 0
    }

    /// NumPy's default linear quantile: (count - 1) * q, with no rank rounding.
    private static func quantile(_ sorted: [Double], _ q: Double) -> Double {
        let position = Double(sorted.count - 1) * q
        let low = Int(floor(position)), high = Int(ceil(position))
        return sorted[low] + (sorted[high] - sorted[low]) * (position - Double(low))
    }

    /// Matches the RF semantic sampler's square quadrature and bilinear field
    /// interpolation. This samples already computed RF fields, not source RGB.
    private static func samples(_ polygon: [G.Point], grid: NativeRFDETRSemanticGrid, semantic: Int) -> [Double] {
        var result: [Double] = []
        result.reserveCapacity(256)
        let side = grid.side, base = semantic * side * side
        for y in 0..<16 { for x in 0..<16 {
            let u = (Double(x) + 0.5) / 16, v = (Double(y) + 0.5) / 16
            let weights = [(1 - u) * (1 - v), u * (1 - v), u * v, (1 - u) * v]
            let px = zip(polygon, weights).reduce(0.0) { $0 + $1.0.x * $1.1 }
            let py = zip(polygon, weights).reduce(0.0) { $0 + $1.0.y * $1.1 }
            let gx = min(Double(side - 1), max(0, px * Double(side) / Double(grid.width) - 0.5))
            let gy = min(Double(side - 1), max(0, py * Double(side) / Double(grid.height) - 0.5))
            let x0 = Int(gx), y0 = Int(gy), x1 = min(side - 1, x0 + 1), y1 = min(side - 1, y0 + 1)
            let dx = gx - Double(x0), dy = gy - Double(y0)
            func at(_ a: Int, _ b: Int) -> Double { Double(grid.probabilities[base + b * side + a]) }
            result.append((at(x0, y0) * (1 - dx) + at(x1, y0) * dx) * (1 - dy)
                + (at(x0, y1) * (1 - dx) + at(x1, y1) * dx) * dy)
        } }
        return result
    }

    static func extract(
        _ input: G.Output, referenceInventory: G.Output, context: Rep.Context,
        grid: NativeRFDETRSemanticGrid, frozenQualityScores: [Double?],
        cancellationCheck: () throws -> Void = {}
    ) throws -> Result {
        try cancellationCheck()
        let inputRows = input.individuals, references = referenceInventory.individuals
        var rows = Array(repeating: Array(repeating: 0.0, count: names.count), count: inputRows.count)
        var available = Array(repeating: false, count: inputRows.count)
        guard !inputRows.isEmpty else { return .init(rows: rows, available: available) }
        guard grid.isValid, frozenQualityScores.count == inputRows.count, !references.isEmpty else {
            return .init(rows: rows, available: available)
        }
        let referenceShapes = references.map { D.Shape($0.polygon) }
        guard referenceShapes.allSatisfy(valid) else { return .init(rows: rows, available: available) }
        let referenceFamilies = references.map(families)
        let allFamilies = Set(referenceFamilies.flatMap { $0 }).sorted()
        guard !allFamilies.isEmpty else { return .init(rows: rows, available: available) }
        let familyIndices = Dictionary(uniqueKeysWithValues: allFamilies.enumerated().map { ($1, $0) })
        let familySlots = referenceFamilies.map { $0.compactMap { familyIndices[$0] } }
        func observations(_ evidence: [Rep.Evidence]) -> [(D.Shape, Double)] {
            evidence.compactMap { item in
                let shape = D.Shape(item.polygon)
                guard valid(shape), item.confidence.isFinite, (0...1).contains(item.confidence) else { return nil }
                return (shape, item.confidence)
            }
        }
        let detectors = observations(context.detectors), recognition = observations(context.recognition)
        let contextAvailable = !detectors.isEmpty && recognition.contains { $0.1 > 0 }
            && detectors.count == context.detectors.count && recognition.count == context.recognition.count
        for i in inputRows.indices {
            try cancellationCheck()
            let row = inputRows[i], shape = D.Shape(row.polygon)
            guard valid(shape) else { continue }
            let bbox = row.bboxConfidence, quality = frozenQualityScores[i]
            var values = Array(repeating: 0.0, count: names.count)
            values[0] = bbox.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let means = NativeOCRRFSemanticAdmission.means(row.polygon, grid: grid)
            for semantic in 0..<4 { values[1 + semantic] = means[semantic] }
            for (slot, observed) in [(5, detectors), (6, recognition)] {
                values[slot] = observed.reduce(0) { max($0, D.intersectionIoU(shape, $1.0, minimum: 0) * $1.1) }
            }
            values[7] = quality.flatMap { $0.isFinite ? $0 : nil } ?? 0
            let own = families(row)
            var votes = Array(repeating: 0.0, count: allFamilies.count)
            for j in references.indices {
                if j % 256 == 0 { try cancellationCheck() }
                let overlap = D.intersectionIoU(shape, referenceShapes[j], minimum: 0)
                for slot in familySlots[j] where !own.contains(allFamilies[slot]) { votes[slot] = max(votes[slot], overlap) }
            }
            let ranked = votes.sorted(by: >)
            values[8] = ranked.count >= 2 ? ranked[1] : 0
            // Own-family zeros remain in the denominator, exactly as Python X.
            values[9] = votes.reduce(0, +) / Double(votes.count)
            values[10] = Double(votes.filter { $0 >= 0.8 }.count)
            values[11] = Double(votes.filter { $0 >= 0.9 }.count)
            let text = samples(row.polygon, grid: grid, semantic: 0).sorted()
            let sfx = samples(row.polygon, grid: grid, semantic: 1).sorted()
            let balloon = samples(row.polygon, grid: grid, semantic: 2).sorted()
            values[12] = text.suffix(64).reduce(0, +) / max(text.reduce(0, +), 1e-12)
            values[13] = quantile(text, 0.25)
            values[14] = quantile(text, 0.75)
            values[15] = quantile(sfx, 0.75)
            values[16] = quantile(balloon, 0.25)
            rows[i] = values
            available[i] = contextAvailable && !row.provenance.isEmpty && values.allSatisfy(\.isFinite)
                && bbox.map { $0.isFinite && (0...1).contains($0) } == true && quality?.isFinite == true
        }
        return .init(rows: rows, available: available)
    }
}
