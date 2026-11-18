import CoreGraphics
import Foundation

extension NativeMainRemovalSourceFactory.NativeCurrentMaskCaller {
    /// Same mask/protection contract and defaults as `prepare`; only owner raster lifetime changes.
    /// Keep the complete target pass, eligibility pass, neutral pass, then normal pass separate.
    /// Visit absolute-coordinate spans and populate existing owner-crop arrays.
    /// Rare larger polygons retain the established one-raster fallback.
    static func prepareStreamingOwners(
        source s: Source, probability p: Probability, evidence e: Evidence,
        contrast: Double = 32, radiusScale: Double = 1, roleSupport: Bool = true,
        protectForeignTargets: Bool = false, foreignTargetHaloScale: Double = 0,
        foreignHaloExcludesSelf: Bool = false
    ) throws -> Result {
        typealias Factory = NativeMainRemovalSourceFactory
        let w = s.width, h = s.height
        guard w > 0, h > 0, w <= 16_777_216 / h, s.rgb.count == w*h*3, e.boundary.count == w*h,
              !s.revision.isEmpty, !p.revision.isEmpty, !e.revision.isEmpty,
              e.owners.allSatisfy({
                  $0.fontPixels.isFinite && $0.fontPixels > 0 && $0.fontPixels < Double(max(w, h))*4 &&
                  $0.polygon.count >= 3 && $0.polygon.allSatisfy({
                      $0.x.isFinite && $0.y.isFinite && $0.x >= 0 && $0.y >= 0 &&
                      $0.x < CGFloat(w) && $0.y < CGFloat(h)
                  }) && convex($0.polygon)
              }),
              e.pending.allSatisfy({
                  !$0.isEmpty && $0.minX >= 0 && $0.minY >= 0 &&
                  $0.maxX <= CGFloat(w) && $0.maxY <= CGFloat(h)
              }) else { throw Failure.invalidEvidence }
        guard s.revision == p.sourceRevision, s.revision == e.sourceRevision else { throw Failure.staleSource }
        let prob = try restore(p, width: w, height: h)
        let q = prob.map { UInt8(min(255, max(0, Int($0*255)))) }
        var target = [UInt8](repeating: 0, count: w*h), guarded = target, preserved = target
        var rasterizations = 0
        for o in e.owners {
            rasterizations += 1
            forEachOwnedRun(o.polygon, width: w, height: h) { y, lower, upper in
                let row = y * w
                if o.translated {
                    for x in lower...upper { target[row + x] = 1 }
                } else {
                    for x in lower...upper { guarded[row + x] = 1 }
                }
            }
        }
        var eligibility = [[String: Any]]()
        for o in e.owners where !o.translated {
            rasterizations += 1
            var lo = 255, hi = 0, support = 0, conflicts = 0
            forEachOwnedRun(o.polygon, width: w, height: h) { y, lower, upper in
                for x in lower...upper {
                    let k = y * w + x
                    for c in 0..<3 { lo = min(lo, Int(s.rgb[k*3+c])); hi = max(hi, Int(s.rgb[k*3+c])) }
                    if q[k] >= 51 { support += 1 }
                    if target[k] != 0 && q[k] >= 128 { conflicts += 1 }
                }
            }
            let eligible = hi-lo >= 48 && support >= 3 && conflicts == 0
            eligibility.append(["owner": o.id, "eligible": eligible, "targetConflicts": conflicts])
            if eligible {
                rasterizations += 1
                forEachOwnedRun(o.polygon, width: w, height: h) { y, lower, upper in
                    let row = y * w
                    for x in lower...upper { preserved[row + x] = 1 }
                }
            }
        }
        for r in e.pending { for y in Int(r.minY)..<Int(r.maxY) { for x in Int(r.minX)..<Int(r.maxX) {
            guarded[y*w+x] = 1; preserved[y*w+x] = 1
        } } }
        let initial = try Factory.NativeSourceBaseMask.extract(
            source: s, owners: e.owners, contrast: contrast, radiusScale: radiusScale, roleSupport: roleSupport)
        let chroma = try Factory.NativeChromaticMaskCompletion.complete(
            rgb: s.rgb, width: w, height: h, base: initial.mask, protection: guarded,
            owners: e.owners.filter { $0.translated }.map {
                .init(id: $0.id, polygon: $0.polygon, fontPixels: $0.fontPixels)
            })
        let union = try Factory.NativeFinalProtectedUnion.apply(
            width: w, height: h, rgb: s.rgb, boundary: e.boundary,
            preserved: preserved, target: target, probability: q, contributions: [chroma.mask])
        var neutralTarget: (mask: [UInt8], crops: Int, maxCrop: Int, included: Set<String>)?
        var candidate = union.mask, neutral = [[String: Any]]()
        for o in e.owners where o.translated && !o.balloon {
            let pad = Int(ceil(o.fontPixels*0.6))+4
            let x0 = max(0, Int(floor(o.polygon.map(\.x).min()!))-pad)
            let y0 = max(0, Int(floor(o.polygon.map(\.y).min()!))-pad)
            let x1 = min(w, Int(ceil(o.polygon.map(\.x).max()!))+pad)
            let y1 = min(h, Int(ceil(o.polygon.map(\.y).max()!))+pad)
            let cw = x1-x0, ch = y1-y0
            var rgb = [UInt8](), base = [Bool](), probability = [Float]()
            // Rasterize directly into the already-required local ownership crop.
            rasterizations += 1
            let owned = croppedOwnerRaster(o.polygon, width: w, height: h,
                x0: x0, y0: y0, cropWidth: cw, cropHeight: ch)
            for y in y0..<y1 { for x in x0..<x1 {
                let k = y*w+x
                rgb.append(contentsOf: s.rgb[k*3..<k*3+3]); base.append(union.mask[k] != 0)
                probability.append(prob[k])
            } }
            // This pass reads union, not candidate.
            let r = Factory.NativeNeutralMaskRefinement.refine(
                rgb: rgb, base: base, probability: probability, owned: owned,
                width: cw, height: ch, fontPixels: o.fontPixels)
            var foreignVeto = 0, removed = 0
            var selfHalo: [UInt8]?
            for k in r.remove.indices where r.remove[k] {
                let global = (y0+k/cw)*w+x0+k%cw
                if protectForeignTargets && !owned[k] {
                    if target[global] != 0 { foreignVeto += 1; continue }
                    if foreignTargetHaloScale.isFinite && foreignTargetHaloScale > 0 {
                        if neutralTarget == nil {
                            neutralTarget=neutralTargetEnvelope(target,owners:e.owners,baseAudit:initial.audit,
                                width:w,height:h,haloScale:foreignTargetHaloScale,countCoverage:foreignHaloExcludesSelf)
                        }
                        if foreignHaloExcludesSelf && selfHalo == nil {
                            selfHalo=neutralSelfHalo(owned,owner:o,baseAudit:initial.audit,
                                width:cw,height:ch,scale:foreignTargetHaloScale)
                        }
                        let selfContribution = foreignHaloExcludesSelf && neutralTarget!.included.contains(o.id) && selfHalo![k] != 0 ? 1 : 0
                        if Int(neutralTarget!.mask[global]) > selfContribution { foreignVeto += 1; continue }
                    }
                }
                candidate[global] = 0; removed += 1
            }
            neutral.append(["owner": o.id, "status": r.status, "removed": removed,
                            "ridge": r.ridgePixels, "ink": r.inkPixels, "sourceSupportRemoved": r.sourceSupportRemoved,
                            "proposedRemoved": r.remove.filter { $0 }.count, "foreignOwnerVeto": foreignVeto])
        }
        var normal = [[String: Any]]()
        for o in e.owners where o.translated && !o.balloon {
            let pad = Int(ceil(o.fontPixels*0.6))+4
            let x0 = max(0, Int(floor(o.polygon.map(\.x).min()!))-pad)
            let y0 = max(0, Int(floor(o.polygon.map(\.y).min()!))-pad)
            let x1 = min(w, Int(ceil(o.polygon.map(\.x).max()!))+pad)
            let y1 = min(h, Int(ceil(o.polygon.map(\.y).max()!))+pad)
            let cw = x1-x0, ch = y1-y0
            var rgb = [UInt8](), base = [Bool](), probability = [Float]()
            // Rasterize directly into the already-required local ownership crop.
            rasterizations += 1
            let owned = croppedOwnerRaster(o.polygon, width: w, height: h,
                x0: x0, y0: y0, cropWidth: cw, cropHeight: ch)
            for y in y0..<y1 { for x in x0..<x1 {
                let k = y*w+x
                rgb.append(contentsOf: s.rgb[k*3..<k*3+3]); base.append(candidate[k] != 0)
                probability.append(prob[k])
            } }
            let r = Factory.NativeSourceNormalSupport.refine(
                rgb: rgb, base: base, probability: probability, owned: owned,
                width: cw, height: ch, fontPixels: o.fontPixels)
            for k in r.add.indices where r.add[k] { candidate[(y0+k/cw)*w+x0+k%cw] = 1 }
            normal.append(["owner": o.id, "status": r.status, "added": r.add.filter { $0 }.count])
        }
        for k in 0..<w*h where union.protection[k] != 0 { candidate[k] = 0 }
        let fullPageFallback = e.owners.contains { $0.polygon.count > ownerSpanVertexLimit }
        return .init(mask: candidate, protection: union.protection, audit: [
            "sourceRevision": s.revision, "probabilityRevision": p.revision, "ownershipRevision": e.revision,
            "base": initial.audit, "normal": normal, "chroma": chroma.audit, "neutral": neutral,
            "eligibility": eligibility, "conflicts": union.conflicts, "excluded": union.excluded, "PILAdapterCalls": 0,
            "neutralHaloEnvelope":["scale":foreignTargetHaloScale,"croppedRasterizations":neutralTarget?.crops ?? 0,
                "maximumCropPixels":neutralTarget?.maxCrop ?? 0,"changesErasureDirectly":false,
                "excludesSelf":foreignHaloExcludesSelf],
            "ownershipRasterCost": [
                "strategy": "stream-owner-spans-v1", "rasterizations": rasterizations,
                "eagerOwnerRasterCount": e.owners.count,
                "maximumLiveFullPageOwnerRasters": fullPageFallback ? 1 : 0,
                "maximumFullPageOwnerRasterPayloadBytes": fullPageFallback ? w*h : 0,
                "maximumPerRowIntervalPayloadBytes": (ownerSpanVertexLimit + 1) * MemoryLayout<ClosedRange<Int>>.stride,
                "boundKind": "full-page-owner-byte-arrays-only-not-local-crops-or-measured-RSS"
            ]
        ])
    }

