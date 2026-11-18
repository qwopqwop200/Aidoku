import Foundation
import CoreGraphics

/// Live source-pixel normal head for explicit V3. Frozen D geometry, not an
/// undilated-glyph claim or a replacement of existing V2 outputs. Caller owns
/// actual V3 emission. No paths, page IDs, GT, decoded text, or mask persistence.
@available(iOS 18.0, *)
enum NativeOCRSourceStrokeGeometry {
    typealias G = NativeOCRIndividualGeometryHypotheses
    typealias Factory = NativeMainRemovalSourceFactory
    enum RFKind: String, Codable, Sendable { case text, soundEffect }
    struct SourceRFBound: Codable, Sendable {
        let kind: RFKind
        let bounds: CGRect
        let confidence: Double
    }
    enum Applicability: Sendable { case frozenD, trainFrozenV3Pruning }
    struct Proof: Codable, Sendable {
        let producer: String
        let ownerID: String
        let sourceIndex: Int
        let sourceParent: Int
        let sourceMembers: Set<Int>
        let cropBounds: [Int]
        let originalPolygon: [G.Point]
        let observationPolygon: [G.Point]
        let nativeMeasuredRadius: Int
        let fontPixels: Double
        let normalSpanBefore: Double
        let normalSpanAfter: Double
        let expansionRatio: Double
        let ownedMaskPixels: Int
        let dehaloMaskPixels: Int
        let fullMaskPixels: Int
        let ownedComponents: Int
        let dehaloOwnedFraction: Double
        let dbAlongSpanRatio: Double
        let rfTextConfidenceCoverage: Double
        let rfEffectConfidenceCoverage: Double
        let ambiguousComponents: Int
        let candidateComponents: Int
        let seedRunCoordinates: String
        let ownershipScope: String
    }
    struct Measurement: Codable, Sendable {
        let refinement: G.Refinement
        let proof: Proof
    }
    struct Production: Sendable {
        let measurements: [Measurement]
        let reasons: [String]
        var refinements: [G.Refinement] { measurements.map(\.refinement) }
    }
    private struct V {
        let x: Double, y: Double
        func dot(_ p: CGPoint) -> Double { x * Double(p.x) + y * Double(p.y) }
    }
    private struct Basis {
        let along: V, normal: V
        let nlo: Double, nhi: Double, alo: Double, ahi: Double
        init?(_ p: [CGPoint]) {
            guard p.count == 4, p.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else { return nil }
            var best = 0, length = -Double.infinity
            for i in 0..<4 {
                let q = p[(i+1)%4], d = pow(Double(q.x-p[i].x),2)+pow(Double(q.y-p[i].y),2)
                if d > length { best=i; length=d }
            }
            guard length > 0 else { return nil }
            let q=p[(best+1)%4], a=V(x:Double(q.x-p[best].x)/sqrt(length),y:Double(q.y-p[best].y)/sqrt(length))
            let n=V(x:-a.y,y:a.x), ns=p.map(n.dot), als=p.map(a.dot)
            guard ns.max()! > ns.min()!, als.max()! > als.min()! else { return nil }
            along=a;normal=n;nlo=ns.min()!;nhi=ns.max()!;alo=als.min()!;ahi=als.max()!
        }
        func fit(_ p:[CGPoint], low:Double, high:Double)->[CGPoint] {
            p.map { point in
                let n=normal.dot(point), d=abs(n-nlo)<=abs(n-nhi) ? low-nlo : high-nhi
                return CGPoint(x:Double(point.x)+d*normal.x,y:Double(point.y)+d*normal.y)
            }
        }
    }

