import CoreGraphics
import Foundation

/// Bounded ordered interval packing for source-aligned captions. Measured
/// geometry and source distance only; no page identifiers or label lookups.
enum NativeSourceCohortPacking {
    struct Placement {
        let owner:String
        let group:String
        let source:CGRect
        let paint:CGRect
        let referenceFont:CGFloat
        let displayFont:CGFloat
        let wrapPenalty:Int
        var wordCuts:Int=0
        /// Exterior cohorts may trade bounded anchor motion for fewer cut words.
        var reflowAxis:NativeSourceClusterAlignment.Axis?=nil
        var softRows:Int=0
        var allowsUnalignedReflow:Bool=false
        /// Set only after final alpha admission inside an assigned balloon.
        var allowsContainedReflow:Bool=false
    }
    /// Compare two actual admitted layouts of identical owners. Source geometry
    /// is observed input, never an evaluation label or image-specific lookup.
    static func regressedGroups(before:[Placement],after:[Placement],allowGroupRowTrade:Bool=false)->Set<String> {
        let groups=Set(before.map(\.group)).union(after.map(\.group))
        guard Set(before.map(\.owner)).count==before.count,Set(after.map(\.owner)).count==after.count else{return groups}
        let old=Dictionary(uniqueKeysWithValues:before.map {($0.owner,$0)})
        var result=Set<String>(),prior:[String:Double]=[:],current:[String:Double]=[:]
        var oldWrap:[String:Int]=[:],newWrap:[String:Int]=[:]
        var oldCuts:[String:Int]=[:],newCuts:[String:Int]=[:]
        guard Set(old.keys)==Set(after.map(\.owner))else{return groups}
        for p in after {
            let b=old[p.owner]!
            guard p.group==b.group,p.source==b.source,p.referenceFont.isFinite,p.referenceFont>0,
                  p.referenceFont==b.referenceFont,p.displayFont.isFinite,b.displayFont.isFinite else{return groups}
            if p.displayFont<b.displayFont-0.01 {result.insert(p.group)}
            func cost(_ v:Placement)->Double {
                let x=(v.paint.midX-v.source.midX)/v.referenceFont,y=(v.paint.midY-v.source.midY)/v.referenceFont
                return Double(x*x+y*y)
            }
            prior[p.group,default:0]+=cost(b);current[p.group,default:0]+=cost(p)
            oldWrap[p.group,default:0]+=b.wrapPenalty;newWrap[p.group,default:0]+=p.wrapPenalty
            oldCuts[p.group,default:0]+=b.wordCuts;newCuts[p.group,default:0]+=p.wordCuts
        }
        let trades=allowGroupRowTrade ? rowTradeGroups(before:before,after:after):[]
        for group in groups {
            let a=prior[group] ?? 0,b=current[group] ?? 0
            let previous=before.filter {$0.group==group},proposed=after.filter {$0.group==group}
            let reducedCuts=newCuts[group,default:0]<oldCuts[group,default:0]
            let compactRows=newCuts[group,default:0]==oldCuts[group,default:0] &&
                previous.allSatisfy {$0.softRows>0} && proposed.allSatisfy {p in
                    old[p.owner].map {p.softRows>0 && p.softRows<=$0.softRows} ?? false
                } && proposed.reduce(0,{$0+$1.softRows})<previous.reduce(0,{$0+$1.softRows})
            let readableReflow=(reducedCuts || compactRows || trades.contains(group)) &&
                allowsReadableReflow(before:previous,after:proposed)
            if !a.isFinite || !b.isFinite || newWrap[group,default:0]>oldWrap[group,default:0] ||
                newWrap[group,default:0]==oldWrap[group,default:0] && newCuts[group,default:0]>oldCuts[group,default:0] ||
                newWrap[group,default:0]==oldWrap[group,default:0] && b>a+max(0.01,a*0.02) && !readableReflow {result.insert(group)}
        }
        return result
    }
    private static func allowsReadableReflow(before:[Placement],after:[Placement])->Bool {
        guard !before.isEmpty else{return false}
        let axis=before[0].reflowAxis
        let contained=before.allSatisfy(\.allowsContainedReflow) && after.allSatisfy(\.allowsContainedReflow)
        guard before.allSatisfy({$0.reflowAxis==axis}),after.allSatisfy({$0.reflowAxis==axis}),
              axis != nil || contained || before.allSatisfy({$0.allowsUnalignedReflow}) && after.allSatisfy({$0.allowsUnalignedReflow})else{return false}
        let old=Dictionary(uniqueKeysWithValues:before.map {($0.owner,$0)})
        var movement:CGFloat=0,anchors:[CGFloat]=[]
        for p in after {
            guard let b=old[p.owner],p.wordCuts<=b.wordCuts,p.wrapPenalty<=b.wrapPenalty,
                  abs(p.displayFont-b.displayFont)<0.01 else{return false}
            // A shorter paragraph changes its centre without moving its aligned
            // start. Bound the actual anchor motion, not that height change.
            let dx=axis == .left ? p.paint.minX-b.paint.minX:p.paint.midX-b.paint.midX
            let dy=axis == .top ? p.paint.minY-b.paint.minY:p.paint.midY-b.paint.midY
            let delta=hypot(dx,dy)/p.referenceFont
            guard delta.isFinite,delta<=(contained ? 0.75:2.5) else{return false}
            // Count a common baseline translation once as an alignment bound,
            // not as an accumulating penalty for every paragraph in the row.
            if let axis {
                let common=abs(axis == .top ? dy:dx)/p.referenceFont
                guard common<=2 else{return false}
                movement+=abs(axis == .top ? dx:dy)/p.referenceFont
                anchors.append(axis == .top ? p.paint.minY:p.paint.minX)
            } else {movement+=delta}
        }
        return movement<=CGFloat(after.count)*(contained ? 0.5:1.5) &&
            (anchors.max() ?? 0)-(anchors.min() ?? 0)<0.01
    }
    /// Drop only the responsible refinement in a rejected cohort. Removing
    /// every word proposal also erases unrelated, already feasible improvements.
    static func rejectedRefinementOwners(before:[Placement],after:[Placement],candidates:Set<String>,preferExpansion:Bool=false)->Set<String> {
        guard Set(before.map(\.owner)).count==before.count else{return candidates}
        let groups=regressedGroups(before:before,after:after)
        let old=Dictionary(uniqueKeysWithValues:before.map {($0.owner,$0)})
        var rejected=Set<String>()
        for group in groups {
            let members=after.filter {$0.group==group && candidates.contains($0.owner)}
            let bad=members.filter {p in
                guard let b=old[p.owner]else{return true}
                return p.displayFont<b.displayFont-0.01 || p.wordCuts>b.wordCuts || p.wrapPenalty>b.wrapPenalty
            }
            if !bad.isEmpty {rejected.formUnion(bad.map(\.owner));continue}
            func motion(_ p:Placement)->CGFloat {
                guard let b=old[p.owner],p.referenceFont>0 else{return .infinity}
                let dx=p.reflowAxis == .left ? p.paint.minX-b.paint.minX:p.paint.midX-b.paint.midX
                let dy=p.reflowAxis == .top ? p.paint.minY-b.paint.minY:p.paint.midY-b.paint.midY
                return hypot(dx,dy)/p.referenceFont
            }
            func expansion(_ p:Placement)->CGFloat {
                guard let b=old[p.owner],p.referenceFont>0 else{return .infinity}
                return max(0,p.reflowAxis == .left ? p.paint.height-b.paint.height:p.paint.width-b.paint.width)/p.referenceFont
            }
            let hasExpansion=preferExpansion && members.contains {expansion($0)>0.01}
            func score(_ p:Placement)->CGFloat {hasExpansion ? expansion(p):motion(p)}
            if let worst=members.max(by:{a,b in score(a)==score(b) ? a.owner>b.owner:score(a)<score(b)}) {
                rejected.insert(worst.owner)
            }
        }
        return rejected.isEmpty && !groups.isEmpty ? candidates:rejected
    }
    struct Option {
        let index:Int
        let extent:CGFloat
        let lower:CGFloat
        let upper:CGFloat // Maximum permitted origin, not the far edge.
        let preferred:CGFloat
        let unit:CGFloat
        let cost:Double
    }
    /// Restrict packing before choosing a wrap, so an excessively wide option
    /// cannot displace its neighbours and force a later whole-cohort rollback.
    static func sourceNearOption(_ option:Option,sourceCentre:CGFloat,anchorDelta:CGFloat,
                                 maximumMotionEm:CGFloat=2.5)->Option? {
        guard option.unit.isFinite,option.unit>0,sourceCentre.isFinite,anchorDelta.isFinite,
              maximumMotionEm.isFinite,maximumMotionEm>0 else{return nil}
        let radius=maximumMotionEm*option.unit
        guard abs(anchorDelta)<=min(radius,2*option.unit) else{return nil}
        let lateral=sqrt(max(0,radius*radius-anchorDelta*anchorDelta))
        let centreOrigin=sourceCentre-option.extent/2
        let lower=max(option.lower,centreOrigin-lateral),upper=min(option.upper,centreOrigin+lateral)
        guard ceil(lower)<=floor(upper) else{return nil}
        return .init(index:option.index,extent:option.extent,lower:lower,upper:upper,
                     preferred:option.preferred,unit:option.unit,cost:option.cost)
    }
    /// Per-owner shaping quality must not be hidden by a better group total.
    /// Both layouts are computed from the same current source observations.
    static func qualityRegressedOwners(before:[Placement],after:[Placement],allowGroupRowTrade:Bool=false)->Set<String> {
        let owners=Set(before.map(\.owner)).union(after.map(\.owner))
        guard Set(before.map(\.owner)).count==before.count,Set(after.map(\.owner)).count==after.count,
              Set(before.map(\.owner))==Set(after.map(\.owner))else{return owners}
        let old=Dictionary(uniqueKeysWithValues:before.map {($0.owner,$0)})
        let trades=allowGroupRowTrade ? rowTradeGroups(before:before,after:after):[]
        return Set(after.compactMap {p in
            let b=old[p.owner]!
            return p.displayFont<b.displayFont-0.01 || p.wrapPenalty>b.wrapPenalty || p.wordCuts>b.wordCuts ||
                p.wordCuts==b.wordCuts && b.softRows>0 && p.softRows>b.softRows && !trades.contains(p.group) ? p.owner:nil
        })
    }
    /// Side-by-side captions may redistribute width at the retained font. An
    /// established source column can add two rows within its original height
    /// when the cohort saves a row overall. Actual mask/peer admission remains
    /// mandatory, and no extra word cuts or punctuation defects are allowed.
    private static func rowTradeGroups(before:[Placement],after:[Placement])->Set<String> {
        guard Set(before.map(\.owner)).count==before.count,Set(after.map(\.owner)).count==after.count,
              Set(before.map(\.owner))==Set(after.map(\.owner))else{return []}
        let old=Dictionary(uniqueKeysWithValues:before.map {($0.owner,$0)})
        let groups=Dictionary(grouping:after,by:\.group)
        return Set(groups.compactMap { group,members in
            guard members.count>1,let axis=members[0].reflowAxis,
                  members.allSatisfy({p in
                    guard let b=old[p.owner]else{return false}
                    return b.group==group && b.source==p.source && b.reflowAxis==axis && p.reflowAxis==axis &&
                        !b.allowsContainedReflow && !p.allowsContainedReflow && p.referenceFont.isFinite && p.referenceFont>0 &&
                        b.displayFont.isFinite && p.displayFont.isFinite && abs(p.displayFont-b.displayFont)<0.01 &&
                        p.wrapPenalty<=b.wrapPenalty && p.wordCuts<=b.wordCuts && b.softRows>0 && p.softRows>0
                  })else{return nil}
            let saved=members.reduce(0,{$0+old[$1.owner]!.softRows-$1.softRows})
            let ordinary=saved>=2 && members.allSatisfy {p in
                let b=old[p.owner]!
                return p.softRows<=b.softRows || b.softRows>=3 && p.softRows==b.softRows+1
            }
            let sourceColumn=axis == .top && saved>=1 && members.allSatisfy {p in
                let b=old[p.owner]!
                return p.softRows<=b.softRows || b.softRows>=3 && p.softRows<=b.softRows+2 &&
                    p.source.height>=p.source.width*1.4 && p.paint.height<=p.source.height+p.referenceFont*0.15
            }
            return ordinary || sourceColumn ? group:nil
        })
    }
    struct Result {let indices:[Int];let origins:[CGFloat];let cost:Double}
    /// Exact fixed-width quadratic packing. Pool adjacent ordered intervals;
    /// integer rounding keeps every pixel gap and capacity bound feasible.
    static func quadraticOrigins(_ members:[Option],gaps:[CGFloat])->[CGFloat]? {
        guard !members.isEmpty,members.count<=256,gaps.count==members.count-1,
              gaps.allSatisfy({$0.isFinite && $0>=0})else{return nil}
        struct Block {
            var first:Int;var last:Int;var weight:Double;var moment:Double
            var lower:CGFloat;var upper:CGFloat
            var value:CGFloat {min(upper,max(lower,CGFloat(moment/weight)))}
        }
        var offsets:[CGFloat]=[],offset:CGFloat=0,blocks:[Block]=[]
        for (i,p)in members.enumerated() {
            guard p.extent.isFinite,p.extent>0,p.preferred.isFinite,p.lower.isFinite,p.upper.isFinite,
                  p.unit.isFinite,p.unit>0 else{return nil}
            if i>0 {offset+=ceil(members[i-1].extent)+ceil(gaps[i-1])}
            guard offset.isFinite else{return nil}
            offsets.append(offset)
            let weight=1/pow(Double(p.unit),2),lower=ceil(p.lower)-offset,upper=floor(p.upper)-offset
            let moment=weight*Double(p.preferred-offset)
            guard lower<=upper,weight.isFinite,weight>0,moment.isFinite else{return nil}
            blocks.append(.init(first:i,last:i,weight:weight,moment:moment,lower:lower,upper:upper))
            while blocks.count>1 && blocks[blocks.count-2].value>blocks[blocks.count-1].value {
                let b=blocks.removeLast(),a=blocks.removeLast()
                let joined=Block(first:a.first,last:b.last,weight:a.weight+b.weight,moment:a.moment+b.moment,
                    lower:max(a.lower,b.lower),upper:min(a.upper,b.upper))
                guard joined.lower<=joined.upper,joined.weight.isFinite,joined.moment.isFinite else{return nil}
                blocks.append(joined)
            }
        }
        var origins=[CGFloat](repeating:0,count:members.count)
        for block in blocks {
            let value=block.value.rounded()
            for i in block.first...block.last {origins[i]=value+offsets[i]}
        }
        return origins
    }
    private struct State {let end:CGFloat;let cost:Double;let indices:[Int];let origins:[CGFloat]}
    static func pack(_ members:[[Option]],gap:CGFloat)->Result? {
        guard !members.isEmpty,members.count<=256,gap.isFinite,gap>=0 else {return nil}
        var states=[State(end:-.infinity,cost:0,indices:[],origins:[])]
        for options in members {
            var next:[State]=[]
            for state in states {
                for option in options where option.extent.isFinite && option.extent>0 && option.lower.isFinite &&
                    option.upper.isFinite && option.preferred.isFinite && option.unit.isFinite && option.unit>0 && option.cost.isFinite {
                    let lo=ceil(max(option.lower,state.end+gap)),hi=floor(option.upper)
                    guard lo<=hi else {continue}
                    for origin in Set([lo,min(hi,max(lo,option.preferred.rounded())),hi]).sorted() {
                        let cost=state.cost+option.cost+Double(abs(origin-option.preferred)/option.unit)*0.8
                        next.append(.init(end:origin+ceil(option.extent),cost:cost,
                            indices:state.indices+[option.index],origins:state.origins+[origin]))
                    }
                }
            }
            next.sort {$0.end == $1.end ? $0.cost<$1.cost : $0.end<$1.end}
            var frontier:[State]=[],best=Double.infinity
            for state in next where state.cost<best-1e-9 {frontier.append(state);best=state.cost}
            if frontier.count>96 {
                let last=frontier.count-1
                frontier=(0..<96).map {frontier[Int((Double($0)*Double(last)/95).rounded())]}
            }
            guard !frontier.isEmpty else {return nil}
            states=frontier
        }
        guard let best=states.min(by:{$0.cost<$1.cost})else{return nil}
        return .init(indices:best.indices,origins:best.origins,cost:best.cost)
    }
}
