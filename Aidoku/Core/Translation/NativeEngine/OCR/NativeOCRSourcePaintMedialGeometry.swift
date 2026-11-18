import Foundation

/// Source-only residual conventions. Every measured layer is returned, never
/// GT-ranked or selected by OCR. Statistical/medial cores are NOT erase masks.
/// Unknown detached paint remains unknown in NativeOCRSourcePaintGeometry records.
/// No sourceIndex-to-owner join, saved fixtures, model calls or probability bounds.
@available(iOS 18.0, *)
enum NativeOCRSourcePaintMedialGeometry {
    static let sourceFirstEnvironmentKey = NativeOCRSourcePaintGeometry.sourceFirstEnvironmentKey
    private static let sourceFirstEnabled = NativeOCRSourcePaintGeometry.sourceFirstGeneration
    /// Process-wide opt-in. Geometry/work changes require the parent's fresh
    /// native pixel replay before enabling this in the active generation plan.
    static let generationV2EnvironmentKey = "AIDOKU_OCR_SOURCE_GENERATION_V2"
    private static let generationV2Enabled = sourceFirstEnabled
        || ProcessInfo.processInfo.environment[generationV2EnvironmentKey] == "1"

    static let recoveryV3EnvironmentKey = "AIDOKU_OCR_GENERATION_RECOVERY_V3"
    private static let recoveryV3Enabled = ProcessInfo.processInfo.environment[recoveryV3EnvironmentKey] == "1"

    // The plan supports both whole mechanisms and individual measured layers.
    static func shouldGenerate(_ mechanism: String, layer: String) -> Bool {
        API.shouldGenerate(mechanism) && API.shouldGenerate(mechanism + "/" + layer)
    }

