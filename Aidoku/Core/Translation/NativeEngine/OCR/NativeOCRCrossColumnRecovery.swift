import CoreGraphics
import Foundation

/// A detector can connect the first glyphs of neighbouring vertical columns
/// into one horizontal row. Re-read each complete column before accepting a
/// split; never distribute a row's recognized characters by geometry alone.
@available(iOS 18.0, *)
enum NativeOCRCrossColumnRecovery {
    struct Proposal {
        let row: NativeCoreMLRecognizedRegion
        let anchors: [NativeCoreMLRecognizedRegion]
        let regions: [NativeCoreMLRecognitionRegion]
    }

    static func proposals(_ reads: [NativeCoreMLRecognizedRegion]) -> [Proposal] {
        guard reads.count <= 256 else { return [] }
        let boxes = reads.map { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
        var result: [Proposal] = [], claimed = Set<Int>()
        for (index, row) in reads.enumerated() {
            let letters = Array(row.text)
            guard (2...4).contains(letters.count), row.confidence >= 0.75,
                  row.text.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) }),
                  let box = boxes[index], box.width >= box.height * 1.6,
                  box.width <= box.height * CGFloat(letters.count) * 1.5 else { continue }
            let candidates = reads.indices.filter { other in
                guard other != index, !claimed.contains(reads[other].sourceIndex), let b = boxes[other],
                      NativeOCRGapLineRecovery.flanks(reads[other].text), b.height >= b.width * 3,
                      b.width >= box.height * 0.7, b.width <= box.height * 1.3,
                      b.minY >= box.minY + box.height * 0.4, b.minY <= box.maxY + box.height * 0.25,
                      b.midX >= box.minX, b.midX <= box.maxX else { return false }
                return true
            }.sorted { boxes[$0]!.midX < boxes[$1]!.midX }
            guard candidates.count == letters.count else { continue }
            let anchors = candidates.map { reads[$0] }
            let columns = candidates.map { boxes[$0]! }
            guard zip(columns, columns.dropFirst()).allSatisfy({ a, b in
                let pitch = b.midX - a.midX, thin = min(a.width, b.width)
                return pitch >= thin * 0.7 && pitch <= thin * 1.4 && abs(a.minY - b.minY) <= thin * 0.3
            }) else { continue }
            let regions = zip(anchors, columns).map { anchor, column in
                let b = CGRect(x: column.minX, y: box.minY, width: column.width, height: column.maxY - box.minY)
                return NativeCoreMLRecognitionRegion(sourceIndex: anchor.sourceIndex,
                    polygon: [CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                              CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)])
            }
            guard claimed.count + anchors.count <= 8 else { continue }
            result.append(Proposal(row: row, anchors: anchors, regions: regions))
            claimed.formUnion(anchors.map(\.sourceIndex))
            if result.reduce(0, { $0 + $1.regions.count }) >= 8 { break }
        }
        return result
    }

    static func replacements(_ proposal: Proposal, reads: [NativeCoreMLRecognizedRegion]) -> [NativeCoreMLRecognizedRegion]? {
        func compact(_ text: String) -> String {
            // A truncated column often loses the distinction between small and
            // full-size kana; compare that distinction loosely without changing
            // any character in the confirmed full-column recognition.
            let small = Array("ぁぃぅぇぉっゃゅょゎァィゥェォッャュョヮ")
            let full = Array("あいうえおつやゆよわアイウエオツヤユヨワ")
            return String(text.filter { $0.isLetter || $0.isNumber }.map { character in
                small.firstIndex(of: character).map { full[$0] } ?? character
            })
        }
        let headers = Array(proposal.row.text)
        var result: [NativeCoreMLRecognizedRegion] = []
        for (offset, anchor) in proposal.anchors.enumerated() {
            guard let read = reads.first(where: { $0.sourceIndex == anchor.sourceIndex }), read.confidence >= 0.75 else { return nil }
            let text = compact(read.text), suffix = compact(anchor.text)
            guard text.count >= suffix.count + 1, text.hasPrefix(String(headers[offset])), text.hasSuffix(suffix) else { return nil }
            result.append(read)
        }
        return result
    }
}


