import CoreGraphics
import Foundation

/// Final geometry policies use physical Range-equivalent rectangles. Source
/// erasure and lettering style remain owned by their respective earlier stages.
enum NativeTranslationFinalGeometry {
    enum Clip { case none, polygon([CGPoint]), unsupported }
    struct Matrix {
        var a: Double = 1, b: Double = 0, c: Double = 0, d: Double = 1, e: Double = 0, f: Double = 0
        var is2D = true
        func transform(_ p: CGPoint) -> CGPoint { CGPoint(x: a * p.x + c * p.y + e, y: b * p.x + d * p.y + f) }
        func inverse(_ p: CGPoint) -> CGPoint? {
            let determinant = a * d - b * c
            guard determinant.isFinite, determinant != 0 else { return nil }
            return CGPoint(x: (d * (p.x - e) - c * (p.y - f)) / determinant,
                           y: (-b * (p.x - e) + a * (p.y - f)) / determinant)
        }
    }
    struct Plate {
        var rect: CGRect
        var size: CGSize
        var matrix: Matrix
        var clip: Clip = .none
        var hasBackgroundImage = false
        var upright = false
    }
    struct Entry {
        let id: String
        let frame: CGRect
        let source: CGRect
        var lines: [CGRect]
        var uprightQuadText = false
        var sourceDisplay = false
        var sourceVertical = false
        var vertical = false
        var originalRotation: Double = 0
        var hasBalloon = false
        var hasBalancedColumnPlan = false
        var isRoot = true
        var inpainted = false
        var keepsSource = false
        var visible = true
        var font: Double
        var pitch: Double
        var stroke: Double
        var horizontalScale: Double = 1
        var plate: Plate?
        var textUpright = false
        var uprightTextProof: String?
        var shift: CGPoint = .zero
        var sourceTopAnchored = false
    }
    struct Shape {
        let lines: [CGRect]
        let scrollSize: CGSize
        let clientSize: CGSize
    }
    typealias Reshape = (Entry, _ font: Double, _ pitch: Double, _ horizontalScale: Double) -> Shape?

    static func uprightText(_ input: [Entry], reshape: Reshape) -> [Entry] {
        var entries = input
        for i in entries.indices {
            let entry = entries[i]
            guard entry.uprightQuadText, !entry.vertical, entry.originalRotation.isFinite,
                  abs(entry.originalRotation) < .pi / 43, entry.visible, !entry.textUpright,
                  finite(entry.frame), let plate = entry.plate,
                  plate.size.width > 0, plate.size.height > 0, plate.matrix.is2D,
                  abs(plate.matrix.e) + abs(plate.matrix.f) <= 0.01 else { continue }
            let polygon: [CGPoint]?
            switch plate.clip {
            case .none: polygon = nil
            case .unsupported: continue
            case .polygon(let points):
                guard points.count >= 3, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                polygon = points
            }
            let center = CGPoint(x: plate.rect.midX, y: plate.rect.midY)
            func inside(_ p: CGPoint) -> Bool {
                if p.x < entry.frame.minX + 0.25 || p.y < entry.frame.minY + 0.25 ||
                   p.x > entry.frame.maxX - 0.25 || p.y > entry.frame.maxY - 0.25 { return false }
                guard let q = plate.matrix.inverse(CGPoint(x: p.x - center.x, y: p.y - center.y)),
                      abs(q.x) <= plate.size.width / 2 - 0.25, abs(q.y) <= plate.size.height / 2 - 0.25 else { return false }
                guard let polygon else { return true }
                let x = q.x + plate.size.width / 2, y = q.y + plate.size.height / 2
                var side: CGFloat = 0
                for j in polygon.indices {
                    let a = polygon[j], b = polygon[(j + 1) % polygon.count]
                    let cross = (b.x - a.x) * (y - a.y) - (b.y - a.y) * (x - a.x)
                    if abs(cross) < 0.001 { continue }
                    let sign: CGFloat = cross < 0 ? -1 : 1
                    if side != 0 && sign != side { return false }; side = sign
                }; return true
            }
            let foreign = entries.indices.filter { $0 != i && entries[$0].visible }.flatMap { entries[$0].lines }
            let hits = foreign.filter { f in entry.lines.contains { hit($0, f) } }.count
            let scale = abs(entry.horizontalScale)
            guard scale > 0, scale <= 1.01 else { continue }
            let finalScale = scale < 0.999 ? scale : 1
            let pitch = entry.pitch / entry.font
            let ratio = pitch.isFinite && pitch != 0 ? pitch : 1.2
            let stroke = entry.stroke / 2
            var accepted = false
            for step in 0...8 {
                let size = max(min(entry.font, 9), entry.font * (1 - Double(step) * 0.025))
                guard let shaped = reshape(entry, size, size * ratio, finalScale), !shaped.lines.isEmpty,
                      shaped.scrollSize.width <= shaped.clientSize.width + 1,
                      shaped.scrollSize.height <= shaped.clientSize.height + 1 else { continue }
                let fits = shaped.lines.allSatisfy { r in
                    corners(r.insetBy(dx: -stroke, dy: -stroke)).allSatisfy(inside)
                }
                if fits && foreign.filter({ f in shaped.lines.contains { hit($0, f) } }).count <= hits {
                    entries[i].font = size; entries[i].pitch = size * ratio
                    entries[i].horizontalScale = finalScale; entries[i].lines = shaped.lines
                    entries[i].textUpright = true; entries[i].uprightTextProof = "fixed-source-plate"
                    accepted = true; break
                }
            }
            if !accepted { entries[i].uprightTextProof = "insufficient-plate" }
        }
        return entries
    }

