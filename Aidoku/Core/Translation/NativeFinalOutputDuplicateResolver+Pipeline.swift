import CoreGraphics
import Foundation

extension NativeFinalOutputDuplicateResolver {
    /// Final observed geometry, then duplicate-owner resolution, before content admission.
    static func applying(_ regions: [ReaderTranslationRegion]) -> (regions: [ReaderTranslationRegion], suppressed: Int) {
        resolve(regions.map(correctedOutputGeometry), complementOnly: false)
    }

    /// Only owners surviving ordinary deduplication and content admission may vouch for a wide complement.
    static func applyingComplementOwners(_ regions: [ReaderTranslationRegion]) -> (regions: [ReaderTranslationRegion], suppressed: Int) {
        guard regions.contains(where: { $0.acceptedSource.membership?.isLegacyComplement == true }) else { return (regions, 0) }
        return resolve(regions, complementOnly: true)
    }

    private static func resolve(_ regions: [ReaderTranslationRegion], complementOnly: Bool)
        -> (regions: [ReaderTranslationRegion], suppressed: Int) {
        // Deduplicate final owners only after corrected geometry is available.
        // Original source tables remain immutable; aliases cannot witness later deletions.
        typealias DuplicateResolver = NativeFinalOutputDuplicateResolver
        var sourceTables: [Int: [[DuplicateResolver.F.Point]]] = [:]
        var sourceAgreement: [Int: [Double]] = [:]
        var sourceTableKeys: [ObjectIdentifier: Int] = [:]
        let observations = regions.map { region -> DuplicateResolver.Observation in
            guard let m = region.acceptedSource.membership else {
                return .init(polygon: [], confidence: region.confidence, body: [], readings: [], table: -1, eligible: false)
            }
            let key = ObjectIdentifier(m.table)
            if sourceTableKeys[key] == nil {
                let ordinal = sourceTableKeys.count
                sourceTableKeys[key] = ordinal
                if !complementOnly {
                    let packetPolygons: [[DuplicateResolver.F.Point]] = m.table.packets.map { packet in
                        packet.polygon.map { .init(x: Double($0.x), y: Double($0.y)) }
                    }
                    sourceTables[ordinal] = packetPolygons
                    if m.table.packets.contains(where: { $0.layoutPolygon != nil }) {
                        sourceAgreement[ordinal] = m.table.packets.enumerated().map { index, packet in
                            guard let baseline = packet.layoutPolygon else { return .nan }
                            let current = packetPolygons[index]
                            let original = baseline.map { DuplicateResolver.F.Point(x: Double($0.x), y: Double($0.y)) }
                            return DuplicateResolver.F.polygonOverlap(current, original)?.iou ?? .nan
                        }
                    }
                }
            }
            return .init(
                polygon: region.polygon.map { .init(x: Double($0.x), y: Double($0.y)) },
                confidence: region.confidence, body: m.body.sorted(), readings: m.readings.sorted(),
                table: sourceTableKeys[key]!, eligible: !m.hasUntrackedInputs,
                nonVotingSourcePackets: m.unknownDedup.sorted(), isLegacyComplement: m.isLegacyComplement)
        }
        let finalDuplicates: Result
        if complementOnly {
            finalDuplicates = resolvingComplementOwners(observations: observations, regions: regions)
            complementObserver?(finalDuplicates)
        } else {
            finalDuplicates = sourceAgreement.isEmpty
                ? DuplicateResolver.selectOriginalWitness(observations, sourceTables: sourceTables)
                : DuplicateResolver.select(observations, sourceTables: sourceTables, sourceAgreement: sourceAgreement)
        }
        guard !finalDuplicates.aliases.isEmpty else { return (regions, 0) }
        var joined = regions
        var changedOwners = Set<Int>()
        for alias in finalDuplicates.aliases {
            let other = joined[alias.removed]
            if complementOnly,
               let parent = joined[alias.anchor].acceptedSource.membership, let child = other.acceptedSource.membership {
                // Wider duplicate boxes remain available for erasure, without changing the surviving body's geometry or role.
                let guest = child.body.union(child.readings).union(child.unknownDedup)
                let originalVotes = parent.body.union(parent.readings).subtracting(parent.unknownDedup)
                let metadata = joined[alias.anchor].acceptedSource
                joined[alias.anchor].acceptedSource = .init(.init(table: parent.table, body: parent.body, readings: parent.readings,
                    unknownDedup: parent.unknownDedup.union(guest.subtracting(originalVotes)), hasUntrackedInputs: parent.hasUntrackedInputs),
                    layoutPolygon: metadata.layoutPolygon, detectorSignals: metadata.detectorSignals)
            } else {
                joined[alias.anchor].acceptedSource = joined[alias.anchor].acceptedSource.retainingDuplicate(
                    other.acceptedSource, exactContentWitness: joined[alias.anchor].source == other.source)
            }
            joined[alias.anchor].detectorSeedEvidence =
                NativeOCRDetectorSeedEvidence.preservingUnion([
                    joined[alias.anchor].detectorSeedEvidence, other.detectorSeedEvidence,
                ])
                ?? joined[alias.anchor].detectorSeedEvidence
            joined[alias.anchor].auxiliaryInkRects += other.auxiliaryInkRects
            joined[alias.anchor].auxiliaryInkPolygons += other.auxiliaryInkPolygons
            joined[alias.anchor].sourceOCRAlternatives += other.sourceOCRAlternatives
            changedOwners.insert(alias.anchor)
        }
        joined = joined.enumerated().compactMap { index, region in
            guard finalDuplicates.keep[index] else { return nil }
            return !complementOnly && changedOwners.contains(index) ? correctedOutputGeometry(region) : region
        }
        return (joined, finalDuplicates.aliases.count)
    }

