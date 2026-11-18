import CoreGraphics
import Foundation

/// Sparse retained alpha, including bands and shadows. Within each contour
/// span, only a row's outermost occupied pixels constrain a translation;
/// transparent corners of the overall glyph rectangle impose no constraint.
enum NativeInkContourClearance {
    struct Row {let y:Int;let left:Int;let right:Int}
    struct Plan {
        let origin:CGPoint
        let margin:Int
        let oldMargin:Int
        let sourceCostBefore:CGFloat
        let sourceCostAfter:CGFloat
    }
    static func envelope(_ input:[Row])->[Row] {
        var result:[Row]=[]
        for row in input {
            if let last=result.last,last.y==row.y {
                result[result.count-1] = .init(y:row.y,left:min(last.left,row.left),right:max(last.right,row.right))
            } else {result.append(row)}
        }
        return result
    }
    /// Euclidean edge clearance between sparse paragraph row envelopes. The
    /// rectangle's empty corners must not veto a readable staggered paragraph.
    static func peerMargin(rows:[Row],peer:[Row],dx:Int=0,dy:Int=0,limit:Int)->CGFloat {
        guard limit>0,limit<=512,!rows.isEmpty,!peer.isEmpty else{return 0}
        var best=Double(limit*limit),start=0
        for row in rows {
            let y=row.y+dy,left=row.left+dx,right=row.right+dx
            while start<peer.count,peer[start].y<y-limit-1 {start+=1}
            var j=start
            while j<peer.count,peer[j].y<=y+limit+1 {
                let p=peer[j],vertical=max(0,abs(y-p.y)-1)
                let horizontal=max(0,max(p.left-right,left-p.right))
                best=min(best,Double(horizontal*horizontal+vertical*vertical))
                if best==0 {return 0};j+=1
            }
        }
        return CGFloat(sqrt(best))
    }
    /// Feasible integer horizontal shifts, retaining disjoint mask lobes.
    /// Rows may be conservative envelopes; no gaps between mask intervals are filled.
    /// More than 128 intermediate intervals fails closed rather than dropping holes.
    static func feasibleIntervals(rows:[Row],bounds:CGRect,dy:Int,margin:Int,
                                  policy:NativeTextExpansionPolicy,page:CGRect)->[ClosedRange<Int>] {
        guard !rows.isEmpty,margin>=0,margin<=512,policy.valid,policy.insideBalloon,
              let rect=policy.maskRectNormalized,let spans=policy.maskSpansNormalized else{return []}
        let capacity=NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page)
        let mask=NativeTextExpansionPolicy.rect(rect,page:page),padding=CGFloat(margin)
        // Preserve legacy soft-distance rounding. Zero-margin admission is strict.
        let epsilon:CGFloat=margin>0 ? 1e-7:0
        let top=bounds.minY+CGFloat(dy)-padding,bottom=bounds.maxY+CGFloat(dy)+padding
        guard top>=max(capacity.minY,mask.minY)-epsilon,bottom<=min(capacity.maxY,mask.maxY)+epsilon else{return []}
        let lower=ceil(max(capacity.minX,mask.minX)+padding-bounds.minX-epsilon)
        let upper=floor(min(capacity.maxX,mask.maxX)-padding-bounds.maxX+epsilon)
        guard lower.isFinite,upper.isFinite,lower<=upper else{return []}
        var feasible:[ClosedRange<CGFloat>]=[lower...upper]
        let n=spans.count/2,pitch=mask.height/CGFloat(n)
        for row in rows {
            guard row.left<row.right else{return []}
            let y=CGFloat(row.y+dy-margin),Y=CGFloat(row.y+dy+1+margin)
            let first=max(0,Int(floor((y-mask.minY+epsilon)/pitch)))
            let last=min(n-1,Int(ceil((Y-mask.minY-epsilon)/pitch))-1)
            guard first<=last else{return []}
            for k in first...last {
                let intervals=policy.maskIntervals(row:k)
                var allowed:[ClosedRange<CGFloat>]=[]
                for j in stride(from:0,to:intervals.count,by:2) {
                    let lo=ceil(CGFloat(intervals[j])*page.width-CGFloat(row.left)+padding-epsilon)
                    let hi=floor(CGFloat(intervals[j+1])*page.width-CGFloat(row.right)-padding+epsilon)
                    if lo<=hi {allowed.append(lo...hi)}
                }
                var next:[ClosedRange<CGFloat>]=[],index=0
                for range in feasible {
                    while index<allowed.count,allowed[index].upperBound<range.lowerBound {index+=1}
                    var j=index
                    while j<allowed.count,allowed[j].lowerBound<=range.upperBound {
                        let lo=max(range.lowerBound,allowed[j].lowerBound)
                        let hi=min(range.upperBound,allowed[j].upperBound)
                        if lo<=hi {
                            // Adjacent integer ranges have no missing admissible shift.
                            if let prior=next.last,lo<=prior.upperBound+1 {
                                next[next.count-1]=prior.lowerBound...max(prior.upperBound,hi)
                            } else {
                                guard next.count<128 else{return []}
                                next.append(lo...hi)
                            }
                        }
                        j+=1
                    }
                }
                guard !next.isEmpty else{return []}
                feasible=next
            }
        }
        guard feasible.allSatisfy({$0.lowerBound >= -32768 && $0.upperBound<=32768}) else{return []}
        return feasible.map {Int($0.lowerBound)...Int($0.upperBound)}
    }
    /// Compatibility view: return one actual interval, never a hull across holes.
    /// Prefer zero, then the closest endpoint; equal distances choose the left lobe.
    static func interval(rows:[Row],bounds:CGRect,dy:Int,margin:Int,
                         policy:NativeTextExpansionPolicy,page:CGRect)->ClosedRange<Int>? {
        let ranges=feasibleIntervals(rows:rows,bounds:bounds,dy:dy,margin:margin,policy:policy,page:page)
        return ranges.min {a,b in
            let x=a.contains(0) ? 0:min(abs(a.lowerBound),abs(a.upperBound))
            let y=b.contains(0) ? 0:min(abs(b.lowerBound),abs(b.upperBound))
            return x==y ? a.lowerBound<b.lowerBound:x<y
        }
    }
    static func margin(rows:[Row],bounds:CGRect,policy:NativeTextExpansionPolicy,page:CGRect,limit:Int)->Int {
        guard limit>0 else{return 0}
        var lo=0,hi=min(512,limit)
        while lo<hi {
            let mid=(lo+hi+1)/2
            if feasibleIntervals(rows:rows,bounds:bounds,dy:0,margin:mid,policy:policy,page:page).contains(where:{$0.contains(0)}) {lo=mid}
            else {hi=mid-1}
        }
        return lo
    }
    static func plans(rows:[Row],bounds:CGRect,source:CGRect,policy:NativeTextExpansionPolicy,
                      guide:NativeTextPlacementGuide,font:CGFloat,page:CGRect,maximumSourceDriftEm:CGFloat=0)->[Plan] {
        guard guide.valid,font.isFinite,font>0,font<=2048,maximumSourceDriftEm.isFinite,
              (0...0.25).contains(maximumSourceDriftEm),bounds==bounds.integral,
              feasibleIntervals(rows:rows,bounds:bounds,dy:0,margin:0,policy:policy,page:page).contains(where:{$0.contains(0)}) else{return []}
        let target=Int(ceil(font*0.2)),old=margin(rows:rows,bounds:bounds,policy:policy,page:page,limit:target)
        guard old<target else{return []}
        let capacity=NativeTextExpansionPolicy.rect(policy.allowedRectNormalized,page:page)
        let mask=NativeTextExpansionPolicy.rect(policy.maskRectNormalized!,page:page)
        let before=NativeContourTextClearance.sourceCost(bounds,source)
        guard before.isFinite else{return []}
        let toward=CGPoint(x:source.midX-bounds.midX,y:source.midY-bounds.midY)
        var result:[Plan]=[],seen=Set<String>()
        for value in stride(from:target,through:old+1,by:-1) {
            let lo=ceil(max(capacity.minY,mask.minY)+CGFloat(value)-bounds.minY-1e-7)
            let hi=floor(min(capacity.maxY,mask.maxY)-CGFloat(value)-bounds.maxY+1e-7)
            guard lo<=hi else{continue}
            var ys:[CGFloat]=[0,toward.y,lo,hi,(lo+hi)/2]
            for k in -4...4 {ys.append(CGFloat(k)*max(1,font*0.25))}
            let vertical=Set(ys.map {Int(min(hi,max(lo,$0.rounded())))})
            for dy in vertical.sorted() {
                for range in feasibleIntervals(rows:rows,bounds:bounds,dy:dy,margin:value,policy:policy,page:page) {
                    for preferred in [CGFloat.zero,toward.x] {
                        let dx=min(range.upperBound,max(range.lowerBound,Int(preferred.rounded())))
                        let proposed=bounds.offsetBy(dx:CGFloat(dx),dy:CGFloat(dy))
                        let cost=NativeContourTextClearance.sourceCost(proposed,source),key="\(dx),\(dy)"
                        let farther=cost>before+1e-7
                        let limitedDrift = maximumSourceDriftEm>0 && sqrt(cost)<=sqrt(before)+font*maximumSourceDriftEm+1e-7 &&
                            hypot(CGFloat(dx),CGFloat(dy))<=font*0.25+1e-7
                        guard (!farther || limitedDrift),policy.sourceAnchorAllows(proposed,page:page,guide:guide),
                              seen.insert(key).inserted else{continue}
                        result.append(.init(origin:proposed.origin,margin:value,oldMargin:old,
                            sourceCostBefore:before,sourceCostAfter:cost))
                    }
                }
            }
        }
        return result.sorted {a,b in
            if a.margin != b.margin {return a.margin>b.margin}
            let fartherA=a.sourceCostAfter>a.sourceCostBefore+1e-7,fartherB=b.sourceCostAfter>b.sourceCostBefore+1e-7
            if fartherA != fartherB {return !fartherA}
            let x=pow(a.origin.x-bounds.minX,2)+pow(a.origin.y-bounds.minY,2)
            let y=pow(b.origin.x-bounds.minX,2)+pow(b.origin.y-bounds.minY,2)
            if x != y {return x<y}
            if a.sourceCostAfter != b.sourceCostAfter {return a.sourceCostAfter<b.sourceCostAfter}
            return a.origin.y==b.origin.y ? a.origin.x<b.origin.x:a.origin.y<b.origin.y
        }
    }
}
