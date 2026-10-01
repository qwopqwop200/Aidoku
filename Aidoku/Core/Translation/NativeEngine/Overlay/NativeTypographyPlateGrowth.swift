import CoreGraphics
import Foundation

/// Frozen plate growth uses physical Range boxes and the extant plate, after
/// the initial font cohort. This policy does not create or guess that plate.
enum NativeTypographyPlateGrowth {
    struct Input {
        var text: String
        var font: Double
        var originalFont: Double
        var sourceGlyph: Double
        var cap: Double = .infinity
        var styleGlyph: Double = 0
        var ratio: Double = 1.2
        var wrappingScript = "korean"
        var vertical = false
        var rotated = false
        var allowsRecovery = true
        var visible = true
        var plateVisible = true
        var condensedOnly = false
        var committedAllowed = true
        var strict = false
        var loneBefore = 0
        var plate: CGRect
        var currentInk: CGRect
        var coverage: [CGRect]?
        var frame: CGRect?
        var others: [CGRect] = []
        var foreignPlates: [CGRect] = []
        var foreignCards: [CGRect] = []
    }
    struct Proposal {
        var box: CGRect
        var font: Double
        var pitch: Double
        var padding: Double
        var horizontalScale: Double
        var room: Bool
        var lifting: Bool
    }
    struct Measurement {
        var ink: CGRect
        var lineRects: [CGRect]
        var scrollWidth: Double
        var clientWidth: Double
        var scrollHeight: Double
        var clientHeight: Double
        var badLineStart = false
        var loneSyllableLines = 0
    }
    struct Room {
        var bounds: CGRect
        var edges: [Double]? = nil
        var left: Double { edges?[0] ?? Double(bounds.minX) }
        var top: Double { edges?[1] ?? Double(bounds.minY) }
        var right: Double { edges?[2] ?? Double(bounds.maxX) }
        var bottom: Double { edges?[3] ?? Double(bounds.maxY) }
        var free: (CGRect) -> Bool
    }
    final class State {
        var roomRefused: Set<String> = []
        var room: Room?
        var roomLift: Room?
        var roomMeasured = false
        var roomLiftMeasured = false
    }
    final class Budget {
        var roomLayouts = 0
        var liftLayouts = 0
        var flatRoomPixels = 786_432
    }
    struct Result {
        var proposal: Proposal
        var measurement: Measurement
        var plate: CGRect
        var coverage: [CGRect]?
        var flatRoom: [Double]?
        /// Literal room8503 clip rewrite happens only when added coverage exists.
        var coverageClipWritten = false
    }
    struct Schedule {
        var target: Double
        var display: Double
        var earlier: Double
        var lifts: [Double]
        var sizes: [Double]
    }
    typealias Measure = (Proposal) -> Measurement?
    typealias Advance = (String, Double) -> Double
    typealias RoomProvider = (_ lifting: Bool, _ glyphReach: Double) -> Room?

    static func schedule(font: Double, originalFont: Double, glyph: Double, styleGlyph: Double = 0,
                         cap: Double = .infinity, korean: Bool = true, committed: Bool = false) -> Schedule {
        let target = quarter(min(32, max(glyph, styleGlyph) * 0.95, originalFont * 3, cap))
        let display = quarter(glyph >= 40 ? min(128, glyph * 0.8, cap) : min(32, glyph * 0.95, font * 3, cap))
        let earlier = quarter(min(glyph >= 40 ? min(64, glyph * 0.8) : 32, glyph * 0.95, font * 3, cap))
        var lifts: [Double] = []
        if korean && glyph.isFinite && glyph > 0 && glyph * 0.9 < 9 && !committed {
            for delta in [0.0, 0.25, 0.5] {
                let size = quarter(min(9, cap, font * 3)) - delta
                if size > target + 0.01 && size >= font + 0.25 && size >= min(font * 1.1, 8.5) { lifts.append(size) }
            }
        }
        var sizes = committed ? condensedSizes(font, target) : lifts
        if display > target && !committed {
            var larger = displaySizes(display, target)
            if earlier > target { for step in 0..<4 { larger.append(quarter(earlier - (earlier - target) * Double(step) / 4)) } }
            sizes += Array(Set(larger)).sorted(by: >)
        }
        if target >= font * 1.1 && !committed {
            for step in 0..<6 { sizes.append(quarter(target - (target - font * 1.1) * Double(step) / 5)) }
        }
        return Schedule(target: target, display: display, earlier: earlier, lifts: lifts, sizes: sizes)
    }