    private static let ownerSpanVertexLimit = 16 // selected source-owner geometry bound

    /// Absolute-coordinate scan conversion, matching the original raster's
    /// separate horizontal-edge and nearest-inward crossing spans.
    static func forEachOwnedRun(_ polygon: [CGPoint], width w: Int, height h: Int,
                                _ body: (Int, Int, Int) -> Void) {
        guard polygon.count >= 3 else { return }
        if polygon.count > ownerSpanVertexLimit {
            let full = raster(polygon, width: w, height: h)
            for y in 0..<h {
                var x = 0
                let offset = y * w
                while x < w {
                    guard full[offset + x] != 0 else { x += 1; continue }
                    let lower = x
                    repeat { x += 1 } while x < w && full[offset + x] != 0
                    body(y, lower, x - 1)
                }
            }
            return
        }
        let p = polygon.map { CGPoint(x: Int($0.x), y: Int($0.y)) }
        let y0 = max(0, Int(p.map(\.y).min()!)), y1 = min(h - 1, Int(p.map(\.y).max()!))
        guard y0 <= y1 else { return }
        var ranges = [ClosedRange<Int>]()
        for y in y0...y1 {
            ranges.removeAll(keepingCapacity: true)
            var left = Double.infinity, right = -Double.infinity
            for i in p.indices {
                let a = p[i], b = p[(i + 1) % p.count]
                if a.y == b.y {
                    if CGFloat(y) == a.y {
                        let lo = max(0, Int(min(a.x, b.x))), hi = min(w - 1, Int(max(a.x, b.x)))
                        if lo <= hi { ranges.append(lo...hi) }
                    }
                } else if CGFloat(y) >= min(a.y, b.y) && CGFloat(y) <= max(a.y, b.y) {
                    let x = Double(a.x + (CGFloat(y) - a.y) * (b.x - a.x) / (b.y - a.y))
                    left = min(left, x); right = max(right, x)
                }
            }
            if left.isFinite {
                let lo = max(0, Int(floor(left + 0.5))), hi = min(w - 1, Int(ceil(right - 0.5)))
                if lo <= hi {
                    if ranges.isEmpty { body(y, lo, hi); continue }
                    ranges.append(lo...hi)
                }
            }
            guard !ranges.isEmpty else { continue }
            ranges.sort { $0.lowerBound < $1.lowerBound }
            var lo = ranges[0].lowerBound, hi = ranges[0].upperBound
            for range in ranges.dropFirst() {
                if range.lowerBound <= hi + 1 { hi = max(hi, range.upperBound) }
                else { body(y, lo, hi); lo = range.lowerBound; hi = range.upperBound }
            }
            body(y, lo, hi)
        }
    }

