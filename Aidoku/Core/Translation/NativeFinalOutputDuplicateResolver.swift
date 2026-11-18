import Foundation

/// Final-owner deduplication. Every removed owner's original source packet must
/// have an independent physical witness in a surviving owner's ORIGINAL packets.
/// Absorbed aliases never become new witnesses; cycles and unknown inputs abstain.
enum NativeFinalOutputDuplicateResolver {
    static let policyVersion = "final-owner-complement-packet-witness-v8"
    typealias F = NativeOCRPremergeCandidateFeatures
    /// Only reject separated envelopes. Touching or overlapping polygons still
    /// use the directed clipping calculation for the exact witness metrics.
    struct Bounds {
        var left = Double.infinity, right = -Double.infinity
        var top = Double.infinity, bottom = -Double.infinity

        init(_ polygon: [F.Point]) {
            for point in polygon {
                left = min(left, point.x)
                right = max(right, point.x)
                top = min(top, point.y)
                bottom = max(bottom, point.y)
            }
        }

        func mayOverlap(_ other: Self) -> Bool {
            left <= other.right && other.left <= right && top <= other.bottom && other.top <= bottom
        }
    }
    static func textKey(_ text: String) -> String {
        text.precomposedStringWithCompatibilityMapping.lowercased().filter { !$0.isWhitespace }
    }

    struct Observation: Codable, Sendable {
        let polygon: [F.Point]
        let confidence: Double
        let body: [Int]
        let readings: [Int]
        let table: Int
        let eligible: Bool
        var nonVotingSourcePackets: [Int]? = nil
        var isLegacyComplement: Bool? = nil
    }
    struct Configuration: Codable, Sendable {
        var packetIoU: Double = 0.6
        var packetContainment: Double = 0.9
        var outputContainment: Double = 0.9
        var requireSourceAgreement: Bool? = true
        var equivalentOwnerIoU: Double? = 0.75
        var equivalentPacketContainment: Double? = 0.95
        var strongPacketIoU: Double? = 0.8
        var strongPacketContainment: Double? = 0.8
        var isValid: Bool {
            let extra = [equivalentOwnerIoU, equivalentPacketContainment, strongPacketIoU,
                strongPacketContainment]
            return [packetIoU, packetContainment, outputContainment].allSatisfy { $0.isFinite && (0.5...1).contains($0) } &&
                extra.compactMap { $0 }.allSatisfy { $0.isFinite && (0.5...1).contains($0) } &&
                ((equivalentOwnerIoU == nil) == (equivalentPacketContainment == nil)) &&
                ((strongPacketIoU == nil) == (strongPacketContainment == nil))
        }
    }
    struct Alias: Codable, Sendable {
        let anchor: Int
        let removed: Int
        let anchorOriginalBody: [Int]
        let anchorOriginalReadings: [Int]
        let removedOriginalBody: [Int]
        let removedOriginalReadings: [Int]
        let outputIoU: Double
        let outputContainment: Double
        var reason: String? = nil
    }
    struct Result: Sendable {
        let keep: [Bool]
        let aliases: [Alias]
    }
    @TaskLocal static var observer: (@Sendable (Result) -> Void)?
    @TaskLocal static var complementObserver: (@Sendable (Result) -> Void)?

    struct SimpleConfiguration: Codable, Sendable {
        var outputIoU: Double = 0.85
        var packetIoU: Double = 0.85
        var requireOriginalWitness: Bool = true
    }

