import CoreGraphics
import Foundation

/// Frozen browser plate policy, expressed in display coordinates. All probes
/// use actual shaped ink; no planner boxes stand in for glyph measurements.
enum NativePanelGeometry {
    typealias Panel = NativeTranslationSourceStylePostPolish.Panel
    struct Layer { var rect: CGRect; var color: [Double]; var coverage: [CGRect] }
    struct Compact { var frame: CGRect; var coverage: [CGRect] }
    struct Backing { var frame: CGRect; var coverage: [CGRect]; var color: [Double]; var captionUnionClipped = false; var sourceBridgeClipped = false; var clipped = true; var coverageClip: NativeCSSCoveragePath.Declaration? = nil }
    struct Balloon { var frame: CGRect; var rect: CGRect; var spans: [Double]; var contourVerified: Bool }
    struct Measurement { var glyphs: [CGRect]; var scrollFits: Bool }
    struct Record {
        var id: String
        var ink: CGRect
        var source: CGRect?
        var sources: [CGRect]
        var sourceColorEligible: Bool
        var sourceTextOnly: Bool
        var balancedColumn: Bool
        var vertical: Bool
        var rotation: Double
        var font: Double
        var sourceFont: Double?
        var sourceVertical: Bool
        var inkPadding: Double
        var foreground: [Double]
        var fallbackBackground: [Double]
        var panels: [Panel]
        var restoredSourcePanels = false
        var certifiedErasure = false
        var isFlat = true
        var transparentBackground = true
        var balloon: Balloon? = nil
        var glyphs: [CGRect] = []
        var strokeWidth: Double = 0
        var shift = CGPoint.zero
        var backings: [Backing] = []
        var reflowFrame: CGRect? = nil
        var reflowFont: Double? = nil
        var balloonResult: String? = nil
    }

    static func valid(_ r: CGRect) -> Bool {
        [r.origin.x, r.origin.y, r.size.width, r.size.height].allSatisfy(\.isFinite) && r.size.width > 0 && r.size.height > 0
    }
    static func solidPanelCoverage(_ rects: [CGRect]) -> [CGRect] {
        guard !rects.isEmpty, rects.count <= 512, rects.allSatisfy(valid) else { return [] }
        let left = rects.map(\.minX).min()!, top = rects.map(\.minY).min()!
        return [CGRect(x: left, y: top, width: rects.map(\.maxX).max()! - left, height: rects.map(\.maxY).max()! - top)]
    }
    static func inside(_ inner: CGRect, _ outer: CGRect, tolerance: CGFloat = 0.04) -> Bool {
        inner.minX >= outer.minX - tolerance && inner.minY >= outer.minY - tolerance &&
            inner.maxX <= outer.maxX + tolerance && inner.maxY <= outer.maxY + tolerance
    }
    static func intersects(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = 0) -> Bool {
        min(a.maxX, b.maxX) - max(a.minX, b.minX) > tolerance && min(a.maxY, b.maxY) - max(a.minY, b.minY) > tolerance
    }
    static func overlap(_ a: CGRect, _ b: CGRect) -> CGFloat {
        max(0, min(a.maxX, b.maxX) - max(a.minX, b.minX)) * max(0, min(a.maxY, b.maxY) - max(a.minY, b.minY))
    }
    static func padded(_ r: CGRect, _ amount: CGFloat) -> CGRect { r.insetBy(dx: -amount, dy: -amount) }

    static func compactPanel(_ panel: CGRect, ink: CGRect, required: [CGRect], neighbors: [CGRect], pad: Double = 3) -> Compact? {
        guard valid(panel), valid(ink), required.allSatisfy(valid), neighbors.allSatisfy(valid), pad.isFinite, pad >= 0,
              inside(ink, panel) else { return nil }
        func intersect(_ r: CGRect, _ padding: CGFloat) -> CGRect? {
            var left = max(panel.minX, floor((r.minX - padding) * 64) / 64)
            var top = max(panel.minY, floor((r.minY - padding) * 64) / 64)
            var right = min(panel.maxX, ceil((r.maxX + padding) * 64) / 64)
            var bottom = min(panel.maxY, ceil((r.maxY + padding) * 64) / 64)
            if left - panel.minX < 1 { left = panel.minX }; if top - panel.minY < 1 { top = panel.minY }
            if panel.maxX - right < 1 { right = panel.maxX }; if panel.maxY - bottom < 1 { bottom = panel.maxY }
            return right > left && bottom > top ? CGRect(x: left, y: top, width: right - left, height: bottom - top) : nil
        }
        let regions = ([ink] + required).compactMap { intersect($0, CGFloat(pad)) } + neighbors.compactMap { intersect($0, 2) }
        let coverage = regions.enumerated().filter { i, r in
            !regions.enumerated().contains { j, q in j != i && inside(r, q, tolerance: 0) && (q != r || j < i) }
        }.map(\.element)
        guard let frame = solidPanelCoverage(coverage).first else { return nil }
        return Compact(frame: frame, coverage: [frame])
    }

