// Separate424 thin-body endpoint supplement. Frozen419/420/423 unchanged.
import Foundation
import CoreGraphics

// Independent419 three-phase observer. Does not call/change418 or use NN/GG.
// Positive is supplemental loss-veto evidence, never semantic/ownership rights.
enum SourceClosedOutlinedThinBody424 {
    typealias RGBA = NativeOCRSharedBoundary396.RGBA
    enum State: String { case closedContrast, unresolved }
    struct Pixel { let index:Int;let center:CGPoint;let rgb:[Int] }
    struct Side {
        let path:[Pixel]
        let fill:[Pixel]
        let fillToRimAA:[Pixel]
        let rim:[Pixel]
        let rimToOutsideAA:[Pixel]
        let outside:[Pixel]
    }
    struct Row {
        let offset:CGFloat
        let seed:Pixel?
        let low:Side?
        let high:Side?
        let fillThickness:CGFloat?
        let positive:Bool
        let reason:String
    }
    struct Result {
        let state:State
        let positive:Bool
        let query:Pixel?
        let rows:[Row]
        let receipt:[String:Any]
    }
    private struct Phase {let start:Int;let pixels:[Pixel]}
    static func assess(rgba:RGBA,queryPoint:CGPoint,normal:CGPoint,along:CGPoint,nativeW:CGFloat)->Result {
        // A real endpoint cannot have symmetric neighbours beyond the glyph.
        // Try fixed actual-source-pixel groups; no native width substitution.
        var unresolved:Result?
        for offsets in [[CGFloat(-1),0,1],[0,1,2],[0,-1,-2]] {
            let r=assessRows(rgba:rgba,queryPoint:queryPoint,normal:normal,along:along,nativeW:nativeW,offsets:offsets)
            if r.positive{return r};unresolved=r
        }
        return unresolved!
    }
    private static func assessRows(rgba r:RGBA,queryPoint:CGPoint,normal n:CGPoint,
                       along a:CGPoint,nativeW mw:CGFloat,offsets:[CGFloat])->Result {
        func unknown(_ status:String,_ query:Pixel?=nil,_ rows:[Row]=[])->Result {
            .init(state:.unresolved,positive:false,query:query,rows:rows,
                receipt:["family":"source-closed-outlined-thin-body424","status":status,
                    "NNOrGGSeedUsed":false,"certifiedBackground":false,"semanticBodyClaimed":false,
                    "ownershipClaimed":false,"erasureAuthority":"none","admissionGranted":false])
        }
        let w=r.width,h=r.height
        guard w>2,h>2,w<=600_000/h,w<=Int.max/4,r.bytesPerRow>=w*4,r.bytesPerRow<=Int.max/h,
              r.bytes.count==h*r.bytesPerRow,[r.origin,queryPoint,n,a].allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              mw.isFinite,mw>0,mw<100_000,abs(hypot(n.x,n.y)-1)<1e-6,
              abs(hypot(a.x,a.y)-1)<1e-6,abs(n.x*a.x+n.y*a.y)<1e-6 else{return unknown("invalid-source-query")}
        func world(_ i:Int)->CGPoint {.init(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5)}
        func rgb(_ i:Int)->[Int] {let k=(i/w)*r.bytesPerRow+(i%w)*4;return (0..<3).map{Int(r.bytes[k+$0])}}
        func pixel(_ i:Int)->Pixel {.init(index:i,center:world(i),rgb:rgb(i))}
        func distance(_ x:[Int],_ y:[Int])->Int {(0..<3).map{abs(x[$0]-y[$0])}.max()!}
        func mean(_ p:[Pixel])->[Int] {(0..<3).map{k in p.reduce(0){$0+$1.rgb[k]}/max(1,p.count)}}
        func sample(_ p:CGPoint)->Int? {
            let x=floor(p.x-r.origin.x),y=floor(p.y-r.origin.y)
            guard x>=0,x<CGFloat(w),y>=0,y<CGFloat(h) else{return nil}
            let i=Int(y)*w+Int(x),k=Int(y)*r.bytesPerRow+Int(x)*4
            return r.bytes[k+3]==255 ? i:nil
        }
        func span(_ p:[Pixel])->CGFloat {
            guard !p.isEmpty else{return 0}
            let z=p.map{$0.center.x*n.x+$0.center.y*n.y}
            return z.max()!-z.min()!+abs(n.x)+abs(n.y)
        }
        func stable(_ p:[Pixel])->Bool {
            !p.isEmpty && (0..<3).allSatisfy{k in let z=p.map{$0.rgb[k]};return z.max()!-z.min()!<=8}
        }
        func interpolation(_ points:[Pixel],_ from:[Int],_ to:[Int])->Bool {
            points.allSatisfy{p in (0..<3).allSatisfy{k in
                p.rgb[k]>=min(from[k],to[k])-8 && p.rgb[k]<=max(from[k],to[k])+8
            }}
        }
        guard let index=sample(queryPoint) else{return unknown("query-outside-opaque-capture")}
        let query=pixel(index),limit=min(512,max(24,Int(ceil(mw*2))+16))
        let maxAA=max(CGFloat(2),min(8,ceil(mw*0.12)))
        let maxRim=max(CGFloat(2),min(12,ceil(mw*0.4)))
        let minFill=CGFloat(1),maxFill=max(CGFloat(3),mw*2)
        func side(_ seed:Int,_ sign:CGFloat)->Side? {
            let start=world(seed),initial=rgb(seed)
            var path=[pixel(seed)],last=seed
            for step in 1...limit {
                guard let j=sample(.init(x:start.x+n.x*sign*CGFloat(step)*0.75,
                                         y:start.y+n.y*sign*CGFloat(step)*0.75)) else{break}
                if j != last{path.append(pixel(j));last=j}
            }
            var fill:[Pixel]=[]
            for p in path {if distance(initial,p.rgb)>16{break};fill.append(p)}
            guard !fill.isEmpty,fill.count<path.count else{return nil}
            let rest=Array(path.dropFirst(fill.count))
            var phases:[Phase]=[],cursor=0
            while cursor<rest.count {
                let first=cursor,colour=rest[first].rgb;cursor += 1
                while cursor<rest.count && distance(colour,rest[cursor].rgb)<=8{cursor += 1}
                phases.append(.init(start:first,pixels:Array(rest[first..<cursor])))
            }
            var best:(Int,Side)?
            for ri in phases.indices {
                let rim=phases[ri],before=Array(rest[..<rim.start]),rc=mean(rim.pixels)
                if span(before)>maxAA{break}
                guard span(rim.pixels)<=maxRim,stable(rim.pixels),distance(initial,rc)>=40,
                      interpolation(before,initial,rc) else{continue}
                if ri+1>=phases.count{continue}
                for oi in (ri+1)..<phases.count {
                    let outside=phases[oi]
                    let after=Array(rest[(rim.start+rim.pixels.count)..<outside.start])
                    if span(after)>maxAA{break}
                    // A recurring fill plateau is not the outside behind a rim.
                    if outside.pixels.count>=2 && distance(initial,mean(outside.pixels))<32{break}
                    guard outside.pixels.count>=4 else{continue}
                    let proof=Array(outside.pixels.prefix(4)),oc=mean(proof)
                    guard Set(proof.map(\.index)).count==4,stable(proof),distance(initial,oc)>=32,
                          distance(rc,oc)>=32,interpolation(after,rc,oc) else{continue}
                    let candidate=Side(path:Array(path.prefix(fill.count+outside.start+4)),fill:fill,
                        fillToRimAA:before,rim:rim.pixels,rimToOutsideAA:after,outside:proof)
                    let strength=min(distance(initial,rc),distance(rc,oc))*1024+min(32,rim.pixels.count)
                    if best==nil || strength>best!.0{best=(strength,candidate)}
                }
            }
            return best?.1
        }
        var rows:[Row]=[],seen=Set<Int>()
        for offset in offsets {
            let requested=CGPoint(x:query.center.x+a.x*offset,y:query.center.y+a.y*offset)
            guard let i=sample(requested),seen.insert(i).inserted else {
                rows.append(.init(offset:offset,seed:nil,low:nil,high:nil,fillThickness:nil,positive:false,reason:"row-open-or-not-distinct"));continue
            }
            let p=pixel(i)
            guard distance(p.rgb,query.rgb)<=16 else {
                rows.append(.init(offset:offset,seed:p,low:nil,high:nil,fillThickness:nil,positive:false,reason:"row-not-query-fill"));continue
            }
            let low=side(i,-1),high=side(i,1)
            guard let low,let high else {
                rows.append(.init(offset:offset,seed:p,low:low,high:high,fillThickness:nil,positive:false,reason:"no-two-sided-three-phase-closure"));continue
            }
            let thickness=span(low.fill+high.fill)
            let fillStable=(0..<3).allSatisfy{k in let v=(low.fill+high.fill).map{$0.rgb[k]};return v.max()!-v.min()!<=20}
            let coloursMatch=distance(mean(low.rim),mean(high.rim))<=16 && distance(mean(low.outside),mean(high.outside))<=12
            let widthsMatch=abs(span(low.rim)-span(high.rim))<=max(CGFloat(2),max(span(low.rim),span(high.rim))*0.5)
            let positive=fillStable && coloursMatch && widthsMatch && thickness>=minFill && thickness<=maxFill
            rows.append(.init(offset:offset,seed:p,low:low,high:high,fillThickness:thickness,positive:positive,
                reason:positive ? "paired-fill-rim-exterior-closure":"unmatched-rim-outside-width-or-fill-thickness"))
        }
        let closed=rows.filter(\.positive)
        guard rows.contains(where:{$0.offset==0 && $0.positive}),closed.count==3 else{return unknown("no-repeated-outlined-query-closure",query,rows)}
        let rim=mean(closed[0].low!.rim),outside=mean(closed[0].low!.outside)
        guard closed.allSatisfy({distance(mean($0.low!.rim),rim)<=16 && distance(mean($0.high!.rim),rim)<=16 &&
                                distance(mean($0.low!.outside),outside)<=12 && distance(mean($0.high!.outside),outside)<=12}) else{
            return unknown("inconsistent-rim-or-outside-across-rows",query,rows)
        }
        let rimPixels=Set(closed.flatMap{$0.low!.rim+$0.high!.rim}.map(\.index))
        guard rimPixels.count>=4 else{return unknown("insufficient-distinct-repeated-rim-pixels",query,rows)}
        return .init(state:.closedContrast,positive:true,query:query,rows:rows,
            receipt:["family":"source-closed-outlined-thin-body424","status":"positive-repeated-three-phase-closure",
                "positiveRows":closed.count,"actualQueryRowClosed":true,"distinctObservedRimPixels":rimPixels.count,
                "outsidePixelsPerSide":4,"minimumFillThickness":Double(minFill),"maximumRimThickness":Double(maxRim),
                "maximumAAStageThickness":Double(maxAA),"fillRimContrastMinimum":40,
                "fillOutsideContrastMinimum":32,"rimOutsideContrastMinimum":32,
                "pairedRimColoursMatch":true,"pairedOutsideColoursMatch":true,"pairedRimWidthsBounded":true,
                "rimObservedOnAtLeastTwoRows":true,"rimPerSideMayBeSinglePixelIfRepeated":true,
                "brightnessOrderingUsed":false,"NNOrGGSeedUsed":false,"wholeCCPainted":false,
                "positiveSupplementalLossVetoOnly":true,"certifiedBackground":false,"semanticBodyClaimed":false,
                "ownershipClaimed":false,"erasureAuthority":"none","geometryProduced":false,"admissionGranted":false])
    }
}
