import Foundation

/// Extra physical observations only; never removes/replaces incumbent geometry.
/// Query members must name actual original-array owners. A corrected query with
/// unknown ancestry abstains; neither sourceIndex proximity nor a nearest box is
/// an ownership resolver. Detached RGB continuations/donors remain UNKNOWN even
/// when their layer, spacing and source context agree. No detector upperBounds,
/// OCR result, identity, learned model, stored candidate or target is consulted.
@available(iOS 18.0, *)
enum NativeOCRSourcePaintCompleteness {
    static let generationModeEnvironmentKey = "AIDOKU_OCR_COMPLETENESS_GENERATION_MODE"

    /// One bounded, serial source-generation invocation only. The scheduler must
    /// pass this SAME instance to measure and measureSearch. Default OFF; no global
    /// cache or frame lifetime is inferred from a source/query identity.
    final class WorkCache {
        let enabled: Bool
        let sourceFirst: Bool
        private let capacity: Int
        private let byteLimit: Int
        private var originals: [NativeOCRSourceOwnedRailPartition.Original]?
        private struct Entry {
            let family: String
            let owner: Int
            let roi: NativeOCRSourcePaintGeometry.PixelROI
            let scope: [[Double]]
            let value: Any
            let bytes: Int
        }
        private var entries: [Entry] = []
        private(set) var buildsByFamily: [String: Int] = [:]
        private(set) var hitsByFamily: [String: Int] = [:]
        private(set) var retainedBytes = 0
        private(set) var peakRetainedBytes = 0
        private(set) var evidenceResets = 0

        init(environment: [String: String] = ProcessInfo.processInfo.environment,
             capacity: Int = 16, byteLimit: Int = 8 * 1024 * 1024) {
            let mode = environment[NativeOCRSourcePaintCompleteness.generationModeEnvironmentKey]
            sourceFirst = mode == "source-first-v2" || environment[NativeOCRSourcePaintGeometry.sourceFirstEnvironmentKey] == "1"
            enabled = sourceFirst || mode == "source-work-v2"
            self.capacity = max(0, capacity); self.byteLimit = max(0, byteLimit)
        }

        /// Strong equality on the actual read set, not RGB statistics, source
        /// ancestry, bbox similarity or a probabilistic pixel fingerprint. Empty
        /// physical searches are reusable too; query-local validity is NOT cached.
        fileprivate func reuse<T>(family: String, owner: Int,
                                  roi: NativeOCRSourcePaintGeometry.PixelROI,
                                  originals current: [NativeOCRSourceOwnedRailPartition.Original],
                                  scope: [[Double]] = [], bytes: Int, _ body: () -> T) -> T {
            guard enabled else { return body() }
            let sameBank = originals.map { previous in
                previous.count == current.count && zip(previous, current).allSatisfy {
                    $0.polygon == $1.polygon && $0.detectorSeedEvidence == $1.detectorSeedEvidence
                }
            } ?? false
            if !sameBank {
                if originals != nil { evidenceResets += 1 }
                entries.removeAll(keepingCapacity: true); retainedBytes = 0
                originals = current
            }
            if let index = entries.firstIndex(where: {
                $0.family == family && $0.owner == owner && $0.scope == scope &&
                $0.roi.originX == roi.originX && $0.roi.originY == roi.originY &&
                $0.roi.width == roi.width && $0.roi.height == roi.height && $0.roi.rgb == roi.rgb
            }), let result = entries[index].value as? T {
                hitsByFamily[family, default: 0] += 1
                return result
            }
            buildsByFamily[family, default: 0] += 1
            let result = body()
            let cost = max(0, bytes) + roi.rgb.count
            guard capacity > 0, cost <= byteLimit else { return result }
            while !entries.isEmpty && (entries.count >= capacity || retainedBytes + cost > byteLimit) {
                retainedBytes -= entries.removeFirst().bytes
            }
            entries.append(.init(family: family, owner: owner, roi: roi, scope: scope, value: result, bytes: cost))
            retainedBytes += cost; peakRetainedBytes = max(peakRetainedBytes, retainedBytes)
            return result
        }
    }

