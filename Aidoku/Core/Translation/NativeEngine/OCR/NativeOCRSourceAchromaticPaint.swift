import Foundation

/// Additive source-paint observations, never replacement or recognition gates.
/// DB cells authenticate contact only: they are not ink masks. Detached pixels,
/// including finite rim endpoints, have UNKNOWN membership even when aligned.
/// Legacy returns every supported layer. Opt-in source-first v2 chooses physical
/// enclosing layers OR one canonical body before alternative producers execute.
@available(iOS 18.0, *)
enum NativeOCRSourceAchromaticPaint {
    static let recoveryV3EnvironmentKey = "AIDOKU_OCR_GENERATION_RECOVERY_V3"
    static var recoveryV3Enabled: Bool {
        ProcessInfo.processInfo.environment[recoveryV3EnvironmentKey] == "1"
    }
    private typealias ROI = NativeOCRSourcePaintGeometry.PixelROI
    private typealias Q = NativeOCRSourcePaintGeometry.Query
    private typealias M = NativeOCRSourcePaintGeometry.Measurement
    private static func shouldGenerate(_ mechanism: String) -> Bool {
        NativeOCRSourcePaintGeometry.shouldGenerate(mechanism)
    }
    private struct RGB {
        let r: Double, g: Double, b: Double
        var low: Double { min(r, min(g,b)) }
        var high: Double { max(r, max(g,b)) }
        var gray: Double { (r+g+b)/3 }
        var chroma: Double { high-low }
        func distance(_ c: RGB) -> Double { max(abs(r-c.r),max(abs(g-c.g),abs(b-c.b))) }
    }
    private struct Box {
        var l: Int, t: Int, r: Int, b: Int
        var width: Int { r-l }; var height: Int { b-t }
    }
    private struct CC { let points: [Int]; let box: Box }
    private struct Ray { let end: Int; let side: Int; let line: Int; let depth: Int }
    private static let steps = [(-1,0),(1,0),(0,-1),(0,1)]
    private static func color(_ roi: ROI, _ x: Int, _ y: Int) -> RGB {
        let c=roi.pixel(x:x,y:y); return RGB(r:c.0,g:c.1,b:c.2)
    }
    private static func valid(_ q: [[Double]]) -> Bool {
        q.count==4 && q.allSatisfy { $0.count==2 && $0.allSatisfy(\.isFinite) }
    }
    /// Exact scalar equality; cyclic order and winding do not change a quad.
    /// No tolerance, coordinate rounding or bbox overlap participates here.
    private static func sameQuad(_ a:[[Double]],_ b:[[Double]]) -> Bool {
        guard valid(a),valid(b) else { return false }
        for reverse in [false,true] { for offset in 0..<4 {
            if (0..<4).allSatisfy({ i in
                let j=(offset+(reverse ? 4-i:i))%4
                return a[i][0]==b[j][0] && a[i][1]==b[j][1]
            }) { return true }
        } }
        return false
    }
    private static func inside(_ x: Double, _ y: Double, _ q: [[Double]]) -> Bool {
        var positive=false, negative=false
        for i in 0..<q.count {
            let a=q[i], b=q[(i+1)%q.count]
            let v=(b[0]-a[0])*(y-a[1])-(b[1]-a[1])*(x-a[0])
            positive = positive || v>0; negative = negative || v<0
        }
        return !(positive && negative)
    }
    private static func median(_ v: [Double]) -> Double {
        guard !v.isEmpty else { return 0 }; let a=v.sorted(), k=a.count/2
        return a.count%2==0 ? (a[k-1]+a[k])/2 : a[k]
    }
    private static func quantile(_ v: [Double], _ fraction: Double) -> Double {
        guard !v.isEmpty else { return 0 }; let a=v.sorted()
        let f=Double(a.count-1)*fraction, i=Int(f), j=min(i+1,a.count-1)
        return a[i]+(a[j]-a[i])*(f-Double(i))
    }
    private static func parts(_ mask: [Bool], _ w: Int, _ h: Int, eight: Bool = true) -> [CC] {
        var seen=[Bool](repeating:false,count:mask.count), result=[CC]()
        for start in mask.indices where mask[start] && !seen[start] {
            var queue=[start], head=0
            seen[start]=true
            var box=Box(l:start%w,t:start/w,r:start%w+1,b:start/w+1)
            while head<queue.count {
                let p=queue[head]; head+=1; let x=p%w,y=p/w
                box.l=min(box.l,x); box.r=max(box.r,x+1); box.t=min(box.t,y); box.b=max(box.b,y+1)
                for dy in -1...1 { for dx in -1...1 {
                    if dx==0 && dy==0 { continue }
                    if !eight && abs(dx)+abs(dy) != 1 { continue }
                    let xx=x+dx, yy=y+dy
                    if xx>=0 && yy>=0 && xx<w && yy<h {
                        let j=yy*w+xx
                        if mask[j] && !seen[j] { seen[j]=true; queue.append(j) }
                    }
                } }
            }
            result.append(CC(points:queue,box:box))
        }
        return result
    }
    private static func bounds(_ points: [Int], _ w: Int) -> Box? {
        guard let p=points.first else { return nil }
        var b=Box(l:p%w,t:p/w,r:p%w+1,b:p/w+1)
        for p in points { b.l=min(b.l,p%w); b.r=max(b.r,p%w+1); b.t=min(b.t,p/w); b.b=max(b.b,p/w+1) }
        return b
    }
    private static func quad(_ b: Box, _ roi: ROI, margin: Double = 0) -> [[Double]] {
        let l=Double(b.l+roi.originX)-margin, r=Double(b.r+roi.originX)+margin
        let t=Double(b.t+roi.originY)-margin, d=Double(b.b+roi.originY)+margin
        return [[l,t],[r,t],[r,d],[l,d]]
    }
    private static func enclosed(_ b: Box, _ roi: ROI) -> Bool {
        b.l>0 && b.t>0 && b.r<roi.width && b.b<roi.height
    }

