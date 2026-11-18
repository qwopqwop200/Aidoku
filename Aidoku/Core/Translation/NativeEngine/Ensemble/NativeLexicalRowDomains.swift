import CoreGraphics
import CoreText
import Foundation

/// Scalar capacity DAG, bounded CTLine LRU and iterative path traversal. No
/// collection of complete partitions. DFS order is the former eager order.
enum NativeLexicalRowDomains {
    enum Failure:Error {case resourceExhausted(String)}
    struct Stats {
        var endpoints=0,edges=0,paths=0,nodes=0,capacityPruned=0,tierPruned=0,linePeak=0,pathPeak=0
        var audit:[String:Any] {[
            "endpoints":endpoints,"edges":edges,"emittedPaths":paths,"visitedEdges":nodes,
            "capacityPruned":capacityPruned,"tierPruned":tierPruned,"linePeak":linePeak,
            "pathPeak":pathPeak,"complete":true,"partitionArraysRetained":0,
            "limits":["edges":262144,"visitedEdges":1000000,"lineCache":128],
            "completeness":"all width/capacity/tier-admissible lexical paths; explicit throw on resource exhaustion"]}
    }
    static func visit(text:String,font:CTFont,size:CGFloat,maximumWidth:CGFloat,
        color:CGColor,measurements:NativeScopedShapePlanCache.Measurements,
        minimumLineHeight:CGFloat,maximumHeight:CGFloat,bestTier:()->Int,tracking:CGFloat=0,
        emit:(NativeWholeWordWrap.Proposal)throws->Void) throws -> Stats {
        let seed=try NativeWholeWordWrap.layout(text:text,font:font,size:size,width:maximumWidth,
            tracking:tracking,color:color,lineFactory:measurements.line)
        let ns=text as NSString
        guard !text.contains(where:NativeLineBreakPolicy.isBreak),ns.length>0 else{return Stats()}
        let legal = NativeLineBreakPolicy.legalOffsets(text: text)
        let spaces = seed.graphemeRanges.map { NativeLineBreakPolicy.isSpace(ns.substring(with: $0).first!) }
        var ends:[Int]=[]
        for (index, range) in seed.graphemeRanges.enumerated() {
            // A whitespace run is one break opportunity, owned by its left
            // row. Do not enumerate visually identical partitions per space,
            // or bypass numeric-unit/quote/kinsoku rules from the seed.
            if spaces[index] && (index+1 == spaces.count || !spaces[index+1]) &&
                legal.contains(NSMaxRange(range)) { ends.append(NSMaxRange(range)) }
        }
        ends.append(ns.length);ends=Array(Set(ends)).sorted()
        let starts=[0]+ends,n=ends.count,required=NativePhraseRowCoupling.boundaries(text)
        let visible=seed.graphemeRanges.enumerated().filter { !spaces[$0.offset] }.map(\.element)
        var stats=Stats();stats.endpoints=n
        // Only scalar edges persist. A row's CTLine is created on demand and
        // shared by active paths; cache eviction changes cost, never decisions.
        var cache:[Int:NativeWholeWordWrap.Row]=[:],order:[Int]=[]
        func row(_ i:Int,_ j:Int)->NativeWholeWordWrap.Row? {
            return autoreleasepool {
            let key=i*n+j
            if let r=cache[key] {return r}
            let owned=NSRange(location:starts[i],length:ends[j]-starts[i])
            guard let first=visible.first(where:{$0.location>=owned.location && NSMaxRange($0)<=NSMaxRange(owned)}),
                let last=visible.last(where:{$0.location>=owned.location && NSMaxRange($0)<=NSMaxRange(owned)}) else{return nil}
            let paint=NSRange(location:first.location,length:NSMaxRange(last)-first.location)
            let line=measurements.line(seed.attributedText.attributedSubstring(from:paint))
            var a:CGFloat=0,d:CGFloat=0,l:CGFloat=0
            let advance=CGFloat(CTLineGetTypographicBounds(line,&a,&d,&l))
            let ink=CTLineGetBoundsWithOptions(line,[.useGlyphPathBounds])
            guard max(advance,ink.maxX)-min(0,ink.minX)<=maximumWidth+0.001 else{return nil}
            let r=NativeWholeWordWrap.Row(ownedRange:owned,paintedRange:paint,line:line,advance:advance,
                ascent:a,descent:d,leading:l,inkBounds:ink,hardBreak:false,overflow:0,discretionaryHyphen:false)
            if cache.count==128 {cache.removeValue(forKey:order.removeFirst())}
            cache[key]=r;order.append(key);stats.linePeak=max(stats.linePeak,cache.count)
            return r
            }
        }
        var edges=[[Int]](repeating:[],count:n),cost=[Int](repeating:0,count:n)
        var allInk=true,minTop=CGFloat.infinity,maxBottom = -CGFloat.infinity
        for j in 0..<n-1 {
            var next=ends[j]
            while next<ns.length,let scalar=UnicodeScalar(ns.character(at:next)),CharacterSet.whitespacesAndNewlines.contains(scalar) {next+=1}
            cost[j]=required.contains(next) ? 1:0
        }
        for i in 0..<n {for j in i..<n {
            if let r=row(i,j) {
                edges[i].append(j+1);stats.edges+=1
                guard stats.edges<=262144 else{throw Failure.resourceExhausted("DAG-edge-budget;complete=false")}
                if r.inkBounds.isEmpty {allInk=false}
                else {minTop=min(minTop,r.inkBounds.maxY);maxBottom=max(maxBottom,r.inkBounds.minY)}
            }
        }}
        let infinity=Int.max/4
        var minRows=[Int](repeating:infinity,count:n+1),minTier=minRows
        minRows[n]=0;minTier[n]=0
        for i in (0..<n).reversed() {for next in edges[i] {
            minRows[i]=min(minRows[i],1+minRows[next])
            minTier[i]=min(minTier[i],cost[next-1]+minTier[next])
        }}
        // No complete width-feasible path: ink extrema can still be infinities.
        // This is an empty additional lexical domain, not a page failure.
        if minRows[0]==infinity {stats.capacityPruned+=1;return stats}
        // For every nonempty ink row, baseline separation >= minimumLineHeight.
        // Thus height >= (rows-1)*pitch + min(maxY) - max(minY).
        // Empty-ink rows disable this bound; they never masquerade as ink.
        let rowLimit=allInk && minimumLineHeight>0 ? max(0,Int(min(CGFloat(n),floor((maximumHeight-minTop+maxBottom)/minimumLineHeight)+1))) : n
        if minRows[0]>rowLimit {stats.capacityPruned+=1;return stats}
        struct Frame {var node:Int;var edge:Int;var tier:Int}
        var stack=[Frame(node:0,edge:0,tier:0)],rows:[NativeWholeWordWrap.Row]=[]
        while !stack.isEmpty {
            let k=stack.count-1,i=stack[k].node
            if i==n {
                let width=rows.map{max($0.advance,$0.inkBounds.maxX)-min(0,$0.inkBounds.minX)}.max() ?? 1
                let result=NativeWholeWordWrap.Result(text:text,attributedText:seed.attributedText,rows:rows,
                    graphemeRanges:seed.graphemeRanges,unresolvedGlyphRanges:seed.unresolvedGlyphRanges,
                    fallbackRanges:seed.fallbackRanges,completeOwnership:true,requiredWidth:width,
                    bodyHeight:rows.reduce(0){$0+$1.ascent+$1.descent+max($1.leading,size*0.12)},
                    requestedFontName:seed.requestedFontName,requestedFontSize:size,appliedTracking:seed.appliedTracking)
                stats.paths+=1
                try emit(.init(width:width+0.001,result:result,
                    singleLetterRows:rows.filter{ns.substring(with:$0.paintedRange).filter{$0.isLetter}.count==1}.count,overflowRows:0))
                stack.removeLast();rows.removeLast();continue
            }
            if stack[k].edge==edges[i].count {
                stack.removeLast();if !rows.isEmpty {rows.removeLast()};continue
            }
            let next=edges[i][stack[k].edge];stack[k].edge+=1;stats.nodes+=1
            guard stats.nodes<=1000000 else{throw Failure.resourceExhausted("traversal-budget;complete=false")}
            if rows.count+1+minRows[next]>rowLimit {stats.capacityPruned+=1;continue}
            let tier=stack[k].tier+cost[next-1]
            if tier+minTier[next]>bestTier() {stats.tierPruned+=1;continue}
            guard let r=row(i,next-1) else{preconditionFailure("scalar DAG changed")}
            rows.append(r);stack.append(Frame(node:next,edge:0,tier:tier));stats.pathPeak=max(stats.pathPeak,rows.count)
        }
        return stats
    }
    /// Compatibility for a non-live reference helper; never used by solve.
    static func materializeForReference(text:String,font:CTFont,size:CGFloat,maximumWidth:CGFloat,
        color:CGColor,measurements:NativeScopedShapePlanCache.Measurements)throws->[NativeWholeWordWrap.Proposal] {
        var result:[NativeWholeWordWrap.Proposal]=[]
        _=try visit(text:text,font:font,size:size,maximumWidth:maximumWidth,color:color,measurements:measurements,
            minimumLineHeight:size,maximumHeight:CGFloat.greatestFiniteMagnitude.squareRoot(),bestTier:{Int.max}) {proposal in
                guard result.count<32768 else{throw Failure.resourceExhausted("reference-materialization;complete=false")}
                result.append(proposal)
            }
        return result
    }
}
