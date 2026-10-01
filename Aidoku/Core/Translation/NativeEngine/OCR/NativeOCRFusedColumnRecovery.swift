import CoreGraphics
import Foundation

/// A wide vertical detection can swallow adjacent columns and recognize just one of them.
/// Split only repeated dark glyph bands on light paper, then independently confirm every crop.
@available(iOS 18.0, *)
enum NativeOCRFusedColumnRecovery {
    struct Proposal {
        let original: NativeCoreMLRecognizedRegion
        let regions: [NativeCoreMLRecognitionRegion]
        var fusedOwner: Int? = nil
    }

    static func proposals(_ reads: [NativeCoreMLRecognizedRegion], frame: NativeOCRRGBAFrame,
                          startingID: Int) -> [Proposal] {
        guard reads.count <= 256 else { return [] }
        var result: [Proposal] = [], nextID = max(startingID, (reads.map(\.sourceIndex).max() ?? 0) + 1)
        var anchors: [Proposal] = []
        var scannedPixels = 0
        for read in reads {
            guard read.confidence >= 0.65, (2...32).contains(read.text.count),
                  read.text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }),
                  let box = NativeOCRScopeGeometry.bounds(for: read.polygon),
                  box.width >= 50, box.width <= 400, box.height >= box.width * 1.2,
                  box.height <= box.width * 3.2 else { continue }
            let x0 = max(0, Int(box.minX)), x1 = min(frame.width, Int(ceil(box.maxX)))
            let y0 = max(0, Int(box.minY)), y1 = min(frame.height, Int(ceil(box.maxY)))
            let width = x1 - x0, height = y1 - y0
            guard width > 0, height > 0, width * height <= 250_000, scannedPixels + width * height <= 1_000_000 else { continue }
            scannedPixels += width * height
            var mask = [Bool](repeating: false, count: width * height)
            var dark = [Int](repeating: 0, count: width)
            var light = [Int](repeating: 0, count: width)
            frame.bytes.withUnsafeBufferPointer { bytes in
                for y in y0..<y1 {
                    for x in x0..<x1 {
                        let p = y * frame.bytesPerRow + x * 4
                        if max(bytes[p], bytes[p + 1], bytes[p + 2]) < 110 { mask[(y - y0) * width + x - x0] = true }
                        if min(bytes[p], bytes[p + 1], bytes[p + 2]) > 220 { light[x - x0] += 1 }
                    }
                }
            }
            // Exclude outline/rule ink touching the detector crop boundary.
            // Only complete internal glyphs can establish a separate column.
            var queue: [Int] = []
            func seed(_ index: Int) {
                if mask[index] { mask[index] = false; queue.append(index) }
            }
            for x in 0..<width { seed(x); seed((height - 1) * width + x) }
            for y in 0..<height { seed(y * width); seed(y * width + width - 1) }
            var cursor = 0
            while cursor < queue.count {
                let index = queue[cursor], x = index % width, y = index / width
                cursor += 1
                for dy in -1...1 {
                    for dx in -1...1 {
                        let xx = x + dx, yy = y + dy
                        if xx >= 0 && xx < width && yy >= 0 && yy < height { seed(yy * width + xx) }
                    }
                }
            }
            for y in 0..<height {
                for x in 0..<width where mask[y * width + x] { dark[x] += 1 }
            }
            let threshold = max(4, Int(CGFloat(height) * 0.035))
            var spans: [Range<Int>] = [], start: Int?
            for x in 0...width {
                if x < width && dark[x] >= threshold {
                    if start == nil { start = x }
                } else if let first = start {
                    spans.append(first..<x); start = nil
                }
            }
            let candidates = spans.filter { span in
                span.lowerBound > 1 && span.upperBound < width - 1 &&
                    CGFloat(span.count) >= box.width * 0.12 && CGFloat(span.count) <= box.width * 0.36 &&
                    light[span].reduce(0, +) * 100 >= span.count * height * 65
            }
            let dominant = candidates.max { $0.count < $1.count }
            let anchor = dominant.map { band in
                read.confidence >= 0.95 && read.text.count >= 3 && CGFloat(band.count) * 2 <= box.width &&
                    candidates.allSatisfy { $0 == band || CGFloat($0.count) <= CGFloat(band.count) * 0.6 }
            } ?? false
            let bands = anchor ? [dominant!] : candidates
            guard (anchor || (2...3).contains(bands.count)), let minimum = bands.map(\.count).min(),
                  bands.allSatisfy({ $0.count <= minimum * 3 / 2 }),
                  zip(bands, bands.dropFirst()).allSatisfy({ a, b in
                      let gap = b.lowerBound - a.upperBound
                      return CGFloat(gap) >= CGFloat(minimum) * 0.25 && CGFloat(gap) <= CGFloat(minimum) * 1.2
                  }) else { continue }
            var crops: [NativeCoreMLRecognitionRegion] = []
            for band in bands.reversed() {
                var top = height, bottom = -1, activeRows = 0, breaks = 0, wasActive = false
                do {
                    for y in y0..<y1 {
                        var count = 0
                        for localX in band {
                            if mask[(y - y0) * width + localX] { count += 1 }
                        }
                        let active = count >= 2
                        if active { top = min(top, y - y0); bottom = y - y0; activeRows += 1 }
                        if wasActive && !active { breaks += 1 }
                        wasActive = active
                    }
                }
                // A panel rule or balloon outline is continuous, not a stack of glyphs.
                guard bottom > top, bottom - top >= band.count * 2, breaks >= 2,
                      activeRows * 100 <= (bottom - top + 1) * 94 else { crops.removeAll(); break }
                let padding = max(3, CGFloat(band.count) * 0.12)
                let rect = CGRect(x: CGFloat(x0 + band.lowerBound) - padding, y: CGFloat(y0 + top) - padding,
                    width: CGFloat(band.count) + padding * 2, height: CGFloat(bottom - top + 1) + padding * 2)
                    .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                crops.append(.init(sourceIndex: nextID, polygon: [CGPoint(x: rect.minX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)]))
                nextID += 1
            }
            guard crops.count == bands.count else { continue }
            let proposal = Proposal(original: read, regions: crops)
            if anchor {
                if anchors.count < 2 { anchors.append(proposal) }
            } else if result.count < 2 { result.append(proposal) }
        }
        // A padded neighbour may overlap a fused detection. Tighten it only
        // beside a recovered block, with an independent identical-text reread.
        let tightened = anchors.compactMap { anchor -> Proposal? in
            guard let box = NativeOCRScopeGeometry.bounds(for: anchor.original.polygon),
                  let crop = NativeOCRScopeGeometry.bounds(for: anchor.regions[0].polygon),
                  let owner = result.first(where: { proposal in
                      guard let fused = NativeOCRScopeGeometry.bounds(for: proposal.original.polygon) else { return false }
                      let columns = proposal.regions.compactMap { NativeOCRScopeGeometry.bounds(for: $0.polygon) }
                      let union = columns.reduce(CGRect.null) { $0.union($1) }
                      let overlap = min(box.maxY, fused.maxY) - max(box.minY, fused.minY)
                      return box.intersects(fused) && overlap >= min(box.height, fused.height) * 0.75 &&
                          (crop.maxX <= union.minX || crop.minX >= union.maxX)
                  }) else { return nil }
            var value = anchor
            value.fusedOwner = owner.original.sourceIndex
            return value
        }
        return result + tightened
    }

    static func replacements(_ proposal: Proposal, reads: [NativeCoreMLRecognizedRegion]) -> [NativeCoreMLRecognizedRegion]? {
        let result = proposal.regions.compactMap { region in reads.first { $0.sourceIndex == region.sourceIndex } }
        guard result.count == proposal.regions.count, result.allSatisfy({ $0.confidence >= 0.9 && (3...48).contains($0.text.count) &&
            $0.text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }) }) else { return nil }
        if proposal.fusedOwner != nil {
            guard result.count == 1, result[0].text == proposal.original.text,
                  result[0].confidence >= max(0.95, proposal.original.confidence - 0.02) else { return nil }
            return result
        }
        let observed = Array(proposal.original.text.filter { $0.isLetter || $0.isNumber })
        // At least one reread must retain the original evidence in order. Allow a single
        // confused glyph, but never authorize unrelated replacement text from pixels alone.
        let confirmed = result.contains { read in
            let full = Array(read.text.filter { $0.isLetter || $0.isNumber })
            var previous = [Int](repeating: 0, count: full.count + 1)
            for character in observed {
                var row = previous
                for j in full.indices {
                    row[j + 1] = character == full[j] ? previous[j] + 1 : max(previous[j + 1], row[j])
                }
                previous = row
            }
            return (previous.last ?? 0) >= max(2, observed.count - 1) &&
                (previous.last ?? 0) * 4 >= observed.count * 3
        }
        guard confirmed, result.map(\.text).joined().count > proposal.original.text.count else { return nil }
        return result
    }
}