    /// Ordered disjoint pieces: top, bottom, left, right. Deliberately not
    /// CGRect.subtract/intersection: zero-area edge contact remains unchanged.
    static func subtractRects(_ rects: [CGRect], cut: CGRect) -> [CGRect] {
        rects.flatMap { a in
            guard intersects(a, cut) else { return [a] }
            let top = max(a.minY, cut.minY), bottom = min(a.maxY, cut.maxY)
            return [CGRect(x: a.minX, y: a.minY, width: a.width, height: cut.minY - a.minY),
                    CGRect(x: a.minX, y: cut.maxY, width: a.width, height: a.maxY - cut.maxY),
                    CGRect(x: a.minX, y: top, width: cut.minX - a.minX, height: bottom - top),
                    CGRect(x: cut.maxX, y: top, width: a.maxX - cut.maxX, height: bottom - top)]
                .filter { $0.size.width > 0 && $0.size.height > 0 }
        }
    }
    static func visiblePanelColors(_ ink: CGRect, layers: [Layer], fallback: [Double]) -> [[Double]] {
        var remaining = [ink], colors: [[Double]] = []
        for layer in layers.reversed() {
            var visible = false
            for cover in layer.coverage {
                remaining = remaining.flatMap { rect in
                    guard intersects(rect, cover, tolerance: 0.04) else { return [rect] }
                    visible = true
                    return subtractRects([rect], cut: cover)
                }
            }
            if visible { colors.append(layer.color) }; if remaining.isEmpty { break }
        }
        if !remaining.isEmpty { colors.append(fallback) }
        var unique: [[Double]] = []
        for color in colors where color.count == 3 && color.allSatisfy(\.isFinite) && !unique.contains(color) { unique.append(color) }
        return unique
    }
    static func textBackingRect(_ ink: CGRect, panel: CGRect, neighbors: [CGRect]) -> CGRect? {
        guard valid(ink), valid(panel), neighbors.allSatisfy(valid), inside(ink, panel) else { return nil }
        for pad: CGFloat in [2, 1, 0] {
            let left = max(panel.minX, ink.minX - pad), top = max(panel.minY, ink.minY - pad)
            let right = min(panel.maxX, ink.maxX + pad), bottom = min(panel.maxY, ink.maxY + pad)
            let frame = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            if neighbors.contains(where: { overlap(frame, $0) > 0.04 }) { continue }
            return frame
        }
        return nil
    }
    static func needsTextBacking(_ ink: CGRect?, owner: Int, panels: [Layer]) -> Bool {
        guard let ink, panels.indices.contains(owner) else { return false }
        return panels.dropFirst(owner + 1).contains { $0.color != panels[owner].color && intersects(ink, $0.rect, tolerance: 0.04) }
    }
    static func textBackingKeepsContrast(_ ink: CGRect?, owner: Int, panels: [Layer], contrast: ([Double]) -> Double) -> Bool {
        guard let ink, panels.indices.contains(owner) else { return false }
        let own = contrast(panels[owner].color)
        guard own.isFinite, own >= 1 else { return false }
        return panels.dropFirst(owner + 1).allSatisfy { panel in
            if !intersects(ink, panel.rect, tolerance: 0.04) { return true }
            let other = contrast(panel.color); return other.isFinite && own + 1e-6 >= other
        }
    }
    static func sourceAnchorShift(_ ink: CGRect, source: CGRect, plate: CGRect, obstacles: [CGRect], leavesOverlap: Bool = false) -> CGPoint? {
        guard valid(ink), valid(source), valid(plate), obstacles.allSatisfy(valid) else { return nil }
        let interior = plate.insetBy(dx: 3, dy: 3)
        guard inside(ink, interior) else { return nil }
        let wantedX = source.minX + source.width / 2 - ink.minX - ink.width / 2
        let wantedY = source.minY + source.height / 2 - ink.minY - ink.height / 2
        if abs(wantedX) <= max(2, source.width * 0.2) && abs(wantedY) <= max(2, source.height * 0.2) { return nil }
        func snap(_ v: CGFloat) -> CGFloat { (v * 64).rounded(.towardZero) / 64 }
        let dx = snap(min(plate.maxX - 3 - ink.width, max(plate.minX + 3, ink.minX + wantedX)) - ink.minX)
        let dy = snap(min(plate.maxY - 3 - ink.height, max(plate.minY + 3, ink.minY + wantedY)) - ink.minY)
        func distance(_ x: CGFloat, _ y: CGFloat) -> CGFloat { pow((wantedX - x) / source.width, 2) + pow((wantedY - y) / source.height, 2) }
        var best: CGPoint?, bestDistance = distance(0, 0)
        for (x, y) in [(dx, dy), (dx, 0), (0, dy)] {
            if hypot(x, y) < 1 || abs(wantedX - x) > abs(wantedX) + 0.001 || abs(wantedY - y) > abs(wantedY) + 0.001 { continue }
            let moved = ink.offsetBy(dx: x, dy: y)
            let swept = CGRect(x: min(ink.minX, moved.minX), y: min(ink.minY, moved.minY), width: ink.width + abs(x), height: ink.height + abs(y))
            if !inside(moved, interior) || obstacles.contains(where: { o in
                let current = overlap(ink, o)
                return leavesOverlap && current > 0.04 ? overlap(moved, o) > current + 0.04 : overlap(swept, o) > current + 0.04
            }) { continue }
            let score = distance(x, y)
            if score < bestDistance - 0.0001 { best = CGPoint(x: x, y: y); bestDistance = score }
        }
        return best
    }

