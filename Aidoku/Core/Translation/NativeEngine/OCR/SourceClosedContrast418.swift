import Foundation
import CoreGraphics

// Seed-free, finite local contrast observation. Positive is a supplemental loss
// VETO cue only: no semantic glyph, erasure, geometry, or ownership authority.
enum SourceClosedContrast418 {
    typealias RGBA = NativeOCRSharedBoundary396.RGBA
    enum State: String { case closedContrast, literalExterior, unresolved }
    struct Pixel {
        let index: Int
        let center: CGPoint
        let rgb: [Int]
    }
    struct Side {
        let path: [Pixel]
        let fill: [Pixel]
        let transition: [Pixel]
        let outside: [Pixel] // Four distinct, actually sampled stable pixels.
    }
    struct Row {
        let requestedOffset: CGFloat
        let requestedPoint: CGPoint
        let seed: Pixel?
        let low: Side?
        let high: Side?
        let positive: Bool
        let fillThickness: CGFloat?
        let reason: String
    }
    struct Result {
        let state: State
        let positive: Bool
        let query: Pixel?
        let rows: [Row]
        let receipt: [String: Any]
    }
    static func assess(rgba r: RGBA, queryPoint: CGPoint, normal n: CGPoint,
                       along a: CGPoint, nativeW: CGFloat) -> Result {
        func unresolved(_ reason: String, query: Pixel? = nil, rows: [Row] = []) -> Result {
            .init(state: .unresolved, positive: false, query: query, rows: rows,
                receipt: ["family":"source-closed-contrast418","status":reason,
                    "NNOrGGSeedUsed":false,"certifiedBackground":false,"ownershipClaimed":false,
                    "erasureAuthority":"none","admissionGranted":false,"queryPoint":[Double(queryPoint.x),Double(queryPoint.y)]])
        }
        let w=r.width,h=r.height
        guard w>2,h>2,w<=600_000/h,w<=Int.max/4,r.bytesPerRow>=w*4,
              r.bytesPerRow<=Int.max/h,r.bytes.count==h*r.bytesPerRow,
              [r.origin,queryPoint,n,a].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              nativeW.isFinite,nativeW>0,nativeW<100_000,
              abs(hypot(n.x,n.y)-1)<1e-6,abs(hypot(a.x,a.y)-1)<1e-6,
              abs(n.x*a.x+n.y*a.y)<1e-6 else{return unresolved("invalid-source-query")}
        func world(_ i:Int)->CGPoint {.init(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func rgb(_ i:Int)->[Int] {let k=(i/w)*r.bytesPerRow+(i%w)*4;return (0..<3).map{Int(r.bytes[k+$0])}}
        func pixel(_ i:Int)->Pixel {.init(index:i,center:world(i),rgb:rgb(i))}
        func distance(_ x:[Int],_ y:[Int])->Int {(0..<3).map{abs(x[$0]-y[$0])}.max()!}
        func mean(_ pixels:[Pixel])->[Int] {(0..<3).map{k in pixels.reduce(0){$0+$1.rgb[k]}/max(1,pixels.count)}}
        func sample(_ p:CGPoint)->Int? {
            let x=floor(p.x-r.origin.x),y=floor(p.y-r.origin.y)
            guard x>=0,x<CGFloat(w),y>=0,y<CGFloat(h) else{return nil}
            let i=Int(y)*w+Int(x),k=Int(y)*r.bytesPerRow+Int(x)*4
            return r.bytes[k+3]==255 ? i:nil
        }
        guard let queryIndex=sample(queryPoint) else{return unresolved("query-outside-opaque-capture")}
        let query=pixel(queryIndex),reference=query.rgb
        let rayLimit=min(512,max(12,Int(ceil(nativeW*1.5))+8))
        let maxTransition=max(CGFloat(2),min(12,ceil(nativeW*0.12)))
        let minimumThickness=max(CGFloat(2),nativeW*0.20)
        let maximumThickness=max(CGFloat(3),nativeW*2)
        func span(_ points:[Pixel])->CGFloat {
            guard !points.isEmpty else{return 0}
            let q=points.map{$0.center.x*n.x+$0.center.y*n.y}
            return q.max()!-q.min()!+abs(n.x)+abs(n.y)
        }
        func stable(_ p:[Pixel])->Bool {
            guard p.count==4,Set(p.map(\.index)).count==4 else{return false}
            for channel in 0..<3 {
                let values=p.map{$0.rgb[channel]}
                if values.max()!-values.min()!>8{return false}
            }
            return true
        }
        func side(_ seed:Int,_ sign:CGFloat)->Side? {
            let start=world(seed),initial=rgb(seed)
            var path=[pixel(seed)],fill=path,transition:[Pixel]=[],last=seed,exited=false
            for step in 1...rayLimit {
                guard let i=sample(.init(x:start.x+n.x*sign*CGFloat(step)*0.75,
                                         y:start.y+n.y*sign*CGFloat(step)*0.75)) else{return nil}
                if i==last{continue};last=i
                let p=pixel(i);path.append(p)
                if !exited && distance(initial,p.rgb)<=16 {
                    fill.append(p);continue
                }
                exited=true
                transition.append(p)
                if span(transition)>maxTransition+abs(n.x)+abs(n.y){return nil}
                guard distance(initial,p.rgb)>=40 else{continue}
                var outside=[p],outsideLast=i
                for k in 1...12 {
                    guard let j=sample(.init(x:p.center.x+n.x*sign*CGFloat(k)*0.75,
                                             y:p.center.y+n.y*sign*CGFloat(k)*0.75)) else{return nil}
                    if j==outsideLast{continue};outsideLast=j;outside.append(pixel(j))
                    if outside.count==4{break}
                }
                guard stable(outside),distance(initial,mean(outside))>=40 else{return nil}
                let aa=Array(transition.dropLast())
                // Literal bounded AA interpolation, not gradient-colour chaining.
                for z in aa {
                    for channel in 0..<3 {
                        let lo=min(initial[channel],mean(outside)[channel])-8
                        let hi=max(initial[channel],mean(outside)[channel])+8
                        if z.rgb[channel]<lo || z.rgb[channel]>hi{return nil}
                    }
                }
                return .init(path:path+Array(outside.dropFirst()),fill:fill,transition:aa,outside:outside)
            }
            return nil
        }
        var rows:[Row]=[],seeds=Set<Int>()
        for fraction in [CGFloat(-0.2),0,0.2] {
            let offset=fraction*nativeW
            let requested=CGPoint(x:query.center.x+a.x*offset,y:query.center.y+a.y*offset)
            guard let i=sample(requested),seeds.insert(i).inserted else {
                rows.append(.init(requestedOffset:offset,requestedPoint:requested,seed:nil,low:nil,high:nil,
                    positive:false,fillThickness:nil,reason:"row-capture-open-or-not-distinct"));continue
            }
            let p=pixel(i)
            guard distance(reference,p.rgb)<=16 else {
                rows.append(.init(requestedOffset:offset,requestedPoint:requested,seed:p,low:nil,high:nil,
                    positive:false,fillThickness:nil,reason:"offset-row-not-same-query-fill"));continue
            }
            let low=side(i,-1),high=side(i,1)
            guard let low,let high else {
                rows.append(.init(requestedOffset:offset,requestedPoint:requested,seed:p,low:low,high:high,
                    positive:false,fillThickness:nil,reason:"no-two-sided-stable-closure"));continue
            }
            let allFill=low.fill+high.fill,thickness=span(allFill)
            let fillRangeOK=(0..<3).allSatisfy{k in
                let values=allFill.map{$0.rgb[k]};return values.max()!-values.min()!<=20
            }
            let outsideMatch=distance(mean(low.outside),mean(high.outside))<=12
            let good=fillRangeOK && outsideMatch && thickness>=minimumThickness && thickness<=maximumThickness
            rows.append(.init(requestedOffset:offset,requestedPoint:requested,seed:p,low:low,high:high,
                positive:good,fillThickness:thickness,
                reason:good ? "actual-bilateral-fill-and-consistent-stable-exterior":"fill-too-thin-wide-gradient-or-opposite-exteriors-disagree"))
        }
        let positiveRows=rows.filter(\.positive)
        // The actual query row must close: two offset rows cannot manufacture
        // foreground evidence for a disconnected/open query point in the middle.
        guard rows.contains(where:{$0.requestedOffset==0 && $0.positive}),positiveRows.count>=2 else {
            return unresolved("no-repeated-finite-query-closure",query:query,rows:rows)
        }
        let exteriorReference=mean(positiveRows[0].low!.outside)
        guard positiveRows.allSatisfy({distance(mean($0.low!.outside),exteriorReference)<=12 &&
                                      distance(mean($0.high!.outside),exteriorReference)<=12}) else {
            return unresolved("different-exterior-colours-across-rows",query:query,rows:rows)
        }
        return .init(state:.closedContrast,positive:true,query:query,rows:rows,
            receipt:["family":"source-closed-contrast418","status":"positive-finite-closed-contrast",
                "positiveRows":positiveRows.count,"actualQueryRowClosed":true,
                "rowOffsetsNativeW":[-0.2,0,0.2],"outsideDistinctPixelsPerSide":4,
                "minimumFillThickness":Double(minimumThickness),"maximumFillThickness":Double(maximumThickness),
                "minimumFillThicknessNativeW":0.20,"fixedReferenceFillTolerance":16,
                "minimumExteriorContrast":40,"exteriorPlateauMaxRGBRange":8,
                "oppositeExteriorMaxRGBDifference":12,"NNOrGGSeedUsed":false,
                "brightnessOrderingUsed":false,"semanticBodyClaimed":false,"ownershipClaimed":false,
                "positiveSupplementalLossVetoOnly":true,"certifiedBackground":false,
                "erasureAuthority":"none","geometryProduced":false,"admissionGranted":false])
    }
}