    static func measure(roi: NativeOCRSourcePaintGeometry.PixelROI,
                        query: NativeOCRSourcePaintGeometry.Query,
                        originals: [NativeOCRSourceOwnedRailPartition.Original],
                        rf: [NativeOCRSourceContext50V2.Primitive],
                        generationLedger: NativeOCRSourcePaintColumnPartition.GenerationLedger? = nil,
                        sourceBudgetV2: Bool? = nil)
        -> [NativeOCRSourcePaintGeometry.Measurement] {
        let recovery = recoveryV3Enabled
        let canonical = recovery || NativeOCRSourcePaintGeometry.sourceFirstGeneration
            || (sourceBudgetV2 ?? generationLedger?.sourceBudgetV2Enabled
                ?? NativeOCRSourcePaintColumnPartition.sourceBudgetV2Enabled)
        if let ledger = generationLedger {
            // The immutable invocation owns the pixel/original/RF banks. Keep
            // ordered vertices and explicit membership: neither bbox overlap
            // nor a sourceIndex authenticates identical physical work.
            let members = Array(Set(query.sourceMembers)).sorted()
            let mode = recovery ? ".recovery-v3" : canonical ? ".source-first-v2" : ""
            return ledger.run(family: "achromatic.query\(mode)/\(members)", polygon: query.polygon,
                              window: [roi.originX, roi.originY, roi.width, roi.height]) {
                measure(roi: roi, query: query, originals: originals, rf: rf, sourceBudgetV2: canonical)
            }
        }
        guard roi.width>2,roi.height>2,roi.width<=1_500_000/roi.height,
              roi.rgb.count==roi.width*roi.height*3,valid(query.polygon) else { return [] }
        let xs=query.polygon.map{$0[0]}, ys=query.polygon.map{$0[1]}
        let l=xs.min()!,r=xs.max()!,t=ys.min()!,b=ys.max()!
        let vertical=b-t>=r-l, short=min(r-l,b-t), long=max(r-l,b-t)
        guard short>=4,long>=2*short else { return [] }
        // Do not flatten visibly rotated source geometry into an axis rectangle.
        for i in 0..<4 {
            let a=query.polygon[i], z=query.polygon[(i+1)%4]
            let dx=abs(z[0]-a[0]),dy=abs(z[1]-a[1])
            if max(dx,dy)>short*1.5 && min(dx,dy)>0.15*max(dx,dy) { return [] }
        }
        if canonical {
            if recovery, let recovered = completeSourceNormal(roi: roi, query: query,
                originals: originals, short: short, long: long, vertical: vertical) {
                return [recovered]
            }
            return canonicalSourceLayers(roi: roi, query: query, short: short, long: long, vertical: vertical)
        }
        let w=roi.width,h=roi.height,n=w*h
        let local=query.polygon.map{[$0[0]-Double(roi.originX),$0[1]-Double(roi.originY)]}
        // This mask is geometric query association ONLY, never DB membership.
        var associatedQuerySupport=[Bool](repeating:false,count:n)
        for y in 0..<h { for x in 0..<w { associatedQuerySupport[y*w+x]=inside(Double(x)+0.5,Double(y)+0.5,local) } }
        // Pixel-only dark-fill is independent of DB ancestry. An unknown query
        // may produce this physical observation, but it certifies no membership
        // and does not clear or rewrite any DB barrier or seed packet.
        var output=[M]()
        output += associatedPixelLayers(roi:roi,query:query,short:short,long:long,vertical:vertical)
        output += fragmentDarkRail(roi:roi,query:query,originals:originals)
        guard ["source-owned-dark-stroke-normal-envelope-v1", "source-bright-achromatic-layer-db-association-v1",
               "source-achromatic-core-finite-rim-envelope-v1"].contains(where: { shouldGenerate($0) }) else { return output }
        // ONLY explicit actual original-array membership, or a UNIQUE exact
        // raw quad, authenticates DB membership. sourceIndex is never resolved
        // as an original index; overlap, proximity and rounding do not qualify.
        var members=Set(query.sourceMembers)
        if !members.allSatisfy({originals.indices.contains($0)}) { return output }
        if members.isEmpty {
            let exact=originals.indices.filter { sameQuad(originals[$0].polygon,query.polygon) }
            if exact.count==1 { members.insert(exact[0]) }
        }
        guard !members.isEmpty else { return output }
        var authenticatedOwn=[Bool](repeating:false,count:n)
        var foreignKnown=authenticatedOwn,unresolved=authenticatedOwn,runBudget=0
        var ownedRunCenters=[[Double]]()
        for (i,o) in originals.enumerated() {
            guard let s=o.detectorSeedEvidence,s.isValid,s.completeCCScan==true,
                  s.mapFullWidth>0,s.mapFullHeight>0 else {
                if members.contains(i) { return output }
                // Missing peer evidence remains a conservative polygon barrier.
                if valid(o.polygon) {
                    let p=o.polygon.map{[$0[0]-Double(roi.originX),$0[1]-Double(roi.originY)]}
                    for y in 0..<h { for x in 0..<w where inside(Double(x)+0.5,Double(y)+0.5,p) { unresolved[y*w+x]=true } }
                }
                continue
            }
            if members.contains(i) && s.components.isEmpty { return output }
            guard s.sourceWidth>=roi.originX+roi.width,s.sourceHeight>=roi.originY+roi.height else { return output }
            let sx=Double(s.sourceWidth)/Double(s.mapFullWidth), sy=Double(s.sourceHeight)/Double(s.mapFullHeight)
            func paint(_ cc: NativeOCRDetectorSeedEvidence.Component, _ definite: Bool) {
                for run in cc.runs {
                    runBudget+=1
                    if runBudget>250_000 { return }
                    if definite && members.contains(i) {
                        ownedRunCenters.append([(Double(run.x)+Double(run.count)/2)*sx,(Double(run.y)+0.5)*sy])
                    }
                    // Native RLE already uses full-grid coordinates; NO origin addition.
                    let xa=max(0,min(w,Int(ceil(Double(run.x)*sx-0.5))-roi.originX))
                    let xb=max(0,min(w,Int(ceil(Double(run.x+run.count)*sx-0.5))-roi.originX))
                    let ya=max(0,min(h,Int(ceil(Double(run.y)*sy-0.5))-roi.originY))
                    let yb=max(0,min(h,Int(ceil(Double(run.y+1)*sy-0.5))-roi.originY))
                    if xb>xa && yb>ya { for y in ya..<yb { for x in xa..<xb {
                        if definite && members.contains(i) { authenticatedOwn[y*w+x]=true }
                        else if definite { foreignKnown[y*w+x]=true }
                        else { unresolved[y*w+x]=true }
                    } } }
                }
            }
            for cc in s.components { paint(cc,true) }
            for cc in s.ambiguousComponents ?? [] { paint(cc,false) }
            for cc in s.candidateComponents ?? [] { paint(cc.component,false) }
        }
        guard runBudget<=250_000 else { return output }
        // No geometric association can erase either kind of barrier. A raw
        // member's ambiguous/candidate cells remain unresolved even for itself.
        let foreign=(0..<n).map { foreignKnown[$0] || unresolved[$0] }
        for i in 0..<n where foreign[i] { authenticatedOwn[i]=false }
        guard authenticatedOwn.contains(true) else { return output }
        var colors=[RGB](); colors.reserveCapacity(n)
        var rimR=[Double](),rimG=[Double](),rimB=[Double]()
        for y in 0..<h { for x in 0..<w {
            let c=color(roi,x,y);colors.append(c)
            if x==0 || y==0 || x==w-1 || y==h-1 { rimR.append(c.r);rimG.append(c.g);rimB.append(c.b) }
        } }
        let background=RGB(r:median(rimR),g:median(rimG),b:median(rimB))
        let peak=quantile(colors.map{$0.low},0.99)
        let brightThreshold=background.chroma>=20 && peak-background.gray>=60 ? (peak+background.gray)/2 : 200
        var rowBackground=[Double](repeating:0,count:vertical ? h:w)
        // Two actual exterior side bands, with no resampling or invented colors.
        for line in rowBackground.indices {
            var samples=[Double]()
            if vertical {
                for x in 0..<w where Double(x+roi.originX)<l || Double(x+roi.originX)>=r { samples.append(colors[line*w+x].gray) }
            } else {
                for y in 0..<h where Double(y+roi.originY)<t || Double(y+roi.originY)>=b { samples.append(colors[y*w+line].gray) }
            }
            rowBackground[line]=samples.isEmpty ? background.gray : median(samples)
        }
        for bright in [true,false] {
            var mask=[Bool](repeating:false,count:n)
            for i in 0..<n {
                let c=colors[i]
                let bg=rowBackground[vertical ? i/w:i%w]
                mask[i] = bright ? c.low>brightThreshold && c.chroma<40 : c.high<128 && c.chroma<48 && bg-c.gray>max(16,bg*0.1)
            }
            let cc=parts(mask,w,h,eight:!bright)
            var selected=[CC](), detached=[CC]()
            for c in cc {
                let cb=c.box
                guard c.points.count>=max(4,Int(short*short*0.001)),enclosed(cb,roi),
                      Double(vertical ? cb.width:cb.height)<=1.5*short,
                      Double(vertical ? cb.height:cb.width)<=2*short else { continue }
                if c.points.contains(where:{foreign[$0]}) { continue }
                let crossCenter=Double(vertical ? cb.l+cb.r:cb.t+cb.b)/2
                let queryCenter=vertical ? (l+r)/2-Double(roi.originX):(t+b)/2-Double(roi.originY)
                guard abs(crossCenter-queryCenter)<=0.6*short else { continue }
                if c.points.contains(where:{authenticatedOwn[$0]}) { selected.append(c) }
                else { detached.append(c) }
            }
            guard selected.count>=2 else { continue }
            var all=selected.flatMap(\.points), chosen=[Bool](repeating:false,count:n)
            for i in all { chosen[i]=true }
            var perimeter=0
            for i in all { let x=i%w,y=i/w
                for (dx,dy) in steps { let xx=x+dx,yy=y+dy
                    if xx<0 || yy<0 || xx>=w || yy>=h || !chosen[yy*w+xx] { perimeter+=1 }
                }
            }
            let stroke=2*Double(all.count)/Double(max(1,perimeter))
            // One hop only, from the frozen authenticated core set. Unknown
            // punctuation is explicitly reported and never becomes DB ownership.
            let roots=selected
            var unknown=0
            for c in detached {
                let matches=roots.contains { root in
                    let a=root.box,z=c.box
                    let cross=vertical ? min(a.r,z.r)-max(a.l,z.l):min(a.b,z.b)-max(a.t,z.t)
                    let gap=vertical ? max(a.t-z.b,max(z.t-a.b,0)):max(a.l-z.r,max(z.l-a.r,0))
                    return cross>0 && Double(gap)<=2*stroke
                }
                if matches { selected.append(c);all += c.points;unknown+=c.points.count;for i in c.points { chosen[i]=true } }
            }
            guard let core=bounds(all,w) else { continue }
            let alongSpan=Double(vertical ? core.height:core.width)
            guard alongSpan>=0.55*long,alongSpan<=1.35*long else { continue }
            let base:[String:Double] = ["corePixels":Double(all.count),"coreComponents":Double(selected.count),
                "definiteRootComponents":Double(roots.count),"authenticatedMemberCount":Double(members.count),
                "queryAssociatedPixels":Double(associatedQuerySupport.filter{$0}.count),
                "foreignKnownPixels":Double(foreignKnown.filter{$0}.count),"unresolvedPixels":Double(unresolved.filter{$0}.count),"unknownDetachedPixels":Double(unknown),
                "detachedMembershipUnknown":1,"strokeWidth":stroke,"recognitionUsed":0,"rfMaskUsed":0,
                "upperBoundsUsed":0,"incumbentPreserved":1,"backgroundChroma":background.chroma]
            if !bright,roots.count>=3,let normal=darkNormalEnvelope(roi:roi,query:query,pixels:all,
                runCenters:ownedRunCenters,short:short) { output.append(normal) }
            // Only chromatic substrates justify the separate measured-stroke
            // uncertainty envelope. This is not a detector ownership claim.
            if shouldGenerate("source-bright-achromatic-layer-db-association-v1") && bright && background.chroma>=20 && peak-background.gray>=60 &&
                Double(core.l)>stroke && Double(core.t)>stroke && Double(w-core.r)>stroke && Double(h-core.b)>stroke {
                var d=base;d["uncertaintyMargin"]=stroke
                output.append(M(polygon:quad(core,roi,margin:stroke),layer:"bright-core-stroke-uncertainty",
                    mechanism:"source-bright-achromatic-layer-db-association-v1",diagnostics:d))
            }
            guard shouldGenerate("source-achromatic-core-finite-rim-envelope-v1") else { continue }
            let rays=finiteRays(colors:colors,chosen:chosen,own:authenticatedOwn,foreign:foreign,w:w,h:h,short:short,bright:bright)
            let rayCells=Set(rays.map { [$0.side,$0.line,$0.side<2 ? $0.end%w:$0.end/w] })
            let coherent=rays.filter { ray in
                let normal=ray.side<2 ? ray.end%w:ray.end/w
                for delta in -3...3 where delta != 0 {
                    for dn in -1...1 where rayCells.contains([ray.side,ray.line+delta,normal+dn]) { return true }
                }
                return false
            }
            let sides=(0..<4).map { side in coherent.filter{$0.side==side}.count }
            if sides.allSatisfy({$0>=3}),let outer=bounds(all+coherent.map(\.end),w),enclosed(outer,roi) {
                var d=base;d["finiteRays"]=Double(coherent.count)
                d["medianRimDepth"]=median(coherent.map{Double($0.depth)})
                for side in 0..<4 { d["side\(side)Rays"]=Double(sides[side]) }
                output.append(M(polygon:quad(outer,roi),layer:bright ? "bright-core-finite-enclosing-rim":"dark-core-finite-bright-rim",
                    mechanism:"source-achromatic-core-finite-rim-envelope-v1",diagnostics:d))
            }
        }
        // RF bounds are contextual only; no rectangle is passed off as a mask.
        for i in output.indices { output[i] = M(polygon:output[i].polygon,layer:output[i].layer,
            mechanism:output[i].mechanism,diagnostics:output[i].diagnostics.merging(["rfPrimitiveCount":Double(rf.count)]){a,_ in a}) }
        return output
    }