    static func grow(_ e: Input, state: State, budget: Budget, advance: Advance,
                     measure: Measure, roomProvider: RoomProvider) -> Result? {
        guard !e.rotated, !e.vertical, e.allowsRecovery, ["korean", "word"].contains(e.wrappingScript),
              e.visible, e.plateVisible, !e.text.isEmpty, e.text.utf16.count <= 180,
              e.sourceGlyph.isFinite, e.sourceGlyph > 0, e.font.isFinite,
              !e.condensedOnly || e.committedAllowed else { return nil }
        let committed = e.condensedOnly
        if committed && (e.sourceGlyph >= 40 || e.wrappingScript != "korean" || e.text.utf16.count > 80) { return nil }
        let s = schedule(font: e.font, originalFont: e.originalFont, glyph: e.sourceGlyph,
                         styleGlyph: e.styleGlyph, cap: e.cap, korean: e.wrappingScript == "korean", committed: committed)
        guard max(s.target, s.display) >= e.font * 1.1 || !s.lifts.isEmpty else { return nil }
        var plate = e.plate
        if let coverage = e.coverage {
            let center = CGPoint(x: e.currentInk.midX, y: e.currentInk.midY)
            let owners = coverage.filter { $0.origin.x.isFinite && $0.origin.y.isFinite && $0.width.isFinite && $0.height.isFinite &&
                $0.origin.x <= center.x && center.x <= $0.origin.x + $0.width &&
                $0.origin.y <= center.y && center.y <= $0.origin.y + $0.height }.sorted { $0.width * $0.height > $1.width * $1.height }
            guard let owner = owners.first else { return nil }; plate = owner
        }
        let ratio = e.ratio == 0 || !e.ratio.isFinite ? 1.2 : e.ratio
        let words = e.text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let beforeCards = touching(e.currentInk, e.foreignCards)
        func lines(_ height: CGFloat, _ size: Double) -> Int { max(1, Int(floor(Double(height) / (size * ratio) + 0.5))) }
        func common(_ m: Measurement, size: Double) -> Bool {
            let before = lines(e.currentInk.height, e.font), after = lines(m.ink.height, size)
            if !keepsLineLength(e.text, before: before, after: after) { return false }
            let gap = s.lifts.contains(size) ? size * 0.35 : 0
            if e.others.contains(where: { meets(m.ink.insetBy(dx: -gap, dy: -gap), $0) }) { return false }
            if gap > 0 && e.foreignPlates.contains(where: { meets(m.ink, $0) }) { return false }
            if size > s.earlier && touching(m.ink, e.foreignCards) > beforeCards + 1 { return false }
            if e.strict && m.badLineStart { return false }
            if committed && (m.loneSyllableLines > e.loneBefore || after > before + 1) { return false }
            return true
        }
        func overflow(_ m: Measurement) -> Bool { m.scrollWidth > m.clientWidth + 1 || m.scrollHeight > m.clientHeight + 1 }
        func plateTry(_ size: Double) -> Result? {
            let pad = max(3, min(8, size * 0.3)), scale = committed ? 0.9 : 1
            let width = Double(plate.width) / scale
            let p = Proposal(box: CGRect(x: Double(plate.minX) - (width - Double(plate.width)) / 2,
                y: Double(plate.minY), width: width, height: Double(plate.height)), font: size, pitch: size * ratio,
                padding: pad, horizontalScale: scale, room: false, lifting: s.lifts.contains(size))
            guard let m = measure(p) else { return nil }
            let widest = words.map { advance($0, size) }.max() ?? -.infinity
            let available = Double(plate.width) - pad * 2
            if committed ? !(widest > available && widest * 0.9 <= available) : widest > available { return nil }
            if overflow(m) || m.ink.minX < plate.minX + pad - 0.5 || m.ink.maxX > plate.maxX - pad + 0.5 ||
                m.ink.minY < plate.minY + pad - 0.5 || m.ink.maxY > plate.maxY - pad + 0.5 || !common(m, size: size) { return nil }
            return Result(proposal: p, measurement: m, plate: e.plate, coverage: e.coverage, flatRoom: nil)
        }
        let cx = Double(plate.midX), cy = Double(plate.midY)
        func screen(_ reach: Double) -> (Double, Double) {
            guard let f = e.frame else { return (0, 0) }
            return (2 * min(cx - max(Double(f.minX), Double(plate.minX) - reach), min(Double(f.maxX), Double(plate.maxX) + reach) - cx),
                    2 * min(cy - max(Double(f.minY), Double(plate.minY) - reach), min(Double(f.maxY), Double(plate.maxY) + reach) - cy))
        }
        func roomTry(_ size: Double) -> Result? {
            let lifting = s.lifts.contains(size)
            if lifting && !(e.font < 8.5) { return nil }
            let glyph = lifting ? max(e.sourceGlyph, 10) : e.sourceGlyph
            let key = "\(size)|\(e.strict)"
            if state.roomRefused.contains(key) { return nil }
            func rejected() -> Result? { state.roomRefused.insert(key); return nil }
            let (wide0, height0) = screen(min(48, glyph * 1.5))
            if !(wide0 >= Double(plate.width) * 1.1 || height0 >= Double(plate.height) * 1.1) { return nil }
            if lifting ? state.roomLiftMeasured && state.roomLift == nil : state.roomMeasured && state.room == nil { return nil }
            let pad = max(3, min(8, size * 0.3))
            let wordWidths = words.map { advance($0, size) }, longest = (wordWidths.max() ?? -.infinity) + pad * 2 + 1
            let total = advance(e.text, size)
            if longest > wide0 || total * size * ratio * 1.1 > (wide0 - 2 * pad) * (height0 - 2 * pad) { return rejected() }
            if lifting && !state.roomLiftMeasured { state.roomLiftMeasured = true; state.roomLift = e.text.utf16.count > 120 ? nil : roomProvider(true, glyph) }
            if !lifting && !state.roomMeasured { state.roomMeasured = true; state.room = e.text.utf16.count > 120 ? nil : roomProvider(false, glyph) }
            guard let room = lifting ? state.roomLift : state.room else { return rejected() }
            let height = 2 * min(cy - room.top, room.bottom - cy)
            let wide = 2 * min(cx - room.left, room.right - cx)
            if !(wide >= Double(plate.width) * 1.1 || height >= Double(plate.height) * 1.1) || total * size * ratio * 1.1 > (wide - 2 * pad) * (height - 2 * pad) { return rejected() }
            var widths: [Double] = []
            for w in [wide, (wide + Double(plate.width)) / 2] + (height > Double(plate.height) + 1 ? [Double(plate.width)] : []) {
                let q = quarter(w); if q >= longest && q <= wide && !widths.contains(q) { widths.append(q) }
            }
            let space = advance(" ", size)
            for width in widths {
                var lineWidths: [Double] = [], run = -1.0
                for next in wordWidths {
                    if run >= 0 && run + space + next <= width - 2 * pad { run += space + next }
                    else { if run >= 0 { lineWidths.append(run) }; run = next }
                }
                if run >= 0 { lineWidths.append(run) }
                let pitch = size * ratio, top = cy - Double(lineWidths.count) * pitch / 2
                if Double(lineWidths.count) * pitch > height - 2 * pad { continue }
                if !lineWidths.enumerated().allSatisfy({ i, lw in room.free(CGRect(x: cx - lw / 2 - pad + 1,
                    y: top + Double(i) * pitch - pad + 1, width: lw + pad * 2 - 2, height: pitch + pad * 2 - 2)) }) { continue }
                if lifting ? budget.liftLayouts >= 48 : budget.roomLayouts >= 48 { return rejected() }
                let p = Proposal(box: CGRect(x: cx - width / 2, y: cy - height / 2, width: width, height: height),
                                 font: size, pitch: pitch, padding: pad, horizontalScale: 1, room: true, lifting: lifting)
                if lifting { budget.liftLayouts += 1 } else { budget.roomLayouts += 1 }
                guard let m = measure(p), !overflow(m), m.ink.width > 0, m.ink.height > 0 else { continue }
                let boxes = m.lineRects.filter { $0.width > 0 && $0.height > 0 }.map { $0.insetBy(dx: -pad, dy: -pad) }
                let slack = lifting ? 1.0 : 0
                if boxes.isEmpty || !boxes.allSatisfy({ room.free($0.insetBy(dx: -slack, dy: -slack)) }) { continue }
                if boxes.contains(where: { box in e.foreignPlates.contains(where: { meets(box, $0) }) }) || !common(m, size: size) { continue }
                let existing = e.coverage ?? [e.plate]
                let added = boxes.filter { box in !existing.contains { c in box.minX >= c.minX - 0.25 && box.minY >= c.minY - 0.25 && box.maxX <= c.maxX + 0.25 && box.maxY <= c.maxY + 0.25 } }
                let combined = added.reduce(e.plate) { $0.union($1) }
                if lifting && !added.isEmpty && e.others.contains(where: { meets(combined, $0) }) { continue }
                return Result(proposal: p, measurement: m, plate: combined, coverage: added.isEmpty ? e.coverage : existing + added,
                              flatRoom: added.isEmpty ? nil : [Double(plate.width), Double(plate.height), width].map { floor($0 * 10 + 0.5) / 10 }, coverageClipWritten: !added.isEmpty)
            }
            return rejected()
        }
        for size in s.sizes {
            if size <= e.font { break }
            if let accepted = plateTry(size) { return accepted }
            if !committed, let accepted = roomTry(size) { return accepted }
        }
        return nil
    }