    private static func croppedOwnerRaster(_ polygon: [CGPoint], width: Int, height: Int,
                                           x0: Int, y0: Int, cropWidth: Int, cropHeight: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: cropWidth * cropHeight)
        if polygon.count > ownerSpanVertexLimit {
            let full = raster(polygon, width: width, height: height)
            for y in 0..<cropHeight {
                let page = (y0 + y) * width + x0, crop = y * cropWidth
                for x in 0..<cropWidth { out[crop + x] = full[page + x] != 0 }
            }
            return out
        }
        forEachOwnedRun(polygon, width: width, height: height) { y, lower, upper in
            guard y >= y0 && y < y0 + cropHeight else { return }
            let lo = max(lower, x0), hi = min(upper, x0 + cropWidth - 1)
            guard lo <= hi else { return }
            let row = (y - y0) * cropWidth - x0
            for x in lo...hi { out[row + x] = true }
        }
        return out
    }
}

#if NATIVE_ENSEMBLE_LAZY_OWNERSHIP_SELF_TEST
/// Opt-in component checks only; never compiled into the normal application.
@main
private enum NativeEnsembleRemovalLazyOwnershipChecks {
    typealias Caller = NativeMainRemovalSourceFactory.NativeCurrentMaskCaller

    struct Fixture {
        let name: String
        let width = 80, height = 64
        var rgb = [UInt8](repeating: 252, count: 80*64*3)
        var db = [Float](repeating: 0, count: 80*64)
        var boundary = [UInt8](repeating: 0, count: 80*64)
        var owners = [Caller.Owner]()
        var pending = [CGRect]()
        var halfDB = false

