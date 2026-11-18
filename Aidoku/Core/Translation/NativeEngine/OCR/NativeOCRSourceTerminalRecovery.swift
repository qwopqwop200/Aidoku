import CoreGraphics
import Foundation

/// Source-only nomination. It never decodes text or invokes a model. A proposal
/// is NOT ownership/acceptance: actual REC prefix preservation is required later.
@available(iOS 18.0, *)
enum NativeOCRSourceTerminalRecovery {
    typealias G = NativeOCRIndividualGeometryHypotheses
    private typealias D = NativeOCRGeometryDeduplication
    struct Proposal: Sendable {
        let parentBankIndex: Int
        let terminalBankIndex: Int
        let parentSource: Int
        let terminalSource: Int
        let rfQueryID: Int
        let polygon: [G.Point]
        let parentPrivatePixels: Int
        let terminalPrivatePixels: Int
    }
    struct Proof: Equatable, Sendable {
        let requestID: String
        let sourceImageIdentity: String
        let parentSource: Int
        let terminalSource: Int
        let rfQueryID: Int
        let polygon: [G.Point]
        let bboxConfidence: Double
        let recognitionConfidence: Double
        let prefixUTF8Count: Int
        let appendedCharacterCount: Int
        let parentPrivatePixels: Int
        let terminalPrivatePixels: Int
    }
    struct GeometrySelection: Sendable {
        let proposals: [Proposal]
        let duplicateGeometryRejected: Int
        let invalidGeometryRejected: Int
    }
    /// Optional nominations never win arbitrary ownership by a quad tie.
    /// Exact cyclic/reversed equality only; no quantization or IoU threshold.
    static func uniqueProposalGeometry(_ proposals:[Proposal])->GeometrySelection {
        func key(_ q:[G.Point])->[G.Point]? {
            let shape=D.Shape(q)
            guard q.count==4,shape.convex,shape.area.isFinite,shape.area>0 else { return nil }
            func less(_ a:[G.Point],_ b:[G.Point])->Bool {
                for i in a.indices where a[i] != b[i] {
                    return a[i].x == b[i].x ? a[i].y<b[i].y:a[i].x<b[i].x
                }
                return false
            }
            var cycles=[[G.Point]]()
            for start in 0..<4 {
                var forward=[G.Point](),reverse=[G.Point]()
                for offset in 0..<4 {
                    forward.append(q[(start+offset)%4])
                    reverse.append(q[(start+4-offset)%4])
                }
                cycles.append(forward);cycles.append(reverse)
            }
            return cycles.min(by:less)
        }
        let keyed=proposals.compactMap { p in key(p.polygon).map { (p,$0) } }
        let groups=Dictionary(grouping:keyed,by:{ $0.1 })
        let kept=keyed.filter { groups[$0.1]!.count==1 }.map(\.0)
        return .init(proposals:kept,duplicateGeometryRejected:keyed.count-kept.count,
            invalidGeometryRejected:proposals.count-keyed.count)
    }
    private struct Axes {
        let ux: Double; let uy: Double
        let vx: Double; let vy: Double
        let low: Double; let high: Double
        let normalLow: Double; let normalHigh: Double
        var shortSide: Double { normalHigh-normalLow }
        func project(_ p: G.Point) -> (Double,Double) { (p.x*ux+p.y*uy,p.x*vx+p.y*vy) }
        init?(_ q: [G.Point]) {
            let shape = D.Shape(q)
            guard shape.convex,shape.area.isFinite,shape.area>0,q.count==4 else { return nil }
            let a=(q[1].x-q[0].x,q[1].y-q[0].y),b=(q[2].x-q[1].x,q[2].y-q[1].y)
            let e=hypot(a.0,a.1)>=hypot(b.0,b.1) ? a:b
            let length=hypot(e.0,e.1)
            guard length>0 else { return nil }
            let localUX=e.0/length,localUY=e.1/length,localVX = -localUY,localVY=localUX
            ux=localUX;uy=localUY;vx=localVX;vy=localVY
            let along=q.map { $0.x*localUX+$0.y*localUY },normal=q.map { $0.x*localVX+$0.y*localVY }
            low=along.min()!;high=along.max()!;normalLow=normal.min()!;normalHigh=normal.max()!
        }
    }
    private static func inside(_ q:[G.Point],_ p:G.Point)->Bool {
        let crosses=q.indices.map { i -> Double in
            let a=q[i],b=q[(i+1)%q.count]
            return (b.x-a.x)*(p.y-a.y)-(b.y-a.y)*(p.x-a.x)
        }
        return crosses.allSatisfy { $0 >= -1e-8 } || crosses.allSatisfy { $0 <= 1e-8 }
    }
    private static func intersectionArea(_ a:D.Shape,_ b:D.Shape)->Double {
        let overlap=D.intersectionIoU(a,b,minimum:0)
        return overlap*(a.area+b.area)/(1+overlap)
    }
    private static func privatePixels(_ box:NativeCoreMLDetectionBox,
                                      probability:NativeMainEnsembleOCRProbability.Sample)->Set<Int>? {
        guard let seed=box.detectorSeedEvidence,seed.isValid,seed.completeCCScan==true,
              seed.sourceWidth==probability.sourceWidth,seed.sourceHeight==probability.sourceHeight,
              seed.mapFullWidth==probability.width,seed.mapFullHeight==probability.height,
              !seed.components.isEmpty else { return nil }
        var result=Set<Int>()
        for component in seed.components {
            for run in component.runs {
                guard run.y>=0,run.y<probability.height,run.x>=0,run.count>0,
                      run.x<=probability.width-run.count else { return nil }
                for x in run.x..<(run.x+run.count) { result.insert(run.y*probability.width+x) }
            }
        }
        return result.isEmpty ? nil:result
    }
    static func proposals(bank:G.Output,reads:[NativeCoreMLRecognizedRegion],
                          originals:[NativeCoreMLDetectionBox],layout:NativeRFDETRLayoutResult,
                          probability:NativeMainEnsembleOCRProbability.Sample,
                          cancellationCheck:() throws -> Void = {}) throws -> [Proposal] {
        let w=probability.width,h=probability.height
        guard w>0,h>0,w==probability.resizedWidth,h==probability.resizedHeight,
              probability.region==CGRect(x:0,y:0,width:w,height:h),
              probability.values.count==w*h else { return [] }
        guard reads.count<bank.individuals.count else { return [] }
        let roots=originals.map { $0.polygon.map { G.Point(x:Double($0.x),y:Double($0.y)) } }
        let pixels=try originals.map { box in try cancellationCheck();return privatePixels(box,probability:probability) }
        func point(_ i:Int)->G.Point {
            .init(x:(Double(i%w)+0.5)*Double(probability.sourceWidth)/Double(w),
                  y:(Double(i/w)+0.5)*Double(probability.sourceHeight)/Double(h))
        }
        var sourceByBank=[Int:Int]()
        for (i,row) in bank.individuals.enumerated() {
            guard row.provenance.count==1,let p=row.provenance.first,
                  roots.indices.contains(p.sourceParent),p.sourceMembers.isEmpty,
                  p.originalDetectorIndex==nil,p.polygon==row.polygon,
                  roots[p.sourceParent]==row.polygon else { return [] }
            sourceByBank[i]=p.sourceParent
        }
        let accepted=Set(reads.map(\.sourceIndex))
        guard accepted.count==reads.count,accepted.allSatisfy(bank.individuals.indices.contains) else { return [] }
        let failed=bank.individuals.indices.filter { !accepted.contains($0) }
        let textRF=layout.primitives.filter { $0.semanticClass == .text }
        var possible=[Proposal]()
        for tinyIndex in failed {
            try cancellationCheck()
            guard let tinySource=sourceByBank[tinyIndex],let tinyPixels=pixels[tinySource] else { continue }
            let tiny=bank.individuals[tinyIndex].polygon
            for parentIndex in accepted.sorted() {
                guard let parentSource=sourceByBank[parentIndex],let parentPixels=pixels[parentSource],
                      parentPixels.isDisjoint(with:tinyPixels),
                      let axes=Axes(bank.individuals[parentIndex].polygon) else { continue }
                let parent=bank.individuals[parentIndex].polygon
                let short=axes.shortSide
                guard short>0,axes.high-axes.low>=2*short else { continue }
                let tc=tiny.map { axes.project($0) }
                let tinyLow=tc.map(\.0).min()!,tinyHigh=tc.map(\.0).max()!
                let tinyNormalLow=tc.map(\.1).min()!,tinyNormalHigh=tc.map(\.1).max()!
                guard tinyHigh-tinyLow<=short,tinyNormalHigh-tinyNormalLow<=short,
                      tinyHigh>axes.high,tinyHigh-axes.high<=short,
                      tinyNormalLow>=axes.normalLow-0.25*short,
                      tinyNormalHigh<=axes.normalHigh+0.25*short else { continue }
                let parentPrivate=parentPixels.map { axes.project(point($0)) }
                let tinyPrivate=tinyPixels.map { axes.project(point($0)) }
                let parentPrivateEnd=parentPrivate.map(\.0).max()!,tinyPrivateStart=tinyPrivate.map(\.0).min()!
                guard tinyPrivateStart>parentPrivateEnd,tinyPrivateStart-parentPrivateEnd<=short,
                      tinyPrivate.allSatisfy({ $0.1>=axes.normalLow && $0.1<=axes.normalHigh }) else { continue }
                func center(_ q:[G.Point])->CGPoint {
                    .init(x:q.reduce(0) { $0+$1.x }/4,y:q.reduce(0) { $0+$1.y }/4)
                }
                let owners=textRF.filter { $0.sourceBounds.contains(center(parent)) && $0.sourceBounds.contains(center(tiny)) }
                guard owners.count==1 else { continue }
                let normalLow=min(axes.normalLow,tinyNormalLow),normalHigh=max(axes.normalHigh,tinyNormalHigh)
                let polygon=parent.map { p -> G.Point in
                    let z=axes.project(p)
                    let along=z.0<(axes.low+axes.high)/2 ? axes.low:tinyHigh
                    let normal=z.1<(axes.normalLow+axes.normalHigh)/2 ? normalLow:normalHigh
                    return .init(x:along*axes.ux+normal*axes.vx,y:along*axes.uy+normal*axes.vy)
                }
                let proposed=D.Shape(polygon),old=D.Shape(parent)
                guard proposed.convex,proposed.area.isFinite,proposed.area>0,
                      parentPixels.union(tinyPixels).allSatisfy({ inside(polygon,point($0)) }) else { continue }
                var conflict=false
                for source in roots.indices where source != parentSource && source != tinySource {
                    if let peer=pixels[source] {
                        if peer.contains(where:{ inside(polygon,point($0)) && !inside(parent,point($0)) }) { conflict=true;break }
                    } else {
                        // Unknown private evidence is not permission to acquire
                        // more of a different observed raw source rectangle.
                        let other=D.Shape(roots[source])
                        if intersectionArea(proposed,other)>intersectionArea(old,other)+1e-8 { conflict=true;break }
                    }
                }
                guard !conflict else { continue }
                possible.append(.init(parentBankIndex:parentIndex,terminalBankIndex:tinyIndex,
                    parentSource:parentSource,terminalSource:tinySource,rfQueryID:owners[0].queryID,
                    polygon:polygon,parentPrivatePixels:parentPixels.count,terminalPrivatePixels:tinyPixels.count))
            }
        }
        let byParent=Dictionary(grouping:possible,by:\.parentBankIndex)
        let byTiny=Dictionary(grouping:possible,by:\.terminalBankIndex)
        return possible.filter { byParent[$0.parentBankIndex]!.count==1 && byTiny[$0.terminalBankIndex]!.count==1 }
            .sorted { $0.parentBankIndex<$1.parentBankIndex }
    }
    static func preservesAndAdds(parent:String,retry:String)->Bool {
        retry.count>parent.count && retry.utf8.starts(with:parent.utf8)
    }
}