    static func displaySizes(_ from: Double, _ to: Double) -> [Double] {
        var sizes: [Double] = [], size = quarter(from)
        while size > to && sizes.count < 24 { sizes.append(size); size = quarter(size * 0.94) }
        return sizes
    }
    static func condensedSizes(_ font: Double, _ target: Double) -> [Double] {
        guard font > 0, target > 0 else { return [] }; var out: [Double] = []
        for gain in [1.25, 1.17, 1.11, 1.06] { let size = quarter(min(target, font * gain)); if size >= font * 1.06 && !out.contains(size) { out.append(size) } }
        return out
    }
    static func keepsLineLength(_ text: String, before: Int, after: Int) -> Bool {
        let count = text.filter { !$0.isWhitespace }.utf16.count
        if count == 0 || after < 1 { return false }; if after < 3 || count < 8 { return true }
        let beforeCount = Double(count) / Double(max(1, before)), afterCount = Double(count) / Double(after)
        return afterCount >= 2.5 || afterCount >= beforeCount
    }
    private static func quarter(_ x: Double) -> Double { floor(x * 4) / 4 }
    private static func meets(_ a: CGRect, _ b: CGRect) -> Bool { a.minX < b.maxX && a.maxX > b.minX && a.minY < b.maxY && a.maxY > b.minY }
    private static func touching(_ a: CGRect, _ boxes: [CGRect]) -> Double { boxes.reduce(0) { sum, b in sum + max(0, Double(min(a.maxX,b.maxX)-max(a.minX,b.minX))) * max(0,Double(min(a.maxY,b.maxY)-max(a.minY,b.minY))) } }
}