        mutating func paint(_ x: Range<Int>, _ y: Range<Int>, _ color: [UInt8], db value: Float = 0) {
            for yy in y { for xx in x {
                let k = yy*width+xx
                for c in 0..<3 { rgb[k*3+c] = color[c] }
                db[k] = value
            } }
        }

        var source: Caller.Source { .init(width: width, height: height, rgb: rgb, revision: "synthetic-source-v1") }
        var probability: Caller.Probability {
            var values = db
            if halfDB {
                values = (0..<height/2).flatMap { y in (0..<width/2).map { x in db[(2*y)*width+2*x] } }
            }
            return .init(width: halfDB ? width/2 : width, height: halfDB ? height/2 : height,
                         values: values, sourceRevision: source.revision, revision: "synthetic-db-v1")
        }
        var evidence: Caller.Evidence {
            .init(sourceRevision: source.revision, revision: "synthetic-ownership-v1",
                  boundary: boundary, owners: owners, pending: pending)
        }
    }

    static func owner(_ id: String, _ rect: CGRect, translated: Bool = true,
                      balloon: Bool = false, font: Double = 12) -> Caller.Owner {
        .init(id: id, polygon: [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.maxX, y: rect.minY),
                               CGPoint(x: rect.maxX, y: rect.maxY), CGPoint(x: rect.minX, y: rect.maxY)],
              fontPixels: font, translated: translated, balloon: balloon)
    }

    static func canonical(_ audit: [String: Any]) throws -> Data {
        try JSONSerialization.data(withJSONObject: audit, options: [.sortedKeys])
    }

    static func main() throws {
        var fixtures = [Fixture(name: "empty")]
        var neutral = Fixture(name: "neutral-db-trim-normal")
        neutral.owners = [owner("target", CGRect(x: 15, y: 12, width: 43, height: 30))]
        neutral.paint(17..<28, 17..<30, [235, 235, 235])
        neutral.paint(20..<25, 20..<27, [20, 20, 20], db: 0.9)
        neutral.paint(45..<49, 20..<27, [20, 20, 20])
        fixtures.append(neutral)
        var balloon = neutral
        balloon.owners = [owner("balloon", CGRect(x: 15, y: 12, width: 43, height: 30), balloon: true)]
        fixtures.append(balloon)
        var overlap = neutral
        overlap.owners.append(owner("overlap", CGRect(x: 21.5, y: 18.5, width: 30, height: 20), font: 7))
        fixtures.append(overlap)
        var reversed = overlap; reversed.owners.reverse(); fixtures.append(reversed)
        var chromatic = Fixture(name: "chromatic-completion")
        chromatic.owners = [owner("color", CGRect(x: 16, y: 14, width: 14, height: 21), font: 14)]
        chromatic.paint(25..<38, 20..<28, [190, 20, 30], db: 0.85)
        fixtures.append(chromatic)
        var kept = neutral
        kept.owners.append(owner("kept", CGRect(x: 55, y: 16, width: 17, height: 19), translated: false))
        kept.paint(60..<66, 22..<28, [180, 20, 30], db: 0.6)
        fixtures.append(kept)
        var conflict = kept
        conflict.owners.append(owner("kept-conflict", CGRect(x: 19, y: 19, width: 9, height: 10), translated: false))
        fixtures.append(conflict)
        var pending = conflict
        pending.pending = [CGRect(x: 18.75, y: 18.25, width: 11.5, height: 12.5), CGRect(x: 43, y: 19, width: 9, height: 11)]
        fixtures.append(pending)
        var rail = neutral
        rail.paint(0..<80, 44..<46, [30, 30, 30])
        for y in 44..<46 { for x in 0..<80 { rail.boundary[y*80+x] = 1 } }
        fixtures.append(rail)
        var edges = Fixture(name: "fractional-convex-roi-edges")
        edges.owners = [.init(id: "top-left", polygon: [CGPoint(x: 0.25, y: 0.75), CGPoint(x: 15.9, y: 0.75),
                            CGPoint(x: 20.4, y: 13.8), CGPoint(x: 0.2, y: 15.6)],
                            fontPixels: 8, translated: true, balloon: false),
                        owner("bottom-right", CGRect(x: 68.25, y: 50.25, width: 11.5, height: 13.5), font: 8)]
        edges.paint(0..<12, 2..<5, [20, 20, 20], db: 0.9)
        edges.paint(74..<80, 59..<64, [30, 30, 30], db: 0.8)
        fixtures.append(edges)
        var half = pending; half.halfDB = true; fixtures.append(half)
        var dark = neutral
        dark.paint(15..<59, 12..<43, [30, 30, 30], db: 0.8)
        fixtures.append(dark)
        var noDB = neutral; noDB.db = noDB.db.map { _ in 0 }; fixtures.append(noDB)
        var foreign = neutral
        foreign.owners = [owner("local-neutral", CGRect(x:15,y:12,width:24,height:30)),
                          owner("neighbor-glyph", CGRect(x:44,y:18,width:8,height:12),balloon:true,font:8)]
        fixtures.append(foreign)

        let settings: [(Double, Double, Bool)] = [(32, 1, true), (32, 0.5, false), (45, 1.5, true)]
        var comparisons = 0, maskPixels = 0, protectedPixels = 0, removed = 0, added = 0, chromaAdded = 0
        var eligible = 0, ineligible = 0, conflicts = 0, excluded = 0
        var neutralStatuses = Set<String>(), normalStatuses = Set<String>(), foreignVetoTotal = 0
        for (index, fixture) in fixtures.enumerated() {
            for (contrast, radius, roles) in settings {
              for protectForeign in [false,true] {
               for haloScale in [0.0,0.5,1.0] {
                for excludesSelf in [false,true] {
                let eager = try Caller.prepare(source: fixture.source, probability: fixture.probability,
                    evidence: fixture.evidence, contrast: contrast, radiusScale: radius, roleSupport: roles,
                    protectForeignTargets:protectForeign,foreignTargetHaloScale:haloScale,
                    foreignHaloExcludesSelf:excludesSelf)
                let stream = try Caller.prepareStreamingOwners(source: fixture.source, probability: fixture.probability,
                    evidence: fixture.evidence, contrast: contrast, radiusScale: radius, roleSupport: roles,
                    protectForeignTargets:protectForeign,foreignTargetHaloScale:haloScale,
                    foreignHaloExcludesSelf:excludesSelf)
                precondition(eager.mask == stream.mask, "mask mismatch fixture \(index)")
                precondition(eager.protection == stream.protection, "protection mismatch fixture \(index)")
                if excludesSelf && fixture.owners.filter({ $0.translated }).count == 1 {
                    let noHalo = try Caller.prepareStreamingOwners(source: fixture.source, probability: fixture.probability,
                        evidence: fixture.evidence, contrast: contrast, radiusScale: radius, roleSupport: roles,
                        protectForeignTargets:protectForeign)
                    precondition(noHalo.mask == stream.mask,"single owner gained foreign halo authority")
                }
                var semantic = stream.audit
                let cost = semantic.removeValue(forKey: "ownershipRasterCost") as! [String: Any]
                let identicalAudit = try canonical(eager.audit) == canonical(semantic)
                precondition(identicalAudit, "semantic audit mismatch")
                let count = fixture.owners.count + fixture.owners.filter { !$0.translated }.count +
                    2*fixture.owners.filter { $0.translated && !$0.balloon }.count
                precondition(cost["rasterizations"] as! Int == count + (stream.audit["eligibility"] as! [[String: Any]]).filter { $0["eligible"] as? Bool == true }.count)
                precondition(cost["maximumLiveFullPageOwnerRasters"] as! Int == 0)
                precondition(cost["maximumFullPageOwnerRasterPayloadBytes"] as! Int == 0)
                for k in stream.mask.indices where stream.protection[k] != 0 { precondition(stream.mask[k] == 0) }
                maskPixels += stream.mask.filter { $0 != 0 }.count
                protectedPixels += stream.protection.filter { $0 != 0 }.count
                for record in stream.audit["neutral"] as! [[String: Any]] {
                    neutralStatuses.insert(record["status"] as! String); removed += record["removed"] as! Int
                    foreignVetoTotal += record["foreignOwnerVeto"] as! Int
                }
                for record in stream.audit["normal"] as! [[String: Any]] {
                    normalStatuses.insert(record["status"] as! String); added += record["added"] as! Int
                }
                for record in stream.audit["chroma"] as! [[String: Any]] { chromaAdded += record["added"] as? Int ?? 0 }
                for record in stream.audit["eligibility"] as! [[String: Any]] {
                    if record["eligible"] as! Bool { eligible += 1 } else { ineligible += 1 }
                }
                conflicts += stream.audit["conflicts"] as! Int; excluded += stream.audit["excluded"] as! Int
                comparisons += 1
                }
               }
              }
            }
        }
        precondition(maskPixels > 0 && protectedPixels > 0 && removed > 0 && added > 0 && chromaAdded > 0)
        precondition(eligible > 0 && ineligible > 0 && conflicts > 0 && excluded > 0)
        precondition(foreignVetoTotal > 0,"foreign-owner veto not exercised")
        // Single-owner halo must never masquerade as a foreign contribution.
        // The overlap pixel must still protect the neighbor when self is subtracted.
        let a=owner("a",CGRect(x:10,y:10,width:10,height:10))
        let b=owner("b",CGRect(x:22,y:10,width:10,height:10))
        let haloAudit: [[String:Any]] = [["owner":"a","radiusSourcePixels":4],
                                       ["owner":"b","radiusSourcePixels":4]]
        let empty=[UInt8](repeating:0,count:80*64)
        let one=Caller.neutralTargetEnvelope(empty,owners:[a],baseAudit:haloAudit,
            width:80,height:64,haloScale:1,countCoverage:true)
        let two=Caller.neutralTargetEnvelope(empty,owners:[a,b],baseAudit:haloAudit,
            width:80,height:64,haloScale:1,countCoverage:true)
        let selfMask=Caller.neutralSelfHalo(Caller.raster(a.polygon,width:80,height:64).map { $0 != 0 },
            owner:a,baseAudit:haloAudit,width:80,height:64,scale:1)
        precondition(one.mask[15*80+23]==1 && selfMask[15*80+23]==1)
        precondition(two.mask[15*80+23]==2,"neighbor overlap lost after self subtraction")
        precondition(one.mask.allSatisfy { $0<=1 } && two.mask.allSatisfy { $0<=2 })
        precondition(neutralStatuses.contains("source-db-exterior-trim") && neutralStatuses.contains("dark-source-abstain") &&
                     neutralStatuses.contains("insufficient-neutral-ridge"))
        precondition(normalStatuses.contains("source-component-normal-support") && normalStatuses.contains("source-distribution-abstain"))

        let s = neutral.source, p = neutral.probability, e = neutral.evidence
        var errors = [(Caller.Source, Caller.Probability, Caller.Evidence)]()
        errors.append((.init(width: 0, height: s.height, rgb: [], revision: s.revision), p, e))
        errors.append((.init(width: s.width, height: s.height, rgb: [], revision: s.revision), p, e))
        errors.append((s, .init(width: p.width, height: p.height, values: p.values,
                               sourceRevision: "stale", revision: p.revision), e))
        errors.append((s, p, .init(sourceRevision: "stale", revision: e.revision, boundary: e.boundary, owners: e.owners, pending: [])))
        errors.append((s, .init(width: p.width, height: p.height, values: [.nan],
                               sourceRevision: p.sourceRevision, revision: p.revision), e))
        var invalidValues = p.values; invalidValues[0] = .nan
        errors.append((s, .init(width: p.width, height: p.height, values: invalidValues,
                               sourceRevision: p.sourceRevision, revision: p.revision), e))
        errors.append((s, .init(width: p.width+1, height: p.height, values: p.values,
                               sourceRevision: p.sourceRevision, revision: p.revision), e))
        errors.append((s, p, .init(sourceRevision: s.revision, revision: "", boundary: e.boundary, owners: [], pending: [])))
        errors.append((s, p, .init(sourceRevision: s.revision, revision: e.revision, boundary: [], owners: [], pending: [])))
        errors.append((s, p, .init(sourceRevision: s.revision, revision: e.revision, boundary: e.boundary,
                                  owners: [], pending: [CGRect(x: 79, y: 0, width: 2, height: 1)])))
        for polygon in [[CGPoint(x: -1, y: 0), CGPoint(x: 2, y: 0), CGPoint(x: 0, y: 2)],
                        [CGPoint(x: 0, y: 0), CGPoint(x: 8, y: 0), CGPoint(x: 2, y: 2), CGPoint(x: 0, y: 8)]] {
            let invalid = Caller.Owner(id: "invalid", polygon: polygon, fontPixels: 8, translated: true, balloon: false)
            errors.append((s, p, .init(sourceRevision: s.revision, revision: e.revision, boundary: e.boundary, owners: [invalid], pending: [])))
        }
        for (source, probability, evidence) in errors {
            func failure(_ streaming: Bool) -> String {
                do {
                    if streaming { _ = try Caller.prepareStreamingOwners(source: source, probability: probability, evidence: evidence) }
                    else { _ = try Caller.prepare(source: source, probability: probability, evidence: evidence) }
                    return "unexpected-success"
                } catch { return String(describing: error) }
            }
            let eager = failure(false), stream = failure(true)
            precondition(eager != "unexpected-success" && eager == stream, "error parity: \(eager) / \(stream)")
        }
        print("PASS \(fixtures.count) synthetic fixtures x \(settings.count) settings x2foreign-veto x3halo x2self-exclusion settings = \(comparisons) exact mask/protection/semantic-audit comparisons; \(errors.count) error parity checks; foreign veto pixels\(foreignVetoTotal)")
        print("Branch witnesses: mask=\(maskPixels) protected=\(protectedPixels) neutralRemoved=\(removed) normalAdded=\(added) chromaAdded=\(chromaAdded) eligible=\(eligible) ineligible=\(ineligible) conflicts=\(conflicts) excluded=\(excluded)")
        print("Ownership structural bound checked: no full-page owner raster in ordinary fixtures; not a measured RSS, latency, real-page or quality result")
    }
}
#endif
