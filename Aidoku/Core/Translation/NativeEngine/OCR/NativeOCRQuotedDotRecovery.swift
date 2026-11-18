import CoreGraphics
import Foundation

/// A bounded repair for outlined vertical quotes whose regular ellipsis dots
/// consume CTC tokens. Read the glyph body twice; punctuation comes only from
/// independently measured corner and dot components in the original pixels.
@available(iOS 18.0, *)
enum NativeOCRQuotedDotRecovery {
    struct Proposal: Sendable {
        let original: NativeCoreMLRecognitionRegion
        let crops: [NativeCoreMLRecognitionRegion]
        let ellipsisCount: Int
    }
    struct Component {
        var left: Int; var top: Int; var right: Int; var bottom: Int; var count: Int
        var width: Int { right - left + 1 }
        var height: Int { bottom - top + 1 }
        var centerX: Double { Double(left + right) / 2 }
        var centerY: Double { Double(top + bottom) / 2 }
    }
    static func eligible(_ read: NativeCoreMLRecognizedRegion) -> Bool {
        let scalars = Array(read.text.unicodeScalars)
        guard (0.35..<0.9).contains(read.confidence), (5...8).contains(scalars.count),
              [0x300C, 0x300E].contains(scalars[0].value),
              scalars.last?.value == (scalars[0].value == 0x300C ? 0x300D : 0x300F) else { return false }
        let body = scalars.dropFirst().dropLast()
        let kana = body.prefix { (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) }
        let tail = body.dropFirst(kana.count)
        // The same low-confidence dot rail can decode as digits OR ASCII
        // periods. Neither spelling supplies punctuation to the replacement:
        // proposal still measures the original corners and complete dot rail.
        return (1...2).contains(kana.count) && (2...4).contains(tail.count)
            && (tail.allSatisfy { (0x30...0x39).contains($0.value) }
                || tail.allSatisfy { $0.value == 0x2E })
    }
    static func proposal(frame: NativeOCRRGBAFrame, region: NativeCoreMLRecognitionRegion,
                         read: NativeCoreMLRecognizedRegion) -> Proposal? {
        guard eligible(read), region.sourceIndex == read.sourceIndex,
              region.polygon == read.polygon else { return nil }
        return pixelProposal(frame: frame, region: region)
    }
    /// Pixel-only nomination is safe before the first recognizer batch. The
    /// two glyph crops still require independent, agreeing model reads.
    static func pixelProposal(frame: NativeOCRRGBAFrame, region: NativeCoreMLRecognitionRegion) -> Proposal? {
        if NativeOCRDirectionGeometry.enabled("quoted") {
            guard let basis = NativeOCRDirectionGeometry.Frame(region.polygon),
           region.minimumSequenceWidth == 0, !region.useProvidedOrder, region.samplingPolygon == nil,
           let window = NativeOCRDirectionGeometry.Window(frame: basis,
                world: NativeOCRDirectionGeometry.bounds(region.polygon), maximumPixels: 1_048_576),
           let pixels = window.rgba(frame.bytes, width: frame.width, height: frame.height, stride: frame.bytesPerRow),
           let localFrame = NativeOCRRGBAFrame(width: window.width, height: window.height, bytes: pixels) else { return nil }
            let localRegion = NativeCoreMLRecognitionRegion(sourceIndex: region.sourceIndex,
                polygon: basis.quad.map(window.project))
            guard let local = axisPixelProposal(frame: localFrame, region: localRegion) else { return nil }
            return Proposal(original: region, crops: local.crops.map {
                NativeCoreMLRecognitionRegion(sourceIndex: region.sourceIndex,
                    polygon: $0.polygon.map(window.restore), useProvidedOrder: true)
            }, ellipsisCount: local.ellipsisCount)
        }
        return axisPixelProposal(frame: frame, region: region)
    }