    /// Unified-cell packing admission: a valid previous ink position is proof
    /// that repartitioning must not substantially increase source displacement.
    static func packingRetainsSourceAnchor(originalInk: CGRect, proposedInk: CGRect, source: CGRect,
                                          cell: CGRect, obstacles: [CGRect]) -> Bool {
        let shift = sourceAnchorShift(proposedInk, source: source, plate: cell, obstacles: obstacles) ?? .zero
        let sx = source.minX + source.width / 2, sy = source.minY + source.height / 2
        let oldDistance = hypot(originalInk.minX + originalInk.width / 2 - sx, originalInk.minY + originalInk.height / 2 - sy)
        let distance = hypot(proposedInk.minX + proposedInk.width / 2 + shift.x - sx, proposedInk.minY + proposedInk.height / 2 + shift.y - sy)
        let tolerance = max(4, min(8, min(source.width, source.height) * 0.15))
        return distance <= oldDistance + tolerance
    }

    /// Late source anchor after a measured unified-caption cell is committed.
    /// `home` must be its actual pre-partition footprint, not an OCR rectangle.
    static func finalSourceAnchorShift(_ ink: CGRect, source: CGRect, plate: CGRect, obstacles: [CGRect],
                                       home: CGRect?, sourceFont: Double?, nonSpaceCharacters: Int) -> CGPoint? {
        var shift = sourceAnchorShift(ink, source: source, plate: plate, obstacles: obstacles)
        if let home, let back = sourceAnchorShift(ink, source: source, plate: plate, obstacles: obstacles, leavesOverlap: true) {
            func miss(_ s: CGPoint?) -> CGFloat {
                hypot(ink.minX + ink.width / 2 + (s?.x ?? 0) - source.minX - source.width / 2,
                      ink.minY + ink.height / 2 + (s?.y ?? 0) - source.minY - source.height / 2)
            }
            let landed = overlap(ink.offsetBy(dx: back.x, dy: back.y), home)
            let glyph = sourceFont.flatMap { $0 > 0 ? $0 : nil } ?? Double(min(source.width, source.height))
            let room = Double(home.width * home.height) / max(1, Double(nonSpaceCharacters) * pow(0.75 * glyph, 2) * 1.3)
            if miss(back) < miss(shift) - 0.5 && landed >= 0.9 * ink.width * ink.height && room >= 1 { shift = back }
        }
        return shift
    }