    /// A common-path NMS baseline. Every comparison uses the original owner
    /// footprints; aliases remain erasure ancestry and never acquire votes.
    /// Layout-bearing legacy inputs retain the selector below in applying().
    static func selectOriginalWitness(_ observations: [Observation], sourceTables: [Int: [[F.Point]]],
                                      configuration: SimpleConfiguration = .init()) -> Result {
        var keep = Array(repeating: true, count: observations.count), aliases: [Alias] = []
        guard observations.count <= 512, sourceTables.count <= 64,
              sourceTables.values.allSatisfy({ $0.count <= 4096 }),
              [configuration.outputIoU, configuration.packetIoU].allSatisfy({ $0.isFinite && (0.5...1).contains($0) })
        else { return .init(keep: keep, aliases: []) }
        let originals = observations.map { Set($0.body).union($0.readings) }
        let footprints = observations.enumerated().map { originals[$0.offset].subtracting($0.element.nonVotingSourcePackets ?? []) }
        let order = observations.indices.filter { i in
            let value = observations[i]
            return value.eligible && value.confidence.isFinite && (0...1).contains(value.confidence) &&
                !footprints[i].isEmpty && sourceTables[value.table].map { table in
                    originals[i].union(value.nonVotingSourcePackets ?? []).allSatisfy { table.indices.contains($0) }
                } == true
        }.sorted { a, b in
            let aLegacy = observations[a].isLegacyComplement == true, bLegacy = observations[b].isLegacyComplement == true
            if aLegacy != bLegacy { return !aLegacy }
            return observations[a].confidence == observations[b].confidence ? a < b : observations[a].confidence > observations[b].confidence
        }
        let bounds = observations.map { Bounds($0.polygon) }
        for (position, anchor) in order.enumerated() where keep[anchor] {
            let parent = observations[anchor]
            guard let table = sourceTables[parent.table] else { continue }
            for child in order.dropFirst(position + 1) where keep[child] && observations[child].table == parent.table {
                guard bounds[child].mayOverlap(bounds[anchor]),
                      let overlap = F.polygonOverlap(observations[child].polygon, parent.polygon),
                      overlap.iou >= configuration.outputIoU else { continue }
                if configuration.requireOriginalWitness {
                    guard footprints[child].allSatisfy({ packet in
                        footprints[anchor].contains { original in
                            F.polygonOverlap(table[packet], table[original]).map { $0.iou >= configuration.packetIoU } == true
                        }
                    }) else { continue }
                }
                keep[child] = false
                aliases.append(.init(anchor: anchor, removed: child,
                    anchorOriginalBody: parent.body, anchorOriginalReadings: parent.readings,
                    removedOriginalBody: observations[child].body, removedOriginalReadings: observations[child].readings,
                    outputIoU: overlap.iou, outputContainment: overlap.firstCoverage,
                    reason: configuration.requireOriginalWitness ? "single-original-packet-nms" : "output-polygon-nms"))
            }
        }
        let result = Result(keep: keep, aliases: aliases)
        observer?(result)
        return result
    }

    /// Original detections originate in float32 coordinates. Round overlap
    /// evidence to a fixed millionth before ordering so equivalent cyclic vertex
    /// layouts cannot reverse an owner on floating-point cancellation noise.
    static func agreementSupports(parent: Double, child: Double) -> Bool {
        guard parent.isFinite, child.isFinite, (0...1).contains(parent), (0...1).contains(child) else { return false }
        return floor(parent * 1_000_000 + 0.5) >= floor(child * 1_000_000 + 0.5)
    }

