import CoreGraphics
import Foundation

/// An exact short tensor can make one glyph depend on the sequence boundary.
/// Two padded readings may resolve it only inside independently confirmed text.
@available(iOS 18.0, *)
enum NativeOCRShortContextRecovery {
    enum Kind: Equatable { case kanaColumn, reactionPunctuation }
    struct Proposal {
        let original: NativeCoreMLRecognizedRegion
        let witnesses: [NativeCoreMLRecognizedRegion]
        let variants: [NativeCoreMLRecognitionRegion]
        let kind: Kind
        var regions: [NativeCoreMLRecognitionRegion] {
            variants + witnesses.map { .init(sourceIndex: $0.sourceIndex, polygon: $0.polygon) }
        }
    }

    static func proposals(_ reads: [NativeCoreMLRecognizedRegion], frame: NativeOCRRGBAFrame, startingID: Int) -> [Proposal] {
        guard reads.count <= 256, startingID >= 0, startingID <= Int.max - 16,
              reads.allSatisfy({ $0.sourceIndex >= 0 && $0.sourceIndex < startingID }),
              Set(reads.map(\.sourceIndex)).count == reads.count else { return [] }
        let frameBounds = CGRect(x: 0, y: 0, width: frame.width, height: frame.height)
        let boxes = reads.map { read -> CGRect? in
            guard read.polygon.count == 4, read.polygon.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
                  let b = NativeOCRScopeGeometry.bounds(for: read.polygon),
                  b.width.isFinite, b.height.isFinite, frameBounds.contains(b) else { return nil }
            return b
        }
        var result: [Proposal] = [], claimed = Set<Int>(), nextID = startingID
        for i in reads.indices {
            let read = reads[i]
            guard !claimed.contains(read.sourceIndex), let box = boxes[i],
                  box.width * box.height <= 150_000,
                  let plan = NativeCoreMLRecognitionPreprocessor.plan(polygon: read.polygon, dynamicWidth: true),
                  plan.bucket.width < 160 else { continue }
            var witnesses: [Int] = [], kind: Kind?
            if read.confidence >= 0.6, read.confidence < 0.9, (3...6).contains(read.text.count),
               read.text.unicodeScalars.allSatisfy(isCJK),
               read.text.unicodeScalars.contains(where: { kanaScript($0) != 0 }),
               read.text.unicodeScalars.contains(where: isHan),
               box.width >= 20, box.width <= 180, box.height >= box.width * 1.8, box.height <= box.width * 4.5 {
                let neighbors = reads.indices.filter { w in
                    guard w != i, !claimed.contains(reads[w].sourceIndex), reads[w].confidence >= 0.8,
                          (2...8).contains(reads[w].text.count), reads[w].text.unicodeScalars.allSatisfy(isCJK),
                          let b = boxes[w], b.width >= box.width * 0.65, b.width <= box.width * 1.5,
                          b.height >= box.height * 0.65, b.height <= box.height * 1.4,
                          b.height >= b.width * 1.7, abs(b.minY - box.minY) <= box.width * 0.3 else { return false }
                    let step = box.midX - b.midX
                    return step >= box.width * 0.7 && step <= box.width * 2.8
                }.sorted { boxes[$0]!.midX > boxes[$1]!.midX }
                if neighbors.count == 2, neighbors.contains(where: { reads[$0].confidence >= 0.95 }),
                   let near = boxes[neighbors[0]], let far = boxes[neighbors[1]] {
                    let a = box.midX - near.midX, b = near.midX - far.midX
                    if b >= box.width * 0.6, abs(a - b) <= max(a, b) * 0.25 {
                        witnesses = neighbors; kind = .kanaColumn
                    }
                }
            }
            if kind == nil, read.confidence >= 0.25, read.confidence < 0.65,
               (1...3).contains(read.text.count), read.text.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter) }) {
                let parents = reads.indices.filter { w in
                    guard w != i, !claimed.contains(reads[w].sourceIndex), reads[w].confidence >= 0.65,
                          (2...8).contains(reads[w].text.count), reads[w].text.unicodeScalars.allSatisfy(isCJK),
                          reads[w].text.unicodeScalars.contains(where: { kanaScript($0) != 0 }),
                          let body = boxes[w], body.height >= body.width * 1.5,
                          body.union(box).width * body.union(box).height <= 524_288 else { return false }
                    return box.midY >= body.minY + body.height * 0.7 && box.midY <= body.maxY + body.width * 0.5 &&
                        box.height <= body.height * 0.5 && box.width <= body.width * 1.2 &&
                        min(box.maxX, body.maxX) - max(box.minX, body.minX) >= min(box.width, body.width) * 0.6
                }
                if parents.count == 1 { witnesses = parents; kind = .reactionPunctuation }
            }
            guard let kind else { continue }
            let variants = [160, 192].map { minimum -> NativeCoreMLRecognitionRegion in
                defer { nextID += 1 }
                return .init(sourceIndex: nextID, polygon: read.polygon, minimumSequenceWidth: minimum)
            }
            result.append(.init(original: read, witnesses: witnesses.map { reads[$0] }, variants: variants, kind: kind))
            claimed.insert(read.sourceIndex)
            claimed.formUnion(witnesses.map { reads[$0].sourceIndex })
            // Four short variant crops and at most four cached witness crops.
            if result.count == 2 { break }
        }
        return result
    }

    static func replacement(_ proposal: Proposal, reads: [NativeCoreMLRecognizedRegion],
                            frame: NativeOCRRGBAFrame) -> NativeCoreMLRecognizedRegion? {
        guard Set(reads.map(\.sourceIndex)).count == reads.count,
              proposal.variants.count == 2,
              proposal.variants.map(\.minimumSequenceWidth) == [160, 192],
              Set(proposal.regions.map(\.sourceIndex)).count == proposal.regions.count,
              proposal.variants.allSatisfy({ $0.polygon == proposal.original.polygon }),
              proposal.witnesses.count == (proposal.kind == .kanaColumn ? 2 : 1) else { return nil }
        let byID = Dictionary(uniqueKeysWithValues: reads.map { ($0.sourceIndex, $0) })
        let variants = proposal.variants.compactMap { byID[$0.sourceIndex] }
        guard variants.count == 2, variants[0].text == variants[1].text,
              zip(variants, proposal.variants).allSatisfy({ $0.polygon == $1.polygon }) else { return nil }
        for original in proposal.witnesses {
            guard let witness = byID[original.sourceIndex], witness.text == original.text, witness.polygon == original.polygon,
                  witness.confidence >= max(proposal.kind == .kanaColumn ? 0.8 : 0.65, original.confidence - 0.03) else { return nil }
        }
        let text = variants[0].text
        let confidence = min(variants[0].confidence, variants[1].confidence)
        switch proposal.kind {
        case .kanaColumn:
            guard confidence >= 0.85, resolvesOneInteriorKana(original: proposal.original.text, replacement: text) else { return nil }
        case .reactionPunctuation:
            guard confidence >= 0.7, (2...3).contains(text.count), text.allSatisfy({ "!?！？".contains($0) }),
                  hasOwnedPunctuation(proposal, text: text, frame: frame) else { return nil }
        }
        return .init(sourceIndex: proposal.original.sourceIndex, polygon: proposal.original.polygon, text: text, confidence: confidence)
    }

    /// No dictionary substitution: both model variants must preserve every other
    /// character, including nonempty prefix and suffix. The changed glyph must
    /// join the script of an adjacent kana character already read originally.
    static func resolvesOneInteriorKana(original: String, replacement: String) -> Bool {
        let before = Array(original.unicodeScalars), after = Array(replacement.unicodeScalars)
        guard before.count == after.count, (3...6).contains(before.count) else { return false }
        let changes = before.indices.filter { before[$0] != after[$0] }
        guard changes.count == 1, let i = changes.first, i > 0, i < before.count - 1,
              isHan(before[i]), kanaScript(after[i]) != 0 else { return false }
        let script = kanaScript(after[i])
        return kanaScript(before[i - 1]) == script || kanaScript(before[i + 1]) == script
    }

    /// Invoke the reader's existing ownership predicate on a bounded copy of the
    /// original source pixels. Agreement cannot turn arbitrary ASCII/art into a
    /// punctuation region when the reader would reject its geometry or colour.
    private static func hasOwnedPunctuation(_ proposal: Proposal, text: String, frame: NativeOCRRGBAFrame) -> Bool {
        guard let witness = proposal.witnesses.first,
              let body = NativeOCRScopeGeometry.bounds(for: witness.polygon),
              let tail = NativeOCRScopeGeometry.bounds(for: proposal.original.polygon) else { return false }
        let crop = body.union(tail).insetBy(dx: -2, dy: -2).integral
            .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
        guard !crop.isNull, crop.width > 0, crop.height > 0,
              crop.width * crop.height <= 524_288 else { return false }
        let width = Int(crop.width), height = Int(crop.height), x0 = Int(crop.minX), y0 = Int(crop.minY)
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        for y in 0..<height {
            let source = (y0 + y) * frame.bytesPerRow + x0 * 4
            pixels.replaceSubrange(y * width * 4..<(y + 1) * width * 4, with: frame.bytes[source..<(source + width * 4)])
        }
        guard let provider = CGDataProvider(data: Data(pixels) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                  bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                  provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { return false }
        func region(_ read: NativeCoreMLRecognizedRegion, source: String, id: String) -> ReaderTranslationRegion {
            let b = NativeOCRScopeGeometry.bounds(for: read.polygon)!
            return .init(id: id, rect: CGRect(x: (b.minX - crop.minX) / crop.width, y: (b.minY - crop.minY) / crop.height,
                width: b.width / crop.width, height: b.height / crop.height), source: source,
                polygon: read.polygon.map { CGPoint(x: ($0.x - crop.minX) / crop.width, y: ($0.y - crop.minY) / crop.height) },
                confidence: read.confidence, sourceOrientation: .vertical)
        }
        let result = ReaderTranslationChromaticBalloon.attachingReactionPunctuation([
            region(witness, source: witness.text, id: "context-body"),
            region(proposal.original, source: text, id: "context-mark")], image: image)
        return result.count == 1 && result[0].id == "context-body" &&
            result[0].source == witness.text + text && !result[0].auxiliaryInkRects.isEmpty
    }

    private static func isHan(_ value: Unicode.Scalar) -> Bool { (0x3400...0x9FFF).contains(value.value) }
    private static func kanaScript(_ value: Unicode.Scalar) -> Int {
        if (0x3041...0x3096).contains(value.value) { return 1 }
        if (0x30A1...0x30FA).contains(value.value) { return 2 }
        return 0
    }
    private static func isCJK(_ value: Unicode.Scalar) -> Bool { isHan(value) || kanaScript(value) != 0 }
}