    /// A single conditional normal-support measurement, not an alternate-query
    /// generator. Explicit complete seed cells select contact roots only. Every
    /// selected source component is kept whole; adjacency may attach ONE actual
    /// opposite-contrast rim, never a dilation or inferred ownership union.
    /// Normal completeness requires observed exterior on BOTH sides of EVERY
    /// occupied source scanline. Along extent is a separate, uncertified axis.
    private static func completeSourceNormal(roi: ROI, query: Q,
        originals: [NativeOCRSourceOwnedRailPartition.Original], short: Double,
        long: Double, vertical: Bool) -> M? {
        guard shouldGenerate("source-achromatic-observed-normal-recovery-v3") else { return nil }
        let w=roi.width,h=roi.height,n=w*h
        var members=Set(query.sourceMembers)
        guard members.allSatisfy({originals.indices.contains($0)}) else { return nil }
        if members.isEmpty {
            let exact=originals.indices.filter{sameQuad(originals[$0].polygon,query.polygon)}
            guard exact.count==1 else { return nil };members.insert(exact[0])
        }
        var own=[Bool](repeating:false,count:n),runCount=0
        for id in members.sorted() {
            guard let s=originals[id].detectorSeedEvidence,s.isValid,s.completeCCScan==true,
                  s.mapFullWidth>0,s.mapFullHeight>0,!s.components.isEmpty,
                  s.sourceWidth>=roi.originX+w,s.sourceHeight>=roi.originY+h else { return nil }
            let sx=Double(s.sourceWidth)/Double(s.mapFullWidth),sy=Double(s.sourceHeight)/Double(s.mapFullHeight)
            for cc in s.components { for run in cc.runs {
                runCount+=1;guard runCount<=250_000 else { return nil }
                let xa=max(0,min(w,Int(ceil(Double(run.x)*sx-0.5))-roi.originX))
                let xb=max(0,min(w,Int(ceil(Double(run.x+run.count)*sx-0.5))-roi.originX))
                let ya=max(0,min(h,Int(ceil(Double(run.y)*sy-0.5))-roi.originY))
                let yb=max(0,min(h,Int(ceil(Double(run.y+1)*sy-0.5))-roi.originY))
                if xb>xa && yb>ya { for y in ya..<yb { for x in xa..<xb { own[y*w+x]=true } } }
            } }
            // Ambiguous source cells cannot authenticate root contact.
            for cc in (s.ambiguousComponents ?? []) + (s.candidateComponents ?? []).map(\.component) {
                for run in cc.runs {
                    runCount+=1;guard runCount<=250_000 else { return nil }
                    let xa=max(0,min(w,Int(ceil(Double(run.x)*sx-0.5))-roi.originX))
                    let xb=max(0,min(w,Int(ceil(Double(run.x+run.count)*sx-0.5))-roi.originX))
                    let ya=max(0,min(h,Int(ceil(Double(run.y)*sy-0.5))-roi.originY))
                    let yb=max(0,min(h,Int(ceil(Double(run.y+1)*sy-0.5))-roi.originY))
                    if xb>xa && yb>ya { for y in ya..<yb { for x in xa..<xb { own[y*w+x]=false } } }
                }
            }
        }
        guard own.contains(true) else { return nil }
        let q=query.polygon.map{[$0[0]-Double(roi.originX),$0[1]-Double(roi.originY)]}
        let lo=q.map{vertical ? $0[0]:$0[1]}.min()!,hi=q.map{vertical ? $0[0]:$0[1]}.max()!
        let lines=vertical ? h:w,cross=vertical ? w:h
        var colors=[RGB]();colors.reserveCapacity(n)
        for y in 0..<h { for x in 0..<w { colors.append(color(roi,x,y)) } }
        func cell(_ line: Int,_ normal: Int) -> Int { vertical ? line*w+normal:normal*w+line }
        var background=[RGB]();background.reserveCapacity(lines)
        for line in 0..<lines {
            let left=(0..<cross).filter{Double($0)+0.5<lo}
            let right=(0..<cross).filter{Double($0)+0.5>hi}
            guard left.count>=2,right.count>=2 else { return nil }
            // Two independent measured exterior bands, not detector fill colors.
            let a=left.map{colors[cell(line,$0)]},b=right.map{colors[cell(line,$0)]}
            let ac=RGB(r:median(a.map(\.r)),g:median(a.map(\.g)),b:median(a.map(\.b)))
            let bc=RGB(r:median(b.map(\.r)),g:median(b.map(\.g)),b:median(b.map(\.b)))
            guard ac.distance(bc)<=32 else { return nil }
            background.append(RGB(r:(ac.r+bc.r)/2,g:(ac.g+bc.g)/2,b:(ac.b+bc.b)/2))
        }
        var dark=0.0,light=0.0
        for i in 0..<n where own[i] {
            let delta=colors[i].gray-background[vertical ? i/w:i%w].gray
            if colors[i].chroma<48 { dark+=max(0,-delta);light+=max(0,delta) }
        }
        guard max(dark,light)>0 else { return nil }
        let bright=light>dark
        func contrasted(_ i: Int,_ positive: Bool) -> Bool {
            let c=colors[i],bg=background[vertical ? i/w:i%w]
            let delta=positive ? c.gray-bg.gray:bg.gray-c.gray
            return c.chroma<48 && delta>max(12,0.10*(positive ? 255-bg.gray:bg.gray))
        }
        let mask=(0..<n).map{contrasted($0,bright)}
        let components=parts(mask,w,h)
        func eligible(_ c: CC) -> Bool {
            enclosed(c.box,roi) && c.points.count>=4 &&
                Double(vertical ? c.box.width:c.box.height)<=1.8*short &&
                Double(vertical ? c.box.height:c.box.width)<=1.35*long
        }
        let roots=components.filter{eligible($0) && $0.points.contains(where:{own[$0]})}
        guard !roots.isEmpty else { return nil }
        var selected=[Bool](repeating:false,count:n)
        for c in roots { for p in c.points { selected[p]=true } }
        // Complete opposite-contrast CCs touching frozen roots are real rims.
        // Detached rings/other glyph layers cannot enter through transitivity.
        let frozen=selected
        let opposite=(0..<n).map{contrasted($0,!bright)}
        var rimCount=0
        for c in parts(opposite,w,h) where eligible(c) {
            let touches=c.points.contains { p in
                let x=p%w,y=p/w
                return steps.contains { dx,dy in
                    let xx=x+dx,yy=y+dy
                    return xx>=0 && yy>=0 && xx<w && yy<h && frozen[yy*w+xx]
                }
            }
            if touches { for p in c.points { selected[p]=true };rimCount+=1 }
        }
        let support=(0..<n).filter{selected[$0]}
        guard !(0..<n).contains(where:{own[$0] && mask[$0] && !selected[$0]}) else { return nil }
        guard let body=bounds(support,w),Double(vertical ? body.height:body.width)>=0.55*long else { return nil }
        var occupied=0,closed=0
        for line in 0..<lines {
            let hits=(0..<cross).filter{selected[cell(line,$0)]}
            if hits.isEmpty && (0..<cross).contains(where:{own[cell(line,$0)]}) { return nil }
            guard let a=hits.first,let b=hits.last else { continue };occupied+=1
            guard a>=2,b+2<cross else { continue }
            let bg=background[line]
            if [a-2,a-1,b+1,b+2].allSatisfy({colors[cell(line,$0)].distance(bg)<=24}) { closed+=1 }
        }
        guard occupied>0,closed==occupied else { return nil }
        // Source extrema complete NORMAL support; preserve original along
        // localization independently. Do not label along as completeSourceInk.
        var envelope=body
        if vertical {
            envelope.t=min(envelope.t,max(0,Int(floor(q.map{$0[1]}.min()!))))
            envelope.b=max(envelope.b,min(h,Int(ceil(q.map{$0[1]}.max()!))))
        } else {
            envelope.l=min(envelope.l,max(0,Int(floor(q.map{$0[0]}.min()!))))
            envelope.r=max(envelope.r,min(w,Int(ceil(q.map{$0[0]}.max()!))))
        }
        return M(polygon:quad(envelope,roi),layer:"UNKNOWN-observed-complete-normal",
            mechanism:"source-achromatic-observed-normal-recovery-v3",diagnostics:[
                "recoveryV3":1,"completeNormalInk":1,"completeAlongInk":0,"alongLocalizationPreserved":1,
                "closedNormalLines":Double(closed),"occupiedNormalLines":Double(occupied),
                "completeSourceCCPixels":Double(support.count),"rootComponents":Double(roots.count),
                "observedOppositeRimComponents":Double(rimCount),"authenticatedRootContact":1,
                "authenticatedDBMembership":0,"detachedMembershipUnknown":1,"sourcePixelOnly":1,
                "geometryPadding":0,"thresholdHypotheses":1,"normalSourcePolarityBright":bright ? 1:0])
    }