    private static func axisPixelProposal(frame: NativeOCRRGBAFrame, region: NativeCoreMLRecognitionRegion) -> Proposal? {
        guard region.minimumSequenceWidth == 0,
              !region.useProvidedOrder, region.samplingPolygon == nil,
              let q = NativeOCRScopeGeometry.canonicalQuad(region.polygon) else { return nil }
        let left = Int(floor(q.map(\.x).min()!)), right = Int(ceil(q.map(\.x).max()!))
        let top = Int(floor(q.map(\.y).min()!)), bottom = Int(ceil(q.map(\.y).max()!))
        let width = right - left + 1, height = bottom - top + 1
        guard left >= 0, top >= 0, right < frame.width, bottom < frame.height,
              (20...128).contains(width), (80...512).contains(height),
              Double(height) / Double(width) >= 2.5,
              abs(q[0].y - q[1].y) <= CGFloat(width) * 0.1,
              abs(q[3].y - q[2].y) <= CGFloat(width) * 0.1,
              abs(q[0].x - q[3].x) <= CGFloat(width) * 0.15,
              abs(q[1].x - q[2].x) <= CGFloat(width) * 0.15 else { return nil }
        var seen = [Bool](repeating: false, count: width * height)
        func white(_ x: Int, _ y: Int) -> Bool {
            let i = (top + y) * frame.bytesPerRow + (left + x) * 4
            return frame.bytes[i] >= 230 && frame.bytes[i + 1] >= 225 && frame.bytes[i + 2] >= 215
        }
        var components: [Component] = []
        for y in 0..<height { for x in 0..<width {
            let i = y * width + x
            guard !seen[i], white(x, y) else { continue }
            seen[i] = true; var pending = [i]
            var c = Component(left: x, top: y, right: x, bottom: y, count: 0)
            while let pixel = pending.popLast() {
                let px = pixel % width, py = pixel / width
                c.left = min(c.left, px); c.right = max(c.right, px)
                c.top = min(c.top, py); c.bottom = max(c.bottom, py); c.count += 1
                for (dx, dy) in [(1, 0), (-1, 0), (0, 1), (0, -1)] {
                    let nx = px + dx, ny = py + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let ni = ny * width + nx
                    if !seen[ni], white(nx, ny) { seen[ni] = true; pending.append(ni) }
                }
            }
            // White paper connected to the crop boundary is background, not
            // an enclosed white glyph interior. Never let it become a corner
            // or a dot; all admitted components remain strictly interior.
            if c.count >= 5, c.left > 0, c.top > 0, c.right < width - 1, c.bottom < height - 1 {
                components.append(c)
            }
        } }
        components.sort { $0.top < $1.top }
        guard let opening = components.first, let closing = components.last,
              components.count >= 10, components.count <= 16,
              opening.left > 0, closing.left > 0,
              opening.right < width - 1, closing.right < width - 1,
              opening.top > 0, closing.bottom < height - 1,
              opening.width >= opening.height * 2, closing.width >= closing.height * 2,
              abs(opening.width - closing.width) <= opening.width / 4,
              abs(opening.centerX - closing.centerX) <= Double(opening.width) / 5 else { return nil }
        // One connected L-shaped white interior at each end establishes 「」.
        // Double-corner quotes and arbitrary outline artwork do not pass.
        func corner(_ c: Component, opening: Bool) -> Bool {
            guard Double(c.count) / Double(c.width * c.height) < 0.45 else { return false }
            let horizontalY = opening ? c.top : c.bottom
            let verticalX = opening ? c.right : c.left
            let horizontal = (c.left...c.right).filter { white($0, horizontalY) }.count
            let vertical = (c.top...c.bottom).filter { white(verticalX, $0) }.count
            return horizontal >= c.width * 3 / 4 && vertical >= c.height * 2 / 3
        }
        guard corner(opening, opening: true), corner(closing, opening: false) else { return nil }
        let inner = Array(components.dropFirst().dropLast())
        let dotLimit = max(6, opening.width / 5)
        let dotCandidates = inner.filter { $0.width <= dotLimit && $0.height <= dotLimit && $0.count <= dotLimit * dotLimit }
        // A disconnected kana stroke can be as small as one dot. Identify the
        // complete trailing regular rail, not every small component in the
        // quote. Unselected components remain glyph evidence below; none is
        // dropped from the source or silently treated as punctuation.
        let rails = [9, 6].compactMap { count -> [Component]? in
            guard dotCandidates.count >= count else { return nil }
            let rail = Array(dotCandidates.suffix(count))
            let gaps = zip(rail, rail.dropFirst()).map { $1.centerY - $0.centerY }
            let mean = gaps.reduce(0, +) / Double(gaps.count)
            guard mean >= Double(dotLimit), mean <= Double(opening.width) * 0.6,
                  gaps.allSatisfy({ abs($0 - mean) <= mean * 0.15 }) else { return nil }
            return rail
        }
        guard let dots = rails.first else { return nil }
        guard [6, 9].contains(dots.count), let firstDot = dots.first, let lastDot = dots.last,
              dots.allSatisfy({ Double($0.count) / Double($0.width * $0.height) >= 0.55 }),
              dots.map(\.width).max()! - dots.map(\.width).min()! <= 2,
              dots.map(\.height).max()! - dots.map(\.height).min()! <= 2,
              dots.map(\.centerX).max()! - dots.map(\.centerX).min()! <= 2 else { return nil }
        let pitches = zip(dots, dots.dropFirst()).map { $1.centerY - $0.centerY }
        let pitch = pitches.reduce(0, +) / Double(pitches.count)
        guard pitch >= Double(dotLimit), pitch <= Double(opening.width) * 0.6,
              pitches.allSatisfy({ abs($0 - pitch) <= pitch * 0.15 }),
              lastDot.bottom < closing.top - 2 else { return nil }
        // All non-dot ink must precede the dot rail; no uncertain suffix is dropped.
        let nonDots = inner.filter { c in !dots.contains(where: { $0.top == c.top && $0.left == c.left && $0.count == c.count }) }
        guard !nonDots.isEmpty, nonDots.allSatisfy({ $0.bottom < firstDot.top - 2 }),
              let first = nonDots.first, let last = nonDots.last else { return nil }
        let glyphHeight = nonDots.map(\.height).max()!
        guard glyphHeight >= dotLimit * 3, first.top > opening.bottom + 3,
              firstDot.top - last.bottom >= dotLimit else { return nil }
        // A substantial gap separates two glyph clusters; disconnected strokes
        // inside the second glyph may be grouped, but extra glyphs are rejected.
        let gaps = zip(nonDots, nonDots.dropFirst()).filter { $1.top - $0.bottom >= glyphHeight / 2 }
        guard gaps.count == 1, nonDots.filter({ $0.height >= glyphHeight / 2 }).count == 2 else { return nil }
        let pad = max(2, glyphHeight / 4)
        let x0 = left + nonDots.map(\.left).min()! - pad
        let x1 = left + nonDots.map(\.right).max()! + pad
        let gap = first.top - opening.bottom
        let ends = top + last.bottom + (firstDot.top - last.bottom) / 2
        let starts = [top + opening.bottom + gap / 3, top + opening.bottom + (gap + 1) / 2]
        guard x0 >= left, x1 <= right, starts[0] != starts[1] else { return nil }
        let crops = starts.map { start in
            NativeCoreMLRecognitionRegion(sourceIndex: region.sourceIndex, polygon: [
                CGPoint(x: x0, y: start), CGPoint(x: x1, y: start),
                CGPoint(x: x1, y: ends), CGPoint(x: x0, y: ends)
            ])
        }
        return Proposal(original: region, crops: crops, ellipsisCount: dots.count / 3)
    }
    static func accepted(proposal: Proposal, reads: [NativeCoreMLRecognizedRegion]) -> NativeCoreMLRecognizedRegion? {
        guard reads.count == 2, reads.map(\.polygon) == proposal.crops.map(\.polygon),
              reads.allSatisfy({ $0.sourceIndex == proposal.original.sourceIndex &&
                  $0.confidence.isFinite && (0.95...1).contains($0.confidence) }),
              reads[0].text == reads[1].text,
              reads[0].text.unicodeScalars.count == 2,
              reads[0].text.unicodeScalars.allSatisfy({ (0x3041...0x3096).contains($0.value) || (0x30A1...0x30FA).contains($0.value) }) else { return nil }
        return NativeCoreMLRecognizedRegion(sourceIndex: proposal.original.sourceIndex, polygon: proposal.original.polygon,
            text: "「" + reads[0].text + String(repeating: "…", count: proposal.ellipsisCount) + "」",
            confidence: min(reads[0].confidence, reads[1].confidence))
    }

}
