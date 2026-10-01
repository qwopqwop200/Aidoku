// OCR and translation engine. See OCR-TRANSLATION-NOTICES.txt.
import CoreGraphics
import Foundation

/// The final effect-gloss unit policy. Admission and grouping retain the frozen
/// page-wide source evidence; failed multi-note attempts commit no modifications.
enum NativeTranslationEffectGloss {
    struct Plate {
        var rect: CGRect
        var colour: [Double]
        var opaque = true
    }
    struct Record {
        var id: String
        var text: String
        var role: String?
        var source: CGRect
        var auxiliary: [CGRect] = []
        var sourceFontSize: Double? = nil
        var sourceVertical = false
        /// Page-space center/width/height/angle. Quad height follows frame width.
        var sourceQuad: [Double]? = nil
        var hasBalloon = false
        var preservedGloss = false
        var preservedErasure = false
        var glyphReplacement = false
        var hidden = false
        var ink: CGRect
        var fontSize: Double
        var sampledForeground: [Double]? = nil
        var sampledStroke: [Double]? = nil
        var sampledBackground: [Double]? = nil
        var appliedForeground: [Double]? = nil
        var plates: [Plate] = []
    }
    struct Note {
        let id: String
        let text: String
        let placement: NativeTranslationGlossPlacement.Placement
        let origin: CGPoint
        let fill: [Double]
        let outline: [Double]
        let strokeWidth: Double
        let title: Bool
        let members: [String]
        let unit: [String]
        let anchor: Int
        let rawAngle: Double
    }
    struct SourceZone {
        let rect: CGRect
        let id: String
    }
    struct Refinement {
        var notes: [Note] = []
        var hiddenIDs: Set<String> = []
        var removedLayerIDs: Set<String> = []
        var sourceZones: [SourceZone] = []
        var rejected: [String: String] = [:]
        var units = 0
    }
    typealias Measure = (_ id: String, _ text: String, _ size: Double, _ width: Double,
                         _ lineHeight: Double, _ origin: CGPoint, _ title: Bool) -> [CGRect]
    typealias ReadSource = (_ rect: CGRect, _ width: Int, _ height: Int) -> [UInt8]?
    private struct Candidate {
        let record: Record
        let role: String
        let glyph: Double
        let text: String
        let inks: [[Double]]
        let plated: Int
        let cover: Double
        let weak: Bool
        let family: String
        let core: String
        let art: Bool
    }