    /// Experimental source-first producer: one measured body OR complete physical
    /// enclosing layers. Arbitration happens before DB rasterization, fragment
    /// fitting, adaptive-polarity passes, uncertainty padding and finite rays.
    /// It intentionally does not replay those alternatives when a fit fails.
    /// The query associates pixels; it authenticates neither ownership nor text.
    private static func canonicalSourceLayers(roi: ROI, query: Q, short: Double,
                                              long: Double, vertical: Bool) -> [M] {
        let w=roi.width,h=roi.height,n=w*h
        var colors=[RGB]();colors.reserveCapacity(n)
        var border=[Double]()
        for y in 0..<h { for x in 0..<w {
            let c=color(roi,x,y);colors.append(c)
            if x==0 || y==0 || x==w-1 || y==h-1 { border.append(c.gray) }
        } }
        // These paths flood the actual component complement or measure an
        // actual dark rim. Preserve both when present: distinct physical layers
        // are not duplicates merely because their rectangles overlap.
        let outer=associatedPixelLayers(roi:roi,query:query,short:short,long:long,
                                        vertical:vertical,sourceColors:colors)
        if !outer.isEmpty { return outer }
        guard shouldGenerate("source-achromatic-canonical-body-v2") else { return [] }
        let background=median(border)
        // ONE polarity and ONE threshold from live exterior contrast. There is
        // no angle/threshold sweep, quantile envelope or uncertainty-padding row.
        let bright=background<128
        let threshold=max(16,0.12*(bright ? 255-background:background))
        let mask=colors.map { c in
            c.chroma<48 && (bright ? c.gray-background:background-c.gray)>threshold
        }
        let local=query.polygon.map{[$0[0]-Double(roi.originX),$0[1]-Double(roi.originY)]}
        let center=vertical ? local.map{$0[0]}.reduce(0,+)/4:local.map{$0[1]}.reduce(0,+)/4
        var support=[Int](),count=0
        for c in parts(mask,w,h) {
            let z=c.box
            guard enclosed(z,roi),c.points.count>=max(4,Int(0.001*short*short)),
                  Double(vertical ? z.width:z.height)<=1.5*short,
                  Double(vertical ? z.height:z.width)<=2*short,
                  abs(Double(vertical ? z.l+z.r:z.t+z.b)/2-center)<=0.6*short,
                  c.points.contains(where:{inside(Double($0%w)+0.5,Double($0/w)+0.5,local)}) else { continue }
            // Include the WHOLE observed CC, including endpoints outside the
            // query. Never turn query clipping into a measured outer boundary.
            support += c.points;count+=1
        }
        guard count>=2,let body=bounds(support,w),
              Double(vertical ? body.height:body.width)>=0.55*long,
              Double(vertical ? body.height:body.width)<=1.35*long else { return [] }
        return [M(polygon:quad(body,roi),layer:bright ? "UNKNOWN-canonical-bright-body":"UNKNOWN-canonical-dark-body",
                  mechanism:"source-achromatic-canonical-body-v2",diagnostics:[
                    "sourceFirstCanonicalV2":1,"sourcePixelOnly":1,"queryAssociationOnly":1,
                    "authenticatedDBMembership":0,"detachedMembershipUnknown":1,"geometryPadding":0,
                    "completeComponentPixels":Double(support.count),"completeComponents":Double(count),
                    "sourcePolarityBright":bright ? 1:0,"sourceContrastThreshold":threshold,
                    "legacyAuthenticatedPassAvoided":1,"legacyFragmentPassAvoided":1])]
    }

