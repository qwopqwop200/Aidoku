import Foundation
import CoreGraphics

/// Source-only geometry. Footprint cells are association cues, NEVER foreground.
/// All envelopes use actual RGBA pixel squares; no rasterized hull or quad.
enum NativeOCRRepair402Axis {
    typealias K = NativeOCRSharedBoundary396
    private struct Component {
        let pixels: [Int]
        let bodyCount: Int
        let clipped: Bool
        let n0: CGFloat, n1: CGFloat, a0: CGFloat, a1: CGFloat
        let colour: SIMD3<Int>
        let contrast: Int
    }
    private static func median(_ v: [CGFloat]) -> CGFloat {
        let s = v.sorted(); return s.isEmpty ? 0 : s[s.count / 2]
    }
    static func generate(actualOld old: [CGPoint], basis f: K.Basis,
                         nativeW mw: CGFloat, evidence e: K.Evidence) -> K.Output {
        func none(_ reason: String) -> K.Output {
            .init(proposals: [], receipt: ["family":"repair402-axis", "status":reason,
                "admissionGranted":false, "GTRead":false, "nativeAdmissionSuiteRun":false])
        }
        let r = e.rgba, w = r.width, h = r.height
        guard w > 2, h > 2, w <= 600_000 / h, w <= Int.max / 4,
              r.bytesPerRow >= w * 4, h <= Int.max / r.bytesPerRow,
              r.bytes.count == h * r.bytesPerRow, e.body.count == w * h,
              old.count == 4, mw.isFinite, mw > 0, mw < 100_000,
              [r.origin, f.origin, f.normal, f.along].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              old.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              abs(hypot(f.normal.x,f.normal.y)-1) < 1e-6,
              abs(hypot(f.along.x,f.along.y)-1) < 1e-6,
              abs(f.normal.x*f.along.x+f.normal.y*f.along.y) < 1e-6,
              e.detectors.count <= 64, e.rf.count <= 160,
              e.nativeCellCenters.count <= 600_000 else { return none("invalid-bounded-source-session") }
        let turns = (0..<4).map { i -> CGFloat in
            let a=old[i], b=old[(i+1)%4], c=old[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({$0 > 1e-8}) || turns.allSatisfy({$0 < -1e-8}) else { return none("invalid-old-convexity") }
        let rf = e.rf.filter { v in
            v.bounds.count == 4 && v.bounds.allSatisfy(\.isFinite) && v.confidence.isFinite &&
            v.confidence >= 0.5 && v.bounds[0] <= v.bounds[2] && v.bounds[1] <= v.bounds[3]
        }
        func world(_ i: Int) -> CGPoint { CGPoint(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5) }
        func project(_ p: CGPoint) -> CGPoint {
            let x=p.x-f.origin.x, y=p.y-f.origin.y
            return CGPoint(x:x*f.normal.x+y*f.normal.y,y:x*f.along.x+y*f.along.y)
        }
        func rgb(_ i: Int) -> SIMD3<Int> {
            let k=(i/w)*r.bytesPerRow+(i%w)*4
            return SIMD3(Int(r.bytes[k]),Int(r.bytes[k+1]),Int(r.bytes[k+2]))
        }
        func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int { max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z)) }
        func opaque(_ i: Int) -> Bool { r.bytes[(i/w)*r.bytesPerRow+(i%w)*4+3] == 255 }
        let body = e.body.indices.filter { e.body[$0] != 0 && opaque($0) }
        guard body.count >= 4 else { return none("insufficient-opaque-real-GG-body") }
        let positions = body.map { project(world($0)) }
        let aMin=positions.map(\.y).min()!, aMax=positions.map(\.y).max()!
        let nMin=positions.map(\.x).min()!, nMax=positions.map(\.x).max()!
        // RGB-connected finite components, anchored to actual GG body. A footprint
        // match alone, or a detector/RF rectangle alone, cannot seed foreground.
        var labels=[Int](repeating:-1,count:w*h), components:[Component]=[]
        let directions=[(-1,0),(1,0),(0,-1),(0,1),(-1,-1),(1,-1),(-1,1),(1,1)]
        for seed in labels.indices where labels[seed] == -1 {
            if !opaque(seed) { labels[seed] = -2; continue }
            guard components.count < 30_000 else { return none("RGB-component-budget-exceeded") }
            let id=components.count, reference=rgb(seed)
            var queue=[seed], cursor=0, count=0, clipped=false, contrast=0
            var loN=CGFloat.infinity, hiN = -CGFloat.infinity, loA=CGFloat.infinity, hiA = -CGFloat.infinity
            labels[seed]=id
            while cursor < queue.count {
                let i=queue[cursor]; cursor += 1
                if e.body[i] != 0 { count += 1 }
                let p=project(world(i)); loN=min(loN,p.x); hiN=max(hiN,p.x); loA=min(loA,p.y); hiA=max(hiA,p.y)
                let x=i%w, y=i/w
                if x == 0 || y == 0 || x == w-1 || y == h-1 { clipped=true }
                for (dx,dy) in directions {
                    let xx=x+dx, yy=y+dy
                    if xx < 0 || yy < 0 || xx >= w || yy >= h { continue }
                    let j=yy*w+xx
                    if !opaque(j) { clipped=true; continue }
                    if distance(rgb(i),rgb(j)) >= 40 { contrast += 1 }
                    if labels[j] == -1 && distance(reference,rgb(j)) <= 32 && distance(rgb(i),rgb(j)) <= 24 {
                        labels[j]=id; queue.append(j)
                    }
                }
            }
            components.append(.init(pixels:queue,bodyCount:count,clipped:clipped,n0:loN,n1:hiN,a0:loA,a1:hiA,colour:reference,contrast:contrast))
        }
        let roots=components.indices.filter {
            let c=components[$0]
            return c.bodyCount > 0 && !c.clipped && c.contrast >= 2 &&
                c.n1-c.n0 <= max(mw*2.5,nMax-nMin+2) && c.a1-c.a0 <= aMax-aMin+mw*2
        }
        // Real body always survives even if its colour CC opens into background.
        // Such a CC is NOT silently converted into foreground.
        var selected=Set(roots), support=Set(body), componentWitnesses:[[String:Any]]=[]
        for id in roots { support.formUnion(components[id].pixels) }
        var rootRF=Set<Int>()
        for i in body.enumerated().filter({$0.offset % max(1,body.count/128) == 0}).prefix(128).map(\.element) {
            for v in rf where v.contains(world(i)) { rootRF.insert(v.query) }
        }
        // Recover bounded detached dots/quotes only with actual sparse detector
        // cells + shared RF query + real colour/contrast and same-row proximity.
        // Still a hypothesis; association and peers remain native obligations.
        var nominations=0
        for id in components.indices where !selected.contains(id) {
            let c=components[id]
            guard nominations < 128, !c.clipped, c.pixels.count >= 2, c.contrast >= 2,
                  c.n1-c.n0 <= mw*1.5, c.a1-c.a0 <= mw*2,
                  c.a0 >= aMin-mw, c.a1 <= aMax+mw,
                  c.n0 >= nMin-mw*0.35, c.n1 <= nMax+mw*0.35,
                  roots.contains(where:{distance(components[$0].colour,c.colour) <= 24}) else { continue }
            nominations += 1
            let sample=c.pixels[c.pixels.count/2], p=world(sample)
            let db=e.detectors.contains { $0.nativeRoot && $0.cells.contains(p) }
            let commonRF=rf.contains { rootRF.contains($0.query) && $0.contains(p) }
            if db && commonRF {
                selected.insert(id); support.formUnion(c.pixels)
                componentWitnesses.append(["component":id,"actualPixelIndex":sample,"nativeRootDetectorCell":true,"commonRFQuery":true,"associationProven":false])
            }
        }
        // Up to two short contact hops recover actual outer outline/AA colours.
        // Contact is pixel adjacency, never an interpolated filled interior.
        for _ in 0..<2 {
            var contacts:[Int:Int]=[:]
            for i in support.sorted() {
                let x=i%w,y=i/w
                for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                    let xx=x+dx,yy=y+dy
                    guard xx>=0,yy>=0,xx<w,yy<h else { continue }
                    let id=labels[yy*w+xx]
                    if id>=0 && !selected.contains(id) { contacts[id,default:0] += 1 }
                }
            }
            var added=false
            for id in contacts.keys.sorted() {
                let c=components[id]
                guard contacts[id,default:0] >= 2, !c.clipped, c.contrast >= 2,
                      c.n1-c.n0 <= max(mw*2,nMax-nMin+4), c.a1-c.a0 <= aMax-aMin+4,
                      c.n0 >= nMin-mw*0.2-2, c.n1 <= nMax+mw*0.2+2,
                      c.a0 >= aMin-mw*0.2-2, c.a1 <= aMax+mw*0.2+2 else { continue }
                selected.insert(id);support.formUnion(c.pixels);added=true
            }
            if !added { break }
        }
        let pixels=support.sorted(), coords=pixels.map { project(world($0)) }
        // Independent occupied row medians prevent a large glyph from dominating
        // angle. Theil-Sen slopes use widely separated rows (bounded 48 rows).
        var rows=[[CGFloat]](repeating:[],count:48), rowA=[[CGFloat]](repeating:[],count:48)
        for p in positions {
            let k=min(47,max(0,Int((p.y-aMin)/max(1,aMax-aMin)*48)))
            rows[k].append(p.x);rowA[k].append(p.y)
        }
        let centers=rows.indices.filter{!rows[$0].isEmpty}.map { CGPoint(x:median(rows[$0]),y:median(rowA[$0])) }
        func robustAngle(_ pts: [CGPoint]) -> CGFloat? {
            var slopes:[CGFloat]=[]
            for i in pts.indices { for j in pts.indices where j>i {
                let d=pts[j].y-pts[i].y
                if abs(d)>=max(mw*0.5,(aMax-aMin)*0.25) { slopes.append((pts[j].x-pts[i].x)/d) }
            }}
            return slopes.count>=3 ? -atan(median(slopes))*180/CGFloat.pi : nil
        }
        let ccCenters=roots.map { id -> CGPoint in
            let c=components[id];return CGPoint(x:(c.n0+c.n1)*0.5,y:(c.a0+c.a1)*0.5)
        }
        let rowAngle=robustAngle(centers), ccAngle=robustAngle(ccCenters)
        func rotate(_ p: CGPoint,_ degrees: CGFloat) -> CGPoint {
            let t=degrees*CGFloat.pi/180,c=cos(t),s=sin(t)
            return CGPoint(x:p.x*c-p.y*s,y:p.x*s+p.y*c)
        }
        // Compact glyphs cannot yield a trustworthy long-row direction. Search
        // a wider SOURCE-relative interval using actual occupied pixel bounds.
        // No horizontal/vertical page-axis shortcut or GT-derived direction.
        let compact=(aMax-aMin) < max(mw*2,nMax-nMin)*1.5
        func score(_ angle: CGFloat) -> CGFloat {
            let p=(compact ? positions : centers).map { rotate($0,angle) }
            let ns=p.map(\.x), aa=p.map(\.y)
            let breadth=(ns.max()!-ns.min()!)+1
            if compact { return breadth*((aa.max()!-aa.min()!)+1)/max(1,mw*mw) }
            return breadth/max(1,mw)
        }
        let limit=compact ? 60 : 30
        var best=CGFloat(0), bestScore=score(0)
        for degree in -limit...limit {
            let a=CGFloat(degree), s=score(a)
            if s < bestScore-1e-9 { best=a;bestScore=s }
        }
        let coarse=best
        for k in -4...4 {
            let a=coarse+CGFloat(k)*0.125,s=score(a)
            if abs(a)<=CGFloat(limit),s < bestScore-1e-9 { best=a;bestScore=s }
        }
        var angles:[(String,CGFloat)]=[]
        func add(_ name: String,_ a: CGFloat?) {
            guard let a=a,a.isFinite,abs(a)<=CGFloat(limit),!angles.contains(where:{abs($0.1-a)<0.1}),angles.count<4 else{return}
            angles.append((name,a))
        }
        add("row",rowAngle);add("cc",ccAngle);add("projection",best);add("source",0)
        // Supply an independently supported projection shoulder if fits coincide.
        if angles.count<4 { add("shoulder",max(-CGFloat(limit),min(CGFloat(limit),best+0.75))) }
        var proposals:[K.Proposal]=[],seen=Set<String>(),geometryRejects=0
        for (name,angle) in angles {
            let t=angle*CGFloat.pi/180,c=cos(t),s=sin(t)
            let n=CGPoint(x:f.normal.x*c-f.along.x*s,y:f.normal.y*c-f.along.y*s)
            let a=CGPoint(x:f.normal.x*s+f.along.x*c,y:f.normal.y*s+f.along.y*c)
            let nr=(abs(n.x)+abs(n.y))*0.5, ar=(abs(a.x)+abs(a.y))*0.5
            let transformed=coords.map { rotate($0,angle) }
            let ns=transformed.map(\.x), aa=transformed.map(\.y)
            let extremes=[ns.indices.min{ns[$0]<ns[$1]}!,ns.indices.max{ns[$0]<ns[$1]}!,aa.indices.min{aa[$0]<aa[$1]}!,aa.indices.max{aa[$0]<aa[$1]}!]
            // Independently fit low/high row edges as a second, shear-aware
            // hypothesis. Robust fit determines slopes only; ALL real support
            // extrema, never quantiles, determine each final outward plane.
            var edgeRows=[[CGPoint]](repeating:[],count:32)
            let fitBody=positions.map{rotate($0,angle)}
            let fitLo=fitBody.map(\.y).min()!,fitHi=fitBody.map(\.y).max()!
            for p in fitBody {
                let k=min(31,max(0,Int((p.y-fitLo)/max(1,fitHi-fitLo)*32)))
                edgeRows[k].append(p)
            }
            let edges=edgeRows.filter{!$0.isEmpty}.map { row -> (CGFloat,CGFloat,CGFloat) in
                (median(row.map(\.y)),row.map(\.x).min()!,row.map(\.x).max()!)
            }
            var lowSlopes:[CGFloat]=[],highSlopes:[CGFloat]=[]
            for i in edges.indices {for j in edges.indices where j>i {
                let d=edges[j].0-edges[i].0
                if abs(d)>=max(mw*0.5,(fitHi-fitLo)*0.3) {
                    lowSlopes.append((edges[j].1-edges[i].1)/d)
                    highSlopes.append((edges[j].2-edges[i].2)/d)
                }
            }}
            let mid=(aa.min()!+aa.max()!)*0.5
            for variant in 0..<2 {
                let padding=variant == 0 ? CGFloat(0):min(1,mw*0.025)
                let sl=variant == 1 && !compact ? max(-0.35,min(0.35,median(lowSlopes))):0
                let sh=variant == 1 && !compact ? max(-0.35,min(0.35,median(highSlopes))):0
                let lo=transformed.map{$0.x-sl*($0.y-mid)}.min()!-nr-abs(sl)*ar-padding
                let hi=transformed.map{$0.x-sh*($0.y-mid)}.max()!+nr+abs(sh)*ar+padding
                let head=aa.min()!-ar-padding,tail=aa.max()!+ar+padding
                func restore(_ nn: CGFloat,_ al: CGFloat) -> CGPoint { CGPoint(x:f.origin.x+nn*n.x+al*a.x,y:f.origin.y+nn*n.y+al*a.y) }
                let raw=[restore(lo+sl*(head-mid),head),restore(hi+sh*(head-mid),head),
                         restore(hi+sh*(tail-mid),tail),restore(lo+sl*(tail-mid),tail)]
                var q=raw,cost=CGFloat.infinity
                for reverse in [false,true] {
                    let z=reverse ? Array(raw.reversed()):raw
                    for offset in 0..<4 {
                        let v=(0..<4).map{z[($0+offset)%4]}
                        let value=(0..<4).reduce(CGFloat(0)) { total,i in total+pow(v[i].x-old[i].x,2)+pow(v[i].y-old[i].y,2) }
                        if value<cost {cost=value;q=v}
                    }
                }
                guard q.allSatisfy({$0.x.isFinite && $0.y.isFinite && $0.x>=r.origin.x && $0.y>=r.origin.y && $0.x<=r.origin.x+CGFloat(w) && $0.y<=r.origin.y+CGFloat(h)}),hi+sh*(head-mid)>lo+sl*(head-mid),hi+sh*(tail-mid)>lo+sl*(tail-mid),tail>head else {geometryRejects += 1;continue}
                let key=q.map{String(format:"%.6f,%.6f",Double($0.x),Double($0.y))}.joined(separator:";")
                guard seen.insert(key).inserted,proposals.count<8 else {continue}
                let nativeLoss=e.nativeCellCenters.filter { K.contains(old,$0) && !K.contains(q,$0) }
                let bodyLoss=body.filter { K.contains(old,world($0)) && !K.contains(q,world($0)) }
                func witness(_ i: Int) -> [String:Any] {
                    let p=world(i),v=rgb(i)
                    return ["actualLocalPixelIndex":i,"center":[Double(p.x),Double(p.y)],"RGB":[v.x,v.y,v.z],"rootGGBody":e.body[i] != 0,"actualNativeFootprintContains":e.privateAt(p),"outsideOld":!K.contains(old,p),"ownershipClaimed":false]
                }
                let oldP=old.map{rotate(project($0),angle)}
                let oldBounds=[oldP.map(\.x).min()!,oldP.map(\.x).max()!,oldP.map(\.y).min()!,oldP.map(\.y).max()!]
                let receipt:[String:Any]=[
                    "family":"repair402-axis","axisFit":name,"angleDegreesRelativeToSource":Double(angle),
                    "allFourBoundsRefitted":true,"independentNormalSideSlopes":[Double(sl),Double(sh)],"sideSlopeAlongOrigin":Double(mid),"normalBounds":[Double(lo),Double(hi)],"alongBounds":[Double(head),Double(tail)],
                    "boundsChangesFromOldProjectedEnvelope":zip([lo,hi,head,tail],oldBounds).map{Double($0.0-$0.1)},
                    "actualOld":old.map{[Double($0.x),Double($0.y)]},"actualOldEnclosed":old.allSatisfy{K.contains(q,$0)},
                    "actualOuterPixelSquareSupportCount":pixels.count,"allSelectedPixelSquaresPreserved":true,
                    "edgeActualPixelWitnesses":extremes.map{witness(pixels[$0])},
                    "sourceGGBodyPixelsOutsideOld":body.filter{!K.contains(old,world($0))}.count,
                    "newlyExcludedOriginalGGBodyPixels":bodyLoss.count,"newlyExcludedNativeCellCenters":nativeLoss.count,
                    "nativeCellLossWitnesses":nativeLoss.prefix(4).map{[Double($0.x),Double($0.y)]},
                    "nativeCellLossIsForegroundLoss":false,"foregroundCompletenessClaimed":false,
                    "sourceFootprintsUsedAsForeground":false,"RLEHullFilled":false,"quadFilledAsInk":false,
                    "detectorAndRFRectanglesAreOwnership":false,"detachedAssociationWitnesses":componentWitnesses,
                    "sourceSupportComponentIDs":selected.sorted(),"nativeAdmissionSuiteRun":false,"admissionGranted":false]
                var obligations=["actual-native-whole-dense-GG-terminal-and-semantic-readmission-required",
                    "foreign-peer-new-acquisition-and-separately-retained-box-check-required",
                    "detached-dot-quote-and-outer-rim-association-unproven","source-only-no-erasure-authority",
                    "captured-window-is-not-global-foreground-completeness"]
                if !nativeLoss.isEmpty { obligations.append("actual-footprint-cell-loss-requires-native-evaluation-not-automatic-ink-veto") }
                if body.contains(where:{let x=$0%w,y=$0/w;return x==0 || y==0 || x==w-1 || y==h-1}) {obligations.append("body-touches-capture-edge-new-local-observation-required")}
                if components.contains(where:{$0.bodyCount>0 && $0.clipped}) {obligations.append("open-body-colour-component-extent-unresolved")}
                if compact {obligations.append("compact-glyph-axis-ambiguous-native-selection-required")}
                proposals.append(.init(suffix:"repair402-axis-\(name)-variant\(variant)",polygon:q,receipt:receipt,obligations:obligations))
            }
        }
        return .init(proposals:proposals,receipt:["family":"repair402-axis","status":proposals.isEmpty ? "no-in-capture-refit":"source-only-proposals-frozen",
            "proposalCount":proposals.count,"maxProposals":8,"realGGBodyPixels":body.count,"selectedActualPixels":pixels.count,
            "rowCenters":centers.count,"rootColourComponents":roots.count,"allRGBComponents":components.count,
            "rowAngle":rowAngle.map{Double($0) as Any} ?? NSNull(),"ccAngle":ccAngle.map{Double($0) as Any} ?? NSNull(),
            "projectionAngle":Double(best),"compactAxisAmbiguous":compact,"geometryRejectedOutsideCapture":geometryRejects,
            "unusableRFRecords":e.rf.count-rf.count,"nonopaqueBodySamples":e.body.indices.filter{e.body[$0] != 0 && !opaque($0)}.count,
            "sourceBasisUsedForEveryAngle":true,"footprintIsNotForeground":true,"GTRead":false,"admissionGranted":false])
    }
}