    private typealias API = NativeOCRSourcePaintGeometry
    private typealias Original = NativeOCRSourceOwnedRailPartition.Original
    private typealias Seed = NativeOCRDetectorSeedEvidence
    private typealias Primitive = NativeOCRSourceContext50V2.Primitive
    private struct V {
        var x: Double; var y: Double
        func dot(_ p: V) -> Double { x*p.x+y*p.y }
        var length: Double { hypot(x,y) }
        var unit: V { V(x:x/length,y:y/length) }
        static func +(l: V,r: V) -> V { V(x:l.x+r.x,y:l.y+r.y) }
        static func -(l: V,r: V) -> V { V(x:l.x-r.x,y:l.y-r.y) }
        static func *(l: V,r: Double) -> V { V(x:l.x*r,y:l.y*r) }
    }
    private struct B {
        var l:Double; var t:Double; var r:Double; var b:Double
        var width:Double { r-l }; var height:Double { b-t }
        var area:Double { max(0,width)*max(0,height) }
        func overlap(_ other:B)->Double { max(0,min(r,other.r)-max(l,other.l))*max(0,min(b,other.b)-max(t,other.t)) }
        var quad:[[Double]] { [[l,t],[r,t],[r,b],[l,b]] }
    }
    private struct Basis {
        var a:V; var n:V
        init?(_ q:[[Double]]) {
            guard NativeOCRSourcePaintMedialGeometry.valid(q) else { return nil }
            let edges=(0..<4).map { V(x:q[($0+1)%4][0]-q[$0][0],y:q[($0+1)%4][1]-q[$0][1]) }
            var chosen=0
            for i in 1..<4 { if edges[i].length>edges[chosen].length { chosen=i } }
            let edge=edges[chosen];guard edge.length>0 else { return nil }
            var axis=edge.unit
            if axis.y<0 || (axis.y==0 && axis.x<0) { axis=axis * -1 }
            a=axis;n=V(x:axis.y,y:-axis.x)
        }
        init(axis:V) { a=axis.unit;n=V(x:a.y,y:-a.x) }
        func bounds(_ p:[V])->B {
            let ns=p.map{n.dot($0)},ts=p.map{a.dot($0)}
            return B(l:ns.min()!,t:ts.min()!,r:ns.max()!,b:ts.max()!)
        }
        func quad(_ b:B)->[[Double]] {
            [(b.l,b.t),(b.r,b.t),(b.r,b.b),(b.l,b.b)].map { n0,t0 in
                let p=n*n0+a*t0;return [p.x,p.y]
            }
        }
    }
    private struct CC { let pixels:[Int];let bounds:B;let clipped:Bool }
    private struct Seg { let parts:[CC] }

    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI,
                        query: NativeOCRSourcePaintGeometry.Query,
                        originals:[NativeOCRSourceOwnedRailPartition.Original],
                        rf:[NativeOCRSourceContext50V2.Primitive],
                        generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil)
        -> [NativeOCRSourcePaintGeometry.Measurement] {
        guard roi.width>2,roi.height>2,roi.width<=1_500_000/roi.height,
              roi.originX>=0,roi.originY>=0,roi.rgb.count==roi.width*roi.height*3,
              originals.count<=4096,Basis(query.polygon) != nil else { return [] }
        let dimensions=Set(originals.compactMap { o -> String? in
            guard let s=o.detectorSeedEvidence,s.isValid else { return nil };return "\(s.sourceWidth)x\(s.sourceHeight)"
        })
        guard dimensions.count==1,let reference=originals.compactMap(\.detectorSeedEvidence).first(where: { $0.isValid }),
              roi.originX+roi.width<=reference.sourceWidth,roi.originY+roi.height<=reference.sourceHeight else { return [] }
        func admissible(_ rows: [API.Measurement]) -> [API.Measurement] {
            rows.filter { m in
                valid(m.polygon) && m.diagnostics.values.allSatisfy(\.isFinite) && m.polygon.allSatisfy {
                    $0[0]>=Double(roi.originX) && $0[1]>=Double(roi.originY) &&
                    $0[0]<=Double(roi.originX+roi.width) && $0[1]<=Double(roi.originY+roi.height)
                }
            }
        }
        let members=authenticated(query,originals)
        var result:[API.Measurement]=[]
        if members.count==1,let owner=members.first,let seed=originals[owner].detectorSeedEvidence,seed.isValid,
           seed.completeCCScan==true,seed.ownershipVersion==2 {
            let exclusive = !seed.components.isEmpty && (seed.ambiguousComponents ?? []).isEmpty && (seed.candidateComponents ?? []).isEmpty
            if exclusive {
                let dark = darkDB(roi,original:originals[owner],seed:seed,originals:originals,owner:owner,generationLedger:generationLedger)
                if sourceFirstEnabled {
                    let primary = admissible(dark).first { $0.terminalEvidence == .completeSourceInk }
                    if let primary { return [primary] }
                }
                result += dark
                let closed = closedCore(roi,query:query.polygon,seed:seed,owner:owner,generationLedger:generationLedger)
                if sourceFirstEnabled, let primary = admissible(closed).first { return [primary] }
                result += closed
            }
        }
        // Independent actual-private-cell intersections certify physical support,
        // NOT the ancestry of an unknown query. No source members are inferred.
        result += regionalLayers(roi,query:query.polygon,originals:originals,rf:rf,generationLedger:generationLedger)
        return admissible(result)
    }

    private static func once(_ ledger: NativeOCRSourcePaintColumnPartition.GenerationLedger?,
                             family: String, owner: Int = -1, polygon: [[Double]], roi: API.PixelROI, accepting full: API.PixelROI,
                             _ body: () -> [API.Measurement]) -> [API.Measurement] {
        guard let ledger else { return body() }
        return ledger.run(family: family, owner: owner, polygon: polygon,
                          window: [roi.originX, roi.originY, roi.width, roi.height]) {
            body().filter { m in
                valid(m.polygon) && m.diagnostics.values.allSatisfy(\.isFinite) && m.polygon.allSatisfy {
                    $0[0]>=Double(full.originX) && $0[1]>=Double(full.originY) &&
                    $0[0]<=Double(full.originX+full.width) && $0[1]<=Double(full.originY+full.height)
                }
            }
        }
    }

    // MARK: Strict source contracts and scalar geometry
    private static func valid(_ q:[[Double]])->Bool {
        guard q.count==4,q.allSatisfy({$0.count==2 && $0.allSatisfy(\.isFinite)}) else { return false }
        let z=(0..<4).map { i -> Double in
            let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
            return (b[0]-a[0])*(c[1]-b[1])-(b[1]-a[1])*(c[0]-b[0])
        }
        return z.allSatisfy{$0>0} || z.allSatisfy{$0<0}
    }
    private static func same(_ a:[[Double]],_ b:[[Double]])->Bool {
        guard valid(a),valid(b) else { return false }
        for reverse in [false,true] { for offset in 0..<4 {
            if (0..<4).allSatisfy({i in let j=(offset+(reverse ? 4-i:i))%4;return a[i]==b[j]}) { return true }
        }};return false
    }
    private static func authenticated(_ query:API.Query,_ originals:[Original])->[Int] {
        let ids=Set(query.sourceMembers)
        if !ids.isEmpty {
            // Query.sourceMembers are ACTUAL CURRENT RAW ARRAY INDICES.
            // Seed.parentBoxIndex is a different domain and must NOT remap them.
            guard ids.allSatisfy({ originals.indices.contains($0) }) else { return [] }
            return ids.sorted()
        }
        let exact=originals.indices.filter { same(originals[$0].polygon,query.polygon) }
        return exact.count==1 ? exact:[]
    }
    private static func quantile(_ values:[Double],_ fraction:Double)->Double {
        guard !values.isEmpty else { return .nan };let v=values.sorted(),p=Double(v.count-1)*fraction
        let i=Int(floor(p)),j=min(v.count-1,i+1);return v[i]+(v[j]-v[i])*(p-Double(i))
    }
    private static func median(_ x:[Double])->Double { quantile(x,0.5) }
    private static func pts(_ q:[[Double]])->[V] { q.map{V(x:$0[0],y:$0[1])} }
    private static func box(_ q:[[Double]])->B {
        B(l:q.map{$0[0]}.min()!,t:q.map{$0[1]}.min()!,r:q.map{$0[0]}.max()!,b:q.map{$0[1]}.max()!)
    }
    private static func world(_ i:Int,_ roi:API.PixelROI)->V {
        V(x:Double(roi.originX+i%roi.width)+0.5,y:Double(roi.originY+i/roi.width)+0.5)
    }
    private static func rgb(_ i:Int,_ roi:API.PixelROI)->[Double] {
        let j=i*3;return [Double(roi.rgb[j]),Double(roi.rgb[j+1]),Double(roi.rgb[j+2])]
    }
    private static func crop(_ roi:API.PixelROI,_ b:B,limit:Int=500000)->API.PixelROI? {
        let x=Int(floor(b.l)),y=Int(floor(b.t)),r=Int(ceil(b.r)),t=Int(ceil(b.b)),w=r-x,h=t-y
        guard x>=roi.originX,y>=roi.originY,r<=roi.originX+roi.width,t<=roi.originY+roi.height,
              w>2,h>2,w<=limit/h else { return nil }
        var data:[UInt8]=[];data.reserveCapacity(w*h*3)
        for yy in y..<t {
            let a=((yy-roi.originY)*roi.width+x-roi.originX)*3
            data.append(contentsOf:roi.rgb[a..<(a+w*3)])
        }
        return .init(width:w,height:h,originX:x,originY:y,rgb:data)
    }
    private static func window(_ roi:API.PixelROI,_ q:[[Double]],_ pad:Double,limit:Int=500000)->API.PixelROI? {
        let b=box(q);return crop(roi,B(l:b.l-pad,t:b.t-pad,r:b.r+pad,b:b.b+pad),limit:limit)
    }
    private static func sides(_ q:[[Double]])->[Double] {
        (0..<4).map { hypot(q[($0+1)%4][0]-q[$0][0],q[($0+1)%4][1]-q[$0][1]) }
    }
    private static func measurement(_ q:[[Double]],_ mechanism:String,_ layer:String,_ d:[String:Double])->API.Measurement {
        var diag=d;diag["detachedMembershipKnown"]=0;diag["recognitionUsed"]=0;diag["RFMaskUsed"]=0;diag["ROIUpperBoundsUsed"]=0
        return .init(polygon:q,layer:layer,mechanism:mechanism,diagnostics:diag)
    }
    private static func pixelEnvelope(_ p:[V],_ basis:Basis)->[[Double]] {
        var b=basis.bounds(p);let hn=0.5*(abs(basis.n.x)+abs(basis.n.y)),ha=0.5*(abs(basis.a.x)+abs(basis.a.y))
        b.l-=hn;b.r+=hn;b.t-=ha;b.b+=ha;return basis.quad(b)
    }
    private static func hull(_ p:[V])->[V] {
        let sorted=p.sorted{$0.x == $1.x ? $0.y<$1.y:$0.x<$1.x}
        var unique:[V]=[]
        for v in sorted { if unique.last?.x != v.x || unique.last?.y != v.y { unique.append(v) } }
        guard unique.count>2 else { return unique }
        func cross(_ a:V,_ b:V,_ c:V)->Double { (b.x-a.x)*(c.y-a.y)-(b.y-a.y)*(c.x-a.x) }
        var lo:[V]=[],hi:[V]=[]
        for v in unique { while lo.count>=2 && cross(lo[lo.count-2],lo[lo.count-1],v)<=0 { lo.removeLast() };lo.append(v) }
        for v in unique.reversed() { while hi.count>=2 && cross(hi[hi.count-2],hi[hi.count-1],v)<=0 { hi.removeLast() };hi.append(v) }
        lo.removeLast();hi.removeLast();return lo+hi
    }
    private static func minimumEnvelopeLegacy(_ p:[V], knownHull: [V]? = nil)->[[Double]]? {
        let h=knownHull ?? hull(p);guard h.count>=3 else { return nil }
        var best:Basis?,area=Double.infinity
        for i in h.indices {
            let edge=h[(i+1)%h.count]-h[i];if edge.length==0 { continue }
            let basis=Basis(axis:edge),b=basis.bounds(p),value=b.width*b.height
            if value<area { area=value;best=basis }
        }
        return best.map{pixelEnvelope(p,$0)}
    }

    private struct EnvelopeFit {
        let quad: [[Double]]?
        let sortedSupportPoints: Int
        let hullVertices: Int
        let evaluatedAxes: Int
        let fullPixelFits: Int
        let legacyFallback: Bool
    }

    /// This predicate replaces a discarded minimum-area fit, not an ink or
    /// appearance gate. The caller's finite source-pixel centers have an envelope
    /// exactly when at least three of them are non-collinear.
    private static func hasSourceArea(_ points: [V]) -> Bool {
        guard let first = points.first,
              let second = points.dropFirst().first(where: { $0.x != first.x || $0.y != first.y }) else { return false }
        let edge = second - first
        return points.contains { point in
            let delta = point - first
            let value = edge.x * delta.y - edge.y * delta.x
            return value.isFinite && value != 0
        }
    }

    /// Horizontal interior source cells cannot be convex-hull vertices. Retain
    /// both actual extrema of every scanline before sorting, including terminals.
    /// Non-canonical coordinates fail back to the original general point fitter.
    private static func scanlineSupport(_ points: [V]) -> [V]? {
        var rows: [Double: (V, V)] = [:]
        for point in points {
            guard point.x.isFinite, point.y.isFinite,
                  point.x - floor(point.x) == 0.5, point.y - floor(point.y) == 0.5 else { return nil }
            if var row = rows[point.y] {
                if point.x < row.0.x { row.0 = point }
                if point.x > row.1.x { row.1 = point }
                rows[point.y] = row
            } else { rows[point.y] = (point, point) }
        }
        return rows.values.flatMap { row in row.0.x == row.1.x ? [row.0] : [row.0, row.1] }
    }

    private static func sameRectangleAxes(_ a: V, _ b: V) -> Bool {
        (a.x == b.x && a.y == b.y) || (a.x == -b.x && a.y == -b.y)
            || (a.x == -b.y && a.y == b.x) || (a.x == b.y && a.y == -b.x)
    }

    /// Score only exact hull support at distinct rectangle axes. Project the
    /// complete original pixel array once for the returned envelope, so no outer
    /// cells or stroke width are approximated. Near-tied angles use the old fit.
    private static func minimumEnvelopeV2(_ points: [V]) -> EnvelopeFit {
        func legacy(_ sorted: Int, _ vertices: [V]?, _ axes: Int) -> EnvelopeFit {
            let sourceHull = vertices ?? hull(points)
            return .init(quad: minimumEnvelopeLegacy(points, knownHull: sourceHull), sortedSupportPoints: sorted,
                hullVertices: sourceHull.count, evaluatedAxes: axes,
                fullPixelFits: sourceHull.count >= 3 ? sourceHull.count + 1 : 0, legacyFallback: true)
        }
        guard let support = scanlineSupport(points) else { return legacy(points.count, nil, 0) }
        let vertices = hull(support)
        guard vertices.count >= 3 else {
            return .init(quad: nil, sortedSupportPoints: support.count, hullVertices: vertices.count,
                evaluatedAxes: 0, fullPixelFits: 0, legacyFallback: false)
        }
        var axes: [Basis] = [], areas: [Double] = [], extents: [Double] = []
        for i in vertices.indices {
            let edge = vertices[(i+1) % vertices.count] - vertices[i]
            guard edge.length > 0 else { continue }
            let basis = Basis(axis: edge)
            guard !axes.contains(where: { sameRectangleAxes($0.a, basis.a) }) else { continue }
            let bounds = basis.bounds(vertices)
            let area = bounds.width * bounds.height
            guard area.isFinite, area > 0 else { return legacy(support.count, vertices, axes.count) }
            axes.append(basis); areas.append(area); extents.append(bounds.width + bounds.height)
        }
        guard var winner = areas.indices.first else { return legacy(support.count, vertices, 0) }
        for i in areas.indices where areas[i] < areas[winner] { winner = i }
        if areas.count > 1 {
            let runnerUp = areas.indices.filter { $0 != winner }.map { areas[$0] }.min()!
            let scale = vertices.reduce(1.0) { max($0, abs($1.x), abs($1.y)) }
            // Arithmetic uncertainty only: large world origins or a tied fit
            // trigger the original work, never a different admission decision.
            let error = max(1, areas[winner]) * 1e-12
                + 64 * Double.ulpOfOne * scale * max(1, extents[winner])
            guard runnerUp - areas[winner] > error else { return legacy(support.count, vertices, axes.count) }
        }
        return .init(quad: pixelEnvelope(points, axes[winner]), sortedSupportPoints: support.count,
            hullVertices: vertices.count, evaluatedAxes: axes.count, fullPixelFits: 1, legacyFallback: false)
    }

    private static func quantiles(_ values: [Double], _ low: Double, _ high: Double) -> (Double, Double) {
        let sorted = values.sorted()
        func value(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return .nan }
            let position = Double(sorted.count - 1) * fraction
            let i = Int(floor(position)), j = min(sorted.count - 1, i + 1)
            return sorted[i] + (sorted[j] - sorted[i]) * (position - Double(i))
        }
        return (value(low), value(high))
    }

    // MARK: Shared actual pixel components and DB cell raster
    private static func neighbors(_ i:Int,_ w:Int,_ h:Int,_ diagonal:Bool)->[Int] {
        let x=i%w,y=i/w;var result:[Int]=[]
        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
            if !diagonal && dx != 0 && dy != 0 { continue }
            let xx=x+dx,yy=y+dy;if xx>=0 && yy>=0 && xx<w && yy<h { result.append(yy*w+xx) }
        }};return result
    }
    private static func segment(_ mask:[Bool],_ roi:API.PixelROI,diagonal:Bool=true)->Seg {
        var labels=Array(repeating:-1,count:mask.count),parts:[CC]=[]
        for start in mask.indices where mask[start] && labels[start]<0 {
            if parts.count>=4096 { return Seg(parts:[]) }
            let id=parts.count;var queue=[start],front=0;labels[start]=id
            var l=roi.width,t=roi.height,r=0,b=0,clipped=false
            while front<queue.count {
                let i=queue[front];front+=1;let x=i%roi.width,y=i/roi.width
                l=min(l,x);r=max(r,x);t=min(t,y);b=max(b,y)
                clipped = clipped || x==0 || y==0 || x==roi.width-1 || y==roi.height-1
                for j in neighbors(i,roi.width,roi.height,diagonal) where mask[j] && labels[j]<0 { labels[j]=id;queue.append(j) }
            }
            parts.append(CC(pixels:queue,bounds:B(l:Double(l+roi.originX),t:Double(t+roi.originY),r:Double(r+roi.originX+1),b:Double(b+roi.originY+1)),clipped:clipped))
        };return Seg(parts:parts)
    }
    private static func raster(_ seed:Seed,_ roi:API.PixelROI)->[Bool] {
        var mask=Array(repeating:false,count:roi.width*roi.height)
        rasterInto(seed, roi, mask: &mask)
        return mask
    }
    /// Same clipped seed-run writes as raster(), without a temporary full ROI
    /// mask and full-array scan for every foreign original.
    private static func rasterInto(_ seed:Seed,_ roi:API.PixelROI,mask:inout [Bool]) {
        let sx=Double(seed.sourceWidth)/Double(seed.mapFullWidth),sy=Double(seed.sourceHeight)/Double(seed.mapFullHeight)
        for cc in seed.components { for r in cc.runs {
            let x0=max(0,Int(floor(Double(r.x)*sx))-roi.originX),x1=min(roi.width,Int(ceil(Double(r.x+r.count)*sx))-roi.originX)
            let y0=max(0,Int(floor(Double(r.y)*sy))-roi.originY),y1=min(roi.height,Int(ceil(Double(r.y+1)*sy))-roi.originY)
            if x1>x0 && y1>y0 { for y in y0..<y1 { for x in x0..<x1 { mask[y*roi.width+x]=true } } }
        }}
    }

    private static func gray(_ roi:API.PixelROI)->[Int] {
        (0..<(roi.width*roi.height)).map { i in
            // OpenCV RGB2GRAY fixed-point coefficients, uint8 path.
            let j=i*3;return (Int(roi.rgb[j])*4899+Int(roi.rgb[j+1])*9617+Int(roi.rgb[j+2])*1868+8192)>>14
        }
    }
    private static func otsu(_ values:[Int])->Int {
        var hist=Array(repeating:0.0,count:256);for v in values { hist[v]+=1 }
        let total=Double(values.count),sum=(0..<256).reduce(0.0){$0+Double($1)*hist[$1]}
        var mass=0.0,partial=0.0,best = -1.0,threshold=0
        for i in 0..<255 {
            mass+=hist[i];partial+=Double(i)*hist[i];if mass==0 || mass==total { continue }
            let delta=partial/mass-(sum-partial)/(total-mass),score=mass*(total-mass)*delta*delta
            if score>best { best=score;threshold=i }
        };return threshold
    }

    // MARK: Continuous private DB median normal + measured dark terminals
    private static func darkDB(_ full:API.PixelROI,original:Original,seed:Seed,originals:[Original],owner:Int,
                               generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger?)->[API.Measurement] {
        let mechanism = "db-median-run-normal-pixel-terminal-extent-v1"
        let completeEnabled = shouldGenerate(mechanism, layer: "db-core-normal-full-dark-along")
        guard completeEnabled else { return [] }
        let q=original.polygon,lengths=sides(q),short=lengths.min()!,long=lengths.max()!
        guard short>=3,long>=3*short,seed.components.count==1,
              let roi=window(full,q,0.25*short,limit:200000) else { return [] }
        return once(generationLedger, family: "medial.dark-db", owner: owner, polygon: q, roi: roi, accepting: full) {
            darkDBPixels(roi, q: q, seed: seed, originals: originals, short: short, long: long, mechanism: mechanism)
        }
    }

    private static func darkDBPixels(_ roi:API.PixelROI,q:[[Double]],seed:Seed,originals:[Original],
                                     short:Double,long:Double,mechanism:String)->[API.Measurement] {
        let own=raster(seed,roi);var foreign=Array(repeating:false,count:own.count)
        var avoidedForeignRasters = 0
        for o in originals { if let other=o.detectorSeedEvidence,other.ownerID != seed.ownerID,other.isValid,
            other.sourceWidth==seed.sourceWidth,other.sourceHeight==seed.sourceHeight {
            if generationV2Enabled {
                rasterInto(other, roi, mask: &foreign)
                avoidedForeignRasters += 1
            } else {
                let m=raster(other,roi);for i in m.indices where m[i] { foreign[i]=true }
            }
        }}
        guard !own.indices.contains(where:{own[$0] && foreign[$0]}) else { return [] }
        let values=gray(roi);guard values.max()!-values.min()!>=64 else { return [] }
        let threshold=min(128,otsu(values)),seg=segment(values.map{$0<=threshold},roi)
        var indices:[Int]=[]
        for cc in seg.parts where cc.pixels.contains(where:{own[$0]}) {
            if cc.clipped || cc.pixels.contains(where:{foreign[$0]}) { return [] };indices += cc.pixels
        }
        guard Double(indices.count)>=max(8,0.02*short*long) else { return [] }
        let points=indices.map{world($0,roi)},wb=box(points.map{[$0.x,$0.y]})
        // The envelope remains an applicability prerequisite for the complete terminal.
        guard max(wb.width,wb.height)>=0.5*long,
              generationV2Enabled ? hasSourceArea(points) : minimumEnvelopeLegacy(points) != nil else { return [] }
        var output: [API.Measurement] = []
        guard box(q).height>=3*box(q).width else { return output }
        var rows:[Int:[(Int,Int)]]=[:]
        for r in seed.components[0].runs { rows[r.y,default:[]].append((r.x,r.x+r.count)) }
        let keys=rows.keys.sorted();guard keys.count>=8,keys.last!-keys.first!+1==keys.count else { return output }
        var merged:[(Int,Int,Int)]=[]
        for y in keys {
            let spans=rows[y]!.sorted{$0.0<$1.0};var hi=spans[0].1
            for span in spans.dropFirst() { if span.0>hi { return output };hi=max(hi,span.1) }
            merged.append((y,spans[0].0,hi))
        }
        let sx=Double(seed.sourceWidth)/Double(seed.mapFullWidth),sy=Double(seed.sourceHeight)/Double(seed.mapFullHeight)
        let centers=merged.map{V(x:Double($0.1+$0.2)*sx/2,y:(Double($0.0)+0.5)*sy)}
        let sampleCount=min(256,centers.count)
        let sampled=(0..<sampleCount).map { centers[Int(Double($0)*Double(centers.count-1)/Double(sampleCount-1))] }
        var slopes:[Double]=[]
        for i in sampled.indices { for j in sampled.indices where j>i { slopes.append((sampled[j].x-sampled[i].x)/(sampled[j].y-sampled[i].y)) } }
        let slope=median(slopes);guard abs(slope)<=0.25 else { return output }
        let basis=Basis(axis:V(x:slope,y:1))
        let width=median(merged.map{Double($0.2-$0.1)*sx*abs(basis.n.x)+sy*abs(basis.n.y)})
        let normal=median(centers.map{basis.n.dot($0)})
        var core:[V]=[]
        for (y,l,r) in merged { for xx in [l,r] { for yy in [y,y+1] { core.append(V(x:Double(xx)*sx,y:Double(yy)*sy)) } } }
        let db=basis.bounds(core),length=db.height
        // This entry is for the installed Manga detector profile. No fitted ratio.
        let ratio=NativeCoreMLDBPostprocessConfiguration.manga.unclipRatio
        let distance=width*length*ratio/(2*(width+length)),ink=basis.bounds(points),half=0.5*(abs(basis.a.x)+abs(basis.a.y))
        let l=normal-width/2-distance,r=normal+width/2+distance
        var diag=["privateRows":Double(keys.count),"medianDBWidth":width,"axisSlope":slope,"unclipRatio":ratio,"nativeUnclipDistance":distance,"darkPixels":Double(points.count),"completeNormalInk":0.0]
        if generationV2Enabled {
            diag["medialGenerationV2"] = 1
            diag["discardedEnvelopeFitAvoided"] = 1
            diag["foreignRasterAllocationsAvoided"] = Double(avoidedForeignRasters)
            diag["foreignFullMaskScansAvoided"] = Double(avoidedForeignRasters)
        }
        if recoveryV3Enabled {
            // The DB unclip width is a detector construction, not printed ink.
            // All points here belong to non-clipped dark CCs intersecting the
            // authenticated private seed and touching no foreign private cells.
            guard let body = darkNormalCompletion(points: points, runCenters: centers) else { return [] }
            diag.merge(body.diagnostics) { _, new in new }
            diag["generationRecoveryV3"] = 1
            diag["dbNormalWidthBeforeRepair"] = r-l
            diag["completeNormalInk"] = 1
            diag["completeVisibleInk"] = 0 // Bright/colored outer strokes remain unmeasured.
            var complete = measurement(body.polygon, mechanism, "owned-dark-normal-completion-v3", diag)
            complete.terminalEvidenceGroup = seed.ownerID
            complete.terminalEvidence = .completeSourceInk
            return [complete]
        }
        do {
            var complete = measurement(basis.quad(B(l:l,t:ink.t-half,r:r,b:ink.b+half)),mechanism,"db-core-normal-full-dark-along",diag)
            complete.terminalEvidenceGroup = seed.ownerID
            complete.terminalEvidence = .completeSourceInk
            output.append(complete)
        }
        return output
    }

    /// One physical body fit, no alternative thresholds/angles or extra records.
    /// Nil means normal/axis support is uncertain: decline the dark primary so
    /// the caller can route closed/rim/achromatic recovery lazily. This completes
    /// selected dark CC support, not every possible visible outer stroke.
    private static func darkNormalCompletion(points: [V], runCenters: [V])
        -> (polygon: [[Double]], diagnostics: [String: Double])? {
        guard points.count >= 32, runCenters.count >= 8 else { return nil }
        func regression(_ rows: ArraySlice<V>) -> Double? {
            let count = Double(rows.count)
            guard count >= 3 else { return nil }
            let mx = rows.reduce(0) { $0+$1.x }/count
            let my = rows.reduce(0) { $0+$1.y }/count
            var covariance = 0.0, variance = 0.0
            for p in rows { covariance += (p.x-mx)*(p.y-my); variance += (p.y-my)*(p.y-my) }
            guard variance > 0 else { return nil }
            let slope = covariance/variance
            return slope.isFinite && abs(slope) <= 0.25 ? slope : nil
        }
        // Linear run-center fit preserves subpixel drift hidden by quantized
        // median pair slopes. Split support detects curvature/branch ambiguity.
        let middle = runCenters.count/2
        guard let slope = regression(runCenters[...]),
              let first = regression(runCenters[..<middle]),
              let last = regression(runCenters[middle...]) else { return nil }
        let basis = Basis(axis: V(x: slope, y: 1))
        let extent = basis.bounds(points)
        let mass = quantiles(points.map { basis.n.dot($0) }, 0.01, 0.99)
        let footprint = 0.5*(abs(basis.n.x)+abs(basis.n.y))
        let alongFootprint = 0.5*(abs(basis.a.x)+abs(basis.a.y))
        let massWidth = mass.1-mass.0+2*footprint
        let tail = max(mass.0-extent.l, extent.r-mass.1)
        let axisDisagreement = max(abs(first-slope), abs(last-slope))*extent.height
        // Mass is an uncertainty check only: never trim supported outer pixels.
        // These source-relative guards do not classify absolute box geometry.
        guard massWidth > 0, tail <= max(2*footprint, 0.25*massWidth),
              axisDisagreement <= max(2*footprint, 0.25*massWidth) else { return nil }
        let bounds = B(l: extent.l-footprint, t: extent.t-alongFootprint,
                       r: extent.r+footprint, b: extent.b+alongFootprint)
        return (basis.quad(bounds), ["normalCompletionAxisSlope": slope,
            "normalCompletionRunCenters": Double(runCenters.count), "normalCompletionMassWidth": massWidth,
            "normalCompletionFullWidth": bounds.width, "normalCompletionTail": tail,
            "normalCompletionAxisDisagreement": axisDisagreement, "normalCompletionUncertain": 0,
            "normalCompletionDarkCCOnly": 1, "normalCompletionPixelCount": Double(points.count),
            "normalCompletionExtraPixelQueries": 0, "normalCompletionCandidates": 1])
    }

    // MARK: Closed neutral rim, modal enclosed fill, fixed robust 90% ink mass
    private static func closedCore(_ full:API.PixelROI,query q:[[Double]],seed:Seed,owner:Int,
                                   generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger?)->[API.Measurement] {
        let layer = sourceFirstEnabled ? "canonical-private-body-complete-extent-v2" : "robust-90percent-ink-mass-core"
        guard shouldGenerate("db-owned-closed-fill-theilsen-90mass-core-v2", layer: layer) else { return [] }
        let width=sides(q).min()!,b=box(q)
        guard let roi=crop(full,B(l:b.l-0.2*width,t:b.t-0.4*width,r:b.r+0.2*width,b:b.b+0.4*width),limit:600000) else { return [] }
        let family = sourceFirstEnabled ? "medial.closed-core.source-first-v2" : "medial.closed-core"
        return once(generationLedger, family: family, owner: owner, polygon: q, roi: roi, accepting: full) {
            closedCorePixels(roi, q: q, seed: seed)
        }
    }

    private static func closedCorePixels(_ roi:API.PixelROI,q:[[Double]],seed:Seed)->[API.Measurement] {
        let white=(0..<(roi.width*roi.height)).map { i -> Bool in let p=rgb(i,roi);return p.min()!>210 && p.max()!-p.min()!<50 }
        let seg=segment(white.map{!$0},roi,diagonal:false)
        let sx=Double(seed.sourceWidth)/Double(seed.mapFullWidth),sy=Double(seed.sourceHeight)/Double(seed.mapFullHeight)
        var cells=Set<Int>()
        for cc in seed.components { for r in cc.runs { for x in r.x..<(r.x+r.count) { cells.insert(r.y*seed.mapFullWidth+x) } } }
        var selected:[Int]=[];var owned=0
        for cc in seg.parts where !cc.clipped && cc.pixels.count>=4 {
            let hits=cc.pixels.reduce(0) { sum,i in
                let p=world(i,roi),gx=Int(floor(p.x/sx)),gy=Int(floor(p.y/sy))
                return sum+(cells.contains(gy*seed.mapFullWidth+gx) ? 1:0)
            }
            if Double(hits)/Double(cc.pixels.count)>=0.05 { selected+=cc.pixels;owned+=1 }
        }
        guard owned>=3,let color=modalColor(selected,roi) else { return [] }
        let completeMaterial = sourceFirstEnabled ? selected : []
        selected=selected.filter { i in let p=rgb(i,roi);return (0..<3).map{abs(p[$0]-color[$0])}.max()!<=48 }
        guard selected.count>=16 else { return [] }
        let points=selected.map{world($0,roi)}
        let envelope: [[Double]]?
        let envelopeWork: EnvelopeFit?
        if sourceFirstEnabled {
            // One source-anchored robust axis below replaces the hull-angle
            // sweep and the trimmed-mass variant. Retain ALL selected material
            // for its complete extent, including non-modal dark outline pixels.
            envelope = nil; envelopeWork = nil
        } else if generationV2Enabled {
            let fit = minimumEnvelopeV2(points)
            guard let measured = fit.quad else { return [] }
            envelope = measured; envelopeWork = fit
        } else {
            guard let measured = minimumEnvelopeLegacy(points) else { return [] }
            envelope = measured; envelopeWork = nil
        }
        guard let initial=Basis(q) else { return [] }
        let ts=points.map{initial.a.dot($0)},ns=points.map{initial.n.dot($0)}
        let fittedPoints = sourceFirstEnabled
            ? B(l: ns.min()!, t: ts.min()!, r: ns.max()!, b: ts.max()!)
            : Basis(envelope!)!.bounds(points)
        let oldspan=initial.bounds(pts(q)).height
        guard max(fittedPoints.width,fittedPoints.height)/oldspan>=0.65 else { return [] }
        var out: [API.Measurement] = []
        let t0=ts.min()!,span=ts.max()!-t0
        guard span>0 else { return out }
        var groups=Array(repeating:[Int](),count:16)
        for i in points.indices { let band=max(0,min(15,Int((ts[i]-t0)/span*16)));groups[band].append(i) }
        var observations:[V]=[]
        for group in groups where group.count>=4 {
            observations.append(V(x:group.map{ts[$0]}.reduce(0,+)/Double(group.count),y:group.map{ns[$0]}.reduce(0,+)/Double(group.count)))
        }
        guard observations.count>=8 else { return out };var slopes:[Double]=[]
        for i in observations.indices { for j in observations.indices where j>i && observations[j].x-observations[i].x>=0.2*span {
            slopes.append((observations[j].y-observations[i].y)/(observations[j].x-observations[i].x))
        }}
        guard !slopes.isEmpty else { return out }
        let slope=median(slopes),intercept=median(observations.map{$0.y-slope*$0.x})
        let residual=median(observations.map{abs($0.y-slope*$0.x-intercept)})
        guard residual<=0.2*sides(q).min()! else { return out }
        let basis=Basis(axis:initial.a+initial.n*slope)
        if sourceFirstEnabled {
            var materialMask = [Bool](repeating: false, count: roi.width * roi.height)
            for i in completeMaterial { materialMask[i] = true }
            guard sourceComponentsRepresented(seed, roi, materialMask: materialMask) else { return [] }
            let completePoints = completeMaterial.map { world($0, roi) }
            let canonical = pixelEnvelope(completePoints, basis)
            // A separately visible closed bright rim is unresolved by this
            // material measurement. Fall through to the regional rim producer
            // (and then the parent's later families), rather than clip it.
            guard !unresolvedBrightRim(white, roi, materialMask: materialMask, basis: basis,
                                      bounds: basis.bounds(completePoints)) else { return [] }
            return [measurement(canonical, "db-owned-closed-fill-theilsen-90mass-core-v2",
                "canonical-private-body-complete-extent-v2",
                ["fillPixels":Double(points.count),"completeMaterialPixels":Double(completePoints.count),
                 "occupiedBands":Double(observations.count),"axisSlope":slope,"medianBandResidual":residual,
                 "canonicalAxisFits":1,"normalMassSortsAvoided":2,"hullAngleSweepsAvoided":1,
                 "privateSeedComponentsCovered":Double(seed.components.count),"completeMeasuredMaterial":1,
                 "completeVisibleInk":0,"outerBrightRimUnresolved":0,"sourceFirstGeneration":1])]
        }
        let normal=points.map{basis.n.dot($0)},along=points.map{basis.a.dot($0)}
        let hn=0.5*(abs(basis.n.x)+abs(basis.n.y)),ha=0.5*(abs(basis.a.x)+abs(basis.a.y))
        let low: Double, high: Double
        if generationV2Enabled {
            let mass = quantiles(normal, 0.05, 0.95)
            low = mass.0 - hn; high = mass.1 + hn
        } else {
            low = quantile(normal,0.05)-hn; high = quantile(normal,0.95)+hn
        }
        let core=basis.quad(B(l:low,t:along.min()!-ha,r:high,b:along.max()!+ha))
        // These two estimates are computed from this exact selected material
        // pixel array, not from a shared query/owner or overlapping columns.
        // Prefer its complete envelope only when the two boundary conventions
        // already agree at the representative selector's 0.9 overlap level.
        // A distinct narrow body remains an explicit ambiguity alternative.
        let common=intersectionArea(core,envelope!)
        let union=abs(polygonArea(pts(core)))+abs(polygonArea(pts(envelope!)))-common
        if union>0 && common/union>=0.9 { return out }
        var diagnostics = ["fillPixels":Double(points.count),"occupiedBands":Double(observations.count),"axisSlope":slope,
            "medianBandResidual":residual,"normalMassFraction":0.9,"normalWidth":high-low,"completeVisibleInk":0,"allAlternativesCounted":1]
        if let work = envelopeWork {
            diagnostics["medialGenerationV2"] = 1
            diagnostics["envelopeSortedSupportPoints"] = Double(work.sortedSupportPoints)
            diagnostics["envelopeHullVertices"] = Double(work.hullVertices)
            diagnostics["envelopeDistinctAxes"] = Double(work.evaluatedAxes)
            diagnostics["envelopeFullPixelFits"] = Double(work.fullPixelFits)
            diagnostics["envelopeLegacyFallback"] = work.legacyFallback ? 1 : 0
            diagnostics["normalMassSortsAvoided"] = 1
        }
        out.append(measurement(core,
            "db-owned-closed-fill-theilsen-90mass-core-v2","robust-90percent-ink-mass-core",
            diagnostics))
        return out
    }

    /// Each actual private DB component must intersect the complete material.
    /// This is a read of measured cells, not query-parent source ownership.
    private static func sourceComponentsRepresented(_ seed: Seed, _ roi: API.PixelROI, materialMask: [Bool]) -> Bool {
        let sx = Double(seed.sourceWidth) / Double(seed.mapFullWidth)
        let sy = Double(seed.sourceHeight) / Double(seed.mapFullHeight)
        return seed.components.allSatisfy { component in
            component.runs.contains { run in
                let x0 = max(0, Int(floor(Double(run.x)*sx))-roi.originX)
                let x1 = min(roi.width, Int(ceil(Double(run.x+run.count)*sx))-roi.originX)
                let y0 = max(0, Int(floor(Double(run.y)*sy))-roi.originY)
                let y1 = min(roi.height, Int(ceil(Double(run.y+1)*sy))-roi.originY)
                guard x1 > x0, y1 > y0 else { return false }
                for y in y0..<y1 { for x in x0..<x1 where materialMask[y*roi.width+x] { return true } }
                return false
            }
        }
    }

    private static func unresolvedBrightRim(_ white: [Bool], _ roi: API.PixelROI, materialMask: [Bool],
                                            basis: Basis, bounds: B) -> Bool {
        let hn = 0.5*(abs(basis.n.x)+abs(basis.n.y)), ha = 0.5*(abs(basis.a.x)+abs(basis.a.y))
        for cc in segment(white, roi, diagonal: false).parts where !cc.clipped {
            guard cc.pixels.contains(where: { i in
                neighbors(i, roi.width, roi.height, false).contains { materialMask[$0] }
            }) else { continue }
            let bright = basis.bounds(cc.pixels.map { world($0, roi) })
            if bright.l < bounds.l-hn || bright.r > bounds.r+hn || bright.t < bounds.t-ha || bright.b > bounds.b+ha {
                return true
            }
        }
        return false
    }
    private static func modalColor(_ indices:[Int],_ roi:API.PixelROI)->[Double]? {
        guard !indices.isEmpty else { return nil };var counts:[Int:Int]=[:]
        for i in indices { let p=rgb(i,roi),key=(Int(p[0])/16)*256+(Int(p[1])/16)*16+Int(p[2])/16;counts[key,default:0]+=1 }
        guard let mode=counts.keys.sorted().max(by:{counts[$0]!<counts[$1]!}) else { return nil }
        let chosen=indices.filter { i in let p=rgb(i,roi);return (Int(p[0])/16)*256+(Int(p[1])/16)*16+Int(p[2])/16==mode }
        return (0..<3).map{j in median(chosen.map{rgb($0,roi)[j]})}
    }

    // MARK: Independently private-rooted fill/rim with printed-fill terminals
    private static func regionalLayers(_ full:API.PixelROI,query q:[[Double]],originals:[Original],rf:[Primitive],
                                       generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger?)->[API.Measurement] {
        let mechanism = "source-db-rooted-rim-normal-fill-terminal-v2"
        let terminalEnabled = shouldGenerate(mechanism, layer: "rim-normal-fill-terminal")
        guard terminalEnabled else { return [] }
        let b=box(q),w=b.width,h=b.height
        guard w>=8,h>=4*w else { return [] }
        let scopes=rf.filter { $0.canonicalClass==1 && valid($0.polygon) && box($0.polygon).overlap(b)>=0.85*w*h }
        let supporters=originals.filter { valid($0.polygon) && b.overlap(box($0.polygon))>=0.3*box($0.polygon).area }
        guard !scopes.isEmpty,supporters.count>=2,let roi=window(full,q,ceil(w*0.25)) else { return [] }
        return once(generationLedger, family: "medial.regional-layers", polygon: q, roi: roi, accepting: full) {
            regionalLayerPixels(roi, q: q, originals: originals, w: w, h: h, b: b,
                                scopes: scopes, supporters: supporters, mechanism: mechanism)
        }
    }

    private static func regionalLayerPixels(_ roi:API.PixelROI,q:[[Double]],originals:[Original],w:Double,h:Double,b:B,
                                           scopes:[Primitive],supporters:[Original],mechanism:String)->[API.Measurement] {
        let all=Array(0..<(roi.width*roi.height)),eligible=all.filter { i in
            let p=world(i,roi),v=rgb(i,roi)
            return p.x>=ceil(b.l) && p.x<Double(Int(floor(b.r))) && p.y>=ceil(b.t) && p.y<Double(Int(floor(b.b))) &&
                v.max()!-v.min()!>=28 && v.reduce(0,+)/3<170
        }
        guard Double(eligible.count)>=w*h*0.025,let color=modalColor(eligible,roi) else { return [] }
        let mask=all.map { i -> Bool in let p=rgb(i,roi);return sqrt((0..<3).reduce(0.0){$0+pow(p[$1]-color[$1],2)})<=36 }
        let seg=segment(mask,roi,diagonal:false);var selected=Array(repeating:false,count:mask.count);var componentCount=0
        for cc in seg.parts where !cc.clipped {
            guard Double(cc.pixels.count)>=max(6,w*0.1),cc.bounds.width<=1.1*w,cc.bounds.height<=1.5*w else { continue }
            let centerX=cc.pixels.map{Double(roi.originX+$0%roi.width)}.reduce(0,+)/Double(cc.pixels.count)
            let centerY=cc.pixels.map{Double(roi.originY+$0/roi.width)}.reduce(0,+)/Double(cc.pixels.count)
            guard abs(centerX-(b.l+b.r)/2)<=w*0.35,centerY>=b.t-w*0.1,centerY<=b.b+w*0.1 else { continue }
            for i in cc.pixels { selected[i]=true };componentCount+=1
        }
        guard componentCount>=4 else { return [] }
        var used=Set<String>(),rootCount=0,rootHits=0
        for original in originals {
            guard let seed=original.detectorSeedEvidence,seed.isValid,seed.ownershipVersion==2,seed.completeCCScan==true else { continue }
            let sx=Double(seed.sourceWidth)/Double(seed.mapFullWidth),sy=Double(seed.sourceHeight)/Double(seed.mapFullHeight)
            for cc in seed.components {
                let key="\(seed.mapFullWidth):\(seed.mapFullHeight):\(cc.seed)";if used.contains(key) { continue }
                var hits=0
                for run in cc.runs {
                    let y=Int(floor((Double(run.y)+0.5)*sy))-roi.originY;if y<0 || y>=roi.height { continue }
                    for gx in run.x..<(run.x+run.count) {
                        let x=Int(floor((Double(gx)+0.5)*sx))-roi.originX
                        if x>=0 && x<roi.width && selected[y*roi.width+x] { hits+=1 }
                    }
                }
                if hits>=3 { used.insert(key);rootCount+=1;rootHits+=hits }
            }
        }
        guard rootCount>=2 else { return [] }
        let fill=selected.indices.filter{selected[$0]},radius=Int(ceil(w*0.2))
        let white=all.map { i -> Bool in let p=rgb(i,roi);return p.min()!>=210 && p.max()!-p.min()!<=30 }
        var seen=selected,rim=Array(repeating:false,count:mask.count),queue=fill,depth=Array(repeating:0,count:mask.count),front=0
        while front<queue.count {
            let i=queue[front];front+=1;if depth[i]>=radius { continue }
            for j in neighbors(i,roi.width,roi.height,false) where !seen[j] {
                seen[j]=true
                if white[j] { rim[j]=true;depth[j]=depth[i]+1;queue.append(j) }
            }
        }
        let rimPixels=rim.indices.filter{rim[$0]};guard Double(rimPixels.count)>=Double(fill.count)*0.25 else { return [] }
        func cellBounds(_ indices:[Int])->B {
            let points=indices.map{world($0,roi)},bb=box(points.map{[$0.x,$0.y]})
            return B(l:bb.l-0.5,t:bb.t-0.5,r:bb.r+0.5,b:bb.b+0.5)
        }
        let fb=cellBounds(fill),rb=cellBounds(fill+rimPixels),hybrid=B(l:rb.l,t:fb.t,r:rb.r,b:fb.b)
        let d=["privateRootComponents":Double(rootCount),"actualPrivateCellHits":Double(rootHits),"fillPixels":Double(fill.count),
               "rimPixels":Double(rimPixels.count),"rimSearchCap":Double(radius),"mangaSupporters":Double(supporters.count),
               "RFRegionalScopes":Double(scopes.count),"historicalQueryAncestryProven":0.0,"allAlternativesCounted":1.0]
        var output: [API.Measurement] = []
        output.append(measurement(hybrid.quad,mechanism,"rim-normal-fill-terminal",d))
        return output
    }

    // MARK: Shared polygon overlap for robust-core ambiguity
    private static func polygonArea(_ p:[V])->Double {
        guard p.count>=3 else { return 0 };var sum=0.0
        for i in p.indices { let a=p[i],b=p[(i+1)%p.count];sum+=a.x*b.y-b.x*a.y };return sum/2
    }
    private static func intersectionArea(_ query:[[Double]],_ clip:[[Double]])->Double {
        var subject=pts(query);let polygon=pts(clip),sign=polygonArea(polygon)>=0 ? 1.0:-1.0
        for i in polygon.indices {
            if subject.isEmpty { return 0 };let a=polygon[i],b=polygon[(i+1)%polygon.count],edge=b-a
            func side(_ p:V)->Double { sign*(edge.x*(p.y-a.y)-edge.y*(p.x-a.x)) }
            let input=subject;subject=[];var previous=input.last!,old=side(previous)
            for p in input {
                let current=side(p)
                if (old>=0) != (current>=0) {
                    let f=old/(old-current);subject.append(previous+(p-previous)*f)
                }
                if current>=0 { subject.append(p) };previous=p;old=current
            }
        };return abs(polygonArea(subject))
    }

}
