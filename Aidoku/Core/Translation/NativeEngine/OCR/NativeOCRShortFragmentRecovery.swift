import CoreGraphics
import Foundation

/// Re-read a split short kana column only beside an independently confirmed
/// Japanese column. The primary read and every ordinary crop stay unchanged.
@available(iOS 18.0, *)
enum NativeOCRShortFragmentRecovery {
    struct Proposal {
        let head: NativeCoreMLRecognizedRegion
        let tail: NativeCoreMLRecognizedRegion
        let witness: NativeCoreMLRecognizedRegion
        let combined: NativeCoreMLRecognitionRegion
        var regions: [NativeCoreMLRecognitionRegion] {
            [combined, .init(sourceIndex: witness.sourceIndex, polygon: witness.polygon)]
        }
        var replaced: Set<Int> { [head.sourceIndex, tail.sourceIndex] }
    }

    static func proposals(_ reads: [NativeCoreMLRecognizedRegion], width: Int, height: Int) -> [Proposal] {
        guard width > 0, height > 0, reads.count <= 256,
              Set(reads.map(\.sourceIndex)).count == reads.count,
              reads.allSatisfy({ $0.sourceIndex >= 0 }) else { return [] }
        let frame = CGRect(x: 0, y: 0, width: width, height: height)
        let boxes = reads.map { read -> CGRect? in
            guard read.polygon.count == 4, read.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  let box = NativeOCRScopeGeometry.bounds(for: read.polygon),
                  box.width.isFinite, box.height.isFinite, frame.contains(box) else { return nil }
            return box
        }
        var claimed = Set<Int>(), result: [Proposal] = []
        for h in reads.indices {
            let head = reads[h]
            guard !claimed.contains(head.sourceIndex), head.confidence >= 0.35, head.confidence < 0.65,
                  (1...2).contains(head.text.count), head.text.unicodeScalars.allSatisfy(isKana),
                  let hb = boxes[h], hb.width >= 12, hb.width <= 140,
                  hb.height >= hb.width * 0.65, hb.height <= hb.width * 2.2 else { continue }
            let tails = reads.indices.filter { t in
                guard t != h, !claimed.contains(reads[t].sourceIndex), reads[t].confidence >= 0.35,
                      reads[t].text.count == 1, reads[t].text.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }),
                      let tb = boxes[t], tb.width >= hb.width * 0.7, tb.width <= hb.width * 1.5,
                      tb.height >= hb.width * 0.65, tb.height <= hb.width * 1.6,
                      tb.midY > hb.midY,
                      tb.minY >= hb.maxY - hb.width * 0.35, tb.minY <= hb.maxY + hb.width * 0.25 else { return false }
                let overlap = min(hb.maxX, tb.maxX) - max(hb.minX, tb.minX)
                return overlap >= min(hb.width, tb.width) * 0.7
            }
            guard tails.count == 1, let t = tails.first, let tb = boxes[t] else { continue }
            let union = hb.union(tb)
            guard union.height >= union.width * 1.5, union.height <= union.width * 3.5,
                  union.width * union.height <= 65_536 else { continue }
            let witnesses = reads.indices.filter { w in
                guard w != h, w != t, !claimed.contains(reads[w].sourceIndex), reads[w].confidence >= 0.9,
                      (3...24).contains(reads[w].text.count), reads[w].text.unicodeScalars.contains(where: isKana),
                      let wb = boxes[w], wb.width >= union.width * 0.6, wb.width <= union.width * 1.5,
                      wb.height >= wb.width * 3, wb.height >= union.height * 1.5,
                      wb.midX < union.midX, wb.maxX <= union.minX + union.width * 0.2,
                      abs(wb.minY - union.minY) <= union.width * 0.4 else { return false }
                let step = union.midX - wb.midX
                return step >= union.width * 0.6 && step <= union.width * 1.6
            }
            guard witnesses.count == 1, let w = witnesses.first else { continue }
            let polygon = [CGPoint(x: union.minX, y: union.minY), CGPoint(x: union.maxX, y: union.minY),
                CGPoint(x: union.maxX, y: union.maxY), CGPoint(x: union.minX, y: union.maxY)]
            result.append(.init(head: head, tail: reads[t], witness: reads[w],
                combined: .init(sourceIndex: head.sourceIndex, polygon: polygon)))
            claimed.formUnion([head.sourceIndex, reads[t].sourceIndex, reads[w].sourceIndex])
            // At most four union crops plus four witness crops, with no new IDs.
            if result.count == 4 { break }
        }
        return result
    }

    static func replacement(_ proposal: Proposal, reads: [NativeCoreMLRecognizedRegion]) -> NativeCoreMLRecognizedRegion? {
        guard Set(reads.map(\.sourceIndex)).count == reads.count,
              proposal.head.sourceIndex != proposal.tail.sourceIndex,
              proposal.head.sourceIndex != proposal.witness.sourceIndex,
              proposal.tail.sourceIndex != proposal.witness.sourceIndex,
              proposal.combined.sourceIndex == proposal.head.sourceIndex,
              let joined = reads.first(where: { $0.sourceIndex == proposal.combined.sourceIndex }),
              let witness = reads.first(where: { $0.sourceIndex == proposal.witness.sourceIndex }),
              joined.polygon == proposal.combined.polygon,
              witness.polygon == proposal.witness.polygon, witness.text == proposal.witness.text,
              witness.confidence >= max(0.9, proposal.witness.confidence - 0.03),
              joined.confidence >= max(0.95, max(proposal.head.confidence, proposal.tail.confidence)),
              joined.text.count == proposal.head.text.count + proposal.tail.text.count,
              joined.text.hasPrefix(proposal.head.text), joined.text.unicodeScalars.allSatisfy(isKana)
        else { return nil }
        return joined
    }

    private static func isKana(_ value: Unicode.Scalar) -> Bool {
        (0x3041...0x3096).contains(value.value) || (0x30A1...0x30FA).contains(value.value)
    }
}