    /// Independent physical query observations. No DB packet is promoted,
    /// merged, reassigned or cleared here. All detached membership is UNKNOWN.
    /// Near-black enclosing paint may be ONE connected component for an entire
    /// column: a glyph-height cap would incorrectly discard that literal layer.
    private static func associatedPixelLayers(roi:ROI,query:Q,short:Double,long:Double,vertical:Bool,
                                               sourceColors:[RGB]? = nil) -> [M] {
        let haloEnabled = shouldGenerate("source-near-black-enclosed-light-halo-envelope-v2")
        let rimEnabled = shouldGenerate("source-query-associated-white-fill-black-rim-envelope-v2")
        guard haloEnabled || rimEnabled, long>=3*short else { return [] }
        let w=roi.width,h=roi.height,n=w*h,q=query.polygon
        let l=q.map{$0[0]}.min()!-Double(roi.originX),r=q.map{$0[0]}.max()!-Double(roi.originX)
        let t=q.map{$0[1]}.min()!-Double(roi.originY),b=q.map{$0[1]}.max()!-Double(roi.originY)
        let crossCenter=vertical ? (l+r)/2:(t+b)/2
        var colors=sourceColors ?? [];colors.reserveCapacity(n)
        if sourceColors == nil {
            for y in 0..<h { for x in 0..<w { colors.append(color(roi,x,y)) } }
        }
        let diagnostics:[String:Double]=["authenticatedDBMembership":0,"detachedMembershipUnknown":1,
            "queryAssociationOnly":1,"incumbentPreserved":1,"geometryPadding":0,"sourcePixelOnly":1]
        var result=[M]()
        if haloEnabled {
            let nearBlack=colors.map{$0.high<=15 && $0.chroma<=40}
            var haloPoints=[Int](),holeLight=0,haloCount=0
            for c in parts(nearBlack,w,h) {
                let z=c.box,normal=vertical ? z.width:z.height
                guard enclosed(z,roi),Double(normal)<=1.8*short else { continue }
                let center=Double(vertical ? z.l+z.r:z.t+z.b)/2
                let alongLo=Double(vertical ? z.t:z.l),alongHi=Double(vertical ? z.b:z.r)
                guard abs(center-crossCenter)<=0.5*short,
                      min(alongHi,vertical ? b:r)>max(alongLo,vertical ? t:l) else { continue }
                // Four-connected exterior flood is the actual topology of the
                // complement, NOT a convex hull or bounding-box fill.
                let ww=z.width+2,hh=z.height+2
                if ww>1_500_000/hh { continue }
                var filled=[UInt8](repeating:0,count:ww*hh)
                for i in c.points { filled[(i/w-z.t+1)*ww+i%w-z.l+1]=1 }
                var queue=[0],head=0;filled[0]=2
                while head<queue.count {
                    let p=queue[head];head+=1;let x=p%ww,y=p/ww
                    for (dx,dy) in steps { let xx=x+dx,yy=y+dy
                        if xx>=0 && yy>=0 && xx<ww && yy<hh && filled[yy*ww+xx]==0 {
                            filled[yy*ww+xx]=2;queue.append(yy*ww+xx)
                        }
                    }
                }
                var light=0
                for yy in 0..<z.height { for xx in 0..<z.width where filled[(yy+1)*ww+xx+1] != 2 {
                    let c=colors[(yy+z.t)*w+xx+z.l]
                    if c.low>=220 && c.chroma<=40 { light+=1 }
                } }
                guard Double(light)>=max(4,0.005*short*short) else { continue }
                haloPoints += c.points;haloCount+=1;holeLight+=light
            }
            if haloCount>=1,let z=bounds(haloPoints,w),Double(vertical ? z.height:z.width)>=0.8*long {
                var d=diagnostics;d["enclosedBrightPixels"]=Double(holeLight);d["nearBlackComponents"]=Double(haloCount)
                d["nearBlackPixels"]=Double(haloPoints.count)
                result.append(M(polygon:quad(z,roi),layer:"near-black-enclosed-bright-halo",
                    mechanism:"source-near-black-enclosed-light-halo-envelope-v2",diagnostics:d))
            }
        }
        guard rimEnabled else { return result }
        // Bright cores use live query association, not authenticated ownership.
        // This path must run for corrected queries with UNKNOWN raw ancestry.
        let bright=colors.map{$0.low>195 && $0.chroma<40}
        var cores=[CC]()
        for c in parts(bright,w,h) {
            let z=c.box
            guard enclosed(z,roi),c.points.count>=max(4,Int(0.001*short*short)),
                  Double(max(z.width,z.height))<=1.5*short else { continue }
            let center=Double(vertical ? z.l+z.r:z.t+z.b)/2
            let a=Double(vertical ? z.t:z.l),bb=Double(vertical ? z.b:z.r)
            if abs(center-crossCenter)<=0.4*short && a>=(vertical ? t:l)-short*0.5 && bb<=(vertical ? b:r)+short*0.5 { cores.append(c) }
        }
        guard cores.count>=3 else { return result }
        let lane=median(cores.map{Double(vertical ? $0.box.l+$0.box.r:$0.box.t+$0.box.b)/2})
        cores=cores.filter{abs(Double(vertical ? $0.box.l+$0.box.r:$0.box.t+$0.box.b)/2-lane)<=0.3*short}
        guard cores.count>=3 else { return result }
        var fill=[Bool](repeating:false,count:n)
        for c in cores { for p in c.points { fill[p]=true } }
        let corePoints=cores.flatMap(\.points)
        guard let cb=bounds(corePoints,w),Double(vertical ? cb.height:cb.width)>=0.65*long else { return result }
        let glyph=median(cores.map{Double(max($0.box.width,$0.box.height))})
        let distance=squaredDistance(fill,w:w,h:h)
        var ringCount=0,ringDark=0
        for i in 0..<n where distance[i]>=4 && distance[i]<=16 {
            ringCount+=1;if colors[i].high<65 { ringDark+=1 }
        }
        let ringFraction=Double(ringDark)/Double(max(1,ringCount))
        guard ringFraction>=0.65 else { return result }
        // A scale limit controls association, never creates padded pixels.
        // Every added point is an ACTUAL measured dark cell near a bright core.
        let radius=0.30*glyph
        var support=corePoints
        for i in 0..<n where !fill[i] && distance[i]<=radius*radius && colors[i].high<65 { support.append(i) }
        if let z=bounds(support,w),enclosed(z,roi) {
            var d=diagnostics;d["coreComponents"]=Double(cores.count);d["corePixels"]=Double(corePoints.count)
            d["observedDarkRimPixels"]=Double(support.count-corePoints.count);d["ringDarkFraction"]=ringFraction
            d["rimAssociationRadius"]=radius;d["glyphScale"]=glyph
            result.append(M(polygon:quad(z,roi),layer:"UNKNOWN-bright-core-observed-dark-rim",
                mechanism:"source-query-associated-white-fill-black-rim-envelope-v2",diagnostics:d))
        }
        return result
    }

