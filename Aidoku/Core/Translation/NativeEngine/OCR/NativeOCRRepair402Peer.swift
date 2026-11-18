import Foundation
import CoreGraphics

// Source-only nominations. Neither a contact path nor a detector vote grants
// ownership or exemption from a native guard. No global image or GT is read.
enum NativeOCRRepair402Peer {
    private typealias K = NativeOCRSharedBoundary396
    private struct Component {
        var pixels: [Int]
        var anchors: Int
        var clipped: Bool
        var contrast: [[Int]]
        var perimeter: Int
        var normalLow: CGFloat
        var normalHigh: CGFloat
        var alongLow: CGFloat
        var alongHigh: CGFloat
    }

    static func generate(actualOld old: [CGPoint], basis f: NativeOCRSharedBoundary396.Basis,
                         nativeW: CGFloat, evidence e: NativeOCRSharedBoundary396.Evidence)
        -> NativeOCRSharedBoundary396.Output {
        let family = "repair402-peer-separation"
        func none(_ reason: String) -> K.Output {
            .init(proposals: [], receipt: ["family": family, "status": reason,
                 "admissionGranted": false, "ownershipChanged": false])
        }
        let r = e.rgba, w = r.width, h = r.height
        guard w > 2, h > 2, w <= 600_000 / h, r.bytesPerRow >= w * 4,
              h <= Int.max / r.bytesPerRow, r.bytes.count == h * r.bytesPerRow,
              e.body.count == w * h, old.count == 4,
              old.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
              r.origin.x.isFinite, r.origin.y.isFinite, f.origin.x.isFinite, f.origin.y.isFinite,
              nativeW.isFinite, nativeW > 0, nativeW < 100_000,
              abs(hypot(f.normal.x, f.normal.y) - 1) < 1e-6,
              abs(hypot(f.along.x, f.along.y) - 1) < 1e-6,
              abs(f.normal.x * f.along.x + f.normal.y * f.along.y) < 1e-6,
              e.detectors.count <= 64, e.rf.count <= 160, e.nativeCellCenters.count <= 600_000,
              e.nativeCellCenters.allSatisfy({ $0.x.isFinite && $0.y.isFinite })
        else { return none("invalid-bounded-evidence") }
        let cross = (0..<4).map { i -> CGFloat in
            let a = old[i], b = old[(i+1)%4], c = old[(i+2)%4]
            return (b.x-a.x)*(c.y-b.y) - (b.y-a.y)*(c.x-b.x)
        }
        guard cross.allSatisfy({ $0 > 1e-8 }) || cross.allSatisfy({ $0 < -1e-8 })
        else { return none("invalid-convex-prior") }
        let ccw = cross[0] > 0
        func point(_ i: Int) -> CGPoint {
            CGPoint(x: r.origin.x + CGFloat(i % w) + 0.5,
                    y: r.origin.y + CGFloat(i / w) + 0.5)
        }
        func projection(_ p: CGPoint) -> CGPoint {
            let x = p.x-f.origin.x, y = p.y-f.origin.y
            return CGPoint(x: x*f.normal.x+y*f.normal.y, y: x*f.along.x+y*f.along.y)
        }
        func rgb(_ i: Int) -> SIMD3<Int> {
            let k = (i/w)*r.bytesPerRow + (i%w)*4
            return SIMD3(Int(r.bytes[k]), Int(r.bytes[k+1]), Int(r.bytes[k+2]))
        }
        func distance(_ a: SIMD3<Int>, _ b: SIMD3<Int>) -> Int {
            max(abs(a.x-b.x), abs(a.y-b.y), abs(a.z-b.z))
        }
        func index(_ x: Int, _ y: Int) -> Int? {
            x >= 0 && x < w && y >= 0 && y < h ? y*w+x : nil
        }
        func witness(_ i: Int) -> [String: Any] {
            let p = point(i), c = rgb(i)
            return ["actualLocalPixelIndex": i, "center": [Double(p.x), Double(p.y)],
                    "RGB": [c.x,c.y,c.z], "rootGGBody": e.body[i] != 0,
                    "actualNativeFootprint": e.privateAt(p), "ownershipClaimed": false]
        }
        func runs(_ pixels: [Int]) -> [[Int]] {
            var result: [[Int]] = []
            for i in pixels.sorted() {
                if let last = result.last, last[0] == i/w, last[1]+last[2] == i%w {
                    result[result.count-1][2] += 1
                } else { result.append([i/w,i%w,1]) }
            }
            return result
        }
        let nr = (abs(f.normal.x)+abs(f.normal.y))*0.5
        let ar = (abs(f.along.x)+abs(f.along.y))*0.5
        let oldP = old.map(projection)
        let oldA0 = oldP.map(\.y).min()!, oldA1 = oldP.map(\.y).max()!
        var labels = [Int](repeating: -1, count: w*h)
        for i in labels.indices where r.bytes[(i/w)*r.bytesPerRow+(i%w)*4+3] != 255 {
            labels[i] = -2
        }
        let eight = [(-1,-1),(0,-1),(1,-1),(-1,0),(1,0),(-1,1),(0,1),(1,1)]
        let four = [(-1,0),(1,0),(0,-1),(0,1)]
        var components: [Component] = []
        // All colours are segmented, including a differently coloured detached
        // terminal. The reference bound prevents a gradient flood through ink.
        for seed in labels.indices where labels[seed] == -1 {
            guard components.count < 20_000 else { return none("component-budget-exceeded") }
            let id = components.count, reference = rgb(seed)
            var queue = [seed], cursor = 0, anchors = 0
            labels[seed] = id
            while cursor < queue.count {
                let i = queue[cursor]; cursor += 1
                let p = point(i)
                if e.body[i] != 0 && e.privateAt(p) && K.contains(old,p) { anchors += 1 }
                for (dx,dy) in eight {
                    guard let j = index(i%w+dx,i/w+dy), labels[j] == -1,
                          distance(rgb(j),reference) <= 32, distance(rgb(j),rgb(i)) <= 24
                    else { continue }
                    labels[j] = id; queue.append(j)
                }
            }
            var n0 = CGFloat.infinity, n1 = -CGFloat.infinity
            var a0 = CGFloat.infinity, a1 = -CGFloat.infinity
            var clipped = false, perimeter = 0, contrast: [[Int]] = []
            for i in queue {
                let p = projection(point(i))
                n0 = min(n0,p.x-nr); n1 = max(n1,p.x+nr)
                a0 = min(a0,p.y-ar); a1 = max(a1,p.y+ar)
                for (dx,dy) in four {
                    guard let j = index(i%w+dx,i/w+dy), labels[j] != -2 else {
                        clipped = true; perimeter += 1; continue
                    }
                    if labels[j] == id { continue }
                    perimeter += 1
                    if contrast.count < 16, let k = index(i%w+2*dx,i/w+2*dy), labels[k] != -2,
                       distance(rgb(i),rgb(j)) >= 40, distance(rgb(j),rgb(k)) <= 16 {
                        contrast.append([i,j,k])
                    }
                }
            }
            components.append(Component(pixels: queue, anchors: anchors, clipped: clipped,
                contrast: contrast, perimeter: perimeter, normalLow: n0, normalHigh: n1,
                alongLow: a0, alongHigh: a1))
        }
        // Unlike 396, do not abort because antialiased art produced >256 roots.
        // Every surviving compact root is retained, not the first N components.
        let roots = Set(components.indices.filter { id in
            let c = components[id]
            return c.anchors >= 2 && !c.clipped && c.contrast.count >= 2 &&
                c.normalHigh-c.normalLow <= nativeW*2 &&
                c.alongHigh-c.alongLow <= max(nativeW*3, oldA1-oldA0+nativeW)
        })
        guard !roots.isEmpty else { return none("no-closed-contrasted-private-GG-root") }
        let low = roots.map { components[$0].normalLow }.min()!
        let high = roots.map { components[$0].normalHigh }.max()!
        let rf = e.rf.filter { v in
            v.confidence.isFinite && v.confidence >= 0.6 && v.bounds.count == 4 &&
                v.bounds.allSatisfy(\.isFinite) && v.bounds[0] <= v.bounds[2] && v.bounds[1] <= v.bounds[3]
        }
        var rootQueries = Set<Int>()
        for id in roots.sorted() {
            for i in components[id].pixels where e.body[i] != 0 && e.privateAt(point(i)) {
                for v in rf where v.contains(point(i)) { rootQueries.insert(v.query) }
            }
        }
        // Exact sparse cell tests at real CC pixels; RF bounds are only a cue.
        // Samples never prove negative membership or exclusive peer ownership.
        var rootVotes: [Int:Int] = [:], peerVotes: [Int:Int] = [:]
        var rfVotes: [Int:Set<Int>] = [:], tested: [Int:[Int]] = [:]
        var detectorQueries = 0
        for id in components.indices {
            let c = components[id]
            guard !c.clipped, c.pixels.count >= 2, c.contrast.count >= 2,
                  c.normalHigh-c.normalLow <= nativeW*2,
                  c.alongHigh-c.alongLow <= max(nativeW*3,oldA1-oldA0+nativeW),
                  c.normalHigh >= low-nativeW*0.5, c.normalLow <= high+nativeW*0.5,
                  c.alongHigh >= oldA0-nativeW, c.alongLow <= oldA1+nativeW else { continue }
            let count = min(16,c.pixels.count)
            for k in 0..<count {
                let i = c.pixels[k*(c.pixels.count-1)/(count-1)], p = point(i)
                tested[id,default:[]].append(i)
                var root = false, peer = false
                for d in e.detectors {
                    guard detectorQueries < 2_000_000 else { return none("detector-query-budget-exceeded") }
                    detectorQueries += 1
                    if d.cells.contains(p) { if d.nativeRoot { root = true } else { peer = true } }
                }
                if root { rootVotes[id,default:0] += 1 }
                if peer { peerVotes[id,default:0] += 1 }
                for v in rf where v.contains(p) { rfVotes[id,default:[]].insert(v.query) }
            }
        }
        // Cardinal contacts are actual adjacent source pixels, not hull/ray fill.
        var contacts: [Int:[Int:Int]] = [:], paths: [Int:[[Int]]] = [:]
        for i in labels.indices where labels[i] >= 0 {
            let parent = labels[i]
            guard !components[parent].clipped else { continue }
            for (dx,dy) in four {
                guard let j = index(i%w+dx,i/w+dy), labels[j] >= 0, labels[j] != parent else { continue }
                let id = labels[j], c = components[id]
                guard !c.clipped, c.contrast.count >= 2, c.perimeter > 0,
                      c.normalHigh-c.normalLow <= nativeW*2,
                      CGFloat(c.pixels.count)/CGFloat(c.perimeter) <= max(2,nativeW*0.3)
                else { continue }
                contacts[parent,default:[:]][id,default:0] += 1
                if paths[id,default:[]].count < 8 { paths[id,default:[]].append([i,j]) }
            }
        }
        var selected = roots
        var association: [Int:String] = [:]
        for id in roots { association[id] = "actual-private-GG-contrasted-root" }
        // No same-palette condition: independent root RLE + common RF may
        // nominate a detached quote, dot or terminal in a different colour.
        for id in tested.keys.sorted() where !roots.contains(id) {
            let c = components[id]
            let overlap = min(high,c.normalHigh)-max(low,c.normalLow)
            if rootVotes[id,default:0] >= 2,
               !(rfVotes[id] ?? []).intersection(rootQueries).isEmpty,
               overlap >= 0, c.alongHigh-c.alongLow <= nativeW*2 {
                selected.insert(id); association[id] = "detached-real-root-RLE-and-common-RF-cue"
            }
        }
        for _ in 0..<2 {
            var added = Set<Int>()
            for parent in selected.sorted() {
                for id in (contacts[parent] ?? [:]).keys.sorted() where !selected.contains(id) {
                    let count = contacts[parent]![id]!, c = components[id]
                    // Peer votes are not erasure permission; this only avoids
                    // acquiring an unanchored separately detected neighbor.
                    let peerOnlySample = peerVotes[id,default:0] >= 2 && rootVotes[id,default:0] == 0
                    if !peerOnlySample, count >= 3,
                       CGFloat(count)/CGFloat(max(1,c.perimeter)) >= 0.04 {
                        added.insert(id); association[id] = "observed-cardinal-contour-contact"
                    }
                }
            }
            if added.isEmpty { break }; selected.formUnion(added)
        }
        var normals: [CGPoint] = [], planes: [CGFloat] = []
        for edge in 0..<4 {
            let a = old[edge], b = old[(edge+1)%4], dx = b.x-a.x, dy = b.y-a.y, len = hypot(dx,dy)
            let n = ccw ? CGPoint(x:dy/len,y:-dx/len) : CGPoint(x:-dy/len,y:dx/len)
            normals.append(n); planes.append(n.x*a.x+n.y*a.y)
        }
        var targets = [CGFloat](repeating: -CGFloat.infinity,count:4)
        var extrema = [Int](repeating: -1,count:4)
        for id in selected.sorted() {
            for i in components[id].pixels {
                let p = point(i)
                for edge in 0..<4 {
                    let n = normals[edge]
                    let z = n.x*p.x+n.y*p.y+(abs(n.x)+abs(n.y))*0.5
                    if z > targets[edge] { targets[edge] = z; extrema[edge] = i }
                }
            }
        }
        let support: [[String:Any]] = selected.sorted().map { id in
            ["componentID": id, "actualLocalRunsYXCount": runs(components[id].pixels),
             "association": association[id] ?? "unresolved", "associationProven": false,
             "rootPrivateGGAnchorPixels": components[id].anchors,
             "testedActualPixels": (tested[id] ?? []).map(witness),
             "sampledRootDetectorHits": rootVotes[id,default:0],
             "sampledPeerDetectorHits": peerVotes[id,default:0],
             "RFQueries": Array(rfVotes[id] ?? []).sorted(),
             "actualCardinalContactWitnesses": (paths[id] ?? []).map { $0.map(witness) },
             "actualStableContrastWitnesses": components[id].contrast.map { $0.map(witness) }]
        }
        var offers: [K.Proposal] = [], seen = Set<String>()
        // Four independent edge moves, paired normal moves, along moves, and
        // their joint correction. Edge identity is derived from the same basis.
        let normalBits = (0..<4).reduce(0) { bits, edge in
            let n = normals[edge]
            return abs(n.x*f.normal.x+n.y*f.normal.y) >= 0.7 ? bits | (1 << edge) : bits
        }
        let masks = [1,2,4,8,normalBits,15 ^ normalBits,15]
        for bits in masks where bits != 0 {
            let proposed = (0..<4).map { bits & (1 << $0) != 0 ? targets[$0] : planes[$0] }
            guard (0..<4).contains(where: { abs(proposed[$0]-planes[$0]) > 0.25 }) else { continue }
            var q: [CGPoint] = []
            for edge in 0..<4 {
                let j = (edge+3)%4, a = normals[j], b = normals[edge]
                let det = a.x*b.y-a.y*b.x
                guard abs(det) > 1e-8 else { break }
                q.append(CGPoint(x:(proposed[j]*b.y-a.y*proposed[edge])/det,
                                 y:(a.x*proposed[edge]-proposed[j]*b.x)/det))
            }
            guard q.count == 4, q.allSatisfy({ $0.x.isFinite && $0.y.isFinite &&
                $0.x >= r.origin.x && $0.x <= r.origin.x+CGFloat(w) &&
                $0.y >= r.origin.y && $0.y <= r.origin.y+CGFloat(h) }) else { continue }
            let turns = (0..<4).map { i -> CGFloat in
                let a=q[i],b=q[(i+1)%4],c=q[(i+2)%4]
                return (b.x-a.x)*(c.y-b.y)-(b.y-a.y)*(c.x-b.x)
            }
            guard ccw ? turns.allSatisfy({$0 > 1e-8}) : turns.allSatisfy({$0 < -1e-8}) else { continue }
            let key = q.map { String(format:"%.7f,%.7f",Double($0.x),Double($0.y)) }.joined(separator:";")
            guard seen.insert(key).inserted else { continue }
            var ggLoss: [Int] = [], privateLoss: [Int] = []
            for i in labels.indices where K.contains(old,point(i)) && !K.contains(q,point(i)) {
                if e.body[i] != 0 { ggLoss.append(i) }
                if e.privateAt(point(i)) { privateLoss.append(i) }
            }
            let nativeLoss = e.nativeCellCenters.filter { K.contains(old,$0) && !K.contains(q,$0) }
            let rec: [String:Any] = ["family":family, "edgeBits":bits,
                "actualOld":old.map { [Double($0.x),Double($0.y)] },
                "originalOldEdgeDirectionsPreserved":true,
                "signedEdgePlaneChanges":(0..<4).map { Double(proposed[$0]-planes[$0]) },
                "actualEdgePixelCellSupport":extrema.map(witness),
                "actualOldEnclosed":old.allSatisfy { K.contains(q,$0) },
                "newlyExcludedOriginalGGBodyPixels":ggLoss.count,
                "GGBodyLossWitnesses":ggLoss.prefix(8).map(witness),
                "newlyExcludedActualFootprintPixels":privateLoss.count,
                "actualFootprintLossWitnesses":privateLoss.prefix(8).map(witness),
                "newlyExcludedOriginalNativeCellCenters":nativeLoss.count,
                "nativeCellLossWitnesses":nativeLoss.prefix(8).map { [Double($0.x),Double($0.y)] },
                "actualSupportComponentIDs":selected.sorted(),
                "sourceSupportReceiptLocation":"output.receipt.sourceSupportComponents",
                "allSourceForegroundPreservedClaimed":false, "erasureAuthority":"none",
                "peerOwnershipInferredFromGeometry":false, "admissionGranted":false,
                "nativeAdmissionSuiteRun":false, "detachedAssociationProven":false]
            offers.append(.init(suffix:"repair402-peer-contact-edges\(bits)", polygon:q, receipt:rec,
                obligations:["actual-native-whole-dense-terminal-GG-and-semantic-admission-required",
                    "replay-every-original-member-footprint-without-mask-mutation",
                    "disappearing-peer-or-background-witness-role-needs-native-confirmation",
                    "detached-quote-diacritic-and-terminal-association-not-proven",
                    "foreign-peer-new-acquisition-and-retained-peer-box-check-required",
                    "source-generator-grants-no-erasure-authority"]))
        }
        return .init(proposals:offers, receipt:["family":family,
            "status":"source-contact-separated-hypotheses", "sourceSupportComponents":support,
            "originalRGBComponents":components.count, "rootComponents":roots.count,
            "selectedComponents":selected.count, "detectorQueries":detectorQueries,
            "clippedComponentsUnresolved":components.filter(\.clipped).count,
            "candidateLimit":8, "candidates":offers.count, "RFIsPixelMask":false,
            "colourEqualityRequiredForDetachedSupport":false, "ownershipChanged":false,
            "absenceOfSampledDetectorVoteProvesAbsence":false,
            "nativeAdmissionSuiteRun":false, "admissionGranted":false])
    }
}