    private static func resolvingComplementOwners(observations: [Observation], regions: [ReaderTranslationRegion]) -> Result {
        var keep = Array(repeating: true, count: observations.count), aliases = [Alias]()
        guard observations.count <= 512 else { return .init(keep: keep, aliases: []) }
        let members = regions.map { $0.acceptedSource.membership }
        let primary = observations.indices.compactMap { i -> (index: Int, body: Set<Int>, readings: Set<Int>)? in
            guard observations[i].eligible, let m = members[i], let start = m.table.legacyPacketStart else { return nil }
            let body = m.body.subtracting(m.unknownDedup)
            // A child has at least one voting body packet and needs a strictly larger parent.
            guard body.count >= 2, body.allSatisfy({ $0 < start }) else { return nil }
            let readings = m.readings.subtracting(m.unknownDedup)
            guard readings.allSatisfy({ $0 < start }) else { return nil }
            return (i, body, readings)
        }
        // Any primary-only owner may cover a wide complement read of its own text.
        let textPrimaries = observations.indices.filter { i in
            guard observations[i].eligible, let m = members[i], let start = m.table.legacyPacketStart else { return false }
            let body = m.body.subtracting(m.unknownDedup), readings = m.readings.subtracting(m.unknownDedup)
            return !body.isEmpty && body.union(readings).allSatisfy { $0 < start }
        }
        guard !primary.isEmpty || !textPrimaries.isEmpty else { return .init(keep: keep, aliases: []) }
        let bounds = observations.map { Bounds($0.polygon) }
        // Keys use the owner's own voting body packets, never a caller-edited summary.
        func bodyKey(_ m: NativeOCRAcceptedSource.Membership) -> [Unicode.Scalar] {
            complementCoverageKey(m.body.subtracting(m.unknownDedup).sorted()
                .compactMap { m.table.packets.indices.contains($0) ? m.table.packets[$0].text : nil }.joined())
        }
        let primaryKeys = Dictionary(uniqueKeysWithValues: textPrimaries.compactMap { i in members[i].map { (i, bodyKey($0)) } })
        let singleLinePrimaries = Set(textPrimaries.filter { i in members[i].map { $0.body.subtracting($0.unknownDedup).count == 1 } == true })
        for i in observations.indices where observations[i].isLegacyComplement == true {
            let child = observations[i]
            guard child.eligible, let m = members[i], let start = m.table.legacyPacketStart,
                  m.table.packets.count <= 4096 else { continue }
            let packets = m.table.packets
            let body = m.body.subtracting(m.unknownDedup), readings = m.readings.subtracting(m.unknownDedup)
            guard !body.isEmpty, body.union(readings).allSatisfy({ $0 >= start && packets.indices.contains($0) }) else { continue }
            var best: (index: Int, iou: Double, coverage: Double)?
            for p in primary where observations[p.index].table == child.table {
                let j = p.index
                guard p.body.count > body.count, bounds[i].mayOverlap(bounds[j]),
                      let output = F.polygonOverlap(child.polygon, observations[j].polygon), output.iou > 0,
                      output.iou > (best?.iou ?? 0) else { continue }
                func witnessed(_ candidates: Set<Int>, by originals: Set<Int>) -> Bool {
                    candidates.allSatisfy { c in
                        let candidate = textKey(packets[c].text)
                        guard !candidate.isEmpty else { return false }
                        return originals.contains { a in
                            guard packets.indices.contains(a) else { return false }
                            guard candidate == textKey(packets[a].text) else { return false }
                            let childPolygon = packets[c].polygon.map { F.Point(x: Double($0.x), y: Double($0.y)) }
                            let parentPolygon = packets[a].polygon.map { F.Point(x: Double($0.x), y: Double($0.y)) }
                            guard let overlap = F.polygonOverlap(childPolygon, parentPolygon),
                                  overlap.iou >= 0.15 else { return false }
                            return true
                        }
                    }
                }
                if witnessed(body, by: p.body), witnessed(readings, by: p.readings) {
                    best = (j, output.iou, output.firstCoverage)
                }
            }
            if let best {
                let parent = observations[best.index]
                keep[i] = false
                aliases.append(.init(anchor: best.index, removed: i, anchorOriginalBody: parent.body, anchorOriginalReadings: parent.readings,
                    removedOriginalBody: child.body, removedOriginalReadings: child.readings, outputIoU: best.iou,
                    outputContainment: best.coverage, reason: "complement-owner-packet-witness"))
            } else if let covered = coveringPrimary(child: i, candidates: textPrimaries, keys: primaryKeys, singleLines: singleLinePrimaries,
                                                    observations: observations, bounds: bounds, childKey: bodyKey(m)) {
                let parent = observations[covered.index]
                keep[i] = false
                aliases.append(.init(anchor: covered.index, removed: i, anchorOriginalBody: parent.body,
                    anchorOriginalReadings: parent.readings, removedOriginalBody: child.body,
                    removedOriginalReadings: child.readings, outputIoU: covered.iou,
                    outputContainment: covered.coverage, reason: "complement-owner-text-coverage"))
            }
        }
        return .init(keep: keep, aliases: aliases)
    }

