import Foundation
import CoreGraphics

enum NativeOCROutlineBoundary397Kernel {
    struct RGBA {let bytes:[UInt8];let width:Int;let height:Int;let bytesPerRow:Int;let origin:CGPoint}
    struct Basis {let origin:CGPoint;let normal:CGPoint;let along:CGPoint}
    struct PrivateRLE {
        let width:Int;let height:Int;let scaleX:CGFloat;let scaleY:CGFloat
        private let rows:[Int:[ClosedRange<Int>]]
        init?(width:Int,height:Int,scaleX:CGFloat,scaleY:CGFloat,runs:[[Int]]) {
            guard width>0,height>0,width<=Int.max/height,scaleX.isFinite,scaleY.isFinite,scaleX>0,scaleY>0 else{return nil}
            var rows:[Int:[ClosedRange<Int>]]=[:]
            for r in runs {
                guard r.count==3,r[0]>=0,r[0]<height,r[1]>=0,r[2]>0,r[2]<=width,r[1]<=width-r[2] else{return nil}
                let v=r[1]...(r[1]+r[2]-1)
                if rows[r[0],default:[]].contains(where:{$0.overlaps(v)}){return nil}
                rows[r[0],default:[]].append(v)
            }
            self.width=width;self.height=height;self.scaleX=scaleX;self.scaleY=scaleY;self.rows=rows
        }
        func contains(_ p:CGPoint)->Bool {
            guard p.x.isFinite,p.y.isFinite else{return false}
            let x=floor(p.x/scaleX+1e-7),y=floor(p.y/scaleY+1e-7)
            guard x>=0,x<CGFloat(width),y>=0,y<CGFloat(height) else{return false}
            return rows[Int(y),default:[]].contains{ $0.contains(Int(x)) }
        }
    }
    struct Repair {let polygon:[CGPoint]?;let receipt:[String:Any]}
    struct Invalid:Error {let reason:String}
    private struct Ray {
        let seed:Int;let bin:Int;let direction:CGPoint
        let fillEnd:Int;let rimStart:Int;let rimEnd:Int
        let support:[Int];let exterior:[Int]
        let rimRGB:SIMD3<Int>;let fillRGB:SIMD3<Int>;let rimDepth:CGFloat
    }
    private struct OpenRay {let seed:Int;let bin:Int;let sawRim:Bool;let reason:String}
    private struct Bank {let rays:[Ray];let open:[OpenRay];let selectedSeeds:Int;let totalSeedBins:Int}
    static func contains(_ q:[CGPoint],_ p:CGPoint)->Bool {
        guard q.count==4 else{return false}
        var plus=false,minus=false
        for i in 0..<4 {let a=q[i],b=q[(i+1)%4],v=(b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
            plus = plus || v>1e-7;minus = minus || v < -1e-7}
        return !plus || !minus
    }
    final class Session {
        let rgba:RGBA,actualOld:[CGPoint],basis:Basis,nativeW:CGFloat
        private let body:[UInt8],privateAt:(CGPoint)->Bool
        private let nativeAnchoredSeeds:Bool
        private var bodyIndices:[Int]=[],anchorColours:[SIMD3<Int>]=[]
        private var banks:[String:Bank]=[:]
        private var sampleQueries=0,rayQueries=0
        private(set) var budgetExhausted=false
        private let n0:CGFloat,n1:CGFloat,a0:CGFloat,a1:CGFloat
        init(rgba r:RGBA,body:[UInt8],privateAt:@escaping(CGPoint)->Bool,actualOld:[CGPoint],basis:Basis,nativeW:CGFloat,nativeAnchoredSeeds:Bool=false)throws {
            guard r.width>2,r.height>2,r.width<=600_000/r.height,r.bytesPerRow>=r.width*4,
                r.height<=Int.max/r.bytesPerRow,r.bytes.count==r.height*r.bytesPerRow,
                body.count==r.width*r.height,nativeW.isFinite,nativeW>0,nativeW<100_000,
                actualOld.count==4,abs(hypot(basis.normal.x,basis.normal.y)-1)<1e-6,
                abs(hypot(basis.along.x,basis.along.y)-1)<1e-6,
                abs(basis.normal.x*basis.along.x+basis.normal.y*basis.along.y)<1e-6 else{throw Invalid(reason:"invalid-bounded-source-session")}
            self.nativeAnchoredSeeds=nativeAnchoredSeeds
            self.rgba=r;self.body=body;self.privateAt=privateAt;self.actualOld=actualOld;self.basis=basis;self.nativeW=nativeW
            func project(_ p:CGPoint)->CGPoint {
                let x=p.x-basis.origin.x,y=p.y-basis.origin.y
                return CGPoint(x:x*basis.normal.x+y*basis.normal.y,y:x*basis.along.x+y*basis.along.y)
            }
            let pp=actualOld.map(project)
            n0=pp.map(\.x).min()!-nativeW;n1=pp.map(\.x).max()!+nativeW
            a0=pp.map(\.y).min()!-nativeW;a1=pp.map(\.y).max()!+nativeW
            var counts:[Int]=[],privateAnchors=0
            for i in body.indices where body[i] != 0 && opaque(i) && observed(world(i)) {
                bodyIndices.append(i)
                guard Self.pointInside(actualOld,world(i)),privateAt(world(i)) else{continue}
                privateAnchors += 1
                let c=rgb(i)
                if let k=anchorColours.firstIndex(where:{distance($0,c)<=24}){counts[k] += 1}
                else if anchorColours.count<16{anchorColours.append(c);counts.append(1)}
            }
            anchorColours=anchorColours.indices.filter{counts[$0]>=2}.map{anchorColours[$0]}
            guard privateAnchors>=2,!anchorColours.isEmpty,!bodyIndices.isEmpty else{throw Invalid(reason:"no-actual-root-GG-and-native-footprint-anchors")}
        }
        private static func pointInside(_ q:[CGPoint],_ p:CGPoint)->Bool {NativeOCROutlineBoundary397Kernel.contains(q,p)}
        private func world(_ i:Int)->CGPoint {CGPoint(x:rgba.origin.x+CGFloat(i%rgba.width)+0.5,y:rgba.origin.y+CGFloat(i/rgba.width)+0.5)}
        private func rgb(_ i:Int)->SIMD3<Int> {
            let k=(i/rgba.width)*rgba.bytesPerRow+(i%rgba.width)*4
            return .init(Int(rgba.bytes[k]),Int(rgba.bytes[k+1]),Int(rgba.bytes[k+2]))
        }
        private func opaque(_ i:Int)->Bool {rgba.bytes[(i/rgba.width)*rgba.bytesPerRow+(i%rgba.width)*4+3]==255}
        private func distance(_ a:SIMD3<Int>,_ b:SIMD3<Int>)->Int {max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z))}
        private func dot(_ p:CGPoint,_ n:CGPoint)->CGFloat {p.x*n.x+p.y*n.y}
        private func observed(_ p:CGPoint)->Bool {
            guard p.x>=rgba.origin.x,p.x<rgba.origin.x+CGFloat(rgba.width),p.y>=rgba.origin.y,p.y<rgba.origin.y+CGFloat(rgba.height) else{return false}
            let dx=p.x-basis.origin.x,dy=p.y-basis.origin.y
            let n=dx*basis.normal.x+dy*basis.normal.y,a=dx*basis.along.x+dy*basis.along.y
            let nr=(abs(basis.normal.x)+abs(basis.normal.y))*0.5,ar=(abs(basis.along.x)+abs(basis.along.y))*0.5
            return n-nr>=n0 && n+nr<=n1 && a-ar>=a0 && a+ar<=a1
        }
        private func sample(_ p:CGPoint)->Int? {
            sampleQueries += 1
            if sampleQueries>8_000_000{budgetExhausted=true;return nil}
            guard observed(p) else{return nil}
            let x=Int(floor(p.x-rgba.origin.x)),y=Int(floor(p.y-rgba.origin.y)),i=y*rgba.width+x
            return opaque(i) && observed(world(i)) ? i:nil
        }
        private func witness(_ i:Int)->[String:Any] {
            let p=world(i),c=rgb(i)
            return ["localPixelIndex":i,"center":[Double(p.x),Double(p.y)],"RGB":[c.x,c.y,c.z],
                "actualRootGGBody":body[i] != 0,"actualNativeFootprintAtCenter":privateAt(p),
                "outsideActual386Old":!Self.pointInside(actualOld,p),"ownershipClaimed":false]
        }
        private func mixture(_ indices:ArraySlice<Int>,from:SIMD3<Int>,to:SIMD3<Int>)->Bool {
            var previous=from
            for i in indices {
                let c=rgb(i)
                for channel in 0..<3 {
                    if c[channel]<min(from[channel],to[channel])-16 || c[channel]>max(from[channel],to[channel])+16{return false}
                    if to[channel]>from[channel] && c[channel]<previous[channel]-16{return false}
                    if to[channel]<from[channel] && c[channel]>previous[channel]+16{return false}
                }
                previous=c
            }
            return true
        }
        private func trace(seed originalSeed:Int,bin:Int,n:CGPoint)->(Ray?,OpenRay?) {
            var seed=originalSeed
            rayQueries += 1
            if rayQueries>32_768{budgetExhausted=true;return(nil,.init(seed:seed,bin:bin,sawRim:false,reason:"root-ray-budget"))}
            // Start a few REAL same-colour GG body cells inward of the
            // extremal seed; the geometry core is never rasterized as a seed.
            let original=world(seed),initial=rgb(seed)
            for backstep in 1...6 {
                let p=CGPoint(x:original.x-n.x*CGFloat(backstep)*0.5,y:original.y-n.y*CGFloat(backstep)*0.5)
                guard let i=sample(p),body[i] != 0,(!nativeAnchoredSeeds || privateAt(world(i))),distance(rgb(i),initial)<=24 else{break}
                seed=i
            }
            let start=world(seed)
            var cells=[seed],last=seed,truncated=false
            let steps=min(4096,Int(ceil(nativeW*4+16)))
            for step in 1...steps {
                let p=CGPoint(x:start.x+n.x*CGFloat(step)*0.5,y:start.y+n.y*CGFloat(step)*0.5)
                guard let i=sample(p) else{truncated=true;break}
                if i != last {cells.append(i);last=i}
            }
            let fill=rgb(seed)
            guard cells.count>=7 else{return(nil,.init(seed:seed,bin:bin,sawRim:false,reason:truncated ? "fill-ray-boundary-truncated-fresh-read-required":"insufficient-observed-ray"))}
            var end=0
            while end+1<cells.count && distance(rgb(cells[end+1]),fill)<=28 {end += 1}
            guard end+3<cells.count else{return(nil,.init(seed:seed,bin:bin,sawRim:false,reason:truncated ? "fill-open-at-probe-fresh-read-required":"no-distinct-fill-to-rim"))}
            let transition=max(2,min(16,Int(ceil(nativeW*0.12))))
            var rimIndex:Int?=nil
            for k in (end+1)...min(cells.count-3,end+transition+1) {
                let c=rgb(cells[k])
                if distance(fill,c)>=40 && distance(c,rgb(cells[k+1]))<=12 && mixture(cells[(end+1)..<k],from:fill,to:c) {rimIndex=k;break}
            }
            guard let rs=rimIndex else{return(nil,.init(seed:seed,bin:bin,sawRim:false,reason:"no-literal-rim-band"))}
            let rim=rgb(cells[rs]);var re=rs+1
            while re+1<cells.count && distance(rgb(cells[re+1]),rim)<=24 {re += 1}
            let required=max(CGFloat(3),nativeW*0.05)
            let stableCount=max(4,Int(ceil(required))+1)
            if re+stableCount<cells.count {
                for bg in (re+1)...min(cells.count-stableCount,re+transition+1) {
                    let outside=rgb(cells[bg])
                    guard distance(rim,outside)>=40,
                        mixture(cells[(re+1)..<bg],from:rim,to:outside) else{continue}
                    let ex=Array(cells[bg..<(bg+stableCount)])
                    guard ex.allSatisfy({distance(rgb($0),outside)<=8}),
                        dot(world(ex.last!),n)-dot(world(ex.first!),n)+abs(n.x)+abs(n.y)>=required else{continue}
                    let support=Array(cells[..<bg])
                    let depth=dot(world(support.last!),n)-dot(world(cells[rs]),n)+abs(n.x)+abs(n.y)
                    guard depth<=max(4,nativeW*0.45) else{return(nil,.init(seed:seed,bin:bin,sawRim:true,reason:"rim-too-deep-peer-or-layer-ambiguity"))}
                    return(.init(seed:seed,bin:bin,direction:n,fillEnd:cells[end],rimStart:cells[rs],rimEnd:cells[re],
                        support:support,exterior:ex,rimRGB:rim,fillRGB:fill,rimDepth:depth),nil)
                }
            }
            let flatSpan=dot(world(cells[re]),n)-dot(world(cells[rs]),n)
            if flatSpan>max(4,nativeW*0.45) {
                // A flat page/field continuing to the probe is NOT a finite rim.
                // In particular fill->white paper cannot invent a white outline.
                return(nil,.init(seed:seed,bin:bin,sawRim:false,reason:"unbounded-flat-exterior-no-finite-rim-proven"))
            }
            return(nil,.init(seed:seed,bin:bin,sawRim:true,reason:truncated ? "rim-open-at-observed-probe-boundary-fresh-read-required":"rim-open-at-source-relative-bound-fresh-read-required"))
        }
        private func bank(_ n:CGPoint)->Bank {
            let key=String(format:"%.7f,%.7f",Double(n.x),Double(n.y))
            if let cached=banks[key]{return cached}
            if banks.count>=32{budgetExhausted=true;return .init(rays:[],open:[],selectedSeeds:0,totalSeedBins:0)}
            let t=CGPoint(x:-n.y,y:n.x),binWidth=max(1,nativeW*0.025)
            var seeds:[String:(bin:Int,colour:Int,index:Int,position:CGFloat)]=[:]
            for i in bodyIndices {
                guard !nativeAnchoredSeeds || privateAt(world(i)) else { continue }
                let c=rgb(i)
                guard let colour=anchorColours.indices.min(by:{distance(c,anchorColours[$0])<distance(c,anchorColours[$1])}),
                    distance(c,anchorColours[colour])<=28 else{continue}
                let p=world(i),bin=Int(floor(dot(p,t)/binWidth)),position=dot(p,n),k="\(bin):\(colour)"
                if let old=seeds[k],old.position>=position{continue}
                seeds[k]=(bin,colour,i,position)
            }
            let all=seeds.values.sorted{a,b in a.bin==b.bin ? a.colour<b.colour:a.bin<b.bin}
            let count=min(1024,all.count)
            var chosen:[(bin:Int,colour:Int,index:Int,position:CGFloat)]=[]
            if count>0 {for k in 0..<count {chosen.append(all[count==1 ? 0:k*(all.count-1)/(count-1)])}}
            var rays:[Ray]=[],open:[OpenRay]=[]
            for s in chosen {
                let value=trace(seed:s.index,bin:s.bin,n:n)
                if let ray=value.0{rays.append(ray)}
                if let failure=value.1{open.append(failure)}
                if budgetExhausted{break}
            }
            let result=Bank(rays:rays,open:open,selectedSeeds:chosen.count,totalSeedBins:all.count)
            banks[key]=result;return result
        }
        func repair(core:[CGPoint])->Repair {
            func no(_ reason:String,_ sides:[[String:Any]]=[])->Repair {
                .init(polygon:nil,receipt:["family":"outline-boundary-repair395","status":reason,
                    "geometricCore":core.map{[Double($0.x),Double($0.y)]},"actual386Old":actualOld.map{[Double($0.x),Double($0.y)]},
                    "edgeObservations":sides,"admissionGranted":false,"sourceOwnershipChanged":false,
                    "recognitionFailureInferredFromHalo":false,"freshReadRequired":reason.contains("fresh-read")])
            }
            guard core.count==4,core.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else{return no("invalid-core")}
            let crosses=(0..<4).map{i -> CGFloat in let a=core[i],b=core[(i+1)%4],c=core[(i+2)%4];return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)}
            guard crosses.allSatisfy({$0>1e-8}) || crosses.allSatisfy({$0 < -1e-8}) else{return no("nonconvex-core")}
            // Vertices may lie on the window border, but never extrapolate them.
            guard core.allSatisfy({$0.x>=rgba.origin.x && $0.x<=rgba.origin.x+CGFloat(rgba.width) && $0.y>=rgba.origin.y && $0.y<=rgba.origin.y+CGFloat(rgba.height)}) else{return no("core-outside-capture-fresh-read-required")}
            let ccw=crosses[0]>0
            var normals:[CGPoint]=[],planes:[CGFloat]=[],offsets=[CGFloat](repeating:0,count:4),sides:[[String:Any]]=[]
            var hasOpenBoundary=false,qualifiedEdges=0,edgeWitnessCount=0
            for edge in 0..<4 {
                let a=core[edge],b=core[(edge+1)%4],dx=b.x-a.x,dy=b.y-a.y,length=hypot(dx,dy)
                let n=ccw ? CGPoint(x:dy/length,y:-dx/length):CGPoint(x:-dy/length,y:dx/length)
                let t=CGPoint(x:-n.y,y:n.x),plane=dot(a,n),low=min(dot(a,t),dot(b,t))-nativeW*0.25,high=max(dot(a,t),dot(b,t))+nativeW*0.25
                normals.append(n);planes.append(plane)
                let measured=bank(n)
                func relevant(_ seed:Int)->Bool {
                    let p=world(seed),tv=dot(p,t),nv=dot(p,n)
                    return tv>=low && tv<=high && nv>=plane-nativeW && nv<=plane+nativeW*0.5
                }
                let open=measured.open.filter{relevant($0.seed)}
                let truncated=open.filter{$0.reason.contains("fresh-read-required")}
                if !truncated.isEmpty{hasOpenBoundary=true}
                let eligible=measured.rays.filter{ray in
                    guard relevant(ray.seed) else{return false}
                    let outer=ray.support.map{dot(world($0),n)+(abs(n.x)+abs(n.y))*0.5}.max()!
                    return outer>=plane-nativeW*0.35 && outer<=plane+nativeW
                }
                // Repeated actual fill/rim relation; outside colour may vary on a
                // coloured field, but EACH ray independently proves stable exterior.
                var groups:[[Ray]]=[]
                for ray in eligible {
                    if let k=groups.firstIndex(where:{distance($0[0].fillRGB,ray.fillRGB)<=32 && distance($0[0].rimRGB,ray.rimRGB)<=32}) {groups[k].append(ray)}
                    else{groups.append([ray])}
                }
                let repeated=groups.filter{group in
                    let bins=Set(group.map{$0.bin})
                    let ts=group.map{dot(world($0.seed),t)}
                    return bins.count>=3 && (ts.max()!-ts.min()!)>=2
                }.flatMap{$0}
                var extreme:Ray?=nil,extent=plane
                for ray in repeated {
                    let x=ray.support.map{dot(world($0),n)+(abs(n.x)+abs(n.y))*0.5}.max()!
                    if x>extent{extent=x;extreme=ray}
                }
                if !repeated.isEmpty{qualifiedEdges += 1}
                offsets[edge]=max(0,extent-plane)
                var picked=Array(repeated.prefix(5))
                if let ray=extreme{picked.append(ray)}
                let witnesses:[[String:Any]]=picked.map{ray in
                    ["seed":witness(ray.seed),"fillEnd":witness(ray.fillEnd),"actualRimStart":witness(ray.rimStart),
                     "actualRimEnd":witness(ray.rimEnd),"actualLastSupport":witness(ray.support.last!),
                     "actualFillRimAAPathPixelIndices":ray.support,"actualStableExterior":ray.exterior.map(witness),
                     "measuredRimDepthOverNativeW":Double(ray.rimDepth/nativeW),"tangentBin":ray.bin,
                     "literalContiguousSampledPath":true,"coreUsedAsInk":false,"ownershipClaimed":false]
                }
                edgeWitnessCount += witnesses.count
                sides.append(["coreEdge":edge,"outwardDirection":[Double(n.x),Double(n.y)],"coreEdgePlane":Double(plane),
                    "measuredOutwardOffset":Double(offsets[edge]),"selectedSourceSeedCount":measured.selectedSeeds,
                    "totalSourceSeedBins":measured.totalSeedBins,"repeatedQualifiedRays":repeated.count,
                    "positiveLiteralRimWitnesses":witnesses,"openFillOrRimAtProbeOrBound":truncated.count,
                    "unqualifiedOrAmbiguousRayCount":open.count-truncated.count,
                    "ambiguousOrTooDeepRimRays":open.filter{$0.sawRim && !$0.reason.contains("fresh-read-required")}.count,
                    "outerSupportCompleteClaimed":false,"plainPaperRimInvented":false])
            }
            if budgetExhausted{return no("source-session-budget-exhausted",sides)}
            // Open rays are unresolved evidence, not a veto on independently closed measured support.
            // This generator never admits geometry; native checks remain mandatory.
            guard qualifiedEdges>0,offsets.contains(where:{$0>0.25}) else{return no("no-repeated-measured-outward-rim-repair",sides)}
            var q:[CGPoint]=[]
            for i in 0..<4 {
                let j=(i+3)%4,a=normals[j],b=normals[i],u=planes[j]+offsets[j],v=planes[i]+offsets[i],det=a.x*b.y-a.y*b.x
                guard abs(det)>1e-9 else{return no("parallel-core-edges",sides)}
                q.append(CGPoint(x:(u*b.y-a.y*v)/det,y:(a.x*v-u*b.x)/det))
            }
            guard q.allSatisfy({$0.x.isFinite && $0.y.isFinite && observed($0)}),
                core.allSatisfy({Self.pointInside(q,$0)}) else{return no("repaired-corner-outside-source-probe-fresh-read-required",sides)}
            let turns=(0..<4).map{i -> CGFloat in let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4];return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)}
            guard turns.allSatisfy({$0>1e-8}) || turns.allSatisfy({$0 < -1e-8}) else{return no("invalid-repaired-convex-core",sides)}
            let oldEnclosed=actualOld.allSatisfy{Self.pointInside(q,$0)}
            return .init(polygon:q,receipt:["family":"outline-boundary-repair395","status":"measured-outer-rim-core-repair-non-admitted",
                "actual386Old":actualOld.map{[Double($0.x),Double($0.y)]},"geometricCore":core.map{[Double($0.x),Double($0.y)]},
                "repairedCore":q.map{[Double($0.x),Double($0.y)]},"coreEnclosed":true,"actual386PriorEnclosed":oldEnclosed,
                "sourceNativeOldRemainsActual386":true,"sourceNativeGraphRemainsActual386":true,
                "coreIsPriorOrForegroundOrOwnership":false,"allActualSourceForegroundPreservedClaimed":false,
                "nativeW":Double(nativeW),"edgeObservations":sides,"positiveWitnessCount":edgeWitnessCount,
                "noImageRereadPerCore":true,"rootGGBodySharedAcrossCores":true,"noGlobalPaletteBB":true,
                "actualNativeWholeDenseGGAndSemanticsRequired":true,"foreignPeerNewAcquisitionUnresolved":true,
                "neighborRetainedBoxAndQuoteAssociationRequired":true,"existingGT80FloorMustBeCheckedByParent":true,
                "recognitionFailureInferredFromHalo":false,"qualityAdopted":false,"erasureAuthority":"none",
                "ownershipChanged":false,"admissionGranted":false,"freshReadRequired":hasOpenBoundary,"unresolvedOpenRays":hasOpenBoundary,
                "partialEvidenceHypothesisOnly":true,"allSourceSupportObserved":false])
        }
        func summary()->[String:Any] {
            ["actualOld":actualOld.map{[Double($0.x),Double($0.y)]},"nativeW":Double(nativeW),
             "rootGGBodyPixels":bodyIndices.count,"actualPrivateBodyColourClasses":anchorColours.count,
             "cachedOrientedDirections":banks.count,"actualRayQueries":rayQueries,"pixelProbeQueries":sampleQueries,
             "budgets":["RGBA":600_000,"directions":32,"raysPerDirection":1024,"rootRays":32_768,"rootPixelQueries":8_000_000,"cores":128],
             "budgetExhausted":budgetExhausted,"oneOriginalRGBAAndRootBodyPerRoot":true,"everyRaySeedActualNativeFootprintAndGG":nativeAnchoredSeeds,
             "sourceBasisProbe":[Double(n0),Double(a0),Double(n1),Double(a1)],"admissionGranted":false]
        }
    }
}
