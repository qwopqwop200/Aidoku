import CoreGraphics
import Foundation

/// Fixed glyph geometry only. Source cohorts and relaxed balloon paragraphs
/// may trade a bounded source offset for readable paragraph separation.
enum NativeAdaptiveTextGutter {
    struct Member {
        let owner:String
        let group:String
        let axis:NativeSourceClusterAlignment.Axis
        let source:CGRect
        let painted:CGRect
        let capacity:CGRect
        let preferred:CGPoint
        let referenceFont:CGFloat
        let displayFont:CGFloat
    }
    struct Metrics {let squared:Double;let distance:Double}
    struct Plan {
        let group:String
        let origins:[String:CGPoint]
        let oldGap:CGFloat
        let targetGap:CGFloat
        let before:Metrics
        let after:Metrics
    }
    static func metrics(_ members:[Member],bounds:[String:CGRect])->Metrics? {
        var squared=0.0,distance=0.0
        for m in members {
            guard let r=bounds[m.owner],m.referenceFont.isFinite,m.referenceFont>0 else{return nil}
            let x=Double((r.midX-m.source.midX)/m.referenceFont)
            let y=Double((r.midY-m.source.midY)/m.referenceFont),cost=x*x+y*y
            guard cost.isFinite else{return nil}
            squared+=cost;distance+=sqrt(cost)
        }
        return .init(squared:squared,distance:distance)
    }
    static func clearance(_ a:CGRect,_ b:CGRect)->CGFloat? {
        let dx=max(b.minX-a.maxX,a.minX-b.maxX),dy=max(b.minY-a.maxY,a.minY-b.maxY)
        if dx<0 && dy<0 {return 0}
        let vertical=max(0,min(a.maxY,b.maxY)-max(a.minY,b.minY))
        let horizontal=max(0,min(a.maxX,b.maxX)-max(a.minX,b.minX))
        if dx>=0 && vertical>=min(a.height,b.height)*0.5 {return dx}
        if dy>=0 && horizontal>=min(a.width,b.width)*0.5 {return dy}
        return nil
    }
    /// Retain a bounded share of observed paragraph separation. Long source
    /// gaps must not pull unrelated captions together or consume all capacity.
    static func desiredGap(_ left:Member,_ right:Member,minimumEm:CGFloat=0.35)->CGFloat {
        let horizontal=left.axis == .top
        let observed=max(0,horizontal ? right.source.minX-left.source.maxX:right.source.minY-left.source.maxY)
        let font=max(left.displayFont,right.displayFont)
        return ceil(max(font*minimumEm,min(observed*0.65,font*1.25)))
    }
    static func allowsMotion(_ members:[Member],before:[String:CGRect],after:[String:CGRect])->Bool {
        guard let a=metrics(members,bounds:before),let b=metrics(members,bounds:after)else{return false}
        if b.squared<=a.squared+1e-9,b.distance<=a.distance+1e-9 {return true}
        guard members.count>1,b.distance<=a.distance+Double(members.count)*0.35 else{return false}
        let horizontal=members[0].axis == .top
        let ordered=members.sorted {
            horizontal ? $0.source.midX<$1.source.midX:$0.source.midY<$1.source.midY
        }
        var improved=false
        for (left,right) in zip(ordered,ordered.dropFirst()) {
            guard let A=before[left.owner],let B=before[right.owner],
                  let C=after[left.owner],let D=after[right.owner]else{return false}
            let old=horizontal ? B.minX-A.maxX:B.minY-A.maxY
            let new=horizontal ? D.minX-C.maxX:D.minY-C.maxY
            let desired=desiredGap(left,right)
            guard new+0.01>=min(old,desired)else{return false}
            if old<desired,new>old+0.5 {improved=true}
        }
        for m in members {
            guard let A=before[m.owner],let B=after[m.owner]else{return false}
            let padding=ceil(m.displayFont*0.15)
            let near=horizontal ? m.capacity.minX:m.capacity.minY
            let far=horizontal ? m.capacity.maxX:m.capacity.maxY
            let oldInset=min((horizontal ? A.minX:A.minY)-near,far-(horizontal ? A.maxX:A.maxY))
            let newInset=min((horizontal ? B.minX:B.minY)-near,far-(horizontal ? B.maxX:B.maxY))
            if oldInset<0.01,newInset>=padding {improved=true}
        }
        guard improved else{return false}
        for m in members {
            guard let A=before[m.owner],let B=after[m.owner],A.size==B.size else{return false}
            let dx=B.minX-A.minX,dy=B.minY-A.minY
            guard hypot(dx,dy)<=m.referenceFont*0.75+0.01,
                  abs(horizontal ? dy:dx)<0.01 else{return false}
        }
        return true
    }
    static func plans(_ input:[Member],desiredGapEm:CGFloat=0.35,edgeInsetEm:CGFloat=0.15,
                      page:CGRect?=nil,pageEdgeMargin:CGFloat=1)->[Plan] {
        let retainedReplay=NativeReadablePeerGutter.enabled
        if retainedReplay {
            guard let page,!page.isNull,!page.isEmpty,
                  [page.minX,page.minY,page.maxX,page.maxY,pageEdgeMargin].allSatisfy(\.isFinite),
                  pageEdgeMargin>=0,page.width>2*pageEdgeMargin,page.height>2*pageEdgeMargin else{return []}
        }
        let guardedPage=retainedReplay ? page?.insetBy(dx:pageEdgeMargin,dy:pageEdgeMargin):nil
        var result=groupPlans(input,desiredGapEm:desiredGapEm,edgeInsetEm:edgeInsetEm,guardedPage:guardedPage)
        // A shared baseline can span distant captions. Do not make a local
        // gutter depend on moving every owner in that alignment group.
        guard input.count<=256 else{return []}
        for group in Dictionary(grouping:input,by:{$0.group}).keys.sorted() {
            let members=input.filter {$0.group==group}
            guard members.count>2,members.allSatisfy({$0.axis==members[0].axis})else{continue}
            let horizontal=members[0].axis == .top
            let ordered=members.sorted {
                let a=horizontal ? $0.source.midX:$0.source.midY,b=horizontal ? $1.source.midX:$1.source.midY
                return a==b ? $0.owner<$1.owner:a<b
            }
            for (a,b) in zip(ordered,ordered.dropFirst()) {
                result+=groupPlans([a,b],desiredGapEm:desiredGapEm,edgeInsetEm:edgeInsetEm,guardedPage:guardedPage)
            }
        }
        return result
    }
    private static func groupPlans(_ input:[Member],desiredGapEm:CGFloat,edgeInsetEm:CGFloat,guardedPage:CGRect?)->[Plan] {
        guard input.count<=256,desiredGapEm.isFinite,desiredGapEm>=0.12,
              edgeInsetEm.isFinite,edgeInsetEm>=0,edgeInsetEm<=0.5 else{return []}
        let groups=Dictionary(grouping:input,by:{$0.group})
        var result:[Plan]=[]
        for group in groups.keys.sorted() {
            let original=groups[group]!
            guard original.count>1,Set(original.map(\.owner)).count==original.count,
                  original.allSatisfy({$0.axis==original[0].axis && $0.referenceFont>0 && $0.displayFont>0})else{continue}
            let horizontal=original[0].axis == .top
            let members=original.sorted {
                let a=horizontal ? $0.source.midX:$0.source.midY,b=horizontal ? $1.source.midX:$1.source.midY
                return a==b ? $0.owner<$1.owner:a<b
            }
            let oldBounds=Dictionary(uniqueKeysWithValues:members.map {($0.owner,$0.painted)})
            guard let before=metrics(members,bounds:oldBounds)else{continue}
            var ordinaryOptions=members.enumerated().map {i,m in
                NativeSourceCohortPacking.Option(index:i,extent:horizontal ? m.painted.width:m.painted.height,
                    lower:horizontal ? m.capacity.minX:m.capacity.minY,
                    upper:horizontal ? m.capacity.maxX-m.painted.width:m.capacity.maxY-m.painted.height,
                    preferred:horizontal ? m.preferred.x:m.preferred.y,unit:m.referenceFont,cost:0)
            }
            if let guardedPage {
                let interval=horizontal ? guardedPage.minX...guardedPage.maxX:guardedPage.minY...guardedPage.maxY
                // A one-pixel containment margin is not a readable page inset.
                // Preserve existing breathing room up to the normal text edge
                // padding; an already tight baseline is never forced tighter.
                ordinaryOptions=ordinaryOptions.enumerated().map {i,option in
                    let member=members[i],padding=ceil(member.displayFont*edgeInsetEm)
                    let origin=horizontal ? member.painted.minX:member.painted.minY
                    let near=max(0,origin-interval.lowerBound)
                    let far=max(0,interval.upperBound-origin-option.extent)
                    return .init(index:option.index,extent:option.extent,
                        lower:max(option.lower,interval.lowerBound+min(padding,near)),
                        upper:min(option.upper,interval.upperBound-option.extent-min(padding,far)),
                        preferred:option.preferred,unit:option.unit,cost:option.cost)
                }
                guard let bounded=NativeReadablePeerGutter.boundedOptions(ordinaryOptions,
                    origins:members.map {horizontal ? $0.painted.minX:$0.painted.minY},pageInterval:interval)else{continue}
                ordinaryOptions=bounded
            }
            var insetChanged=false
            let insetOptions=ordinaryOptions.enumerated().map {i,option in
                let m=members[i],padding=ceil(m.displayFont*edgeInsetEm)
                let origin=horizontal ? m.painted.minX:m.painted.minY
                var lower=option.lower,upper=option.upper
                if padding>0,upper-lower>=2*padding {
                    if abs(origin-lower)<0.01 {lower+=padding}
                    if abs(origin-upper)<0.01 {upper-=padding}
                }
                insetChanged = insetChanged || lower != option.lower || upper != option.upper
                return NativeSourceCohortPacking.Option(index:option.index,extent:option.extent,lower:lower,upper:upper,
                    preferred:option.preferred,unit:option.unit,cost:option.cost)
            }
            let oldGaps=zip(members,members.dropFirst()).map {a,b in
                horizontal ? b.painted.minX-a.painted.maxX:b.painted.minY-a.painted.maxY
            }
            let maximumFont=members.map(\.displayFont).max()!,oldMinimum=oldGaps.min()!
            let readableGap=ceil(maximumFont*desiredGapEm)
            let floorGap=max(ceil(maximumFont*0.12)+1,min(ceil(oldMinimum),readableGap))
            let targets=zip(members,members.dropFirst()).map {max(floorGap,desiredGap($0,$1,minimumEm:desiredGapEm))}
            let desired=max(floorGap,targets.max() ?? readableGap)
            guard floorGap.isFinite,desired.isFinite,desired-floorGap<=4096 else{continue}
            var selected=false
            for options in (insetChanged ? [insetOptions,ordinaryOptions]:[ordinaryOptions]) {
            for gap in stride(from:Int(desired),through:Int(floorGap),by:-1) {
                // Relax pair-specific source spacing only when capacity or the
                // bounded source-motion test rejects the stronger proposal.
                let relaxation=desired-CGFloat(gap)
                let gaps=zip(oldGaps,targets).map {old,target in
                    max(floorGap,max(target-relaxation,min(old,target)))
                }
                guard let origins=NativeSourceCohortPacking.quadraticOrigins(options,gaps:gaps)else{continue}
                var proposed:[String:CGRect]=[:],points:[String:CGPoint]=[:]
                for (i,m)in members.enumerated() {
                    let r=CGRect(x:horizontal ? origins[i]:m.painted.minX,y:horizontal ? m.painted.minY:origins[i],
                        width:m.painted.width,height:m.painted.height)
                    proposed[m.owner]=r;points[m.owner]=r.origin
                }
                guard let after=metrics(members,bounds:proposed),
                      allowsMotion(members,before:oldBounds,after:proposed)else{continue}
                let changed=members.contains {proposed[$0.owner] != $0.painted}
                guard changed else{continue}
                if CGFloat(gap)>oldMinimum+0.01 || after.distance<before.distance-1e-9 || after.squared<before.squared-1e-9 {
                    result.append(.init(group:group,origins:points,oldGap:oldMinimum,targetGap:CGFloat(gap),before:before,after:after))
                    selected=true
                }
                break
            }
            if selected {break}
            }
        }
        return result
    }
}