    /// Exact squared Euclidean distance to measured core cells, separable lower
    /// envelope of parabolas (linear time). This is pixel distance, not RF data.
    private static func squaredDistance(_ core:[Bool],w:Int,h:Int) -> [Double] {
        let infinity=1e15
        func transform(_ f:[Double]) -> [Double] {
            let n=f.count;var v=[Int](repeating:0,count:n),z=[Double](repeating:0,count:n+1)
            var k=0;z[0] = -.infinity;z[1] = .infinity
            if n>1 { for q in 1..<n {
                var s=0.0
                while true {
                    let p=v[k]
                    s=((f[q]+Double(q*q))-(f[p]+Double(p*p)))/Double(2*(q-p))
                    if s>z[k] || k==0 { break };k-=1
                }
                k+=1;v[k]=q;z[k]=s;z[k+1] = .infinity
            } }
            k=0;var d=[Double](repeating:0,count:n)
            for q in 0..<n { while z[k+1]<Double(q) { k+=1 };let a=q-v[k];d[q]=Double(a*a)+f[v[k]] }
            return d
        }
        var tmp=[Double](repeating:0,count:w*h),out=tmp
        for y in 0..<h {
            let d=transform((0..<w).map{core[y*w+$0] ? 0:infinity})
            for x in 0..<w { tmp[y*w+x]=d[x] }
        }
        for x in 0..<w {
            let d=transform((0..<h).map{tmp[$0*w+x]})
            for y in 0..<h { out[y*w+x]=d[y] }
        }
        return out
    }