    static func select(_ observations: [Observation], sourceTables: [Int: [[F.Point]]],
                       sourceAgreement: [Int: [Double]] = [:], configuration: Configuration = .init()) -> Result {
        let n = observations.count
        var keep = Array(repeating: true, count: n), aliases: [Alias] = []
        guard n <= 512, configuration.isValid, sourceTables.count <= 64,
              sourceTables.values.allSatisfy({ $0.count <= 4096 }) else { return Result(keep: keep, aliases: []) }
        let originalFootprints = observations.map { Set($0.body).union($0.readings) }
        let bodySets = observations.map { Set($0.body).subtracting($0.nonVotingSourcePackets ?? []) }
        let readingSets = observations.map { Set($0.readings).subtracting($0.nonVotingSourcePackets ?? []) }
        let footprints = observations.indices.map { bodySets[$0].union(readingSets[$0]).sorted() }
        // Several output hypotheses can reference the same immutable source
        // packets. Cache directed measurements, including invalid polygons;
        // transferred aliases never enter this table or become new witnesses.
        typealias Overlap = (iou: Double, firstCoverage: Double, secondCoverage: Double)
        var packetOverlaps: [Int: [Int: Overlap?]] = [:]
        var cachedPacketCount = 0
        func packetOverlap(_ tableID: Int, _ child: Int, _ parent: Int) -> Overlap? {
            guard let table = sourceTables[tableID] else { return nil }
            let key = child * table.count + parent
            if let cached = packetOverlaps[tableID]?[key] { return cached }
            let measured = F.polygonOverlap(table[child], table[parent])
            if cachedPacketCount < 65_536 {
                packetOverlaps[tableID, default: [:]][key] = .some(measured)
                cachedPacketCount += 1
            }
            return measured
        }
        let eligible = observations.enumerated().map { index, value in
            let agreementValid: Bool
            if configuration.requireSourceAgreement == true {
                agreementValid = sourceAgreement[value.table].map { scores in
                    footprints[index].allSatisfy { scores.indices.contains($0) && scores[$0].isFinite && (0...1).contains(scores[$0]) }
                } ?? false
            } else { agreementValid = true }
            return agreementValid && value.eligible && value.confidence.isFinite && (0...1).contains(value.confidence) &&
            !footprints[index].isEmpty && sourceTables[value.table].map { table in
                originalFootprints[index].union(value.nonVotingSourcePackets ?? []).allSatisfy { table.indices.contains($0) }
            } == true && F.polygonOverlap(value.polygon, value.polygon) != nil
        }
        let bounds = observations.map { Bounds($0.polygon) }
        var covers = Array(repeating: Array(repeating: false, count: n), count: n)
        var pending = Set<Int>()
        var measurements: [Int: (Double, Double)] = [:]
        var reasons: [Int: String] = [:]
        for parent in 0..<n where eligible[parent] {
            for child in 0..<n where child != parent && eligible[child] && observations[parent].table == observations[child].table {
                if observations[parent].isLegacyComplement == true && observations[child].isLegacyComplement != true { continue }
                guard bounds[child].mayOverlap(bounds[parent]),
                      let overlap = F.polygonOverlap(observations[child].polygon, observations[parent].polygon),
                      overlap.iou > 0 else { continue }
                let normalGate = overlap.firstCoverage >= configuration.outputContainment
                let equivalentGate = configuration.equivalentOwnerIoU.map { overlap.iou >= $0 } == true &&
                    configuration.equivalentPacketContainment.map { max(overlap.firstCoverage, overlap.secondCoverage) >= $0 } == true
                guard normalGate || equivalentGate else { continue }
                let childPackets = footprints[child], parentPackets = footprints[parent]
                let pairs = childPackets.map { packet in
                    parentPackets.map { witness in packetOverlap(observations[parent].table, packet, witness) }
                }
                // An output envelope can contain a distinct original source.
                // Neither union containment nor transferred aliases establish
                // that its independently observed polygon is interchangeable.
                // Apply this to every removal path before source agreement/rank.
                guard pairs.allSatisfy({ row in
                    row.contains { $0.map { $0.iou >= 0.85 } == true }
                }) else { continue }
                func allWitnessed(iou: Double?, containment: Double, smallerArea: Bool, agreement: Bool) -> Bool {
                    for (ci, packet) in childPackets.enumerated() {
                        let found = parentPackets.enumerated().contains { pi, witness in
                            guard let measured = pairs[ci][pi] else { return false }
                            if let iou, measured.iou < iou { return false }
                            let coverage = smallerArea ? max(measured.firstCoverage, measured.secondCoverage) : measured.firstCoverage
                            if coverage < containment { return false }
                            if agreement {
                                guard let scores = sourceAgreement[observations[parent].table],
                                      scores.indices.contains(witness), scores.indices.contains(packet),
                                      scores[witness].isFinite, scores[packet].isFinite,
                                      agreementSupports(parent: scores[witness], child: scores[packet]) else { return false }
                            }
                            return true
                        }
                        if !found { return false }
                    }
                    return true
                }
                var reason: String?
                if normalGate && allWitnessed(iou: configuration.packetIoU, containment: configuration.packetContainment,
                    smallerArea: false, agreement: configuration.requireSourceAgreement == true) { reason = "original-packet-witness" }
                if reason == nil, equivalentGate, let containment = configuration.equivalentPacketContainment {
                    let strictEvidence = max(overlap.firstCoverage, overlap.secondCoverage) >= 0.99 &&
                        allWitnessed(iou: nil, containment: 0.99, smallerArea: true, agreement: true)
                    let confidenceConcordance = observations[parent].confidence >= observations[child].confidence &&
                        allWitnessed(iou: nil, containment: containment, smallerArea: true, agreement: true)
                    if strictEvidence || confidenceConcordance { reason = "equivalent-output-different-fragmentation" }
                }
                if reason == nil, normalGate, let iou = configuration.strongPacketIoU,
                   let containment = configuration.strongPacketContainment,
                   allWitnessed(iou: iou, containment: containment, smallerArea: false, agreement: true) {
                    reason = "strong-packet-overlap"
                }
                // A lower source/layout agreement can come from recovering an
                // original body's missing end strokes. Require a near-identical
                // BODY witness plus separate original parent content instead of
                // counting a nested reading as another body observation.
                if reason == nil, overlap.firstCoverage >= 0.95,
                   observations[parent].confidence >= observations[child].confidence,
                   bodySets[parent].count >= 2,
                   !bodySets[child].isEmpty {
                    let parentBody = bodySets[parent]
                    let childBody = bodySets[child]
                    let bodyColumns = parentPackets.indices.filter { parentBody.contains(parentPackets[$0]) }
                    let bodiesWitnessed = childPackets.indices.filter { childBody.contains(childPackets[$0]) }.allSatisfy { ci in
                        bodyColumns.contains { pi in
                            pairs[ci][pi].map { $0.iou >= 0.9 && $0.firstCoverage >= 0.95 } == true
                        }
                    }
                    let readingsNested = readingSets[child].allSatisfy { packet in
                        guard let ci = childPackets.firstIndex(of: packet) else { return false }
                        let witnessed = bodyColumns.contains { pi in
                            pairs[ci][pi].map { $0.firstCoverage >= 0.95 } == true
                        }
                        return witnessed && childBody.contains { body in
                            packetOverlap(observations[parent].table, packet, body).map { $0.firstCoverage >= 0.99 } == true
                        }
                    }
                    let uniqueContinuation = bodyColumns.contains { pi in
                        pairs.allSatisfy { row in row[pi].map { $0.iou <= 0.1 } == true }
                    }
                    if bodiesWitnessed && readingsNested && uniqueContinuation {
                        reason = "nested-reading-body-continuation"
                    }
                }
                if let reason {
                    pending.insert(parent)
                    pending.insert(child)
                    covers[parent][child] = true
                    measurements[parent * n + child] = (overlap.iou, overlap.firstCoverage)
                    reasons[parent * n + child] = reason
                }
            }
        }
        // Isolated owners cannot suppress another owner or affect any ranking.
        while !pending.isEmpty {
            let maximal = pending.filter { child in
                !pending.contains { parent in covers[parent][child] && !covers[child][parent] }
            }
            guard let anchor = maximal.max(by: { a, b in
                if observations[a].confidence != observations[b].confidence { return observations[a].confidence < observations[b].confidence }
                let aa = F.rfPolygonArea(observations[a].polygon), bb = F.rfPolygonArea(observations[b].polygon)
                if aa != bb { return aa < bb }
                return a > b
            }) else { break }
            pending.remove(anchor)
            for child in pending.sorted() where covers[anchor][child] {
                keep[child] = false; pending.remove(child)
                let measured = measurements[anchor * n + child]!
                aliases.append(.init(anchor: anchor, removed: child,
                    anchorOriginalBody: observations[anchor].body, anchorOriginalReadings: observations[anchor].readings,
                    removedOriginalBody: observations[child].body, removedOriginalReadings: observations[child].readings,
                    outputIoU: measured.0, outputContainment: measured.1, reason: reasons[anchor * n + child]))
            }
        }
        let result = Result(keep: keep, aliases: aliases)
        observer?(result)
        return result
    }
}