    /// Invoke once for V3 before recognition gating, retaining the measurement
    /// evidence alongside its immutable refinement context. OFF unless enabled.
    static func produce(requestID: String, originals: [NativeCoreMLDetectionBox],
                        frame: NativeOCRRGBAFrame, sourceRFBounds: [SourceRFBound] = [],
                        enabled: Bool = false, applicability: Applicability = .frozenD,
                        cancellationCheck: () throws -> Void = {}) throws -> Production {
        guard enabled else { return .init(measurements:[],reasons:["disabled"]) }
        guard !requestID.isEmpty, originals.count<=4096 else {
            return .init(measurements:[],reasons:["invalid-request-or-source-budget"])
        }
        var output:[Measurement]=[], reasons:[String]=[]
        for (index,box) in originals.enumerated() {
            try cancellationCheck()
            guard let seed=box.detectorSeedEvidence,seed.isValid,
                  seed.sourceWidth==frame.width,seed.sourceHeight==frame.height,
                  !seed.components.isEmpty,let basis=Basis(box.polygon) else {
                reasons.append("source-\(index)-missing-invalid-or-unowned-seed");continue
            }
            let span=basis.nhi-basis.nlo
            let observation=basis.fit(box.polygon,low:basis.nlo-0.15*span,high:basis.nhi+0.15*span)
            let xs=observation.map{Double($0.x)},ys=observation.map{Double($0.y)}
            let bx0=xs.min()!,bx1=xs.max()!,by0=ys.min()!,by1=ys.max()!
            let x0=max(0,Int(ceil(bx0-0.15*(bx1-bx0)))),y0=max(0,Int(ceil(by0-0.15*(by1-by0))))
            let x1=min(frame.width,Int(floor(bx1+0.15*(bx1-bx0)))),y1=min(frame.height,Int(floor(by1+0.15*(by1-by0))))
            let w=x1-x0,h=y1-y0
            guard w>0,h>0,w<=Factory.NativeSourceRoleMask.maximumROIPixels/h else {
                reasons.append("source-\(index)-native-ROI-budget");continue
            }
            var own=raster(seed.components,seed:seed,x0:x0,y0:y0,width:w,height:h)
            var foreign=[UInt8](repeating:0,count:w*h)
            for (otherIndex,other) in originals.enumerated() where otherIndex != index {
                guard let packet=other.detectorSeedEvidence,packet.isValid,
                      packet.sourceWidth==frame.width,packet.sourceHeight==frame.height else { continue }
                let otherMask=raster(packet.components,seed:packet,x0:x0,y0:y0,width:w,height:h)
                for i in foreign.indices { foreign[i] |= otherMask[i] }
            }
            for i in own.indices where foreign[i] != 0 { own[i]=0 }
            guard own.contains(1) else { reasons.append("source-\(index)-no-exclusive-owned-core");continue }
            let anchor=Factory.NativeSourceRoleMask.dilate(own,width:w,height:h,radius:1)
            var rgb=[UInt8](repeating:0,count:w*h*3)
            for y in 0..<h { for x in 0..<w {
                let s=(y+y0)*frame.bytesPerRow+(x+x0)*4,t=(y*w+x)*3
                rgb[t]=frame.bytes[s];rgb[t+1]=frame.bytes[s+1];rgb[t+2]=frame.bytes[s+2]
            }}
            let local=box.polygon.map{CGPoint(x:$0.x-CGFloat(x0),y:$0.y-CGFloat(y0))}
            do {
                let source=Factory.NativeCurrentMaskCaller.Source(width:w,height:h,rgb:rgb,revision:"live-source-normal-dehalo-v1")
                let owner=Factory.NativeCurrentMaskCaller.Owner(id:"source-owner",polygon:local,fontPixels:span,translated:true,balloon:false)
                let base=try Factory.NativeSourceBaseMask.extract(source:source,owners:[owner])
                let completed=try Factory.NativeChromaticMaskCompletion.complete(rgb:rgb,width:w,height:h,base:base.mask,
                    protection:[UInt8](repeating:0,count:w*h),owners:[.init(id:owner.id,polygon:local,fontPixels:span)])
                guard let radius=base.audit.compactMap({$0["radiusSourcePixels"] as? Int}).first else {
                    reasons.append("source-\(index)-missing-native-radius");continue
                }
                let reduced=erode(completed.mask,width:w,height:h,radius:radius)
                let measured=measure(reduced,anchor:anchor,foreign:foreign,width:w,height:h,x0:x0,y0:y0,basis:basis)
                guard measured.pixels>0 else { reasons.append("source-\(index)-no-owned-dehalo-support");continue }
                let low=min(basis.nlo,measured.low),high=max(basis.nhi,measured.high)
                guard high-low>span+1e-8 else { reasons.append("source-\(index)-unchanged");continue }
                let polygon=basis.fit(box.polygon,low:low,high:high)
                let dbAlong=seed.components.flatMap(\.runs).flatMap { run->[Double] in
                    let sx=Double(seed.sourceWidth)/Double(seed.mapFullWidth),sy=Double(seed.sourceHeight)/Double(seed.mapFullHeight)
                    return [CGPoint(x:Double(run.x)*sx,y:Double(run.y)*sy),CGPoint(x:Double(run.x+run.count)*sx,y:Double(run.y)*sy),
                            CGPoint(x:Double(run.x+run.count)*sx,y:Double(run.y+1)*sy),CGPoint(x:Double(run.x)*sx,y:Double(run.y+1)*sy)].map(basis.along.dot)
                }
                let dbAlongRatio=(dbAlong.max()!-dbAlong.min()!)/(basis.ahi-basis.alo)
                let rf=rfCoverage(box.polygon,bounds:sourceRFBounds)
                let reducedPixels=reduced.filter{$0 != 0}.count
                let ownedFraction=Double(measured.pixels)/Double(max(1,reducedPixels))
                if applicability == .trainFrozenV3Pruning &&
                    !(seed.mapOriginX==0 && seed.mapOriginY==0 && rf.0>=0.30524998903274536 && ownedFraction<=0.9996665555185061 && dbAlongRatio>=0.7163053582182364) {
                    reasons.append("source-\(index)-source-only-pruning");continue
                }
                let record=G.Record(requestID:requestID,sourceIndex:index,sourceParent:index,sourceMembers:[index],
                    alternativeID:"source-stroke-dehalo-v1/\(index)",origin:.sourceRefinement,originalDetectorIndex:index,
                    polygon:polygon.map{.init(x:Double($0.x),y:Double($0.y))})
                let proof=Proof(producer:"native-source-base-completion-measured-radius-dehalo-v1",ownerID:seed.ownerID,
                    sourceIndex:index,sourceParent:index,sourceMembers:[index],cropBounds:[x0,y0,x1,y1],
                    originalPolygon:box.polygon.map{.init(x:Double($0.x),y:Double($0.y))},
                    observationPolygon:observation.map{.init(x:Double($0.x),y:Double($0.y))},nativeMeasuredRadius:radius,
                    fontPixels:span,normalSpanBefore:span,normalSpanAfter:high-low,expansionRatio:(high-low-span)/span,
                    ownedMaskPixels:measured.pixels,dehaloMaskPixels:reducedPixels,fullMaskPixels:completed.mask.filter{$0 != 0}.count,
                    ownedComponents:measured.components,dehaloOwnedFraction:ownedFraction,dbAlongSpanRatio:dbAlongRatio,
                    rfTextConfidenceCoverage:rf.0,rfEffectConfidenceCoverage:rf.1,
                    ambiguousComponents:seed.ambiguousComponents?.count ?? 0,candidateComponents:seed.candidateComponents?.count ?? 0,
                    seedRunCoordinates:"full-grid; mapOrigin NOT added",
                    ownershipScope:"frozen-D core-anchor association, NOT whole-glyph ownership certification; uncertain packets retained as proof")
                output.append(.init(refinement:.init(head:.normal,record:record),proof:proof))
            } catch {
                reasons.append("source-\(index)-native-mask-failure-\(String(describing:error))")
            }
        }
        return .init(measurements:output,reasons:reasons)
    }
    /// FULL detector-grid coordinates. Unlike the old Python latent path, never add mapOrigin.
    private static func raster(_ components:[NativeOCRDetectorSeedEvidence.Component],seed:NativeOCRDetectorSeedEvidence,
                               x0:Int,y0:Int,width:Int,height:Int)->[UInt8] {
        var out=[UInt8](repeating:0,count:width*height)
        let sx=Double(seed.sourceWidth)/Double(seed.mapFullWidth),sy=Double(seed.sourceHeight)/Double(seed.mapFullHeight)
        for component in components { for run in component.runs {
            let a=max(0,Int(floor(Double(run.x)*sx))-x0),b=min(width,Int(ceil(Double(run.x+run.count)*sx))-x0)
            let c=max(0,Int(floor(Double(run.y)*sy))-y0),d=min(height,Int(ceil(Double(run.y+1)*sy))-y0)
            if b>a && d>c { for y in c..<d { for x in a..<b { out[y*width+x]=1 } } }
        }}
        return out
    }
    /// Exact square erosion with zero boundary, O(ROI pixels), matching cv2 frozen D.
    private static func erode(_ mask:[UInt8],width:Int,height:Int,radius:Int)->[UInt8] {
        guard radius>0 else { return mask.map{$0 == 0 ? 0:1} }
        var horizontal=[UInt8](repeating:0,count:mask.count),out=horizontal
        for y in 0..<height {
            var prefix=[Int](repeating:0,count:width+1)
            for x in 0..<width { prefix[x+1]=prefix[x]+(mask[y*width+x] == 0 ? 1:0) }
            if width>2*radius { for x in radius..<(width-radius) where prefix[x+radius+1]-prefix[x-radius]==0 { horizontal[y*width+x]=1 } }
        }
        for x in 0..<width {
            var prefix=[Int](repeating:0,count:height+1)
            for y in 0..<height { prefix[y+1]=prefix[y]+(horizontal[y*width+x] == 0 ? 1:0) }
            if height>2*radius { for y in radius..<(height-radius) where prefix[y+radius+1]-prefix[y-radius]==0 { out[y*width+x]=1 } }
        }
        return out
    }
    private static func measure(_ mask:[UInt8],anchor:[UInt8],foreign:[UInt8],width:Int,height:Int,x0:Int,y0:Int,basis:Basis)
        ->(low:Double,high:Double,pixels:Int,components:Int) {
        var seen=mask,low=Double.infinity,high = -Double.infinity,pixels=0,components=0
        let half=0.5*(abs(basis.normal.x)+abs(basis.normal.y))
        for start in seen.indices where seen[start] != 0 {
            var stack=[start],touches=false,competing=false,censored=false,count=0,lo=Double.infinity,hi = -Double.infinity
            seen[start]=0
            while let i=stack.popLast() {
                let x=i%width,y=i/width;touches = touches || anchor[i] != 0;competing = competing || foreign[i] != 0
                censored = censored || x==0 || y==0 || x==width-1 || y==height-1
                let point=CGPoint(x:Double(x+x0)+0.5,y:Double(y+y0)+0.5),along=basis.along.dot(point)
                if along>=basis.alo && along<=basis.ahi {let n=basis.normal.dot(point);lo=min(lo,n-half);hi=max(hi,n+half);count+=1}
                for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    if xx>=0 && xx<width && yy>=0 && yy<height {
                        let j=yy*width+xx
                        if seen[j] != 0 {seen[j]=0;stack.append(j)}
                    }
                }}
            }
            if touches && !competing && !censored && count>0 {low=min(low,lo);high=max(high,hi);pixels+=count;components+=1}
        }
        return (low,high,pixels,components)
    }
    private static func rfCoverage(_ polygon:[CGPoint],bounds:[SourceRFBound])->(Double,Double) {
        let subject=polygon.map{G.Point(x:Double($0.x),y:Double($0.y))};let area=abs(shoelace(subject));guard area>0 else{return (0,0)}
        var text=0.0,effect=0.0
        for bound in bounds where bound.confidence.isFinite && (0...1).contains(bound.confidence) && !bound.bounds.isNull && !bound.bounds.isInfinite &&
            bound.bounds.minX.isFinite && bound.bounds.minY.isFinite && bound.bounds.maxX.isFinite && bound.bounds.maxY.isFinite {
            var clipped=subject;let r=bound.bounds
            for (axis,value,greater) in [(0,Double(r.minX),true),(0,Double(r.maxX),false),(1,Double(r.minY),true),(1,Double(r.maxY),false)] {
                let old=clipped;clipped=[];guard !old.isEmpty else{break}
                func coordinate(_ p:G.Point)->Double{axis==0 ? p.x:p.y}
                func inside(_ p:G.Point)->Bool{greater ? coordinate(p)>=value:coordinate(p)<=value}
                for i in old.indices {
                    let a=old[i],b=old[(i+1)%old.count],ai=inside(a),bi=inside(b)
                    func intersection()->G.Point {
                        let d=coordinate(b)-coordinate(a),t=d==0 ? 0:(value-coordinate(a))/d
                        return .init(x:a.x+(b.x-a.x)*t,y:a.y+(b.y-a.y)*t)
                    }
                    if ai && bi {clipped.append(b)} else if ai && !bi {clipped.append(intersection())}
                    else if !ai && bi {clipped.append(intersection());clipped.append(b)}
                }
            }
            let score=bound.confidence*min(1,abs(shoelace(clipped))/area)
            if bound.kind == .text {text=max(text,score)} else {effect=max(effect,score)}
        }
        return (text,effect)
    }
    private static func shoelace(_ p:[G.Point])->Double {
        guard p.count>=3 else{return 0};var a=0.0
        for i in p.indices {let q=p[(i+1)%p.count];a+=p[i].x*q.y-q.x*p[i].y};return a/2
    }
}
