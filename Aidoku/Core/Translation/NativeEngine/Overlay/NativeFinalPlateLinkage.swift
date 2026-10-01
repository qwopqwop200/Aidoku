import CoreGraphics
import Foundation

/// Final plate linkage14597–14903: preserve all source/ink/restoration, then
/// expose only artwork whose newly revealed plate edges remain indistinguishable.
enum NativeFinalPlateLinkage {
    struct Item {
        let id: String
        let rotation: Double
        let vertical: Bool
        let sourceVertical: Bool
        let sourceFont: Double?
        let sourceBounds: [Double]?
        let auxiliaryBounds: [[Double]]
    }
    struct Node {
        let id: String
        var ink: CGRect
        let font: Double
        let shown: Bool
        let transformed: Bool
        let fits: Bool
        let sampledColors: [[Double]]
    }
    struct Panel {
        let id: String
        var box: CGRect
        var coverage: [CGRect]?
        let color: [Double]
        let rootChild: Bool
        let sourceErasure: Bool
        let preservedCaption: Bool
        let foreignFills: Bool
        let transformed: Bool
        let backing: Bool
        let shown: Bool
        let unknownClip: Bool
        let restoration: CGRect?
    }
    struct Crop { let x: Int; let y: Int; let width: Int; let height: Int }
    struct Link {
        let panelIndex: Int
        let id: String
        let pieces: [CGRect]
        let releases: [CGRect]
        let single: Bool
        let move: CGPoint?
        let releasedArea: Double
    }
    struct Result { let links: [Link]; let panels: [Panel]; let remainingPixels: Int; let timeExhausted: Bool }

