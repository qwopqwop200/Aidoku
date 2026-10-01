import CoreGraphics
import Foundation

/// Unified opaque captions: source coverage remains owned throughout cell
/// preflight, final font fitting, source anchoring and foreign surface repaint.
/// The renderer supplies actual shaped ink for every typography probe.
enum NativeCaptionPacking {
    struct Panel {
        var rect: CGRect
        var color: [Double]
        var coverage: [CGRect] = []
        var sourceErasure = false
        var clipped = false
        var backing = false
        var radius: Double = 3
        var coverageClip: NativeCSSCoveragePath.Declaration? = nil
        /// Separate current CSS state from the caption-union policy marker.
        var coverageClipActive: Bool? = nil
    }
    struct Pixels { let rgba: [UInt8]; let width: Int; let height: Int }
    struct ForeignFill {
        let rect: CGRect
        let color: [Double]
        // Declared CSS image geometry survives later owner box changes.
        var backgroundPosition: CGPoint? = nil
        var backgroundSize: CGSize? = nil
    }
    struct Entry {
        var id: String
        var text: String
        var font: Double
        var originalFont: Double? = nil
        var lineRatio: Double = 1.2
        var ink: CGRect
        var source: CGRect?
        var sourceFont: Double? = nil
        var vertical = false
        var rotation: Double = 0
        var balancedColumn = false
        var packingValid = false
        var panels: [Panel]
        var sources: [CGRect] = []
        var isUnit = false
        var unitResidue = false
        var sourceErasurePreserved = false
        var oversizedUnrestored = false
        var readabilityPanel = true
        var hasBackgroundImage = false
        var relayoutTextRect: CGRect? = nil
        var relayoutLinePitch: Double? = nil
        var cell: CGRect? = nil
        var content: CGRect? = nil
        var unified = false
        var fitPreserved: String? = nil
        var compactOriginal: CGRect? = nil
        var ownFootprint: CGRect? = nil
        var requiredCoverage: [CGRect] = []
        var foreignFills: [ForeignFill] = []
        var finalAnchorOriginalInk: CGRect? = nil
        var finalAnchorShift: CGPoint? = nil
    }
    struct Measurement { let ink: CGRect; var scrollFits = true }
    struct Relayout { let ink: CGRect; let font: Double; let sources: [CGRect]; var textRect: CGRect? = nil; var linePitch: Double? = nil; var packingValid: Bool? = nil; var interiorOutside: ((CGRect) -> Double)? = nil }
    struct Result { let entries: [Entry]; let measurements: Int; let fallbacks: Int; let balloonLayouts: Int; var skippedIDs: Set<String> = [] }
    private struct Caption {
        let index: Int
        let owner: Int
        var box: CGRect
        let center: CGPoint
        var repartitioning = false
        var compact: CGRect?
        var covered: [CGRect] = []
        var owners: [(Int, CGRect)] = []
        var own: CGRect?
        var skipped = false
    }
    private struct Group { var members: [Int]; var box: CGRect }

    static func captionFloor(_ original: Double, minimum: Double) -> Double? {
        guard original.isFinite, original > 0, minimum.isFinite, minimum > 0 else { return nil }
        return max(minimum, min(original, 8.5), original * 0.8)
    }

    /// The browser reads the committed owner's DOM rectangle before this
    /// final anchor; its authored cell dimensions are retained separately.
    static func anchorPackedCaption(_ input: Entry, obstacles: [CGRect], home: CGRect?,
                                    usedPanelRect: (CGRect) -> CGRect = { $0 }) -> Entry {
        var e = input
        guard let source = e.source, valid(source), !e.vertical, e.rotation == 0, !e.balancedColumn,
              let authoredPlate = e.cell else { return e }
        let plate = usedPanelRect(authoredPlate)
        guard valid(plate), let shift = NativePanelGeometry.finalSourceAnchorShift(e.ink, source: source, plate: plate,
            obstacles: obstacles, home: home, sourceFont: e.sourceFont,
            nonSpaceCharacters: e.text.replacingOccurrences(of: " ", with: "").utf16.count) else { return e }
        let moved = e.ink.offsetBy(dx: shift.x, dy: shift.y)
        guard contains(plate.insetBy(dx: 3, dy: 3), moved, tolerance: 0.04) else { return e }
        e.finalAnchorOriginalInk = e.ink; e.finalAnchorShift = shift; e.ink = moved
        return e
    }

