import Foundation
import CoreGraphics

/// Creates background-only gutters after fitting without moving text or losing source ownership.
enum NativeIndependentPanelGutter {
    struct Panel {
        let id: String
        let pieces: [[CGPoint]]
        let owner: CGRect
        let textFrame: CGRect
        let kept: Bool
        let rotation: CGFloat
    }

    static func bounds(_ points: [CGPoint]) -> CGRect {
        CGRect(x: points.map(\.x).min()!, y: points.map(\.y).min()!,
               width: points.map(\.x).max()! - points.map(\.x).min()!,
               height: points.map(\.y).max()! - points.map(\.y).min()!)
    }

    static func clip(_ polygon: [CGPoint], to box: CGRect) -> [CGPoint] {
        var out = polygon
        for (axis, limit, sign) in [(0, box.minX, CGFloat(1)), (0, box.maxX, CGFloat(-1)),
                                   (1, box.minY, CGFloat(1)), (1, box.maxY, CGFloat(-1))] {
            let input = out
            out = []
            guard let last = input.last else { break }
            var a = last
            for b in input {
                let av = axis == 0 ? a.x : a.y, bv = axis == 0 ? b.x : b.y
                let ia = sign * (av-limit) >= 0, ib = sign * (bv-limit) >= 0
                if ia != ib {
                    let t = (limit-av)/(bv-av)
                    // The computed intersection belongs exactly to this clipping plane.
                    // Avoid an interpolation ULP escaping the strict downstream owner bounds.
                    let x = axis == 0 ? limit : a.x+t*(b.x-a.x)
                    let y = axis == 1 ? limit : a.y+t*(b.y-a.y)
                    out.append(CGPoint(x: x, y: y))
                }
                if ib { out.append(b) }
                a = b
            }
        }
        return out
    }

    static func area(_ polygon: [CGPoint]) -> CGFloat {
        guard let last = polygon.last else { return 0 }
        var a = last, sum: CGFloat = 0
        for b in polygon { sum += a.x*b.y-b.x*a.y; a = b }
        return abs(sum)/2
    }

    static func propose(panels: [Panel], sourceSize: CGSize, imageSize: CGSize,
                        gapPoints: CGFloat = 2) -> [String: CGRect] {
        guard sourceSize.width > 0, sourceSize.height > 0, imageSize.width > 1, imageSize.height > 1 else { return [:] }
        let scale = [sourceSize.width, sourceSize.height], pixels = [imageSize.width, imageSize.height]
        guard panels.allSatisfy({ !$0.pieces.isEmpty && $0.pieces.allSatisfy { $0.count >= 3 } }) else { return [:] }
        let boxes = panels.map { bounds($0.pieces.flatMap { $0 }) }
        let guards = panels.map { p in
            p.owner.insetBy(dx: -4/scale[0], dy: -4/scale[1])
                .union(p.textFrame.insetBy(dx: -0.7/scale[0], dy: -0.7/scale[1]))
        }
        var proposed = boxes.map { [$0.minX, $0.minY, $0.maxX, $0.maxY] }
        func edge(_ r: CGRect, _ axis: Int, _ maxEdge: Bool) -> CGFloat {
            axis == 0 ? (maxEdge ? r.maxX : r.minX) : (maxEdge ? r.maxY : r.minY)
        }
        for i in panels.indices {
            for j in panels.indices where j > i {
                if panels[i].kept || panels[j].kept || panels[i].rotation != 0 || panels[j].rotation != 0 { continue }
                for axis in 0...1 {
                    let orth = 1-axis
                    if min(edge(boxes[i], orth, true), edge(boxes[j], orth, true)) <=
                        max(edge(boxes[i], orth, false), edge(boxes[j], orth, false)) { continue }
                    let centerI = edge(boxes[i], axis, false)+edge(boxes[i], axis, true)
                    let centerJ = edge(boxes[j], axis, false)+edge(boxes[j], axis, true)
                    let left = centerI < centerJ ? i : j, right = centerI < centerJ ? j : i
                    let gap = (edge(boxes[right], axis, false)-edge(boxes[left], axis, true))*scale[axis]
                    let target = max(gapPoints/scale[axis], 3/(pixels[axis]-1))
                    if gap >= target*scale[axis] || gap < -2 { continue }
                    let low = edge(guards[left], axis, true), high = edge(guards[right], axis, false)
                    let reserve = 2/(pixels[axis]-1)
                    if high-low < target+2*reserve { continue }
                    let middle = min(max((edge(boxes[left], axis, true)+edge(boxes[right], axis, false))/2,
                                         low+target/2+reserve), high-target/2-reserve)
                    let leftEdge = min(floor((middle-target/2)*pixels[axis])/pixels[axis],
                                       floor((middle-target/2)*(pixels[axis]-1))/(pixels[axis]-1))
                    let rightEdge = max(ceil((middle+target/2)*pixels[axis])/pixels[axis],
                                        ceil((middle+target/2)*(pixels[axis]-1))/(pixels[axis]-1))
                    if leftEdge < low || rightEdge > high { continue }
                    proposed[left][axis+2] = min(proposed[left][axis+2], leftEdge)
                    proposed[right][axis] = max(proposed[right][axis], rightEdge)
                }
            }
        }
        var result: [String: CGRect] = [:]
        for i in panels.indices {
            let b = proposed[i]
            let box = CGRect(x: b[0], y: b[1], width: b[2]-b[0], height: b[3]-b[1])
            if box == boxes[i] { continue }
            let valid = panels[i].pieces.allSatisfy { old in
                let next = clip(old, to: box)
                return next.count >= 3 && area(next) > 1e-12 &&
                    area(clip(old, to: guards[i])) <= area(clip(next, to: guards[i]))+1e-10
            }
            if valid { result[panels[i].id] = box }
        }
        return result
    }
}
