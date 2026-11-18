import Foundation

/// Source-only CC03 discovery. Complete weak runs establish support, never
/// ownership: emitted auxiliary observations deliberately have no seed owner.
@available(iOS 18.0, *)
enum NativeOCRCanonicalAuxiliarySeeds {
    struct Observation: Sendable {
        let polygon: [[Double]]
        let score: Double
    }
    private struct P { let x: Double; let y: Double }
    private struct Component {
        let points: [P]
        let rf: Int
        let privatePixels: Int
    }
    enum Failure: Error { case invalidMap }

    /// Eight-connected components in raster discovery order, including all
    /// pixels so CC statistics do not depend on contour simplification.
    private static func components(_ active: [Bool], width: Int, height: Int) -> [[Int]] {
        var visited = [Bool](repeating: false, count: active.count), groups: [[Int]] = []
        for start in active.indices where active[start] && !visited[start] {
            var queue = [start], head = 0
            visited[start] = true
            while head < queue.count {
                let i = queue[head]; head += 1
                let x = i % width, y = i / width
                for yy in max(0, y - 1)...min(height - 1, y + 1) {
                    for xx in max(0, x - 1)...min(width - 1, x + 1) {
                        let j = yy * width + xx
                        if active[j] && !visited[j] { visited[j] = true; queue.append(j) }
                    }
                }
            }
            groups.append(queue)
        }
        return groups
    }
    /// Only RF component IDs are consumed. Flood horizontal runs in raster
    /// seed order, extending one column on either side for 8-connectivity.
    private static func supportLabels(_ ink: [Float], width: Int, height: Int) -> [Int] {
        var labels = [Int](repeating: 0, count: ink.count)
        var pending: [(row: Int, low: Int, high: Int)] = []
        var label = 0
        func addRun(row: Int, column: Int) -> Int {
            let offset = row * width
            var low = column, high = column
            while low > 0 && ink[offset+low-1] >= 0.25 { low -= 1 }
            while high+1 < width && ink[offset+high+1] >= 0.25 { high += 1 }
            for x in low...high { labels[offset+x] = label }
            pending.append((row, low, high))
            return high
        }
        for i in ink.indices where ink[i] >= 0.25 && labels[i] == 0 {
            label += 1
            _ = addRun(row: i / width, column: i % width)
            while let run = pending.popLast() {
                for y in max(0, run.row-1)...min(height-1, run.row+1) where y != run.row {
                    let offset = y * width, end = min(width-1, run.high+1)
                    var x = max(0, run.low-1)
                    while x <= end {
                        if ink[offset+x] >= 0.25 && labels[offset+x] == 0 {
                            x = addRun(row: y, column: x)
                        }
                        x += 1
                    }
                }
            }
        }
        return labels
    }
    private static func hull(_ points: [P]) -> [P] {
        let p = points.sorted { $0.x == $1.x ? $0.y < $1.y : $0.x < $1.x }
        guard p.count > 2 else { return p }
        func cross(_ a: P, _ b: P, _ c: P) -> Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        var low: [P] = [], high: [P] = []
        for q in p {
            while low.count >= 2 && cross(low[low.count-2], low.last!, q) <= 0 { low.removeLast() }
            low.append(q)
        }
        for q in p.reversed() {
            while high.count >= 2 && cross(high[high.count-2], high.last!, q) <= 0 { high.removeLast() }
            high.append(q)
        }
        return Array(low.dropLast()) + Array(high.dropLast())
    }
    private struct Rect {
        let axis: P; let normal: P
        let low: P; let high: P
        var width: Double { high.x-low.x }
        var height: Double { high.y-low.y }
        func quad(expand: Double = 0) -> [P] {
            [P(x:low.x-expand,y:low.y-expand), P(x:high.x+expand,y:low.y-expand),
             P(x:high.x+expand,y:high.y+expand), P(x:low.x-expand,y:high.y+expand)].map {
                P(x:axis.x*$0.x+normal.x*$0.y,y:axis.y*$0.x+normal.y*$0.y)
            }
        }
    }
    private static func rectangle(_ points: [P]) -> Rect? {
        let h = hull(points)
        guard h.count >= 3 else { return nil }
        var best: Rect?
        for i in h.indices {
            let b = h[(i+1)%h.count], a = h[i], length = hypot(b.x-a.x,b.y-a.y)
            guard length > 0 else { continue }
            let u = P(x:(b.x-a.x)/length,y:(b.y-a.y)/length), v = P(x:-u.y,y:u.x)
            let xs = h.map { $0.x*u.x+$0.y*u.y }, ys = h.map { $0.x*v.x+$0.y*v.y }
            let r = Rect(axis:u,normal:v,low:P(x:xs.min()!,y:ys.min()!),high:P(x:xs.max()!,y:ys.max()!))
            if best == nil || r.width*r.height < best!.width*best!.height { best = r }
        }
        return best
    }
    static func produce(probability p: NativeMainEnsembleOCRProbability.Sample,
                        originals: [NativeCoreMLDetectionBox], referencePolygons: [[[Double]]],
                        support: NativeRFDETRSourceSupportGrid,
                        cancellationCheck: () throws -> Void) throws -> [Observation] {
        let w = p.width, h = p.height, cells = 162*162
        guard w > 0, h > 0, w == p.resizedWidth, h == p.resizedHeight,
              p.values.count == w*h, support.native17Fields.count == 17*cells,
              p.values.allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw Failure.invalidMap }
        // OpenCV INTER_LINEAR center mapping of native text/SFX max support.
        func rf(_ x: Int, _ y: Int) -> Float {
            let fx = (Double(x)+0.5)*162/Double(w)-0.5, fy = (Double(y)+0.5)*162/Double(h)-0.5
            let ix = Int(floor(fx)), iy = Int(floor(fy)), dx = Float(fx-Double(ix)), dy = Float(fy-Double(iy))
            func sample(_ xx: Int, _ yy: Int) -> Float {
                let i = min(161,max(0,yy))*162+min(161,max(0,xx))
                return max(support.native17Fields[i],support.native17Fields[3*cells+i])
            }
            let a = sample(ix,iy)*(1-dx)+sample(ix+1,iy)*dx
            let b = sample(ix,iy+1)*(1-dx)+sample(ix+1,iy+1)*dx
            return a*(1-dy)+b*dy
        }
        var ink = [Float](); ink.reserveCapacity(w*h)
        for y in 0..<h { try cancellationCheck(); for x in 0..<w { ink.append(rf(x,y)) } }
        let rfLabels = supportLabels(ink, width: w, height: h)
        var privateInk = [Bool](repeating:false,count:w*h)
        for original in originals {
            guard let seed = original.detectorSeedEvidence, seed.completeCCScan == true,
                  seed.mapFullWidth == w, seed.mapFullHeight == h else { continue }
            for component in seed.components { for run in component.runs where (0..<h).contains(run.y) {
                let low=max(0,run.x), high=min(w,max(0,run.x+run.count))
                if low < high { for x in low..<high { privateInk[run.y*w+x] = true } }
            } }
        }
        let raw = components(p.values.map { $0 >= 0.3 },width:w,height:h)
        var accepted: [Component] = []
        for pixels in raw where pixels.count >= 4 {
            try cancellationCheck()
            let mean = pixels.reduce(0.0) { $0+Double(ink[$1]) }/Double(pixels.count)
            let high = Double(pixels.filter { ink[$0] >= 0.25 }.count)/Double(pixels.count)
            let roots = pixels.filter { privateInk[$0] }.count
            guard high >= 0.25, mean >= 0.15, roots > 0 || mean >= 0.4 else { continue }
            var frequencies: [Int:Int] = [:]
            for i in pixels where rfLabels[i] > 0 { frequencies[rfLabels[i],default:0] += 1 }
            guard let label = frequencies.keys.sorted().max(by: { frequencies[$0]! < frequencies[$1]! }) else { continue }
            let points = hull(pixels.map { P(x:Double($0%w),y:Double($0/w)) })
            guard points.count >= 3 else { continue }
            accepted.append(.init(points:points,rf:label,privatePixels:roots))
        }
        var parents = Array(accepted.indices)
        func root(_ i: Int) -> Int { var j=i; while parents[j] != j { j=parents[j] }; return j }
        func projections(_ points: [P], _ axis: P) -> (Double,Double) {
            let v=points.map { $0.x*axis.x+$0.y*axis.y }; return (v.min()!,v.max()!)
        }
        for i in accepted.indices {
            guard let r=rectangle(accepted[i].points) else { continue }
            let axis=r.width >= r.height ? r.axis:r.normal, normal=P(x:-axis.y,y:axis.x)
            let aa=projections(accepted[i].points,axis), an=projections(accepted[i].points,normal), aw=an.1-an.0
            for j in 0..<i where accepted[j].rf == accepted[i].rf {
                let bb=projections(accepted[j].points,axis), bn=projections(accepted[j].points,normal), bw=bn.1-bn.0
                let overlap=min(an.1,bn.1)-max(an.0,bn.0), gap=max(0,max(aa.0-bb.1,bb.0-aa.1))
                if overlap >= 0.5*max(1,min(aw,bw)) && gap <= 1.5*max(aw,bw) { parents[root(i)] = root(j) }
            }
        }
        var groups: [Int:[P]] = [:], order: [Int] = []
        for i in accepted.indices {
            let key=root(i); if groups[key] == nil { order.append(key) }; groups[key,default:[]] += accepted[i].points
        }
        var output: [Observation] = []
        for key in order {
            try cancellationCheck()
            guard let r=rectangle(groups[key]!), min(r.width,r.height) >= 2 else { continue }
            let body=r.quad().map { P(x:$0.x.rounded(.toNearestOrEven),y:$0.y.rounded(.toNearestOrEven)) }
            let bounds=(max(0,Int(floor(body.map(\.x).min()!))),max(0,Int(floor(body.map(\.y).min()!))),
                        min(w-1,Int(ceil(body.map(\.x).max()!))),min(h-1,Int(ceil(body.map(\.y).max()!))))
            // OpenCV's integer convex fill includes its LINE_8 boundary,
            // not only points inside the continuous quadrilateral.
            var low=[Int](repeating:w,count:h), high=[Int](repeating:-1,count:h)
            for edge in body.indices {
                var a=body[edge], b=body[(edge+1)%4]
                if a.x > b.x { swap(&a,&b) }
                var x=Int(a.x), y=Int(a.y)
                let dx=Int(b.x-a.x), dy=Int(abs(b.y-a.y)), sy=b.y >= a.y ? 1 : -1
                let major=max(dx,dy), minor=min(dx,dy)
                var error=major-2*minor
                for _ in 0...major {
                    if (0..<h).contains(y), (0..<w).contains(x) { low[y]=min(low[y],x);high[y]=max(high[y],x) }
                    if error < 0 { if dx >= dy { y += sy } else { x += 1 }; error += 2*major }
                    if dx >= dy { x += 1 } else { y += sy }
                    error -= 2*minor
                }
            }
            // Fixed16 scanline edge intersections, including rounded endpoints,
            // match the integer convex-fill scoring contract of CC03.
            struct ScanEdge { var index: Int; let direction: Int; var x: Int; var dx: Int; var endY: Int }
            let first=body.indices.min { body[$0].y < body[$1].y }!
            let startY=Int(body[first].y), endY=min(h-1,Int(body.map(\.y).max()!))
            var edges=[ScanEdge(index:first,direction:1,x:-65536,dx:0,endY:startY),
                       ScanEdge(index:first,direction:3,x:-65536,dx:0,endY:startY)]
            var remaining=4
            for y in startY...endY {
                for i in 0..<2 where y >= edges[i].endY {
                    var previous=edges[i].index, next=(previous+edges[i].direction)%4
                    while true {
                        let before=remaining; remaining -= 1
                        if before <= 0 { break }
                        let ty=Int(body[next].y)
                        if ty > y {
                            let xs=Int(body[previous].x)*65536, xe=Int(body[next].x)*65536
                            edges[i].endY=ty; edges[i].dx=((xe-xs)*2+(ty-y))/(2*(ty-y))
                            edges[i].x=xs; edges[i].index=next
                            break
                        }
                        previous=next;next=(next+edges[i].direction)%4
                    }
                }
                if remaining < 0 { break }
                if (0..<h).contains(y) {
                    let a=(min(edges[0].x,edges[1].x)+32768)>>16
                    let b=(max(edges[0].x,edges[1].x)+32768)>>16
                    if b >= 0 && a < w { low[y]=min(low[y],max(0,a));high[y]=max(high[y],min(w-1,b)) }
                }
                edges[0].x += edges[0].dx; edges[1].x += edges[1].dx
            }
            var values: [Float] = []
            for y in bounds.1...bounds.3 where low[y] <= high[y] {
                for x in low[y]...high[y] { values.append(p.values[y*w+x]) }
            }
            let score=Double(NativeRFDETRSourceSupportGrid.numpySum(values)/Float(max(1,values.count)))
            guard score >= 0.085 else { continue }
            let distance=r.width*r.height*1.4/(2*(r.width+r.height))
            let quad=r.quad(expand:distance).map { q in
                [max(0,min(Double(p.sourceWidth),q.x*Double(p.sourceWidth)/Double(w))),
                 max(0,min(Double(p.sourceHeight),q.y*Double(p.sourceHeight)/Double(h)))]
            }
            let fp=quad.map { NativeOCRPremergeCandidateFeatures.Point(x:$0[0],y:$0[1]) }
            guard NativeOCRPremergeCandidateFeatures.rfPolygonArea(fp) > 1,
                  !referencePolygons.contains(where: { row in
                      (NativeOCRPremergeCandidateFeatures.polygonOverlap(fp,row.map { .init(x:$0[0],y:$0[1]) })?.iou ?? 0) >= 0.8
                  }) else { continue }
            output.append(.init(polygon:quad,score:score))
        }
        return output
    }
}
