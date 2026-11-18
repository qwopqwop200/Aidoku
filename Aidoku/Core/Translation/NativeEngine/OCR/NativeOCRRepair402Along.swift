import Foundation
import CoreGraphics

// Source-only nomination. Every component consists exclusively of captured pixels.
// Neither an RF rectangle nor a detector rectangle is rasterized into foreground.
enum NativeOCRRepair402Along {
    typealias K = NativeOCRSharedBoundary396
    private struct Component {
        var pixels: [Int]
        var anchors: Int
        var clipped: Bool
        var contrast: Int
        var n0: CGFloat
        var n1: CGFloat
        var a0: CGFloat
        var a1: CGFloat
        var db: Set<Int> = []
        var rf: Set<Int> = []
    }
    static func generate(actualOld old: [CGPoint], basis f: K.Basis,
                         nativeW mw: CGFloat, evidence e: K.Evidence) -> K.Output {
        func none(_ status: String) -> K.Output {
            .init(proposals: [], receipt: ["family":"repair402-along", "status":status,
                "admissionGranted":false, "GTRead":false])
        }
        let r = e.rgba, w = r.width, h = r.height
        guard w > 2, h > 2, w <= 600_000 / h, r.bytesPerRow >= w * 4,
              h <= Int.max / r.bytesPerRow, r.bytes.count == h * r.bytesPerRow,
              e.body.count == w * h, old.count == 4, mw.isFinite, mw > 0,
              mw < 100_000, old.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              r.origin.x.isFinite, r.origin.y.isFinite, f.origin.x.isFinite, f.origin.y.isFinite,
              abs(hypot(f.normal.x, f.normal.y)-1) < 1e-6,
              abs(hypot(f.along.x, f.along.y)-1) < 1e-6,
              abs(f.normal.x*f.along.x + f.normal.y*f.along.y) < 1e-6,
              e.detectors.count <= 64, e.rf.count <= 160,
              e.nativeCellCenters.count <= 600_000 else { return none("invalid-captured-input") }
        let turns = (0..<4).map { i -> CGFloat in
            let a=old[i], b=old[(i+1)%4], c=old[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
        }
        guard turns.allSatisfy({$0 > 1e-8}) || turns.allSatisfy({$0 < -1e-8}) else {
            return none("invalid-old-convexity")
        }
        let ccw = turns[0] > 0
        var normals: [CGPoint] = [], planes: [CGFloat] = []
        for edge in 0..<4 {
            let a=old[edge], b=old[(edge+1)%4], dx=b.x-a.x, dy=b.y-a.y, length=hypot(dx,dy)
            let n=ccw ? CGPoint(x:dy/length,y:-dx/length) : CGPoint(x:-dy/length,y:dx/length)
            normals.append(n); planes.append(n.x*a.x+n.y*a.y)
        }
        let endEdges = (0..<4).filter { abs(normals[$0].x*f.along.x+normals[$0].y*f.along.y) > 0.8 }
        guard endEdges.count == 2 else { return none("ambiguous-along-end-planes") }
        let head = endEdges.min { normals[$0].x*f.along.x+normals[$0].y*f.along.y < normals[$1].x*f.along.x+normals[$1].y*f.along.y }!
        let tail = endEdges.first { $0 != head }!
        func world(_ i: Int) -> CGPoint { CGPoint(x:r.origin.x+CGFloat(i%w)+0.5,y:r.origin.y+CGFloat(i/w)+0.5) }
        func project(_ p: CGPoint) -> CGPoint {
            let x=p.x-f.origin.x, y=p.y-f.origin.y
            return CGPoint(x:x*f.normal.x+y*f.normal.y,y:x*f.along.x+y*f.along.y)
        }
        func rgb(_ i: Int) -> SIMD3<Int> {
            let k=(i/w)*r.bytesPerRow+(i%w)*4
            return SIMD3(Int(r.bytes[k]),Int(r.bytes[k+1]),Int(r.bytes[k+2]))
        }
        func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
            max(abs(a.x-b.x),abs(a.y-b.y),abs(a.z-b.z))
        }
        func index(_ x: Int, _ y: Int) -> Int? { x >= 0 && x < w && y >= 0 && y < h ? y*w+x : nil }
        let oldP=old.map(project), n0=oldP.map(\.x).min()!, n1=oldP.map(\.x).max()!
        let nr=(abs(f.normal.x)+abs(f.normal.y))*0.5, ar=(abs(f.along.x)+abs(f.along.y))*0.5
        let card=[(-1,0),(1,0),(0,-1),(0,1)]
        let dirs=[(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)]
        var labels=[Int](repeating:-1,count:w*h), components:[Component]=[]
        for i in labels.indices where r.bytes[(i/w)*r.bytesPerRow+(i%w)*4+3] != 255 { labels[i] = -2 }
        // Fixed-seed colour bound prevents slowly varying background flood drift.
        for seed in labels.indices where labels[seed] == -1 {
            guard components.count < 20_000 else { return none("component-budget") }
            let id=components.count, reference=rgb(seed)
            var queue=[seed], cursor=0, anchors=0, clipped=false, contrast=0
            var loN=CGFloat.infinity, hiN = -CGFloat.infinity, loA=CGFloat.infinity, hiA = -CGFloat.infinity
            labels[seed]=id
            while cursor < queue.count {
                let i=queue[cursor]; cursor += 1
                let p=world(i), v=project(p)
                loN=min(loN,v.x-nr); hiN=max(hiN,v.x+nr); loA=min(loA,v.y-ar); hiA=max(hiA,v.y+ar)
                if e.body[i] != 0 && e.privateAt(p) && K.contains(old,p) { anchors += 1 }
                for (dx,dy) in dirs {
                    guard let j=index(i%w+dx,i/w+dy) else { clipped=true; continue }
                    if labels[j] == -2 { clipped=true; continue }
                    if labels[j] == -1 && distance(rgb(j),reference) <= 32 && distance(rgb(i),rgb(j)) <= 24 {
                        labels[j]=id; queue.append(j)
                    }
                }
                for (dx,dy) in card {
                    if let j=index(i%w+dx,i/w+dy), let k=index(i%w+2*dx,i/w+2*dy),
                       labels[j] != -2, labels[k] != -2,
                       distance(rgb(i),rgb(j)) >= 40, distance(rgb(j),rgb(k)) <= 16 { contrast += 1 }
                }
            }
            components.append(Component(pixels:queue,anchors:anchors,clipped:clipped,contrast:contrast,n0:loN,n1:hiN,a0:loA,a1:hiA))
        }
        func finiteGlyph(_ c: Component) -> Bool {
            !c.clipped && c.pixels.count >= 2 && c.pixels.count <= 200_000 &&
                c.n1-c.n0 <= mw*2 && c.a1-c.a0 <= mw*3 && c.contrast >= 2
        }
        let roots=components.indices.filter { finiteGlyph(components[$0]) && components[$0].anchors >= 2 }
        guard !roots.isEmpty else { return none("no-finite-contrasting-root-body-components") }
        guard roots.count <= 512 else { return none("root-budget") }
        // Evidence queries sample real CC pixels, never a bounding rectangle.
        let potential=components.indices.filter { id in
            let c=components[id]
            return finiteGlyph(c) && c.n1 >= n0-mw*0.2 && c.n0 <= n1+mw*0.2
        }
        guard potential.count <= 2048 else { return none("association-query-budget") }
        var queryCount=0
        for id in potential {
            let pixels=components[id].pixels, count=min(12,pixels.count)
            for k in 0..<count {
                let p=world(pixels[k*(pixels.count-1)/max(1,count-1)])
                for (ordinal,d) in e.detectors.enumerated() {
                    queryCount += 1
                    guard queryCount <= 2_000_000 else { return none("detector-query-budget") }
                    if d.cells.contains(p) { components[id].db.insert(ordinal) }
                }
                for (ordinal,v) in e.rf.enumerated() where v.bounds.count == 4 &&
                    v.bounds.allSatisfy({$0.isFinite}) && v.confidence.isFinite && v.confidence >= 0.4 && v.contains(p) {
                    components[id].rf.insert(ordinal)
                }
            }
        }
        let rootRF=roots.reduce(into:Set<Int>()) { $0.formUnion(components[$1].rf) }
        let rootDB=roots.reduce(into:Set<Int>()) { result,id in
            result.formUnion(components[id].db.filter { e.detectors[$0].nativeRoot })
        }
        var selected=Set(roots), detached:[[String:Any]]=[]
        // Independently supported detached accents/quotes/dots may have ANY colour.
        // Association remains a nomination, not private ownership or erasure authority.
        for id in potential where !selected.contains(id) {
            let c=components[id], db=c.db.intersection(rootDB), rf=c.rf.intersection(rootRF)
            guard !db.isEmpty && !rf.isEmpty else { continue }
            let near=roots.contains { other in
                let p=components[other], gap=max(0,max(c.a0-p.a1,p.a0-c.a1))
                return gap <= mw*1.25 && abs((c.n0+c.n1-p.n0-p.n1)*0.5) <= mw*0.7
            }
            if near {
                selected.insert(id)
                detached.append(["componentID":id,"actualRootDetectorOrdinals":db.sorted().map { e.detectors[$0].ordinal },
                    "RFQueryIDs":rf.sorted().map {e.rf[$0].query},"colourMatchRequired":false,"associationProven":false])
            }
        }
        // Actual contacts nominate contrasting outer rims missed by winning-fill rays.
        var contactCounts=[Int:[Int:Int]](), contacts=0
        for id in selected.sorted() {
            for i in components[id].pixels {
                for (dx,dy) in card {
                    guard let j=index(i%w+dx,i/w+dy), labels[j] >= 0, labels[j] != id else { continue }
                    let other=labels[j], c=components[other]
                    guard !c.clipped, c.pixels.count <= 200_000, c.n1-c.n0 <= mw*2,
                          c.a1-c.a0 <= max(mw*3,components[id].a1-components[id].a0+mw),
                          distance(rgb(i),rgb(j)) >= 24 else { continue }
                    contacts += 1
                    guard contacts <= 1_000_000 else { return none("contact-query-budget") }
                    contactCounts[id,default:[:]][other,default:0] += 1
                }
            }
        }
        var rim=selected
        for id in selected.sorted() {
            for other in (contactCounts[id] ?? [:]).keys.sorted() where contactCounts[id]![other]! >= 2 {
                rim.insert(other)
            }
        }
        func witness(_ i: Int) -> [String:Any] {
            let p=world(i), c=rgb(i)
            return ["actualLocalPixelIndex":i,"center":[Double(p.x),Double(p.y)],"RGB":[c.x,c.y,c.z],
                "rootGGBody":e.body[i] != 0,"nativeRootCell":e.privateAt(p),"ownershipClaimed":false]
        }
        func runs(_ pixels: [Int]) -> [[Int]] {
            var out:[[Int]]=[]
            for i in pixels.sorted() {
                if let last=out.last, last[0]==i/w && last[1]+last[2]==i%w { out[out.count-1][2] += 1 }
                else { out.append([i/w,i%w,1]) }
            }
            return out
        }
        var offers:[K.Proposal]=[], seen=Set<String>()
        // Rim variant comes first; fill variant is separately labelled and must
        // survive native whole/dense/terminal guards, especially on multicolour ends.
        for (name,ids) in [("contact-rim",rim),("root-detached-fill",selected)] {
            let pixels=ids.sorted().flatMap { components[$0].pixels }
            var targets=planes, extrema=[Int:Int]()
            for edge in endEdges {
                let n=normals[edge], radius=(abs(n.x)+abs(n.y))*0.5
                var value = -CGFloat.infinity, extreme = -1
                for i in pixels {
                    let p=world(i), v=n.x*p.x+n.y*p.y+radius
                    if v > value { value=v; extreme=i }
                }
                targets[edge]=min(planes[edge],value); extrema[edge]=extreme
            }
            // Each end moves independently: a poor head estimate must not block tail repair.
            for edges in [[head],[tail],[head,tail]] {
                var proposed=planes
                for edge in edges { proposed[edge]=targets[edge] }
                guard edges.contains(where: {planes[$0]-proposed[$0] > 0.5}) else { continue }
                var q:[CGPoint]=[]
                for i in 0..<4 {
                    let j=(i+3)%4, a=normals[j], b=normals[i], u=proposed[j], v=proposed[i]
                    let determinant=a.x*b.y-a.y*b.x
                    guard abs(determinant) > 1e-8 else { break }
                    q.append(CGPoint(x:(u*b.y-a.y*v)/determinant,y:(a.x*v-u*b.x)/determinant))
                }
                guard q.count == 4, q.allSatisfy({$0.x.isFinite && $0.y.isFinite &&
                    $0.x >= r.origin.x && $0.x <= r.origin.x+CGFloat(w) &&
                    $0.y >= r.origin.y && $0.y <= r.origin.y+CGFloat(h) && K.contains(old,$0)}) else { continue }
                let cross=(0..<4).map { i -> CGFloat in
                    let a=q[i], b=q[(i+1)%4], c=q[(i+2)%4]
                    return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
                }
                guard ccw ? cross.allSatisfy({$0 > 1e-8}) : cross.allSatisfy({$0 < -1e-8}) else { continue }
                let key=q.map {String(format:"%.7f,%.7f",Double($0.x),Double($0.y))}.joined(separator:";")
                guard seen.insert(key).inserted else { continue }
                let bodyLoss=(0..<w*h).filter {e.body[$0] != 0 && K.contains(old,world($0)) && !K.contains(q,world($0))}
                let cellLoss=e.nativeCellCenters.filter {K.contains(old,$0) && !K.contains(q,$0)}
                let selectedLoss=pixels.filter {K.contains(old,world($0)) && !K.contains(q,world($0))}
                let receipt:[String:Any]=[
                    "family":"repair402-along","supportMode":name,"actualOld":old.map {[Double($0.x),Double($0.y)]},
                    "movedOldEdgeIndices":edges,"oldEdgeDirectionsPreserved":true,"normalEdgesUnchanged":true,
                    "signedEdgePlaneChanges":(0..<4).map {Double(proposed[$0]-planes[$0])},
                    "actualOldEnclosed":old.allSatisfy {K.contains(q,$0)},"candidateInsideActualOld":q.allSatisfy {K.contains(old,$0)},
                    "sourceSupportComponentIDs":ids.sorted(),"sourceSupportActualPixelRuns":runs(pixels),
                    "edgeActualPixelWitnesses":edges.compactMap {extrema[$0]}.filter {$0 >= 0}.map(witness),
                    "rootAnchoredComponentIDs":roots,"RFDBDetachedSupport":detached,
                    "contactPairs":selected.sorted().flatMap { id in (contactCounts[id] ?? [:]).keys.sorted().map {
                        ["from":id,"to":$0,"actualCardinalContacts":contactCounts[id]![$0]!] } },
                    "newlyExcludedOriginalGGBodyPixels":bodyLoss.count,"GGBodyLossWitnesses":bodyLoss.prefix(8).map(witness),
                    "newlyExcludedActualNativeCellCenters":cellLoss.count,
                    "nativeCellLossWitnesses":cellLoss.prefix(8).map {[Double($0.x),Double($0.y)]},
                    "selectedSupportPixelLossCount":selectedLoss.count,
                    "unselectedComponentsIntersectingOld":components.indices.filter { !ids.contains($0) && components[$0].pixels.contains {K.contains(old,world($0))} },
                    "stableBackgroundStripCertified":false,"componentContrastIsOwnership":false,
                    "completeForegroundPreservationClaimed":false,"detachedAssociationProven":false,
                    "existingOldOmissionsRepaired":false,"arbitraryPaddingUsed":false,
                    "geometryOrPaletteUsedAsForegroundMask":false,"admissionGranted":false,"GTRead":false]
                offers.append(.init(suffix:"repair402-along-\(name)-\(edges.map(String.init).joined(separator:"-"))",
                    polygon:q,receipt:receipt,obligations:[
                        "actual original-member whole/dense/terminal admission; never bypass existing vetoes",
                        "resolve excluded GG/private pixels and detached same-line glyph/quote/accent association",
                        "check exterior background and foreign-peer/semantic acquisition on actual source",
                        "parent native mandatory suite and physical endpoint completeness; no admission claimed"]))
                if offers.count == 8 { break }
            }
        }
        return .init(proposals:offers,receipt:["family":"repair402-along","status":offers.isEmpty ? "no-supported-inward-end-change":"raw-proposals-only",
            "proposalCount":offers.count,"componentCount":components.count,"actualRootComponents":roots.count,
            "actualDetectorCellQueries":queryCount,"admissionGranted":false,"GTRead":false,
            "noRayClosureRequirement":true,"oldNativeFootprintUnmodified":true])
    }
}