    private struct Edges {
        let minX: Double; let minY: Double; let maxX: Double; let maxY: Double
        var width: Double { maxX-minX }; var height: Double { maxY-minY }
        var midX: Double { (minX+maxX)/2 }; var midY: Double { (minY+maxY)/2 }
        var size: CGSize { CGSize(width:width,height:height) }
        var cg: CGRect { CGRect(x:minX,y:minY,width:width,height:height) }
        init(_ r: CGRect) { minX=r.origin.x;minY=r.origin.y;maxX=r.origin.x+r.size.width;maxY=r.origin.y+r.size.height }
        init(left: Double, top: Double, right: Double, bottom: Double) { minX=left;minY=top;maxX=right;maxY=bottom }
        init(x: Double,y: Double,width: Double,height: Double) { minX=x;minY=y;maxX=x+width;maxY=y+height }
        func insetBy(dx: Double,dy: Double)->Edges { Edges(left:minX+dx,top:minY+dy,right:maxX-dx,bottom:maxY-dy) }
    }
    static func resolve(items: [Item], nodes inputNodes: [Node], panels inputPanels: [Panel], frame: CGRect,
        imageSize: CGSize, opacity: Double, preserveBackground: Bool,
        milliseconds: () -> Double = { 0 }, read: (Crop) throws -> [UInt8]?) rethrows -> Result {
        var panels = inputPanels, nodes = inputNodes, remaining = 1_048_576, links: [Link] = []
        var exhausted = false
        guard opacity == 1, items.count <= 256, preserveBackground, valid(frame), imageSize.width > 0, imageSize.height > 0 else {
            return .init(links: [], panels: panels, remainingPixels: remaining, timeExhausted: false)
        }
        let started = milliseconds(), sx = Double(imageSize.width / frame.width), sy = Double(imageSize.height / frame.height)
        func source(_ values: [Double]?) -> Edges? {
            guard let b=values,b.count==4,b.allSatisfy(\.isFinite),b[2]>0,b[3]>0 else { return nil }
            return Edges(left:frame.minX+b[0]*frame.width,top:frame.minY+b[1]*frame.height,
                right:frame.minX+(b[0]+b[2])*frame.width,bottom:frame.minY+(b[1]+b[3])*frame.height)
        }
        func sources(_ item: Item) -> [Edges] { ([item.sourceBounds]+item.auxiliaryBounds.map(Optional.some)).compactMap(source) }
        func clipped(_ a: Edges, _ b: Edges) -> Edges {
            Edges(left:max(a.minX,b.minX),top:max(a.minY,b.minY),right:min(a.maxX,b.maxX),bottom:min(a.maxY,b.maxY))
        }
        func inside(_ r: Edges, _ x: Double, _ y: Double) -> Bool { x >= r.minX && x <= r.maxX && y >= r.minY && y <= r.maxY }
        func empty(_ r: Edges) -> Bool { r.size.width <= 0.25 || r.size.height <= 0.25 }
        func cut(_ a: Edges, _ b: Edges) -> Double { max(0,min(a.maxX,b.maxX)-max(a.minX,b.minX))*max(0,min(a.maxY,b.maxY)-max(a.minY,b.minY)) }
        func bounds(_ rects: [Edges]) -> Edges {
            let x = rects.map(\.minX).min()!, y = rects.map(\.minY).min()!
            return Edges(left:x,top:y,right:rects.map(\.maxX).max()!,bottom:rects.map(\.maxY).max()!)
        }
        func subtract(_ rects: [Edges], _ b: Edges) -> [Edges] {
            rects.flatMap { a -> [Edges] in
                if min(a.maxX,b.maxX) <= max(a.minX,b.minX) || min(a.maxY,b.maxY) <= max(a.minY,b.minY) { return [a] }
                let top = max(a.minY,b.minY), bottom = min(a.maxY,b.maxY)
                return [Edges(left:a.minX,top:a.minY,right:a.maxX,bottom:b.minY),
                    Edges(left:a.minX,top:b.maxY,right:a.maxX,bottom:a.maxY),
                    Edges(left:a.minX,top:top,right:b.minX,bottom:bottom),
                    Edges(left:b.maxX,top:top,right:a.maxX,bottom:bottom)]
                    .filter { $0.size.width >= 0.25 && $0.size.height >= 0.25 }
            }
        }
        for pi in panels.indices {
            if milliseconds()-started > 60 { exhausted = true; break }
            let panel = panels[pi]
            guard let item = items.first(where: { $0.id == panel.id }), item.rotation == 0,
                  panel.rootChild, !panel.sourceErasure, !panel.preservedCaption, !panel.foreignFills,
                  !panel.transformed, !panel.backing, panel.shown, panel.color.count == 3,
                  let ni = nodes.firstIndex(where: { $0.id == panel.id }), nodes[ni].shown, !nodes[ni].transformed else { continue }
            let node = nodes[ni], box = Edges(panel.box)
            var ink = Edges(node.ink)
            guard !empty(box), !empty(ink) else { continue }
            let coverage = panel.coverage?.filter(valid).map(Edges.init) ?? [box]
            guard !coverage.isEmpty, panel.coverage != nil || !panel.unknownClip else { continue }
            let size = node.font == 0 ? 10 : node.font, pad = max(3,min(6,size*0.3))
            var vacated = false, move: CGPoint?
            if !item.vertical, let source = source(item.sourceBounds) {
                let room = coverage.filter { $0.minX < source.maxX && $0.maxX > source.minX && $0.minY < source.maxY && $0.maxY > source.minY }
                if cut(ink,source) == 0, !room.isEmpty {
                    let R = bounds(room), w = ink.width, h = ink.height, margin = min(3,pad)
                    if w <= R.width-2*margin && h <= R.height-2*margin {
                        let cx = max(R.minX+margin+w/2,min(R.maxX-margin-w/2,source.midX))
                        let cy = max(R.minY+margin+h/2,min(R.maxY-margin-h/2,source.midY))
                        let next = Edges(left:cx-w/2,top:cy-h/2,right:cx+w/2,bottom:cy+h/2)
                        let onPlate = [0.0,0.25,0.5,0.75,1].allSatisfy { u in [0.0,0.5,1].allSatisfy { v in coverage.contains { inside($0,next.minX+u*w,next.minY+v*h) } } }
                        let clear = nodes.allSatisfy { other in !other.shown || empty(Edges(other.ink)) || other.id == node.id ||
                            Edges(other.ink).maxX+2 <= next.minX || Edges(other.ink).minX-2 >= next.maxX || Edges(other.ink).maxY+2 <= next.minY || Edges(other.ink).minY-2 >= next.maxY }
                        let under = panels.filter { $0.id != item.id && $0.shown }.allSatisfy { other in
                            let pieces = other.coverage?.filter(valid); let rects = pieces?.isEmpty == false ? pieces!.map(Edges.init) : [Edges(other.box)]
                            return rects.reduce(0.0) { $0+cut(next,$1) } <= max(0.1*w*h,rects.reduce(0.0) { $0+cut(ink,$1) })
                        }
                        if onPlate && clear && under && hypot(next.minX-ink.minX,next.minY-ink.minY) >= max(4,size*0.5) && node.fits {
                            move = CGPoint(x:next.minX-ink.minX,y:next.minY-ink.minY); ink = next; vacated = true
                        }
                    }
                }
            }
            var required = [ink.insetBy(dx:-pad,dy:-pad)] + sources(item).map { $0.insetBy(dx:-pad,dy:-pad) }
            for other in items where other.id != item.id {
                let cross = max(3,min(16,other.sourceFont?.isFinite == true ? other.sourceFont! : 3))
                for source in sources(other) where !(source.minX > box.maxX || source.maxX < box.minX || source.minY > box.maxY || source.maxY < box.minY) {
                    required.append(source.insetBy(dx:other.sourceVertical ? -cross : -3,dy:other.sourceVertical ? -3 : -cross))
                }
            }
            required += nodes.filter { $0.shown && $0.id != item.id && !empty(Edges($0.ink)) }.map { Edges($0.ink).insetBy(dx:-2,dy:-2) }
            if let restoration = panel.restoration { required.append(Edges(restoration)) }
            let kept = required.map { clipped($0,box) }.filter { !empty($0) }
            let env = clipped(bounds([ink]+sources(item)).insetBy(dx:-pad,dy:-pad),box), cb = bounds(coverage)
            let cuts = kept+[env]+coverage
            let xs = Array(Set([box.minX,box.maxX]+cuts.flatMap { [$0.minX,$0.maxX] })).filter { $0 >= box.minX && $0 <= box.maxX }.sorted()
            let ys = Array(Set([box.minY,box.maxY]+cuts.flatMap { [$0.minY,$0.maxY] })).filter { $0 >= box.minY && $0 <= box.maxY }.sorted()
            guard xs.count*ys.count <= 4096 else { continue }
            let cols = xs.count-1, rows = ys.count-1
            guard cols > 0, rows > 0 else { continue }
            var free = [UInt8](repeating:0,count:cols*rows), used = free, releases: [Edges] = []
            for j in 0..<rows { for i in 0..<cols {
                let cx = (xs[i]+xs[i+1])/2, cy = (ys[j]+ys[j+1])/2
                if xs[i+1]-xs[i] < 0.01 || ys[j+1]-ys[j] < 0.01 { continue }
                if kept.contains(where: { inside($0,cx,cy) }) || !coverage.contains(where: { inside($0,cx,cy) }) { continue }
                free[j*cols+i] = inside(env,cx,cy) ? 2 : 1
            } }
            struct Candidate { let i0: Int; let i1: Int; let j0: Int; let j1: Int; let area: Double; let zone: UInt8 }
            var freed = false
            for _ in 0..<32 {
                var best: Candidate?
                for zone: UInt8 in [1,2] {
                    if best != nil { break }
                    for j in 0..<rows { for i in 0..<cols where free[j*cols+i] == zone && used[j*cols+i] == 0 {
                        var maxI = cols, b = j
                        while b < rows && free[b*cols+i] == zone && used[b*cols+i] == 0 {
                            var a = i
                            while a < maxI && free[b*cols+a] == zone && used[b*cols+a] == 0 { a += 1 }
                            maxI = a
                            let area = Double((xs[maxI]-xs[i])*(ys[b+1]-ys[j]))
                            if best == nil || area > best!.area { best = Candidate(i0:i,i1:maxI-1,j0:j,j1:b,area:area,zone:zone) }
                            b += 1
                        }
                    } }
                }
                guard let best else { break }
                for b in best.j0...best.j1 { for a in best.i0...best.i1 { used[b*cols+a] = 1 } }
                let R = Edges(left:xs[best.i0],top:ys[best.j0],right:xs[best.i1+1],bottom:ys[best.j1+1])
                let w = Double(R.width), h = Double(R.height)
                if min(w,h) < 2 || w*h < max(16,0.36*size*size) { continue }
                func side(_ x0: Double, _ y0: Double, _ x1: Double, _ y1: Double) -> Bool {
                    (0...8).filter { t in kept.contains { inside($0,x0+(x1-x0)*Double(t)/8,y0+(y1-y0)*Double(t)/8) } }.count*2 >= 9
                }
                let inner = [side(R.minX-0.75,R.minY,R.minX-0.75,R.maxY),side(R.maxX+0.75,R.minY,R.maxX+0.75,R.maxY),
                    side(R.minX,R.minY-0.75,R.maxX,R.minY-0.75),side(R.minX,R.maxY+0.75,R.maxX,R.maxY+0.75)]
                let x0 = max(0,Int(floor((R.minX-frame.minX)*sx))), y0 = max(0,Int(floor((R.minY-frame.minY)*sy)))
                let x1 = min(Int(imageSize.width),Int(ceil((R.maxX-frame.minX)*sx))), y1 = min(Int(imageSize.height),Int(ceil((R.maxY-frame.minY)*sy)))
                let pw = x1-x0, ph = y1-y0
                guard pw >= 1, ph >= 1, pw <= remaining/ph else { continue }
                remaining -= pw*ph
                guard let data = try read(Crop(x:x0,y:y0,width:pw,height:ph)), data.count >= pw*ph*4 else { continue }
                var hidden = 0, total = 0, edge = 0, edgeSame = 0, letter = [UInt8](repeating:0,count:pw*ph)
                let colors = node.sampledColors.filter { $0.count == 3 && $0.allSatisfy(\.isFinite) }
                func pagePoint(_ x: Int, _ y: Int) -> (Double,Double) { (frame.minX+(Double(x0+x)+0.5)/sx,frame.minY+(Double(y0+y)+0.5)/sy) }
                for yy in 0..<ph { for xx in 0..<pw {
                    let (cx,cy) = pagePoint(xx,yy)
                    if !inside(R,cx,cy) { continue }
                    let i = (yy*pw+xx)*4
                    let differs = (0..<3).contains { abs(Double(data[i+$0])-panel.color[$0]) > 40 }
                    total += 1
                    if differs {
                        hidden += 1
                        if colors.contains(where: { c in (0..<3).allSatisfy { abs(Double(data[i+$0])-c[$0]) <= 72 } }) { letter[yy*pw+xx] = 1 }
                    }
                    if (inner[0] && cx-R.minX < 1.5) || (inner[1] && R.maxX-cx < 1.5) || (inner[2] && cy-R.minY < 1.5) || (inner[3] && R.maxY-cy < 1.5) {
                        edge += 1; if !differs { edgeSame += 1 }
                    }
                } }
                let strip = best.zone == 1 && ((R.minX <= cb.minX+0.5 && R.maxX >= cb.maxX-0.5 && (R.minY <= cb.minY+0.5 || R.maxY >= cb.maxY-0.5)) ||
                    (R.minY <= cb.minY+0.5 && R.maxY >= cb.maxY-0.5 && (R.minX <= cb.minX+0.5 || R.maxX >= cb.maxX-0.5)))
                let left = vacated && best.zone == 1
                if total == 0 || Double(hidden) < 0.12*Double(total) || Double(hidden) < 6*sx*sy ||
                    (!strip && inner.contains(true) && !left && (edge == 0 || Double(edgeSame) < 0.8*Double(edge))) { continue }
                var isolated = 0, mark = [UInt8](repeating:0,count:pw*ph)
                let speck = left ? Double.infinity : max(6,2*sx*sy)
                if !left { for s0 in 0..<(pw*ph) {
                    if Double(isolated) > speck { break }
                    if letter[s0] == 0 || mark[s0] != 0 { continue }
                    var stack = [s0], count = 0, out = false; mark[s0] = 1
                    while let c = stack.popLast() {
                        let xx = c%pw, yy = c/pw; count += 1
                        let (cx,cy) = pagePoint(xx,yy)
                        if (!inner[0] && cx-R.minX < 1) || (!inner[1] && R.maxX-cx < 1) || (!inner[2] && cy-R.minY < 1) || (!inner[3] && R.maxY-cy < 1) { out = true }
                        for b in (yy-1)...(yy+1) { for a in (xx-1)...(xx+1) where a >= 0 && b >= 0 && a < pw && b < ph {
                            let q = b*pw+a
                            if letter[q] != 0 && mark[q] == 0 { mark[q] = 1; stack.append(q) }
                        } }
                    }
                    if !out { isolated += count }
                } }
                if Double(isolated) > speck { continue }
                releases.append(R); if left { freed = true }
            }
            if move != nil && !freed { continue }
            if releases.isEmpty { continue }
            var pieces = coverage
            for release in releases { pieces = subtract(pieces,release) }
            pieces = pieces.map { clipped($0,box) }.filter { !empty($0) }
            guard !pieces.isEmpty, pieces.count <= 256, node.fits else { continue }
            let single = pieces.count == 1 && panel.coverage == nil && !panel.unknownClip
            if single { panels[pi].box = pieces[0].cg } else { panels[pi].coverage = pieces.map(\.cg) }
            nodes[ni].ink = ink.cg
            links.append(.init(panelIndex:pi,id:item.id,pieces:pieces.map(\.cg),releases:releases.map(\.cg),single:single,move:move,
                releasedArea:releases.reduce(0.0) { $0+Double($1.width*$1.height) }))
        }
        return .init(links:links,panels:panels,remainingPixels:remaining,timeExhausted:exhausted)
    }
    private static func valid(_ rect: CGRect) -> Bool {
        [rect.origin.x,rect.origin.y,rect.size.width,rect.size.height].allSatisfy(\.isFinite) && rect.size.width > 0 && rect.size.height > 0
    }
}
