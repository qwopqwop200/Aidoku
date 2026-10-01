import CoreGraphics
import Foundation

/// Failed giant-source restoration retains the original illustration and tries
/// one title gloss. Partner joins and source-order placement are transactional.
enum NativeTranslationOversizedTitleGloss {
    struct Record {
        let id: String
        let text: String
        let normalizedSourceBounds: CGRect
        let sourceFontSize: Double?
        let rotation: Double
        let hasRestorationProposal: Bool
        var origin: CGPoint
        var ink: CGRect
        var fontSize: Double
        var panels: [NativeTranslationSourceStylePostPolish.Panel]
        var sampledForeground: [Double]?
        var sampledStroke: [Double]?
        var sampledBackground: [Double]?
        var backgroundKind: String = "readability-panel"
        var preservedErasure = false
        var preservedGloss = false
        var backings: [NativePanelGeometry.Backing] = []
        /// Other-cover inventory includes standalone/source-rotated BCRs.
        /// They participate in blocking and reject a partner, never in the
        /// initial readability-panel/backing trim query.
        var rotatedCoverFrames: [CGRect] = []
        var rotatesSourcePanels = false
    }
    struct Result {
        var records: [Record]
        var gloss = NativeTranslationEffectGloss.Refinement()
    }
    typealias Measure = (_ id: String, _ text: String, _ size: Double, _ width: Double, _ lineHeight: Double, _ origin: CGPoint) -> CGRect