/// Tightly spaced vertical lettering can be detected as several overlapping horizontal
/// rows. Reconstruct columns only for a repeated grid on a Japanese vertical page,
/// then require an independent full-column read to confirm the observed characters.
@available(iOS 18.0, *)
enum NativeOCRGridColumnRecovery {
    struct Proposal {
        let replaced: Set<Int>
        let regions: [NativeCoreMLRecognitionRegion]
        let evidence: [String]
        let suffixes: [String]
        let suffixScores: [Double]
        let pixelAdded: Set<Int>
        let singleRow: Bool

        init(replaced: Set<Int>, regions: [NativeCoreMLRecognitionRegion], evidence: [String],
             suffixes: [String], suffixScores: [Double], pixelAdded: Set<Int> = [], singleRow: Bool = false) {
            self.replaced = replaced
            self.regions = regions
            self.evidence = evidence
            self.suffixes = suffixes
            self.suffixScores = suffixScores
            self.pixelAdded = pixelAdded
            self.singleRow = singleRow
        }
    }

    /// Refine an established multi-row grid with pixels from the same page. The
    /// detector may stop after the first three glyphs and omit its leftmost
    /// column entirely. A repeated ink colour with a bright enclosing stroke
    /// supplies a bounded full-height crop; recognition still has to confirm it.
    static func pixelRefined(_ proposal: Proposal, reads: [NativeCoreMLRecognizedRegion],
                             frame: NativeOCRRGBAFrame, addedID: Int, verticalSeed: CGRect? = nil,
                             includeLeft: Bool = true, minimumActive: CGFloat = 1.5,
                             preferDarkInk: Bool = false) -> Proposal? {
        let count = proposal.regions.count
        guard (verticalSeed == nil ? 4...8 : 3...8).contains(count),
              proposal.replaced.count >= (proposal.singleRow ? 1 : 2) else { return nil }
        let seed = verticalSeed ?? reads.compactMap({ read -> CGRect? in
                  guard proposal.replaced.contains(read.sourceIndex),
                        let box = NativeOCRScopeGeometry.bounds(for: read.polygon),
                        box.width >= box.height * 1.6, box.width / CGFloat(count) >= box.height * 0.6,
                        box.width / CGFloat(count) <= box.height * 1.1 else { return nil }
                  return box
              }).min(by: { $0.minY < $1.minY })
        guard let seed else { return nil }
        let pitch = seed.width / CGFloat(count)
        let left = max(0, Int(floor(seed.minX - pitch * 1.15)))
        let right = min(frame.width, Int(ceil(seed.maxX + pitch * 0.15)))
        let top = max(0, Int(floor(seed.minY - pitch * 0.15)))
        let bottom = min(frame.height, Int(ceil(seed.minY + pitch * 16)))
        let width = right - left, height = bottom - top
        guard width > 0, height > 0, width * height <= 900_000 else { return nil }
        // An optional missing column needs exterior room; the established
        // columns do not. A page-edge seed must still get its full-height read.
        let scanLeftColumn = includeLeft && left < Int(seed.minX - pitch * 0.65)
        let stride = width + 1
        var white = [Int32](repeating: 0, count: stride * (height + 1))
        frame.bytes.withUnsafeBufferPointer { bytes in
            for y in 0..<height {
                var row: Int32 = 0
                for x in 0..<width {
                    let p = (top + y) * frame.bytesPerRow + (left + x) * 4
                    let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
                    if min(r, g, b) >= 230 && max(r, g, b) - min(r, g, b) <= 30 { row += 1 }
                    white[(y + 1) * stride + x + 1] = white[y * stride + x + 1] + row
                }
            }
        }
        func nearWhite(_ x: Int, _ y: Int) -> Bool {
            let x0 = max(0, x - 6), x1 = min(width, x + 7)
            let y0 = max(0, y - 6), y1 = min(height, y + 7)
            return white[y1 * stride + x1] - white[y0 * stride + x1]
                - white[y1 * stride + x0] + white[y0 * stride + x0] > 0
        }
        var histogram = [Int](repeating: 0, count: 4096), samples = 0
        var darkHistogram = [Int](repeating: 0, count: 4096), darkSamples = 0
        let seedX0 = max(0, Int(seed.minX) - left), seedX1 = min(width, Int(ceil(seed.maxX)) - left)
        let seedY0 = max(0, Int(seed.minY) - top), seedY1 = min(height, Int(ceil(seed.maxY)) - top)
        frame.bytes.withUnsafeBufferPointer { bytes in
            for y in seedY0..<seedY1 {
                for x in seedX0..<seedX1 {
                    let p = (top + y) * frame.bytesPerRow + (left + x) * 4
                    let r = Int(bytes[p]), g = Int(bytes[p + 1]), b = Int(bytes[p + 2])
                    guard max(r, g, b) < 190,
                          max(r, g, b) - min(r, g, b) >= 40 || max(r, g, b) < 100,
                          nearWhite(x, y) else { continue }
                    let bin = (r / 16) * 256 + (g / 16) * 16 + b / 16
                    histogram[bin] += 1
                    if max(r, g, b) < 100 {
                        darkHistogram[bin] += 1
                        darkSamples += 1
                    }
                    samples += 1
                }
            }
        }
        guard let defaultMode = histogram.indices.max(by: { histogram[$0] < histogram[$1] }),
              histogram[defaultMode] >= max(20, samples / 12) else { return nil }
        let darkMode = darkHistogram.indices.max(by: { darkHistogram[$0] < darkHistogram[$1] }) ?? 0
        let mode = preferDarkInk && darkSamples >= 80 && darkHistogram[darkMode] >= max(40, darkSamples / 3)
            ? darkMode : defaultMode
        let ink = [(mode / 256) * 16 + 8, ((mode / 16) % 16) * 16 + 8, (mode % 16) * 16 + 8]
        var marked = [Bool](repeating: false, count: width * height)
        frame.bytes.withUnsafeBufferPointer { bytes in
            for y in 0..<height {
                for x in 0..<width {
                    let p = (top + y) * frame.bytesPerRow + (left + x) * 4
                    if abs(Int(bytes[p]) - ink[0]) <= 36 && abs(Int(bytes[p + 1]) - ink[1]) <= 36 &&
                        abs(Int(bytes[p + 2]) - ink[2]) <= 36 && nearWhite(x, y) {
                        marked[y * width + x] = true
                    }
                }
            }
        }
        var boxes: [(column: Int, box: CGRect)] = []
        for column in (scanLeftColumn ? -1 : 0)..<count {
            let x0 = max(0, Int(round(seed.minX + CGFloat(column) * pitch)) - left)
            let x1 = min(width, Int(round(seed.minX + CGFloat(column + 1) * pitch)) - left)
            guard x1 > x0 else { return nil }
            var first = -1, last = -1, active = 0, gap = 0
            for y in seedY0..<height {
                var pixels = 0
                for x in x0..<x1 where marked[y * width + x] { pixels += 1 }
                if pixels >= 2 {
                    if first < 0 { first = y }
                    last = y
                    active += 1
                    gap = 0
                } else if first >= 0 {
                    gap += 1
                    // Outlined glyph rows can leave nearly one full character
                    // pitch of empty pixels between small kana and the next
                    // glyph. A larger blank gap still ends this column.
                    if CGFloat(gap) > pitch * 0.9 { break }
                }
            }
            guard first >= 0, last >= first, CGFloat(first - seedY0) <= pitch * (verticalSeed == nil ? 0.4 : 0.6),
                  CGFloat(active) >= pitch * minimumActive else {
                if column == -1 { continue }
                return nil
            }
            var minX = width, maxX = 0, minY = height, maxY = 0
            for y in first...last {
                for x in x0..<x1 where marked[y * width + x] {
                    minX = min(minX, x); maxX = max(maxX, x)
                    minY = min(minY, y); maxY = max(maxY, y)
                }
            }
            let box = CGRect(x: max(0, left + minX - 4), y: max(0, top + minY - 6),
                             width: min(frame.width, left + maxX + 6) - max(0, left + minX - 4),
                             height: min(frame.height, top + maxY + 7) - max(0, top + minY - 6))
            boxes.append((column, box))
        }
        guard boxes.count >= count else { return nil }
        var regions: [NativeCoreMLRecognitionRegion] = [], evidence: [String] = [], suffixes: [String] = [], scores: [Double] = []
        var added = Set<Int>()
        for (column, box) in boxes {
            let id = column < 0 ? addedID : proposal.regions[column].sourceIndex
            regions.append(.init(sourceIndex: id, polygon: [CGPoint(x: box.minX, y: box.minY),
                CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]))
            if column < 0 {
                added.insert(id); evidence.append(""); suffixes.append(""); scores.append(0)
            } else {
                evidence.append(proposal.evidence[column])
                suffixes.append(proposal.suffixes[column])
                scores.append(proposal.suffixScores[column])
            }
        }
        return Proposal(replaced: proposal.replaced, regions: regions, evidence: evidence,
                        suffixes: suffixes, suffixScores: scores, pixelAdded: added,
                        singleRow: proposal.singleRow)
    }

