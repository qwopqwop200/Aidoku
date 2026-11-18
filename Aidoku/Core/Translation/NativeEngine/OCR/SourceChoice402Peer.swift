import Foundation
import CoreGraphics

// A nomination from existing source receipts, never native admission. No image,
// detector, model, filesystem, ID or GT access occurs here.
enum SourceChoice402Peer {
    private typealias K = NativeOCRSharedBoundary396
    private struct Support {
        let id: Int
        let association: String
        let anchors: Int
        let rootHits: Int
        let peerHits: Int
        let rf: Set<Int>
        let runs: [[Int]]
        let contrast: [[Int]]
    }

    static func preferred(output: NativeOCRSharedBoundary396.Output, actualOld: [CGPoint],
                          basis: NativeOCRSharedBoundary396.Basis, nativeW: CGFloat)
        -> (index: Int, score: Double, receipt: [String: Any])? {
        guard output.receipt["family"] as? String == "repair402-peer-separation",
              output.receipt["status"] as? String == "source-contact-separated-hypotheses",
              !output.proposals.isEmpty, output.proposals.count <= 8,
              actualOld.count == 4, actualOld.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
              nativeW.isFinite, nativeW > 0, nativeW < 100_000,
              basis.origin.x.isFinite, basis.origin.y.isFinite,
              abs(hypot(basis.normal.x,basis.normal.y)-1) < 1e-6,
              abs(hypot(basis.along.x,basis.along.y)-1) < 1e-6,
              abs(basis.normal.x*basis.along.x+basis.normal.y*basis.along.y) < 1e-6,
              let records = output.receipt["sourceSupportComponents"] as? [[String:Any]],
              !records.isEmpty, records.count <= 20_000 else { return nil }
        func integer(_ value: Any?) -> Int? {
            if let x = value as? Int { return x }
            return nil
        }
        func number(_ value: Any?) -> Double? {
            if let x = value as? Double, x.isFinite { return x }
            if let x = value as? CGFloat, x.isFinite { return Double(x) }
            if let x = value as? Int { return Double(x) }
            return nil
        }
        func point(_ value: Any?) -> CGPoint? {
            guard let v = value as? [Any], v.count == 2,
                  let x = number(v[0]), let y = number(v[1]) else { return nil }
            return CGPoint(x:x,y:y)
        }
        func projection(_ p: CGPoint) -> CGPoint {
            let x=p.x-basis.origin.x,y=p.y-basis.origin.y
            return CGPoint(x:x*basis.normal.x+y*basis.normal.y,
                           y:x*basis.along.x+y*basis.along.y)
        }
        // Reconstruct the original local pixel lattice only when at least two
        // recorded source witnesses independently agree on its integer stride.
        var witnesses: [Int:CGPoint] = [:]
        func collect(_ v: [String:Any]) -> Bool {
            guard let i = integer(v["actualLocalPixelIndex"]), i >= 0, i < 600_000,
                  let p = point(v["center"]), let rgb = v["RGB"] as? [Int],
                  rgb.count == 3, rgb.allSatisfy({$0 >= 0 && $0 <= 255}) else { return false }
            if let old = witnesses[i], hypot(old.x-p.x,old.y-p.y) > 1e-6 { return false }
            witnesses[i] = p; return true
        }
        var supports: [Support] = []
        for record in records {
            guard let id = integer(record["componentID"]), id >= 0,
                  let kind = record["association"] as? String,
                  let anchors = integer(record["rootPrivateGGAnchorPixels"]), anchors >= 0,
                  let root = integer(record["sampledRootDetectorHits"]), root >= 0,
                  let peer = integer(record["sampledPeerDetectorHits"]), peer >= 0,
                  let rf = record["RFQueries"] as? [Int],
                  let runs = record["actualLocalRunsYXCount"] as? [[Int]], !runs.isEmpty,
                  let triples = record["actualStableContrastWitnesses"] as? [[[String:Any]]],
                  triples.count >= 2, triples.count <= 16 else { return nil }
            var contrast: [[Int]] = []
            for triple in triples {
                guard triple.count == 3, triple.allSatisfy(collect) else { return nil }
                let ids = triple.compactMap { integer($0["actualLocalPixelIndex"]) }
                let colours = triple.compactMap { $0["RGB"] as? [Int] }
                guard ids.count == 3, colours.count == 3 else { return nil }
                let edge = (0..<3).map { abs(colours[0][$0]-colours[1][$0]) }.max()!
                let stable = (0..<3).map { abs(colours[1][$0]-colours[2][$0]) }.max()!
                guard edge >= 40, stable <= 16 else { return nil }
                contrast.append(ids)
            }
            for v in record["testedActualPixels"] as? [[String:Any]] ?? [] {
                guard collect(v) else { return nil }
            }
            for pair in record["actualCardinalContactWitnesses"] as? [[[String:Any]]] ?? [] {
                guard pair.count == 2, pair.allSatisfy(collect) else { return nil }
            }
            supports.append(Support(id:id,association:kind,anchors:anchors,rootHits:root,
                                    peerHits:peer,rf:Set(rf),runs:runs,contrast:contrast))
        }
        guard Set(supports.map(\.id)).count == supports.count,
              let reference = witnesses.keys.sorted().first, let p0 = witnesses[reference]
        else { return nil }
        var inferredWidths = Set<Int>(), verticalWitnesses = 0
        for i in witnesses.keys.sorted() {
            let p = witnesses[i]!, dx = Double(p.x-p0.x), dy = Double(p.y-p0.y)
            guard abs(dx-dx.rounded()) < 1e-6, abs(dy-dy.rounded()) < 1e-6 else { return nil }
            if abs(dy) < 0.5 {
                guard abs(Double(i-reference)-dx) < 1e-6 else { return nil }
            } else {
                let width = (Double(i-reference)-dx)/dy
                guard width >= 3, width <= 200_000, abs(width-width.rounded()) < 1e-6 else { return nil }
                inferredWidths.insert(Int(width.rounded())); verticalWitnesses += 1
            }
        }
        guard inferredWidths.count == 1, verticalWitnesses >= 2, let width = inferredWidths.first
        else { return nil }
        let origin = CGPoint(x:p0.x-CGFloat(reference%width)-0.5,
                             y:p0.y-CGFloat(reference/width)-0.5)
        func world(_ i:Int) -> CGPoint {
            CGPoint(x:origin.x+CGFloat(i%width)+0.5,y:origin.y+CGFloat(i/width)+0.5)
        }
        var membership: [Int:Int] = [:], pixels: [Int:[Int]] = [:]
        for s in supports {
            for run in s.runs {
                guard run.count == 3, run[0] >= 0, run[0] < 600_000/width,
                      run[1] >= 0, run[2] > 0, run[2] <= width, run[1] <= width-run[2]
                else { return nil }
                for x in run[1]..<(run[1]+run[2]) {
                    let i = run[0]*width+x
                    guard membership.updateValue(s.id,forKey:i) == nil else { return nil }
                    pixels[s.id,default:[]].append(i)
                    if membership.count > 600_000 { return nil }
                }
            }
            for triple in s.contrast {
                guard membership[triple[0]] == s.id,
                      let p = witnesses[triple[0]], let q = witnesses[triple[1]],
                      let t = witnesses[triple[2]],
                      abs(abs(p.x-q.x)+abs(p.y-q.y)-1) < 1e-6,
                      hypot((q.x-p.x)-(t.x-q.x),(q.y-p.y)-(t.y-q.y)) < 1e-6
                else { return nil }
            }
        }
        // Recheck actual cardinal contacts from the recorded sparse runs. The
        // generator's abbreviated contact witnesses may omit the rooted parent;
        // exact RLE adjacency recovers it without adding any foreground pixels.
        var contacts: [Int:[Int:Int]] = [:]
        for (i,id) in membership {
            let adjacent = [i%width > 0 ? i-1 : -1, i%width+1 < width ? i+1 : -1,
                            i >= width ? i-width : -1, i+width]
            for j in adjacent where j >= 0 {
                if let other = membership[j], other != id {
                    contacts[id,default:[:]][other,default:0] += 1
                }
            }
        }
        let roots = supports.filter {$0.association == "actual-private-GG-contrasted-root" && $0.anchors >= 2}
        guard !roots.isEmpty else { return nil }
        let rootRF = roots.reduce(into:Set<Int>()) { $0.formUnion($1.rf) }
        var reached = Set(roots.map(\.id)), associationWitnesses: [[String:Any]] = []
        for s in supports where s.association == "detached-real-root-RLE-and-common-RF-cue" {
            guard s.rootHits >= 2, !s.rf.intersection(rootRF).isEmpty else { return nil }
            reached.insert(s.id)
            associationWitnesses.append(["componentID":s.id,"kind":"independent-root-RLE-and-common-RF",
                "rootDetectorHits":s.rootHits,"commonRFQueries":Array(s.rf.intersection(rootRF)).sorted()])
        }
        for _ in 0..<2 {
            var added = Set<Int>()
            for s in supports where !reached.contains(s.id) && s.association == "observed-cardinal-contour-contact" {
                if s.peerHits >= 2 && s.rootHits == 0 { continue }
                if let parent = reached.sorted().first(where:{(contacts[$0]?[s.id] ?? 0) >= 3}) {
                    added.insert(s.id)
                    associationWitnesses.append(["componentID":s.id,"kind":"exact-source-run-cardinal-contact",
                        "parentComponentID":parent,"actualContactEdges":contacts[parent]![s.id]!])
                }
            }
            if added.isEmpty { break }; reached.formUnion(added)
        }
        guard reached == Set(supports.map(\.id)) else { return nil }
        let totalAnchors = roots.reduce(0) {$0+$1.anchors}
        let agreeingAnchors = roots.filter {$0.rootHits >= 2 && !$0.rf.intersection(rootRF).isEmpty}
            .reduce(0) {$0+$1.anchors}
        guard totalAnchors > 0 else { return nil }
        let agreement = Double(agreeingAnchors)/Double(totalAnchors)
        guard agreement >= 0.6 else { return nil }
        let oldA = actualOld.map(projection).map(\.y)
        let oldA0 = oldA.min()!, oldA1 = oldA.max()!, oldSpan = oldA1-oldA0
        guard oldSpan > 0 else { return nil }
        var rows = Set<Int>(), rootA0 = CGFloat.infinity, rootA1 = -CGFloat.infinity
        for s in roots {
            for i in pixels[s.id] ?? [] {
                let a = projection(world(i)).y
                rootA0 = min(rootA0,a); rootA1 = max(rootA1,a)
                rows.insert(Int(floor((a-oldA0)/max(1,nativeW*0.5))))
            }
        }
        guard rows.count >= 2, rootA1-rootA0 >= min(nativeW*0.75,oldSpan*0.35) else { return nil }
        let turns = (0..<4).map { i -> CGFloat in
            let a=actualOld[i],b=actualOld[(i+1)%4],c=actualOld[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({$0 > 1e-8}) || turns.allSatisfy({$0 < -1e-8}) else { return nil }
        let ccw = turns[0] > 0
        var normals: [CGPoint] = [], oldPlanes: [CGFloat] = []
        for edge in 0..<4 {
            let a=actualOld[edge],b=actualOld[(edge+1)%4],dx=b.x-a.x,dy=b.y-a.y,len=hypot(dx,dy)
            let n=ccw ? CGPoint(x:dy/len,y:-dx/len) : CGPoint(x:-dy/len,y:dx/len)
            normals.append(n);oldPlanes.append(n.x*a.x+n.y*a.y)
        }
        var extents=[CGFloat](repeating:-CGFloat.infinity,count:4)
        for i in membership.keys {
            let p=world(i)
            for edge in 0..<4 {
                let n=normals[edge],z=n.x*p.x+n.y*p.y+(abs(n.x)+abs(n.y))*0.5
                extents[edge]=max(extents[edge],z)
            }
        }
        let closure = supports.reduce(0.0) {$0+min(1,Double($1.contrast.count)/4)}/Double(supports.count)
        let repetition = min(1,Double(rows.count)/4)
        let epsilon = max(1e-5,nativeW*1e-6)
        var best: (index:Int,score:Double,receipt:[String:Any])?
        for (index,proposal) in output.proposals.enumerated() {
            let r=proposal.receipt,q=proposal.polygon
            guard r["family"] as? String == "repair402-peer-separation",q.count == 4,
                  q.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  let recordedOld=r["actualOld"] as? [[Double]],recordedOld.count == 4,
                  zip(recordedOld,actualOld).allSatisfy({ pair in
                      pair.0.count == 2 && abs(pair.0[0]-Double(pair.1.x)) < Double(epsilon) &&
                          abs(pair.0[1]-Double(pair.1.y)) < Double(epsilon)
                  }),
                  let ids=r["actualSupportComponentIDs"] as? [Int],Set(ids) == reached,
                  integer(r["newlyExcludedOriginalGGBodyPixels"]) == 0,
                  integer(r["newlyExcludedActualFootprintPixels"]) == 0,
                  integer(r["newlyExcludedOriginalNativeCellCenters"]) == 0,
                  let changes=r["signedEdgePlaneChanges"] as? [Double],changes.count == 4,
                  let edgeWitnesses=r["actualEdgePixelCellSupport"] as? [[String:Any]],edgeWitnesses.count == 4
            else { continue }
            var changed = 0, slack = CGFloat(0), valid = true
            for edge in 0..<4 {
                let n=normals[edge],a=q[edge],b=q[(edge+1)%4]
                let plane=n.x*a.x+n.y*a.y
                guard abs(n.x*b.x+n.y*b.y-plane) <= epsilon,
                      changes[edge].isFinite,
                      abs(plane-oldPlanes[edge]-CGFloat(changes[edge])) <= epsilon,
                      plane+epsilon >= extents[edge],
                      let i=integer(edgeWitnesses[edge]["actualLocalPixelIndex"]),membership[i] != nil,
                      let p=point(edgeWitnesses[edge]["center"]),hypot(world(i).x-p.x,world(i).y-p.y) < epsilon,
                      abs(n.x*p.x+n.y*p.y+(abs(n.x)+abs(n.y))*0.5-extents[edge]) <= epsilon
                else {valid=false;break}
                slack += max(0,plane-extents[edge])/nativeW
                if abs(changes[edge]) > 0.25 {changed += 1}
            }
            guard valid,changed > 0,membership.keys.allSatisfy({K.contains(q,world($0))}) else {continue}
            let fit=1/(1+Double(slack)/4)
            let boundary=min(1,Double(changed)/2)
            let score=min(1,max(0,0.28*agreement+0.22*closure+0.20*fit+0.15*repetition+0.15*boundary))
            guard score >= 0.78 else {continue}
            let receipt:[String:Any] = ["family":"repair402-peer-source-choice","proposalIndex":index,
                "proposalSuffix":proposal.suffix,"normalizedNominationScore":score,
                "scoreMeaning":"source-evidence nomination strength, not accuracy or admission probability",
                "scoreComponents":["anchorWeightedRootRLEAndRFAgreement":agreement,
                    "observedStableContrastClosure":closure,"sourceCellExtentFit":fit,
                    "rootAlongRepetition":repetition,"supportedChangedEdges":boundary],
                "scoreWeights":[0.28,0.22,0.20,0.15,0.15],"minimumNominationScore":0.78,
                "sourceSupportComponentIDs":supports.map(\.id).sorted(),
                "recordedSourcePixelCellsEnclosed":membership.count,"rootAnchorPixels":totalAnchors,
                "rootAlongBins":rows.count,"associationEvidence":associationWitnesses,
                "originalGGFootprintAndNativeCenterLossCounts":[0,0,0],
                "closureScope":"finite nominated original RGB CCs with recorded inside-outside-stable contrast triples",
                "sourceCompletenessInvented":false,"allForegroundPreservedClaimed":false,
                "detachedAssociationProven":false,"foreignPeerSemanticsResolved":false,
                "otherClippedComponentsUnresolved":output.receipt["clippedComponentsUnresolved"] ?? 0,
                "nativeAllGuardsStillRequired":true,"admissionGranted":false,
                "erasureAuthority":"none","runtimePolicyAutomaticallyChanged":false]
            // Deterministic ties use menu order, never an ID or GT lookup.
            if best == nil || score > best!.score+1e-12 {best=(index,score,receipt)}
        }
        return best
    }
}
