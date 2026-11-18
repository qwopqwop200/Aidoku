import CoreGraphics
import Foundation

/// A short detector quad does not independently establish a writing baseline.
/// Nearby long DB columns nominate a local axis; actual DB/source pixels bound
/// the candidate, and two independently padded recognitions must agree later.
@available(iOS 18.0, *)
enum NativeOCRContextualColumnRecovery {
    /// Recognition agreement cannot certify that a recrop kept the printed
    /// strokes. Test source cells in the candidate's own frame, allowing only
    /// the probability grid's sampling uncertainty under any scene rotation.
    static func retainsObservedSource(_ points:[CGPoint],candidate:[CGPoint],uncertainty:CGFloat)->Bool {
        guard let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(candidate) else { return false }
        let allowed=basis.rect.insetBy(dx:-uncertainty,dy:-uncertainty)
        return points.allSatisfy { allowed.contains(basis.project($0)) }
    }

    struct Proposal {
        let parent: Int
        let polygon: [CGPoint]
        let samplings: [[CGPoint]]
        let complements: Set<Int>
        let independentGeometry: Bool
        var pointTailOnly: Bool = false
        var measuredTrimOnly: Bool = false
        var immutableExpansionTrim: Bool = false
        var sourceFamilyTrim: Bool = false
        var observedWeakTerminal: Bool = false
        var measuredNormalOnly: Bool = false
        var measuredTerminalOnly: Bool = false
        var measuredGlyphContourOnly: Bool = false
        var retainedGlyphWordConfirmation: Bool = false
        var symbolicTerminalOnly: Bool = false
        var measuredSourceAxis: Bool = false
        var measuredAxisComponents: [CGRect] = []
        var sourceTerminalProof: [CGPoint]? = nil
        var sourceTerminalInk: [[CGPoint]] = []
        var sourceHeadCompletion: Bool = false
        var sourceTailCompletion: Bool = false
        var pointSources: Set<Int> = []
    }

    struct ColumnJoin {
        let parent: Int
        let recovered: Int
        let polygon: [CGPoint]
        let samplings: [[CGPoint]]
        var maximumInsertedGlyphs: Int = 0
        var additionalSources: Set<Int> = []
    }

    /// Dot count can change under CTC, but a confidently observed dot run
    /// cannot disappear or move to another place in the retained word.
    static func preservesConfidentDotSlots(candidate:String,baseline:NativeCoreMLRecognizedRegion,
        threshold:Double)->Bool {
        guard NativeOCRRFPrimaryEnsemble.measuredTrimSignature(baseline.tokenObservations.map(\.text).joined()) ==
            NativeOCRRFPrimaryEnsemble.measuredTrimSignature(baseline.text) else { return false }
        var required=Set<Int>(),position=0
        for token in baseline.tokenObservations {
            for character in token.text.precomposedStringWithCompatibilityMapping where !character.isWhitespace {
                if character == "." {
                    if token.confidence.isFinite,token.confidence >= max(0.5,threshold) { required.insert(position) }
                } else { position+=1 }
            }
        }
        var observed=Set<Int>();position=0
        for character in candidate.precomposedStringWithCompatibilityMapping where !character.isWhitespace {
            if character == "." { observed.insert(position) } else { position+=1 }
        }
        return required.isSubset(of:observed)
    }

    /// A physical source-preserving recrop may resolve one previously
    /// non-majority CTC token. It cannot remove tokens, change punctuation or
    /// replace any confidently observed letter. The caller independently
    /// requires two identical real reads and a private-primary pixel proof.
    static func preservesSourceFamilyWord(candidate:NativeCoreMLRecognizedRegion,
        baseline:NativeCoreMLRecognizedRegion,threshold:Double)->Bool {
        let old=baseline.tokenObservations,new=candidate.tokenObservations
        guard baseline.confidence >= threshold,candidate.confidence >= max(0.8,baseline.confidence),
              old.count >= 2,new.count==old.count,
              NativeOCRRFPrimaryEnsemble.measuredTrimSignature(old.map(\.text).joined()) ==
                NativeOCRRFPrimaryEnsemble.measuredTrimSignature(baseline.text),
              NativeOCRRFPrimaryEnsemble.measuredTrimSignature(new.map(\.text).joined()) ==
                NativeOCRRFPrimaryEnsemble.measuredTrimSignature(candidate.text) else { return false }
        var corrections=0
        for (before,after) in zip(old,new) where before.text != after.text {
            guard before.confidence.isFinite,after.confidence.isFinite,
                  before.confidence < 0.5,after.confidence >= 0.5,after.confidence > before.confidence,
                  before.text.count==1,after.text.count==1,
                  before.text.unicodeScalars.allSatisfy({CharacterSet.letters.contains($0)}),
                  after.text.unicodeScalars.allSatisfy({CharacterSet.letters.contains($0)}) else { return false }
            corrections+=1
        }
        return corrections==1
    }

    static func preservesFragmentJoin(candidate:String,word:String,fragment:String,budget:Int)->Bool {
        let prefix=NativeOCRRFPrimaryEnsemble.measuredTrimSignature(word)
        let suffix=NativeOCRRFPrimaryEnsemble.measuredTrimSignature(fragment)
        let full=NativeOCRRFPrimaryEnsemble.measuredTrimSignature(candidate)
        guard !prefix.isEmpty,!suffix.isEmpty,budget >= 0,full.hasPrefix(prefix),full.hasSuffix(suffix),
              full.count >= prefix.count+suffix.count else { return false }
        let inserted=full.dropFirst(prefix.count).dropLast(suffix.count)
        return inserted.count <= budget && inserted.allSatisfy(\.isLetter)
    }

