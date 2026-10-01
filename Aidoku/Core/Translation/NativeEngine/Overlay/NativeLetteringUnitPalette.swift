import CoreGraphics
import Foundation

/// One source colour and readable plate for connected display-lettering pieces.
/// The complete unit is accepted only after checking all affected foreign ink.
enum NativeLetteringUnitPalette {
    struct Member {
        let id: String
        let box: CGRect
        let plate: [Double]
        let fill: [Double]
        let source: [Double]
        let surface: [Double]?
        let glyph: Double
        let font: Double
        let stroke: [Double]?
        let strokeWidth: Double
        let vertical: Bool
    }
    struct Neighbor { let id: String; let ink: CGRect; let fill: [Double]? }
    struct ForeignFill {
        let rect: CGRect
        var color: [Double]
        var backgroundPosition: CGPoint? = nil
        var backgroundSize: CGSize? = nil
    }
    struct Panel {
        let id: String
        var color: [Double]
        var fills: [ForeignFill]
        var owner = true
        var backgroundRewritten = false
    }
    struct Update {
        let id: String
        let chosenID: String
        let oldPlate: [Double]
        let plate: [Double]
        let oldFill: [Double]
        let fill: [Double]
        let stroke: [Double]?
        let strokeWidth: Double
        let minimumContrast: Double
    }
    struct Result { let updates: [Update]; let panels: [Panel] }

    static func resolve(members input: [Member], neighbors: [Neighbor], panels inputPanels: [Panel], itemCount: Int,
        opacity: Double, preserveText: Bool, preserveBackground: Bool) -> Result {
        guard opacity == 1, preserveText, preserveBackground, itemCount <= 256 else { return Result(updates: [], panels: inputPanels) }
        func valid(_ color: [Double]) -> Bool { color.count == 3 && color.allSatisfy { $0.isFinite && $0 >= 0 && $0 <= 255 } }
        func gap(_ a: [Double], _ b: [Double]) -> Double { zip(a,b).map { abs($0-$1) }.max() ?? 0 }
        func luminance(_ color: [Double]) -> Double {
            let rgb = color.map { $0 / 255 }.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0+0.055)/1.055,2.4) }
            return rgb[0]*0.2126 + rgb[1]*0.7152 + rgb[2]*0.0722
        }
        func contrast(_ a: [Double], _ b: [Double]) -> Double {
            let x = luminance(a), y = luminance(b); return (max(x,y)+0.05)/(min(x,y)+0.05)
        }
        let members = input.filter { valid($0.plate) && valid($0.fill) && valid($0.source) && $0.glyph >= 18 }
        var roots = Array(members.indices)
        func find(_ value: Int) -> Int {
            var index = value
            while roots[index] != index { roots[index] = roots[roots[index]]; index = roots[index] }
            return index
        }
        if members.count > 1 {
            for i in 0..<members.count { for j in (i+1)..<members.count {
                let a = members[i], b = members[j], A = a.box, B = b.box
                if a.vertical != b.vertical || max(a.glyph,b.glyph) > 1.25*min(a.glyph,b.glyph) || gap(a.source,b.source) > 40 { continue }
                let gx = max(A.minX,B.minX)-min(A.maxX,B.maxX), gy = max(A.minY,B.minY)-min(A.maxY,B.maxY)
                if max(gx,gy) > max(2,min(a.glyph,b.glyph)*0.15) { continue }
                let crossY = min(A.maxY,B.maxY)-max(A.minY,B.minY), crossX = min(A.maxX,B.maxX)-max(A.minX,B.minX)
                if !(gx > gy ? crossY >= 0.6*min(A.height,B.height) : crossX >= 0.6*min(A.width,B.width)) { continue }
                roots[find(i)] = find(j)
            } }
        }
        var unitIndices: [Int:Int] = [:], units: [[Member]] = []
        for i in members.indices {
            let root = find(i)
            if let unit = unitIndices[root] { units[unit].append(members[i]) }
            else { unitIndices[root] = units.count; units.append([members[i]]) }
        }
        var updates: [Update] = [], panels = inputPanels
        var currentFills: [String: [Double]] = [:]
        for unit in units where unit.count >= 2 && unit.count <= 12 {
            let first = unit[0]
            if unit.allSatisfy({ gap($0.plate,first.plate) <= 48 && (luminance($0.plate) > 0.18) == (luminance(first.plate) > 0.18) }) { continue }
            let required: Double = (unit.map(\.font).min() ?? 10) >= 18 ? 3 : 4.5
            let candidates = unit.filter { member in
                gap(member.fill,member.source) <= 48 && contrast(member.fill,member.plate) >= required && gap(member.plate,member.source) > 48 &&
                (member.surface == nil || member.surface.map { !valid($0) || gap(member.plate,$0) <= 48 } == true) &&
                (member.stroke == nil || member.stroke.map { valid($0) && contrast(member.fill,$0) >= 3 } == true)
            }
            guard var chosen = candidates.first else { continue }
            for candidate in candidates.dropFirst() where candidate.box.width*candidate.box.height > chosen.box.width*chosen.box.height { chosen = candidate }
            let unitIDs = Set(unit.map(\.id))
            let unsafe = neighbors.contains { neighbor in
                guard !unitIDs.contains(neighbor.id), neighbor.ink.size.width > 0, neighbor.ink.size.height > 0,
                      unit.contains(where: { $0.id != chosen.id && neighbor.ink.minX < $0.box.maxX && $0.box.minX < neighbor.ink.maxX &&
                        neighbor.ink.minY < $0.box.maxY && $0.box.minY < neighbor.ink.maxY }) else { return false }
                guard let fill = currentFills[neighbor.id] ?? neighbor.fill, valid(fill) else { return true }
                return contrast(fill,chosen.plate) < 3
            }
            if unsafe { continue }
            for member in unit where member.id != chosen.id {
                let width = chosen.stroke == nil ? (member.stroke == nil ? member.strokeWidth : 0)
                    : max(0.75,floor(chosen.strokeWidth*member.font/chosen.font*4+0.5)/4)
                currentFills[member.id] = chosen.fill
                for index in panels.indices where panels[index].id == member.id && panels[index].owner { panels[index].color = chosen.plate }
                updates.append(Update(id: member.id, chosenID: chosen.id, oldPlate: member.plate, plate: chosen.plate,
                    oldFill: member.fill, fill: chosen.fill, stroke: chosen.stroke, strokeWidth: width,
                    minimumContrast: contrast(chosen.fill,chosen.plate)))
            }
            let old = unit.map(\.plate)
            for index in panels.indices where panels[index].fills.contains(where: { old.contains($0.color) }) {
                // Even an unchanged matching colour causes a fresh CSS image
                // declaration in the frozen policy (14207–14219).
                panels[index].backgroundRewritten = true
                panels[index].fills = panels[index].fills.map { fill in
                    var next = fill
                    if old.contains(fill.color) { next.color = chosen.plate }
                    return next
                }.filter { $0.color != panels[index].color }
            }
        }
        return Result(updates: updates, panels: panels)
    }
}
