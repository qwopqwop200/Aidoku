import CoreGraphics
import Foundation

/// A tall detector column may extend through a separately detected small aside.
/// Require two independently aligned columns in each block, then reread only the
/// overlong columns. Text is never split by assigning characters to coordinates.
@available(iOS 18.0, *)
enum NativeOCRStackedAsideRecovery {
    struct Proposal {
        let originals: [NativeCoreMLRecognizedRegion]
        let regions: [NativeCoreMLRecognitionRegion]
    }

    static func proposals(_ reads: [NativeCoreMLRecognizedRegion]) -> [Proposal] {
        guard reads.count <= 256 else { return [] }
        let columns = reads.compactMap { read -> (read: NativeCoreMLRecognizedRegion, box: CGRect)? in
            guard read.confidence >= 0.8, read.text.count >= 3,
                  read.text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }),
                  let box = NativeOCRScopeGeometry.bounds(for: read.polygon),
                  box.width > 0, box.height >= box.width * 2.4 else { return nil }
            return (read, box)
        }
        var result: [Proposal] = [], claimed = Set<Int>()
        for lower in columns {
            let font = lower.box.width
            let lowerBlock = columns.filter { item in
                let small = min(font, item.box.width)
                return max(font, item.box.width) <= small * 1.25 &&
                    abs(item.box.minY - lower.box.minY) <= small * 0.4 &&
                    abs(item.box.midX - lower.box.midX) <= font * 2.2
            }
            guard lowerBlock.count >= 2 else { continue }
            let lowerBox = lowerBlock.dropFirst().reduce(lowerBlock[0].box) { $0.union($1.box) }
            // A complete upper column establishes the actual end of the upper block.
            for anchor in columns where anchor.box.width >= font * 1.25 && anchor.box.width <= font * 1.8 {
                let gap = lowerBox.minY - anchor.box.maxY
                guard gap >= 0, gap <= font * 0.7,
                      anchor.box.minY < lowerBox.minY - font * 3,
                      anchor.box.intersects(lowerBox.insetBy(dx: -font, dy: -font)) else { continue }
                let crossing = columns.filter { item in
                    let small = min(anchor.box.width, item.box.width)
                    return !claimed.contains(item.read.sourceIndex) &&
                        max(anchor.box.width, item.box.width) <= small * 1.2 &&
                        abs(item.box.minY - anchor.box.minY) <= small * 0.6 &&
                        abs(item.box.midX - anchor.box.midX) <= small * 2 &&
                        item.box.maxY >= lowerBox.minY + font &&
                        item.box.minX < lowerBox.maxX + font * 1.5 && item.box.maxX > lowerBox.minX
                }
                guard !crossing.isEmpty else { continue }
                let bottom = (anchor.box.maxY + lowerBox.minY) / 2
                let crops = crossing.map { item in
                    let box = CGRect(x: item.box.minX, y: item.box.minY,
                        width: item.box.width, height: bottom - item.box.minY)
                    return NativeCoreMLRecognitionRegion(sourceIndex: item.read.sourceIndex, polygon: [
                        CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                        CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)])
                }
                result.append(Proposal(originals: crossing.map(\.read), regions: crops))
                claimed.formUnion(crossing.map { $0.read.sourceIndex })
                if result.count >= 4 { return result }
            }
        }
        return result
    }

    static func replacements(_ proposal: Proposal, reads: [NativeCoreMLRecognizedRegion]) -> [NativeCoreMLRecognizedRegion]? {
        let result = proposal.originals.compactMap { original -> NativeCoreMLRecognizedRegion? in
            guard let read = reads.first(where: { $0.sourceIndex == original.sourceIndex }), read.confidence >= 0.85 else { return nil }
            let old = original.text.filter { $0.isLetter || $0.isNumber }
            let new = read.text.filter { $0.isLetter || $0.isNumber }
            guard new.count >= 3, old.hasPrefix(new), new.count * 2 >= old.count else { return nil }
            return read
        }
        return result.count == proposal.originals.count ? result : nil
    }
}