    static func pack(_ input: [Entry], page: CGRect?, minimumFont: Double = 5, opacity: Double,
                     measure: (Entry, CGRect, Double) -> Measurement?,
                     readSource: ((CGRect, Int, Int) -> Pixels?)? = nil,
                     balloonRelayout: ((Entry) -> Relayout?)? = nil,
                     usedPanelRect: (CGRect) -> CGRect = { $0 }) -> Result {
        guard input.count <= 4_096 else { return Result(entries: input, measurements: 0, fallbacks: 0, balloonLayouts: 0) }
        var entries = input, balloonLayouts = 0
        let page = page.flatMap { valid($0) ? $0 : nil }
        if opacity == 1, input.count <= 256, let balloonRelayout {
            for i in entries.indices {
                let e = entries[i], owned = e.panels.filter { !$0.backing }
                guard e.rotation == 0, e.readabilityPanel, !e.sourceErasurePreserved, owned.count == 1,
                      e.panels.count == 1, !owned[0].sourceErasure, !owned[0].clipped, valid(e.ink),
                      let result = balloonRelayout(e), valid(result.ink), !result.sources.isEmpty else { continue }
                let padding = CGFloat(max(3, min(6, result.font * 0.3)))
                let boxes = result.sources + (e.isUnit ? e.source.map { [$0] } ?? [] : []) + [result.ink]
                var target = union(boxes).insetBy(dx: -padding, dy: -padding)
                if let page { target = intersection(target, page) }
                if area(target) > area(owned[0].rect) + 0.5 &&
                    (!e.isUnit || e.unitResidue || (result.interiorOutside?(target) ?? .infinity) > 2) { continue }
                entries[i].font = result.font; entries[i].ink = result.ink; entries[i].panels[0].rect = target
                entries[i].relayoutTextRect = result.textRect; entries[i].relayoutLinePitch = result.linePitch
                if let pitch = result.linePitch, result.font > 0 { entries[i].lineRatio = pitch / result.font }
                if let fits = result.packingValid { entries[i].packingValid = fits }
                balloonLayouts += 1
            }
        }
        var captions: [Caption] = []
        for i in entries.indices {
            let e = entries[i]
            let indices = e.panels.indices.filter { !e.panels[$0].backing }
            guard e.rotation == 0, valid(e.ink), !indices.isEmpty else { continue }
            let owner = indices.first(where: { !e.panels[$0].sourceErasure }) ?? indices[0]
            let plate = union(indices.map { e.panels[$0].rect })
            let paddedInk = e.ink.insetBy(dx: -3, dy: -3)
            var left = min(paddedInk.minX, plate.minX), top = min(paddedInk.minY, plate.minY)
            var right = max(paddedInk.maxX, plate.maxX), bottom = max(paddedInk.maxY, plate.maxY)
            if let page {
                left = max(page.minX - 3, left); top = max(page.minY - 3, top)
                right = min(page.maxX + 3, right); bottom = min(page.maxY + 3, bottom)
            }
            if left < plate.minX - 0.5, frameLine(rect(left, plate.minY, plate.minX, plate.maxY), vertical: true, read: readSource) { left = plate.minX }
            if right > plate.maxX + 0.5, frameLine(rect(plate.maxX, plate.minY, right, plate.maxY), vertical: true, read: readSource) { right = plate.maxX }
            if top < plate.minY - 0.5, frameLine(rect(plate.minX, top, plate.maxX, plate.minY), vertical: false, read: readSource) { top = plate.minY }
            if bottom > plate.maxY + 0.5, frameLine(rect(plate.minX, plate.maxY, plate.maxX, bottom), vertical: false, read: readSource) { bottom = plate.maxY }
            guard right - left > 6, bottom - top > 6 else { continue }
            let box = rect(left, top, right, bottom)
            captions.append(Caption(index: i, owner: owner, box: box, center: CGPoint(x: (left + right) / 2, y: (top + bottom) / 2)))
        }
        var groups = captions.indices.map { Group(members: [$0], box: captions[$0].box) }
        var changed = true
        while changed {
            changed = false
            outer: for i in groups.indices {
                for j in groups.indices where j > i {
                    if !hit(groups[i].box, groups[j].box, 0.5) { continue }
                    groups[i].members += groups[j].members
                    groups[i].box = union([groups[i].box, groups[j].box]); groups.remove(at: j)
                    changed = true; break outer
                }
            }
        }
        func partition(_ members: [Int], _ box: CGRect, _ invert: Bool) -> [Int: CGRect] {
            if members.count == 1 { return [members[0]: box] }
            let spreadX = members.map { captions[$0].center.x }.max()! - members.map { captions[$0].center.x }.min()!
            let spreadY = members.map { captions[$0].center.y }.max()! - members.map { captions[$0].center.y }.min()!
            let preferred = spreadX / max(1, box.width) >= spreadY / max(1, box.height)
            let horizontal = invert ? !preferred : preferred
            let order = members.enumerated().sorted { a, b in
                let x = horizontal ? captions[a.element].center.x : captions[a.element].center.y
                let y = horizontal ? captions[b.element].center.x : captions[b.element].center.y
                return x == y ? a.offset < b.offset : x < y
            }.map(\.element)
            let middle = order.count / 2, first = Array(order.prefix(middle)), last = Array(order.suffix(from: middle))
            let low = horizontal ? box.minX : box.minY, high = horizontal ? box.maxX : box.maxY
            let ideal = horizontal ? (captions[first.last!].center.x + captions[last[0]].center.x) / 2 :
                (captions[first.last!].center.y + captions[last[0]].center.y) / 2
            let cut = max(low + (high - low) * 0.15, min(high - (high - low) * 0.15, ideal))
            let a = horizontal ? rect(box.minX, box.minY, cut, box.maxY) : rect(box.minX, box.minY, box.maxX, cut)
            let b = horizontal ? rect(cut, box.minY, box.maxX, box.maxY) : rect(box.minX, cut, box.maxX, box.maxY)
            return partition(first, a, invert).merging(partition(last, b, invert)) { a, _ in a }
        }
        let originalInks = entries.map(\.ink)
        var budget = 512, fallbacks = 0
        func floorFor(_ e: Entry, _ repartitioning: Bool) -> Double? {
            captionFloor(repartitioning ? max(e.font, e.originalFont ?? e.font) : e.font, minimum: minimumFont)
        }
        func probe(_ c: Caption, _ box: CGRect) -> Bool {
            let allowance = budget; budget -= 1
            guard allowance > 0 else { return false }
            let e = entries[c.index]
            guard let floor = floorFor(e, c.repartitioning), floor <= e.font + 0.01,
                  let measured = measure(e, box, floor), valid(measured.ink) else { return false }
            if c.repartitioning, e.packingValid, let source = e.source, valid(source) {
                let obstacles = originalInks.enumerated().filter { $0.offset != c.index && valid($0.element) }.map(\.element)
                if !NativePanelGeometry.packingRetainsSourceAnchor(originalInk: originalInks[c.index], proposedInk: measured.ink,
                    source: source, cell: box, obstacles: obstacles) { return false }
            }
            return contains(box.insetBy(dx: 3, dy: 3), measured.ink, tolerance: 0.5)
        }
        for group in groups {
            let footprints = group.members.map { captions[$0].box }
            for member in group.members { captions[member].repartitioning = group.members.count > 1 }
            var selected: [Int: CGRect]?
            for invert in group.members.count > 1 ? [false, true] : [false] {
                let trial = partition(group.members, group.box, invert)
                if group.members.allSatisfy({ probe(captions[$0], trial[$0]!) }) { selected = trial; break }
            }
            guard let selected else {
                for (j, member) in group.members.enumerated() {
                    captions[member].box = footprints[j]; captions[member].skipped = true
                    entries[captions[member].index].fitPreserved = budget < 0 ? "budget-preserved" : "floor-preserved"
                }
                fallbacks += 1; continue
            }
            for (j, member) in group.members.enumerated() {
                let cell = selected[member]!, covered = footprints.map { intersection($0, cell) }.filter(valid)
                captions[member].box = cell; captions[member].covered = covered
                captions[member].owners = footprints.enumerated().filter { $0.offset != j }.map {
                    (captions[group.members[$0.offset]].index, intersection($0.element, cell))
                }.filter { valid($0.1) }
                captions[member].own = intersection(footprints[j], cell)
                if !covered.isEmpty {
                    let compact = union(covered)
                    if area(compact) < area(cell) - 1 { captions[member].compact = compact }
                }
            }
        }
        for c in captions where !c.skipped {
            var e = entries[c.index], cell = c.compact ?? c.box
            var current = measure(e, cell, e.font)
            if c.compact != nil && !(current.map { contains(cell.insetBy(dx: 3, dy: 3), $0.ink, tolerance: 0.5) } ?? false) {
                cell = c.box; current = measure(e, cell, e.font)
            } else if c.compact != nil { e.compactOriginal = c.box }
            func fits(_ value: Measurement?) -> Bool { value.map { contains(cell.insetBy(dx: 3, dy: 3), $0.ink, tolerance: 0.5) } ?? false }
            if !fits(current), var lower = floorFor(e, c.repartitioning) {
                var upper = e.font
                for _ in 0..<10 {
                    let candidate = (lower + upper) / 2, trial = measure(e, cell, candidate)
                    if fits(trial) { lower = candidate } else { upper = candidate }
                }
                e.font = lower; current = measure(e, cell, lower)
            }
            let originalOwner = e.panels[c.owner]
            e.panels = [Panel(rect: cell, color: originalOwner.color, coverage: [cell],
                sourceErasure: originalOwner.sourceErasure, radius: c.repartitioning ? 0 : originalOwner.radius)]
            e.cell = cell; e.content = cell.insetBy(dx: 3, dy: 3); e.unified = true
            if let current { e.ink = current.ink }
            e.requiredCoverage = c.covered; e.ownFootprint = c.own
            entries[c.index] = e
        }
        // The complete final geometry is fixed before sequential source anchoring.
        var finalInks = entries.map(\.ink)
        let finalSources = entries.map(\.source)
        for c in captions where !c.skipped {
            let e = anchorPackedCaption(entries[c.index], obstacles: entries.indices.filter { $0 != c.index }.flatMap { i in
                [finalInks[i], finalSources[i]].compactMap { $0 }.filter(valid)
            }, home: c.own.flatMap { valid($0) ? $0 : nil }, usedPanelRect: usedPanelRect)
            finalInks[c.index] = e.ink; entries[c.index] = e
        }
        for c in captions where !c.skipped && !c.covered.isEmpty {
            var e = entries[c.index]
            guard let authoredCell = e.cell else { continue }
            let cell = usedPanelRect(authoredCell)
            let inkBox = e.ink.insetBy(dx: -3, dy: -3)
            var coverage = (c.covered + [inkBox]).map { intersection($0, cell) }.filter(valid)
            if coverage.isEmpty || coverage.count > 257 { continue }
            coverage = NativePanelGeometry.solidPanelCoverage(coverage)
            e.panels[0].coverage = coverage; e.panels[0].clipped = true
            e.panels[0].coverageClipActive = true
            e.panels[0].coverageClip = NativeCSSCoveragePath.declaration(coverage: coverage, origin: cell.origin, commands: .absolute)
            var fills: [ForeignFill] = []
            for (owner, piece) in c.owners {
                guard let color = entries[owner].panels.first?.color, color.count == 3, color != e.panels[0].color else { continue }
                let pieces = NativePanelGeometry.subtractRects(NativePanelGeometry.subtractRects([piece], cut: c.own ?? inkBox).filter {
                    $0.width >= 1 && $0.height >= 1
                }, cut: inkBox).filter { $0.width >= 1 && $0.height >= 1 }
                for p in pieces {
                    let b = intersection(p, cell)
                    if b.width >= 1 && b.height >= 1 && ownerFits(b, owner: color, cell: e.panels[0].color, read: readSource) {
                        fills.append(ForeignFill(rect: b, color: color,
                            backgroundPosition: CGPoint(x: b.minX - cell.minX, y: b.minY - cell.minY),
                            backgroundSize: b.size))
                    }
                }
            }
            if !fills.isEmpty && fills.count <= 64 && !e.hasBackgroundImage { e.foreignFills = fills }
            entries[c.index] = e
        }
        return Result(entries: entries, measurements: 512 - max(0, budget), fallbacks: fallbacks, balloonLayouts: balloonLayouts,
            skippedIDs: Set(captions.filter(\.skipped).map { entries[$0.index].id }))
    }

