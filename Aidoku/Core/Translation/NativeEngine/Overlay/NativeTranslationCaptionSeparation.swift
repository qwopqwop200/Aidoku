import CoreGraphics
import Foundation

/// Exact final measured leading and transparent-column separation policies.
/// The typesetter supplies the fully reshaped candidate after holding its first
/// line in place. Geometry commits only after every foreign-text/page gate passes.
enum NativeTranslationCaptionSeparation {
    struct Metric {
        let ascent: Double
        let descent: Double
    }
    struct Entry {
        let id: String
        let frame: CGRect
        let source: CGRect
        let text: String
        let sourceVertical: Bool
        let vertical: Bool
        let rotation: Double
        let hasBalloon: Bool
        let isRoot: Bool
        let inpainted: Bool
        let keepsSource: Bool
        let visible: Bool
        let horizontalWriting: Bool
        /// DOMMatrix is2D && abs(b)+abs(c)+abs(d-1)<=.001.
        let horizontalTransform: Bool
        let font: Double
        let stroke: Double
        let metrics: [Metric]
        var lineHeight: Double
        var height: Double
        var lines: [CGRect]
        var shift = CGPoint.zero
        var columnShift = 0.0
        var measuredPitch: Double? = nil
    }
    struct Candidate {
        let lines: [CGRect]
        let height: Double
        let shiftY: Double
    }
    typealias Reshape = (_ entry: Entry, _ lineHeight: Double) -> Candidate?

    static func linePitch(metrics: [Metric], stroke: Double, font: Double) -> Double {
        guard metrics.count >= 2, metrics.allSatisfy({ $0.ascent.isFinite && $0.descent.isFinite }),
              stroke.isFinite, stroke >= 0, font > 0 else { return 0 }
        var pitch = 0.0
        for index in 1..<metrics.count {
            pitch = max(pitch, metrics[index - 1].descent + metrics[index].ascent + stroke + max(0.2, font * 0.025))
        }
        return font <= 8 && stroke >= font * 0.15 ? max(pitch, font * 4 / 3) : pitch
    }

    static func separateLines(_ input: [Entry], itemCount: Int? = nil, reshape: Reshape) -> [Entry] {
        guard (itemCount ?? input.count) <= 256 else { return input }
        var entries = input, budget = 8192
        for index in entries.indices {
            let e = entries[index]
            guard eligible(e), e.horizontalWriting, e.horizontalTransform, e.lineHeight.isFinite,
                  e.text.utf16.count <= 1024 else { continue }
            budget -= e.text.unicodeScalars.count
            if budget < 0 { break }
            if e.metrics.count < 2 { continue }
            let needed = linePitch(metrics: e.metrics, stroke: e.stroke, font: e.font)
            if needed <= e.lineHeight + 0.25 || needed > e.font * 1.8 { continue }
            let foreign = entries.indices.filter { $0 != index && entries[$0].visible }.flatMap { entries[$0].lines }.filter(valid)
            func hits(_ boxes: [CGRect]) -> Int { foreign.filter { r in boxes.contains { intersects($0, r) } }.count }
            let newPitch = ceil(needed * 64) / 64
            guard let after = reshape(e, newPitch), !after.lines.isEmpty,
                  after.lines.allSatisfy({ valid($0) && $0.minY - e.stroke / 2 >= e.frame.minY && $0.maxY + e.stroke / 2 <= e.frame.maxY }),
                  hits(after.lines) <= hits(e.lines) else { continue }
            entries[index].lineHeight = newPitch; entries[index].height = after.height
            entries[index].shift.y += after.shiftY; entries[index].lines = after.lines
            entries[index].measuredPitch = needed
        }
        return entries
    }

    static func separateColumns(_ input: [Entry], keptSources: [CGRect], itemCount: Int? = nil) -> [Entry] {
        guard (itemCount ?? input.count) <= 128 else { return input }
        var entries = input.filter(\.visible), budget = 4096
        let kept = keptSources.map { $0.insetBy(dx: -1, dy: -1) }
        func measured(_ e: Entry) -> [CGRect] { e.lines.filter(valid).map { $0.insetBy(dx: -e.stroke / 2 - 0.5, dy: -e.stroke / 2 - 0.5) } }
        for _ in 0..<3 {
            for ai in entries.indices { for bi in entries.indices where bi > ai {
                budget -= 1
                if budget < 0 { return merging(entries, into: input) }
                var a = ai, b = bi
                if !eligible(entries[a]) || !eligible(entries[b]) || entries[a].lines.isEmpty || entries[b].lines.isEmpty || entries[a].frame != entries[b].frame { continue }
                if entries[a].source.midX > entries[b].source.midX { swap(&a, &b) }
                let ar = measured(entries[a]), br = measured(entries[b])
                if entries[a].source.midX == entries[b].source.midX || !ar.contains(where: { r in br.contains { hit(r, $0) } }) { continue }
                var gap: CGFloat = 0
                for r in ar { for o in br where min(r.maxY, o.maxY) > max(r.minY, o.minY) { gap = max(gap, r.maxX - o.minX + 1) } }
                if gap <= 0 { continue }
                func bounded(_ index: Int, _ dx: CGFloat, _ rects: [CGRect]) -> Bool {
                    let e = entries[index], limit = min(16, max(3, e.source.width)), total = e.columnShift + Double(dx)
                    return abs(total) <= limit && rects.allSatisfy { $0.minX + dx >= e.frame.minX && $0.maxX + dx <= e.frame.maxX }
                }
                let foreign = entries.indices.filter { $0 != a && $0 != b }.flatMap { measured(entries[$0]) } + kept
                for (dx, ex) in [(-gap / 2, gap / 2), (-gap, 0), (0, gap)] {
                    if !bounded(a, dx, ar) || !bounded(b, ex, br) { continue }
                    let nextA = ar.map { $0.offsetBy(dx: dx, dy: 0) }, nextB = br.map { $0.offsetBy(dx: ex, dy: 0) }
                    if nextA.contains(where: { r in nextB.contains { hit(r, $0) } }) || (nextA + nextB).contains(where: { r in foreign.contains { hit(r, $0) } }) { continue }
                    // Translation leaves the measured glyphs unchanged; value copies provide
                    // the same successful read-back as the browser's DOM range remeasurement.
                    entries[a].lines = entries[a].lines.map { $0.offsetBy(dx: dx, dy: 0) }
                    entries[b].lines = entries[b].lines.map { $0.offsetBy(dx: ex, dy: 0) }
                    entries[a].shift.x += dx; entries[b].shift.x += ex
                    entries[a].columnShift += Double(dx); entries[b].columnShift += Double(ex)
                    break
                }
            } }
        }
        return merging(entries, into: input)
    }
    private static func merging(_ output: [Entry], into input: [Entry]) -> [Entry] {
        input.map { original in output.first { $0.id == original.id } ?? original }
    }
    private static func eligible(_ e: Entry) -> Bool {
        e.sourceVertical && !e.vertical && e.rotation == 0 && !e.hasBalloon && e.isRoot && e.inpainted && !e.keepsSource && e.visible && valid(e.frame) && valid(e.source)
    }
    private static func valid(_ r: CGRect) -> Bool { [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0 }
    private static func intersects(_ a: CGRect, _ b: CGRect) -> Bool { a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY }
    private static func hit(_ a: CGRect, _ b: CGRect) -> Bool { min(a.maxX, b.maxX) - max(a.minX, b.minX) > 0.05 && min(a.maxY, b.maxY) - max(a.minY, b.minY) > 0.05 }
}
