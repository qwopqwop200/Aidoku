import CoreGraphics
import Foundation

/// A wide vertical detection can swallow adjacent columns and recognize just one of them.
/// Split only repeated dark glyph bands on light paper, then independently confirm every crop.
@available(iOS 18.0, *)
enum NativeOCRFusedColumnRecovery {
    struct AnchoredProposal {
        let original: NativeCoreMLRecognizedRegion
        let missing: NativeCoreMLRecognitionRegion
        let witnesses: [(region: NativeCoreMLRecognitionRegion, original: NativeCoreMLRecognizedRegion)]
        var regions: [NativeCoreMLRecognitionRegion] { [missing] + witnesses.map(\.region) }
    }

    struct Proposal {
        let original: NativeCoreMLRecognizedRegion
        let regions: [NativeCoreMLRecognitionRegion]
        var fusedOwner: Int? = nil
    }

    static func proposals(_ reads: [NativeCoreMLRecognizedRegion], frame: NativeOCRRGBAFrame,
                          startingID: Int) -> [Proposal] {
        guard validIDRange(reads, startingID: startingID) else { return [] }
        var result: [Proposal] = [], nextID = max(startingID, (reads.map(\.sourceIndex).max() ?? 0) + 1)
        var anchors: [Proposal] = []
        var scannedPixels = 0
        for read in reads {
            // Exact-width recognition can slightly reduce the aggregate confidence of a
            // fused crop. Admission alone never authorizes replacement: every separated
            // column must still pass the high-confidence reread and original-text LCS.
            guard read.confidence >= 0.6, (2...32).contains(read.text.count),
                  read.text.unicodeScalars.contains(where: { (0x3040...0x30FF).contains($0.value) }),
                  let box = NativeOCRScopeGeometry.bounds(for: read.polygon),
                  box.width >= 50, box.width <= 400, box.height >= box.width * 1.2,
                  box.height <= box.width * 3.2 else { continue }
            let scan = box.intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
            guard !scan.isNull, scan.width > 0, scan.height > 0 else { continue }
            let x0 = Int(scan.minX), x1 = Int(ceil(scan.maxX))
            let y0 = Int(scan.minY), y1 = Int(ceil(scan.maxY))
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

    /// A low-confidence enclosing detection may hide one undetected column between
    /// two independently read columns. Keep those strong reads; recover only a bounded
    /// internal glyph band after both neighbours reproduce their full text.
    static func anchoredProposals(_ reads: [NativeCoreMLRecognizedRegion], frame: NativeOCRRGBAFrame,
                                  startingID: Int) -> [AnchoredProposal] {
        guard validIDRange(reads, startingID: startingID) else { return [] }
        var result: [AnchoredProposal] = []
        var nextID = max(startingID, (reads.map(\.sourceIndex).max() ?? 0) + 1)
        var scannedPixels = 0
        for read in reads where read.confidence >= 0.15 && read.confidence < 0.65 {
            guard result.count < 2, (2...32).contains(read.text.count),
                  let box = NativeOCRScopeGeometry.bounds(for: read.polygon),
                  box.width >= 120, box.width <= 600, box.height >= box.width * 0.8,
                  box.height <= box.width * 3.2 else { continue }
            let anchors = reads.compactMap { candidate -> (NativeCoreMLRecognizedRegion, CGRect)? in
                guard candidate.sourceIndex != read.sourceIndex, candidate.confidence >= 0.9,
                      (3...32).contains(candidate.text.count), containsKana(candidate.text),
                      let bounds = NativeOCRScopeGeometry.bounds(for: candidate.polygon),
                      bounds.width >= 15, bounds.height >= bounds.width * 1.5,
                      box.intersection(bounds).width * box.intersection(bounds).height >= bounds.width * bounds.height * 0.95
                else { return nil }
                return (candidate, bounds)
            }.sorted { $0.1.midX < $1.1.midX }
            guard (2...6).contains(anchors.count) else { continue }
            for (left, right) in zip(anchors, anchors.dropFirst()) {
                let pitch = (left.1.width + right.1.width) / 2
                let gap = right.1.minX - left.1.maxX
                guard gap >= pitch * 0.5, gap <= pitch * 1.8,
                      abs(left.1.minY - right.1.minY) <= pitch * 0.6,
                      min(left.1.height, right.1.height) >= max(left.1.height, right.1.height) * 0.6 else { continue }
                let scan = CGRect(x: left.1.maxX, y: box.minY, width: gap, height: box.height)
                    .intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                guard !scan.isNull, scan.width > 0, scan.height > 0 else { continue }
                let x0 = Int(ceil(scan.minX)), x1 = Int(floor(scan.maxX))
                let y0 = Int(floor(scan.minY)), y1 = Int(ceil(scan.maxY))
                let width = x1 - x0, height = y1 - y0
                guard width > 0, height > 0, width * height <= 250_000,
                      scannedPixels + width * height <= 500_000 else { continue }
                scannedPixels += width * height
                var mask = [Bool](repeating: false, count: width * height)
                var light = [Int](repeating: 0, count: width)
                frame.bytes.withUnsafeBufferPointer { bytes in
                    for y in 0..<height {
                        for x in 0..<width {
                            let offset = (y + y0) * frame.bytesPerRow + (x + x0) * 4
                            mask[y * width + x] = max(bytes[offset], bytes[offset + 1], bytes[offset + 2]) < 110
                            if min(bytes[offset], bytes[offset + 1], bytes[offset + 2]) > 220 { light[x] += 1 }
                        }
                    }
                }
                // The enclosing box can include a balloon outline. Boundary-connected
                // ink cannot prove a missing glyph column.
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
                var dark = [Int](repeating: 0, count: width)
                for y in 0..<height {
                    for x in 0..<width where mask[y * width + x] { dark[x] += 1 }
                }
                let threshold = max(4, Int(CGFloat(height) * 0.035))
                var spans: [Range<Int>] = [], start: Int?
                for x in 0...width {
                    if x < width && dark[x] >= threshold {
                        if start == nil { start = x }
                    } else if let first = start { spans.append(first..<x); start = nil }
                }
                guard let band = spans.max(by: { $0.count < $1.count }),
                      band.lowerBound > 1, band.upperBound < width - 1,
                      CGFloat(band.count) >= pitch * 0.4, CGFloat(band.count) <= pitch * 1.1,
                      spans.allSatisfy({ $0 == band || $0.count * 4 <= band.count }),
                      light[band].reduce(0, +) * 100 >= band.count * height * 55 else { continue }
                var top = height, bottom = -1, activeRows = 0, breaks = 0, wasActive = false
                for y in 0..<height {
                    let active = band.reduce(0) { $0 + (mask[y * width + $1] ? 1 : 0) } >= 2
                    if active { top = min(top, y); bottom = y; activeRows += 1 }
                    if wasActive && !active { breaks += 1 }
                    wasActive = active
                }
                guard bottom > top, bottom - top >= band.count * 2, breaks >= 2,
                      activeRows * 100 <= (bottom - top + 1) * 94,
                      abs(CGFloat(y0 + top) - min(left.1.minY, right.1.minY)) <= pitch * 0.6 else { continue }
                let padding = max(3, CGFloat(band.count) * 0.12)
                let rect = CGRect(x: CGFloat(x0 + band.lowerBound) - padding, y: CGFloat(y0 + top) - padding,
                                  width: CGFloat(band.count) + padding * 2, height: CGFloat(bottom - top + 1) + padding * 2)
                    .intersection(box).intersection(CGRect(x: 0, y: 0, width: frame.width, height: frame.height))
                guard !result.contains(where: { proposal in
                    guard let previous = NativeOCRScopeGeometry.bounds(for: proposal.missing.polygon) else { return false }
                    let shared = rect.intersection(previous)
                    return !shared.isNull && shared.width * shared.height >=
                        min(rect.width * rect.height, previous.width * previous.height) * 0.75
                }) else { continue }
                let missing = NativeCoreMLRecognitionRegion(sourceIndex: nextID, polygon: [
                    CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                    CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)])
                nextID += 1
                let witnesses = [left.0, right.0].map { original in
                    let region = NativeCoreMLRecognitionRegion(sourceIndex: nextID, polygon: original.polygon)
                    nextID += 1
                    return (region: region, original: original)
                }
                result.append(.init(original: read, missing: missing, witnesses: witnesses))
                break // At most one unexplained column per enclosing detection.
            }
        }
        return result
    }

    static func anchoredReplacement(_ proposal: AnchoredProposal,
                                    reads: [NativeCoreMLRecognizedRegion]) -> NativeCoreMLRecognizedRegion? {
        guard proposal.witnesses.count == 2,
              Set(proposal.witnesses.map { $0.region.sourceIndex }).count == 2,
              proposal.witnesses.allSatisfy({ $0.region.sourceIndex != proposal.missing.sourceIndex }),
              let missing = reads.first(where: { $0.sourceIndex == proposal.missing.sourceIndex }),
              missing.confidence >= 0.95, (3...32).contains(missing.text.count), containsKana(missing.text),
              missing.polygon == proposal.missing.polygon else { return nil }
        for witness in proposal.witnesses {
            guard let confirmed = reads.first(where: { $0.sourceIndex == witness.region.sourceIndex }),
                  confirmed.confidence >= max(0.9, witness.original.confidence - 0.02),
                  confirmed.text == witness.original.text, confirmed.polygon == witness.region.polygon else { return nil }
        }
        return missing
    }

    private static func containsKana(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3040...0x30FF).contains($0.value) }
    }

    private static func validIDRange(_ reads: [NativeCoreMLRecognizedRegion], startingID: Int) -> Bool {
        // The larger proposal pass can allocate three IDs for each of 256 reads,
        // including candidates later rejected by the two-proposal output budget.
        reads.count <= 256 && startingID >= 0 && startingID <= Int.max - 1024 &&
            reads.allSatisfy { $0.sourceIndex >= 0 && $0.sourceIndex <= Int.max - 1024 }
    }
}