    /// Zero requested dimensions mean a native-size crop. The adapter maps
    /// display coordinates to source pixels with floor/ceil/clamp and supplies
    /// those physical dimensions. The original 65,536-pixel cap stays here.
    private static func frameLine(_ box: CGRect, vertical: Bool, read: ((CGRect, Int, Int) -> Pixels?)?) -> Bool {
        guard let read, valid(box), let p = read(box.insetBy(dx: -1, dy: -1), 0, 0),
              p.width > 0, p.height > 0, p.width <= 65_536 / p.height,
              p.rgba.count == p.width * p.height * 4 else { return false }
        let along = vertical ? p.height : p.width, across = vertical ? p.width : p.height
        for a in 0..<across {
            var run = 0
            for b in 0..<along {
                let x = vertical ? a : b, y = vertical ? b : a, at = (y * p.width + x) * 4
                if 0.299 * Double(p.rgba[at]) + 0.587 * Double(p.rgba[at + 1]) + 0.114 * Double(p.rgba[at + 2]) < 80 { run += 1 }
            }
            if Double(run) >= Double(along) * 0.8 { return true }
        }
        return false
    }
    private static func ownerFits(_ b: CGRect, owner: [Double], cell: [Double], read: ((CGRect, Int, Int) -> Pixels?)?) -> Bool {
        guard let read else { return false }
        let w = max(1, min(32, Int(floor(b.width + 0.5)))), h = max(1, min(32, Int(floor(b.height + 0.5))))
        guard let pixels = read(b, w, h), pixels.width == w, pixels.height == h, pixels.rgba.count == w * h * 4 else { return false }
        let p = pixels.rgba
        var close = [0, 0]
        for at in stride(from: 0, to: p.count, by: 4) {
            for (k, color) in [owner, cell].enumerated() where color.count == 3 {
                if (0..<3).allSatisfy({ abs(Double(p[at + $0]) - color[$0]) <= 40 }) { close[k] += 1 }
            }
        }
        return Double(close[0]) >= Double(close[1]) + 0.1 * Double(w * h)
    }
    private static func valid(_ r: CGRect) -> Bool { r.size.width > 0 && r.size.height > 0 && NativePanelGeometry.valid(r) }
    private static func hit(_ a: CGRect, _ b: CGRect, _ amount: CGFloat = 0) -> Bool { NativePanelGeometry.intersects(a, b, tolerance: amount) }
    private static func area(_ r: CGRect) -> CGFloat { max(0, r.width) * max(0, r.height) }
    private static func rect(_ left: CGFloat, _ top: CGFloat, _ right: CGFloat, _ bottom: CGFloat) -> CGRect { CGRect(x: left, y: top, width: right - left, height: bottom - top) }
    private static func intersection(_ a: CGRect, _ b: CGRect) -> CGRect { rect(max(a.minX, b.minX), max(a.minY, b.minY), min(a.maxX, b.maxX), min(a.maxY, b.maxY)) }
    private static func union(_ boxes: [CGRect]) -> CGRect { rect(boxes.map(\.minX).min()!, boxes.map(\.minY).min()!, boxes.map(\.maxX).max()!, boxes.map(\.maxY).max()!) }
    private static func contains(_ box: CGRect, _ ink: CGRect, tolerance: CGFloat) -> Bool {
        ink.minX >= box.minX - tolerance && ink.minY >= box.minY - tolerance && ink.maxX <= box.maxX + tolerance && ink.maxY <= box.maxY + tolerance
    }
}