extension NativeTypographyPlateGrowth {
    struct Member {
        var id: String
        var source: Double
        var script: String
        var vertical: Bool
        var sourceVertical: Bool
        var sourceRect: CGRect?
        var cohortFont: Double
        var memberFont: Double
        var styleKey: String = ""
        var visible = true
        var rotation: Double = 0
        var nearUprightRotation: Double = 0
    }
    struct Grower {
        var id: String
        var source: Double
        var script: String
        var vertical: Bool
        var inPlace = false
        var size: Double?
        var extended = false
        var base: Double = 0
        var interiorBase: Double?
        var cohortTarget: Double?
        var releasedTarget: Double?
        var styleCap: Double?
        var interiorRefit: Double?
    }

    /// The restored surface search can change its proof route during a cap
    /// retry. Later consistency passes must observe that accepted live state.
    struct GrowthState {
        var extended: Bool
        var base: Double
        var interiorBase: Double?
    }

    /// All plate growers are collected first, then restored-surface growers.
    /// Reads are live: each successful refit changes the members seen next.
    static func reconcile(_ growers: inout [Grower], members: () -> [Member], kept: [Member],
                          run: (_ id: String, _ cap: Double, _ strict: Bool) -> Double?,
                          readableHold: (_ id: String) -> Double,
                          plateFilled: (_ id: String) -> Bool,
                          interiorGaps: (_ id: String, _ font: Double) -> Int,
                          growthState: ((_ id: String) -> GrowthState?)? = nil) {
        func refresh(_ index: Int) {
            guard let current = growthState?(growers[index].id) else { return }
            growers[index].extended = current.extended
            growers[index].base = current.base
            growers[index].interiorBase = current.interiorBase
        }
        func eligibleMembers() -> [Member] { members().filter { $0.source > 0 && $0.visible && $0.rotation == 0 && $0.nearUprightRotation == 0 } }
        func median(_ peers: [Member]) -> Double {
            let sizes = peers.map(\.cohortFont).sorted(); return sizes.isEmpty ? .nan : sizes[(sizes.count - 1) / 2]
        }
        func ratio(_ a: Double, _ b: Double) -> Double { max(a,b)/min(a,b) }
        func aligned(_ a: Member, _ b: Member) -> Bool {
            guard let r = a.sourceRect, let q = b.sourceRect else { return true }
            if a.sourceVertical { return min(r.maxX,q.maxX)-max(r.minX,q.minX) > 0.5 * min(r.width,q.width) }
            return min(r.maxY,q.maxY)-max(r.minY,q.minY) > 0.5 * min(r.height,q.height)
        }
        func holds(_ g: Grower, _ a: Member, _ b: Member) -> Bool {
            if g.id == b.id { return true }; guard let r = a.sourceRect, let q = b.sourceRect else { return true }
            let gap = max(r.minX-q.maxX,q.minX-r.maxX,r.minY-q.maxY,q.minY-r.maxY)
            return Double(gap) <= (a.sourceVertical && b.sourceVertical ? 2.5 : 3) * max(g.source,b.source)
        }
        var boundCache: [String: Bool] = [:]
        func bound(_ id: String) -> Bool { if let old = boundCache[id] { return old }; let value = plateFilled(id); boundCache[id] = value; return value }
        for i in growers.indices {
            let g = growers[i], all = eligibleMembers()
            guard let a = members().first(where: { $0.id == g.id }) else { continue }
            let cohort = all.filter { m in m.script == g.script && m.vertical == g.vertical && ratio(g.source,m.source) <= 1.22 &&
                (g.source < 40 || m.id == g.id || aligned(a,m) || !bound(m.id)) }
            if cohort.count < 2 { continue }
            let keptCohort = kept.filter { g.inPlace && $0.script == g.script && $0.vertical == g.vertical && ratio(g.source,$0.source) <= 1.22 }
            let target = max(median(cohort),keptCohort.isEmpty ? 0 : median(cohort + keptCohort),readableHold(g.id))
            guard let oldSize = g.size, oldSize > target * 1.05 else { continue }
            let peers = cohort.filter { holds(g,a,$0) }
            let columns = peers.filter { $0.id == g.id || a.sourceVertical && $0.sourceVertical }
            let others = peers.filter { m in !columns.contains(where: { $0.id == m.id }) }.map(\.memberFont).filter(\.isFinite)
            let local = max(min(columns.count < 2 ? Double.infinity : median(columns),others.min() ?? .infinity),readableHold(g.id))
            var size: Double?
            if local > target * 1.05 {
                size = run(g.id,local,true)
                if let value = size, value <= target * 1.05 { size = nil }
                if size != nil { growers[i].releasedTarget = local }
            }
            if size == nil { size = run(g.id,target,false) }
            growers[i].size = size; growers[i].cohortTarget = target
        }
        for i in growers.indices {
            refresh(i)
            let g = growers[i]
            guard g.size != nil, g.extended, g.base > 0, g.source > 0,
                  let own = members().first(where: { $0.id == g.id }) else { continue }
            let fonts = eligibleMembers().filter { m in m.id != g.id && m.script == g.script && m.vertical == g.vertical &&
                m.styleKey == own.styleKey && ratio(g.source,m.source) <= 1.15 }.map(\.cohortFont).filter(\.isFinite)
            guard let least = fonts.min() else { continue }
            let limit = max(quarter(least * 1.25),readableHold(g.id)), size = own.memberFont
            if !(size > limit) || g.base > limit { continue }
            var capped = run(g.id,limit,false)
            if capped == nil { capped = run(g.id,size,false) }
            growers[i].size = capped; growers[i].styleCap = limit
        }
        for i in growers.indices {
            refresh(i)
            let g = growers[i]
            guard g.size != nil, let base = g.interiorBase, base > 0,
                  let own = members().first(where: { $0.id == g.id }) else { continue }
            let size = own.memberFont, allowed = interiorGaps(g.id,base)
            if interiorGaps(g.id,size) <= allowed { continue }
            var limit = quarter(size) - 0.25
            while limit > base && interiorGaps(g.id,limit) > allowed { limit -= 0.25 }
            let target = max(limit,base)
            var refit = run(g.id,target,false)
            if refit == nil { refit = run(g.id,size,false) }
            growers[i].size = refit; growers[i].interiorRefit = target
        }
    }
}