    /// Explicit fragment provenance supplies INPUT SCOPE only. No inferred raw
    /// parent or overlap-based member is invented. Observed dark continuation
    /// remains UNKNOWN even when all root fragments are explicit originals.
    private static func fragmentDarkRail(roi:ROI,query:Q,originals:[NativeOCRSourceOwnedRailPartition.Original]) -> [M] {
        guard shouldGenerate("source-fragment-dark-layer-pixel-rail-v2") else { return [] }
        let ids=Array(Set(query.sourceMembers))
        guard ids.count>=2,ids.count<=16,ids.allSatisfy({originals.indices.contains($0)}) else { return [] }
        let groups=ids.map{originals[$0].polygon}
        guard groups.allSatisfy({valid($0)}) else { return [] }
        let eligible=groups.filter { q in
            q.map{$0[1]}.max()!-q.map{$0[1]}.min()! >= 1.5*(q.map{$0[0]}.max()!-q.map{$0[0]}.min()!)
        }
        guard let root=eligible.min(by:{$0.map{$0[1]}.min()!<$1.map{$0[1]}.min()!}) else { return [] }
        let left=root.map{$0[0]}.min()!,right=root.map{$0[0]}.max()!,width=right-left,center=(left+right)/2
        let top=root.map{$0[1]}.min()!,bottom=root.map{$0[1]}.max()!
        guard width>=8 else { return [] }
        let points=groups.flatMap{$0},l=points.map{$0[0]}.min()!,r=points.map{$0[0]}.max()!
        let t=points.map{$0[1]}.min()!,b=points.map{$0[1]}.max()!
        guard b-t<=20*width,r-l<=2*width else { return [] }
        let x0=max(roi.originX,Int(floor(l-0.25*width))),x1=min(roi.originX+roi.width,Int(ceil(r+0.25*width)))
        let y0=max(roi.originY,Int(floor(t-0.15*width))),y1=min(roi.originY+roi.height,Int(ceil(b+0.15*width)))
        let w=x1-x0,h=y1-y0
        guard w>2,h>2,w<=1_500_000/h else { return [] }
        var colors=[RGB](),background=[Double]();colors.reserveCapacity(w*h)
        for y in 0..<h {
            var bins=[Int:[Double]]()
            for x in 0..<w { let c=color(roi,x+x0-roi.originX,y+y0-roi.originY);colors.append(c)
                let k=Int(c.r)/32*64+Int(c.g)/32*8+Int(c.b)/32;bins[k,default:[]].append(c.gray)
            }
            let key=bins.keys.sorted().max(by:{bins[$0]!.count==bins[$1]!.count ? $0>$1:bins[$0]!.count<bins[$1]!.count})!
            background.append(median(bins[key]!))
        }
        let mask=colors.indices.map{colors[$0].gray<background[$0/w]-max(12,0.18*background[$0/w])}
        let candidates=parts(mask,w,h).filter { c in
            let z=c.box
            return c.points.count>=max(4,Int(0.002*width*width)) &&
                Double(z.l+x0)>=center-width*0.5 && Double(z.r+x0)<=center+width*0.5 &&
                Double(z.height)<=1.6*width && Double(z.width)<=width && Double(z.b+y0)>=top && enclosed(z,ROI(width:w,height:h,originX:x0,originY:y0,rgb:[]))
        }.sorted{$0.box.t==$1.box.t ? $0.box.l<$1.box.l:$0.box.t<$1.box.t}
        let roots=candidates.filter{Double($0.box.t+y0)<bottom && Double($0.box.b+y0)>top && Double($0.box.width)>=0.45*width}
        guard roots.count>=2 else { return [] }
        let railL=roots.map{$0.box.l}.min()!,railR=roots.map{$0.box.r}.max()!
        var selected=[CC](),end=top
        // Measured root-stroke scale replaces the prototype's width padding.
        var rootMask=[Bool](repeating:false,count:w*h)
        for c in roots { for p in c.points { rootMask[p]=true } }
        var perimeter=0,area=0
        for i in rootMask.indices where rootMask[i] { area+=1;let x=i%w,y=i/w
            for (dx,dy) in steps {let xx=x+dx,yy=y+dy;if xx<0 || yy<0 || xx>=w || yy>=h || !rootMask[yy*w+xx] {perimeter+=1}}
        }
        let stroke=2*Double(area)/Double(max(1,perimeter))
        for c in candidates {
            if Double(c.box.l)<Double(railL)-stroke || Double(c.box.r)>Double(railR)+stroke { continue }
            if Double(c.box.t+y0)-end>0.65*width { break }
            selected.append(c);end=max(end,Double(c.box.b+y0))
        }
        guard end>bottom+width,let z=bounds(selected.flatMap(\.points),w) else { return [] }
        let world=Box(l:railL+x0-roi.originX,t:z.t+y0-roi.originY,r:railR+x0-roi.originX,b:z.b+y0-roi.originY)
        guard Double(world.l)>stroke,Double(world.t)>stroke,Double(roi.width-world.r)>stroke,Double(roi.height-world.b)>stroke else { return [] }
        return [M(polygon:quad(world,roi,margin:stroke),layer:"UNKNOWN-fragment-dark-rail",
            mechanism:"source-fragment-dark-layer-pixel-rail-v2",diagnostics:["authenticatedDBMembership":0,
            "sourceMemberScopeCount":Double(ids.count),"rootComponents":Double(roots.count),"selectedComponents":Double(selected.count),
            "measuredStrokeUncertainty":stroke,"queryAssociationOnly":1,"detachedMembershipUnknown":1,"incumbentPreserved":1])]
    }