    static func uprightPlate(_ input: [Entry]) -> [Entry] {
        var entries = input
        for i in entries.indices {
            let e = entries[i]
            guard e.uprightQuadText, !e.vertical, e.sourceDisplay, e.originalRotation.isFinite,
                  abs(e.originalRotation) < .pi / 43, e.textUpright, e.visible, finite(e.frame),
                  var plate = e.plate, !plate.hasBackgroundImage,
                  plate.matrix.is2D, abs(plate.matrix.e) + abs(plate.matrix.f) <= 0.01,
                  plate.size.width > 0, plate.size.height > 0,
                  abs(hypot(plate.matrix.a, plate.matrix.b) - 1) <= 0.001,
                  abs(hypot(plate.matrix.c, plate.matrix.d) - 1) <= 0.001 else { continue }
            switch plate.clip {
            case .none: break
            case .unsupported: continue
            case .polygon(let points):
                guard points.count == 4, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { continue }
                let mapped = points.map { p -> CGPoint in
                    let q = plate.matrix.transform(CGPoint(x: p.x - plate.size.width / 2, y: p.y - plate.size.height / 2))
                    return CGPoint(x: q.x + plate.rect.midX, y: q.y + plate.rect.midY)
                }
                guard corners(e.frame).allSatisfy({ c in mapped.contains { hypot($0.x - c.x, $0.y - c.y) < 0.1 } }) else { continue }
            }
            let left = max(e.frame.minX, plate.rect.minX), top = max(e.frame.minY, plate.rect.minY)
            let right = min(e.frame.maxX, plate.rect.maxX), bottom = min(e.frame.maxY, plate.rect.maxY)
            guard right > left, bottom > top else { continue }
            plate.rect = CGRect(x: left, y: top, width: right - left, height: bottom - top)
            plate.size = plate.rect.size; plate.matrix = Matrix(); plate.clip = .none; plate.upright = true
            entries[i].plate = plate
        }
        return entries
    }