    /// Wide legacy reads often span one or two primary owners and repeat or
    /// interleave their lines, so exact packet witnesses miss them. A complement
    /// is a duplicate only when primaries cover its output box AND its text.
    /// Calibrated on the 830-page live run (legacy-only owners after grouping).
    static let complementGeometryCoverage = 0.5
    static let complementTextCoverage = 0.9
    /// A complement lying inside ONE single-line primary is a second reading of
    /// that physical line (OCR variant), provided half its characters agree.
    static let complementSameLineContainment = 0.8
    static let complementSameLineTextCoverage = 0.5

    private static func coveringPrimary(child i: Int, candidates: [Int], keys: [Int: [Unicode.Scalar]], singleLines: Set<Int>,
                                        observations: [Observation], bounds: [Bounds], childKey: [Unicode.Scalar])
        -> (index: Int, iou: Double, coverage: Double)? {
        guard !childKey.isEmpty else { return nil }
        var covered = 0.0, smaller = 0.0
        var anchor: (index: Int, iou: Double, coverage: Double)?
        var overlapping: [[Unicode.Scalar]] = []
        for j in candidates where observations[j].table == observations[i].table && bounds[i].mayOverlap(bounds[j]) {
            guard let overlap = F.polygonOverlap(observations[i].polygon, observations[j].polygon),
                  overlap.firstCoverage > 0 else { continue }
            covered += overlap.firstCoverage
            smaller = max(smaller, overlap.firstCoverage, overlap.secondCoverage)
            overlapping.append(keys[j] ?? [])
            if overlap.firstCoverage > (anchor?.coverage ?? 0) { anchor = (j, overlap.iou, overlap.firstCoverage) }
        }
        guard let anchor else { return nil }
        let available = Set(overlapping.joined())
        let textCoverage = Double(childKey.lazy.filter { available.contains($0) }.count) / Double(childKey.count)
        if anchor.coverage >= complementSameLineContainment, singleLines.contains(anchor.index),
           textCoverage >= complementSameLineTextCoverage {
            return anchor
        }
        guard max(min(1, covered), smaller) >= complementGeometryCoverage else { return nil }
        if childKey.count <= 2 {
            // Too short for character coverage: one primary must read it verbatim.
            return overlapping.contains { containsRun(childKey, in: $0) } ? anchor : nil
        }
        return textCoverage >= complementTextCoverage ? anchor : nil
    }