    /// Short, aligned vertical reads may all stop at the detector's common
    /// bottom even though their glyphs continue. Require three independently
    /// read columns before asking the pixel scanner for longer crops.
    static func shortVerticalProposals(_ reads: [NativeCoreMLRecognizedRegion],
                                       frame: NativeOCRRGBAFrame, startingID: Int) -> [Proposal] {
        guard reads.count <= 256 else { return [] }
        let boxes = reads.map { NativeOCRScopeGeometry.bounds(for: $0.polygon) ?? .null }
        let candidates = reads.indices.filter { index in
            let b = boxes[index], text = reads[index].text
            return reads[index].confidence >= 0.85 && b.width >= 30 &&
                b.height >= b.width * 1.8 && b.height <= b.width * 4.5 &&
                (2...8).contains(text.count) && text.unicodeScalars.contains {
                    (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                }
        }.sorted { boxes[$0].midX < boxes[$1].midX }
        var claimed = Set<Int>(), proposals: [Proposal] = []
        for first in candidates {
            let origin = boxes[first]
            let row = candidates.filter { index in
                let box = boxes[index]
                return box.midX >= origin.midX && box.midX <= origin.midX + origin.width * 3.5 &&
                    abs(box.minY - origin.minY) <= origin.width * 0.35
            }
            guard row.count >= 3 else { continue }
            let indices = Array(row.prefix(3))
            guard indices.allSatisfy({ !claimed.contains(reads[$0].sourceIndex) }) else { continue }
            let columns = indices.map { boxes[$0] }
            let step1 = columns[1].midX - columns[0].midX
            let step2 = columns[2].midX - columns[1].midX
            let pitch = (step1 + step2) / 2
            guard pitch >= 30, pitch <= 140, abs(step1 - step2) <= pitch * 0.25,
                  zip(columns, columns.dropFirst()).allSatisfy({ left, right in
                      let width = min(left.width, right.width)
                      return right.midX - left.midX >= width * 0.6 &&
                          right.midX - left.midX <= max(left.width, right.width) * 1.3 &&
                          abs(right.minY - left.minY) <= pitch * 0.3 &&
                          right.height >= left.height * 0.7 && right.height <= left.height * 1.4
                  }) else { continue }
            let top = columns.map(\.minY).min() ?? 0
            let seed = CGRect(x: columns[0].minX, y: top, width: pitch * 3, height: pitch)
            let anchors = indices.map { reads[$0] }
            let original = Proposal(replaced: Set(anchors.map(\.sourceIndex)),
                regions: anchors.map { .init(sourceIndex: $0.sourceIndex, polygon: $0.polygon) },
                evidence: anchors.map(\.text), suffixes: Array(repeating: "", count: 3),
                suffixScores: Array(repeating: 0, count: 3))
            guard let refined = pixelRefined(original, reads: reads, frame: frame,
                                             addedID: startingID + proposals.count, verticalSeed: seed),
                  refined.regions.count >= 3 else { continue }
            // A weak, wide detector read can straddle the omitted column and
            // the first known column. Once both are independently re-read,
            // retaining that old fragment duplicates their text in the merge.
            let refinedBoxes = refined.regions.compactMap { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
            let straddlers = reads.indices.filter { index in
                guard !original.replaced.contains(reads[index].sourceIndex), reads[index].confidence < 0.85 else { return false }
                let box = boxes[index]
                guard !box.isNull, box.width <= pitch * 2.2,
                      abs(box.minY - seed.minY) <= pitch * 0.4 else { return false }
                return refinedBoxes.contains { full in
                    NativeOCRScopeGeometry.intersectionArea(box, full) >= min(box.width * box.height,
                        full.width * full.height) * 0.4
                }
            }
            let replaced = refined.replaced.union(straddlers.map { reads[$0].sourceIndex })
            proposals.append(Proposal(replaced: replaced, regions: refined.regions,
                evidence: refined.evidence, suffixes: refined.suffixes,
                suffixScores: refined.suffixScores, pixelAdded: refined.pixelAdded))
            claimed.formUnion(replaced)
            if proposals.count >= 4 { break }
        }
        return proposals
    }

    /// A single wide OCR row can contain the first glyph of several outlined
    /// vertical columns. Pixel continuity supplies each column's lower extent;
    /// the recognizer must then confirm every first glyph and complete column.
    static func singleRowProposals(_ reads: [NativeCoreMLRecognizedRegion],
                                   frame: NativeOCRRGBAFrame, startingID: Int) -> [Proposal] {
        guard reads.count <= 256, reads.contains(where: { read in
            guard let b = NativeOCRScopeGeometry.bounds(for: read.polygon) else { return false }
            return b.height >= b.width * 3 && read.confidence >= 0.9 &&
                read.text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        }) else { return [] }
        var proposals: [Proposal] = [], claimed = Set<Int>()
        for read in reads {
            let characters = Array(read.text)
            guard !claimed.contains(read.sourceIndex), read.confidence >= 0.9,
                  (4...7).contains(characters.count),
                  read.text.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) ||
                      (0x3400...0x9FFF).contains($0.value) }),
                  let seed = NativeOCRScopeGeometry.bounds(for: read.polygon) else { continue }
            let pitch = seed.width / CGFloat(characters.count)
            guard seed.width >= seed.height * 3, pitch >= seed.height * 0.6,
                  pitch <= seed.height * 1.1 else { continue }
            let base = startingID + proposals.count * 10
            let initial = Proposal(replaced: [read.sourceIndex], regions: characters.indices.map { column in
                let x = seed.minX + CGFloat(column) * pitch
                let box = CGRect(x: x, y: seed.minY, width: pitch, height: seed.height)
                return .init(sourceIndex: base + column, polygon: [CGPoint(x: box.minX, y: box.minY),
                    CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.maxY),
                    CGPoint(x: box.minX, y: box.maxY)])
            }, evidence: characters.map(String.init),
                suffixes: Array(repeating: "", count: characters.count),
                suffixScores: Array(repeating: 0, count: characters.count), singleRow: true)
            guard let refined = pixelRefined(initial, reads: reads, frame: frame, addedID: base + 8,
                verticalSeed: seed, includeLeft: false, minimumActive: 1.2),
                  refined.regions.count == characters.count else { continue }
            let fullBoxes = refined.regions.compactMap { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
            let union = fullBoxes.reduce(CGRect.null) { $0.union($1) }
            let fragments = reads.compactMap { candidate -> Int? in
                guard candidate.sourceIndex != read.sourceIndex,
                      let box = NativeOCRScopeGeometry.bounds(for: candidate.polygon),
                      !box.isNull else { return nil }
                let shared = NativeOCRScopeGeometry.intersectionArea(box, union)
                let owned = shared >= box.width * box.height * 0.55 &&
                    box.minY >= union.minY - pitch * 0.4 && box.maxY <= union.maxY + pitch * 0.4
                let weakStraddler = candidate.confidence < 0.75 &&
                    shared >= min(box.width * box.height, union.width * union.height) * 0.4
                return owned || weakStraddler ? candidate.sourceIndex : nil
            }
            let replaced = refined.replaced.union(fragments)
            proposals.append(Proposal(replaced: replaced, regions: refined.regions,
                evidence: refined.evidence, suffixes: refined.suffixes,
                suffixScores: refined.suffixScores, singleRow: true))
            claimed.formUnion(replaced)
            if proposals.count >= 2 { break }
        }
        return proposals
    }

    /// A bottom row sometimes contains only the final character of each
    /// vertical column. A complete neighboring column supplies the common top
    /// boundary; the bottom characters must survive every full-column reread.
    static func tailRowProposals(_ reads: [NativeCoreMLRecognizedRegion],
                                 frame: NativeOCRRGBAFrame, startingID: Int) -> [Proposal] {
        guard reads.count <= 256 else { return [] }
        let bounds = reads.map { NativeOCRScopeGeometry.bounds(for: $0.polygon) ?? .null }
        var proposals: [Proposal] = [], claimed = Set<Int>()
        for (index, row) in reads.enumerated() {
            let box = bounds[index], letters = Array(row.text), count = letters.count
            guard !claimed.contains(row.sourceIndex), row.confidence >= 0.95,
                  (3...5).contains(count), !box.isNull,
                  box.width >= box.height * 2.2,
                  row.text.unicodeScalars.allSatisfy({ (0x3040...0x30FF).contains($0.value) ||
                      (0x3400...0x9FFF).contains($0.value) }) else { continue }
            let pitch = box.width / CGFloat(count)
            guard pitch >= 30, pitch <= 140, pitch >= box.height * 0.6,
                  pitch <= box.height * 1.1 else { continue }
            let anchored = reads.indices.filter { candidate in
                let left = bounds[candidate]
                return candidate != index && !left.isNull && reads[candidate].confidence >= 0.9 &&
                    left.height >= pitch * 3 && left.width >= pitch * 0.7 && left.width <= pitch * 1.45 &&
                    left.midX < box.minX && box.minX - left.maxX <= pitch * 0.4 &&
                    box.minX - left.maxX >= -pitch * 0.3 &&
                    box.minY - left.minY >= pitch * 2.5 &&
                    abs(box.maxY - left.maxY) <= pitch * 1.2 &&
                    reads[candidate].text.count >= 3
            }
            guard anchored.count == 1 else { continue }
            let anchor = bounds[anchored[0]]
            let seed = CGRect(x: box.minX, y: anchor.minY, width: box.width, height: pitch)
            let base = startingID + proposals.count * 10
            let initial = Proposal(replaced: [row.sourceIndex], regions: letters.indices.map { column in
                let x = box.minX + CGFloat(column) * pitch
                let cell = CGRect(x: x, y: seed.minY, width: pitch, height: pitch)
                return .init(sourceIndex: base + column, polygon: [CGPoint(x: cell.minX, y: cell.minY),
                    CGPoint(x: cell.maxX, y: cell.minY), CGPoint(x: cell.maxX, y: cell.maxY),
                    CGPoint(x: cell.minX, y: cell.maxY)])
            }, evidence: Array(repeating: "", count: count), suffixes: letters.map(String.init),
                suffixScores: Array(repeating: row.confidence, count: count), singleRow: true)
            guard let refined = pixelRefined(initial, reads: reads, frame: frame, addedID: base + 8,
                verticalSeed: seed, includeLeft: false, minimumActive: 2, preferDarkInk: true),
                refined.regions.count == count else { continue }
            // The footer read is an independently observed lower bound for
            // every column. Dark illustration below it can look like glyph
            // ink, so do not let the pixel scan enlarge the OCR crop into art.
            let foot = min(CGFloat(frame.height), box.maxY + pitch * 0.4)
            let clipped = refined.regions.compactMap { region -> NativeCoreMLRecognitionRegion? in
                guard let rectangle = NativeOCRScopeGeometry.bounds(for: region.polygon),
                      rectangle.minY < foot else { return nil }
                let bottom = min(rectangle.maxY, foot)
                return .init(sourceIndex: region.sourceIndex, polygon: [
                    CGPoint(x: rectangle.minX, y: rectangle.minY), CGPoint(x: rectangle.maxX, y: rectangle.minY),
                    CGPoint(x: rectangle.maxX, y: bottom), CGPoint(x: rectangle.minX, y: bottom)
                ])
            }
            guard clipped.count == count else { continue }
            proposals.append(Proposal(replaced: refined.replaced, regions: clipped,
                evidence: refined.evidence, suffixes: refined.suffixes,
                suffixScores: refined.suffixScores, singleRow: true))
            claimed.insert(row.sourceIndex)
            if proposals.count >= 2 { break }
        }
        return proposals
    }

    static func proposals(_ reads: [NativeCoreMLRecognizedRegion], width: Int, height: Int, startingID: Int = 0) -> [Proposal] {
        func japanese(_ text: String) -> Bool {
            text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
        }
        guard reads.count <= 256, reads.contains(where: {
            guard let b = NativeOCRScopeGeometry.bounds(for: $0.polygon) else { return false }
            return b.height >= b.width * 3 && japanese($0.text) && $0.confidence >= 0.85
        }) else { return [] }
        // A short horizontal numeral (e.g. 10) occupies one cell in vertical
        // Japanese text. The neighbouring rows must independently agree on pitch.
        func cells(_ text: String) -> [String] {
            var result: [String] = []
            for c in text {
                let digit = c >= "0" && c <= "9"
                if digit, let last = result.last, last.count < 3,
                   last.allSatisfy({ $0 >= "0" && $0 <= "9" }) {
                    result[result.count - 1].append(c)
                } else { result.append(String(c)) }
            }
            return result
        }
        let tokens = reads.map { cells($0.text) }
        let boxes = reads.map { NativeOCRScopeGeometry.bounds(for: $0.polygon) ?? .null }
        let candidates = reads.indices.filter {
            let b = boxes[$0], text = reads[$0].text
            return reads[$0].confidence >= 0.65 && (2...7).contains(tokens[$0].count) &&
                text.unicodeScalars.allSatisfy { (0x3000...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value) ||
                    CharacterSet.punctuationCharacters.contains($0) || (0x30...0x39).contains($0.value) } &&
                b.width >= b.height * 1.6 && b.width <= b.height * CGFloat(tokens[$0].count) * 1.3
        }.sorted { boxes[$0].minY < boxes[$1].minY }
        // Reserve detector IDs even when their reads were rejected or deferred.
        var claimed = Set<Int>(), result: [Proposal] = []
        var nextID = max(startingID, (reads.map(\.sourceIndex).max() ?? 0) + 1)
        var columnCount = 0
        for first in candidates where !claimed.contains(first) {
            let a = boxes[first], count = tokens[first].count, pitch = a.width / CGFloat(count)
            guard reads[first].confidence >= 0.75, count >= 3, pitch >= a.height * 0.6, pitch <= a.height * 1.1 else { continue }
            // Establish an overlapping pair first. Later rows may omit leading
            // columns or have a larger gap, but must stay on the same column lattice.
            var rows = [first]
            for j in candidates where j != first && !claimed.contains(j) {
                let b = boxes[j], previous = boxes[rows.last!]
                guard b.minY > previous.minY + a.height * 0.35,
                      b.minY < previous.minY + a.height * (rows.count >= 2 ? 1.5 : 0.9),
                      b.height >= a.height * 0.7, b.height <= a.height * 1.4,
                      abs((b.minX - a.minX) / pitch - ((b.minX - a.minX) / pitch).rounded()) <= 0.45,
                      b.minX >= a.minX - pitch * 0.45,
                      Int(((b.minX - a.minX) / pitch).rounded()) + tokens[j].count <= count,
                      abs(b.width / CGFloat(tokens[j].count) - pitch) <= pitch * 0.25,
                      tokens[j].count <= count else { continue }
                rows.append(j)
            }
            guard rows.count >= 2, columnCount + count <= 32 else { continue }
            var envelope = rows.reduce(a) { $0.union(boxes[$1]) }
            // A rejected multi-column envelope or an accepted continuation supplies
            // the bottom extent; do not borrow a neighbouring paragraph's bounds.
            let continuations = reads.indices.filter { j in
                let b = boxes[j]
                return !rows.contains(j) && b.minX >= envelope.minX - pitch * 0.6 &&
                    b.maxX <= envelope.maxX + pitch * 0.6 && b.minY >= envelope.minY + pitch &&
                    b.minY <= envelope.maxY + pitch * 0.5 && b.maxY <= envelope.maxY + pitch * (b.height >= b.width * 2.5 ? 10 : 4)
            }
            let tails = continuations.filter { reads[$0].text.count >= 2 && boxes[$0].height >= boxes[$0].width * 1.5 && boxes[$0].width <= pitch * 1.8 }
            guard rows.count >= 3 || tails.count >= 2 else { continue }
            for j in continuations { envelope = envelope.union(boxes[j]) }
            guard envelope.height <= pitch * 16 else { continue }
            let replaced = Set((rows + continuations).map { reads[$0].sourceIndex })
            var regions: [NativeCoreMLRecognitionRegion] = [], evidence: [String] = [], suffixes: [String] = [], suffixScores: [Double] = []
            for column in 0..<count {
                let x = a.minX + CGFloat(column) * pitch
                let tail = tails.first { abs(boxes[$0].midX - (x + pitch / 2)) <= pitch * 0.45 }
                // A shorter column must stop at its own observed continuation;
                // extending every crop to the longest column reads neighbouring tails.
                let bottom = tail.map { max(rows.map { boxes[$0].maxY }.max() ?? a.maxY, boxes[$0].maxY) } ?? envelope.maxY
                let b = CGRect(x: max(0, x - pitch * 0.12), y: max(0, a.minY - pitch * 0.1),
                    width: pitch * 1.24, height: bottom - a.minY + pitch * 0.2)
                    .intersection(CGRect(x: 0, y: 0, width: width, height: height))
                regions.append(.init(sourceIndex: nextID, polygon: [CGPoint(x: b.minX, y: b.minY),
                    CGPoint(x: b.maxX, y: b.minY), CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)]))
                evidence.append(rows.compactMap { index -> String? in
                    let characters = tokens[index]
                    let offset = Int(((boxes[index].minX - a.minX) / pitch).rounded())
                    let local = column - offset
                    return local >= 0 && local < characters.count ? characters[local] : nil
                }.joined())
                suffixes.append(tail.map { reads[$0].text } ?? "")
                suffixScores.append(tail.map { reads[$0].confidence } ?? 0)
                nextID += 1
            }
            result.append(Proposal(replaced: replaced, regions: regions, evidence: evidence, suffixes: suffixes, suffixScores: suffixScores))
            claimed.formUnion(rows + continuations); columnCount += count
        }
        return result
    }

    static func replacements(_ proposal: Proposal, reads: [NativeCoreMLRecognizedRegion]) -> [NativeCoreMLRecognizedRegion]? {
        var result: [NativeCoreMLRecognizedRegion] = []
        for (column, region) in proposal.regions.enumerated() {
            guard let read = reads.first(where: { $0.sourceIndex == region.sourceIndex }), read.confidence >= 0.8 else { return nil }
            if proposal.pixelAdded.contains(region.sourceIndex) {
                guard read.confidence >= 0.9, read.text.count >= 5,
                      read.text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) ||
                          (0x3400...0x9FFF).contains($0.value) }) else { return nil }
                result.append(read)
                continue
            }
            let observed = Array(proposal.evidence[column]), full = Array(read.text)
            let suffix = proposal.suffixes[column]
            guard observed.count >= (proposal.singleRow ? 1 : 2) || !suffix.isEmpty,
                  full.count >= (proposal.singleRow ? 2 : observed.count),
                  !proposal.singleRow || read.confidence >= 0.8 else { return nil }
            // Small kana and occasional row misreads can differ, but every column
            // must independently retain the majority of its observed top glyphs.
            func comparable(_ character: Character) -> String {
                String(character).decomposedStringWithCanonicalMapping
                    .replacingOccurrences(of: "\u{3099}", with: "").replacingOccurrences(of: "\u{309A}", with: "")
            }
            let matching = zip(observed, full).filter { comparable($0) == comparable($1) }.count
            guard matching * 3 >= observed.count * 2 else { return nil }
            if !suffix.isEmpty {
                let suffixLetters = suffix.filter { $0.isLetter || $0.isNumber }
                let fullLetters = read.text.filter { $0.isLetter || $0.isNumber }
                // A continuation must survive too; a good prefix cannot authorize
                // deleting the remainder of an already recognized column.
                if !fullLetters.hasSuffix(suffixLetters) {
                    let correctedNumericHead = proposal.evidence[column].contains(where: { $0 >= "0" && $0 <= "9" })
                        && matching == observed.count && read.confidence >= max(0.95, proposal.suffixScores[column])
                        && suffixLetters.count >= 4 && fullLetters.count >= suffixLetters.count + 2
                        && fullLetters.hasSuffix(suffixLetters.dropFirst())
                    if correctedNumericHead { result.append(read); continue }
                    let japaneseSuffix = String(suffixLetters.unicodeScalars.filter {
                        (0x3040...0x30FF).contains($0.value) || (0x3400...0x9FFF).contains($0.value)
                    })
                    // A weak Latin hallucination in a Japanese continuation is not
                    // a trustworthy suffix. Its Japanese ending must still survive.
                    guard proposal.suffixScores[column] < 0.85, observed.count >= 2,
                          read.confidence >= max(0.85, proposal.suffixScores[column] + 0.1),
                          !japaneseSuffix.isEmpty, japaneseSuffix.count < suffixLetters.count,
                          fullLetters.hasSuffix(japaneseSuffix) else { return nil }
                }
            }
            result.append(read)
        }
        return result
    }
}
