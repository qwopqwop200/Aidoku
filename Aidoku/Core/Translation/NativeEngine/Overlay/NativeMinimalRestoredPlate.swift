import CoreGraphics
import Foundation

enum NativeMinimalRestoredPlate {
    struct Surface {
        var width: Int
        var height: Int
        var safe: [UInt8]
        var rgba: [UInt8]
        var frame: CGRect
        var imageSize: CGSize
        var origin: CGPoint
        var scale: CGSize
    }
    struct OtherSource {
        var frame: CGRect
        var bounds: [[Double]]
        var vertical: Bool
        var sourceFont: Double?
        var font: Double?
    }
    struct Input {
        var panel: CGRect
        var ink: CGRect
        var font: Double
        var clipped = false
        var coverage: [CGRect]? = nil
        var sources: [OtherSource] = []
        var otherInk: [CGRect] = []
    }
    struct Proposal {
        var rect: CGRect
        var coverage: [CGRect]
        var clipped: Bool
        var beforeArea: Double
        var afterArea: Double
    }
    private struct Bounds {
        var l: Double
        var t: Double
        var r: Double
        var b: Double
        init(_ rect: CGRect) { l = Double(rect.minX); t = Double(rect.minY); r = Double(rect.maxX); b = Double(rect.maxY) }
        init(_ l: Double, _ t: Double, _ r: Double, _ b: Double) { self.l = l; self.t = t; self.r = r; self.b = b }
        var rect: CGRect { CGRect(x: l, y: t, width: r - l, height: b - t) }
        var area: Double { (r - l) * (b - t) }
    }
    static func shrink(_ surface: Surface, input: Input) -> Proposal? {
        let w = surface.width, h = surface.height
        guard w > 0, h > 0, w <= Int.max / h / 4, surface.safe.count == w * h, surface.rgba.count == w * h * 4,
              surface.scale.width > 0, surface.scale.height > 0, surface.frame.width > 0, surface.frame.height > 0,
              surface.imageSize.width > 0, surface.imageSize.height > 0,
              [surface.scale.width,surface.scale.height,surface.frame.minX,surface.frame.minY,surface.frame.width,
               surface.frame.height,surface.imageSize.width,surface.imageSize.height,surface.origin.x,surface.origin.y,
               input.panel.minX,input.panel.minY,input.panel.width,input.panel.height,
               input.ink.minX,input.ink.minY,input.ink.width,input.ink.height].allSatisfy(\.isFinite),
              input.panel.width >= 4, input.panel.height >= 4, input.ink.width > 0, input.ink.height > 0 else { return nil }
        let p = Bounds(input.panel), ink = Bounds(input.ink)
        let coverage: [Bounds]
        if input.clipped {
            guard let given = input.coverage else { return nil }
            coverage = given.filter { [$0.minX,$0.minY,$0.width,$0.height].allSatisfy(\.isFinite) }.map(Bounds.init)
            guard !coverage.isEmpty else { return nil }
        } else { coverage = [p] }
        func covered(_ x: Double, _ y: Double) -> Bool { coverage.contains { x >= $0.l && x <= $0.r && y >= $0.t && y <= $0.b } }
        let font = input.font == 0 || !input.font.isFinite ? 10 : input.font
        let pad = max(3, min(6, font * 0.3))
        func clamp(_ box: Bounds) -> Bounds { Bounds(max(p.l,box.l),max(p.t,box.t),min(p.r,box.r),min(p.b,box.b)) }
        var selected = clamp(Bounds(ink.l-pad,ink.t-pad,ink.r+pad,ink.b+pad))
        @discardableResult func include(_ bounds: Bounds) -> Bool {
            let q = clamp(bounds)
            guard q.r > q.l, q.b > q.t else { return false }
            let next = Bounds(min(selected.l,q.l),min(selected.t,q.t),max(selected.r,q.r),max(selected.b,q.b))
            let grew = next.l < selected.l || next.t < selected.t || next.r > selected.r || next.b > selected.b
            selected = next; return grew
        }
        for source in input.sources {
            let f = source.frame
            guard [f.minX,f.minY,f.width,f.height].allSatisfy(\.isFinite) else { continue }
            let foreignFont = source.font.flatMap { $0 == 0 || !$0.isFinite ? nil : $0 } ?? 10
            let otherPad = max(3,min(6,foreignFont * 0.3))
            let cross = max(otherPad,min(16,source.sourceFont.flatMap { $0.isFinite ? $0 : nil } ?? otherPad))
            let mx = source.vertical ? cross : otherPad, my = source.vertical ? otherPad : cross
            for b in source.bounds where b.count == 4 && b.allSatisfy(\.isFinite) {
                include(Bounds(Double(f.minX)+b[0]*Double(f.width)-mx,Double(f.minY)+b[1]*Double(f.height)-my,
                    Double(f.minX)+(b[0]+b[2])*Double(f.width)+mx,Double(f.minY)+(b[1]+b[3])*Double(f.height)+my))
            }
        }
        for rect in input.otherInk where rect.width > 0 && rect.height > 0 {
            let b = Bounds(rect); include(Bounds(b.l-pad,b.t-pad,b.r+pad,b.b+pad))
        }
        let frame = surface.frame, size = surface.imageSize, origin = surface.origin, scale = surface.scale
        let kx = Double(frame.width / size.width / scale.width), ky = Double(frame.height / size.height / scale.height)
        func px(_ x: Int) -> Double { Double(frame.minX)+(Double(origin.x)+(Double(x)+0.5)/Double(scale.width))/Double(size.width)*Double(frame.width) }
        func py(_ y: Int) -> Double { Double(frame.minY)+(Double(origin.y)+(Double(y)+0.5)/Double(scale.height))/Double(size.height)*Double(frame.height) }
        let loX = floor(((p.l-Double(frame.minX))/Double(frame.width)*Double(size.width)-Double(origin.x))*Double(scale.width))-1
        let hiX = ceil(((p.r-Double(frame.minX))/Double(frame.width)*Double(size.width)-Double(origin.x))*Double(scale.width))+1
        let loY = floor(((p.t-Double(frame.minY))/Double(frame.height)*Double(size.height)-Double(origin.y))*Double(scale.height))-1
        let hiY = ceil(((p.b-Double(frame.minY))/Double(frame.height)*Double(size.height)-Double(origin.y))*Double(scale.height))+1
        guard [loX,hiX,loY,hiY,kx,ky].allSatisfy(\.isFinite) else { return nil }
        let x0 = Int(max(0,min(Double(w),loX))), x1 = Int(max(0,min(Double(w),hiX)))
        let y0 = Int(max(0,min(Double(h),loY))), y1 = Int(max(0,min(Double(h),hiY)))
        let columns = x0 < x1 ? (x0..<x1).map(px) : [], rows = y0 < y1 ? (y0..<y1).map(py) : []
        let hx = kx / 2, hy = ky / 2
        func uncovered(_ x: Double, _ y: Double) -> Bool {
            covered(x,y) && !(x >= selected.l && x <= selected.r && y >= selected.t && y <= selected.b)
        }
        if x0 < x1 && y0 < y1 { for _ in 0..<6 {
            var grew = false
            for yy in y0..<y1 {
                let cy = rows[yy-y0], top = cy-hy, bottom = cy+hy
                for xx in x0..<x1 {
                    let i = yy*w+xx
                    if surface.safe[i] != 0 && surface.rgba[i*4+3] == 0 { continue }
                    let cx = columns[xx-x0], left = cx-hx, right = cx+hx
                    if uncovered(left,top) || uncovered(right,top) || uncovered(left,bottom) || uncovered(right,bottom) {
                        if include(Bounds(left-1,top-1,right+1,bottom+1)) { grew = true }
                    }
                }
            }
            if !grew { break }
        } }
        let next = coverage.map { Bounds(max($0.l,selected.l),max($0.t,selected.t),min($0.r,selected.r),min($0.b,selected.b)) }
            .filter { $0.r-$0.l >= 0.5 && $0.b-$0.t >= 0.5 }
        guard !next.isEmpty else { return nil }
        let box = Bounds(next.map(\.l).min()!,next.map(\.t).min()!,next.map(\.r).max()!,next.map(\.b).max()!)
        let before = coverage.reduce(0.0) { $0+$1.area }, after = next.reduce(0.0) { $0+$1.area }
        guard box.area < p.area * 0.95 || after < before * 0.95 else { return nil }
        return Proposal(rect: box.rect, coverage: next.map(\.rect), clipped: next.count > 1 || input.clipped,
                        beforeArea: floor(before+0.5), afterArea: floor(after+0.5))
    }
}