    static func refining(records: [Record], keptSources: [CGRect], frame: CGRect, opacity: Double,
                         inpaintingEnabled: Bool, image: CGImage?, readSource: ReadSource,
                         measure: Measure) -> Refinement {
        var result = Refinement()
        guard records.count <= 256, opacity == 1, image != nil, valid(frame),
              records.contains(where: { $0.role != nil }) else { return result }
        let sizes = records.compactMap(\.sourceFontSize).filter { $0.isFinite && $0 > 0 }.sorted()
        let median = sizes.isEmpty ? 0 : sizes[sizes.count / 2]
        let fonts = records.map(\.fontSize).filter { $0 > 0 }.sorted()
        let bodyFont = fonts.isEmpty ? 12 : fonts[fonts.count / 2]
        var candidates: [Candidate] = []
        for record in records {
            guard let role = record.role, ["sfx", "display", "title", "piece"].contains(role),
                  valid(record.source), !record.hidden, !record.preservedGloss, !record.preservedErasure else { continue }
            if inpaintingEnabled && ["display", "title"].contains(role) { continue }
            if record.glyphReplacement { result.rejected[record.id] = "glyphs-replaced"; continue }
            if record.hasBalloon { if role != "piece" { result.rejected[record.id] = "balloon" }; continue }
            let glyph = record.sourceFontSize.flatMap { $0 > 0 ? $0 : nil } ?? Double(min(record.source.width, record.source.height))
            let relative = median > 0 ? glyph / median : 0
            let weak = role == "piece" || (role == "sfx" ? median > 0 && relative < 1 :
                role == "title" ? relative < 3 || record.sourceVertical : relative < 2)
            let text = record.text.replacingOccurrences(of: " +", with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if text.isEmpty || text.utf16.count > (role == "title" ? 32 : 24) {
                if role != "piece" { result.rejected[record.id] = "text" }; continue
            }
            let inks = [rgb(record.sampledForeground), rgb(record.sampledStroke)].compactMap { $0 }
            var share = 0.0, area = 0.0, plated = 0
            for plate in weak ? [] : record.plates where plate.opaque && rgb(plate.colour) != nil {
                plated += 1
                let cover = coverage(plate: plate, source: record.source, inks: inks, frame: frame, readSource: readSource)
                if cover.0 > share { share = cover.0; area = max(area, cover.1) }
            }
            var previous: UnicodeScalar?, core = ""
            for scalar in text.unicodeScalars where (0xAC00...0xD7A3).contains(scalar.value) {
                if scalar != previous { core.unicodeScalars.append(scalar) }; previous = scalar
            }
            candidates.append(Candidate(record: record, role: role, glyph: glyph, text: text, inks: inks,
                plated: plated, cover: share, weak: weak, family: role == "title" ? "title" : "effect", core: core,
                art: !weak && plated > 0 && share >= 0.25 && area >= 120))
        }
        var divider: NativeTranslationGlossPlacement?
        func linked(_ a: Candidate, _ b: Candidate) -> Bool {
            let swapped = a.inks.count == 2 && b.inks.count == 2 && !far(a.inks[0], b.inks[1], 60) && !far(a.inks[1], b.inks[0], 60)
            if a.family != b.family || a.role == "piece" && b.role == "piece" ||
                a.family == "effect" && !a.inks.isEmpty && !b.inks.isEmpty && far(a.inks[0], b.inks[0], 60) && !swapped { return false }
            if a.role == "piece" || b.role == "piece" {
                let piece = a.role == "piece" ? a : b
                return piece.core.utf16.count <= 4 && piece.text.utf16.count <= 8 && touching(a, b)
            }
            if a.family == "title" {
                return touching(a, b) && !a.record.sourceVertical && !b.record.sourceVertical &&
                    abs(a.record.source.midX - b.record.source.midX) <= max(a.record.source.width, b.record.source.width) * 0.25
            }
            if touching(a, b) { return true }
            let lo = min(a.glyph, b.glyph), hi = max(a.glyph, b.glyph)
            if a.family != "effect" || a.core.isEmpty || a.core != b.core || gap(a, b) > hi * 1.6 || hi > lo * 2.5 { return false }
            let u = a.record.source.union(b.record.source)
            let x0 = min(a.record.source.maxX, b.record.source.maxX), x1 = max(a.record.source.minX, b.record.source.minX)
            let y0 = min(a.record.source.maxY, b.record.source.maxY), y1 = max(a.record.source.minY, b.record.source.minY)
            if divider == nil { divider = NativeTranslationGlossPlacement(frame: frame, band: u, fill: [0, 0, 0], ground: nil, image: image) }
            divider!.setBand(u)
            return !(x1 - x0 >= 2 && divider!.divided(CGRect(x: x0, y: u.minY, width: x1 - x0, height: u.height), wide: false)) &&
                !(y1 - y0 >= 2 && divider!.divided(CGRect(x: u.minX, y: y0, width: u.width, height: y1 - y0), wide: true))
        }
        var parents = Array(candidates.indices)
        func find(_ i: Int) -> Int { if parents[i] != i { parents[i] = find(parents[i]) }; return parents[i] }
        for i in candidates.indices { for j in candidates.indices where j > i {
            if find(i) != find(j), linked(candidates[i], candidates[j]) { parents[find(i)] = find(j) }
        } }
        var units: [[Candidate]] = [], roots: [Int] = []
        for i in candidates.indices {
            let root = find(i)
            if let index = roots.firstIndex(of: root) { units[index].append(candidates[i]) }
            else { roots.append(root); units.append([candidates[i]]) }
        }
        var placedInks: [CGRect] = []
        for original in units {
            var unit = original
            guard unit.contains(where: \.art) else {
                for c in unit where c.role != "piece" { result.rejected[c.record.id] = c.weak ? "size" : c.plated > 0 ? "plate-on-flat" : "no-plate" }
                continue
            }
            let vertical = unit.allSatisfy { $0.record.sourceVertical }
            unit.sort { a, b in
                if vertical { return b.record.source.midX < a.record.source.midX }
                if abs(a.record.source.minY - b.record.source.minY) > min(a.glyph, b.glyph) * 0.5 { return a.record.source.minY < b.record.source.minY }
                return a.record.source.minX < b.record.source.minX
            }
            var parts: [[Candidate]] = []
            for c in unit {
                if let index = parts.firstIndex(where: { $0.contains { touching($0, c) } }) { parts[index].append(c) }
                else { parts.append([c]) }
            }
            let lead = unit.first { $0.role != "piece" } ?? unit[0], title = lead.role == "title"
            let texts = parts.map { title ? $0.map(\.text).joined(separator: "\n") : join($0.map(\.text)) }
            var text = texts[0]
            for i in texts.indices.dropFirst() {
                let next = texts[i], prior = texts[i - 1]
                let repeated = singleSyllable(next) && singleSyllable(prior) && next.first == prior.first
                text += (repeated ? "" : " ") + next
            }
            if text.utf16.count > (title ? 40 : 32) { for c in unit { result.rejected[c.record.id] = "text" }; continue }
            let s = union(unit), memberIDs = Set(unit.map { $0.record.id })
            let otherRecords = records.filter { !memberIDs.contains($0.id) }
            var blocked = otherRecords.filter { !$0.hidden }.map(\.ink).filter(valid)
            blocked += otherRecords.flatMap(\.plates).filter(\.opaque).map(\.rect)
            blocked += otherRecords.map(\.source).filter(valid)
            blocked += keptSources.filter(valid)
            blocked += placedInks
            let fill = lead.inks.first ?? rgb(lead.record.appliedForeground) ?? [20, 20, 20]
            let light = luminance(fill) > 0.18, stroke = rgb(lead.record.sampledStroke), spread = fill.max()! - fill.min()!
            let outline: [Double]
            if let stroke, contrast(stroke, fill) >= 3 { outline = stroke }
            else { outline = light ? (spread > 48 ? fill.map { floor($0 * 0.18 + 0.5) } : [17, 18, 23]) : [255, 255, 255] }
            let start = title ? min(26, max(14, floor(lead.glyph * 0.3 * 4 + 0.5) / 4)) :
                min(16, max(11, min(bodyFont, floor(lead.glyph * 0.3 * 4 + 0.5) / 4)))
            let placer = NativeTranslationGlossPlacement(frame: frame, band: s, fill: fill, ground: rgb(lead.record.sampledBackground), image: image)
            let allArea = unit.reduce(0.0) { $0 + Double($1.record.source.width * $1.record.source.height) }
            let tilted = unit.filter { quad($0) != nil }
            let tiltedArea = tilted.reduce(0.0) { $0 + Double($1.record.source.width * $1.record.source.height) }
            let rawAngle = tiltedArea >= allArea * 0.5 && tiltedArea > 0 ?
                tilted.reduce(0.0) { $0 + quad($1)![4] * Double($1.record.source.width * $1.record.source.height) } / tiltedArea : 0
            let degrees = abs(rawAngle) * 180 / .pi
            let angle = degrees < 4 || degrees > 60 ? 0 : degrees <= 30 ? rawAngle : (rawAngle < 0 ? -1 : 1) * .pi / 6
            struct Attempt { let node: Candidate; let text: String; let anchors: [[Candidate]] }
            func attempt(_ requests: [Attempt]) -> [Note]? {
                let before = placedInks.count
                var done: [Note] = []
                for request in requests {
                    guard let first = request.anchors.first else { placedInks.removeSubrange(before...); return nil }
                    let origin = union(first).origin
                    var chosen: NativeTranslationGlossPlacement.Placement?, anchor = -1
                    for (index, anchors) in request.anchors.enumerated() {
                        let own = Set(anchors.map { $0.record.id }), others = unit.filter { !own.contains($0.record.id) }.map { $0.record.source }
                        let options = NativeTranslationGlossPlacement.Options(start: start, minimum: title ? 12 : 9,
                            lines: title ? Double(max(2, request.text.components(separatedBy: "\n").count)) : request.text.contains(" ") && request.text.utf16.count > 12 ? 2 : 1, texture: true)
                        let measuring: NativeTranslationGlossPlacement.Measure = { size, width, lh in
                            measure(request.node.record.id, request.text, size, width, lh, origin, title)
                        }
                        let tilted = angle != 0 ? placer.searchTilted(frame: anchorFrame(anchors, angle: angle),
                            blocked: blocked + others + placedInks, options: options, measure: measuring) : nil
                        let upright = tilted == nil || tilted!.size < start ? placer.search(source: union(anchors),
                            blocked: blocked + others + placedInks, options: options, measure: measuring) : nil
                        chosen = tilted != nil && !(upright != nil && upright!.size > tilted!.size) ? tilted : upright
                        if chosen != nil { anchor = index; break }
                    }
                    guard let placed = chosen else { placedInks.removeSubrange(before...); return nil }
                    let bounds: CGRect
                    if let center = placed.center, let block = placed.block, let angle = placed.angle {
                        let w = abs(cos(angle)) * block.width + abs(sin(angle)) * block.height
                        let h = abs(sin(angle)) * block.width + abs(cos(angle)) * block.height
                        bounds = CGRect(x: center.x - w / 2, y: center.y - h / 2, width: w, height: h)
                    } else {
                        let measured = measure(request.node.record.id, request.text, placed.size, placed.width, placed.lineHeight, origin, title)
                        bounds = zip(measured, placed.moves).reduce(CGRect.null) { $0.union($1.0.offsetBy(dx: $1.1.x, dy: $1.1.y)) }
                    }
                    placedInks.append(bounds.insetBy(dx: -3, dy: -3))
                    done.append(Note(id: request.node.record.id, text: request.text, placement: placed, origin: origin,
                        fill: fill, outline: outline, strokeWidth: max(placed.texture ? 2.5 : 0, max(1.5, min(3.5, placed.size * 0.14))),
                        title: title, members: request.anchors[anchor].map { $0.record.id }, unit: unit.map { $0.record.id }, anchor: anchor, rawAngle: rawAngle))
                }
                return done
            }
            let heads = parts.map { $0.first { $0.role != "piece" } ?? $0[0] }
            var notes: [Note]?
            if parts.count > 1 && heads.allSatisfy({ $0.core.utf16.count >= 2 }) {
                notes = attempt(parts.indices.map { Attempt(node: heads[$0], text: join(parts[$0].map(\.text)), anchors: [parts[$0]]) })
            }
            if notes == nil {
                var anchors: [[Candidate]] = []
                if parts.count == 1 || Double(s.width * s.height) <= allArea * 2.5 { anchors.append(unit) }
                if parts.count > 1 { anchors += parts }
                notes = attempt([Attempt(node: lead, text: text, anchors: anchors)])
            }
            guard let notes else { for c in unit { result.rejected[c.record.id] = "placement" }; continue }
            let painted = records.filter { !memberIDs.contains($0.id) }.map(\.source).filter(valid)
            let notesIDs = Set(notes.map(\.id))
            for c in unit {
                result.removedLayerIDs.insert(c.record.id)
                let pad = max(1, min(4, c.glyph * 0.15))
                for r in ([c.record.source] + c.record.auxiliary).filter(valid) {
                    var pieces = [r.insetBy(dx: -pad, dy: -pad)]
                    for cut in painted { pieces = pieces.flatMap { subtract($0, cut) }; if pieces.count > 64 { break } }
                    result.sourceZones += pieces.filter { $0.width >= 0.5 && $0.height >= 0.5 }.map { SourceZone(rect: $0, id: c.record.id) }
                }
                if !notesIDs.contains(c.record.id) { result.hiddenIDs.insert(c.record.id) }
            }
            result.notes += notes; result.units += 1
        }
        return result
    }

    private static func valid(_ r: CGRect) -> Bool { [r.minX, r.minY, r.width, r.height].allSatisfy(\.isFinite) && r.width > 0 && r.height > 0 }
    private static func rgb(_ a: [Double]?) -> [Double]? { a.flatMap { $0.count == 3 && $0.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 255 }) ? $0 : nil } }
    private static func far(_ a: [Double], _ b: [Double], _ t: Double) -> Bool { zip(a, b).map { abs($0 - $1) }.max()! > t }
    private static func gap(_ a: Candidate, _ b: Candidate) -> Double {
        let a = a.record.source, b = b.record.source
        return Double(max(a.minX - b.maxX, b.minX - a.maxX, a.minY - b.maxY, b.minY - a.maxY))
    }
    private static func touching(_ a: Candidate, _ b: Candidate) -> Bool {
        let lo = min(a.glyph, b.glyph), hi = max(a.glyph, b.glyph)
        return gap(a, b) <= lo * (a.role == "piece" || b.role == "piece" ? 0.3 : 0.6) && hi <= lo * (a.family == "title" ? 4 : 2)
    }
    private static func union(_ a: [Candidate]) -> CGRect { a.reduce(CGRect.null) { $0.union($1.record.source) } }
    private static func join(_ words: [String]) -> String {
        guard var joined = words.first else { return "" }
        let ends = Set("!~…—-"), starts = Set("!?~…—.-")
        func hangul(_ c: Character?) -> Bool { c?.unicodeScalars.count == 1 && c!.unicodeScalars.first.map { (0xAC00...0xD7A3).contains($0.value) } == true }
        for next in words.dropFirst() {
            let concatenate = ((hangul(joined.last) || joined.last.map { ends.contains($0) } == true) && hangul(next.first)) || next.first.map { starts.contains($0) } == true
            joined += (concatenate ? "" : " ") + next
        }
        return joined
    }
    private static func singleSyllable(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first, (0xAC00...0xD7A3).contains(first.value) else { return false }
        return text.unicodeScalars.allSatisfy { $0 == first }
    }
    private static func luminance(_ rgb: [Double]) -> Double {
        let components = rgb.map { v -> Double in let x = v / 255; return x <= 0.04045 ? x / 12.92 : pow((x + 0.055) / 1.055, 2.4) }
        return components[0] * 0.2126 + components[1] * 0.7152 + components[2] * 0.0722
    }
    private static func contrast(_ a: [Double], _ b: [Double]) -> Double { let x = luminance(a), y = luminance(b); return (max(x, y) + 0.05) / (min(x, y) + 0.05) }
    private static func quad(_ c: Candidate) -> [Double]? {
        c.record.sourceQuad.flatMap { $0.count == 5 && $0.allSatisfy(\.isFinite) && $0[2] > 0 && $0[3] > 0 ? $0 : nil }
    }
    private static func anchorFrame(_ members: [Candidate], angle: Double) -> NativeTranslationGlossPlacement.TiltedFrame {
        let c = cos(angle), n = sin(angle), ac = abs(c), aSin = abs(n), determinant = ac * ac - aSin * aSin
        var points: [CGPoint] = []
        func turned(_ x: Double, _ y: Double, _ w: Double, _ h: Double, _ a: Double) {
            for (u, v) in [(-w, -h), (w, -h), (w, h), (-w, h)] { points.append(CGPoint(x: x + u * cos(a) - v * sin(a), y: y + u * sin(a) + v * cos(a))) }
        }
        for member in members {
            let r = member.record.source
            if let q = quad(member) { turned(q[0], q[1], q[2] / 2, q[3] / 2, q[4]); continue }
            let w = (Double(r.width) * ac - Double(r.height) * aSin) / determinant
            let h = (Double(r.height) * ac - Double(r.width) * aSin) / determinant
            if determinant > 0.1 && w > 2 && h > 2 { turned(Double(r.midX), Double(r.midY), w / 2, h / 2, angle) }
            else { points += [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY), CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)] }
        }
        let us = points.map { Double($0.x) * c + Double($0.y) * n }, vs = points.map { -Double($0.x) * n + Double($0.y) * c }
        let u0 = us.min()!, u1 = us.max()!, v0 = vs.min()!, v1 = vs.max()!, mu = (u0 + u1) / 2, mv = (v0 + v1) / 2
        return .init(cx: mu * c - mv * n, cy: mu * n + mv * c, angle: angle, hw: (u1 - u0) / 2, hh: (v1 - v0) / 2)
    }
    private static func coverage(plate: Plate, source: CGRect, inks: [[Double]], frame: CGRect, readSource: ReadSource) -> (Double, Double) {
        let r = plate.rect.intersection(frame)
        guard !r.isNull, r.width >= 2, r.height >= 2 else { return (0, 0) }
        let k = max(1, Double(max(r.width, r.height)) / 64), w = max(2, Int(floor(Double(r.width) / k + 0.5))), h = max(2, Int(floor(Double(r.height) / k + 0.5)))
        guard let data = readSource(r, w, h), data.count == w * h * 4 else { return (0, 0) }
        var counted = 0, covered = 0
        for y in 0..<h { for x in 0..<w {
            let px = r.minX + (CGFloat(x) + 0.5) * r.width / CGFloat(w), py = r.minY + (CGFloat(y) + 0.5) * r.height / CGFloat(h), i = (y * w + x) * 4
            let colour = (0..<3).map { Double(data[i + $0]) }
            if px >= source.minX && px <= source.maxX && py >= source.minY && py <= source.maxY && inks.contains(where: { !far(colour, $0, 48) }) { continue }
            counted += 1; if far(colour, plate.colour, 24) { covered += 1 }
        } }
        return (counted > 0 ? Double(covered) / Double(counted) : 0, Double(covered) * Double(r.width * r.height) / Double(w * h))
    }
    private static func subtract(_ r: CGRect, _ cut: CGRect) -> [CGRect] {
        let overlap = r.intersection(cut)
        if overlap.isNull || overlap.width <= 0 || overlap.height <= 0 { return [r] }
        var pieces: [CGRect] = []
        if overlap.minY > r.minY { pieces.append(CGRect(x: r.minX, y: r.minY, width: r.width, height: overlap.minY - r.minY)) }
        if overlap.maxY < r.maxY { pieces.append(CGRect(x: r.minX, y: overlap.maxY, width: r.width, height: r.maxY - overlap.maxY)) }
        if overlap.minX > r.minX { pieces.append(CGRect(x: r.minX, y: overlap.minY, width: overlap.minX - r.minX, height: overlap.height)) }
        if overlap.maxX < r.maxX { pieces.append(CGRect(x: overlap.maxX, y: overlap.minY, width: r.maxX - overlap.maxX, height: overlap.height)) }
        return pieces
    }
}
