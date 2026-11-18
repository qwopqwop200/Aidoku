import CoreGraphics
import Foundation

/// A request may span two lobes while each lobe remains an independent layout/erase owner.
/// Neither shared style nor connected paper alone establishes a content unit.
enum ReaderTranslationLobedRequestMerger {
    static func continuesRequest(_ head: String, _ tail: String) -> Bool {
        let a = head.filter { !$0.isWhitespace }, b = tail.filter { !$0.isWhitespace }
        let boundaries = "。！？!?「」『』“”"
        guard a.count >= 6, a.count <= 100, b.count >= 6, b.count <= 60,
              !a.contains(where: { boundaries.contains($0) }),
              !b.contains(where: { "「」『』“”".contains($0) }),
              a.hasSuffix("に"), a.contains("せめて") || a.hasPrefix("どうか") else { return false }
        // Explicitly governed request, not a fresh subject or independently quoted utterance.
        let prefixes = ["ちゃんと", "きちんと", "どうか"]
        guard let prefix = prefixes.first(where: { b.hasPrefix($0) }) else { return false }
        let predicate = String(b.dropFirst(prefix.count))
        return predicate.range(of: "^[一-龯ぁ-んァ-ヶ]{1,16}してください[よねなぁぃぅぇぉー〜～っ]*[。！？!?]*$",
                               options: .regularExpression) != nil
    }

    static func apply(_ input: [ReaderTranslationRegion], image: CGImage,
                      enclosure: ReaderTranslationEnclosedBackground.ComponentMap,
                      separates: (CGRect, CGRect, BrowserOCRSourceOrientation) -> Bool = { _, _, _ in false }) -> [ReaderTranslationRegion] {
        guard image.width > 0, image.height > 0 else { return input }
        let width = CGFloat(image.width), height = CGFloat(image.height)
        func pixels(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * width, y: r.minY * height, width: r.width * width, height: r.height * height)
        }
        let candidates = input.filter {
            $0.translation == nil && $0.sourceOrientation == .vertical && $0.unitMemberRects.isEmpty && !$0.isOccludedFinePrint
        }.sorted { $0.rect.minY < $1.rect.minY }
        var replacements: [String: ReaderTranslationRegion] = [:], consumed = Set<String>()
        for head in candidates {
            guard !consumed.contains(head.id) else { continue }
            let eligible = candidates.filter { tail in
                guard head.id != tail.id, !consumed.contains(tail.id), continuesRequest(head.source, tail.source) else { return false }
                let a = pixels(head.rect), b = pixels(tail.rect)
                let gap = b.minY - a.maxY, span = min(a.width, b.width)
                let overlap = min(a.maxX, b.maxX) - max(a.minX, b.minX)
                guard span > 0, gap > 0, gap <= min(a.height, b.height) * 0.65,
                      overlap >= span * 0.25, max(a.width, b.width) <= span * 2,
                      !input.contains(where: { $0.id != head.id && $0.id != tail.id && $0.rect.intersects(head.rect.union(tail.rect)) }),
                      let paper = enclosure.balloon(of: a), paper == enclosure.balloon(of: b),
                      !enclosure.separates(a, b), !separates(a, b, .vertical) else { return false }
                return true
            }
            // Ambiguous continuations remain independent; do not select by proximity.
            guard eligible.count == 1, let tail = eligible.first else { continue }
            let anchor = input.first { $0.id == head.id || $0.id == tail.id }!
            let box = head.rect.union(tail.rect)
            var joined = ReaderTranslationRegion(id: anchor.id, rect: box, source: head.source + tail.source,
                confidence: min(head.confidence, tail.confidence), sourceImageAspectRatio: Double(width / height),
                sourceOrientation: .vertical, sourceSingleVerticalColumn: false)
            joined.unitMemberRects = [head.rect, tail.rect]
            joined.auxiliaryInkRects = head.auxiliaryInkRects + tail.auxiliaryInkRects
            joined.auxiliaryInkPolygons = head.auxiliaryInkPolygons + tail.auxiliaryInkPolygons
            joined.detectorSeedEvidence = NativeOCRDetectorSeedEvidence.preservingUnion([head.detectorSeedEvidence, tail.detectorSeedEvidence])
            joined.acceptedSource = .union([head.acceptedSource, tail.acceptedSource])
            joined.sourceOCRAlternatives = head.sourceOCRAlternatives + tail.sourceOCRAlternatives
            joined.isRecoveredLine = head.isRecoveredLine || tail.isRecoveredLine
            joined.polygon = [CGPoint(x: box.minX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                              CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY)]
            // Leave balloonInterior unset: the downstream pass must measure the two-member unit.
            replacements[anchor.id] = joined
            consumed.formUnion([head.id, tail.id])
        }
        return input.compactMap { replacements[$0.id] ?? (consumed.contains($0.id) ? nil : $0) }
    }
}
