import CoreGraphics
import Foundation

/// A short uncertain decode only requests a retry; it never identifies which
/// column was omitted. Independent DB children and concordant crop reads do.
@available(iOS 18.0, *)
enum NativeOCRMultilineColumnRecovery {
    struct Proposal: Sendable {
        let original: NativeCoreMLRecognitionRegion
        let originalText: String
        /// Right-to-left columns, each followed by its second padding variant.
        let crops: [NativeCoreMLRecognitionRegion]
    }

    static func eligible(_ read: NativeCoreMLRecognizedRegion) -> Bool {
        let text = read.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return read.confidence.isFinite && (0.35..<0.65).contains(read.confidence)
            && (2...4).contains(text.unicodeScalars.count)
            && text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }
    }

    static func proposal(region: NativeCoreMLRecognitionRegion, read: NativeCoreMLRecognizedRegion,
                         frame: CGRect, peers: [NativeCoreMLRecognitionRegion]) -> Proposal? {
        guard eligible(read), region.sourceIndex == read.sourceIndex, region.polygon == read.polygon,
              region.samplingPolygon == nil, !region.useProvidedOrder, region.minimumSequenceWidth == 0,
              !region.isThinFinePrintRecovery, let evidence = region.recognitionColumnEvidence,
              evidence.parentBoxIndex == region.sourceIndex,
              evidence.sourceWidth == Int(frame.width), evidence.sourceHeight == Int(frame.height),
              evidence.provenance == "db-independent-child-components",
              (2...3).contains(evidence.polygons.count),
              evidence.componentPixels.count == evidence.polygons.count,
              evidence.meanProbabilities.count == evidence.polygons.count,
              evidence.componentPixels.allSatisfy({ $0 >= 8 }),
              evidence.threshold.isFinite, evidence.threshold > 0, evidence.threshold <= 1,
              evidence.meanProbabilities.allSatisfy({ $0.isFinite && $0 >= evidence.threshold && $0 <= 1 }),
              let parent = bounds(region.polygon), frame.contains(parent),
              parent.width * parent.height <= 150_000 else { return nil }
        let columns = evidence.polygons.compactMap { bounds($0) }.sorted { $0.midX > $1.midX }
        guard columns.count == evidence.polygons.count,
              columns.allSatisfy({ parent.contains($0) && $0.width >= 5 && $0.height >= $0.width * 2 }),
              zip(columns, columns.dropFirst()).allSatisfy({ a, b in
                  let gap = a.minX - b.maxX
                  return gap >= 2 && gap <= max(a.width, b.width) * 1.5
              }) else { return nil }
        let foreign = peers.filter { $0.sourceIndex != region.sourceIndex }.compactMap { bounds($0.polygon, requireAxisAligned: false) }
        let maxima = evidence.recognitionClearance?.maximumPaddingFractions
            ?? Array(repeating: 0.24, count: columns.count)
        guard maxima.count == columns.count,
              maxima.allSatisfy({ $0 == 0.24 || $0 == 0.6 }) else { return nil }
        var crops: [NativeCoreMLRecognitionRegion] = []
        for (index, column) in columns.enumerated() {
            // The measured independent components establish distinct x supports,
            // not equal column lengths. Original detector Y is a recognition-only
            // hypothesis, never new ink coverage or erasure ownership. Variants
            // must agree, preserve the original decode, and avoid foreign peers.
            let left = index + 1 < columns.count ? (column.minX + columns[index + 1].maxX) / 2 : parent.minX
            let right = index > 0 ? (column.maxX + columns[index - 1].minX) / 2 : parent.maxX
            var previous: CGRect?
            // Wider context is permitted only by an original-DB certificate for
            // this column. Keep two model calls, including on legacy evidence.
            let fractions: [CGFloat] = maxima[index] == 0.6 ? [0.4, 0.6] : [0.12, 0.24]
            for fraction in fractions {
                let pad = max(1, column.width * fraction)
                let crop = CGRect(x: max(left, column.minX - pad), y: parent.minY,
                    width: min(right, column.maxX + pad) - max(left, column.minX - pad), height: parent.height)
                guard !crop.isNull, frame.contains(crop), crop.contains(column), crop != previous else { return nil }
                if maxima[index] > 0.24 || foreign.contains(where: { $0.intersects(crop) }) {
                    // A peer's rectangle may cover blank context. Only the
                    // original DB producer's closed-component clearance may
                    // override that broad rectangle veto for this exact crop.
                    // This evidence never changes source or erasure geometry.
                    guard clearedForRecognition(crop, columnIndex: index, columns: columns,
                                                parent: parent, evidence: evidence) else { return nil }
                }
                crops.append(.init(sourceIndex: region.sourceIndex, polygon: quad(crop)))
                previous = crop
            }
        }
        return Proposal(original: region, originalText: read.text, crops: crops)
    }

    private static func clearedForRecognition(_ crop: CGRect, columnIndex: Int, columns: [CGRect],
                                              parent: CGRect, evidence: NativeOCRDetectorColumnEvidence) -> Bool {
        guard let proof = evidence.recognitionClearance,
              proof.provenance == "original-db-closed-component-recognition-clearance-v1",
              proof.parentBoxIndex == evidence.parentBoxIndex,
              proof.threshold == 0.15, evidence.threshold == 0.9,
              proof.ownedComponentPixels > 0, proof.ownedComponentPixels <= 65_536,
              proof.polygons.count == columns.count, proof.supportedCells.count == columns.count,
              proof.supportedCells.allSatisfy({ $0 > 0 && $0 <= proof.ownedComponentPixels }),
              evidence.cellRuns.count == columns.count, evidence.componentSeeds.count == columns.count
        else { return false }
        let corridors = proof.polygons.compactMap { bounds($0) }.sorted { $0.midX > $1.midX }
        let maxima = proof.maximumPaddingFractions ?? Array(repeating: 0.24, count: columns.count)
        guard corridors.count == columns.count, maxima.count == columns.count,
              maxima.allSatisfy({ $0 == 0.24 || $0 == 0.6 }) else { return false }
        for (index, column) in columns.enumerated() {
            let left = index + 1 < columns.count ? (column.minX + columns[index + 1].maxX) / 2 : parent.minX
            let right = index > 0 ? (column.maxX + columns[index - 1].minX) / 2 : parent.maxX
            let pad = max(1, column.width * CGFloat(maxima[index]))
            let expected = CGRect(x: max(left, column.minX - pad), y: parent.minY,
                width: min(right, column.maxX + pad) - max(left, column.minX - pad), height: parent.height)
            // Reject stale or enlarged certificates, even if they contain crop.
            guard corridors[index] == expected, parent.contains(corridors[index]),
                  corridors[index].contains(column) else { return false }
        }
        return corridors[columnIndex].contains(crop)
    }

    static func accepted(proposal: Proposal, reads: [NativeCoreMLRecognizedRegion]) -> NativeCoreMLRecognizedRegion? {
        guard reads.count == proposal.crops.count, [4, 6].contains(reads.count) else { return nil }
        var ordered: [NativeCoreMLRecognizedRegion] = []
        for crop in proposal.crops {
            let matches = reads.filter { $0.sourceIndex == crop.sourceIndex && $0.polygon == crop.polygon }
            guard matches.count == 1, matches[0].confidence.isFinite, matches[0].confidence >= 0.95 else { return nil }
            ordered.append(matches[0])
        }
        var columns: [String] = []
        for i in stride(from: 0, to: ordered.count, by: 2) {
            let text = ordered[i].text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text == ordered[i + 1].text.trimmingCharacters(in: .whitespacesAndNewlines),
                  (3...64).contains(text.unicodeScalars.count),
                  text.unicodeScalars.filter({ (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }).count >= 2
            else { return nil }
            columns.append(text)
        }
        // Repeated identical short effects do not establish omitted prose.
        guard Set(columns).count == columns.count else { return nil }
        let text = columns.joined()
        guard text.unicodeScalars.count >= proposal.originalText.unicodeScalars.count + 3,
              preservesOriginalScript(proposal.originalText, in: text) else { return nil }
        return .init(sourceIndex: proposal.original.sourceIndex, polygon: proposal.original.polygon,
                     text: text, confidence: ordered.map(\.confidence).min()!)
    }

    /// Retain every original Japanese/CJK scalar in order. This protects a
    /// known suffix but does not prove full coverage of either source column.
    private static func preservesOriginalScript(_ original: String, in recovered: String) -> Bool {
        let wanted = Array(original.unicodeScalars.filter {
            (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
        })
        guard !wanted.isEmpty else { return false }
        var index = 0
        for scalar in recovered.unicodeScalars where index < wanted.count {
            if scalar == wanted[index] { index += 1 }
        }
        return index == wanted.count
    }

    private static func bounds(_ polygon: [CGPoint], requireAxisAligned: Bool = true) -> CGRect? {
        guard polygon.count == 4, polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return nil }
        let xs = polygon.map(\.x), ys = polygon.map(\.y)
        let r = CGRect(x: xs.min()!, y: ys.min()!, width: xs.max()! - xs.min()!, height: ys.max()! - ys.min()!)
        guard r.width > 0, r.height > 0 else { return nil }
        // Only axis-aligned child components; slanted evidence needs its own crop policy.
        guard !requireAxisAligned || polygon.allSatisfy({ (abs($0.x-r.minX) < 0.01 || abs($0.x-r.maxX) < 0.01)
            && (abs($0.y-r.minY) < 0.01 || abs($0.y-r.maxY) < 0.01) }) else { return nil }
        return r
    }
    private static func quad(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x:r.minX,y:r.minY), CGPoint(x:r.maxX,y:r.minY), CGPoint(x:r.maxX,y:r.maxY), CGPoint(x:r.minX,y:r.maxY)]
    }
}