    static func anchorVerticalTops(_ input: [Entry], itemCount: Int? = nil) -> [Entry] {
        guard (itemCount ?? input.count) <= 256 else { return input }
        var entries = input
        for i in entries.indices {
            let e = entries[i]
            guard e.sourceVertical, !e.vertical, e.originalRotation == 0, !e.hasBalloon,
                  e.hasBalancedColumnPlan, e.source.height >= e.source.width * 1.5,
                  e.isRoot, !e.keepsSource, e.inpainted, e.visible, !e.lines.isEmpty else { continue }
            let top = e.lines.map(\.minY).min()!, bottom = e.lines.map(\.maxY).max()!
            let target = e.source.minY, dy = target - top
            if abs(dy) < 0.25 || target < e.frame.minY || bottom + dy > e.frame.maxY { continue }
            let foreign = entries.indices.filter { $0 != i && entries[$0].visible }.flatMap { entries[$0].lines }
            func hits(_ offset: CGFloat) -> Int { foreign.filter { f in e.lines.contains { hit($0.offsetBy(dx: 0, dy: offset), f) } }.count }
            if hits(dy) > hits(0) { continue }
            entries[i].lines = e.lines.map { $0.offsetBy(dx: 0, dy: dy) }
            entries[i].shift.y += dy; entries[i].sourceTopAnchored = true
        }
        return entries
    }

    struct Kept { let id: String; let rect: CGRect; let sourceFontSize: Double? }
    struct Zone { let id: String; let rect: CGRect }
    static func keptZones(kept: [Kept], painted: [CGRect]) -> [Zone] {
        guard kept.count <= 256 else { return [] }
        let cuts = Array(painted.filter(valid).prefix(512))
        return kept.flatMap { k -> [Zone] in
            guard valid(k.rect) else { return [] }
            let glyph = k.sourceFontSize.flatMap { $0 > 0 ? $0 : nil } ?? Double(min(k.rect.width, k.rect.height))
            let pad = max(1, min(3, glyph * 0.15))
            var pieces = [k.rect.insetBy(dx: -pad, dy: -pad)]
            for cut in cuts { pieces = subtract(pieces, cut); if pieces.count > 64 { break } }
            return pieces.filter { $0.width >= 0.5 && $0.height >= 0.5 }.map { Zone(id: k.id, rect: $0) }
        }
    }
    private static func subtract(_ pieces: [CGRect], _ cut: CGRect) -> [CGRect] {
        pieces.flatMap { r -> [CGRect] in
            if min(r.maxX, cut.maxX) <= max(r.minX, cut.minX) || min(r.maxY, cut.maxY) <= max(r.minY, cut.minY) { return [r] }
            let top = max(r.minY, cut.minY), bottom = min(r.maxY, cut.maxY)
            let endpoints: [[CGFloat]] = [[r.minX,r.minY,r.maxX,cut.minY], [r.minX,cut.maxY,r.maxX,r.maxY],
                    [r.minX,top,cut.minX,bottom], [cut.maxX,top,r.maxX,bottom]]
            return endpoints.filter { $0[2] > $0[0] && $0[3] > $0[1] }
                .map { CGRect(x:$0[0],y:$0[1],width:$0[2]-$0[0],height:$0[3]-$0[1]) }
        }
    }
    private static func finite(_ r: CGRect) -> Bool { [r.minX,r.minY,r.width,r.height].allSatisfy(\.isFinite) }
    private static func valid(_ r: CGRect) -> Bool { finite(r) && r.size.width > 0 && r.size.height > 0 }
    private static func hit(_ a: CGRect, _ b: CGRect) -> Bool { a.minX < b.maxX && b.minX < a.maxX && a.minY < b.maxY && b.minY < a.maxY }
    private static func corners(_ r: CGRect) -> [CGPoint] { [CGPoint(x:r.minX,y:r.minY),CGPoint(x:r.maxX,y:r.minY),CGPoint(x:r.maxX,y:r.maxY),CGPoint(x:r.minX,y:r.maxY)] }
}