    /// Source-anchor commit, protected late backings, conservative plate trim,
    /// then contrast on visible surfaces. Panels retain their input paint order.
    enum Phase { case all, anchorBacking, compactContrast, compactOnly }

    static func polish(_ input: [Record], opacity: Double, phase: Phase = .all) -> [Record] {
        guard opacity == 1, input.count <= 256, input.reduce(0, { $0 + $1.panels.count }) <= 512 else { return input }
        var records = input
        func layers() -> [Layer] { records.flatMap { r in r.panels.map { .init(rect: $0.rect, color: $0.background, coverage: $0.coverage.isEmpty ? [$0.rect] : $0.coverage) } } }
        func owner(_ index: Int) -> Int? {
            guard let local = records[index].panels.lastIndex(where: { !$0.sourceErasure }) else { return nil }
            return records.prefix(index).reduce(0, { $0 + $1.panels.count }) + local
        }
        func neighbors(_ index: Int) -> [CGRect] { records.indices.filter { $0 != index }.map { records[$0].ink }.filter(valid) }
        func contrast(_ color: [Double], _ bg: [Double]) -> Double { NativeTranslationSourceStylePostPolish.sourceColorContrast(color, panel: bg) }
        let frozen = layers()
        if phase == .all || phase == .anchorBacking {
        for i in records.indices {
            let r = records[i]
            guard r.sourceColorEligible, !r.sourceTextOnly, !r.balancedColumn, !r.vertical, r.rotation == 0,
                  r.transparentBackground, let source = r.source, let owner = owner(i) else { continue }
            let obstacles = records.indices.filter { $0 != i }.flatMap { [padded(records[$0].ink, 1)] + (records[$0].source.map { [$0] } ?? []) }.filter(valid)
            guard let shift = sourceAnchorShift(r.ink, source: source, plate: frozen[owner].rect, obstacles: obstacles) else { continue }
            let moved = r.ink.offsetBy(dx: shift.x, dy: shift.y)
            guard textBackingKeepsContrast(r.ink, owner: owner, panels: frozen, contrast: { contrast(r.foreground, $0) }),
                  textBackingKeepsContrast(moved, owner: owner, panels: frozen, contrast: { contrast(r.foreground, $0) }),
                  !needsTextBacking(moved, owner: owner, panels: frozen) || textBackingRect(moved, panel: frozen[owner].rect, neighbors: neighbors(i)) != nil else { continue }
            records[i].ink = moved; records[i].shift.x += shift.x; records[i].shift.y += shift.y
            records[i].glyphs = r.glyphs.map { $0.offsetBy(dx: shift.x, dy: shift.y) }
        }
        for i in records.indices {
            let r = records[i]
            guard let own = owner(i), needsTextBacking(r.ink, owner: own, panels: frozen),
                  textBackingKeepsContrast(r.ink, owner: own, panels: frozen, contrast: { contrast(r.foreground, $0) }),
                  let backing = textBackingRect(r.ink, panel: frozen[own].rect, neighbors: neighbors(i)) else { continue }
            records[i].backings.append(.init(frame: frozen[own].rect, coverage: [backing], color: frozen[own].color, coverageClip: NativeCSSCoveragePath.percentageInset(coverage: backing, owner: frozen[own].rect)))
        }
        }
        if phase != .anchorBacking {
        for i in records.indices {
            let r = records[i]
            guard !r.sourceTextOnly, !r.balancedColumn, let local = r.panels.lastIndex(where: { !$0.sourceErasure }) else { continue }
            let old = r.panels[local].rect, pad = max(r.inkPadding, max(3, min(6, r.font * 0.3)))
            let fringe = max(0, min(16, r.sourceFont.flatMap { $0.isFinite ? $0 : nil } ?? pad) - pad)
            let required = r.restoredSourcePanels || r.certifiedErasure ? [] : r.sources.map {
                $0.insetBy(dx: r.sourceVertical ? -fringe : 0, dy: r.sourceVertical ? 0 : -fringe)
            }
            let foreign = records.indices.filter { $0 != i && !records[$0].restoredSourcePanels }.flatMap { j -> [CGRect] in
                let other = records[j], cross = max(3, min(16, other.sourceFont.flatMap { $0.isFinite ? $0 : nil } ?? 3))
                return other.sources.filter(valid).map { $0.insetBy(dx: other.sourceVertical ? -cross : -3, dy: other.sourceVertical ? -3 : -cross) }.filter { intersects($0, old) }
            }
            guard let compact = compactPanel(old, ink: r.ink, required: required, neighbors: neighbors(i) + foreign, pad: pad) else { continue }
            records[i].panels[local].rect = compact.frame; records[i].panels[local].coverage = compact.coverage
        }
        if phase != .compactOnly {
        var visibleLayers = layers() + records.flatMap { r in r.backings.map { .init(rect: $0.frame, color: $0.color, coverage: $0.coverage) } }
        for i in records.indices {
            let r = records[i]
            guard r.sourceColorEligible, !r.sourceTextOnly, valid(r.ink), r.foreground.count == 3,
                  r.foreground.allSatisfy(\.isFinite), let local = r.panels.lastIndex(where: { !$0.sourceErasure }) else { continue }
            var surfaces = visiblePanelColors(r.ink, layers: visibleLayers, fallback: r.fallbackBackground)
            guard !surfaces.isEmpty else { continue }
            let colored = r.foreground.max()! - r.foreground.min()! >= 40
            let target = r.font >= 18 && colored && surfaces.allSatisfy { NativeTranslationSourceStylePostPolish.luminance(r.foreground) < NativeTranslationSourceStylePostPolish.luminance($0) } ? 3.0 : 4.5
            func score(_ color: [Double]) -> Double { surfaces.map { contrast(color, $0) }.min() ?? 0 }
            if score(r.foreground) >= target { continue }
            if surfaces.contains(where: { $0 != r.fallbackBackground }),
               let rect = textBackingRect(r.ink, panel: r.panels[local].rect, neighbors: neighbors(i)) {
                let backing = Backing(frame: r.panels[local].rect, coverage: [rect], color: r.panels[local].background, coverageClip: NativeCSSCoveragePath.percentageInset(coverage: rect, owner: r.panels[local].rect))
                records[i].backings.append(backing)
                visibleLayers.append(.init(rect: backing.frame, color: r.fallbackBackground, coverage: backing.coverage))
                surfaces = [r.fallbackBackground]
            }
            let adjusted = NativeTranslationSourceStylePostPolish.adjustInkForContrast(r.foreground, contrast: score, target: target)
            if score(adjusted) >= score(r.foreground) { records[i].foreground = adjusted }
        }
        }
        }
        return records
    }