    static func refining(records input: [Record], frame: CGRect, image: CGImage?, keptSources: [CGRect],
                         erased: [CGRect], measure: Measure,
                         placerFactory: ((CGRect, CGRect, [Double], [Double]?, CGImage?) -> NativeTranslationGlossPlacement)? = nil) -> Result {
        var result = Result(records: input)
        struct Gloss { let id: String; let partner: String?; let size: Double }
        var glosses: [Gloss] = []
        func source(_ b: CGRect) -> CGRect {
            CGRect(x: frame.minX + b.minX * frame.width, y: frame.minY + b.minY * frame.height,
                width: b.width * frame.width, height: b.height * frame.height)
        }
        func intersects(_ a: CGRect, _ b: CGRect) -> Bool {
            a.minX - 3 < b.maxX && a.maxX + 3 > b.minX && a.minY - 3 < b.maxY && a.maxY + 3 > b.minY
        }
        func overlap(_ a: CGRect, _ b: CGRect) -> Bool { a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY }
        func coverFrames(_ record: Record) -> [CGRect] {
            (record.rotatesSourcePanels ? [] : record.panels.map(\.rect)) + record.backings.map(\.frame) + record.rotatedCoverFrames
        }
        func valid(_ color: [Double]?) -> [Double]? { color.flatMap { NativeTranslationSourceStylePostPolish.valid($0) ? $0 : nil } }
        func clean(_ text: String) -> String {
            text.replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        func countHangul(_ text: String) -> Int { text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.count }
        func notice(_ text: String) -> Bool {
            text.range(of: "샘플|견본|무단|전재|금지|업로드|sample", options: [.regularExpression, .caseInsensitive]) != nil
        }
        for i in result.records.indices {
            var record = result.records[i]
            let b = record.normalizedSourceBounds
            if record.rotation != 0 || record.hasRestorationProposal || b.width <= 0 || b.height <= 0 || frame.width <= 0 || frame.height <= 0 ||
                b.width * b.height < 0.22 || record.text.utf16.count > 120 || record.ink.width <= 0 || record.ink.height <= 0 ||
                b.width * frame.width * b.height * frame.height < record.ink.width * record.ink.height * 8 || record.panels.isEmpty && record.backings.isEmpty { continue }
            let obstacles = result.records.indices.filter { $0 != i }.map { result.records[$0].ink }
            if obstacles.contains(where: { intersects(record.ink, $0) }) {
                let limit = min(72, b.height * frame.height * 0.15), step = record.ink.height + 8
                var shift: CGFloat?
                for k in 1...4 {
                    for direction: CGFloat in [1, -1] {
                        let dy = direction * CGFloat(k) * step, next = record.ink.offsetBy(dx: 0, dy: dy)
                        if abs(dy) > limit || next.minY < frame.minY + 4 || next.maxY > frame.maxY - 4 || obstacles.contains(where: { intersects(next, $0) }) { continue }
                        shift = dy; break
                    }
                    if shift != nil { break }
                }
                guard let shift else { continue }
                record.origin.y += shift; record.ink = record.ink.offsetBy(dx: 0, dy: shift)
            }
            var changed = 0
            for p in record.panels.indices {
                if record.panels[p].hasForeignChildren { continue }
                let panel = record.panels[p].rect
                let l = max(panel.minX, record.ink.minX - 4), t = max(panel.minY, record.ink.minY - 4)
                let r = min(panel.maxX, record.ink.maxX + 4), bottom = min(panel.maxY, record.ink.maxY + 4)
                if r <= l || bottom <= t { continue }
                let clipped = CGRect(x: l, y: t, width: r - l, height: bottom - t)
                record.panels[p].rect = clipped; record.panels[p].coverage = [clipped]
                record.panels[p].clipped = false; record.panels[p].coverageClip = nil; record.panels[p].captionUnionClipped = true; changed += 1
            }
            // The frozen covers query also includes same-region clipped clones.
            for backingIndex in record.backings.indices {
                let frame = record.backings[backingIndex].frame
                let left = max(frame.minX, record.ink.minX-4), top = max(frame.minY, record.ink.minY-4)
                let right = min(frame.maxX, record.ink.maxX+4), bottom = min(frame.maxY, record.ink.maxY+4)
                if right <= left || bottom <= top { continue }
                let trimmed = CGRect(x: left, y: top, width: right-left, height: bottom-top)
                record.backings[backingIndex].frame = trimmed
                record.backings[backingIndex].coverage = [trimmed]
                record.backings[backingIndex].clipped = false
                record.backings[backingIndex].coverageClip = nil
                record.backings[backingIndex].captionUnionClipped = true
                changed += 1
            }
            if changed > 0 { record.preservedErasure = true; record.backgroundKind = "source-preserved-caption" }
            result.records[i] = record
            if changed == 0 || changed != record.panels.count + record.backings.count { continue }
            let current = record.fontSize
            let sourceSize = record.sourceFontSize.flatMap { $0 > 0 ? $0 : nil } ?? Double(b.height * frame.height) * 0.5
            let text = clean(record.text), syllables = countHangul(text)
            let latin = text.unicodeScalars.filter { (65...90).contains($0.value) || (97...122).contains($0.value) }.count
            let words = text.components(separatedBy: " ")
            let repeated = text.replacingOccurrences(of: " ", with: "").range(of: "^([가-힣]{1,2})\\1+[!?~.…]*$", options: .regularExpression) != nil
            if current <= 0 || current >= sourceSize * 0.25 || syllables < 3 || latin > syllables || text.utf16.count > 32 ||
                repeated || words.count > 1 && words.allSatisfy({ $0 == words[0] }) || notice(text) { continue }
            let s = source(b)
            let fill = valid(record.sampledForeground) ?? [255, 255, 255]
            let light = NativeTranslationSourceStylePostPolish.luminance(fill) > 0.18, spread = fill.max()! - fill.min()!
            let outline: [Double]
            if let stroke = valid(record.sampledStroke), NativeTranslationSourceStylePostPolish.sourceColorContrast(stroke, panel: fill) >= 3 { outline = stroke }
            else { outline = light ? spread > 48 ? fill.map { floor($0 * 0.18 + 0.5) } : [17, 18, 23] : [255, 255, 255] }
            let minimum = max(current, 14), start = min(26, max(minimum, floor(sourceSize * 0.3 * 4 + 0.5) / 4))
            let placer = placerFactory?(frame, s, fill, valid(record.sampledBackground), image) ??
                NativeTranslationGlossPlacement(frame: frame, band: s, fill: fill, ground: valid(record.sampledBackground), image: image)
            let options = NativeTranslationGlossPlacement.Options(start: start, minimum: minimum)
            let blocked = obstacles + result.records.indices.filter { $0 != i }.flatMap { coverFrames(result.records[$0]) } +
                result.records.indices.filter { $0 != i }.map { source(result.records[$0].normalizedSourceBounds) } + keptSources.map(source)
            var partner: Int?, partnerGap = CGFloat.infinity
            for j in result.records.indices where j != i {
                let other = result.records[j], o = other.normalizedSourceBounds
                if other.rotation != 0 || other.hasRestorationProposal || other.backgroundKind != "readability-panel" || other.preservedErasure ||
                    (other.sourceFontSize ?? 0) < sourceSize * 0.45 { continue }
                let said = clean(other.text)
                if countHangul(said) < 2 || said.utf16.count > 24 || notice(said) { continue }
                let g = max(o.minY, b.minY) - min(o.maxY, b.maxY), horizontal = min(o.maxX, b.maxX) - max(o.minX, b.minX)
                if g > min(o.height, b.height) * 0.3 || horizontal < min(o.width, b.width) * 0.5 || coverFrames(other).isEmpty || !other.rotatedCoverFrames.isEmpty ||
                    other.panels.contains(where: { $0.rotated || $0.hasForeignChildren }) || erased.contains(where: { overlap($0, source(o)) }) { continue }
                if partner == nil || abs(g) < abs(partnerGap) { partner = j; partnerGap = g }
            }
            func measured(_ indices: [Int], _ size: Double, _ width: Double, _ lineHeight: Double) -> [CGRect] {
                indices.map { index in
                    let r = result.records[index]
                    return measure(r.id, r.text, size, width, lineHeight, r.origin)
                }
            }
            var placed: NativeTranslationGlossPlacement.Placement?
            if let j = partner {
                let other = result.records[j], otherSource = source(other.normalizedSourceBounds), joined = s.union(otherSource)
                func same(_ r: CGRect, _ q: CGRect) -> Bool { abs(r.minX - q.minX) < 0.5 && abs(r.minY - q.minY) < 0.5 }
                let partnerBlocked = blocked.filter { r in !same(r, other.ink) && !same(r, otherSource) && !coverFrames(other).contains(where: { same(r, $0) }) }
                placer.setBand(joined)
                placed = placer.search(source: joined, blocked: partnerBlocked, before: other.normalizedSourceBounds.minY < b.minY,
                    options: options, measure: { measured([i, j], $0, $1, $2) })
                if placed == nil { partner = nil }
            }
            if placed == nil {
                placed = placer.search(source: s, blocked: blocked, options: options, measure: { measured([i], $0, $1, $2) })
            }
            guard let placed else { continue }
            let selected = [i] + (partner.map { [$0] } ?? [])
            for (k, index) in selected.enumerated() {
                var r = result.records[index]
                let move = placed.moves[k]
                let individual = NativeTranslationGlossPlacement.Placement(cost: placed.cost, size: placed.size, width: placed.width,
                    lineHeight: placed.lineHeight, moves: [move], edge: placed.edge, rank: placed.rank, side: placed.side, gap: placed.gap,
                    texture: placed.texture, ink: placed.ink, angle: placed.angle, center: placed.center, block: placed.block)
                result.gloss.notes.append(.init(id: r.id, text: r.text, placement: individual, origin: r.origin,
                    fill: fill, outline: outline, strokeWidth: max(1.5, min(3.5, placed.size * 0.14)), title: true,
                    members: selected.map { result.records[$0].id }, unit: selected.map { result.records[$0].id }, anchor: 0, rawAngle: 0))
                r.origin.x += move.x; r.origin.y += move.y
                r.ink = measure(r.id, r.text, placed.size, placed.width, placed.lineHeight, result.records[index].origin).offsetBy(dx: move.x, dy: move.y)
                r.fontSize = placed.size; r.panels = []; r.backings = []; r.preservedGloss = true
                r.backgroundKind = "source-preserved-caption"; result.records[index] = r
                result.gloss.hiddenIDs.insert(r.id); result.gloss.removedLayerIDs.insert(r.id)
            }
            glosses.append(Gloss(id: record.id, partner: partner.map { result.records[$0].id }, size: placed.size))
        }
        if glosses.count > 1, let least = glosses.map(\.size).min(), glosses.allSatisfy({ $0.size <= least * 1.6 }) {
            for gloss in glosses where gloss.size != least && gloss.partner == nil {
                guard let noteIndex = result.gloss.notes.firstIndex(where: { $0.id == gloss.id }) else { continue }
                let note = result.gloss.notes[noteIndex], p = note.placement, lh = floor(least * 1.2 * 100 + 0.5) / 100
                let before = measure(note.id, note.text, p.size, p.width, p.lineHeight, note.origin)
                let after = measure(note.id, note.text, least, p.width, lh, note.origin)
                let dx = (before.minX + before.maxX - after.minX - after.maxX) / 2
                let dy = (before.minY + before.maxY - after.minY - after.maxY) / 2
                let harmonized = NativeTranslationGlossPlacement.Placement(cost: p.cost, size: least, width: p.width, lineHeight: lh,
                    moves: p.moves.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }, edge: p.edge, rank: p.rank, side: p.side,
                    gap: p.gap, texture: p.texture, ink: p.ink, angle: p.angle, center: p.center, block: p.block)
                result.gloss.notes[noteIndex] = .init(id: note.id, text: note.text, placement: harmonized, origin: note.origin,
                    fill: note.fill, outline: note.outline, strokeWidth: max(1.5, min(3.5, least * 0.14)), title: true,
                    members: note.members, unit: note.unit, anchor: note.anchor, rawAngle: note.rawAngle)
                if let recordIndex = result.records.firstIndex(where: { $0.id == note.id }), let move = harmonized.moves.first {
                    result.records[recordIndex].fontSize = least
                    result.records[recordIndex].origin = CGPoint(x: note.origin.x + move.x, y: note.origin.y + move.y)
                    result.records[recordIndex].ink = after.offsetBy(dx: move.x, dy: move.y)
                }
            }
        }
        return result
    }
}