    /// The factory crop can retain a symbol while omitting a small preceding
    /// glyph. Observe real print in that omitted band, excluding the local
    /// paper colour; detector padding alone cannot nominate a new glyph.
    static func fragmentHeadInk(_ band:CGRect,basis:NativeOCRRFPrimaryEnsemble.EndpointFrame,
        frame:NativeOCRRGBAFrame,palette:[[Int]],glyph:CGFloat)->Bool {
        let colours=palette.filter { $0.count==3 }
        guard !colours.isEmpty,glyph >= 5,band.width > 0,band.height > 0 else { return false }
        func rgb(_ point:CGPoint)->[Int]? {
            let x=Int(floor(point.x)),y=Int(floor(point.y))
            guard x >= 0,x < frame.width,y >= 0,y < frame.height else { return nil }
            let i=y*frame.bytesPerRow+x*4
            return (0..<3).map { Int(frame.bytes[i+$0]) }
        }
        var paper:[[Int]]=[]
        for fraction in [CGFloat(0.25),0.5,0.75] {
            for x in [band.minX-glyph*0.3,band.maxX+glyph*0.3] {
                if let colour=rgb(basis.restore(.init(x:x,y:band.minY+band.height*fraction))) { paper.append(colour) }
            }
        }
        guard paper.count >= 4 else { return false }
        let background=(0..<3).map { c in paper.map { $0[c] }.sorted()[paper.count/2] }
        let world=NativeOCRDirectionGeometry.bounds(NativeOCRDirectionGeometry.corners(band).map(basis.restore))
        let x0=max(0,Int(floor(world.minX))),x1=min(frame.width,Int(ceil(world.maxX)))
        let y0=max(0,Int(floor(world.minY))),y1=min(frame.height,Int(ceil(world.maxY)))
        guard x1 > x0,y1 > y0,x1-x0 <= 262_144/(y1-y0) else { return false }
        var count=0,extent=CGRect.null
        for y in y0..<y1 { for x in x0..<x1 {
            let p=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5),local=basis.project(p)
            guard band.contains(local),let colour=rgb(p),
                  zip(colour,background).map({abs($0-$1)}).max()! >= 48,
                  colours.contains(where:{zip(colour,$0).map({abs($0-$1)}).max()! <= 48}) else { continue }
            count+=1;extent=extent.union(CGRect(origin:local,size:.zero))
        } }
        return CGFloat(count) >= max(8,glyph*glyph*0.02) && extent.width >= glyph*0.35 && extent.height >= glyph*0.25
    }

    /// Measure a bounded original-paint component rooted inside the retained
    /// fragment. Fill and rim families are flooded separately: their union
    /// could connect a white glyph through its rim into white paper.
    static func fragmentPaintBounds(fragment:[CGPoint],base:CGRect,basis:NativeOCRRFPrimaryEnsemble.EndpointFrame,
        frame:NativeOCRRGBAFrame,palette:[[Int]],glyph:CGFloat,peers:[[CGPoint]]=[])->CGRect? {
        let colours=palette.filter{$0.count==3},search=base.insetBy(dx:-glyph*0.75,dy:-glyph*0.75)
        let world=NativeOCRDirectionGeometry.bounds(NativeOCRDirectionGeometry.corners(search).map(basis.restore))
        let x0=max(0,Int(floor(world.minX))),x1=min(frame.width,Int(ceil(world.maxX)))
        let y0=max(0,Int(floor(world.minY))),y1=min(frame.height,Int(ceil(world.maxY))),width=x1-x0,height=y1-y0
        guard glyph >= 5,!colours.isEmpty,width > 0,height > 0,width <= 262_144/height else { return nil }
        func rgb(_ x:Int,_ y:Int)->[Int] {
            let i=(y+y0)*frame.bytesPerRow+(x+x0)*4
            return (0..<3).map {Int(frame.bytes[i+$0])}
        }
        func matches(_ a:[Int],_ b:[Int])->Bool {
            if zip(a,b).map({abs($0-$1)}).max()! <= 32 { return true }
            let ac=a.max()!-a.min()!,bc=b.max()!-b.min()!
            guard ac >= 48,bc >= 48 else { return false }
            return (0..<3).allSatisfy { abs(Double(a[$0]-a.min()!)/Double(ac)-Double(b[$0]-b.min()!)/Double(bc)) <= 0.2 }
        }
        var families:[[Int]]=[]
        for c in colours where !families.contains(where:{matches(c,$0)}) { families.append(c) }
        let own=basis.bounds(fragment)
        var paper:[[Int]]=[]
        for fraction in [CGFloat(0.25),0.5,0.75] {
            for x in [own.minX-glyph*0.6,own.maxX+glyph*0.6] {
                let p=basis.restore(CGPoint(x:x,y:own.minY+own.height*fraction))
                let xx=Int(floor(p.x))-x0,yy=Int(floor(p.y))-y0
                if xx >= 0,xx < width,yy >= 0,yy < height { paper.append(rgb(xx,yy)) }
            }
        }
        guard paper.count >= 4 else { return nil }
        let background=(0..<3).map { c in paper.map{$0[c]}.sorted()[(paper.count-1)/2] }
        // A rim may physically touch another column. Only a component rooted
        // in both detector-owned columns may be split at their local bisector.
        // A lateral cut never excuses an open longitudinal paint surface.
        let neighbours=peers.filter { polygon in
            guard let peer=NativeOCRRFPrimaryEnsemble.EndpointFrame(polygon),
                  abs(peer.along.x*basis.along.x+peer.along.y*basis.along.y) >= 0.95 else { return false }
            let r=basis.bounds(polygon),distance=abs(r.midX-own.midX)
            return distance >= glyph*0.75 && distance <= glyph*3 &&
                min(r.maxY,own.maxY)-max(r.minY,own.minY) >= min(r.height,own.height)*0.5
        }
        var total=CGRect.null
        for colour in families.prefix(8) where zip(colour,background).map({abs($0-$1)}).max()! > 32 {
            var mask=[Bool](repeating:false,count:width*height),seeds:[Int]=[]
            for y in 0..<height { for x in 0..<width {
                let p=CGPoint(x:CGFloat(x+x0)+0.5,y:CGFloat(y+y0)+0.5),local=basis.project(p)
                let source=rgb(x,y)
                if search.contains(local),matches(source,colour),zip(source,background).map({abs($0-$1)}).max()! > 32 {
                    let k=y*width+x;mask[k]=true
                    if NativeOCRDirectionGeometry.contains(fragment,p) { seeds.append(k) }
                }
            } }
            var visited=Set<Int>()
            for seed in seeds where !visited.contains(seed) {
                var queue=[seed],cursor=0,inside=0,extent=CGRect.null,open=false
                visited.insert(seed)
                while cursor < queue.count {
                    let k=queue[cursor];cursor+=1;let x=k%width,y=k/width
                    let local=basis.project(CGPoint(x:CGFloat(x+x0)+0.5,y:CGFloat(y+y0)+0.5))
                    extent=extent.union(CGRect(origin:local,size:.zero));if base.contains(local) { inside+=1 }
                    if x==0 || y==0 || x==width-1 || y==height-1 || local.x-search.minX < 1 ||
                        search.maxX-local.x < 1 || local.y-search.minY < 1 || search.maxY-local.y < 1 { open=true }
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx=x+dx,yy=y+dy
                        guard xx >= 0,xx < width,yy >= 0,yy < height else { continue }
                        let next=yy*width+xx
                        if mask[next],visited.insert(next).inserted { queue.append(next) }
                    } }
                }
                if open,!neighbours.isEmpty {
                    var owned=search,shared=false
                    for peer in neighbours where queue.contains(where: { k in
                        NativeOCRDirectionGeometry.contains(peer,CGPoint(x:CGFloat(k%width+x0)+0.5,y:CGFloat(k/width+y0)+0.5))
                    }) {
                        let r=basis.bounds(peer),cut=(r.midX+own.midX)*0.5
                        if r.midX < own.midX { let end=owned.maxX;owned.origin.x=max(owned.minX,cut);owned.size.width=end-owned.minX }
                        else { owned.size.width=min(owned.maxX,cut)-owned.minX }
                        shared=true
                    }
                    if shared,owned.width > 0 {
                        // The bisector proves which terminal belongs here,
                        // not where a touching rim's normal edge would close.
                        // Only independently closed components may widen it.
                        let right=min(owned.maxX,base.maxX)
                        owned.origin.x=max(owned.minX,base.minX);owned.size.width=right-owned.minX
                        extent = .null;inside=0;open=false
                        var retained:[Int]=[]
                        for k in queue {
                            let x=k%width,y=k/width
                            let local=basis.project(CGPoint(x:CGFloat(x+x0)+0.5,y:CGFloat(y+y0)+0.5))
                            guard owned.contains(local) else { continue }
                            retained.append(k);extent=extent.union(CGRect(origin:local,size:.zero))
                            if base.contains(local) { inside+=1 }
                            if x==0 || y==0 || x==width-1 || y==height-1 ||
                                local.x-search.minX < 1 || search.maxX-local.x < 1 ||
                                local.y-search.minY < 1 || search.maxY-local.y < 1 { open=true }
                        }
                        queue=retained
                    }
                }
                guard !open,queue.count >= max(4,Int(glyph*0.2)),inside*2 >= queue.count,
                      extent.minX >= base.minX-glyph*0.5,extent.maxX <= base.maxX+glyph*0.5,
                      extent.minY >= base.minY-glyph*0.75,extent.maxY <= base.maxY+glyph*0.75 else { continue }
                total=total.union(extent)
            }
        }
        return total.isNull ? nil:total
    }

    static func retainedFragmentJoins(boxes:[NativeCoreMLDetectionBox],reads:[NativeCoreMLRecognizedRegion],
        layout:NativeRFDETRLayoutResult?,frame:NativeOCRRGBAFrame,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,threshold:Double)->[ColumnJoin] {
        typealias Basis=NativeOCRRFPrimaryEnsemble.EndpointFrame
        var output:[ColumnJoin]=[]
        let active=Set(reads.filter{$0.confidence >= threshold}.map(\.sourceIndex))
        for fragment in reads {
            let j=fragment.sourceIndex,letters=fragment.text.filter { $0.isLetter || $0.isNumber }
            guard boxes.indices.contains(j),fragment.confidence >= threshold,!fragment.text.isEmpty,
                  fragment.text.filter({!$0.isWhitespace}).count <= 3,letters.count <= 1,
                  boxes[j].detectorSeedEvidence?.isValid == true,
                  let style=inkStyles.flatMap({ $0.indices.contains(j) ? $0[j]:nil }) else { continue }
            let candidates=reads.compactMap { word -> ColumnJoin? in
                let i=word.sourceIndex
                guard i != j,boxes.indices.contains(i),word.confidence >= max(0.8,threshold),
                      word.text.filter({$0.isLetter || $0.isNumber}).count >= 2,
                      boxes[i].detectorSeedEvidence?.isValid == true,
                      let basis=Basis(word.polygon),let peer=Basis(boxes[j].polygon),
                      abs(basis.along.x*peer.along.x+basis.along.y*peer.along.y) >= 0.95 else { return nil }
                let a=basis.rect,b=basis.bounds(boxes[j].polygon),kept=basis.bounds(fragment.polygon),g=min(a.width,b.width)
                let omitted=max(0,kept.minY-b.minY),gap=b.minY-a.maxY
                guard g >= 5,a.height >= g*2,b.height <= g*3.2,max(a.width,b.width) <= g*1.6,
                      min(a.maxX,b.maxX)-max(a.minX,b.minX) >= g*0.8,abs(a.midX-b.midX) <= g*0.25,
                      gap >= -g*0.25,gap <= g*2.5,omitted <= g*1.5 else { return nil }
                let bridges=boxes.indices.filter { k in
                    guard k != i,k != j,!active.contains(k),boxes[k].score >= 0.5,
                          let evidence=boxes[k].detectorSeedEvidence,evidence.isValid,!evidence.components.isEmpty,
                          let f=Basis(boxes[k].polygon),abs(basis.along.x*f.along.x+basis.along.y*f.along.y) >= 0.95 else { return false }
                    let r=basis.bounds(boxes[k].polygon)
                    return r.width >= g*0.5 && r.width <= g*1.6 && r.height <= g*2.5 &&
                        min(a.maxX,r.maxX)-max(a.minX,r.minX) >= min(a.width,r.width)*0.8 &&
                        abs(a.midX-r.midX) <= min(a.width,r.width)*0.3 &&
                        r.minY >= a.maxY-g*0.25 && r.maxY <= b.minY+g*0.25
                }
                guard bridges.count <= 2,omitted >= g*0.25 || !bridges.isEmpty else { return nil }
                let bridgeRects=bridges.map { basis.bounds(boxes[$0].polygon) }.sorted {$0.minY < $1.minY}
                var cursor=a.maxY
                for r in bridgeRects {
                    guard r.minY-cursor <= g*0.9 else { return nil }
                    cursor=max(cursor,r.maxY)
                }
                guard b.minY-cursor <= g*0.9 else { return nil }
                let head=min(b.minY,bridgeRects.first?.minY ?? b.minY)
                let band=CGRect(x:min(a.minX,b.minX),y:head,width:max(a.maxX,b.maxX)-min(a.minX,b.minX),
                    height:max(kept.minY,b.minY)-head)
                guard fragmentHeadInk(band,basis:basis,frame:frame,palette:style.colors,glyph:g) else { return nil }
                let base=bridgeRects.reduce(a.union(b).union(kept)){$0.union($1)}
                let paint=fragmentPaintBounds(fragment:fragment.polygon,base:base,basis:basis,frame:frame,
                    palette:style.colors,glyph:g,peers:boxes.indices.filter { $0 != i && $0 != j && !bridges.contains($0) }.map { boxes[$0].polygon })
                let rect=base.insetBy(dx:-2,dy:-2).union(paint?.insetBy(dx:-2,dy:-2) ?? base)
                func quad(_ r:CGRect)->[CGPoint] { NativeOCRDirectionGeometry.corners(r).map(basis.restore) }
                let polygon=quad(rect)
                // Both sources are already retained. A shared local RF text
                // or SFX scope establishes locality without a whole-page text
                // envelope granting unrelated columns permission to join.
                guard layout?.primitives.contains(where:{ p in
                    (p.semanticClass == .text || p.semanticClass == .soundEffect) && p.confidence >= 0.4 &&
                        NativeOCRDirectionGeometry.area(NativeOCRDirectionAdapters.support(p)) < CGFloat(frame.width*frame.height)*0.8 &&
                        NativeOCRDirectionAdapters.coverage(polygon,by:p) >= 0.9
                }) == true else { return nil }
                let samplings=[polygon,quad(rect.insetBy(dx:-g*0.12,dy:-g*0.08))]
                guard samplings.flatMap({$0}).allSatisfy({$0.x >= 0 && $0.x <= CGFloat(frame.width) &&
                    $0.y >= 0 && $0.y <= CGFloat(frame.height)}),!reads.contains(where:{ third in
                        guard third.sourceIndex != i,third.sourceIndex != j,third.confidence >= threshold,
                              boxes.indices.contains(third.sourceIndex),
                              let evidence=boxes[third.sourceIndex].detectorSeedEvidence else { return false }
                        return samplesObservedGlyph(samplings,peerPolygon:third.polygon,evidence:evidence)
                    }) else { return nil }
                return .init(parent:i,recovered:j,polygon:polygon,samplings:samplings,
                    maximumInsertedGlyphs:bridges.count+Int(ceil(omitted/(g*0.8))),additionalSources:Set(bridges))
            }
            if candidates.count==1 { output.append(candidates[0]) }
        }
        let counts=Dictionary(grouping:output,by:\.parent)
        return output.filter { counts[$0.parent]?.count==1 }
    }

    /// A member-only terminal read can replace an existing multi-source read
    /// only when it has independently recognized that entire word and kept
    /// its full crop. The existing group's identity owns its original seeds.
    static func retainedTerminalGroup(prior:NativeCoreMLRecognizedRegion,
        candidate:NativeCoreMLRecognizedRegion,threshold:Double)->NativeCoreMLRecognizedRegion? {
        let content=NativeOCRRFPrimaryEnsemble.measuredTrimContent(prior.text)
        let area=NativeOCRDirectionGeometry.area(prior.polygon)
        guard prior.confidence >= threshold,candidate.confidence >= max(0.8,threshold),
              !content.isEmpty,content==NativeOCRRFPrimaryEnsemble.measuredTrimContent(candidate.text),
              area > 0,NativeOCRDirectionGeometry.intersectionArea(prior.polygon,candidate.polygon) >= area*0.95,
              NativeOCRRFPrimaryEnsemble.preservesRecognizedCore(candidate:candidate.text,
                confidence:candidate.confidence,baseline:prior.text,threshold:threshold,retainsOriginalSpan:true,
                confirmedTerminalCompletion:true) else { return nil }
        return .init(sourceIndex:prior.sourceIndex,polygon:candidate.polygon,text:candidate.text,
            confidence:candidate.confidence,tokenObservations:candidate.tokenObservations)
    }

    /// A supplemental join cannot consume a glyph already printed inside a
    /// different retained word. Both the original crop and shared detector
    /// cells must corroborate the existing owner; padding overlap is not ink.
    static func borrowsRetainedGlyph(members:[Int],boxes:[NativeCoreMLDetectionBox],
        reads:[NativeCoreMLRecognizedRegion],threshold:Double,retainedAliases:[Int:Set<Int>] = [:])->Bool {
        let membership=Set(members)
        for member in members {
            guard boxes.indices.contains(member),
                  let evidence=boxes[member].detectorSeedEvidence,evidence.isValid else { continue }
            let child=reads.first { $0.sourceIndex==member }
            let polygon=child?.polygon ?? boxes[member].polygon
            let content=child.map { NativeOCRRFPrimaryEnsemble.measuredTrimContent($0.text) } ?? ""
            let area=NativeOCRDirectionGeometry.area(polygon)
            guard area > 0 else { continue }
            for peer in reads where !membership.contains(peer.sourceIndex) &&
                peer.confidence >= max(0.8,threshold) && peer.text.filter({$0.isLetter || $0.isNumber}).count >= 2 {
                let transferred=retainedAliases[peer.sourceIndex]?.contains(member)==true
                guard transferred || (child.map { $0.confidence >= max(0.8,threshold) &&
                    $0.text.filter({$0.isLetter || $0.isNumber}).count==1 } == true && !content.isEmpty &&
                    NativeOCRRFPrimaryEnsemble.measuredTrimContent(peer.text).contains(content)) else { continue }
                guard boxes.indices.contains(peer.sourceIndex),
                      let owner=boxes[peer.sourceIndex].detectorSeedEvidence,owner.isValid,
                      NativeOCRDirectionGeometry.intersectionArea(polygon,boxes[peer.sourceIndex].polygon) >= area*0.95,
                      NativeOCRRFPrimaryEnsemble.retainsSharedGlyph(child:evidence,parent:owner,
                        childPolygon:polygon,container:peer.polygon) else { continue }
                return true
            }
        }
        return false
    }

    /// Complete a cut source glyph/counter using another private occurrence
    /// of the same printed shape, in the word's intrinsic frame. Colours are
    /// flooded separately so a contrasting rim cannot connect ink to paper.
    /// This only nominates crops; two actual reads must preserve the complete
    /// old word. It grants no new-letter or neighbouring-word permission.
    static func retainedGlyphTerminals(boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,retained:Set<Int>,
        peerPolygons:[Int:[CGPoint]],excluding:Set<Int>)->[Proposal] {
        struct Paint {
            let rect:CGRect
            let cells:[Int]
            let seeds:Int
            let shape:Set<Int>
        }
        var result:[Proposal]=[]
        for i in retained.sorted() where boxes.indices.contains(i) && !excluding.contains(i) {
            guard let original=peerPolygons[i],let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original),
                  let evidence=boxes[i].detectorSeedEvidence,evidence.isValid,
                  evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
                  !evidence.components.isEmpty,
                  let style=inkStyles.flatMap({$0.indices.contains(i) ? $0[i]:nil}) else { continue }
            let base=basis.rect,g=base.width
            guard g >= 8,base.height >= g*2 else { continue }
            let left=base.minX-g*0.75,top=base.minY-g*1.5
            let width=Int(ceil(g*2.5)),height=Int(ceil(base.height+g*3))
            guard width > 0,height > 0,width <= 262_144/height else { continue }
            var pixels=[[Int]](repeating:[],count:width*height)
            for y in 0..<height { for x in 0..<width {
                let world=basis.restore(.init(x:left+CGFloat(x)+0.5,y:top+CGFloat(y)+0.5))
                let xx=Int(floor(world.x)),yy=Int(floor(world.y))
                guard xx >= 0,xx < frame.width,yy >= 0,yy < frame.height else { continue }
                let at=yy*frame.bytesPerRow+xx*4
                pixels[y*width+x]=(0..<3).map {Int(frame.bytes[at+$0])}
            } }
            var anchors=Set<Int>()
            for component in evidence.components { for run in component.runs { for x in run.x..<(run.x+run.count) {
                let world=CGPoint(x:(CGFloat(x)+0.5)*CGFloat(frame.width)/CGFloat(evidence.mapFullWidth),
                    y:(CGFloat(run.y)+0.5)*CGFloat(frame.height)/CGFloat(evidence.mapFullHeight))
                guard NativeOCRDirectionGeometry.contains(original,world) else { continue }
                let p=basis.project(world),xx=Int(floor(p.x-left)),yy=Int(floor(p.y-top))
                if xx >= 0,xx < width,yy >= 0,yy < height { anchors.insert(yy*width+xx) }
            } } }
            var colours:[[Int]]=[],headPaint:Paint?,tailPaint:Paint?
            for colour in style.colors where colour.count==3 && !colours.contains(where:{
                zip($0,colour).map({abs($0-$1)}).max()! <= 48
            }) {
                colours.append(colour)
                guard colours.count <= 8 else { break }
                var mask=pixels.map { c in c.count==3 && zip(c,colour).allSatisfy {abs($0-$1)<=24} }
                var components:[Paint]=[]
                for seed in mask.indices where mask[seed] {
                    var cells=[seed],cursor=0,open=false,x0=width,x1=0,y0=height,y1=0,roots=0
                    mask[seed]=false
                    while cursor < cells.count {
                        let k=cells[cursor];cursor+=1;let x=k%width,y=k/width
                        x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                        if anchors.contains(k) { roots+=1 }
                        if x==0 || y==0 || x==width-1 || y==height-1 { open=true }
                        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                            let xx=x+dx,yy=y+dy
                            guard xx >= 0,xx < width,yy >= 0,yy < height else { continue }
                            let next=yy*width+xx
                            if mask[next] { mask[next]=false;cells.append(next) }
                        } }
                    }
                    let w=x1-x0+1,h=y1-y0+1
                    guard !open,cells.count >= max(3,Int(g*0.15)),CGFloat(w)<=g*1.7,CGFloat(h)<=g*1.7 else { continue }
                    // Raster cells occupy area. Mapping only their centres
                    // leaves phase-dependent holes when a small source glyph
                    // is enlarged to this comparison grid (especially at 45°).
                    var shape=Set<Int>()
                    for k in cells {
                        let x=k%width-x0,y=k/width-y0
                        let a=max(0,min(23,x*24/w)),b=max(0,min(23,((x+1)*24+w-1)/w-1))
                        let c=max(0,min(23,y*24/h)),d=max(0,min(23,((y+1)*24+h-1)/h-1))
                        for yy in c...d { for xx in a...b { shape.insert(yy*24+xx) } }
                    }
                    components.append(.init(rect:.init(x:left+CGFloat(x0),y:top+CGFloat(y0),
                        width:CGFloat(w),height:CGFloat(h)),cells:cells,seeds:roots,shape:shape))
                }
                let roots=components.filter {$0.seeds >= 2 && base.contains($0.rect) && $0.rect.height >= g*0.3}
                guard !roots.isEmpty else { continue }
                for c in components {
                    let r=c.rect
                    guard r.width >= g*0.3,r.width <= g*0.95,r.height >= g*0.3,r.height <= g*1.2,
                          c.cells.count >= Int(ceil(g)),abs(r.midX-base.midX)<=g*0.6 else { continue }
                    let head=r.minY < base.minY-2 && r.maxY >= base.minY-g*0.65 && r.maxY <= base.minY+g*0.25
                    let tail=r.maxY > base.maxY+2 && r.minY <= base.maxY+g*0.65 && r.minY >= base.maxY-g*0.8
                    guard head || tail,roots.contains(where:{ root in
                        let a=root.rect
                        guard min(a.width,r.width)>=max(a.width,r.width)*0.7,
                              min(a.height,r.height)>=max(a.height,r.height)*0.7 else {return false}
                        let union=root.shape.union(c.shape).count
                        return union > 0 && Double(root.shape.intersection(c.shape).count)/Double(union)>=0.6
                    }) else { continue }
                    // Completing ink already cut by this crop outranks a
                    // detached repetition farther into the following word.
                    if head,headPaint == nil || max(0,base.minY-r.maxY)<max(0,base.minY-headPaint!.rect.maxY) { headPaint=c }
                    if tail,tailPaint == nil || max(0,r.minY-base.maxY)<max(0,tailPaint!.rect.minY-base.maxY) { tailPaint=c }
                }
            }
            guard headPaint != nil || tailPaint != nil else { continue }
            var rect=base
            for c in [headPaint,tailPaint].compactMap({$0}) { rect=rect.union(c.rect.insetBy(dx:-2,dy:-2)) }
            let polygon=NativeOCRDirectionGeometry.corners(rect).map(basis.restore)
            let padded=NativeOCRDirectionGeometry.corners(rect.insetBy(dx:-g*0.08,dy:0)).map(basis.restore)
            guard (polygon+padded).allSatisfy({$0.x >= 0 && $0.x <= CGFloat(frame.width) && $0.y >= 0 && $0.y <= CGFloat(frame.height)}),
                  !peerPolygons.contains(where:{j,peer in
                    j != i && boxes.indices.contains(j) && boxes[j].detectorSeedEvidence.map {
                        samplesObservedGlyph([polygon,padded],peerPolygon:peer,evidence:$0,excludingPolygon:original)
                    } == true
                  }) else { continue }
            result.append(.init(parent:i,polygon:polygon,samplings:[polygon,padded],complements:[],
                independentGeometry:false,measuredTerminalOnly:true,sourceTerminalProof:polygon,
                sourceHeadCompletion:headPaint != nil,sourceTailCompletion:tailPaint != nil))
        }
        return result
    }

    /// New terminal punctuation needs measured ink at that exact end. Existing
    /// word letters and punctuation remain an uninterrupted preserved sequence.
    static func preservesNormalWord(candidate:String,baseline:String,head:Bool,tail:Bool)->Bool {
        let old=NativeOCRRFPrimaryEnsemble.measuredTrimSignature(baseline),new=NativeOCRRFPrimaryEnsemble.measuredTrimSignature(candidate)
        if old==new { return true }
        guard !old.isEmpty,head || tail,
              NativeOCRRFPrimaryEnsemble.measuredTrimContent(candidate)==NativeOCRRFPrimaryEnsemble.measuredTrimContent(baseline),
              let range=new.range(of:old) else { return false }
        let prefix=new[..<range.lowerBound],suffix=new[range.upperBound...]
        func punctuation(_ text:Substring)->Bool {
            text.unicodeScalars.allSatisfy { scalar in
                switch scalar.properties.generalCategory {
                case .openPunctuation,.closePunctuation,.initialPunctuation,.finalPunctuation,.otherPunctuation:return true
                default:return false
                }
            }
        }
        return (prefix.isEmpty || head) && (suffix.isEmpty || tail) && punctuation(prefix) && punctuation(suffix)
    }

    /// A punctuation train has no word core. Its source-rooted completion must
    /// preserve every existing non-dot mark, and can add punctuation only at
    /// the measured end. Dot tokenization itself is not a character count.
    private static func isSymbolicPoint(_ scalar:Unicode.Scalar)->Bool {
        scalar == "." || scalar == "·" || scalar == "・" || scalar == "‧"
    }

    static func isSymbolicPointTrain(_ text:String)->Bool {
        let normalized=text.precomposedStringWithCompatibilityMapping.filter { !$0.isWhitespace }
        return normalized.unicodeScalars.filter(isSymbolicPoint).count >= 2 && !normalized.isEmpty &&
            normalized.unicodeScalars.allSatisfy { CharacterSet.punctuationCharacters.contains($0) }
    }

    static func preservesSymbolicTerminal(candidate:String,baseline:String,head:Bool,tail:Bool)->Bool {
        guard isSymbolicPointTrain(baseline),head || tail else { return false }
        func signature(_ text:String)->String? {
            var result="",dot=false
            for scalar in text.precomposedStringWithCompatibilityMapping.unicodeScalars {
                if CharacterSet.whitespacesAndNewlines.contains(scalar) { continue }
                guard CharacterSet.punctuationCharacters.contains(scalar) else { return nil }
                if isSymbolicPoint(scalar) {
                    if !dot { result.append(".") };dot=true
                } else { result.unicodeScalars.append(scalar);dot=false }
            }
            return result
        }
        guard let old=signature(baseline),let new=signature(candidate),!old.isEmpty,
              let range=new.range(of:old) else { return false }
        return (range.lowerBound==new.startIndex || head) && (range.upperBound==new.endIndex || tail)
    }

    static func retainsConfirmedSymbolicTerminal(candidate:NativeCoreMLRecognizedRegion,
        baseline:String,confirmed:NativeCoreMLRecognizedRegion,head:Bool,tail:Bool)->Bool {
        candidate.sourceIndex==confirmed.sourceIndex && candidate.polygon==confirmed.polygon &&
            candidate.confidence >= confirmed.confidence &&
            NativeOCRRFPrimaryEnsemble.measuredTrimSignature(candidate.text) ==
                NativeOCRRFPrimaryEnsemble.measuredTrimSignature(confirmed.text) &&
            preservesSymbolicTerminal(candidate:candidate.text,baseline:baseline,head:head,tail:tail)
    }

    /// Join only a newly verified, formerly unread column fragment to one
    /// established word. This nominates observations; both full-column reads
    /// must still preserve both independently recognized word cores.
    static func recoveredColumnJoins(boxes:[NativeCoreMLDetectionBox],reads:[NativeCoreMLRecognizedRegion],
                                    recovered:Set<Int>,layout:NativeRFDETRLayoutResult?,
                                    inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,
                                    threshold:Double,width:Int,height:Int)->[ColumnJoin] {
        typealias Basis=NativeOCRRFPrimaryEnsemble.EndpointFrame
        var output:[ColumnJoin]=[]
        for source in reads where recovered.contains(source.sourceIndex) {
            let i=source.sourceIndex
            guard boxes.indices.contains(i),boxes[i].score >= 0.8,
                  boxes[i].detectorSeedEvidence?.isValid == true,
                  let raw=Basis(boxes[i].polygon),raw.rect.height > raw.rect.width*3.2,
                  source.confidence >= threshold,source.text.filter({$0.isLetter || $0.isNumber}).count >= 2,
                  let basis=Basis(source.polygon),inkStyles?[i] != nil else { continue }
            let candidates=reads.compactMap { peer -> ColumnJoin? in
                let j=peer.sourceIndex
                guard j != i,!recovered.contains(j),boxes.indices.contains(j),
                      peer.confidence >= max(0.8,threshold),
                      peer.text.filter({$0.isLetter || $0.isNumber}).count >= 2,
                      boxes[j].detectorSeedEvidence?.isValid == true,inkStyles?[j] != nil,
                      !NativeOCRRFPrimaryEnsemble.distinctEndpointInk(inkStyles?[i],inkStyles?[j]),
                      inkStyles?[i]?.colors.contains(where:{ a in
                          inkStyles?[j]?.colors.contains(where:{ b in
                              a.count==3 && b.count==3 && zip(a,b).map { abs($0-$1) }.max()! <= 48
                          }) == true
                      }) == true,
                      let other=Basis(peer.polygon),
                      abs(basis.along.x*other.along.x+basis.along.y*other.along.y) >= 0.95 else { return nil }
                let a=basis.rect,b=basis.bounds(peer.polygon),g=min(a.width,b.width)
                let overlap=min(a.maxX,b.maxX)-max(a.minX,b.minX)
                let gap=max(a.minY-b.maxY,b.minY-a.maxY,0)
                let alongOverlap=min(a.maxY,b.maxY)-max(a.minY,b.minY)
                guard g >= 5,max(a.width,b.width) <= g*1.6,overlap >= g*0.8,
                      abs(a.midX-b.midX) <= g*0.25,gap <= g*0.9,alongOverlap <= g,
                      min(a.height,b.height) >= g*2 else { return nil }
                let rect=a.union(b)
                func quad(_ r:CGRect)->[CGPoint] { NativeOCRDirectionGeometry.corners(r).map(basis.restore) }
                let polygon=quad(rect)
                guard layout?.primitives.contains(where:{ p in
                    p.semanticClass == .text && p.confidence >= 0.4 &&
                        NativeOCRDirectionAdapters.coverage(polygon,by:p) >= 0.9
                }) == true,
                      layout?.primitives.contains(where:{ p in
                    p.semanticClass == .soundEffect && p.confidence >= 0.25 &&
                        NativeOCRDirectionAdapters.coverage(polygon,by:p) >= 0.3
                }) != true else { return nil }
                let samplings:[ [CGPoint] ]=[0.12,0.24].map { quad(rect.insetBy(dx:-rect.width*$0,dy:-rect.width*$0)) }
                guard samplings.flatMap({$0}).allSatisfy({$0.x >= 0 && $0.x <= CGFloat(width) && $0.y >= 0 && $0.y <= CGFloat(height)}),
                      !reads.contains(where:{ third in
                    guard third.sourceIndex != i,third.sourceIndex != j,third.confidence >= threshold,
                          boxes.indices.contains(third.sourceIndex),
                          let evidence=boxes[third.sourceIndex].detectorSeedEvidence else { return false }
                    return samplesObservedGlyph(samplings,peerPolygon:third.polygon,evidence:evidence)
                }) else { return nil }
                return ColumnJoin(parent:j,recovered:i,polygon:polygon,samplings:samplings)
            }
            if candidates.count==1 { output.append(candidates[0]) }
        }
        // Competing newly recovered fragments cannot independently consume
        // the same retained word in one recognition batch.
        let counts=Dictionary(grouping:output,by: \.parent)
        return output.filter { counts[$0.parent]?.count==1 }
    }

    /// A narrow shared detector component touching this source can be its
    /// clipped mark or small glyph. Sharing a broad multi-column component
    /// does not grant the same continuation permission.
    static func sharedContinuationSeeds(evidence:NativeOCRDetectorSeedEvidence,source:[CGPoint],
                                        reference:[CGPoint])->Set<Int> {
        guard evidence.isValid,let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(reference) else { return [] }
        let original=f.bounds(source),glyph=min(original.width,f.rect.width)
        guard glyph >= 5 else { return [] }
        let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth),
            sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
        var seeds=Set<Int>()
        for c in evidence.components+(evidence.ambiguousComponents ?? [])+(evidence.candidateComponents ?? []).map(\.component)
            where c.meanProbability >= evidence.threshold {
            var bounds=CGRect.null,inside=0
            for run in c.runs { for x in run.x..<(run.x+run.count) {
                let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                bounds=bounds.union(CGRect(origin:f.project(p),size:.zero))
                if NativeOCRDirectionGeometry.contains(source,p) { inside+=1 }
            } }
            bounds=bounds.insetBy(dx:-(abs(f.across.x)*sx+abs(f.across.y)*sy)/2,
                dy:-(abs(f.along.x)*sx+abs(f.along.y)*sy)/2)
            let gap=max(original.minY-bounds.maxY,bounds.minY-original.maxY,0)
            if inside >= 2,bounds.width <= glyph*0.6,bounds.height <= glyph*3,gap <= glyph,
               abs(bounds.midX-original.midX) <= glyph*0.35 { seeds.insert(c.seed) }
        }
        return seeds
    }

    /// Recheck newly committed reads when several proposals were recognized
    /// together. A proposal made before a neighbour recovered its first glyph
    /// must not claim that same glyph after the neighbour has committed it.
    static func samplesObservedGlyph(_ samplings:[[CGPoint]],peerPolygon:[CGPoint],
                                     evidence:NativeOCRDetectorSeedEvidence,excludingSeeds:Set<Int> = [],excludingPolygon:[CGPoint]? = nil,contestedCandidateSeeds:Set<Int> = [])->Bool {
        guard evidence.isValid else { return false }
        let sx=CGFloat(evidence.sourceWidth)/CGFloat(evidence.mapFullWidth),
            sy=CGFloat(evidence.sourceHeight)/CGFloat(evidence.mapFullHeight)
        var cells=Set<Int>()
        let exclusive=(evidence.candidateComponents ?? []).filter { c in
            !contestedCandidateSeeds.contains(c.component.seed) &&
            c.outsideCompetingCells.allSatisfy { $0*5 >= c.component.pixelCount*4 }
        }.map(\.component)
        let parts=evidence.components+exclusive
        for c in parts where c.meanProbability >= evidence.threshold && !excludingSeeds.contains(c.seed) {
            for run in c.runs { for x in run.x..<(run.x+run.count) {
                let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                if NativeOCRDirectionGeometry.contains(peerPolygon,p),
                   !(excludingPolygon.map { NativeOCRDirectionGeometry.contains($0,p) } ?? false),
                   samplings.contains(where:{NativeOCRDirectionGeometry.contains($0,p)}) {
                    cells.insert(run.y*evidence.mapFullWidth+x)
                    if cells.count >= 2 { return true }
                }
            } }
        }
        return false
    }

    /// A word-preserving re-read does not newly acquire its old private glyphs.
    /// Fresh words and changed identities still require the full ownership
    /// recheck; any new pixels outside this old observed span remain barriers.
    static func unchangedObservedWordSpan(before: NativeCoreMLRecognizedRegion?,
        after: NativeCoreMLRecognizedRegion, threshold: Double) -> [CGPoint]? {
        guard let before,before.sourceIndex==after.sourceIndex,before.confidence >= threshold,
              before.text.filter({$0.isLetter || $0.isNumber}).count >= 2,
              NativeOCRRFPrimaryEnsemble.measuredTrimContent(before.text) ==
                NativeOCRRFPrimaryEnsemble.measuredTrimContent(after.text) else { return nil }
        return before.polygon
    }

    /// Complete only measured point tails of words already read by REC.
    /// No new source, leading extent, width or direction can be nominated here.
    static func retainedPointTails(boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,retained:Set<Int>,
        peerPolygons:[Int:[CGPoint]],excluding:Set<Int>,layout:NativeRFDETRLayoutResult? = nil,
        groups:[NativeOCRRFPrimaryEnsemble.Group] = [],audit:((Int,String)->Void)? = nil,
        terminalCapParents:Set<Int> = [])->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk else { return [] }
        var result:[Proposal]=[]
        for i in retained.sorted() where !excluding.contains(i) && boxes.indices.contains(i) {
            audit?(i,"point-tail start")
            var pointSources=Set<Int>()
            guard let original=peerPolygons[i],let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original),
                  let styles=inkStyles else { continue }
            // A real grouped read owns its original member components even
            // though its synthetic detector box has no single seed evidence.
            // Measure each member in that actual word's intrinsic frame.
            let group=groups.first { $0.index==i }
            let members=group?.members ?? [i],represented=Set(members)
            let unread=Set(boxes.indices).subtracting(peerPolygons.keys).subtracting(represented)
            var palette:[[Int]]=[]
            for member in members where styles.indices.contains(member) {
                for colour in styles[member]?.colors ?? [] where !palette.contains(colour) { palette.append(colour) }
            }
            var measuredProof:[CGPoint]?
            for member in members where boxes.indices.contains(member) && styles.indices.contains(member) {
                // Recalibrate these already observed word colours against the
                // member's own cells. A colour absent from its pixels still
                // obtains no anchors; this cannot borrow an unrelated layer.
                let style=group == nil ? styles[member]:.init(colors:palette)
                if let proof=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:member,boxes:boxes,frame:frame,
                    inkStyle:style,allowingPeers:represented,sourceWindow:original,
                    audit:{ audit?(i,"point-kernel \($0)") },observedSource:original,
                    unreadPeers:unread,pointSourceObserver:{pointSources.formUnion($0)},allowTerminalCap:terminalCapParents.contains(i)) {
                    measuredProof=measuredProof.map {
                        NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(base:$0,supplement:proof,minimumChange:0)
                    } ?? proof
                }
            }
            guard let proof=measuredProof else { audit?(i,"no point proof");continue }
            var measured=basis.bounds(proof)
            if !pointSources.isEmpty {
                let evidence=(group?.evidence ?? boxes[i].detectorSeedEvidence.map {[$0]} ?? []) +
                    pointSources.sorted().compactMap {boxes[$0].detectorSeedEvidence}
                if let contour=endpointGlyphContour(polygon:proof,evidence:evidence,frame:frame,head:false) {
                    measured=measured.union(contour)
                }
            }
            var end=measured.maxY
            // The observed point train roots a bounded observation of its
            // adjacent end symbol. Use admitted RGB ink, never padded search
            // extents, and still require two real word-preserving decodes.
            if let layout {
                var ink:[CGPoint]?
                _ = NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:i,boxes:boxes,
                    layout:layout,frame:frame,terminalOnly:true,inkStyles:inkStyles,inkObserver:{ink=$0})
                if let ink {
                    let cap=basis.bounds(ink).maxY
                    if cap > end,cap-end <= basis.rect.width*2 { end=cap }
                }
            }
            guard end > basis.rect.maxY+2 else { audit?(i,"no novel tail");continue }
            measured=CGRect(x:measured.minX,y:basis.rect.minY,width:measured.width,height:end-basis.rect.minY)
            let polygon=NativeOCRDirectionGeometry.corners(measured).map(basis.restore)
            let samples=[CGFloat(0.12),0.24].map { padding in
                NativeOCRDirectionGeometry.corners(measured.insetBy(dx:0,
                    dy:-basis.rect.width*padding)).map(basis.restore)
            }
            guard samples.flatMap({$0}).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}) else { continue }
            guard !retained.contains(where:{ j in
                guard j != i,let peer=peerPolygons[j],let evidence=boxes[j].detectorSeedEvidence else { return false }
                // A candidate shared with this source is not this peer's
                // private glyph merely because most of its CC lies outside
                // the competing rectangle. Keep all truly private peer cells.
                let own=boxes[i].detectorSeedEvidence
                var ownParts=own?.components ?? []
                ownParts += own?.ambiguousComponents ?? []
                ownParts += (own?.candidateComponents ?? []).map(\.component)
                let ownSeeds=Set(ownParts.map(\.seed))
                let contested=Set((evidence.candidateComponents ?? []).filter {
                    $0.competingOwnerIDs.contains(own?.ownerID ?? "") &&
                    ownSeeds.contains($0.component.seed)
                }.map { $0.component.seed })
                let blocked=samplesObservedGlyph(samples,peerPolygon:peer,evidence:evidence,
                    excludingPolygon:original,contestedCandidateSeeds:contested)
                if blocked { audit?(i,"sampling borrows peer=\(j)") }
                return blocked
            }) else { continue }
            // The entire aliased source must remain inside the measured crop;
            // a few dots at its edge cannot transfer ownership of unseen ink.
            let originalEvidence=group?.evidence ?? boxes[i].detectorSeedEvidence.map { [$0] }
            guard pointSources.isEmpty || NativeOCRDetectorSeedEvidence.preservingUnion(
                [originalEvidence]+pointSources.sorted().map { boxes[$0].detectorSeedEvidence.map { [$0] } }) != nil else { continue }
            guard pointSources.allSatisfy({ j in
                let area=NativeOCRDirectionGeometry.area(boxes[j].polygon)
                if area > 0 && NativeOCRDirectionGeometry.intersectionArea(boxes[j].polygon,polygon) >= area*0.95 {return true}
                // Detector/retry padding can extend beyond a closed cap.
                // Preserve every owned ink cell instead of importing its
                // empty rectangle into the recovered word.
                guard terminalCapParents.contains(i),basis.bounds(proof).width > basis.rect.width+1,
                      let evidence=boxes[j].detectorSeedEvidence,evidence.isValid else {return false}
                let sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth)
                let sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
                let allowed=measured.insetBy(dx:-max(sx,sy),dy:-max(sx,sy))
                var total=0,covered=0
                for component in evidence.components {for run in component.runs {for x in run.x..<(run.x+run.count) {
                    total+=1
                    if allowed.contains(basis.project(.init(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy))) {covered+=1}
                }}}
                return total>=4 && covered*100>=total*98
            }) else { audit?(i,"point source extends outside proof");continue }
            result.append(.init(parent:i,polygon:polygon,samplings:samples,complements:[],
                independentGeometry:false,pointTailOnly:true,pointSources:pointSources))
        }
        return Array(result.prefix(16))
    }

    /// Observe a closed original-paint component crossing an accepted glyph
    /// boundary. Rasterize in the word's frame, so a rotation cannot change
    /// the observation budget. Private detector cells teach colours; a closed
    /// same-glyph component, never a search window, supplies the added extent.
    static func endpointGlyphContour(polygon:[CGPoint],evidence:[NativeOCRDetectorSeedEvidence],
        frame:NativeOCRRGBAFrame,head:Bool)->CGRect? {
        guard let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(polygon),!evidence.isEmpty,
              evidence.allSatisfy({$0.isValid && $0.sourceWidth==frame.width && $0.sourceHeight==frame.height}) else { return nil }
        // Replay-only geometry guard. Colour continuity and unchanged OCR
        // do not establish ownership of a newly acquired lateral strip.
        // Keep legacy recovery until full-corpus no-loss replay admits this.
        let sourceOwnedGrowth = ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_OWNED_CONTOUR_GROWTH"] == "1"
        let base=basis.rect,g=base.width,span=min(g*1.25,base.height)
        guard g >= 8,span >= g else { return nil }
        let left=base.minX-g*0.75,top=head ? base.minY-g*0.75:base.maxY-span-g*0.75
        let step=max(CGFloat(1),ceil(sqrt((g*2.5)*(span+g*1.5)/262_144)))
        let width=Int(ceil(g*2.5/step)),height=Int(ceil((span+g*1.5)/step)),count=width*height
        guard width > 2,height > 2,count <= 262_144 else { return nil }
        var rgb=[UInt8](repeating:0,count:count*3),valid=[Bool](repeating:false,count:count),inside=valid,roots=valid,owned=valid
        for y in 0..<height { for x in 0..<width {
            let p=basis.restore(.init(x:left+(CGFloat(x)+0.5)*step,y:top+(CGFloat(y)+0.5)*step))
            let xx=Int(floor(p.x)),yy=Int(floor(p.y)),k=y*width+x
            guard xx >= 0,xx < frame.width,yy >= 0,yy < frame.height else { continue }
            valid[k]=true;inside[k]=NativeOCRDirectionGeometry.contains(polygon,p)
            let at=yy*frame.bytesPerRow+xx*4
            for c in 0..<3 {rgb[k*3+c]=frame.bytes[at+c]}
        } }
        var grid:CGFloat=1
        for e in evidence {
            let sx=CGFloat(e.sourceWidth)/CGFloat(e.mapFullWidth),sy=CGFloat(e.sourceHeight)/CGFloat(e.mapFullHeight)
            grid=max(grid,sx,sy)
            let radius=max(1,Int(ceil(hypot(sx,sy)/(2*step))))
            for component in e.components { for run in component.runs { for x in run.x..<(run.x+run.count) {
                let p=basis.project(.init(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy))
                let xx=Int(floor((p.x-left)/step)),yy=Int(floor((p.y-top)/step))
                guard xx >= -radius,xx < width+radius,yy >= -radius,yy < height+radius else { continue }
                for row in max(0,yy-radius)...min(height-1,yy+radius) {
                    for col in max(0,xx-radius)...min(width-1,xx+radius) {
                        let k=row*width+col
                        // Only private components establish lateral ownership;
                        // ambiguous/candidate cells cannot acquire a side band.
                        if sourceOwnedGrowth && valid[k] {owned[k]=true}
                        if inside[k] {roots[k]=true}
                    }
                }
            } } }
        }
        var bins:[Int:[Int]]=[:]
        for k in roots.indices where roots[k] && valid[k] {
            let key=(Int(rgb[k*3])/16)*256+(Int(rgb[k*3+1])/16)*16+Int(rgb[k*3+2])/16
            bins[key,default:[]].append(k)
        }
        struct Paint {let rect:CGRect;let roots:Int;let mass:Int;let colour:[Int];let onPaper:Bool;let expands:Bool}
        var paints:[Paint]=[],privateInk:[Paint]=[]
        let ranked=bins.sorted {$0.value.count != $1.value.count ? $0.value.count > $1.value.count:$0.key < $1.key}
        for (_,samples) in ranked.prefix(16) where samples.count >= 8 {
            let colour=(0..<3).map { c in samples.map {Int(rgb[$0*3+c])}.sorted()[samples.count/2] }
            let chroma=colour.max()!-colour.min()!
            var mask=valid.indices.map { k in
                guard valid[k],(0..<3).allSatisfy({abs(Int(rgb[k*3+$0])-colour[$0]) <= 32}) else {return false}
                let channels=(0..<3).map {Int(rgb[k*3+$0])}
                return chroma < 48 || (channels.max()!-channels.min()!)*4 >= chroma*3
            }
            var rim=0,rimMatching=0
            for k in valid.indices where valid[k] && (k%width==0 || k%width==width-1 || k/width==0 || k/width==height-1) {
                rim+=1;if mask[k] {rimMatching+=1}
            }
            let onPaper=rim > 0 && rimMatching*10 >= rim
            for seed in mask.indices where mask[seed] {
                var queue=[seed],cursor=0,x0=width,x1=0,y0=height,y1=0,privateCount=0,oldCount=0,open=false
                var leftOwned=0,rightOwned=0,leftEdge=CGFloat.infinity,rightEdge = -CGFloat.infinity
                mask[seed]=false
                while cursor < queue.count {
                    let k=queue[cursor];cursor+=1;let x=k%width,y=k/width
                    x0=min(x0,x);x1=max(x1,x);y0=min(y0,y);y1=max(y1,y)
                    if roots[k] {privateCount+=1};if inside[k] {oldCount+=1}
                    if sourceOwnedGrowth && owned[k] {
                        let px=left+(CGFloat(x)+0.5)*step
                        if px < base.minX {leftOwned+=1;leftEdge=min(leftEdge,px)}
                        if px > base.maxX {rightOwned+=1;rightEdge=max(rightEdge,px)}
                    }
                    if x==0 || y==0 || x==width-1 || y==height-1 {open=true}
                    for dy in -1...1 {for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx=x+dx,yy=y+dy
                        guard xx >= 0,xx < width,yy >= 0,yy < height else {continue}
                        let n=yy*width+xx
                        if !valid[n] {open=true}
                        if mask[n] {mask[n]=false;queue.append(n)}
                    }}
                }
                let box=CGRect(x:left+CGFloat(x0)*step,y:top+CGFloat(y0)*step,
                    width:CGFloat(x1-x0+1)*step,height:CGFloat(y1-y0+1)*step)
                guard !open,privateCount >= max(4,Int(g*0.04/step)),queue.count >= max(8,Int(g*0.25/step)),
                      oldCount*100 >= queue.count*35,queue.count*100 <= (x1-x0+1)*(y1-y0+1)*80,
                      box.width <= g*1.9,box.height <= g*1.9,
                      (head ? box.minY <= base.minY+g*0.5:box.maxY >= base.maxY-g*0.5) else {continue}
                if sourceOwnedGrowth {
                    // Raster/grid uncertainty permits a thin outline rim.
                    // A material side expansion needs this very paint CC's
                    // private cells in that strip, reaching its outer edge.
                    // Interior roots alone cannot certify connected artwork.
                    let rim=max(step*2,grid)
                    let witnesses=max(4,Int(ceil(grid/step)))
                    guard (box.minX >= base.minX-rim ||
                        (leftOwned >= witnesses && leftEdge <= box.minX+rim)),
                        (box.maxX <= base.maxX+rim ||
                        (rightOwned >= witnesses && rightEdge >= box.maxX-rim)) else {continue}
                }
                let change=max(2*step,g*0.15)
                let expands=box.minX < base.minX-change || box.maxX > base.maxX+change ||
                    (head ? box.minY < base.minY-change:box.maxY > base.maxY+change)
                let paint=Paint(rect:box,roots:privateCount,mass:queue.count,colour:colour,onPaper:onPaper,expands:expands)
                privateInk.append(paint)
                if box.width >= g*0.3,box.height >= g*0.35 {paints.append(paint)}
            }
        }
        let tolerance=max(step*2,grid*2)
        func aligned(_ a:CGRect,_ b:CGRect)->Bool {
            abs(a.minX-b.minX)<=tolerance && abs(a.maxX-b.maxX)<=tolerance &&
                abs(a.minY-b.minY)<=tolerance && abs(a.maxY-b.maxY)<=tolerance
        }
        // A closed counter can expose the same colour as the surrounding
        // paper. That colour alone is not print evidence. Require a different
        // source-owned colour tracing the same boundary; solid paper panels
        // also lack the nonrectangular occupied shape required above.
        let eligible=paints.filter { p in !p.onPaper || paints.contains { other in
            (!p.expands || other.expands) &&
                zip(p.colour,other.colour).map({abs($0-$1)}).max()! >= 48 && aligned(p.rect,other.rect)
        } }
        // A shared white halo can connect two differently coloured rows.
        // Its new outer boundary must also be reached by this source's own
        // observed chromatic paint, rather than a neighbouring row's fill.
        // Detector cells also contain background pixels. Only a closed,
        // privately rooted ink component may establish a coloured fill
        // that constrains a neutral outline. An open coloured background
        // must never prevent a genuinely white glyph from completing.
        let sourceChromatic=privateInk.filter {
            !$0.onPaper && $0.colour.max()!-$0.colour.min()! >= 48
        }.map {($0.colour,$0.roots)}
        func completesSmallEndpoint(_ p:Paint)->Bool {
            // Novelty is measured at the terminal's own resolved glyph scale,
            // with the same pixel floor, rather than the larger word envelope.
            let glyph=min(g,max(p.rect.width,p.rect.height))
            let change=max(2*step,glyph*0.08)
            return head ? p.rect.minY < base.minY-change:p.rect.maxY > base.maxY+change
        }
        let colourVerified=eligible.filter { candidate in
            // A thin coloured rim is not the fill of a strongly observed
            // neutral glyph. It cannot overrule its larger private ink body.
            guard candidate.expands || completesSmallEndpoint(candidate),
                  candidate.colour.max()!-candidate.colour.min()! < 48,
                  let strongest=sourceChromatic.map({$0.1}).max(),
                  strongest*4 >= candidate.roots else {return true}
            let colours=sourceChromatic.filter {$0.1*4 >= strongest}.map(\.0)
            let margin=max(tolerance,g*0.08+step*2),change=max(2*step,g*0.15),endChange=max(2*step,g*0.08)
            let ink=privateInk.filter { p in
                p.colour.max()!-p.colour.min()! >= 48 &&
                    zip(p.colour,candidate.colour).map({abs($0-$1)}).max()! >= 48 &&
                    colours.contains { zip($0,p.colour).allSatisfy {abs($0-$1)<=32} } &&
                    candidate.rect.insetBy(dx:-margin,dy:-margin).contains(p.rect)
            }
            let box=candidate.rect
            return (box.minX >= base.minX-change || ink.contains {$0.rect.minX <= box.minX+margin}) &&
                (box.maxX <= base.maxX+change || ink.contains {$0.rect.maxX >= box.maxX-margin}) &&
                (!head || box.minY >= base.minY-endChange || ink.contains {$0.rect.minY <= box.minY+margin}) &&
                (head || box.maxY <= base.maxY+endChange || ink.contains {$0.rect.maxY >= box.maxY-margin})
        }
        guard let primary=colourVerified.max(by:{$0.roots != $1.roots ? $0.roots < $1.roots:$0.mass < $1.mass}) else {return nil}
        if !primary.expands {
            // A glyph's closed counter/fill may carry more private detector
            // cells than its outline. Rank those as layers of the same source,
            // rather than allowing the in-crop fill to veto its own outer cap.
            // Every outer layer is independently closed, colour-verified and
            // privately rooted. Nearby side islands do not contain this glyph.
            let layers=colourVerified.filter { p in
                guard !p.onPaper,p.expands,p.roots*8 >= primary.roots,
                      p.mass*3 >= primary.mass,
                      zip(p.colour,primary.colour).map({abs($0-$1)}).max()! >= 48,
                      p.rect.insetBy(dx:-tolerance,dy:-tolerance).contains(primary.rect),
                      p.rect.width <= primary.rect.width*2,
                      p.rect.height <= primary.rect.height*2 else {return false}
                return primary.rect.minX-p.rect.minX <= g*0.5 &&
                    p.rect.maxX-primary.rect.maxX <= g*0.5 &&
                    primary.rect.minY-p.rect.minY <= g*0.5 &&
                    p.rect.maxY-primary.rect.maxY <= g*0.5
            }
            if let layer=layers.max(by:{$0.roots < $1.roots}) {
                let peers=layers.filter {aligned($0.rect,layer.rect)}
                return peers.reduce(layer.rect) {$0.union($1.rect)}.insetBy(dx:-step*2,dy:-step*2)
            }
            // A large complete letter does not invalidate a smaller terminal
            // letter of the same owned print. The latter must carry its own
            // substantial private support and actually cross the word end;
            // a weak side island cannot borrow the dominant letter's colour.
            // A compact coloured terminal has its own glyph scale: a heart
            // or small kana need not be .35 of the preceding full-size glyph.
            // Neutral paint still needs the existing paper/colour checks.
            let compactChromatic=privateInk.filter { p in
                !p.onPaper && p.colour.max()!-p.colour.min()! >= 48 &&
                    p.rect.width >= g*0.2 && p.rect.height >= g*0.2
            }
            let terminal=(colourVerified+compactChromatic).filter { p in
                // A thin private DB core can cover less than a quarter of the
                // original-pixel glyph. Require both substantial pixel count
                // at this component's scale and a distributed occupied share.
                let witnessed=p.roots >= max(16,Int(min(p.rect.width,p.rect.height)/step)) &&
                    p.roots*12 >= p.mass
                return !p.onPaper && (p.roots*4 >= p.mass || witnessed) && completesSmallEndpoint(p) &&
                    zip(p.colour,primary.colour).allSatisfy {abs($0-$1)<=32}
            }
            guard let first=terminal.first else {return nil}
            return terminal.dropFirst().reduce(first.rect) {$0.union($1.rect)}.insetBy(dx:-step*2,dy:-step*2)
        }
        // Complete in-crop counters may veto a weaker expansion, but cannot
        // corroborate a new outside paper island or enlarge its measured rim.
        // Every returned layer therefore qualified for expansion independently.
        // Other colour layers can add their measured thin rim, not a remote
        // branch reached by a looser colour family through surrounding art.
        let peers=colourVerified.filter {$0.expands && aligned($0.rect,primary.rect)}
        return peers.reduce(primary.rect) {$0.union($1.rect)}.insetBy(dx:-step*2,dy:-step*2)
    }

    /// Pure geometry proposal, callable on an individual detector/correction
    /// quad before recognition admission. No decoded text, confidence, GT or
    /// source identity enters the contour/ownership decision. Returning a
    /// proposal does not mean the caller selected it as actual output.
    static func endpointGlyphContourGeometry(polygon sourcePolygon:[CGPoint],
        evidence:[NativeOCRDetectorSeedEvidence],frame:NativeOCRRGBAFrame)
        -> (polygon:[CGPoint],padded:[CGPoint],ink:[[CGPoint]],head:Bool,tail:Bool)? {
        guard let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(sourcePolygon) else {return nil}
        let sourceOwnedGrowth = ProcessInfo.processInfo.environment["AIDOKU_OCR_SOURCE_OWNED_CONTOUR_GROWTH"] == "1"
        var measured=basis.rect,ink:[[CGPoint]]=[],head=false,tail=false
        for atHead in [true,false] {
            if let contour=endpointGlyphContour(polygon:sourcePolygon,evidence:evidence,frame:frame,head:atHead) {
                measured=measured.union(contour);ink.append(NativeOCRDirectionGeometry.corners(contour).map(basis.restore))
                if sourceOwnedGrowth {
                    // A side-only contour is not evidence of a new terminal.
                    // Keep independently witnessed lateral glyph recovery,
                    // but never label an interior component as a head/tail.
                    let change=max(2,basis.rect.width*0.08)
                    if atHead && contour.minY < basis.rect.minY-change {head=true}
                    if !atHead && contour.maxY > basis.rect.maxY+change {tail=true}
                } else if atHead {head=true} else {tail=true}
            }
        }
        guard !ink.isEmpty else {return nil}
        // Resize the accepted quad in its own frame. Replacing it with
        // an enclosing rectangle would lose its original skew and could
        // swap the recognizer's long/short sampling edges for a row.
        func resized(_ rect:CGRect)->[CGPoint] {
            sourcePolygon.map { p in
                var q=basis.project(p)
                let u=(q.x-basis.rect.minX)/basis.rect.width,v=(q.y-basis.rect.minY)/basis.rect.height
                q.x+=(1-u)*(rect.minX-basis.rect.minX)+u*(rect.maxX-basis.rect.maxX)
                q.y+=(1-v)*(rect.minY-basis.rect.minY)+v*(rect.maxY-basis.rect.maxY)
                return basis.restore(q)
            }
        }
        let polygon=resized(measured)
        let padded=resized(measured.insetBy(dx:-max(2,basis.rect.width*0.06),dy:-2))
        guard (polygon+padded).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
            $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}) else {return nil}
        return (polygon,padded,ink,head,tail)
    }

    static func retainedEndpointGlyphContours(boxes:[NativeCoreMLDetectionBox],reads:[NativeCoreMLRecognizedRegion],
        groups:[NativeOCRRFPrimaryEnsemble.Group],frame:NativeOCRRGBAFrame,threshold:Double)->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk else {return []}
        var result:[Proposal]=[]
        let retainedGroups=Set(reads.filter {$0.confidence >= threshold}.map(\.sourceIndex))
        // A retained full word is the physical source identity. Its fragment
        // alternatives cannot replace that word with a shorter, newly widened
        // member and silently lose the other detector owners during dedup.
        let groupedMembers=Set(groups.filter {retainedGroups.contains($0.index)}.flatMap(\.members))
        for read in reads where read.confidence >= threshold && read.text.contains(where:{$0.isLetter || $0.isNumber}) {
            guard !groupedMembers.contains(read.sourceIndex) else {continue}
            guard boxes.indices.contains(read.sourceIndex),
                  let evidence=groups.first(where:{$0.index==read.sourceIndex})?.evidence ??
                    boxes[read.sourceIndex].detectorSeedEvidence.map({[$0]}) else {continue}
            guard let geometry=endpointGlyphContourGeometry(polygon:read.polygon,evidence:evidence,frame:frame) else {continue}
            let polygon=geometry.polygon,padded=geometry.padded,ink=geometry.ink
            let head=geometry.head,tail=geometry.tail
            guard (polygon+padded).allSatisfy({$0.x >= 0 && $0.y >= 0 && $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}),
                  !reads.contains(where:{ peer in
                    guard peer.sourceIndex != read.sourceIndex,peer.confidence >= threshold,
                          boxes.indices.contains(peer.sourceIndex),let own=boxes[peer.sourceIndex].detectorSeedEvidence else {return false}
                    return samplesObservedGlyph([polygon,padded],peerPolygon:peer.polygon,evidence:own,excludingPolygon:read.polygon)
                  }) else {continue}
            result.append(.init(parent:read.sourceIndex,polygon:polygon,samplings:[polygon,padded],complements:[],
                independentGeometry:false,measuredGlyphContourOnly:true,sourceTerminalProof:polygon,
                sourceTerminalInk:ink,sourceHeadCompletion:head,sourceTailCompletion:tail))
            // A wide decorative initial glyph and smaller following letters
            // can respond differently to extra padding. The retained crop is
            // also a real independent tensor. It may confirm an unchanged
            // word seen in ONE complete measured crop, never new word content.
            for sample in [polygon,padded] {
                result.append(.init(parent:read.sourceIndex,polygon:polygon,samplings:[sample,read.polygon],complements:[],
                    independentGeometry:false,measuredGlyphContourOnly:true,retainedGlyphWordConfirmation:true,
                    sourceTerminalProof:polygon,sourceTerminalInk:ink,sourceHeadCompletion:head,sourceTailCompletion:tail))
            }
        }
        return result
    }

    /// Finish an already decoded terminal stroke when it bends out of the
    /// original lane. Follow connected, paired print colours across the crop
    /// edge; a window boundary or an unmeasured pixel is never a stroke cap.
    static func retainedCurvedStrokeTerminals(boxes:[NativeCoreMLDetectionBox],
        reads:[NativeCoreMLRecognizedRegion],frame:NativeOCRRGBAFrame,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,excluding:Set<Int>,threshold:Double)->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk else { return [] }
        var result:[Proposal]=[]
        for read in reads where read.confidence >= threshold && !excluding.contains(read.sourceIndex) {
            let i=read.sourceIndex
            let content=NativeOCRRFPrimaryEnsemble.canonicalTerminalStroke(read.text).filter { $0.isLetter || $0.isNumber }
            guard content.count >= 2,content.last == "ー",boxes.indices.contains(i),
                  let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(read.polygon),
                  let evidence=boxes[i].detectorSeedEvidence,evidence.isValid,
                  evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
                  let style=inkStyles.flatMap({$0.indices.contains(i) ? $0[i]:nil}) else { continue }
            let colours=style.colors.filter { $0.count==3 && $0.min()! < 224 }
                .sorted { ($0.max()!-$0.min()!) > ($1.max()!-$1.min()!) }
            guard let ink=colours.first else { continue }
            let family=colours.filter { c in zip(c,ink).map({abs($0-$1)}).max()! <= 48 }
            let font=basis.rect.width,columns=Int(ceil(font*3)),rows=Int(ceil(font*5))
            guard font >= 6,rows > 0,columns <= 262_144/rows else { continue }
            func rgb(_ p:CGPoint)->[Int]? {
                let x=Int(floor(p.x)),y=Int(floor(p.y))
                guard x >= 0,x < frame.width,y >= 0,y < frame.height else { return nil }
                let k=y*frame.bytesPerRow+x*4
                return (0..<3).map { Int(frame.bytes[k+$0]) }
            }
            func filled(_ c:[Int])->Bool { family.contains { colour in zip(c,colour).map({abs($0-$1)}).max()! <= 32 } }
            let sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth)
            let sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
            // A low-resolution DB cell certifies a source footprint, not
            // only its centre. Thin coloured fill can fall between cell
            // centres while the same cells correctly detect its white rim.
            // Count unique original pixels inside the immutable private cells.
            var sourcePixels=Set<Int>()
            for component in evidence.components { for run in component.runs {
                let left=max(0,Int(floor(CGFloat(run.x)*sx)))
                let right=min(frame.width,Int(ceil(CGFloat(run.x+run.count)*sx)))
                let top=max(0,Int(floor(CGFloat(run.y)*sy)))
                let bottom=min(frame.height,Int(ceil(CGFloat(run.y+1)*sy)))
                guard left < right,top < bottom else { continue }
                for y in top..<bottom { for x in left..<right {
                    let p=CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)
                    if NativeOCRDirectionGeometry.contains(boxes[i].polygon,p),rgb(p).map(filled)==true {
                        sourcePixels.insert(y*frame.width+x)
                    }
                } }
            } }
            guard sourcePixels.count >= 8 else { continue }
            let radius=max(2,min(16,Int(ceil(font*0.15)))),count=columns*rows
            var expanded=basis.rect,completedHead=false,completedTail=false
            for head in [true,false] {
                let x0=basis.rect.minX-font
                let y0=head ? basis.rect.minY-font*4:basis.rect.maxY-font
                let edge=head ? basis.rect.minY:basis.rect.maxY
                var white=[UInt8](repeating:0,count:count),fill=white,measured=[Bool](repeating:false,count:count)
                for y in 0..<rows { for x in 0..<columns {
                    let p=basis.restore(.init(x:x0+CGFloat(x)+0.5,y:y0+CGFloat(y)+0.5)),k=y*columns+x
                    guard let c=rgb(p) else { continue }
                    measured[k]=true
                    if filled(c) { fill[k]=1 }
                    if c.min()! >= 224,c.max()!-c.min()! <= 32 { white[k]=1 }
                } }
                func distance(_ mask:[UInt8])->[Int] {
                    var d=mask.map { $0 == 0 ? columns+rows:0 }
                    for y in 0..<rows { for x in 0..<columns {
                        let k=y*columns+x
                        if x > 0 { d[k]=min(d[k],d[k-1]+1) }
                        if y > 0 { d[k]=min(d[k],d[k-columns]+1) }
                    } }
                    for y in stride(from:rows-1,through:0,by:-1) { for x in stride(from:columns-1,through:0,by:-1) {
                        let k=y*columns+x
                        if x+1 < columns { d[k]=min(d[k],d[k+1]+1) }
                        if y+1 < rows { d[k]=min(d[k],d[k+columns]+1) }
                    } }
                    return d
                }
                let nearWhite=distance(white),nearFill=distance(fill)
                let mask=(0..<count).map { k in
                    (fill[k] != 0 && nearWhite[k] <= radius) || (white[k] != 0 && nearFill[k] <= radius)
                }
                var visited=[Bool](repeating:false,count:count),queue:[Int]=[]
                for seed in mask.indices where mask[seed] && !visited[seed] {
                    queue.removeAll(keepingCapacity:true);queue.append(seed);visited[seed]=true
                    var cursor=0,left=columns,right=0,top=rows,bottom=0,insideTop=rows,insideBottom = -1
                    var crossed=false,open=false,rowMass:[Int:Int]=[:]
                    while cursor < queue.count {
                        let k=queue[cursor];cursor+=1;let y=k/columns,x=k%columns
                        left=min(left,x);right=max(right,x);top=min(top,y);bottom=max(bottom,y)
                        rowMass[y,default:0]+=1
                        let along=y0+CGFloat(y)+0.5,normal=x0+CGFloat(x)+0.5
                        if normal >= basis.rect.minX,normal <= basis.rect.maxX,abs(along-edge) <= 1.5 { crossed=true }
                        if along >= basis.rect.minY,along <= basis.rect.maxY {
                            insideTop=min(insideTop,y);insideBottom=max(insideBottom,y)
                        }
                        // The inward edge is already inside the retained read.
                        // Only an outward or lateral observation edge leaves
                        // the new stroke's cap unknown.
                        if x==0 || x==columns-1 || (head ? y==0:y==rows-1) { open=true }
                        for dy in -1...1 { for dx in -1...1 {
                            let xx=x+dx,yy=y+dy
                            guard xx >= 0,xx < columns,yy >= 0,yy < rows else { continue }
                            let n=yy*columns+xx
                            if !measured[n] { open=true }
                            if mask[n] && !visited[n] { visited[n]=true;queue.append(n) }
                        } }
                    }
                    guard crossed,!open,insideBottom >= insideTop,
                          CGFloat(insideBottom-insideTop+1) >= font*0.6,
                          CGFloat(bottom-top+1) >= font*1.6 else { continue }
                    let widths=rowMass.values.sorted(),median=widths[widths.count/2]
                    guard CGFloat(median) <= font*0.5 else { continue }
                    let low=y0+CGFloat(top),high=y0+CGFloat(bottom+1)
                    let extensionLength=head ? edge-low:high-edge
                    guard extensionLength > CGFloat(radius*2+1) else { continue }
                    let observed=CGRect(x:x0+CGFloat(left)-2,y:low-2,
                        width:CGFloat(right-left+1)+4,height:high-low+4)
                    expanded=expanded.union(observed)
                    if head { completedHead=true } else { completedTail=true }
                }
            }
            guard completedHead || completedTail else { continue }
            // A measured source continuation may widen the normal envelope;
            // its original axis and all previously retained pixels stay fixed.
            let originalCorners=NativeOCRDirectionGeometry.corners(basis.rect)
            let order=read.polygon.map { p in
                let local=basis.project(p)
                return originalCorners.indices.min { a,b in
                    hypot(local.x-originalCorners[a].x,local.y-originalCorners[a].y) <
                        hypot(local.x-originalCorners[b].x,local.y-originalCorners[b].y)
                }!
            }
            guard Set(order).count==4 else { continue }
            func orderedQuad(_ rect:CGRect)->[CGPoint] {
                let corners=NativeOCRDirectionGeometry.corners(rect).map(basis.restore)
                return order.map { corners[$0] }
            }
            let polygon=orderedQuad(expanded)
            // Preserve the established two-read observation first. CTC may
            // tokenize a tightly framed curved cap as a new mark; only when
            // that pair fails may a separately validated font-scaled collar
            // confirm the exact same physical bbox. Neither pair changes the
            // confidence floor, owner barriers, or printed-word guards.
            let margins:[CGFloat]=[0,CGFloat(radius)]
            for margin in margins {
                let sampling=orderedQuad(expanded.insetBy(dx:-margin,dy:-margin))
                let padded=orderedQuad(expanded.insetBy(dx:-margin-2,dy:-margin-2))
                guard (polygon+sampling+padded).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                    $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}) else { continue }
                var borrows=false
                for peer in reads where peer.sourceIndex != i && peer.confidence >= threshold &&
                    boxes.indices.contains(peer.sourceIndex) {
                    if let own=boxes[peer.sourceIndex].detectorSeedEvidence,
                       samplesObservedGlyph([polygon,sampling,padded],peerPolygon:peer.polygon,evidence:own,
                        excludingPolygon:read.polygon) { borrows=true;break }
                }
                guard !borrows else { continue }
                result.append(.init(parent:i,polygon:polygon,samplings:[sampling,padded],complements:[],
                    independentGeometry:false,measuredTerminalOnly:true,sourceTerminalProof:polygon,
                    sourceHeadCompletion:completedHead,sourceTailCompletion:completedTail))
            }
        }
        return result
    }

    /// A strong retained prefix can establish an observed word beyond its
    /// original DB seeds. Re-observe a weak, partly cropped last glyph with
    /// the existing pixel kernel in that admitted span. The same bounded
    /// extension, ink/peer checks and paired recognition still apply; no new
    /// colour tolerance or detector ownership is invented.
    static func retainedObservedWeakTerminals(boxes:[NativeCoreMLDetectionBox],
        reads:[NativeCoreMLRecognizedRegion],frame:NativeOCRRGBAFrame,layout:NativeRFDETRLayoutResult?,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,excluding:Set<Int>,threshold:Double)->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk,let layout else { return [] }
        var result:[Proposal]=[]
        for read in reads where read.confidence >= threshold && !excluding.contains(read.sourceIndex) {
            let i=read.sourceIndex,tokens=read.tokenObservations
            guard boxes.indices.contains(i),let evidence=boxes[i].detectorSeedEvidence,evidence.isValid,
                  tokens.count >= 2,let last=tokens.last,last.confidence.isFinite,last.confidence < 0.5,
                  last.text.count==1,last.text.allSatisfy({$0.isLetter || $0.isNumber}),
                  tokens.dropLast().allSatisfy({$0.confidence.isFinite && $0.confidence >= max(0.8,threshold)}),
                  NativeOCRRFPrimaryEnsemble.measuredTrimSignature(tokens.map(\.text).joined()) ==
                    NativeOCRRFPrimaryEnsemble.measuredTrimSignature(read.text),
                  let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(read.polygon),
                  basis.rect.width >= 6,
                  inkStyles.flatMap({$0.indices.contains(i) ? $0[i]:nil}) != nil else { continue }
            var observed=boxes
            observed[i] = .init(polygon:read.polygon,score:boxes[i].score,detectorSeedEvidence:evidence)
            var ink:[CGPoint]?
            guard NativeOCRRFPrimaryEnsemble.pixelEndpointCompletion(index:i,boxes:observed,layout:layout,
                frame:frame,inkStyles:inkStyles,inkObserver:{ink=$0}) != nil,let ink else { continue }
            let proof=basis.bounds(ink),extensionLength=proof.maxY-basis.rect.maxY
            guard extensionLength > 2,extensionLength <= basis.rect.width*0.75,
                  proof.minX >= basis.rect.minX-2,proof.maxX <= basis.rect.maxX+2 else { continue }
            let polygon=NativeOCRRFPrimaryEnsemble.resizingReadSpan(read.polygon,
                head:basis.rect.minY,tail:proof.maxY+2)
            let margin=max(2,basis.rect.width*0.04)
            let padded=polygon.map { point -> CGPoint in
                var p=basis.project(point)
                p.x += p.x < basis.rect.midX ? -margin:margin
                return basis.restore(p)
            }
            let samples=[polygon,padded]
            guard samples.flatMap({$0}).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}) else { continue }
            guard !reads.contains(where:{ peer in
                guard peer.sourceIndex != i,peer.confidence >= threshold,boxes.indices.contains(peer.sourceIndex),
                      let own=boxes[peer.sourceIndex].detectorSeedEvidence else { return false }
                return samplesObservedGlyph(samples,peerPolygon:peer.polygon,evidence:own,excludingPolygon:read.polygon)
            }) else { continue }
            result.append(.init(parent:i,polygon:polygon,samplings:samples,complements:[],independentGeometry:false,
                observedWeakTerminal:true,measuredTerminalOnly:true,sourceTerminalProof:polygon,sourceTailCompletion:true))
        }
        return result
    }

    /// A DB region may include several unrelated surface colours. Measure the
    /// primary printed family from its private source cells, without letting a
    /// secondary artwork palette extend the observed word. This only nominates
    /// a crop: paired real recognition must preserve the complete retained text.
    static func retainedSourceFamilyTrims(boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,retained:Set<Int>,
        peerPolygons:[Int:[CGPoint]],excluding:Set<Int>,terminalProofs:[Int:[CGPoint]] = [:],
        immutableSourcePolygons:[Int:[CGPoint]] = [:],
        probability:NativeMainEnsembleOCRProbability.Sample? = nil,
        exclamationParents:Set<Int> = [])->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk,
              frame.bytesPerRow >= frame.width*4,frame.bytes.count >= frame.bytesPerRow*frame.height else { return [] }
        var result:[Proposal]=[]
        for i in retained.sorted() where boxes.indices.contains(i) && !excluding.contains(i) {
            guard let original=peerPolygons[i],let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original),
                  let evidence=boxes[i].detectorSeedEvidence,evidence.isValid,!evidence.components.isEmpty,
                  evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height,
                  let style=inkStyles.flatMap({$0.indices.contains(i) ? $0[i]:nil}),
                  let firstColour=style.colors.first,firstColour.count==3 else { continue }
            // White outlines may merge into white paper. A contrasting fill
            // already measured in the same private DB source supplies the
            // printed family; do not infer a new colour from nearby artwork.
            let whiteOutline=firstColour.min()! >= 224 && firstColour.max()!-firstColour.min()! <= 32
            let colour=whiteOutline ? (style.colors.first(where: { c in
                c.count==3 && zip(c,firstColour).map({abs($0-$1)}).max()! >= 96
            }) ?? firstColour):firstColour
            // A contrasting layer measured with a white outline is already
            // a distinct print colour. Use the original-pixel matching collar
            // shared by the crossing-ink verifier; a looser palette grouping
            // tolerance can connect similarly hued artwork to the word.
            let tolerance=whiteOutline ? 32:48
            let whiteOnly=whiteOutline && colour == firstColour
            let width=basis.rect.width,columns=Int(ceil(width)),rows=Int(ceil(basis.rect.height))
            guard width >= 6,basis.rect.height >= width*2,rows > 0,columns <= 524_288/rows else { continue }
            func matches(_ p:CGPoint,colour reference:[Int]? = nil)->Bool {
                let x=Int(floor(p.x)),y=Int(floor(p.y))
                guard x >= 0,x < frame.width,y >= 0,y < frame.height else { return false }
                let offset=y*frame.bytesPerRow+x*4
                return (0..<3).allSatisfy { abs(Int(frame.bytes[offset+$0])-(reference ?? colour)[$0]) <= tolerance }
            }
            func enclosedWhiteFill(_ world:CGPoint)->Bool {
                guard whiteOutline,!whiteOnly,matches(world,colour:firstColour) else { return false }
                let local=basis.project(world)
                func enclosed(_ sign:CGFloat)->Bool {
                    for step in 1...columns {
                        let p=basis.restore(.init(x:local.x+sign*CGFloat(step),y:local.y))
                        if matches(p) { return true }
                        if !matches(p,colour:firstColour) { return false }
                    }
                    return false
                }
                return enclosed(-1) && enclosed(1)
            }
            let sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth)
            let sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
            var anchors:[CGFloat]=[],anchorPoints:[CGPoint]=[],sourceRoots:[CGPoint]=[]
            for component in evidence.components { for run in component.runs { for x in run.x..<(run.x+run.count) {
                let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                if NativeOCRDirectionGeometry.contains(boxes[i].polygon,p),matches(p) {
                    let local=basis.project(p)
                    anchors.append(local.y);anchorPoints.append(local)
                }
                if whiteOutline,NativeOCRDirectionGeometry.contains(immutableSourcePolygons[i] ?? boxes[i].polygon,p),
                   matches(p) || matches(p,colour:firstColour) { sourceRoots.append(p) }
            } } }
            guard anchors.count >= 8,let firstAnchor=anchors.min(),let lastAnchor=anchors.max() else { continue }
            var whiteRowVotes:[Int]?
            if whiteOnly {
                // Pure white lettering has no contrasting colour with which
                // to reject illustration outlines. Measure its stroke depth
                // at immutable private DB pixels, then use that depth only
                // to locate the word family. Original detector extents and
                // connected crossing strokes are preserved below.
                let count=rows*columns
                var mask=[Bool](repeating:false,count:count),mass=[Int](repeating:0,count:rows)
                for row in 0..<rows { for column in 0..<columns {
                    let p=basis.restore(.init(x:basis.rect.minX+CGFloat(column)+0.5,
                        y:basis.rect.minY+CGFloat(row)+0.5))
                    let k=row*columns+column
                    mask[k]=matches(p)
                    if mask[k] { mass[row]+=1 }
                } }
                var depth=mask.map { $0 ? rows+columns:0 }
                for row in 0..<rows { for column in 0..<columns {
                    let k=row*columns+column
                    depth[k]=min(depth[k],row+1,column+1)
                    if row > 0 { depth[k]=min(depth[k],depth[k-columns]+1) }
                    if column > 0 { depth[k]=min(depth[k],depth[k-1]+1) }
                } }
                for row in stride(from:rows-1,through:0,by:-1) { for column in stride(from:columns-1,through:0,by:-1) {
                    let k=row*columns+column
                    depth[k]=min(depth[k],rows-row,columns-column)
                    if row+1 < rows { depth[k]=min(depth[k],depth[k+columns]+1) }
                    if column+1 < columns { depth[k]=min(depth[k],depth[k+1]+1) }
                } }
                let observed=anchorPoints.compactMap { p -> Int? in
                    let x=Int(floor(p.x-basis.rect.minX)),y=Int(floor(p.y-basis.rect.minY))
                    guard x >= 0,x < columns,y >= 0,y < rows,mask[y*columns+x] else { return nil }
                    return depth[y*columns+x]
                }.sorted()
                guard observed.count >= 8 else { continue }
                let stroke=observed[observed.count/2]
                // One-pixel sources cannot distinguish a thin letter from a
                // thin graphic. Keep their already retained geometry.
                guard stroke >= 2 else { continue }
                var coreRows=[Bool](repeating:false,count:rows)
                for row in 0..<rows {
                    coreRows[row]=(0..<columns).filter { depth[row*columns+$0] >= stroke }.count >= 2
                }
                whiteRowVotes=(0..<rows).map { row in
                    (max(0,row-stroke)...min(rows-1,row+stroke)).contains(where:{coreRows[$0]}) ? mass[row]:0
                }
            }
            var bands:[(first:Int,last:Int,pixels:Int)]=[]
            for row in 0..<rows {
                var count=whiteRowVotes?[row] ?? 0
                if whiteRowVotes == nil {
                    for column in 0..<columns {
                        let p=basis.restore(.init(x:basis.rect.minX+CGFloat(column)+0.5,
                            y:basis.rect.minY+CGFloat(row)+0.5))
                        if NativeOCRDirectionGeometry.contains(original,p),matches(p) { count+=1 }
                    }
                }
                guard count >= 2 else { continue }
                if let last=bands.last,CGFloat(row-last.last) <= width*0.5 {
                    bands[bands.count-1].last=row;bands[bands.count-1].pixels+=count
                } else { bands.append((row,row,count)) }
            }
            let uncertainty=max(sx,sy)+1
            let anchored=bands.filter { band in
                firstAnchor >= basis.rect.minY+CGFloat(band.first)-uncertainty &&
                    lastAnchor <= basis.rect.minY+CGFloat(band.last+1)+uncertainty
            }
            guard anchored.count==1,let band=anchored.first,CGFloat(band.last-band.first+1) >= width*1.5,
                  band.pixels*5 >= bands.reduce(0,{$0+$1.pixels})*4 else { continue }
            let pad=max(2,width*0.08)
            var head=max(basis.rect.minY,basis.rect.minY+CGFloat(band.first)-pad)
            var tail=min(basis.rect.maxY,basis.rect.minY+CGFloat(band.last+1)+pad)
            if whiteOnly {
                // Thickness nominates removal of newly acquired graphics;
                // it never erases the original detector's thin punctuation.
                let source=basis.bounds(immutableSourcePolygons[i] ?? boxes[i].polygon)
                head=max(basis.rect.minY,min(head,source.minY))
                tail=min(basis.rect.maxY,max(tail,source.maxY))
            }
            // Small hand-labelled edge differences do not justify another read.
            guard head-basis.rect.minY > width*0.5 || basis.rect.maxY-tail > width*0.5 else { continue }
            var measured=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:head,tail:tail)
            // When white is an outline around a contrasting fill, its colour
            // can also belong to paper/highlights connected to that outline.
            // The independently measured fill supplies the trim witness;
            // pure-white lettering keeps its own private-rooted white witness.
            measured=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:original,candidate:measured,
                frame:frame,inkStyle:.init(colour),sourceRoots:whiteOutline ? sourceRoots:nil)
            var observedWhiteFill=false
            if whiteOutline,!whiteOnly {
                // A white fill enclosed by its contrasting border is genuine
                // lettering, unlike a white outline connected to paper. Root
                // its crossing-tip witness only where the same source row
                // reaches the measured colour on BOTH intrinsic sides.
                let fillRoots=sourceRoots.filter(enclosedWhiteFill)
                observedWhiteFill = !fillRoots.isEmpty
                if !fillRoots.isEmpty {
                    measured=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:original,candidate:measured,
                        frame:frame,inkStyle:.init(firstColour),sourceRoots:fillRoots)
                }
            }
            if let roi=evidence.sourceProbabilityROI,roi.isValid,
               roi.sourceWidth==frame.width,roi.sourceHeight==frame.height,
               roi.detector.originX==0,roi.detector.originY==0,
               roi.detector.width==roi.detector.fullWidth,roi.detector.height==roi.detector.fullHeight {
                // A detached part of a real glyph may not survive the strong
                // DB component threshold. Same-word REC is insufficient: a
                // cropped glyph can still decode correctly. Preserve matching
                // original ink close to either cut when the full-frame weak
                // DB map also observes it. This is a keep constraint inside
                // the old read, never new source ownership or crop growth.
                let cut=basis.bounds(measured),reach=width*0.75
                let weakFloor=UInt8(ceil(255*0.05))
                var weakRoots:[CGPoint]=[]
                // Preserve actual fill layers, not every palette entry:
                // contrasting artwork may have contributed a secondary hue.
                // Neutral antialias layers can resolve the same dark glyph;
                // a shared white outline must pass the fill-enclosure proof.
                let neutral=colour.max()!-colour.min()! <= 32
                let weakColours=observedWhiteFill ? [firstColour]:
                    (!whiteOutline && neutral ? style.colors.filter {
                        $0.count==3 && $0.max()!-$0.min()! <= 32 && $0.max()! <= colour.max()!+32
                    }:[colour])
                let weakStyle=NativeOCRRFPrimaryEnsemble.EndpointInkStyle(colors:weakColours)
                func matchesObservedLayer(_ p:CGPoint)->Bool {
                    if observedWhiteFill { return enclosedWhiteFill(p) }
                    return weakColours.contains { reference in
                        reference.count==3 && matches(p,colour:reference)
                    }
                }
                for row in 0..<rows {
                    let y=basis.rect.minY+CGFloat(row)+0.5
                    guard (y < cut.minY && y >= cut.minY-reach) ||
                          (y > cut.maxY && y <= cut.maxY+reach) else { continue }
                    for column in 0..<columns {
                        let p=basis.restore(.init(x:basis.rect.minX+CGFloat(column)+0.5,y:y))
                        guard NativeOCRDirectionGeometry.contains(immutableSourcePolygons[i] ?? boxes[i].polygon,p),
                              matchesObservedLayer(p) else { continue }
                        let x=Int(floor(p.x))-roi.roi.x,y=Int(floor(p.y))-roi.roi.y
                        guard x >= 0,x < roi.roi.width,y >= 0,y < roi.roi.height,
                              roi.upperBounds[y*roi.roi.width+x] >= weakFloor else { continue }
                        weakRoots.append(p)
                    }
                }
                if !weakRoots.isEmpty {
                    measured=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:original,candidate:measured,
                        frame:frame,inkStyle:weakStyle,preserveDetached:true,sourceRoots:weakRoots)
                }
            }
            measured=NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:measured,
                candidate:original,original:boxes[i].polygon,proof:terminalProofs[i])
            if let points=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:i,boxes:boxes,frame:frame,
                inkStyle:.init(colour),sourceWindow:measured,observedSource:original,protectingObservedPoints:true) {
                let cut=basis.bounds(measured),proof=basis.bounds(points)
                measured=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,
                    head:max(basis.rect.minY,min(cut.minY,proof.minY)),
                    tail:min(basis.rect.maxY,max(cut.maxY,proof.maxY)))
            }
            if exclamationParents.contains(i) {
                // Inspect the proposed cut, not the old wide read: a mark
                // already inside that old read produces no growth event.
                // A known exclamation still needs an independently measured
                // source-rooted stem/dot proof before it can constrain a trim.
                var scoped=boxes
                scoped[i] = .init(polygon:measured,score:boxes[i].score,detectorSeedEvidence:evidence)
                var marks:[[CGPoint]]=[]
                _ = NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:i,boxes:scoped,
                    frame:frame,probability:probability,inkStyle:style,
                    terminalMarkObserver:{marks.append($0)},recognizesExclamation:true)
                var cut=basis.bounds(measured)
                for mark in marks {
                    let ink=basis.bounds(mark)
                    guard ink.minY >= basis.rect.minY,ink.maxY <= basis.rect.maxY else { continue }
                    let first=max(basis.rect.minY,min(cut.minY,ink.minY-2))
                    let last=min(basis.rect.maxY,max(cut.maxY,ink.maxY+2))
                    cut=CGRect(x:cut.minX,y:first,width:cut.width,height:last-first)
                }
                measured=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:cut.minY,tail:cut.maxY)
            }
            let cut=basis.bounds(measured)
            guard cut.minY <= firstAnchor,cut.maxY >= lastAnchor,
                  cut.minY-basis.rect.minY > width*0.5 || basis.rect.maxY-cut.maxY > width*0.5 else { continue }
            let padded=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,
                head:max(basis.rect.minY,cut.minY-pad),tail:min(basis.rect.maxY,cut.maxY+pad))
            guard (measured+padded).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}) else { continue }
            result.append(.init(parent:i,polygon:measured,samplings:[measured,padded],complements:[],
                independentGeometry:false,measuredTrimOnly:true,sourceFamilyTrim:true))
            // A tight normal crop may hide a small kana or mark from CTC.
            // Keep the established pair first; this independently recognized
            // context pair can confirm the SAME measured output geometry only
            // if it preserves every retained word and confident dot slot.
            let contextMargin=width*0.12
            let context=[measured,padded].map { quad in
                quad.map { point -> CGPoint in
                    var p=basis.project(point)
                    p.x += p.x < basis.rect.midX ? -contextMargin:contextMargin
                    return basis.restore(p)
                }
            }
            if context.flatMap({$0}).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}),
               !peerPolygons.contains(where:{ j,peer in
                    guard j != i,boxes.indices.contains(j),let own=boxes[j].detectorSeedEvidence else { return false }
                    return samplesObservedGlyph(context,peerPolygon:peer,evidence:own,excludingPolygon:original)
               }) {
                result.append(.init(parent:i,polygon:measured,samplings:context,complements:[],
                    independentGeometry:false,measuredTrimOnly:true,sourceFamilyTrim:true))
            }
        }
        return result
    }

    /// Expansion must not make an unowned island part of the original word.
    /// Nominate from the immutable detector frame only AFTER a confident read
    /// exists. The caller requires two word-identical reads; no text is edited.
    static func retainedExpansionTrims(boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        layout:NativeRFDETRLayoutResult?,inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,
        retained:Set<Int>,peerPolygons:[Int:[CGPoint]],excluding:Set<Int>,terminalProofs:[Int:[CGPoint]] = [:],
        probability:NativeMainEnsembleOCRProbability.Sample? = nil)->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk else { return [] }
        var result:[Proposal]=[]
        for i in retained.sorted() where boxes.indices.contains(i) && !excluding.contains(i) {
            guard let original=peerPolygons[i],let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original),
                  let style=inkStyles.flatMap({ $0.indices.contains(i) ? $0[i]:nil }) else { continue }
            let source=basis.bounds(boxes[i].polygon),old=basis.rect
            guard source.minY > old.minY+2 || source.maxY < old.maxY-2 else { continue }
            let observed=NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:i,boxes:boxes,polygon:original,
                layout:layout,frame:frame,inkStyles:inkStyles,observedWord:true,immutableObservation:true)
            let r=basis.bounds(observed)
            // This route removes new expansion only. Original calibrated crop
            // edges and earlier valid trims retain their existing authority.
            let head=max(old.minY,min(source.minY,r.minY)),tail=min(old.maxY,max(source.maxY,r.maxY))
            var measured=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:head,tail:tail)
            var candidates=boxes
            candidates[i] = .init(polygon:measured,score:boxes[i].score,detectorSeedEvidence:boxes[i].detectorSeedEvidence)
            if let terminal=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:i,boxes:candidates,
                frame:frame,probability:probability,inkStyle:style) {
                let current=basis.bounds(measured),cap=basis.bounds(terminal)
                measured=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,
                    head:max(old.minY,min(current.minY,cap.minY)),tail:min(old.maxY,max(current.maxY,cap.maxY)))
            }
            measured=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:original,candidate:measured,
                frame:frame,inkStyle:style)
            measured=NativeOCRRFPrimaryEnsemble.preservingRecoveredTerminal(trimmed:measured,
                candidate:original,original:boxes[i].polygon,proof:terminalProofs[i])
            // A uniform printed point train is physical source even if CTC
            // retokenized its count. Do not turn that recovery into blank space.
            if let points=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:i,boxes:boxes,frame:frame,
                inkStyle:style,sourceWindow:measured,observedSource:original,protectingObservedPoints:true) {
                let cut=basis.bounds(measured),proof=basis.bounds(points)
                measured=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,
                    head:max(old.minY,min(cut.minY,proof.minY)),tail:min(old.maxY,max(cut.maxY,proof.maxY)))
            }
            let cut=basis.bounds(measured)
            guard cut.minY > old.minY+2 || cut.maxY < old.maxY-2 else { continue }
            let padded=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,
                head:max(old.minY,cut.minY-old.width*0.12),tail:min(old.maxY,cut.maxY+old.width*0.12))
            let samplings=[measured,padded]
            guard samplings.flatMap({$0}).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)}) else { continue }
            result.append(.init(parent:i,polygon:measured,samplings:samplings,complements:[],
                independentGeometry:false,measuredTrimOnly:true,immutableExpansionTrim:true))
        }
        return result
    }

    /// Once REC independently retains a real word, empty endpoint padding
    /// may be nominated for a trim, subject to two word-identical real reads.
    /// Independent end observations keep a failed head measurement from
    /// vetoing a valid tail trim (or the reverse).
    static func retainedWordTrims(boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        layout:NativeRFDETRLayoutResult?,inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,
        retained:Set<Int>,peerPolygons:[Int:[CGPoint]],excluding:Set<Int>,fallbackParents:Set<Int> = [])->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk else { return [] }
        var result:[Proposal]=[]
        for i in retained.sorted() where boxes.indices.contains(i) && !excluding.contains(i) {
            let competitorStyles=NativeOCRRFPrimaryEnsemble.observedTrimCompetitorStyles(index:i,boxes:boxes,inkStyles:inkStyles)
            let sharedWord=competitorStyles != nil
            // Strong first-pass trims already have their own paired control.
            // Only an actually restored, two-ended trim needs end-wise retry;
            // re-trimming every retained strong word changes unrelated layouts.
            guard boxes[i].score < 0.8 || fallbackParents.contains(i) || sharedWord else { continue }
            guard let original=peerPolygons[i],let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original) else { continue }
            var measured=NativeOCRRFPrimaryEnsemble.trimmingEndpointPadding(index:i,boxes:boxes,polygon:original,
                layout:layout,frame:frame,inkStyles:inkStyles,observedWord:true)
            let initial=basis.bounds(measured)
            guard initial.minY > basis.rect.minY+2 || initial.maxY < basis.rect.maxY-2 else { continue }
            let failedBothEnds=initial.minY > basis.rect.minY+2 && initial.maxY < basis.rect.maxY-2
            if boxes[i].score >= 0.8 && !failedBothEnds && !sharedWord { continue }
            // A terminal omitted by the DB seeds is still visible text.
            // Inspect the proposed crop edge with the existing source-colour
            // terminal kernel; restore only measured ink inside the old read.
            var candidates=boxes
            candidates[i] = .init(polygon:measured,score:boxes[i].score,detectorSeedEvidence:boxes[i].detectorSeedEvidence)
            if let terminal=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:i,boxes:candidates,
                frame:frame,inkStyle:inkStyles.flatMap { $0.indices.contains(i) ? $0[i]:nil }) {
                let r=basis.bounds(measured),cap=basis.bounds(terminal)
                let head=max(basis.rect.minY,min(r.minY,cap.minY)),tail=min(basis.rect.maxY,max(r.maxY,cap.maxY))
                measured=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:head,tail:tail)
            }
            let style=inkStyles.flatMap { $0.indices.contains(i) ? $0[i]:nil } ??
                NativeOCRRFPrimaryEnsemble.endpointInkStyle(box:boxes[i],frame:frame)
            let completeStyles=competitorStyles ?? []
            measured=NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:original,candidate:measured,
                frame:frame,inkStyle:style,preserveDetached:boxes[i].score >= 0.8 && !sharedWord,
                competingInkStyles:completeStyles)
            let r=basis.bounds(measured)
            guard r.minY >= basis.rect.minY-1,r.maxY <= basis.rect.maxY+1,
                  r.minY > basis.rect.minY+2 || r.maxY < basis.rect.maxY-2 else { continue }
            let bothEnds=r.minY > basis.rect.minY+2 && r.maxY < basis.rect.maxY-2
            var measurements=[r]
            if bothEnds {
                measurements.append(CGRect(x:r.minX,y:basis.rect.minY,width:r.width,height:r.maxY-basis.rect.minY))
                measurements.append(CGRect(x:r.minX,y:r.minY,width:r.width,height:basis.rect.maxY-r.minY))
            }
            for (offset,proposed) in measurements.enumerated() {
                var measurement=proposed
                if boxes[i].score < 0.8 && offset > 0 {
                    let cut=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:measurement.minY,tail:measurement.maxY)
                    measurement=basis.bounds(NativeOCRRFPrimaryEnsemble.preservingTrimCrossingInk(original:original,
                        candidate:cut,frame:frame,inkStyle:style,preserveDetached:true,competingInkStyles:completeStyles))
                }
                if boxes[i].score >= 0.8 || offset > 0 {
                    let cut=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:measurement.minY,tail:measurement.maxY)
                    // New independent-end fallbacks cannot erase periodic
                    // print already inside the old read, even if REC omitted it.
                    if let points=NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(index:i,boxes:boxes,frame:frame,
                        inkStyle:style,sourceWindow:cut,observedSource:original,protectingObservedPoints:true) {
                        let proof=basis.bounds(points)
                        let head=max(basis.rect.minY,min(measurement.minY,proof.minY))
                        let tail=min(basis.rect.maxY,max(measurement.maxY,proof.maxY))
                        measurement=CGRect(x:measurement.minX,y:head,width:measurement.width,height:tail-head)
                    }
                }
                guard measurement.minY > basis.rect.minY+2 || measurement.maxY < basis.rect.maxY-2 else { continue }
                let samples=[CGFloat(0),0.12].map { padding in
                    // The first observation uses the exact final endpoints;
                    // the second varies previously observed along-axis padding.
                    let head=max(basis.rect.minY,measurement.minY-basis.rect.width*padding)
                    let tail=min(basis.rect.maxY,measurement.maxY+basis.rect.width*padding)
                    return NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:head,tail:tail)
                }
                func insideFrame(_ samples:[[CGPoint]])->Bool {
                    samples.flatMap({$0}).allSatisfy({$0.x >= 0 && $0.y >= 0 &&
                        $0.x <= CGFloat(frame.width) && $0.y <= CGFloat(frame.height)})
                }
                guard insideFrame(samples) else { continue }
                let polygon=NativeOCRRFPrimaryEnsemble.resizingReadSpan(original,head:measurement.minY,tail:measurement.maxY)
                result.append(.init(parent:i,polygon:polygon,samplings:samples,complements:[],
                    independentGeometry:false,measuredTrimOnly:true))
                // CTC can change a glyph's spelling when its blank aspect
                // context changes. Observe the SAME measured head and tail
                // with two normal margins, never hiding a clipped end behind
                // along-axis padding. Other source owners remain barriers.
                let normalSamples=[CGFloat(0.12),0.24].map { padding in
                    polygon.map { point in
                        var p=basis.project(point)
                        p.x=measurement.midX+(p.x-measurement.midX)*(1+padding*2)
                        return basis.restore(p)
                    }
                }
                guard insideFrame(normalSamples),!boxes.indices.contains(where:{ j in
                    guard j != i,let evidence=boxes[j].detectorSeedEvidence else { return false }
                    return samplesObservedGlyph(normalSamples,peerPolygon:peerPolygons[j] ?? boxes[j].polygon,
                        evidence:evidence,excludingPolygon:original)
                }) else { continue }
                result.append(.init(parent:i,polygon:polygon,samplings:normalSamples,complements:[],
                    independentGeometry:false,measuredTrimOnly:true))
            }
        }
        return Array(result.prefix(16))
    }

    /// Independent glyph bands, rather than a neighbouring text box, may
    /// certify a correction to the source baseline. Pairwise slopes use a
    /// long observed span; inconsistent or sub-grid drift leaves it unchanged.
    static func measuredGlyphSlope(_ components:[CGRect],span:CGFloat,glyph:CGFloat,grid:CGFloat)->CGFloat? {
        guard glyph > 0,span >= glyph*3 else { return nil }
        let letters=components.filter { $0.width >= glyph*0.2 && $0.height >= glyph*0.2 && $0.height <= glyph*1.5 }
        guard letters.count >= 3 else { return nil }
        let sizes=letters.map { max($0.width,$0.height) }.sorted(),font=sizes[sizes.count/2]
        guard font >= grid*2 else { return nil }
        let bands=Dictionary(grouping:letters,by:{Int(floor($0.midY/(font*0.75)))})
        let intervals=bands.values.map { rects in
            rects.reduce(CGRect.null) { $0.union($1) }
        }.sorted { $0.midY < $1.midY }
        let points=intervals.map { CGPoint(x:$0.midX,y:$0.midY) }
        guard points.count >= 3,let first=points.first,let last=points.last,
              last.y-first.y >= span*0.5 else { return nil }
        var slopes:[CGFloat]=[],leftSlopes:[CGFloat]=[],rightSlopes:[CGFloat]=[]
        for a in points.indices { for b in points.indices where b > a && points[b].y-points[a].y >= font*1.5 {
            let dy=points[b].y-points[a].y
            slopes.append((points[b].x-points[a].x)/dy)
            leftSlopes.append((intervals[b].minX-intervals[a].minX)/dy)
            rightSlopes.append((intervals[b].maxX-intervals[a].maxX)/dy)
        } }
        guard slopes.count >= 2 else { return nil }
        func median(_ v:[CGFloat])->CGFloat { let s=v.sorted();return s[s.count/2] }
        let slope=median(slopes),intercept=median(points.map { $0.x-slope*$0.y })
        let drift=abs(slope)*(last.y-first.y),errors=points.map { abs($0.x-slope*$0.y-intercept) }
        let left=median(leftSlopes),right=median(rightSlopes),length=last.y-first.y
        // A change of font width can move the centre while one edge remains
        // aligned. Both observed sides must independently resolve the same
        // directional drift before it becomes a baseline correction.
        guard left*slope > 0,right*slope > 0,abs(left)*length > grid,abs(right)*length > grid else { return nil }
        guard slope.isFinite,drift > grid*2,median(errors) <= max(grid*2,font*0.05),
              errors.filter({$0 <= max(grid*2,min(font*0.2,drift*0.5))}).count*5 >= points.count*4 else { return nil }
        return slope
    }

    /// A halo may connect an entire word while its wide glyph bands still
    /// independently describe the baseline. Thin inter-glyph bridges and dot
    /// trains cannot redefine the font scale or count as wide glyph evidence.
    static func rasterGlyphBands(_ pixels:[CGPoint],grid:CGFloat)->[CGRect] {
        let step=max(1,grid)
        let rows=Dictionary(grouping:pixels,by:{Int(floor($0.y/step))}).values.map { points in
            points.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
        }.filter { $0.width >= step*2 }
        guard rows.count >= 3 else { return [] }
        let widths=rows.map(\.width).sorted(),font=widths[min(widths.count-1,widths.count*4/5)]
        guard font >= step*2 else { return [] }
        let wide=rows.filter { $0.width >= font*0.5 },head=wide.map(\.minY).min()!
        return Dictionary(grouping:wide,by:{Int(floor(($0.midY-head)/font))}).values.map { rects in
            rects.reduce(CGRect.null) { $0.union($1) }
        }
    }

    /// A shared CC may be predominantly this retained word's print even when
    /// the factory could not assign it as an exclusive component. Use that
    /// measured majority only to seed original-colour connected components;
    /// never change detector ownership or use the RF paragraph as a crop.
    static func retainedNormalTrims(boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        probability:NativeMainEnsembleOCRProbability.Sample? = nil,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,retained:Set<Int>,
        peerPolygons:[Int:[CGPoint]],excluding:Set<Int>)->[Proposal] {
        var result:[Proposal]=[]
        for i in retained.sorted() where boxes.indices.contains(i) && !excluding.contains(i) {
            guard let original=peerPolygons[i],let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original),
                  basis.rect.width >= 8,basis.rect.height >= basis.rect.width*3,
                  let evidence=boxes[i].detectorSeedEvidence,evidence.isValid,
                  evidence.sourceWidth==frame.width,evidence.sourceHeight==frame.height else { continue }
            let candidates=(evidence.candidateComponents ?? []).filter { candidate in
                candidate.component.pixelCount >= 8 && !candidate.competingOwnerIDs.isEmpty &&
                    candidate.outsideCompetingCells.allSatisfy { $0*5 >= candidate.component.pixelCount*4 }
            }
            guard !candidates.isEmpty else { continue }
            let colours=(inkStyles.flatMap { $0.indices.contains(i) ? $0[i]:nil }?.colors ?? []).filter { $0.count==3 }
            guard !colours.isEmpty else { continue }
            let g=basis.rect.width,sx=CGFloat(frame.width)/CGFloat(evidence.mapFullWidth),
                sy=CGFloat(frame.height)/CGFloat(evidence.mapFullHeight)
            let search=basis.rect.insetBy(dx:-g*0.5,dy:-g*0.15)
            let world=NativeOCRDirectionGeometry.bounds(NativeOCRDirectionGeometry.corners(search).map(basis.restore))
            let x0=max(0,Int(floor(world.minX))),y0=max(0,Int(floor(world.minY))),
                x1=min(frame.width,Int(ceil(world.maxX))),y1=min(frame.height,Int(ceil(world.maxY)))
            let width=x1-x0,height=y1-y0
            guard width > 0,height > 0,width <= 262_144/height else { continue }
            func ink(_ x:Int,_ y:Int)->Bool {
                let offset=y*frame.bytesPerRow+x*4
                return colours.contains { colour in colour.count==3 &&
                    (0..<3).allSatisfy { abs(Int(frame.bytes[offset+$0])-colour[$0]) <= 24 }
                }
            }
            var mask=[Bool](repeating:false,count:width*height)
            for y in y0..<y1 { for x in x0..<x1 {
                if search.contains(basis.project(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))),ink(x,y) {
                    mask[(y-y0)*width+x-x0]=true
                }
            } }
            var seeds=Set<Int>(),seedPoints:[CGPoint]=[],observed:[CGPoint]=[]
            for candidate in candidates {
                let competitors=boxes.indices.filter { j in
                    j != i && peerPolygons[j] != nil && boxes[j].detectorSeedEvidence.map {
                        candidate.competingOwnerIDs.contains($0.ownerID)
                    } == true
                }
                for run in candidate.component.runs { for x in run.x..<(run.x+run.count) {
                    let p=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(run.y)+0.5)*sy)
                    guard NativeOCRDirectionGeometry.contains(original,p),
                          !competitors.contains(where:{ NativeOCRDirectionGeometry.contains(peerPolygons[$0]!,p) }) else { continue }
                    observed.append(p)
                    let xx=Int(floor(p.x)),yy=Int(floor(p.y))
                    guard xx >= x0,xx < x1,yy >= y0,yy < y1,mask[(yy-y0)*width+xx-x0] else { continue }
                    seeds.insert((yy-y0)*width+xx-x0);seedPoints.append(p)
                } }
            }
            guard seeds.count >= 16,basis.bounds(seedPoints).height >= basis.rect.height*0.5 else { continue }
            let ownSeeds=Set(candidates.map { $0.component.seed })
            var foreign=Set<Int>()
            for j in boxes.indices where j != i && peerPolygons[j] != nil {
                guard let peer=boxes[j].detectorSeedEvidence,peer.isValid else { continue }
                let exclusive=(peer.candidateComponents ?? []).filter { c in
                    c.outsideCompetingCells.allSatisfy { $0*5 >= c.component.pixelCount*4 }
                }.map(\.component)
                for c in peer.components+exclusive where c.pixelCount >= 8 && !ownSeeds.contains(c.seed) {
                    for run in c.runs { for x in run.x..<(run.x+run.count) {
                        let p=CGPoint(x:(CGFloat(x)+0.5)*CGFloat(frame.width)/CGFloat(peer.mapFullWidth),
                            y:(CGFloat(run.y)+0.5)*CGFloat(frame.height)/CGFloat(peer.mapFullHeight))
                        let xx=Int(floor(p.x)),yy=Int(floor(p.y))
                        if xx >= x0,xx < x1,yy >= y0,yy < y1,
                           NativeOCRDirectionGeometry.contains(peerPolygons[j]!,p) {
                            foreign.insert((yy-y0)*width+xx-x0)
                        }
                    } }
                }
            }
            var foreignContact=Set<Int>()
            let contactRadius=max(1,Int(ceil(max(sx,sy)/2)))
            for k in foreign {
                let x=k % width,y=k/width
                for dy in -contactRadius...contactRadius { for dx in -contactRadius...contactRadius {
                    let xx=x+dx,yy=y+dy
                    if xx >= 0,xx < width,yy >= 0,yy < height { foreignContact.insert(yy*width+xx) }
                } }
            }
            var visited=Set<Int>(),components:[CGRect]=[],sourceComponents:[[Int]]=[],sourceSupport:[CGPoint]=[],uncertified=false
            for seed in seeds.sorted() where !visited.contains(seed) {
                var queue=[seed],cursor=0,points:[CGPoint]=[],open=false,borrows=false
                visited.insert(seed)
                while cursor < queue.count {
                    let k=queue[cursor];cursor+=1
                    let x=k % width,y=k/width,p=CGPoint(x:CGFloat(x+x0)+0.5,y:CGFloat(y+y0)+0.5),local=basis.project(p)
                    points.append(local)
                    if foreign.contains(k) { borrows=true }
                    if x==0 || y==0 || x==width-1 || y==height-1 ||
                        local.x-search.minX < 1 || search.maxX-local.x < 1 ||
                        local.y-search.minY < 1 || search.maxY-local.y < 1 { open=true }
                    for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                        let xx=x+dx,yy=y+dy
                        guard xx >= 0,xx < width,yy >= 0,yy < height else { continue }
                        let next=yy*width+xx
                        if mask[next],visited.insert(next).inserted { queue.append(next) }
                    } }
                }
                let r=points.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
                if open || borrows || r.width > g*0.95 { uncertified=true;continue }
                guard points.count >= 3 else { continue }
                components.append(r);sourceComponents.append(queue);sourceSupport+=points
            }
            guard !uncertified,components.count >= 2 else { continue }
            // Fill and outline are separate colour components. Flooding their
            // union would walk from a white glyph through its orange rim into
            // white paper. Nominate repeated contrasting rim colours, then
            // certify their closed components separately from the fill.
            var modes:[Int:(sum:[Int],count:Int,bands:Set<Int>,seeds:Set<Int>)]=[:]
            let reach=max(2,min(12,Int(ceil(g*0.12))))
            for (group,pixels) in sourceComponents.enumerated() {
                let band=Int(floor((components[group].midY-basis.rect.minY)/g))
                for k in pixels {
                    let x=k % width,y=k/width
                    for (dx,dy) in [(1,0),(-1,0),(0,1),(0,-1)] {
                        let nx=x+dx,ny=y+dy
                        guard nx >= 0,nx < width,ny >= 0,ny < height,!mask[ny*width+nx] else { continue }
                        for distance in 1...reach {
                            let xx=x+dx*distance,yy=y+dy*distance
                            guard xx >= 0,xx < width,yy >= 0,yy < height else { break }
                            let at=(yy+y0)*frame.bytesPerRow+(xx+x0)*4
                            let rgb=(0..<3).map { Int(frame.bytes[at+$0]) }
                            let contrast=colours.map { colour in (0..<3).map { abs(rgb[$0]-colour[$0]) }.max()! }.min()!
                            let chroma=rgb.max()!-rgb.min()!,dark=rgb.reduce(0,+)/3
                            let fill=colours.map { $0.reduce(0,+)/3 }.min()!
                            guard contrast >= 64,chroma >= 48 || dark <= fill-96 else { continue }
                            let key=(rgb[0]/16)*256+(rgb[1]/16)*16+rgb[2]/16
                            var m=modes[key] ?? ([0,0,0],0,[],[])
                            for c in 0..<3 { m.sum[c]+=rgb[c] }
                            m.count+=1;m.bands.insert(band);m.seeds.insert(yy*width+xx);modes[key]=m
                        }
                    }
                }
            }
            let ranked=modes.values.filter { $0.count >= 16 && $0.bands.count >= 2 }.sorted {
                if $0.bands.count != $1.bands.count { return $0.bands.count > $1.bands.count }
                if $0.count != $1.count { return $0.count > $1.count }
                return $0.sum.lexicographicallyPrecedes($1.sum)
            }
            var axisComponents:[CGRect]=[],axisRaster:[CGPoint]=[]
            for mode in ranked.prefix(8) {
                let rgb=mode.sum.map { $0/mode.count }
                var seen=Set<Int>(),rims:[CGRect]=[],rimSupport:[CGPoint]=[],supported=Set<Int>()
                func rim(_ k:Int)->Bool {
                    if mask[k] { return false }
                    let at=(k/width+y0)*frame.bytesPerRow+(k % width+x0)*4
                    return (0..<3).allSatisfy { abs(Int(frame.bytes[at+$0])-rgb[$0]) <= 24 }
                }
                for seed in mode.seeds.sorted() where !seen.contains(seed) && rim(seed) {
                    var queue=[seed],cursor=0,extent=CGRect.null,open=false
                    seen.insert(seed)
                    while cursor < queue.count {
                        let k=queue[cursor];cursor+=1
                        let x=k % width,y=k/width,p=basis.project(CGPoint(x:CGFloat(x+x0)+0.5,y:CGFloat(y+y0)+0.5))
                        extent=extent.union(CGRect(origin:p,size:.zero))
                        if x==0 || y==0 || x==width-1 || y==height-1 ||
                            p.x-search.minX < 1 || search.maxX-p.x < 1 ||
                            p.y-search.minY < 1 || search.maxY-p.y < 1 { open=true }
                        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                            let xx=x+dx,yy=y+dy
                            guard xx >= 0,xx < width,yy >= 0,yy < height else { continue }
                            let next=yy*width+xx
                            if !seen.contains(next),rim(next) { seen.insert(next);queue.append(next) }
                        } }
                    }
                    guard !open,extent.width <= g*0.95,extent.width > 0,extent.height > 0,
                          CGFloat(queue.count) <= extent.width*extent.height*0.75 else { continue }
                    let enclosed=components.indices.filter { extent.insetBy(dx:-1,dy:-1).contains(components[$0]) }
                    guard !enclosed.isEmpty else { continue }
                    // A rotated component's enclosing rectangle fills empty
                    // triangles that are not its paint. Only actual rim contact
                    // with another private source can veto the measured collar.
                    if queue.contains(where:{ foreignContact.contains($0) }) { uncertified=true;break }
                    rims.append(extent)
                    rimSupport+=queue.map { k in
                        basis.project(CGPoint(x:CGFloat(k % width+x0)+0.5,y:CGFloat(k/width+y0)+0.5))
                    }
                    for group in enclosed { supported.insert(Int(floor((components[group].midY-basis.rect.minY)/g))) }
                }
                if uncertified { break }
                if supported.count >= 2 {
                    axisComponents=rims;components+=rims;axisRaster=rimSupport;sourceSupport+=rimSupport;break
                }
            }
            guard !uncertified else { continue }
            let core=components.reduce(CGRect.null) { $0.union($1) }
            guard core.height >= basis.rect.height*0.5 else { continue }
            let rasterBands=rasterGlyphBands(axisRaster.isEmpty ? sourceSupport:axisRaster,grid:hypot(sx,sy))
            let slope=measuredGlyphSlope(axisComponents.isEmpty ? components:axisComponents,
                span:basis.rect.height,glyph:g,grid:hypot(sx,sy)) ??
                measuredGlyphSlope(components,span:basis.rect.height,glyph:g,grid:hypot(sx,sy)) ??
                measuredGlyphSlope(rasterBands,span:basis.rect.height,glyph:g,grid:hypot(sx,sy)) ?? 0
            let scale=sqrt(1+slope*slope)
            func align(_ p:CGPoint)->CGPoint { .init(x:(p.x-slope*p.y)/scale,y:(slope*p.x+p.y)/scale) }
            func restore(_ p:CGPoint)->CGPoint {
                basis.restore(CGPoint(x:(p.x+slope*p.y)/scale,y:(p.y-slope*p.x)/scale))
            }
            func extent(_ points:[CGPoint])->CGRect {
                points.map(align).reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
            }
            let measured=extent(sourceSupport)
            let old=extent(original.map(basis.project))
            // Raster support and antialias margin enclose all observed glyph
            // components. Keep the old along span; a certified source axis
            // does not justify trimming either already observed endpoint.
            let pad=CGFloat(2),lo=measured.minX-pad,hi=measured.maxX+pad
            guard hi-lo >= g*0.25,hi-lo <= g*0.9,
                  g-(hi-lo) > max(2,max(sx,sy)) else { continue }
            let head=min(old.minY,measured.minY-pad),tail=max(old.maxY,measured.maxY+pad)
            let rect=CGRect(x:lo,y:head,width:hi-lo,height:tail-head)
            var polygon=NativeOCRDirectionGeometry.corners(rect).map(restore)
            guard retainsObservedSource(observed,candidate:polygon,uncertainty:hypot(sx,sy)) else { continue }
            var terminal:[CGPoint]?,terminalInk:[[CGPoint]]=[],headCompleted=false,tailCompleted=false
            var scoped=boxes
            scoped[i] = .init(polygon:polygon,score:boxes[i].score,detectorSeedEvidence:evidence)
            if let cap=NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:i,boxes:scoped,frame:frame,
                probability:probability,inkStyle:inkStyles?[i] ?? nil,observedSourceInk:sourceSupport.map(basis.restore),
                terminalInkObserver:{terminalInk.append($0)}),
               let f=NativeOCRRFPrimaryEnsemble.EndpointFrame(polygon) {
                var observed=f.bounds(cap)
                for ink in terminalInk { observed=observed.union(f.bounds(ink).insetBy(dx:-pad,dy:-pad)) }
                headCompleted=observed.minY < f.rect.minY-1;tailCompleted=observed.maxY > f.rect.maxY+1
                if headCompleted || tailCompleted {
                    let complete=observed.union(f.rect)
                    polygon=NativeOCRDirectionGeometry.corners(complete).map(f.restore)
                    terminal=polygon
                }
            }
            guard let finalBasis=NativeOCRRFPrimaryEnsemble.EndpointFrame(polygon) else { continue }
            let padded=NativeOCRDirectionGeometry.corners(finalBasis.rect.insetBy(dx:-g*0.08,dy:0)).map(finalBasis.restore)
            guard (polygon+padded).allSatisfy({ $0.x >= 0 && $0.x <= CGFloat(frame.width) &&
                $0.y >= 0 && $0.y <= CGFloat(frame.height) }) else { continue }
            result.append(.init(parent:i,polygon:polygon,samplings:[polygon,padded],complements:[],
                independentGeometry:false,measuredNormalOnly:true,measuredSourceAxis:slope != 0,
                measuredAxisComponents:rasterBands.isEmpty ? components:rasterBands,
                sourceTerminalProof:terminal,sourceHeadCompletion:headCompleted,sourceTailCompletion:tailCompleted))
        }
        return result
    }

    static func hasTerminalExclamation(_ text:String)->Bool {
        let last=text.unicodeScalars.reversed().first { scalar in
            !CharacterSet.whitespacesAndNewlines.contains(scalar) &&
                scalar.properties.generalCategory != .closePunctuation &&
                scalar.properties.generalCategory != .finalPunctuation
        }
        return last=="!" || last=="！"
    }

    /// A retained word can still have a clipped quote even when it needs no
    /// padding trim or width repair. Reuse the source-colour terminal proof
    /// with the retained crop and the immutable pre-recognition ink palette.
    static func retainedTerminals(boxes:[NativeCoreMLDetectionBox],frame:NativeOCRRGBAFrame,
        probability:NativeMainEnsembleOCRProbability.Sample?,
        inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,retained:Set<Int>,
        peerPolygons:[Int:[CGPoint]],excluding:Set<Int>,representedSpans:[Int:[[CGPoint]]] = [:],
        exclamationParents:Set<Int> = [],pointTrainParents:Set<Int> = [],symbolicParents:Set<Int> = [])->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk,let probability,
              probability.width > 0,probability.height > 0 else { return [] }
        let scoped=boxes.enumerated().map { index,box in
            NativeCoreMLDetectionBox(polygon:peerPolygons[index] ?? box.polygon,score:box.score,
                detectorSeedEvidence:box.detectorSeedEvidence)
        }
        var result:[Proposal]=[]
        for i in retained.sorted() where scoped.indices.contains(i) && !excluding.contains(i) {
            guard let original=peerPolygons[i],let basis=NativeOCRRFPrimaryEnsemble.EndpointFrame(original),
                  basis.rect.width >= 6,basis.rect.height >= basis.rect.width*2,
                  let style=inkStyles.flatMap({ $0.indices.contains(i) ? $0[i]:nil }) else { continue }
            var paint:[[CGPoint]]=[]
            _ = NativeOCRRFPrimaryEnsemble.neutralOutlineTerminalProof(index:i,boxes:scoped,
                frame:frame,probability:probability,inkStyle:style,terminalMarkObserver:{paint.append($0)},
                recognizesExclamation:exclamationParents.contains(i))
            // Reuse the original palette against the retained crop. A generic
            // neutral track envelope cannot establish a new terminal here.
            let train=pointTrainParents.contains(i) ? NativeOCRRFPrimaryEnsemble.compactInkTrainTerminal(
                index:i,boxes:scoped,frame:frame,inkStyle:style):nil
            guard !paint.isEmpty || train != nil else { continue }
            var observed=basis.rect
            for points in paint { observed=observed.union(basis.bounds(points).insetBy(dx:-2,dy:-2)) }
            if let train {
                let r=basis.bounds(train),head=min(observed.minY,r.minY),tail=max(observed.maxY,r.maxY)
                observed=CGRect(x:observed.minX,y:head,width:observed.width,height:tail-head)
            }
            let head=observed.minY < basis.rect.minY-2,tail=observed.maxY > basis.rect.maxY+2
            guard head || tail else { continue }
            // A retained multi-source read may already include this member's
            // cap. Replacing that read with its member would discard the other
            // source identities despite adding no newly observed terminal.
            let grid=max(CGFloat(frame.width)/CGFloat(probability.width),CGFloat(frame.height)/CGFloat(probability.height))
            guard !(representedSpans[i] ?? []).contains(where:{ polygon in
                let r=basis.bounds(polygon),epsilon=max(2,grid)
                return r.minY <= observed.minY+epsilon && r.maxY >= observed.maxY-epsilon
            }) else { continue }
            let symbolic=symbolicParents.contains(i) && (train != nil || !paint.isEmpty)
            let measured=NativeOCRDirectionGeometry.corners(observed).map(basis.restore)
            let physicalNormalGrowth=paint.contains { points in
                let r=basis.bounds(points)
                return r.minX < basis.rect.minX-2 || r.maxX > basis.rect.maxX+2
            }
            // Symbolic trains keep their admitted source shape unless a
            // separately collared cap proves real normal-axis growth. Both
            // paths retain ALL observed cap endpoints, not just the dot train.
            let polygon=symbolic && !physicalNormalGrowth ? NativeOCRRFPrimaryEnsemble.combiningEndpointGrowth(
                base:original,supplement:measured,minimumChange:0):measured
            let padded=NativeOCRDirectionGeometry.corners(observed.insetBy(dx:-basis.rect.width*0.08,dy:0)).map(basis.restore)
            // A dot-width crop can amputate the stem of an exclamation during
            // sampling. Two independent normal paddings read the same measured
            // span; neither padding changes the returned geometry or ownership.
            let wider=NativeOCRDirectionGeometry.corners(observed.insetBy(dx:-basis.rect.width*0.16,dy:0)).map(basis.restore)
            // A physically widened cap already supplies the missing stem
            // room. Keep its exact measured crop as the first real read;
            // applying the dot-width padding pair again can erase that read.
            let samplings=symbolic && !physicalNormalGrowth ? [padded,wider]:[polygon,padded]
            guard (polygon+samplings.flatMap { $0 }).allSatisfy({ $0.x >= 0 && $0.x <= CGFloat(frame.width) &&
                $0.y >= 0 && $0.y <= CGFloat(frame.height) }) else { continue }
            result.append(.init(parent:i,polygon:polygon,samplings:samplings,complements:[],
                independentGeometry:false,measuredTerminalOnly:true,symbolicTerminalOnly:symbolic,sourceTerminalProof:polygon,
                sourceTerminalInk:paint,sourceHeadCompletion:head,sourceTailCompletion:tail))
        }
        return result
    }

    static func proposals(boxes:[NativeCoreMLDetectionBox],layout:NativeRFDETRLayoutResult?,
                          probability:NativeMainEnsembleOCRProbability.Sample?,frame:NativeOCRRGBAFrame,
                          inkStyles:[NativeOCRRFPrimaryEnsemble.EndpointInkStyle?]?,activePeers:Set<Int>? = nil,peerPolygons:[Int:[CGPoint]] = [:],excludingParents:Set<Int> = [],retainedSingleGlyphs:Set<Int> = [],audit:((Int,String)->Void)? = nil)->[Proposal] {
        guard NativeOCRRFPrimaryEnsemble.refinesEndpointInk,let map=probability,
              map.sourceWidth==frame.width,map.sourceHeight==frame.height,
              map.width > 0,map.height > 0,map.values.count==map.width*map.height else { return [] }
        typealias Basis=NativeOCRRFPrimaryEnsemble.EndpointFrame
        let sx=CGFloat(frame.width)/CGFloat(map.width),sy=CGFloat(frame.height)/CGFloat(map.height)
        let references=boxes.indices.compactMap { i -> (Int,Basis)? in
            // The late pass has actual retained reads. A rejected thin tail
            // must not become the font-size or direction authority merely
            // because its detector rectangle is the closest one.
            guard activePeers?.contains(i) ?? true,
                  boxes[i].score >= 0.8,boxes[i].detectorSeedEvidence?.isValid == true,
                  let f=Basis(peerPolygons[i] ?? boxes[i].polygon),
                  f.rect.width >= 6,f.rect.height >= f.rect.width*2 else { return nil }
            return (i,f)
        }
        var output:[Proposal]=[]
        for i in boxes.indices where !excludingParents.contains(i) {
            audit?(i,"start score=\(boxes[i].score)")
            guard let own=Basis(boxes[i].polygon),own.rect.width >= 5,
                  let evidence=boxes[i].detectorSeedEvidence,evidence.isValid,
                  boxes[i].score >= 0.5 || evidence.components.contains(where:{
                      $0.pixelCount >= 8 && $0.meanProbability >= evidence.threshold
                  }) else { continue }
            let retainedBasis=peerPolygons[i].flatMap(Basis.init)
            // A long retained word can end inside a glyph also detected by a
            // smaller factory. Exact shared-cell containment establishes that
            // endpoint alias; proximity to another rectangle does not.
            let endpointAlias:Bool
            if own.rect.height > own.rect.width*3.2,activePeers?.contains(i)==true,
               let retainedBasis,let support=peerPolygons[i] {
                let original=retainedBasis.bounds(boxes[i].polygon),g=retainedBasis.rect.width
                endpointAlias=boxes.indices.contains { j in
                    guard j != i,boxes[j].score >= 0.8,let child=boxes[j].detectorSeedEvidence,
                          let childBasis=Basis(boxes[j].polygon) else { return false }
                    let r=retainedBasis.bounds(boxes[j].polygon)
                    return childBasis.rect.width >= 5 && r.width < g*0.7 && r.height <= g*2 &&
                        r.minY >= original.maxY-g && r.maxY > original.maxY+1 &&
                        abs(r.midX-original.midX) <= g*0.35 &&
                        NativeOCRRFPrimaryEnsemble.retainsSharedGlyph(child:child,parent:evidence,
                            childPolygon:boxes[j].polygon,container:support)
                }
            } else { endpointAlias=false }
            // A strong but unread column may have lost its normal-axis glyph
            // margin. Only the late pass can establish that it is unread;
            // a shared RF text scope must also support the retained font peer.
            let unreadColumn=own.rect.height > own.rect.width*3.2 &&
                activePeers.map { !$0.contains(i) } == true && boxes[i].score >= 0.8
            guard own.rect.height <= own.rect.width*3.2 || endpointAlias || unreadColumn else { continue }
            audit?(i,"eligible")
            var privateSource:[CGPoint]=[]
            for component in evidence.components where component.meanProbability >= evidence.threshold {
                for run in component.runs { for x in run.x..<(run.x+run.count) {
                    let p=CGPoint(x:(CGFloat(x)+0.5)*CGFloat(frame.width)/CGFloat(evidence.mapFullWidth),
                                  y:(CGFloat(run.y)+0.5)*CGFloat(frame.height)/CGFloat(evidence.mapFullHeight))
                    if NativeOCRDirectionGeometry.contains(boxes[i].polygon,p) { privateSource.append(p) }
                } }
            }
            let candidates=references.compactMap { entry -> (Int,Basis,CGFloat)? in
                let (j,f)=entry
                guard j != i else { return nil }
                if unreadColumn {
                    guard abs(own.along.x*f.along.x+own.along.y*f.along.y) >= 0.95,
                          layout?.primitives.contains(where:{ p in
                              p.semanticClass == .text && p.confidence >= 0.4 &&
                              NativeOCRDirectionAdapters.coverage(boxes[i].polygon,by:p) >= 0.9 &&
                              NativeOCRDirectionAdapters.coverage(peerPolygons[j] ?? boxes[j].polygon,by:p) >= 0.9
                          }) == true else { return nil }
                }
                let r=f.bounds(boxes[i].polygon),g=f.rect.width
                let cross=max(f.rect.minX-r.maxX,r.minX-f.rect.maxX,0)
                let along=max(f.rect.minY-r.maxY,r.minY-f.rect.maxY,0)
                let fit=privateSource.count >= 8 ? f.bounds(privateSource):r
                guard fit.width >= g*0.35,fit.width <= g*6,fit.height <= g*6,
                      cross <= g*5,along <= g*3 else { return nil }
                return (j,f,(cross+along)/g+abs(log(max(0.1,fit.width/g)))*0.3)
            }
            let selectedReference:(Int,Basis,CGFloat)? = endpointAlias ?
                retainedBasis.map { (i,$0,CGFloat(0)) }:candidates.min(by:{ $0.2 < $1.2 })
            guard let reference=selectedReference else { audit?(i,"no reference");continue }
            let basis=reference.1
            audit?(i,"reference width=\(basis.rect.width)")
            let original=basis.bounds(boxes[i].polygon),glyph=basis.rect.width
            let sharedMarks=sharedContinuationSeeds(evidence:evidence,source:boxes[i].polygon,
                reference:boxes[reference.0].polygon)
            audit?(i,"shared continuation seeds=\(sharedMarks.sorted())")
            let nestedAnchors=boxes.indices.compactMap { j -> CGRect? in
                guard j != i,boxes[j].score >= 0.8,let child=boxes[j].detectorSeedEvidence else { return nil }
                let q=peerPolygons[j] ?? boxes[j].polygon,r=basis.bounds(q)
                guard r.width >= 5,r.height <= r.width*2,
                      r.width < original.width*0.7,r.height < original.height*0.7,
                      NativeOCRRFPrimaryEnsemble.retainsSharedGlyph(child:child,parent:evidence,
                          childPolygon:q,container:boxes[i].polygon) else { return nil }
                return r
            }
            let nestedAnchor=nestedAnchors.sorted { a,b in a.width==b.width ? a.minX < b.minX:a.width > b.width }.first
            let broad=original.width > glyph*1.8 && evidence.components.isEmpty
            var peers:Set<Int>=[]
            if broad {
                guard evidence.components.isEmpty,evidence.candidateComponents?.contains(where:{ c in
                    c.outsideCompetingCells.contains { Double($0) >= Double(c.component.pixelCount)*0.8 }
                }) == true else { continue }
                peers=Set(boxes.indices.filter { j in
                    guard j != i,boxes[j].score >= 0.6,let f=Basis(boxes[j].polygon),
                          f.rect.height >= f.rect.width*1.4 else { return false }
                    let r=basis.bounds(boxes[j].polygon),intersection=original.intersection(r)
                    return !intersection.isNull && intersection.width*intersection.height >= r.width*r.height*0.6 &&
                        r.width >= glyph*0.5 && r.width <= glyph*1.8
                })
                guard !peers.isEmpty,layout?.primitives.contains(where:{ p in
                    p.semanticClass == .text && p.confidence >= 0.55 &&
                        NativeOCRDirectionAdapters.coverage(boxes[i].polygon,by:p) > 0
                }) == true else { continue }
            }
            var search=original.insetBy(dx:-glyph*0.15,dy:-glyph*1.5)
            if endpointAlias {
                // Rejected fragments can nominate observation extent, never
                // its font scale, ownership, or an admitted recognition. Keep
                // the retained word's basis and inspect a bounded same-lane
                // chain; actual DB/RGB cells and retained peers still bound it.
                let tails=boxes.indices.compactMap { j -> CGRect? in
                    guard j != i,activePeers?.contains(j) != true,boxes[j].score >= 0.8,
                          boxes[j].detectorSeedEvidence?.isValid==true,
                          let f=Basis(boxes[j].polygon),
                          abs(f.along.x*basis.along.x+f.along.y*basis.along.y) >= 0.95 else { return nil }
                    let r=basis.bounds(boxes[j].polygon)
                    let cross=min(r.maxX,original.maxX)-max(r.minX,original.minX)
                    guard r.width <= glyph*1.5,r.height <= glyph*4,
                          cross >= min(r.width,original.width)*0.6,
                          abs(r.midX-original.midX) <= glyph*0.35,
                          r.maxY > original.maxY,r.maxY <= original.maxY+glyph*4 else { return nil }
                    return r
                }.sorted { $0.minY < $1.minY }
                var tail=original.maxY
                for r in tails where r.minY <= tail+glyph*0.9 { tail=max(tail,r.maxY) }
                let head=min(original.minY,retainedBasis?.rect.minY ?? original.minY)
                search=CGRect(x:search.minX,y:head,width:search.width,
                    height:max(search.maxY,tail+glyph)-head)
                audit?(i,"retained endpoint alias; observed tail=\(tail)")
            }
            let world=NativeOCRDirectionGeometry.bounds(NativeOCRDirectionGeometry.corners(search).map(basis.restore))
            let x0=max(0,Int(floor(world.minX/sx))),x1=min(map.width,Int(ceil(world.maxX/sx)))
            let y0=max(0,Int(floor(world.minY/sy))),y1=min(map.height,Int(ceil(world.maxY/sy)))
            guard x1 > x0,y1 > y0,(x1-x0)*(y1-y0) <= 65_536 else { continue }
            // Other private glyphs bound a crop; their padding must not veto
            // a valid neighbouring glyph wholesale. Work in the nominated
            // intrinsic frame and keep their complete private-core envelopes.
            var blockers:[CGRect]=[]
            let searchQuad=NativeOCRDirectionGeometry.corners(search).map(basis.restore)
            func observedPeerComponents(_ peer:NativeOCRDetectorSeedEvidence)->[NativeOCRDetectorSeedEvidence.Component] {
                guard activePeers != nil else { return peer.components.filter { !sharedMarks.contains($0.seed) } }
                let exclusive=(peer.candidateComponents ?? []).filter { candidate in
                    candidate.outsideCompetingCells.allSatisfy { $0*5 >= candidate.component.pixelCount*4 }
                }.map(\.component)
                return (peer.components+exclusive).filter { !sharedMarks.contains($0.seed) }
            }
            for j in boxes.indices where j != i && (activePeers?.contains(j) ?? true) {
                guard let peer=boxes[j].detectorSeedEvidence,peer.isValid,peer.ownerID != evidence.ownerID,
                      NativeOCRDirectionGeometry.intersectionArea(searchQuad,peerPolygons[j] ?? boxes[j].polygon) > 0 else { continue }
                let dx=CGFloat(frame.width)/CGFloat(peer.mapFullWidth),dy=CGFloat(frame.height)/CGFloat(peer.mapFullHeight)
                for component in observedPeerComponents(peer) {
                    var points:[CGPoint]=[]
                    for run in component.runs { for x in run.x..<(run.x+run.count) {
                        let world=CGPoint(x:(CGFloat(x)+0.5)*dx,y:(CGFloat(run.y)+0.5)*dy),p=basis.project(world)
                        if search.contains(p),NativeOCRDirectionGeometry.contains(peerPolygons[j] ?? boxes[j].polygon,world),
                           !NativeOCRDirectionGeometry.contains(boxes[i].polygon,world) { points.append(p) }
                    } }
                    if points.count >= 2 {
                        // A peer can wrap around this crop. Its enclosing
                        // rectangle would fill the unowned hole between two
                        // sides and veto our own glyph. Keep occupied runs in
                        // the nominated frame instead of filling that hole.
                        let step=max(dx,dy)
                        let rows=Dictionary(grouping:points,by:{Int(floor($0.y/step))})
                        for (row,cells) in rows {
                            let columns=Set(cells.map { Int(floor($0.x/step)) }).sorted()
                            guard let first=columns.first else { continue }
                            var start=first,last=first
                            func appendRun() {
                                blockers.append(CGRect(x:CGFloat(start)*step-step,y:CGFloat(row)*step-step,
                                    width:CGFloat(last-start+3)*step,height:step*3))
                            }
                            for column in columns.dropFirst() {
                                if column > last+1 { appendRun();start=column }
                                last=column
                            }
                            appendRun()
                        }
                    }
                }
            }
            var laneHead = nestedAnchor == nil ? search.minY:original.minY,
                laneTail=nestedAnchor == nil ? search.maxY:original.maxY
            for blocker in blockers where blocker.maxX > original.minX && blocker.minX < original.maxX {
                if blocker.maxY <= original.minY { laneHead=max(laneHead,blocker.maxY) }
                if blocker.minY >= original.maxY { laneTail=min(laneTail,blocker.minY) }
            }
            var cells:[CGPoint]=[]
            let ownColours=inkStyles?[i]?.colors ?? []
            // A broad, tilted parent can learn its paper instead of its ink.
            // A nearby resolved word supplies the print-colour hypothesis;
            // only matching actual parent pixels may establish its head lane.
            let colours: [[Int]] = original.width > glyph*1.8 && nestedAnchor == nil ?
                (inkStyles?[reference.0]?.colors.first.map { [$0] } ?? ownColours):ownColours
            func sourceInk(_ world:CGPoint)->Bool {
                let xx=Int(floor(world.x)),yy=Int(floor(world.y))
                guard xx >= 0,yy >= 0,xx < frame.width,yy < frame.height else { return false }
                let offset=yy*frame.bytesPerRow+xx*4
                return colours.contains { colour in
                    colour.count==3 && (0..<3).map({abs(Int(frame.bytes[offset+$0])-colour[$0])}).max()! <= 24
                }
            }
            for y in y0..<y1 { for x in x0..<x1 {
                let v=map.values[y*map.width+x]
                guard v.isFinite,v >= 0.05 else { continue }
                let world=CGPoint(x:(CGFloat(x)+0.5)*sx,y:(CGFloat(y)+0.5)*sy),p=basis.project(world)
                guard search.contains(p),p.y >= laneHead,p.y <= laneTail,!blockers.contains(where:{ $0.contains(p) }) else { continue }
                if v < 0.85 {
                    guard !broad,sourceInk(world) else { continue }
                }
                cells.append(p)
            } }
            audit?(i,"cells=\(cells.count) blockers=\(blockers.count) original=\(original)")
            guard cells.count >= 8 else { continue }
            var bands:[CGRect]=[]
            if broad {
                let available=cells.filter { p in
                    original.contains(p) && !peers.contains { j in
                        let r=basis.bounds(boxes[j].polygon)
                        return abs(p.x-r.midX) <= r.width*0.4
                    }
                }
                let bins=Dictionary(grouping:available,by:{ Int(floor($0.x)) }).keys.sorted()
                var spans:[ClosedRange<Int>]=[]
                for x in bins {
                    if let last=spans.last,CGFloat(x-last.upperBound) <= glyph*0.25 {
                        spans[spans.count-1]=last.lowerBound...x
                    } else { spans.append(x...x) }
                }
                for span in spans where CGFloat(span.upperBound-span.lowerBound+1) >= glyph*0.4 {
                    let points=available.filter { Int(floor($0.x)) >= span.lowerBound && Int(floor($0.x)) <= span.upperBound }
                    let r=points.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
                    if points.count >= 12,r.height >= glyph*1.5,r.width <= glyph*1.8 { bands.append(r) }
                }
                guard bands.count==1 else { continue }
            } else {
                var anchor:[CGPoint]=[]
                let all=evidence.components+(evidence.ambiguousComponents ?? [])+(evidence.candidateComponents ?? []).map(\.component)
                for c in all {
                    var inside:[CGPoint]=[]
                    for run in c.runs { for x in run.x..<(run.x+run.count) {
                        let p=CGPoint(x:(CGFloat(x)+0.5)*CGFloat(frame.width)/CGFloat(evidence.mapFullWidth),
                                      y:(CGFloat(run.y)+0.5)*CGFloat(frame.height)/CGFloat(evidence.mapFullHeight))
                        if NativeOCRDirectionGeometry.contains(boxes[i].polygon,p) { inside.append(basis.project(p)) }
                    } }
                    if inside.count >= 2,Double(inside.count) >= Double(c.pixelCount)*0.7 { anchor += inside }
                }
                let core=anchor.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
                let narrow = !core.isNull && core.width > 0
                // A nested shared-glyph detector already resolves the lane.
                // The broad parent's other columns must not vote that child's
                // own complete glyph out of its narrow band.
                let wideAnchor=nestedAnchor == nil && narrow && original.width > glyph*1.8
                let painted=anchor.filter { sourceInk(basis.restore($0)) }
                let headPoints=wideAnchor ? painted.filter { $0.y <= core.minY+glyph*1.5 }:[]
                let headCore=headPoints.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }
                let guided=wideAnchor && headPoints.count >= 8 && headCore.width > 0
                let centre=endpointAlias ? original.midX:
                    (nestedAnchor?.midX ?? (guided ? headCore.midX:(narrow ? core.midX:original.midX)))
                let width=endpointAlias ? search.width:(nestedAnchor.map { $0.width+max(sx,sy)*2 } ??
                    (guided ? max(glyph*0.75,headCore.width+max(sx,sy)*2):
                    (narrow ? min(original.width*1.2,max(glyph*0.75,core.width*1.6+max(sx,sy))):original.width)))
                let normal=CGRect(x:centre-width/2,y:search.minY,width:width,height:search.height)
                var rejectedBands=Set<Int>()
                if guided {
                    let bins=Dictionary(grouping:painted,by:{Int(floor(($0.y-core.minY)/glyph))})
                    for (bin,points) in bins where points.count >= 8 {
                        if Double(points.filter { normal.contains($0) }.count) < Double(points.count)*0.6 { rejectedBands.insert(bin) }
                    }
                }
                let selected=cells.filter { normal.contains($0) && (!guided || !rejectedBands.contains(Int(floor(($0.y-core.minY)/glyph)))) }
                let originalPoints=selected.filter { original.contains($0) }
                audit?(i,"anchor=\(anchor.count) normal=\(normal) originalPoints=\(originalPoints.count)")
                guard originalPoints.count >= 4 else { continue }
                var first=originalPoints.map(\.y).min()!,last=guided ? first:originalPoints.map(\.y).max()!
                if guided {
                    for p in selected.sorted(by:{$0.y < $1.y}) where p.y > last {
                        if p.y-last > glyph*0.9 { break };last=p.y
                    }
                }
                for p in selected.sorted(by:{ $0.y > $1.y }) where p.y < first {
                    if first-p.y > glyph*0.9 { break };first=p.y
                }
                for p in selected.sorted(by:{ $0.y < $1.y }) where p.y > last {
                    if p.y-last > glyph*0.9 { break };last=p.y
                }
                let kept=selected.filter { $0.y >= first && $0.y <= last }
                bands=[kept.reduce(CGRect.null) { $0.union(CGRect(origin:$1,size:.zero)) }]
            }
            guard var rect=bands.first,!rect.isNull,rect.width >= 3,rect.height >= 3 else { continue }
            audit?(i,"band=\(rect)")
            let measuredBand=rect
            rect=rect.insetBy(dx:-max(max(sx,sy),broad ? glyph*0.2:0),dy:-max(max(sx,sy),broad ? glyph*0.25:0))
            if unreadColumn {
                // Probability seeds can cover only the light interior of an
                // outlined glyph. A missing read supplies no evidence that its
                // original normal extent was empty; preserve it for both REC
                // observations instead of cropping down to those interior cells.
                let left=min(rect.minX,original.minX),right=max(rect.maxX,original.maxX)
                rect=CGRect(x:left,y:rect.minY,width:right-left,height:rect.height)
            }
            if endpointAlias,let retainedBasis {
                // This nomination proves a missing tail, not a replacement
                // of the already recognized head, width, or reading baseline.
                guard measuredBand.maxY > retainedBasis.rect.maxY+glyph*0.2 else { continue }
                let left=min(rect.minX,retainedBasis.rect.minX),right=max(rect.maxX,retainedBasis.rect.maxX)
                rect=CGRect(x:left,y:retainedBasis.rect.minY,width:right-left,
                    height:max(rect.maxY,retainedBasis.rect.maxY)-retainedBasis.rect.minY)
            }
            var leftLimit = -CGFloat.greatestFiniteMagnitude,rightLimit=CGFloat.greatestFiniteMagnitude
            var headLimit = laneHead,tailLimit=laneTail
            for blocker in blockers {
                if blocker.maxX <= measuredBand.minX { leftLimit=max(leftLimit,blocker.maxX) }
                if blocker.minX >= measuredBand.maxX { rightLimit=min(rightLimit,blocker.minX) }
                if blocker.maxY <= measuredBand.minY { headLimit=max(headLimit,blocker.maxY) }
                if blocker.minY >= measuredBand.maxY { tailLimit=min(tailLimit,blocker.minY) }
            }
            for j in peers {
                let r=basis.bounds(boxes[j].polygon),mid=(r.midX+rect.midX)/2
                if r.midX < rect.midX { leftLimit=max(leftLimit,mid) } else { rightLimit=min(rightLimit,mid) }
            }
            let right=min(rightLimit,rect.maxX),left=max(leftLimit,rect.minX)
            guard right-left >= glyph*0.35 else { continue }
            let head=max(headLimit,rect.minY),tail=min(tailLimit,rect.maxY)
            guard tail-head >= 3 else { continue }
            rect=CGRect(x:left,y:head,width:right-left,height:tail-head)
            var alignment=abs(own.along.x*basis.along.x+own.along.y*basis.along.y)
            // Near-square single glyphs have no resolved long edge. Swapping
            // their two edge labels is not a physical 90-degree correction.
            if max(own.rect.width,own.rect.height) <= min(own.rect.width,own.rect.height)*1.5 {
                alignment=max(alignment,abs(own.across.x*basis.along.x+own.across.y*basis.along.y))
            }
            // A short quad's baseline has detector-cell angular uncertainty.
            // Do not manufacture a new reading from an unresolvable tilt change.
            let angularUncertainty=max(CGFloat.pi/36,atan2(2*max(sx,sy),min(own.rect.width,own.rect.height)))
            let changedAxis=alignment < cos(angularUncertainty*(activePeers?.contains(i)==true ? 1:2))
            let grows=original.minY-measuredBand.minY > glyph*0.2 || measuredBand.maxY-original.maxY > glyph*0.2
            let narrows=nestedAnchor != nil || (activePeers?.contains(i)==true && privateSource.count >= 8 &&
                original.width >= glyph*1.5 && original.width-measuredBand.width > glyph*0.5)
            let restoresWidth=unreadColumn && privateSource.count >= 8 &&
                (original.minX-measuredBand.minX > max(sx,sy) || measuredBand.maxX-original.maxX > max(sx,sy))
            audit?(i,"angle=\(changedAxis) growth=\(grows) narrow=\(narrows) rect=\(rect)")
            guard broad || changedAxis || grows || narrows || restoresWidth else { continue }
            func quad(_ r:CGRect)->[CGPoint] { NativeOCRDirectionGeometry.corners(r).map(basis.restore) }
            let polygon=quad(rect)
            // A single retained glyph cannot corroborate its sampling axis
            // through an observed word sequence. Its private strokes must
            // independently survive the contextual recrop. Multi-glyph words
            // retain the separate two-read/core-continuation admission proof.
            if activePeers?.contains(i)==true,retainedSingleGlyphs.contains(i) {
                let retained=(privateSource+cells.map(basis.restore)).filter { point in
                    guard sourceInk(point),NativeOCRDirectionGeometry.contains(peerPolygons[i] ?? boxes[i].polygon,point)
                    else { return false }
                    // A broad detector parent may cover an independently read
                    // neighbouring column. Its ink is not this source's private
                    // stroke merely because the original rectangle encloses it.
                    return !boxes.indices.contains { j in
                        guard j != i,activePeers?.contains(j)==true,
                              let peer=boxes[j].detectorSeedEvidence,peer.ownerID != evidence.ownerID,
                              !observedPeerComponents(peer).isEmpty else { return false }
                        return NativeOCRDirectionGeometry.contains(peerPolygons[j] ?? boxes[j].polygon,point)
                    }
                }
                guard retainsObservedSource(retained,candidate:polygon,uncertainty:hypot(sx,sy)) else {
                    audit?(i,"drops retained source cells");continue
                }
            }
            // Padding on the broad detector parent is not evidence of text.
            // Validate RF support against the measured remaining column instead.
            if broad {
                guard layout?.primitives.contains(where:{ p in
                    p.semanticClass == .text && p.confidence >= 0.55 &&
                        NativeOCRDirectionAdapters.coverage(polygon,by:p) >= 0.9
                }) == true else { continue }
            }
            guard polygon.allSatisfy({ $0.x >= 0 && $0.x <= CGFloat(frame.width) && $0.y >= 0 && $0.y <= CGFloat(frame.height) }) else { continue }
            let samplings:[[[CGPoint]]]=[0.12,0.24].map { f in
                var r=rect.insetBy(dx:-glyph*f,dy:-glyph*f)
                let x0=max(leftLimit,r.minX),x1=min(rightLimit,r.maxX)
                let y0=max(headLimit,r.minY),y1=min(tailLimit,r.maxY)
                r=CGRect(x:x0,y:y0,width:x1-x0,height:y1-y0)
                let q=quad(r)
                return q.allSatisfy({ $0.x >= 0 && $0.x <= CGFloat(frame.width) && $0.y >= 0 && $0.y <= CGFloat(frame.height) }) ? [q]:[]
            }
            let variants=samplings.flatMap { $0 }
            guard variants.count==2 else { continue }
            let borrows=variants.contains { sampling in
                boxes.indices.contains { j in
                    guard j != i,(activePeers?.contains(j) ?? true),let peer=boxes[j].detectorSeedEvidence,peer.isValid,
                          peer.ownerID != evidence.ownerID,
                          NativeOCRDirectionGeometry.intersectionArea(sampling,peerPolygons[j] ?? boxes[j].polygon) > 0 else { return false }
                    let dx=CGFloat(frame.width)/CGFloat(peer.mapFullWidth),dy=CGFloat(frame.height)/CGFloat(peer.mapFullHeight)
                    for c in observedPeerComponents(peer) { for run in c.runs { for x in run.x..<(run.x+run.count) {
                        let p=CGPoint(x:(CGFloat(x)+0.5)*dx,y:(CGFloat(run.y)+0.5)*dy)
                        if NativeOCRDirectionGeometry.contains(peerPolygons[j] ?? boxes[j].polygon,p),
                           NativeOCRDirectionGeometry.contains(sampling,p),
                           !NativeOCRDirectionGeometry.contains(boxes[i].polygon,p) { audit?(i,"foreign=\(j) point=\(p)");return true }
                    } } }
                    return false
                }
            }
            audit?(i,"borrows=\(borrows) variants=\(variants.count)")
            guard !borrows else { continue }
            audit?(i,"proposed")
            output.append(.init(parent:i,polygon:polygon,samplings:variants,complements:peers,
                independentGeometry:broad || changedAxis || nestedAnchor != nil))
        }
        // Unresolved broad columns and genuinely ambiguous axes have priority;
        // a fixed page budget bounds both recognition cost and source exposure.
        return Array(output.sorted { a,b in
            if a.complements.isEmpty != b.complements.isEmpty { return !a.complements.isEmpty }
            return a.parent < b.parent
        }.prefix(16))
    }
}