extension NativeTypographyPlateGrowth {
    struct FlatRoomInput {
        var plate: CGRect
        var glyph: Double
        var covered: [CGRect]
        var frame: CGRect
        var imageWidth: Int
        var imageHeight: Int
        var color: [Double]
        var opaque = true
        var hasImage = false
        var hasShadow = false
        var hasBorder = false
        var transformed = false
    }
    typealias PixelRead = (_ x: Int, _ y: Int, _ width: Int, _ height: Int) -> [UInt8]?
    /// Exact bounded native-pixel table: a single off-colour pixel blocks its
    /// cell; averaging never turns a fine source outline into free paper.
    static func flatRoom(_ e: FlatRoomInput, budget: Budget, read: PixelRead) -> Room? {
        guard e.imageWidth > 0, e.imageHeight > 0, e.frame.origin.x.isFinite, e.frame.origin.y.isFinite,
              e.frame.width.isFinite, e.frame.height.isFinite, e.frame.width > 0, e.frame.height > 0,
              budget.flatRoomPixels > 0, e.color.count >= 3, e.opaque, !e.hasImage, !e.hasShadow,
              !e.hasBorder, !e.transformed else { return nil }
        let reach = min(48,e.glyph * 1.5), p = e.plate, f = e.frame
        let left = max(Double(f.minX),Double(p.minX)-reach),right = min(Double(f.maxX),Double(p.maxX)+reach)
        let top = max(Double(f.minY),Double(p.minY)-reach),bottom = min(Double(f.maxY),Double(p.maxY)+reach)
        if right-left < Double(p.width)+2 && bottom-top < Double(p.height)+2 { return nil }
        let iw = Double(e.imageWidth),ih = Double(e.imageHeight)
        let x0 = max(0,Int(floor((left-Double(f.minX))/Double(f.width)*iw)))
        let y0 = max(0,Int(floor((top-Double(f.minY))/Double(f.height)*ih)))
        let x1 = min(e.imageWidth,Int(ceil((right-Double(f.minX))/Double(f.width)*iw)))
        let y1 = min(e.imageHeight,Int(ceil((bottom-Double(f.minY))/Double(f.height)*ih)))
        let sw = x1-x0,sh = y1-y0
        guard sw >= 2, sh >= 2, sw <= 262_144/sh, sw*sh <= budget.flatRoomPixels else { return nil }
        budget.flatRoomPixels -= sw*sh
        guard let data = read(x0,y0,sw,sh),data.count >= sw*sh*4 else { return nil }
        let k = min(1,Double(f.width)/iw*1.5),w = max(1,Int(ceil(Double(sw)*k))),h = max(1,Int(ceil(Double(sh)*k)))
        var blocked=[UInt8](repeating:0,count:w*h),offset=[Float](repeating:0,count:w*h),count=[UInt16](repeating:0,count:w*h)
        let step = iw/Double(f.width) >= 2.5 ? 2 : 1
        for y in stride(from:0,to:sh,by:step) {
            let row=min(h-1,Int(floor(Double(y)*k)))*w,base=y*sw*4
            for x in stride(from:0,to:sw,by:step) {
                let i=base+x*4,cell=row+min(w-1,Int(floor(Double(x)*k)))
                let d=max(abs(Double(data[i])-e.color[0]),abs(Double(data[i+1])-e.color[1]),abs(Double(data[i+2])-e.color[2]))
                if d>24 {blocked[cell]=1};offset[cell]=Float(Double(offset[cell])+d);count[cell] &+= 1
            }
        }
        for i in 0..<w*h where count[i]>0 && Double(offset[i])/Double(count[i])>10 {blocked[i]=1}
        let cl=Double(f.minX)+Double(x0)/iw*Double(f.width),ct=Double(f.minY)+Double(y0)/ih*Double(f.height)
        let sx=Double(w)/(Double(sw)/iw*Double(f.width)),sy=Double(h)/(Double(sh)/ih*Double(f.height))
        for r in e.covered {
            let l=max(0,Int(floor((Double(r.minX)-cl)*sx))),t=max(0,Int(floor((Double(r.minY)-ct)*sy)))
            let rr=min(w,Int(ceil((Double(r.maxX)-cl)*sx))),bb=min(h,Int(ceil((Double(r.maxY)-ct)*sy)))
            if t<bb { for y in t..<bb {let end=y*w+max(l,rr),start=y*w+l;if start>=0 && end<=blocked.count && start<end {blocked.replaceSubrange(start..<end,with:repeatElement(0,count:end-start))}} }
        }
        var sat=[Int](repeating:0,count:(w+1)*(h+1))
        for y in 0..<h {var run=0;for x in 0..<w {run+=Int(blocked[y*w+x]);sat[(y+1)*(w+1)+x+1]=sat[y*(w+1)+x+1]+run}}
        return Room(bounds:CGRect(x:left,y:top,width:right-left,height:bottom-top),edges:[left,top,right,bottom],free:{box in
            let l=Int(floor((Double(box.minX)-cl)*sx)),t=Int(floor((Double(box.minY)-ct)*sy))
            let r=Int(ceil((Double(box.maxX)-cl)*sx)),b=Int(ceil((Double(box.maxY)-ct)*sy))
            if l<0 || t<0 || r>w || b>h || r<=l || b<=t {return false}
            return sat[b*(w+1)+r]-sat[t*(w+1)+r]-sat[b*(w+1)+l]+sat[t*(w+1)+l]==0
        })
    }
}

extension NativeTypographyPlateGrowth {
    static func readableHold(source: Double, script: String, font: Double, ink: CGRect, otherVisibleInk: [CGRect]) -> Double {
        guard script == "korean", source.isFinite, source > 0, source*0.9 < 9, font >= 8.5 else {return 0}
        let gap=font*0.25
        if otherVisibleInk.contains(where: {r in r.width>0 && ink.minX-gap<r.maxX && ink.maxX+gap>r.minX && ink.minY-gap<r.maxY && ink.maxY+gap>r.minY}) {return 0}
        return min(9,font)
    }
    static func plateFilled(plate: CGRect?, font: Double, wordWidths: [Double], inkHeight: Double, displayCardGrowth: Bool) -> Bool {
        guard let plate,font>0,!wordWidths.isEmpty,!displayCardGrowth else {return false}
        let pad=max(3,min(8,font*0.3))
        return (wordWidths.max() ?? -.infinity)+pad*2 >= Double(plate.width)*0.9 || inkHeight+pad*2 >= Double(plate.height)*0.9
    }
}