    private static let smallKana: [Unicode.Scalar: Unicode.Scalar] = Dictionary(uniqueKeysWithValues: zip(
        "ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮヵヶ".unicodeScalars, "あいうえおつやゆよわアイウエオツヤユヨワカケ".unicodeScalars))

    /// NFKC, lowercased letters and numbers with small kana enlarged; symbol-only
    /// text (for example "♡" or "!") keeps its non-whitespace scalars instead.
    static func complementCoverageKey(_ text: String) -> [Unicode.Scalar] {
        let scalars = text.precomposedStringWithCompatibilityMapping.lowercased().unicodeScalars
        let letters = scalars.compactMap { scalar -> Unicode.Scalar? in
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber:
                return smallKana[scalar] ?? scalar
            default: return nil
            }
        }
        return letters.isEmpty ? Array(scalars).filter { !$0.properties.isWhitespace } : letters
    }

    private static func containsRun(_ needle: [Unicode.Scalar], in haystack: [Unicode.Scalar]) -> Bool {
        guard !needle.isEmpty, needle.count <= haystack.count else { return false }
        return (0...(haystack.count - needle.count)).contains { haystack[$0..<($0 + needle.count)].elementsEqual(needle) }
    }

    private static func correctedOutputGeometry(_ original: ReaderTranslationRegion) -> ReaderTranslationRegion {
        guard let m = original.acceptedSource.membership, !m.body.isEmpty,
            m.table.width > 0, m.table.height > 0
        else { return original }
        let packets = m.body.sorted().map { m.table.packets[$0] }
        guard packets.contains(where: { $0.layoutPolygon != nil }),
            packets.allSatisfy({ $0.polygon.count == 4 && $0.polygon.allSatisfy { $0.x.isFinite && $0.y.isFinite } })
        else { return original }
        let width = CGFloat(m.table.width)
        let height = CGFloat(m.table.height)
        func normalized(_ q: [CGPoint]) -> CGRect {
            q.reduce(CGRect.null) { box, p in
                box.union(CGRect(origin: CGPoint(x: p.x / width, y: p.y / height), size: .zero))
            }
        }
        let rect = normalized(packets.flatMap(\.polygon))
        var region = ReaderTranslationRegion(
            id: original.id,
            rect: rect,
            source: original.source,
            sourceColumnRecognition: original.sourceColumnRecognition,
            sourceRFParagraphRecognition: original.sourceRFParagraphRecognition,
            translation: original.translation,
            keepsClassifiedSFXSource: original.keepsClassifiedSFXSource,
            rendersUnchangedSymbols: original.rendersUnchangedSymbols,
            polygon: [
                CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY),
                CGPoint(x: rect.minX, y: rect.maxY),
            ],
            confidence: original.confidence,
            sourceImageAspectRatio: original.sourceImageAspectRatio,
            translationOrder: original.translationOrder,
            translationOrderVersion: original.translationOrderVersion,
            sourceOrientation: original.sourceOrientation,
            sourceSingleVerticalColumn: original.sourceSingleVerticalColumn,
            translationReuseIdentity: original.translationReuseIdentity,
            translationRecoveryFailure: original.translationRecoveryFailure,
            auxiliaryInkRects: original.auxiliaryInkRects,
            auxiliaryInkPolygons: original.auxiliaryInkPolygons,
            detectorSeedEvidence: original.detectorSeedEvidence,
            acceptedSource: original.acceptedSource,
            sourceOCRAlternatives: original.sourceOCRAlternatives,
            sourceRoleEvidence: original.sourceRoleEvidence,
            balloonInterior: original.balloonInterior,
            unitMemberRects: original.unitMemberRects,
            isOccludedFinePrint: original.isOccludedFinePrint,
            isRecoveredLine: original.isRecoveredLine
        )
        NativeParagraphFragmentGrouping.preservingOriginalAngle(&region, useLayout: false)
        if !original.unitMemberRects.isEmpty { region.unitMemberRects = packets.map { normalized($0.polygon) } }
        return region
    }
}