    private typealias Paint = NativeOCRSourcePaintGeometry
    private typealias Original = NativeOCRSourceOwnedRailPartition.Original
    private typealias Primitive = NativeOCRSourceContext50V2.Primitive
    private struct P { var x: Double; var y: Double }
    private struct B {
        var l: Double; var t: Double; var r: Double; var b: Double
        var width: Double { r-l }; var height: Double { b-t }
        var center: P { P(x: (l+r)/2, y: (t+b)/2) }
        func contains(_ p: P) -> Bool { p.x >= l && p.x <= r && p.y >= t && p.y <= b }
    }
    private struct Basis {
        var o: P; var a: P; var n: P
        init?(_ q: [[Double]]) {
            guard q.count == 4, q.allSatisfy({ $0.count == 2 && $0.allSatisfy(\.isFinite) }) else { return nil }
            var length = 0.0, axis = P(x: 0, y: 0)
            for i in 0..<4 {
                let j = (i+1)%4, x = q[j][0]-q[i][0], y = q[j][1]-q[i][1], v = hypot(x, y)
                if v > length { length = v; axis = P(x: x, y: y) }
            }
            guard length > 0 else { return nil }
            axis = P(x: axis.x/length, y: axis.y/length)
            if axis.y < 0 || (axis.y == 0 && axis.x < 0) { axis = P(x: -axis.x, y: -axis.y) }
            o = P(x: q.map { $0[0] }.reduce(0,+)/4, y: q.map { $0[1] }.reduce(0,+)/4)
            a = axis; n = P(x: axis.y, y: -axis.x)
        }
        func project(_ p: P) -> P { let x=p.x-o.x, y=p.y-o.y; return P(x: x*n.x+y*n.y, y: x*a.x+y*a.y) }
        func restore(_ p: P) -> P { P(x: o.x+p.x*n.x+p.y*a.x, y: o.y+p.x*n.y+p.y*a.y) }
        func bounds(_ points: [P]) -> B {
            var b = B(l: .infinity, t: .infinity, r: -.infinity, b: -.infinity)
            for p in points { let z=project(p); b.l=min(b.l,z.x); b.r=max(b.r,z.x); b.t=min(b.t,z.y); b.b=max(b.b,z.y) }
            return b
        }
        func quad(_ b: B) -> [[Double]] {
            [P(x:b.l,y:b.t),P(x:b.r,y:b.t),P(x:b.r,y:b.b),P(x:b.l,y:b.b)].map { let p=restore($0); return [p.x,p.y] }
        }
        func tilted(_ slope: Double) -> Basis {
            var result=self; let scale=sqrt(1+slope*slope)
            result.a=P(x:(a.x+slope*n.x)/scale,y:(a.y+slope*n.y)/scale)
            result.n=P(x:result.a.y,y:-result.a.x); return result
        }
    }
    private struct Component {
        var pixels: [Int]; var bounds: B; var center: P; var roots: Int
        var rim: Double
    }
    private struct Context {
        let roi: Paint.PixelROI; let originals: [Original]; let owner: Int
        let seed: NativeOCRDetectorSeedEvidence; let labels: [Int]; let uncertain: [Bool]
        let own: [Bool]; let foreign: [Bool]; let external: [Bool]; let sx: Double; let sy: Double
        let basis: Basis; let raw: B
        var count: Int { roi.width*roi.height }
        func point(_ index: Int) -> P {
            P(x:Double(roi.originX+index%roi.width)+0.5,y:Double(roi.originY+index/roi.width)+0.5)
        }
        func pixel(_ index: Int) -> [Double] {
            let p=roi.pixel(x:index%roi.width,y:index/roi.width); return [p.0,p.1,p.2]
        }
    }
    /// Every qualifying mechanism/layer is returned and must be counted by the
    /// caller. Unknown additions are observations, not promoted definite DB cells.
    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive],
                        generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil,
                        workCache: WorkCache? = nil)
        -> [NativeOCRSourcePaintGeometry.Measurement] {
        guard roi.width > 2, roi.height > 2, roi.width <= 1_000_000/roi.height,
              roi.originX >= 0, roi.originY >= 0, roi.rgb.count == roi.width*roi.height*3,
              originals.count <= 4096, let qb=Basis(query.polygon) else { return [] }
        guard let owner=resolvedOwner(query:query,originals:originals) else { return [] }
        if sourceFirstEnabled(workCache) {
            let canonical=Paint.Query(polygon:originals[owner].polygon,sourceIndex:query.sourceIndex,sourceMembers:[owner])
            // A promised longer source job must be the first physical completion;
            // defer before building masks or fitting a short-window variant.
            if requiredSourceBounds(query:canonical,originals:originals,rf:rf) != nil { return [] }
        }
        guard let context=sourceContext(roi:roi,originals:originals,owner:owner,workCache:workCache) else { return [] }
        if sourceFirstEnabled(workCache) {
            return sourceFirst(context,query:query,rf:rf,
                               generationLedger:generationLedger,workCache:workCache)
        }
        var output: [Paint.Measurement]=[]
        // A source-demonstrated head/peer rail does not require the HEAD to
        // contain definite DB cells. Its full joint membership remains UNKNOWN.
        if let v=outlinedRail(context, query: query, generationLedger: generationLedger, workCache: workCache) { output.append(v) }
        if context.seed.components.isEmpty || !context.own.contains(true) {
            return validMeasurements(output,roi:roi,query:query)
        }
        if let v=outlinedEndpoint(context,query:query,basis:qb,workCache:workCache) { output.append(v) }
        if let v=sourceOnlyVariant(context,query:query,family:"centroid-axis",generationLedger:generationLedger,workCache:workCache,{
            centroidAxis(context)
        }) { output.append(v) }
        if let v=contrastTail(context,query:query,rf:rf,generationLedger:generationLedger,workCache:workCache) { output.append(v) }
        if let v=sourceOnlyVariant(context,query:query,family:"bright-terminal",generationLedger:generationLedger,workCache:workCache,{
            brightTerminal(context)
        }) { output.append(v) }
        return validMeasurements(output,roi:roi,query:query)
    }

    /// Execute only the two mechanisms that request longer source windows.
    /// Incumbent-window measurements still run unchanged through measure().
    static func measureSearch(roi: NativeOCRSourcePaintGeometry.PixelROI, query: NativeOCRSourcePaintGeometry.Query,
                              originals: [NativeOCRSourceOwnedRailPartition.Original], rf: [NativeOCRSourceContext50V2.Primitive],
                        generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil,
                        workCache: WorkCache? = nil)
        -> [NativeOCRSourcePaintGeometry.Measurement] {
        guard roi.width > 2, roi.height > 2, roi.width <= 1_000_000/roi.height,
              roi.originX >= 0, roi.originY >= 0, roi.rgb.count == roi.width*roi.height*3,
              originals.count <= 4096, Basis(query.polygon) != nil,
              let owner=resolvedOwner(query:query,originals:originals),
              let context=sourceContext(roi:roi,originals:originals,owner:owner,workCache:workCache) else { return [] }
        if sourceFirstEnabled(workCache) {
            return sourceFirst(context,query:query,rf:rf,
                               generationLedger:generationLedger,workCache:workCache)
        }
        var output: [Paint.Measurement]=[]
        if let value=outlinedRail(context, query: query, generationLedger: generationLedger, workCache: workCache) { output.append(value) }
        if !context.seed.components.isEmpty && context.own.contains(true),
           let value=contrastTail(context,query:query,rf:rf,generationLedger:generationLedger,workCache:workCache) { output.append(value) }
        return validMeasurements(output,roi:roi,query:query)
    }

    private static func sourceFirstEnabled(_ cache: WorkCache?) -> Bool {
        Paint.sourceFirstGeneration || cache?.sourceFirst == true ||
            ProcessInfo.processInfo.environment[generationModeEnvironmentKey] == "source-first-v2"
    }

    /// Aggressive opt-in proposal creation, not late output suppression. The
    /// scheduler promises requiredSourceBounds() jobs after ordinary source jobs.
    /// Source members/unique exact original geometry still resolve the owner;
    /// sourceIndex and parent/context receipts never authorize a source search.
    /// Query-specific head angles/normal spans no longer create physical variants.
    private static func sourceFirst(_ c: Context, query: Paint.Query, rf: [Primitive],
                                    generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger?,
                                    workCache: WorkCache?) -> [Paint.Measurement] {
        let canonical = Paint.Query(polygon:c.originals[c.owner].polygon,
                                    sourceIndex:query.sourceIndex,sourceMembers:[c.owner])
        let selected = once(generationLedger,family:"completeness.source-first-v2.canonical",context:c,
                            query:canonical,querySensitive:false) {
            if let rail = outlinedRail(c,query:canonical,generationLedger:nil,workCache:workCache) { return rail }
            guard !c.seed.components.isEmpty, c.own.contains(true) else { return nil }
            if let tail = contrastTail(c,query:canonical,rf:rf,generationLedger:nil,workCache:workCache) { return tail }
            guard let basis = Basis(canonical.polygon) else { return nil }
            if let endpoint = outlinedEndpoint(c,query:canonical,basis:basis,workCache:workCache) { return endpoint }
            // No speculative body is created before a successful completion.
            // A single outer ledger entry covers the entire first-success chain,
            // so a duplicate complete offer cannot fall through to a NEW body.
            if let workCache, workCache.enabled {
                return workCache.reuse(family:"source-first-body",owner:c.owner,roi:c.roi,
                                       originals:c.originals,bytes:1024) { centroidAxis(c) ?? brightTerminal(c) }
            }
            return centroidAxis(c) ?? brightTerminal(c)
        }
        return validMeasurements(selected.map { [$0] } ?? [],roi:c.roi,query:canonical)
    }

    private static func sourceContext(roi: Paint.PixelROI, originals: [Original], owner: Int,
                                      workCache: WorkCache?) -> Context? {
        guard let workCache, workCache.enabled else {
            return makeContext(roi:roi,originals:originals,owner:owner,allowEmptyOwned:true)
        }
        return workCache.reuse(family:"context",owner:owner,roi:roi,originals:originals,
                               bytes:roi.width*roi.height*32) {
            makeContext(roi:roi,originals:originals,owner:owner,allowEmptyOwned:true)
        }
    }

    private static func sourceOnlyVariant(_ c: Context, query: Paint.Query, family: String,
                                          generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger?,
                                          workCache: WorkCache?, _ body: () -> Paint.Measurement?) -> Paint.Measurement? {
        guard let workCache, workCache.enabled else { return body() }
        return once(generationLedger,family:"completeness.source-work-v2."+family,context:c,
                    query:query,querySensitive:false) {
            workCache.reuse(family:family,owner:c.owner,roi:c.roi,originals:c.originals,bytes:1024,body)
        }
    }

    /// Both entrypoints normalize the producer's actual pixel window first.
    /// Rail output is owner-dependent; contrast output also reads the ordered
    /// query basis. Validate before committing, since sameQuad is query-local.
    private static func once(_ ledger: NativeOCRSourcePaintColumnPartition.GenerationLedger?, family: String,
                             context c: Context, query: Paint.Query, querySensitive: Bool,
                             _ body: () -> Paint.Measurement?) -> Paint.Measurement? {
        guard let ledger else { return body() }
        return ledger.run(family: family, owner: c.owner,
                          polygon: querySensitive ? query.polygon : c.originals[c.owner].polygon,
                          window: [c.roi.originX, c.roi.originY, c.roi.width, c.roi.height]) {
            guard let value = body() else { return [] }
            return validMeasurements([value], roi: c.roi, query: query)
        }.first
    }

    private static func validMeasurements(_ output: [Paint.Measurement], roi: Paint.PixelROI, query: Paint.Query) -> [Paint.Measurement] {
        output.filter { m in
            m.polygon.count == 4 && m.polygon.allSatisfy { p in
                p.count == 2 && p.allSatisfy(\.isFinite) && p[0] >= Double(roi.originX) &&
                p[0] <= Double(roi.originX+roi.width) && p[1] >= Double(roi.originY) && p[1] <= Double(roi.originY+roi.height)
            } && !sameQuad(m.polygon,query.polygon)
        }
    }

    private static func resolvedOwner(query: Paint.Query, originals: [Original]) -> Int? {
        let members=Array(Set(query.sourceMembers)).sorted()
        if members.count == 1, let owner=members.first, originals.indices.contains(owner) { return owner }
        guard members.isEmpty else { return nil }
        let exact=originals.indices.filter { sameQuad(originals[$0].polygon,query.polygon) }
        return exact.count == 1 ? exact[0]:nil
    }

    /// The wrapper must include this source-derived search window BEFORE
    /// measure(). A query-width margin cannot contain a fragmented long rail or
    /// a low-contrast tail whose true ink is outside the existing query crop.
    /// These are requested PIXELS, never an output polygon or a padding offer.
    static func requiredSourceBounds(query: NativeOCRSourcePaintGeometry.Query,
                                     originals: [NativeOCRSourceOwnedRailPartition.Original],
                                     rf: [NativeOCRSourceContext50V2.Primitive]) -> [[Double]]? {
        guard let owner=resolvedOwner(query:query,originals:originals),
              Basis(originals[owner].polygon) != nil else { return nil }
        let q=originals[owner].polygon,raw=worldBounds(q),w=raw.width,h=raw.height
        guard w>0,h>0 else { return nil };var needed: B?
        if let peer=railPeer(owner:owner,originals:originals) {
            needed=B(l:raw.l-0.25*w,t:raw.t-0.2*w,r:raw.r+0.25*w,b:peer.1.b+1.5*w)
        }
        let scope=rf.contains { r in
            r.canonicalClass == 1 && r.confidence.isFinite && r.confidence>=0.5 && Basis(r.polygon) != nil &&
                worldBounds(r.polygon).contains(P(x:raw.center.x,y:raw.b))
        }
        if w>=8 && h>=2*w && abs(q[0][1]-q[1][1])<=0.05*w && abs(q[0][0]-q[3][0])<=0.05*w && scope {
            let tail=B(l:raw.l-0.2*w,t:raw.t-0.2*w,r:raw.r+0.2*w,b:raw.b+min(3*w,0.75*h))
            if let prior=needed { needed=B(l:min(prior.l,tail.l),t:min(prior.t,tail.t),r:max(prior.r,tail.r),b:max(prior.b,tail.b)) }
            else { needed=tail }
        }
        guard let b=needed,b.width*b.height<=1_000_000 else { return nil }
        return [[b.l,b.t],[b.r,b.t],[b.r,b.b],[b.l,b.b]]
    }

    private static func railPeer(owner: Int, originals: [Original]) -> (Int,B)? {
        guard originals.indices.contains(owner),Basis(originals[owner].polygon) != nil else { return nil }
        let raw=worldBounds(originals[owner].polygon),w=raw.width,h=raw.height
        guard w>=8,h/w>=0.65,h/w<=2 else { return nil };var peers:[(Int,B)]=[]
        for i in originals.indices where i != owner {
            guard Basis(originals[i].polygon) != nil else { return nil };let b=worldBounds(originals[i].polygon)
            if b.width>=0.15*w && b.width<=0.65*w && b.t<raw.b && b.b>raw.b && abs(b.center.x-raw.center.x)<=0.2*w { peers.append((i,b)) }
        }
        return peers.count == 1 ? peers[0]:nil
    }

    /// Restrict supplied pixels to a source-derived mechanism window. A larger
    /// common ROI must not change morphology borders or join remote components.
    private static func searchContext(_ c: Context, bounds b: B) -> Context? {
        let x0=max(0,Int(floor(b.l))),y0=max(0,Int(floor(b.t)))
        let x1=min(c.seed.sourceWidth,Int(ceil(b.r))),y1=min(c.seed.sourceHeight,Int(ceil(b.b)))
        guard x1>x0,y1>y0,x0>=c.roi.originX,y0>=c.roi.originY,
              x1<=c.roi.originX+c.roi.width,y1<=c.roi.originY+c.roi.height else { return nil }
        if x0 == c.roi.originX && y0 == c.roi.originY && x1-x0 == c.roi.width && y1-y0 == c.roi.height { return c }
        var rgb:[UInt8]=[],labels:[Int]=[],uncertain:[Bool]=[],own:[Bool]=[],foreign:[Bool]=[],external:[Bool]=[]
        rgb.reserveCapacity((x1-x0)*(y1-y0)*3)
        for y in y0..<y1 { for x in x0..<x1 {
            let i=(y-c.roi.originY)*c.roi.width+x-c.roi.originX
            rgb += c.roi.rgb[(i*3)..<(i*3+3)];labels.append(c.labels[i]);uncertain.append(c.uncertain[i])
            own.append(c.own[i]);foreign.append(c.foreign[i]);external.append(c.external[i])
        }}
        let roi=Paint.PixelROI(width:x1-x0,height:y1-y0,originX:x0,originY:y0,rgb:rgb)
        return Context(roi:roi,originals:c.originals,owner:c.owner,seed:c.seed,labels:labels,uncertain:uncertain,
                       own:own,foreign:foreign,external:external,sx:c.sx,sy:c.sy,basis:c.basis,raw:c.raw)
    }

    private static func points(_ q: [[Double]]) -> [P] { q.map { P(x:$0[0],y:$0[1]) } }
    private static func sameQuad(_ a: [[Double]], _ b: [[Double]]) -> Bool {
        guard a.count == 4, b.count == 4, (a+b).allSatisfy({ $0.count == 2 }) else { return false }
        for reverse in [false,true] { for offset in 0..<4 {
            if (0..<4).allSatisfy({ i in let j=(offset+(reverse ? 4-i:i))%4; return a[i][0] == b[j][0] && a[i][1] == b[j][1] }) { return true }
        }}; return false
    }
    private static func median(_ x: [Double]) -> Double {
        guard !x.isEmpty else { return .nan }; let s=x.sorted(),m=s.count/2
        return s.count%2 == 1 ? s[m]:(s[m-1]+s[m])/2
    }
    private static func worldBounds(_ q: [[Double]]) -> B {
        B(l:q.map{$0[0]}.min()!,t:q.map{$0[1]}.min()!,r:q.map{$0[0]}.max()!,b:q.map{$0[1]}.max()!)
    }
    private static func inside(_ q: [[Double]], _ p: P) -> Bool {
        guard q.count == 4, q.allSatisfy({$0.count == 2}) else { return false }
        var positive=false,negative=false
        for i in 0..<4 { let j=(i+1)%4,z=(q[j][0]-q[i][0])*(p.y-q[i][1])-(q[j][1]-q[i][1])*(p.x-q[i][0]); positive = positive || z>1e-9; negative = negative || z < -1e-9 }
        return !(positive && negative)
    }
    private static func usable(_ s: NativeOCRDetectorSeedEvidence, reference: NativeOCRDetectorSeedEvidence) -> Bool {
        s.isValid && s.ownershipVersion == 2 && s.completeCCScan == true && s.sourceWidth == reference.sourceWidth &&
        s.sourceHeight == reference.sourceHeight && s.mapFullWidth == reference.mapFullWidth && s.mapFullHeight == reference.mapFullHeight
    }
    private static func makeContext(roi: Paint.PixelROI, originals: [Original], owner: Int, allowEmptyOwned: Bool = false) -> Context? {
        guard let seed=originals[owner].detectorSeedEvidence, seed.isValid, seed.ownershipVersion == 2,
              seed.completeCCScan == true, (allowEmptyOwned || !seed.components.isEmpty), let basis=Basis(originals[owner].polygon),
              roi.originX+roi.width <= seed.sourceWidth, roi.originY+roi.height <= seed.sourceHeight else { return nil }
        let count=roi.width*roi.height,sx=Double(seed.sourceWidth)/Double(seed.mapFullWidth),sy=Double(seed.sourceHeight)/Double(seed.mapFullHeight)
        var labels=Array(repeating:0,count:count),uncertain=Array(repeating:false,count:count),foreignUncertain=Array(repeating:false,count:count)
        func paint(_ c: NativeOCRDetectorSeedEvidence.Component, _ id: Int, _ ambiguous: Bool) {
            for r in c.runs {
                // Runs are FULL detector-grid coordinates. Never add mapOrigin.
                let x0=max(0,min(roi.width,Int(ceil(Double(r.x)*sx-0.5))-roi.originX))
                let x1=max(0,min(roi.width,Int(ceil(Double(r.x+r.count)*sx-0.5))-roi.originX))
                let y0=max(0,min(roi.height,Int(ceil(Double(r.y)*sy-0.5))-roi.originY))
                let y1=max(0,min(roi.height,Int(ceil(Double(r.y+1)*sy-0.5))-roi.originY))
                if x1>x0 && y1>y0 { for y in y0..<y1 { for x in x0..<x1 {
                    let i=y*roi.width+x
                    if ambiguous { uncertain[i]=true;if id != owner+1 { foreignUncertain[i]=true } } else { labels[i] = labels[i] == 0 || labels[i] == id ? id:-1 }
                }}}
            }
        }
        for (i,original) in originals.enumerated() {
            if let s=original.detectorSeedEvidence, usable(s,reference:seed) {
                for c in s.components { paint(c,i+1,false) }
                for c in (s.ambiguousComponents ?? [])+(s.candidateComponents ?? []).map(\.component) { paint(c,i+1,true) }
            } else if i != owner {
                guard Basis(original.polygon) != nil else { return nil }
                let b=worldBounds(original.polygon)
                let x0=max(0,min(roi.width,Int(floor(b.l))-roi.originX)),x1=max(0,min(roi.width,Int(ceil(b.r))-roi.originX+1))
                let y0=max(0,min(roi.height,Int(floor(b.t))-roi.originY)),y1=max(0,min(roi.height,Int(ceil(b.b))-roi.originY+1))
                if x1>x0 && y1>y0 { for y in y0..<y1 { for x in x0..<x1 {
                    if inside(original.polygon,P(x:Double(roi.originX+x)+0.5,y:Double(roi.originY+y)+0.5)) { uncertain[y*roi.width+x]=true;foreignUncertain[y*roi.width+x]=true }
                }}}
            }
        }
        let own=labels.indices.map { labels[$0] == owner+1 && !uncertain[$0] }
        guard allowEmptyOwned || own.contains(true) else { return nil }
        let foreign=labels.indices.map { (labels[$0] != 0 && labels[$0] != owner+1) || uncertain[$0] }
        let external=labels.indices.map { (labels[$0] != 0 && labels[$0] != owner+1) || foreignUncertain[$0] }
        return Context(roi:roi,originals:originals,owner:owner,seed:seed,labels:labels,uncertain:uncertain,
                       own:own,foreign:foreign,external:external,sx:sx,sy:sy,basis:basis,raw:basis.bounds(points(originals[owner].polygon)))
    }
    private static func components(_ mask: [Bool], _ w: Int, _ h: Int, diagonal: Bool = true) -> [[Int]] {
        var seen=Array(repeating:false,count:mask.count),result:[[Int]]=[]
        for start in mask.indices where mask[start] && !seen[start] {
            var queue=[start],front=0;seen[start]=true
            while front<queue.count { let i=queue[front];front+=1
                let x=i%w,y=i/w
                for dy in -1...1 {
                    let yy=y+dy;if yy<0 || yy>=h { continue }
                    for dx in -1...1 where dx != 0 || dy != 0 {
                        if !diagonal && dx != 0 && dy != 0 { continue }
                        let xx=x+dx;if xx<0 || xx>=w { continue }
                        let j=yy*w+xx
                        if mask[j] && !seen[j] { seen[j]=true;queue.append(j) }
                    }
                }
            }
            result.append(queue); if result.count>4096 { return [] }
        };return result
    }
    private static func clipped(_ pixels: [Int], _ c: Context, guardPixels: Int = 0) -> Bool {
        pixels.contains { i in i%c.roi.width<=guardPixels || i/c.roi.width<=guardPixels ||
            i%c.roi.width>=c.roi.width-1-guardPixels || i/c.roi.width>=c.roi.height-1-guardPixels }
    }
    private static func gray(_ c: Context) -> [Double] {
        (0..<c.count).map { i in let p=c.pixel(i);return 0.299*p[0]+0.587*p[1]+0.114*p[2] }
    }
    private static func otsu(_ x: [Double]) -> Double {
        var h=Array(repeating:0.0,count:256);for v in x { h[max(0,min(255,Int(v)))]+=1 }
        let total=Double(x.count),sum=(0..<256).reduce(0.0){$0+Double($1)*h[$1]}
        var mass=0.0,partial=0.0,best = -1.0,threshold=0.0
        for k in 0..<255 { mass+=h[k];partial+=Double(k)*h[k];if mass == 0 || mass == total { continue }
            let difference=partial/mass-(sum-partial)/(total-mass),score=mass*(total-mass)*difference*difference
            if score>best { best=score;threshold=Double(k) }
        };return threshold
    }
    private static func ring(_ pixels: [Int], _ c: Context, radius: Int) -> [Int] {
        let source=Set(pixels);var result=Set<Int>()
        for i in pixels { let x=i%c.roi.width,y=i/c.roi.width
            for yy in max(0,y-radius)...min(c.roi.height-1,y+radius) {
                for xx in max(0,x-radius)...min(c.roi.width-1,x+radius) { let j=yy*c.roi.width+xx;if !source.contains(j) { result.insert(j) } }
            }
        };return result.sorted()
    }
    private static func describe(_ pixels: [Int], _ c: Context, _ basis: Basis) -> Component {
        let pp=pixels.map(c.point),b=basis.bounds(pp)
        return Component(pixels:pixels,bounds:b,center:P(x:pp.map(\.x).reduce(0,+)/Double(pp.count),
                         y:pp.map(\.y).reduce(0,+)/Double(pp.count)),roots:pixels.filter{c.own[$0]}.count,
                         rim:0)
    }
    private static func measurement(_ q: [[Double]], _ mechanism: String, _ layer: String, _ c: Context,
                                    _ diagnostic: [String:Double]) -> Paint.Measurement {
        var d=diagnostic;d["anchorSourceIndex"]=Double(c.owner);d["detachedMembershipKnown"]=0
        d["usesDetectorProbability"]=0;d["usesRecognition"]=0
        return .init(polygon:q,layer:layer,mechanism:mechanism,diagnostics:d)
    }

    // MARK: Chromatic fill with measured enclosing collar; endpoints only
    private struct EndpointSupport {
        let cloud: [P]
        let roots: Int
        let components: Int
        let height: Double
        let collarFloor: Double
    }
    private static func outlinedEndpoint(_ c: Context, query: Paint.Query, basis: Basis,
                                         workCache: WorkCache?) -> Paint.Measurement? {
        let support: EndpointSupport?
        if let workCache, workCache.enabled {
            support = workCache.reuse(family:"endpoint-pixels",owner:c.owner,roi:c.roi,originals:c.originals,
                                      bytes:c.count*16) { endpointPixels(c) }
        } else { support = endpointPixels(c) }
        guard let support else { return nil }
        let qb=basis.bounds(points(query.polygon)),half=0.5*(abs(basis.a.x)+abs(basis.a.y))
        for p in points(query.polygon) { let q=basis.project(p)
            if min(abs(q.x-qb.l),abs(q.x-qb.r))>1e-7*max(1,qb.width,qb.height) { return nil }
        }
        let bounds=basis.bounds(support.cloud)
        let result=B(l:qb.l,t:min(qb.t,bounds.t-half),r:qb.r,b:max(qb.b,bounds.b+half))
        guard result.t<qb.t-1e-9 || result.b>qb.b+1e-9 else { return nil }
        return measurement(basis.quad(result),"owned-outlined-fill-endpoint-completion-v1","chromatic-fill-UNKNOWN-continuation",c,
                           ["rootedComponents":Double(support.roots),"components":Double(support.components),
                            "rootGlyphHeight":support.height,"measuredCollarFloor":support.collarFloor,"normalSidesPreserved":1])
    }
    private static func endpointPixels(_ c: Context) -> EndpointSupport? {
        let width=c.raw.width
        guard width>=3,c.raw.height>=2*width else { return nil }
        var colors:[[Double]]=[]
        for cp in c.seed.components { for r in cp.runs { for x in r.x..<(r.x+r.count) {
            let xx=Int((Double(x)+0.5)*c.sx)-c.roi.originX,yy=Int((Double(r.y)+0.5)*c.sy)-c.roi.originY
            if xx>=0 && xx<c.roi.width && yy>=0 && yy<c.roi.height {
                let p=c.pixel(yy*c.roi.width+xx),mean=p.reduce(0,+)/3
                if p.max()!-p.min()!>=24 && mean<128 { colors.append(p) }
            }
        }}}
        guard colors.count>=8 else { return nil }
        let prototype=(0..<3).map{j in median(colors.map{$0[j]})},mean=prototype.reduce(0,+)/3
        var directions:[[Double]]=[],strengths:[Double]=[]
        for p in colors { let m=p.reduce(0,+)/3,z=p.map{$0-m},norm=sqrt(z.map{$0*$0}.reduce(0,+))
            if norm>0 { directions.append(z.map{$0/norm});strengths.append(norm) }
        }
        var direction=(0..<3).map{j in median(directions.map{$0[j]})}
        let norm=sqrt(direction.map{$0*$0}.reduce(0,+));guard norm>0 else { return nil };direction=direction.map{$0/norm}
        let minimum=0.5*median(strengths);var mask=Array(repeating:false,count:c.count)
        for i in mask.indices {
            let p=c.pixel(i),m=p.reduce(0,+)/3,z=p.map{$0-m},strength=sqrt(z.map{$0*$0}.reduce(0,+)),q=c.basis.project(c.point(i))
            if strength>=minimum && m<=mean+64 && zip(z,direction).map(*).reduce(0,+)/max(strength,1e-9)>=0.90 &&
                q.x>=c.raw.l-0.45*width && q.x<=c.raw.r+0.45*width && q.y>=c.raw.t-2.5*width && q.y<=c.raw.b+2.5*width &&
                !c.external[i] { mask[i]=true }
        }
        var parts:[Component]=[]
        for pixels in components(mask,c.roi.width,c.roi.height) {
            if clipped(pixels,c) || pixels.count<3 { continue }
            var part=describe(pixels,c,c.basis)
            if part.bounds.width>1.4*width || part.bounds.height>1.7*width { continue }
            let rim=ring(pixels,c,radius:2)
            part.rim=rim.isEmpty ? 0:Double(rim.filter{c.pixel($0).min()!>=220}.count)/Double(rim.count)
            if part.roots == 0 && pixels.contains(where:{c.external[$0]}) { continue }
            parts.append(part)
        }
        guard parts.count<=512 else { return nil };let roots=parts.filter{$0.roots>0}
        let rootedRims=roots.map(\.rim);guard roots.count>=3,median(rootedRims)>=0.4 else { return nil }
        let floor=0.5*median(rootedRims),height=median(roots.map{$0.bounds.height+1})
        var selected=Set(parts.indices.filter{parts[$0].roots>0 && parts[$0].rim>=floor}),changed=true
        while changed {
            changed=false
            for i in parts.indices where !selected.contains(i) && parts[i].rim>=floor {
                let p=parts[i].bounds
                if abs(p.center.x)>0.35*width { continue }
                if selected.contains(where:{j in let q=parts[j].bounds
                    return max(p.t-q.b,q.t-p.b,0)<=height && min(p.r,q.r)>=max(p.l,q.l)
                }) { selected.insert(i);changed=true }
            }
        }
        guard !selected.isEmpty else { return nil }
        return .init(cloud:selected.flatMap{parts[$0].pixels}.map(c.point),roots:roots.count,
                     components:selected.count,height:height,collarFloor:floor)
    }

    // MARK: Bright terminal polarity layer, retained alongside mixed incumbent
    private static func brightTerminal(_ c: Context) -> Paint.Measurement? {
        let raw=worldBounds(c.originals[c.owner].polygon),w=raw.width,h=raw.height
        guard w>=4,h>=3*w else { return nil }
        let indices=(0..<c.count).filter{raw.contains(c.point($0))};guard !indices.isEmpty else { return nil }
        let values=indices.map{i in c.pixel(i).reduce(0,+)/3},threshold=otsu(values)
        let low=values.filter{$0<=threshold},high=values.filter{$0>threshold}
        guard !low.isEmpty,!high.isEmpty,median(low)<=170,median(high)>=220,
              median(high)-median(low)>=70,Double(high.count)/Double(indices.count)<=0.45 else { return nil }
        var mask=Array(repeating:false,count:c.count)
        for i in indices { if c.pixel(i).reduce(0,+)/3>threshold && !c.external[i] { mask[i]=true } }
        var parts:[Component]=[]
        for p in components(mask,c.roi.width,c.roi.height) {
            let v=describe(p,c,c.basis)
            if Double(p.count)>=0.005*w*w && v.bounds.width<=1.2*w && v.bounds.height<=1.5*w { parts.append(v) }
        }
        var chains:[[Component]]=[],ends:[Double]=[]
        for part in parts.sorted(by:{$0.bounds.t<$1.bounds.t}) {
            if let end=ends.last,part.bounds.t-end<=0.75*w { chains[chains.count-1].append(part);ends[ends.count-1]=max(end,part.bounds.b) }
            else { chains.append([part]);ends.append(part.bounds.b) }
        }
        let qualifies=chains.filter { chain in
            let b=c.basis.bounds(chain.flatMap(\.pixels).map(c.point))
            return chain.count>=3 && b.height>=2*w && b.height>=0.5*h && max(b.t-c.raw.t,c.raw.b-b.b)>=0.6*w
        }
        guard qualifies.count == 1 else { return nil };let pixels=qualifies[0].flatMap(\.pixels),p=pixels.map(c.point)
        let rows=Set(pixels.map{$0/c.roi.width}).sorted();var bands=1
        for i in 1..<rows.count where Double(rows[i]-rows[i-1])>0.08*w { bands+=1 }
        guard bands>=3 else { return nil }
        let world=B(l:p.map(\.x).min()!-0.5,t:p.map(\.y).min()!-0.5,r:p.map(\.x).max()!+0.5,b:p.map(\.y).max()!+0.5)
        var total=0,support=0
        for cp in c.seed.components { for run in cp.runs { for x in run.x..<(run.x+run.count) {
            total+=1;if world.contains(P(x:(Double(x)+0.5)*c.sx,y:(Double(run.y)+0.5)*c.sy)) { support+=1 }
        }}}
        guard support>0,Double(support)>=0.25*Double(total) else { return nil }
        let q=[[world.l,world.t],[world.r,world.t],[world.r,world.b],[world.l,world.b]]
        return measurement(q,"source-polarity-layer/bright-terminal-chain-v1","bright-terminal-UNKNOWN-stroke-chain",c,
                           ["otsu":threshold,"rowBands":Double(bands),"components":Double(qualifies[0].count),"supportedCells":Double(support)])
    }

    // MARK: Component-centroid axis with a finite, measured pale rim
    private static func distance1D(_ f: [Double]) -> [Double] {
        let n=f.count;guard n>1 else { return f };var v=Array(repeating:0,count:n),z=Array(repeating:0.0,count:n+1)
        var k=0;z[0] = -.infinity;z[1] = .infinity
        for q in 1..<n {
            var s=((f[q]+Double(q*q))-(f[v[k]]+Double(v[k]*v[k])))/Double(2*(q-v[k]))
            while k>0 && s<=z[k] { k-=1;s=((f[q]+Double(q*q))-(f[v[k]]+Double(v[k]*v[k])))/Double(2*(q-v[k])) }
            k+=1;v[k]=q;z[k]=s;z[k+1] = .infinity
        }
        var result=Array(repeating:0.0,count:n);k=0
        for q in 0..<n { while z[k+1]<Double(q) { k+=1 };let d=q-v[k];result[q]=Double(d*d)+f[v[k]] }
        return result
    }
    private static func distance(_ mask: [Bool], _ w: Int, _ h: Int) -> [Double] {
        guard mask.contains(false) else { return Array(repeating:.infinity,count:mask.count) }
        var temp=Array(repeating:0.0,count:mask.count),result=temp
        for x in 0..<w {
            let line=distance1D((0..<h).map{mask[$0*w+x] ? 1e12:0})
            for y in 0..<h { temp[y*w+x]=line[y] }
        }
        for y in 0..<h { let line=distance1D(Array(temp[y*w..<(y+1)*w]));for x in 0..<w { result[y*w+x]=sqrt(line[x]) } }
        return result
    }
    private static func centroidAxis(_ c: Context) -> Paint.Measurement? {
        let width=c.raw.width,length=c.raw.height
        guard width>=4,length>=3*width else { return nil }
        let values=gray(c),threshold=otsu(values);var mask=values.map{$0<=threshold}
        for i in mask.indices where c.external[i] { mask[i]=false }
        var selected:[Component]=[]
        for pixels in components(mask,c.roi.width,c.roi.height) {
            if pixels.count<3 { continue };let part=describe(pixels,c,c.basis),center=c.basis.project(part.center)
            if abs(center.x)>0.55*width || abs(center.y)>0.6*length { continue }
            var nearest=c.owner,best=Double.infinity
            for j in c.originals.indices {
                guard let basis=Basis(c.originals[j].polygon) else { return nil }
                let b=basis.bounds(points(c.originals[j].polygon)),p=basis.project(part.center)
                let d=hypot(p.x,max(0,abs(p.y)-0.6*b.height))
                if d<best { best=d;nearest=j }
            }
            if nearest != c.owner { continue };if clipped(pixels,c) { return nil };selected.append(part)
        }
        guard selected.count>=6,selected.count<=256 else { return nil }
        let centers=selected.map{c.basis.project($0.center)},ts=centers.map(\.y)
        guard ts.max()!-ts.min()!>=0.65*length else { return nil };var slopes:[Double]=[]
        for i in centers.indices { for j in centers.indices where j>i && abs(centers[j].y-centers[i].y)>0.25*length {
            slopes.append((centers[j].x-centers[i].x)/(centers[j].y-centers[i].y))
        }}
        guard !slopes.isEmpty else { return nil };let slope=median(slopes);guard abs(slope)<=0.25 else { return nil }
        let fitted=c.basis.tilted(slope),pixels=selected.flatMap(\.pixels),selectedSet=Set(pixels)
        let substrate=(0..<c.count).map{i -> Bool in let p=c.pixel(i)
            return (p.min()!>225 && p.max()!-p.min()!<20) || values[i]<225
        }
        let distances=distance(substrate,c.roi.width,c.roi.height),edge=ring(pixels,c,radius:1).filter{!selectedSet.contains($0)}
        guard !edge.isEmpty else { return nil };let radius=median(edge.map{distances[$0]})+1
        guard radius.isFinite,radius>=1.5,radius<=0.15*width else { return nil }
        let b=fitted.bounds(pixels.map(c.point)),hn=radius+0.5*(abs(fitted.n.x)+abs(fitted.n.y))
        let ha=radius+0.5*(abs(fitted.a.x)+abs(fitted.a.y))
        let envelope=B(l:b.l-hn,t:b.t-ha,r:b.r+hn,b:b.b+ha)
        return measurement(fitted.quad(envelope),"source-owned-ink-centroid-axis-measured-halo-v1","ink-centroid-axis-measured-pale-rim",c,
                           ["components":Double(selected.count),"otsu":threshold,"axisSlope":slope,"measuredRimRadius":radius,
                            "alongCoverage":(ts.max()!-ts.min()!)/length])
    }

    // MARK: Pixel rail continuation below a source-demonstrated short head
    private static func outlinedRail(_ c: Context, query: Paint.Query,
                                     generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger?,
                                     workCache: WorkCache?) -> Paint.Measurement? {
        let raw=worldBounds(c.originals[c.owner].polygon),w=raw.width,h=raw.height
        guard w>=8,h/w>=0.65,h/w<=2 else { return nil }
        guard let peer=railPeer(owner:c.owner,originals:c.originals) else { return nil }
        let required=B(l:raw.l-0.25*w,t:raw.t-0.2*w,r:raw.r+0.25*w,b:peer.1.b+1.5*w)
        guard let search=searchContext(c,bounds:required) else { return nil }
        if search.roi.originX != c.roi.originX || search.roi.originY != c.roi.originY ||
            search.roi.width != c.roi.width || search.roi.height != c.roi.height { return outlinedRail(search, query: query, generationLedger: generationLedger, workCache:workCache) }
        return once(generationLedger, family: "completeness.outlined-rail", context: c,
                    query: query, querySensitive: false) {
            if let workCache, workCache.enabled {
                return workCache.reuse(family:"rail-pixels",owner:c.owner,roi:c.roi,originals:c.originals,bytes:1024) {
                    outlinedRailPixels(c,raw:raw,peer:peer,required:required)
                }
            }
            return outlinedRailPixels(c, raw: raw, peer: peer, required: required)
        }
    }

    private static func outlinedRailPixels(_ c: Context, raw: B, peer: (Int,B), required: B) -> Paint.Measurement? {
        let w = raw.width
        let values=gray(c),mask=values.indices.map{values[$0]<100 && required.contains(c.point($0))}
        var head:[Component]=[],rails:[Component]=[]
        for p in components(mask,c.roi.width,c.roi.height,diagonal:false) {
            if p.count<4 || clipped(p,c) { continue }
            let part=describe(p,c,c.basis),pp=p.map(c.point)
            let b=B(l:pp.map(\.x).min()!-0.5,t:pp.map(\.y).min()!-0.5,r:pp.map(\.x).max()!+0.5,b:pp.map(\.y).max()!+0.5)
            if b.l>=raw.l-0.1*w && b.r<=raw.r+0.1*w && b.t>=raw.t-0.1*w && b.b<=raw.b+0.1*w { head.append(part) }
            if b.width<=0.25*w && b.height>=0.6*w && b.height/b.width>=5 && abs(b.center.x-raw.center.x)<=0.2*w && b.t>=raw.b-0.3*w {
                var part=part;part.bounds=b;rails.append(part)
            }
        }
        guard !head.isEmpty else { return nil };var end=raw.b,chain:[Component]=[]
        for part in rails.sorted(by:{$0.bounds.t<$1.bounds.t}) {
            if part.bounds.t-end>0.3*w { break }
            if part.bounds.b>end { chain.append(part);end=part.bounds.b }
        }
        guard chain.count>=2,end>peer.1.b+0.25*w else { return nil }
        var rimSamples:[Double]=[]
        for rail in chain {
            let rows=Dictionary(grouping:rail.pixels,by:{$0/c.roi.width});var sample:[Double]=[]
            for (y,pixels) in rows {
                let worldY=Double(c.roi.originY+y)
                if worldY<rail.bounds.t+0.25*rail.bounds.height || worldY>=rail.bounds.b-0.25*rail.bounds.height { continue }
                let xs=pixels.map{$0%c.roi.width};var sides:[Int]=[]
                for (x,sign) in [(xs.min()!,-1),(xs.max()!,1)] {
                    var count=0
                    for step in 1...max(1,Int(ceil(0.2*w))) {
                        let xx=x+sign*step;if xx<0 || xx>=c.roi.width { break }
                        if values[y*c.roi.width+xx]>=245 { count+=1 } else if step>2 { break }
                    };sides.append(count)
                }
                if sides.min()!>=2 { sample+=sides.map(Double.init) }
            }
            guard !sample.isEmpty else { return nil };rimSamples+=sample
        }
        let rim=median(rimSamples),p=(head+chain).flatMap(\.pixels).map(c.point)
        let b=B(l:p.map(\.x).min()!-0.5-rim,t:p.map(\.y).min()!-0.5-rim,
                r:p.map(\.x).max()!+0.5+rim,b:p.map(\.y).max()!+0.5+rim)
        return measurement([[b.l,b.t],[b.r,b.t],[b.r,b.b],[b.l,b.b]],"pixel-outlined-collinear-rail-continuation-v1",
                           "joint-head-UNKNOWN-outlined-rail",c,["pairedSourceIndex":Double(peer.0),"railComponents":Double(chain.count),
                           "measuredRimPixels":rim,"rimSamples":Double(rimSamples.count),
                           "headDefiniteComponents":Double(c.seed.components.count),"jointLayerMembershipKnown":0])
    }

    // MARK: Low-contrast endpoint, scoped by one actual RF text rectangle
    /// Elliptical max/min morphology. Horizontal deque windows for each ellipse
    /// row keep work O(ROI pixels * ellipse height), not a kernel-area scan.
    private static func horizontal(_ input: [Double], width: Int, height: Int, radius: Int, maximum: Bool) -> [Double] {
        var out=Array(repeating:0.0,count:input.count)
        for y in 0..<height {
            var deque=Array(repeating:0,count:width),front=0,tail=0,next=0
            for x in 0..<width {
                while next<=min(width-1,x+radius) {
                    let value=input[y*width+next]
                    while tail>front && (maximum ? input[y*width+deque[tail-1]]<=value:input[y*width+deque[tail-1]]>=value) { tail-=1 }
                    deque[tail]=next;tail+=1;next+=1
                }
                while tail>front && deque[front]<x-radius { front+=1 }
                out[y*width+x]=input[y*width+deque[front]]
            }
        };return out
    }
    private static func ellipse(_ input: [Double], width: Int, height: Int, rx: Int, ry: Int, maximum: Bool) -> [Double] {
        var out=Array(repeating:maximum ? -Double.infinity:Double.infinity,count:input.count),cache:[Int:[Double]]=[:]
        for dy in -ry...ry {
            let radius=ry == 0 ? rx:Int((Double(rx)*sqrt(max(0,1-Double(dy*dy)/Double(ry*ry)))).rounded(.toNearestOrEven))
            if cache[radius] == nil { cache[radius]=horizontal(input,width:width,height:height,radius:radius,maximum:maximum) }
            let row=cache[radius]!
            for y in 0..<height {
                let yy=y+dy;if yy<0 || yy>=height { continue }
                for x in 0..<width { let i=y*width+x,v=row[yy*width+x];out[i]=maximum ? max(out[i],v):min(out[i],v) }
            }
        };return out
    }
    private static func contrastTail(_ c: Context, query: Paint.Query, rf: [Primitive],
                                     generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger?,
                                     workCache: WorkCache?) -> Paint.Measurement? {
        let q=c.originals[c.owner].polygon,b=worldBounds(q),w=b.width,h=b.height
        guard w>=8,h>=2*w,abs(q[0][1]-q[1][1])<=0.05*w,abs(q[0][0]-q[3][0])<=0.05*w else { return nil }
        let scopes=rf.filter{$0.canonicalClass == 1 && $0.confidence.isFinite && $0.confidence>=0.5 && Basis($0.polygon) != nil}
            .map{worldBounds($0.polygon)}.filter{$0.contains(P(x:b.center.x,y:b.b))}
        guard !scopes.isEmpty else { return nil }
        let reach=min(3*w,0.75*h)
        let required=B(l:b.l-0.2*w,t:b.t-0.2*w,r:b.r+0.2*w,b:b.b+reach)
        guard let search=searchContext(c,bounds:required) else { return nil }
        if search.roi.originX != c.roi.originX || search.roi.originY != c.roi.originY ||
            search.roi.width != c.roi.width || search.roi.height != c.roi.height { return contrastTail(search,query:query,rf:rf,generationLedger:generationLedger,workCache:workCache) }
        return once(generationLedger, family: "completeness.contrast-tail", context: c,
                    query: query, querySensitive: true) {
            let support: ContrastSupport?
            if let workCache, workCache.enabled {
                support=workCache.reuse(family:"contrast-pixels",owner:c.owner,roi:c.roi,originals:c.originals,
                    scope:scopes.map{[$0.l,$0.t,$0.r,$0.b]},bytes:1024) {
                    contrastTailPixels(c,b:b,scopes:scopes,reach:reach)
                }
            } else { support=contrastTailPixels(c,b:b,scopes:scopes,reach:reach) }
            guard let support, let basis=Basis(query.polygon) else { return nil }
            let prior=basis.bounds(points(query.polygon)),terminal=basis.bounds([P(x:b.l,y:support.end),P(x:b.r,y:support.end)])
            guard terminal.b>prior.b else { return nil }
            let result=B(l:prior.l,t:prior.t,r:prior.r,b:terminal.b)
            return measurement(basis.quad(result),"db-owned-rf-scoped-local-contrast-terminal-chain-v1","UNKNOWN-local-contrast-tail",c,
                ["rootComponents":Double(support.roots),"newComponents":Double(support.added),
                 "sharedRFScopes":Double(support.scopes),"reach":reach,"normalSidesPreserved":1])
        }
    }

    private struct ContrastSupport {
        let end: Double
        let roots: Int
        let added: Int
        let scopes: Int
    }
    private static func contrastTailPixels(_ c: Context, b: B, scopes: [B], reach: Double) -> ContrastSupport? {
        let w = b.width
        let values=gray(c).map{$0.rounded(.toNearestOrEven)},rx=max(1,Int(1.2*w)/2),ry=max(1,Int(0.5*w)/2)
        let dilated=ellipse(values,width:c.roi.width,height:c.roi.height,rx:rx,ry:ry,maximum:true)
        let closed=ellipse(dilated,width:c.roi.width,height:c.roi.height,rx:rx,ry:ry,maximum:false)
        var mask=Array(repeating:false,count:c.count)
        for i in mask.indices {
            let p=c.point(i)
            if p.x>=b.l-0.2*w && p.x<=b.r+0.2*w && p.y>=b.t-0.2*w && p.y<=b.b+reach &&
                closed[i]-values[i]>=12 && !c.external[i] { mask[i]=true }
        }
        var parts:[Component]=[]
        for p in components(mask,c.roi.width,c.roi.height) {
            if clipped(p,c) || Double(p.count)<max(4,0.001*w*w) { continue }
            var part=describe(p,c,c.basis);let pp=p.map(c.point)
            part.bounds=B(l:pp.map(\.x).min()!-0.5,t:pp.map(\.y).min()!-0.5,r:pp.map(\.x).max()!+0.5,b:pp.map(\.y).max()!+0.5)
            let pb=part.bounds
            if pb.width>1.25*w || pb.height>1.5*w || abs(part.center.x-b.center.x)>0.4*w || min(pb.r,b.r)-max(pb.l,b.l)<0.6*pb.width { continue }
            parts.append(part)
        }
        let roots=parts.filter{$0.roots>=2 && $0.bounds.b>=b.b-w && $0.bounds.b<=b.b && $0.bounds.t>=b.t}
        guard !roots.isEmpty else { return nil }
        var active=scopes.filter{s in roots.contains{ s.contains($0.center) }},end=roots.map{$0.bounds.b}.max()!,added=0
        guard !active.isEmpty else { return nil }
        for part in parts.sorted(by:{$0.bounds.t<$1.bounds.t}) {
            let p=part.bounds
            if p.b<=b.b || p.b<=end || p.t-end>0.65*w { continue }
            let supported=active.filter{$0.contains(part.center) && p.b<=$0.b+0.5*w}
            if supported.isEmpty { continue }
            var blocked=false
            for j in c.originals.indices where j != c.owner {
                guard Basis(c.originals[j].polygon) != nil else { return nil };let peer=worldBounds(c.originals[j].polygon)
                if min(b.r,peer.r)-max(b.l,peer.l)>0.25*min(w,peer.width) && min(p.b,peer.b)>max(b.b,peer.t) { blocked=true }
            }
            if blocked { break };active=supported;end=p.b;added+=1
        }
        guard added>0 else { return nil }
        return .init(end:end,roots:roots.count,added:added,scopes:active.count)
    }
}