    /// Exact final contour policy. Reflow is accepted only after the platform
    /// shaper returns visible line rectangles and independent overflow proof.
    static func containBalloonPanels(_ input: [Record], measure: ((String, CGRect, Double) -> Measurement?)? = nil) -> [Record] {
        guard input.count <= 256, input.reduce(0, { $0 + $1.panels.count }) <= 512 else { return input }
        var records = input, checks = 131_072
        let sources = records.flatMap(\.sources)
        let inks = records.flatMap { r in r.glyphs.filter(valid).map { padded($0, 0.5 + CGFloat(r.strokeWidth) / 2) } }
        guard sources.count <= 2048, inks.count <= 2048 else { return input }
        for i in records.indices {
            guard let b = records[i].balloon, b.contourVerified, records[i].rotation == 0, records[i].isFlat,
                  b.spans.count >= 4, b.spans.count <= 1024, b.spans.count.isMultiple(of: 2), b.spans.allSatisfy(\.isFinite),
                  [b.rect.minX, b.rect.minY, b.rect.width, b.rect.height].allSatisfy(\.isFinite) else { continue }
            let top = b.frame.minY + b.rect.minY * b.frame.height, height = b.rect.height * b.frame.height, bands = b.spans.count / 2
            guard height > 0 else { continue }
            func rows(_ r: CGRect) -> ClosedRange<Int>? {
                let first = max(0, Int(floor((r.minY - top) / height * CGFloat(bands))))
                let last = min(bands - 1, Int(ceil((r.maxY - top) / height * CGFloat(bands))) - 1)
                return first <= last ? first...last : nil
            }
            func contourInside(_ r: CGRect) -> Bool {
                guard r.minY >= top, r.maxY <= top + height else { return false }
                if let range = rows(r) {
                    for y in range {
                        checks -= 1
                        if checks < 0 || b.spans[y * 2] < 0 || b.spans[y * 2 + 1] <= b.spans[y * 2] ||
                            r.minX < b.frame.minX + b.spans[y * 2] * b.frame.width ||
                            r.maxX > b.frame.minX + b.spans[y * 2 + 1] * b.frame.width { return false }
                    }
                }
                return true
            }
            for p in records[i].panels.indices {
                let panel = records[i].panels[p]
                if panel.sourceErasure || panel.rotated || !panel.isFlat { continue }
                let coverage = panel.coverage.isEmpty ? [panel.rect] : panel.coverage
                guard coverage.count <= 512, coverage.allSatisfy({ [$0.minX, $0.minY, $0.width, $0.height].allSatisfy(\.isFinite) }) else { continue }
                if coverage.allSatisfy(contourInside) { continue }
                let required = (sources + inks).filter { r in coverage.contains { intersects($0, r) } }
                if required.isEmpty { continue }
                if let envelope = solidPanelCoverage(required).first, contourInside(envelope) {
                    var chosen = envelope
                    for pad: CGFloat in [2, 1, 0] {
                        let candidate = padded(envelope, pad)
                        if inside(candidate, panel.rect, tolerance: 0) && contourInside(candidate) { chosen = candidate; break }
                    }
                    if !inside(chosen, panel.rect, tolerance: 0) { continue }
                    records[i].panels[p].coverage = [chosen]; records[i].panels[p].clipped = true
                    records[i].panels[p].coverageClip = NativeCSSCoveragePath.inset([chosen.minY-panel.rect.minY, panel.rect.maxX-chosen.minX-chosen.width, panel.rect.maxY-chosen.minY-chosen.height, chosen.minX-panel.rect.minX], unit: .pixels)
                    records[i].balloonResult = "rectangular"
                    continue
                }
                guard let source = solidPanelCoverage(sources.filter { r in coverage.contains { intersects($0, r) } }).first,
                      contourInside(source), let measure else { records[i].balloonResult = "source-or-ink-outside"; continue }
                let foreign = records.indices.filter { $0 != i }.flatMap { records[$0].glyphs.filter(valid) }
                let font = records[i].font
                var fit: (CGRect, Double, Measurement)?
                if font > 0 {
                    for extra: CGFloat in [0, 4, 8, 12, 16] {
                        if fit != nil { break }
                        for up in [CGFloat(0), extra / 2, extra] {
                            let y = source.minY - up - 1, h = source.height + extra + 2
                            if y < top || y + h > top + height { continue }
                            var left = -CGFloat.infinity, right = CGFloat.infinity
                            let yRect = CGRect(x: 0, y: y, width: 1, height: h)
                            if let range = rows(yRect) {
                                for row in range {
                                    checks -= 1
                                    if checks < 0 || b.spans[row * 2] < 0 { left = .infinity; break }
                                    left = max(left, b.frame.minX + b.spans[row * 2] * b.frame.width + 0.5)
                                    right = min(right, b.frame.minX + b.spans[row * 2 + 1] * b.frame.width - 0.5)
                                }
                            }
                            let candidate = CGRect(x: left, y: y, width: right - left, height: h)
                            if candidate.width <= 4 || left > source.minX || right < source.maxX || candidate.width * h > panel.rect.width * panel.rect.height * 1.15 ||
                                !contourInside(candidate) || foreign.contains(where: { intersects($0, candidate) }) { continue }
                            for step in 0...4 {
                                let size = font - Double(step) * 0.25
                                if size < max(5, font * 0.85) { break }
                                guard let proof = measure(records[i].id, candidate, size), proof.scrollFits,
                                      !proof.glyphs.isEmpty, proof.glyphs.allSatisfy(valid),
                                      proof.glyphs.allSatisfy({ inside(padded($0, 0.5 + CGFloat(records[i].strokeWidth) / 2), candidate, tolerance: 0) }) else { continue }
                                fit = (candidate, size, proof); break
                            }
                            if fit != nil { break }
                        }
                    }
                }
                guard let fit else { records[i].balloonResult = "no-safe-rectangle"; continue }
                records[i].panels[p].rect = fit.0; records[i].panels[p].coverage = [fit.0]; records[i].panels[p].clipped = false; records[i].panels[p].coverageClip = nil
                records[i].reflowFrame = fit.0; records[i].reflowFont = fit.1; records[i].glyphs = fit.2.glyphs
                records[i].ink = solidPanelCoverage(fit.2.glyphs).first ?? records[i].ink
                records[i].balloonResult = "reflowed-rectangle"
            }
        }
        return records
    }
}