    /// Normal envelope from actual dark cells, with axis correction measured
    /// from full-grid native DB run centers. Query supplies only along extent.
    /// A cell-footprint half width is distinct from a typography margin.
    private static func darkNormalEnvelope(roi:ROI,query:Q,pixels:[Int],runCenters:[[Double]],short:Double) -> M? {
        guard shouldGenerate("source-owned-dark-stroke-normal-envelope-v1") else { return nil }
        guard pixels.count>=32,runCenters.count>=3 else { return nil }
        let q=query.polygon
        let cx=q.reduce(0){$0+$1[0]}/4,cy=q.reduce(0){$0+$1[1]}/4
        var ax=0.0,ay=0.0,best=0.0
        for i in 0..<4 {
            let dx=q[(i+1)%4][0]-q[i][0],dy=q[(i+1)%4][1]-q[i][1],length=hypot(dx,dy)
            if length>best { best=length;ax=dx/length;ay=dy/length }
        }
        guard best>=4*short else { return nil }
        if ay<0 || (ay==0 && ax<0) { ax = -ax;ay = -ay }
        var nx=ay,ny = -ax
        let ta=runCenters.map{($0[0]-cx)*ax+($0[1]-cy)*ay}
        let na=runCenters.map{($0[0]-cx)*nx+($0[1]-cy)*ny}
        let mt=ta.reduce(0,+)/Double(ta.count),mn=na.reduce(0,+)/Double(na.count)
        var covariance=0.0,variance=0.0
        for i in ta.indices { covariance+=(ta[i]-mt)*(na[i]-mn);variance+=(ta[i]-mt)*(ta[i]-mt) }
        guard variance>0 else { return nil }
        let slope=covariance/variance
        guard slope.isFinite,abs(slope)<=0.15 else { return nil }
        let ux=ax+slope*nx,uy=ay+slope*ny,length=hypot(ux,uy)
        ax=ux/length;ay=uy/length;nx=ay;ny = -ax
        let normal=pixels.map { i -> Double in
            let x=Double(i%roi.width+roi.originX)+0.5-cx
            let y=Double(i/roi.width+roi.originY)+0.5-cy
            return x*nx+y*ny
        }
        let low=quantile(normal,0.01)-0.5,high=quantile(normal,0.99)+0.5
        guard high-low>=0.5*short,high-low<=short else { return nil }
        let along=q.map{($0[0]-cx)*ax+($0[1]-cy)*ay}
        let lo=along.min()!,hi=along.max()!
        let out=[(lo,low),(lo,high),(hi,high),(hi,low)].map { a,n in [cx+ax*a+nx*n,cy+ay*a+ny*n] }
        return M(polygon:out,layer:"dark-stroke-normal-body",mechanism:"source-owned-dark-stroke-normal-envelope-v1",
                 diagnostics:["axisSlopeFromActualRuns":slope,"runCenters":Double(runCenters.count),
                              "corePixelCount":Double(pixels.count),"normalQuantileLow":0.01,"normalQuantileHigh":0.99,
                              "cellFootprintHalfWidth":0.5,"alongExtentPreserved":1,"incumbentPreserved":1,
                              "detachedMembershipUnknown":1])
    }

    /// Literal core -> opposite/colored rim -> stable distinct exterior. Ends
    /// are measured rim cells; no radius dilation or padding grid is emitted.
    private static func finiteRays(colors:[RGB],chosen:[Bool],own:[Bool],foreign:[Bool],
                                   w:Int,h:Int,short:Double,bright:Bool) -> [Ray] {
        var starts=[(Int,Int,Int)]()
        for y in 0..<h {
            var lo=w,hi = -1
            for x in 0..<w where chosen[y*w+x] { lo=min(lo,x);hi=max(hi,x) }
            if hi>=0 { starts.append((lo,y,0));starts.append((hi,y,1)) }
        }
        for x in 0..<w {
            var lo=h,hi = -1
            for y in 0..<h where chosen[y*w+x] { lo=min(lo,y);hi=max(hi,y) }
            if hi>=0 { starts.append((x,lo,2));starts.append((x,hi,3)) }
        }
        var rays=[Ray]()
        let limit=max(4,Int(ceil(short*0.45))),transition=max(2,Int(ceil(short*0.12)))
        for (x,y,side) in starts {
            let (dx,dy)=steps[side];var rimStart=0,last = -1,depth=0
            let core=colors[y*w+x]
            for step in 1...(limit+transition+3) {
                let xx=x+dx*step,yy=y+dy*step
                if xx<1 || yy<1 || xx>=w-1 || yy>=h-1 { break }
                let i=yy*w+xx,c=colors[i]
                if foreign[i] { break }
                let isRim=bright ? (c.high<100 || (c.chroma>=40 && core.distance(c)>=60)) : (c.low>=210 && c.chroma<=35)
                if rimStart==0 {
                    if isRim { rimStart=step;last=i;depth=1 }
                    else if step>=transition { break }
                } else if isRim {
                    depth+=1;last=i
                    if depth>limit { break }
                } else {
                    let nx=xx+dx,ny=yy+dy
                    if nx<0 || ny<0 || nx>=w || ny>=h || last<0 || depth<2 { break }
                    let next=colors[ny*w+nx],rim=colors[last]
                    if !foreign[ny*w+nx] && c.distance(next)<=20 && c.distance(rim)>=40 {
                        rays.append(Ray(end:last,side:side,line:side<2 ? y:x,depth:depth))
                    }
                    break
                }
            }
        }
        return rays
    }

}
