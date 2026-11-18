import CoreGraphics
import Foundation

/// Outside-owner terminal expansion requires independent ownership, not proximity to a mask.
enum EnsembleCandidate06Next: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 1, "colorContrast": 28, "terminalReach": 0.75, "pairGap": 0.28,
        "maxPixels": 32_000_000, "maxROIPixels": 500_000, "maxWorkPixels": 4_000_000,
        "maxPaintOperations": 8_000_000, "supportCoverage": 0.95,
        "surfaceTolerance": 28, "stemSeedFraction": 0.12, "maxSurfacePixels": 600_000,
        "minimumOutsidePointContrast": 0
    ]
    private struct RGB {
        var r: Int; var g: Int; var b: Int
        func gap(_ c: RGB) -> Double { Double(max(abs(r - c.r), abs(g - c.g), abs(b - c.b))) }
    }
    private struct Owner { var index: Int; var item: [String: Any]; var box: CGRect; var polygon: [CGPoint] }
    private struct Region { var kind: Int; var box: CGRect; var outer: [CGPoint]; var holes: [[CGPoint]] }
    private struct Attachment {
        var advance: Double; var domain: Int; var kind: String; var surfacePixels: Int; var typedAnchor: Bool
    }
    private struct CC {
        var pixels: [Int]; var box: CGRect; var strong: Int; var seeds: Int; var owned: Int
        var color: RGB; var boundary: Bool; var protected: Bool
    }
    private struct Stop: Error { var message: String }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String, _ lo: Double, _ hi: Double) -> Double {
            let v = parameters[key] ?? defaults[key]!
            return v.isFinite ? max(lo, min(hi, v)) : defaults[key]!
        }
        var result = Ensemble100Proposal(items: page.items)
        guard p("enabled", 0, 1) > 0 else { return result }
        let w = page.original.width, h = page.original.height
        guard w > 0, h > 0, w <= Int.max / h, w * h <= Int(p("maxPixels", 1, 64_000_000)),
              page.removalMask.width == w, page.removalMask.height == h, let mask = gray(page.removalMask) else {
            result.audit = ["agent06Terminal2": "unsupported-mask-dimensions-decode-or-page-budget", "changedPixels": 0]; return result
        }
        let originals = page.savedEvidence["originalItems"] as? [[String: Any]] ?? []
        let allItems = page.items + originals
        let held = allItems.filter { preserved($0) }.compactMap { bounds($0, w, h) }
        var owners: [Owner] = []
        for (index, item) in page.items.enumerated() where !preserved(item) {
            guard let text = item["text"] as? String, !text.isEmpty, let box = bounds(item, w, h) else { continue }
            let members = originals.filter { !preserved($0) }.compactMap { original -> (CGRect, [String: Any])? in
                guard let r = bounds(original, w, h), area(r.intersection(box)) >= area(r) * 0.8 else { return nil }
                return (r, original)
            }
            for (r, raw) in members.isEmpty ? [(box, item)] : members {
                if !owners.contains(where: { $0.box.equalTo(r) }) {
                    owners.append(Owner(index: index, item: raw, box: r, polygon: itemPolygon(raw,w,h)))
                }
            }
        }
        let rf: [Region] = page.rfRegions.compactMap { r in
            guard (0...3).contains(r.classID),r.confidence.isFinite, r.confidence >= 0.6, let box = scaled(r.bounds, w, h) else { return nil }
            return Region(kind: r.classID, box: box, outer: ring(r.exterior, w, h), holes: r.holes.map { ring($0, w, h) })
        }
        let ocrLines = cachedOCRLines(page.savedEvidence["originalOCR"],w,h)
        let canvas = CGRect(x: 0, y: 0, width: w, height: h), contrast = p("colorContrast", 22, 36)
        var output = mask, changed = 0, work = 0, operations = 0, pairChecks = 0, pairCount = 0, pointCount = 0, surfaceWork = 0
        var unconfirmedOutsideUnits = 0
        var reasons: [String: Int] = [:], traces: [[String: Any]] = []
        func reject(_ key: String) { reasons[key, default: 0] += 1 }
        do {
            for (ownerIndex, owner) in owners.enumerated() {
                let glyph = glyphSize(owner, page), reach = p("terminalReach", 0.65, 1.15)
                let vertical = owner.item["sourceVertical"] as? Bool ?? (owner.box.height > owner.box.width * 1.8)
                let roi: CGRect
                if vertical {
                    roi = CGRect(x: owner.box.minX - glyph * 0.25, y: max(owner.box.minY, owner.box.maxY - glyph * 1.5),
                        width: owner.box.width + glyph * 0.5, height: min(owner.box.height, glyph * 1.5) + glyph * (reach + 0.35))
                        .intersection(canvas).integral
                } else {
                    roi = CGRect(x: max(owner.box.minX, owner.box.maxX - glyph * 1.5), y: owner.box.minY - glyph * 0.25,
                        width: min(owner.box.width, glyph * 1.5) + glyph * (reach + 0.35), height: owner.box.height + glyph * 0.5)
                        .intersection(canvas).integral
                }
                let rw = Int(roi.width), rh = Int(roi.height), n = rw * rh, x0 = Int(roi.minX), y0 = Int(roi.minY)
                guard n > 0 else { reject("empty-terminal-roi"); continue }
                guard n <= Int(p("maxROIPixels", 64, 2_000_000)) else { throw Stop(message: "roi-budget") }
                guard work + n <= Int(p("maxWorkPixels", 64, 12_000_000)) else { throw Stop(message: "cumulative-pixel-budget") }
                work += n
                guard let rgb = rgba(page.original, roi) else { reject("source-rgb-decode-failed"); continue }
                let nearby = (rf+ocrLines).filter { $0.box.insetBy(dx: -2, dy: -2).intersects(roi) }
                let others = owners.enumerated().filter { $0.offset != ownerIndex }.map { $0.element.box }.filter {
                    area($0.intersection(owner.box)) < min(area($0), area(owner.box)) * 0.65
                }
                guard var blocked = protect(nearby, held + others, roi, edges: false),
                      let edges = protect(nearby, [], roi, edges: true) else { throw Stop(message: "protection-allocation") }
                var signal = [Float](repeating: 0, count: n), labels = [Int](repeating: -1, count: n)
                let radius = min(18, max(4, Int((glyph * 0.35).rounded())))
                let offsets = [(radius,0),(-radius,0),(0,radius),(0,-radius),
                               (radius,radius),(-radius,radius),(radius,-radius),(-radius,-radius)]
                var sourceFallbacks = 0
                for ty in stride(from: 0, to: rh, by: 4) { for tx in stride(from: 0, to: rw, by: 4) {
                    let cx = min(rw - 1, tx + 2), cy = min(rh - 1, ty + 2)
                    var samples: [RGB] = [], masked: [RGB] = []
                    for (dx,dy) in offsets { for jitter in [0,2] {
                        let x = cx + dx + jitter, y = cy + dy
                        guard x >= 0, y >= 0, x < rw, y < rh else { continue }
                        let c = color(rgb, y * rw + x)
                        if mask[(y+y0)*w+x+x0] < 64 { samples.append(c) } else { masked.append(c) }
                    } }
                    // Source-only robust fallback: changing fresh restoration cannot change this candidate.
                    if samples.count < 6 { samples += masked; sourceFallbacks += 1 }
                    guard samples.count >= 4 else { continue }
                    let bg = RGB(r: median(samples.map(\.r)), g: median(samples.map(\.g)), b: median(samples.map(\.b)))
                    let dev = samples.map { $0.gap(bg) }.sorted(), noise = dev[min(dev.count-1,dev.count*3/4)]
                    for y in ty..<min(rh,ty+4) { for x in tx..<min(rw,tx+4) {
                        signal[y*rw+x] = Float(max(0,color(rgb,y*rw+x).gap(bg)-noise*1.25))
                    } }
                } }
                for i in 0..<n where edges[i] != 0 && signal[i] >= Float(contrast*0.55) { blocked[i] = 1 }
                var components: [CC] = []
                for start in 0..<n where labels[start] == -1 && signal[start] >= Float(contrast*0.55) {
                    guard components.count < 8000 else { throw Stop(message: "component-budget") }
                    let label = components.count
                    var q = [start], cursor = 0, strong = 0, seeds = 0, owned = 0, isBlocked = false, boundary = false
                    var minX = rw, maxX = 0, minY = rh, maxY = 0, sum = RGB(r:0,g:0,b:0)
                    labels[start] = label
                    while cursor < q.count {
                        let i = q[cursor], x = i % rw, y = i / rw; cursor += 1
                        minX=min(minX,x); maxX=max(maxX,x); minY=min(minY,y); maxY=max(maxY,y)
                        if x == 0 || y == 0 || x == rw-1 || y == rh-1 { boundary = true }
                        if blocked[i] != 0 { isBlocked = true }
                        if owns(CGPoint(x:Double(x+x0)+0.5,y:Double(y+y0)+0.5),owner) { owned += 1 }
                        if signal[i] >= Float(contrast) {
                            strong += 1; let c=color(rgb,i); sum.r += c.r; sum.g += c.g; sum.b += c.b
                            if mask[(y+y0)*w+x+x0] >= 128 { seeds += 1 }
                        }
                        for dy in -1...1 { for dx in -1...1 where dx != 0 || dy != 0 {
                            let xx=x+dx, yy=y+dy
                            guard xx >= 0, yy >= 0, xx < rw, yy < rh else { continue }
                            let j=yy*rw+xx
                            if labels[j] == -1 && signal[j] >= Float(contrast*0.55) { labels[j]=label; q.append(j) }
                        } }
                    }
                    components.append(CC(pixels:q,box:CGRect(x:x0+minX,y:y0+minY,width:maxX-minX+1,height:maxY-minY+1),
                        strong:strong,seeds:seeds,owned:owned,color:RGB(r:sum.r/max(1,strong),g:sum.g/max(1,strong),b:sum.b/max(1,strong)),
                        boundary:boundary,protected:isBlocked))
                }
                func safe(_ c: CC) -> Bool {
                    !c.boundary && !c.protected && c.strong > 0 && Double(c.strong)/Double(c.pixels.count) >= 0.35 &&
                        max(c.box.width,c.box.height) <= glyph*1.5 && Double(c.pixels.count) <= glyph*glyph
                }
                func dot(_ c: CC) -> Bool {
                    let big=max(c.box.width,c.box.height), small=min(c.box.width,c.box.height)
                    return safe(c) && big <= max(2,min(32,glyph*0.28)) && big/small <= 2.5 && Double(c.pixels.count) <= max(1,glyph*glyph*0.07)
                }
                let anchors = components.indices.filter {
                    let c=components[$0]
                    return safe(c) && c.seeds >= 2 && Double(c.owned)/Double(c.pixels.count) >= 0.65
                }
                guard !anchors.isEmpty else { reject("no-terminal-source-mask-anchor"); continue }
                let palette = anchors.map { components[$0].color }
                let tolerance=max(32,contrast*1.5)
                func matches(_ c: CC) -> Bool { palette.contains { $0.gap(c.color) <= tolerance } }
                func typedBody(_ index: Int) -> Bool {
                    let c=components[index], b=c.box
                    guard c.seeds >= max(3,Int(Double(c.strong)*0.2)), b.height >= glyph*0.3,
                          b.width >= glyph*0.12, b.height/b.width >= 0.25, b.height/b.width <= 4 else { return false }
                    var runCounts: [Int] = []
                    for fraction in [0.15,0.3,0.5,0.7,0.85] {
                        let y=min(rh-1,max(0,Int(b.minY)-y0+Int(Double(b.height-1)*fraction)))
                        var runs=0, previous=false
                        for x in max(0,Int(b.minX)-x0)..<min(rw,Int(b.maxX)-x0) {
                            let hit=labels[y*rw+x] == index
                            if hit && !previous { runs += 1 }; previous=hit
                        }
                        runCounts.append(runs)
                    }
                    return (runCounts.max() ?? 0) >= 2 && Set(runCounts).count >= 2
                }
                let typedAnchors=Set(anchors.filter(typedBody))
                var localPointEvidence: [Int: Double] = [:]
                func pointContrast(_ index: Int) -> Double {
                    if let value = localPointEvidence[index] { return value }
                    let value = localPointContrast(original: page.original, box: components[index].box) ?? -1
                    localPointEvidence[index] = value
                    return value
                }
                let pixelRun=typedAnchors.contains { a in typedAnchors.contains { b in
                    guard a != b else { return false }
                    let aa=components[a].box, bb=components[b].box
                    let along=vertical ? abs(aa.midY-bb.midY) : abs(aa.midX-bb.midX)
                    let cross=vertical ? abs(aa.midX-bb.midX) : abs(aa.midY-bb.midY)
                    return cross <= glyph*0.2 && along >= glyph*0.35 && along <= glyph*1.5 &&
                        min(aa.height,bb.height)/max(aa.height,bb.height) >= 0.65
                } }
                func fractionInside(_ ids: [Int], _ r: Region) -> Double {
                    var count=0, total=0
                    for id in ids { for i in components[id].pixels {
                        total += 1
                        if inside(CGPoint(x:Double(i%rw+x0)+0.5,y:Double(i/rw+y0)+0.5),r) { count += 1 }
                    } }
                    return Double(count)/Double(max(1,total))
                }
                func attach(_ unit: CGRect, _ ids: [Int], body: Int?) throws -> Attachment? {
                    let excluded=Set(ids)
                    let start=vertical ? unit.minY : unit.minX, end=vertical ? unit.maxY : unit.maxX
                    let ownerEnd=vertical ? owner.box.maxY : owner.box.maxX
                    guard start >= ownerEnd-glyph*0.9, end <= ownerEnd+glyph*reach else { return nil }
                    let center=CGPoint(x:unit.midX,y:unit.midY)
                    let ownDistance=pointGap(center,owner.box)
                    guard !others.contains(where: { pointGap(center,$0)+glyph*0.12 < ownDistance || $0.insetBy(dx:-1,dy:-1).intersects(unit) }) else {
                        reject("different-paragraph-nearer-or-overlap"); return nil
                    }
                    let candidates=anchors.filter { a in
                        guard !excluded.contains(a) else { return false }
                        let b=components[a].box, cross=vertical ? unit.midX : unit.midY
                        let low=vertical ? b.minX-glyph*0.22 : b.midY-glyph*0.2
                        let high=vertical ? b.maxX+glyph*0.3 : b.maxY+glyph*0.25
                        return cross >= low && cross <= high
                    }
                    guard let a=candidates.max(by: {
                        (vertical ? components[$0].box.maxY : components[$0].box.maxX) <
                            (vertical ? components[$1].box.maxY : components[$1].box.maxX)
                    }) else { return nil }
                    let b=components[a].box, advance=start-(vertical ? b.maxY : b.maxX)
                    guard advance >= -glyph*0.18 && advance <= glyph*reach else { return nil }
                    let outside=ids.contains { components[$0].owned != components[$0].pixels.count }
                    if !outside {
                        return Attachment(advance:Double(advance),domain:-1,kind:"existing-ocr-owner",surfacePixels:0,typedAnchor:typedAnchors.contains(a))
                    }
                    // An OCR/RF region authorizes ownership, not the existence
                    // of a glyph. Reject smooth-background pseudo-points using
                    // independent immediate original-pixel evidence, equally
                    // for OCR, RF-text and RF-balloon support paths.
                    let minimumContrast = p("minimumOutsidePointContrast", 0, 32)
                    if minimumContrast > 0 {
                        for index in ids where index != body {
                            guard pointContrast(index) >= minimumContrast else {
                                reject("outside-point-no-local-source-contrast"); return nil
                            }
                        }
                    }
                    // A paired glyph must itself touch the old mask. A nearby masked letter is insufficient.
                    if let body {
                        let c=components[body]
                        guard c.seeds >= max(2,Int(ceil(Double(c.strong)*p("stemSeedFraction",0.05,0.3)))) else {
                            unconfirmedOutsideUnits += 1;reject("outside-pair-stem-not-mask-anchored");return nil
                        }
                    } else if !typedAnchors.contains(a) {
                        unconfirmedOutsideUnits += 1;reject("outside-point-without-complex-source-text-body");return nil
                    }
                    let coverage=p("supportCoverage",0.85,1)
                    for index in nearby.indices {
                        let r=nearby[index]
                        guard r.kind == 0 || r.kind == 4,
                              area(r.box) <= max(area(owner.box)*2.5,glyph*glyph*4),
                              area(r.box.intersection(owner.box)) >= min(area(r.box),area(owner.box))*0.25,
                              fractionInside(ids,r) >= coverage, fractionInside([a],r) >= coverage else { continue }
                        return Attachment(advance:Double(advance),domain:index,kind:r.kind == 0 ? "independent-rf-text" : "independent-cached-ocr-line",
                                          surfacePixels:0,typedAnchor:typedAnchors.contains(a))
                    }
                    // A balloon alone never authorizes a free-standing point. A seeded body/dot pair
                    // additionally needs connected original background pixels within the actual polygon.
                    if body != nil {
                        for index in nearby.indices {
                            let r=nearby[index]
                            guard r.kind == 2,!r.outer.isEmpty,fractionInside(ids,r) >= coverage,fractionInside([a],r) >= coverage else { continue }
                            let visited=try connectedSurface(r,anchor:b,unit:unit,rgb:rgb,labels:labels,blocked:blocked,roi:roi,
                                glyph:glyph,tolerance:p("surfaceTolerance",16,44),coverage:coverage,work:&surfaceWork,
                                limit:Int(p("maxSurfacePixels",1,2_000_000)))
                            if visited > 0 {
                                return Attachment(advance:Double(advance),domain:index,kind:"rf-polygon-and-connected-source-surface",
                                                  surfacePixels:visited,typedAnchor:typedAnchors.contains(a))
                            }
                            reject("outside-pair-no-connected-pixel-body")
                        }
                    }
                    reject("outside-owner-ownership-unconfirmed-original-mask-retained")
                    unconfirmedOutsideUnits += 1
                    if pixelRun { reject("pixel-text-run-observed-not-erasure-authority") }
                    return nil
                }
                var selected=Set<Int>(), itemPairs=0, itemDots=0
                var pairedPointCandidates=Set<Int>()
                var domains: [Int:Int] = [:]
                var units: [[String:Any]] = []
                for bodyIndex in components.indices {
                    guard !selected.contains(bodyIndex) else { continue }
                    let body=components[bodyIndex], b=body.box
                    guard safe(body), matches(body), b.height >= glyph*0.25, b.height <= glyph*1.1,
                          b.width <= glyph*0.85, b.height/b.width >= 0.8, b.height/b.width <= 12 else { continue }
                    pairChecks += components.count
                    guard pairChecks <= 1_000_000 else { throw Stop(message:"pair-check-budget") }
                    for dotIndex in components.indices where dotIndex != bodyIndex && !selected.contains(dotIndex) {
                        let point=components[dotIndex], d=point.box, gap=d.minY-b.maxY
                        guard dot(point), matches(point), body.color.gap(point.color) <= tolerance,
                              b.height >= d.height*1.5, gap >= 0, gap <= glyph*p("pairGap",0.15,0.4),
                              abs(d.midX-b.midX) <= max(b.width*0.55,glyph*0.18) else { continue }
                        let unit=b.union(d)
                        pairedPointCandidates.insert(dotIndex)
                        guard let attached=try attach(unit,[bodyIndex,dotIndex],body:bodyIndex) else { reject("pair-not-owned-terminal"); continue }
                        selected.insert(bodyIndex); selected.insert(dotIndex); itemPairs += 1
                        domains[bodyIndex]=attached.domain;domains[dotIndex]=attached.domain
                        units.append(["kind":"body-dot-pair","body":rect(b),"dot":rect(d),"bodyPixels":body.pixels.count,
                            "dotPixels":point.pixels.count,"bodyMaskSeeds":body.seeds,"dotMaskSeeds":point.seeds,
                            "bodyOwnedFraction":Double(body.owned)/Double(body.pixels.count),"pairGapPixels":gap,
                            "anchorAdvancePixels":attached.advance,"ownershipEvidence":attached.kind,
                            "connectedSurfacePixels":attached.surfacePixels,"typedAnchor":attached.typedAnchor])
                        break
                    }
                }
                for i in components.indices where !selected.contains(i) {
                    let c=components[i]
                    guard dot(c), matches(c), c.seeds == 0 else { continue }
                    guard !pairedPointCandidates.contains(i) else { reject("rejected-body-dot-not-downgraded-to-point");continue }
                    guard let attached=try attach(c.box,[i],body:nil) else { reject("point-not-owned-terminal"); continue }
                    selected.insert(i); itemDots += 1
                    domains[i]=attached.domain
                    units.append(["kind":"terminal-point","box":rect(c.box),"pixels":c.pixels.count,
                                  "anchorAdvancePixels":attached.advance,"ownershipEvidence":attached.kind,"typedAnchor":attached.typedAnchor])
                }
                let before=changed
                for index in selected.sorted() {
                    let c=components[index]
                    operations += c.pixels.count*9
                    guard operations <= Int(p("maxPaintOperations",1,32_000_000)) else { throw Stop(message:"paint-budget") }
                    // One source pixel fringe around actual accepted CCs, never bbox/balloon fill.
                    for i in c.pixels {
                        let x=i%rw,y=i/rw
                        for (dx,dy) in [(0,0),(-1,0),(1,0),(0,-1),(0,1)] {
                            let xx=x+dx,yy=y+dy
                            guard xx >= 0,yy >= 0,xx < rw,yy < rh else { continue }
                            let j=yy*rw+xx
                            guard blocked[j] == 0, labels[j] == -1 || labels[j] == index else { continue }
                            let point=CGPoint(x:Double(xx+x0)+0.5,y:Double(yy+y0)+0.5),domain=domains[index] ?? -1
                            guard owns(point,owner) || (domain >= 0 && inside(point,nearby[domain])) else { continue }
                            let global=(yy+y0)*w+xx+x0
                            if output[global] != 255 { output[global]=255; changed += 1 }
                        }
                    }
                }
                pairCount += itemPairs; pointCount += itemDots
                traces.append(["itemIndex":owner.index,"sourceBox":rect(owner.box),"roi":rect(roi),"glyphPixels":glyph,
                    "sourceOnlyBackgroundFallbacks":sourceFallbacks,"components":components.count,"anchors":anchors.count,
                    "complexSeededTextBodies":typedAnchors.count,"repeatedPixelTextBodyEvidence":pixelRun,
                    "pairs":itemPairs,"points":itemDots,"changedPixels":changed-before,"units":units,
                    "localPointContrast": localPointEvidence.sorted { $0.key < $1.key }.map {
                        ["component": $0.key, "box": rect(components[$0.key].box), "contrast": $0.value] as [String: Any]
                    }])
            }
        } catch let stop as Stop {
            result.audit=["agent06Terminal2":"aborted-original-mask-preserved","reason":stop.message,"changedPixels":0,
                          "discardedChangePixels":changed,"sourcePixelsVisited":work,"paintOperations":operations,"pairChecks":pairChecks,"surfacePixelsVisited":surfaceWork]
            return result
        }
        result.audit=["agent06Terminal2":"source-only-terminal-cc-units","changedPixels":changed,"bodyDotPairs":pairCount,
            "terminalPoints":pointCount,"sourcePixelsVisited":work,"paintOperations":operations,"pairChecks":pairChecks,
            "surfacePixelsVisited":surfaceWork,"cachedOCRLineCount":ocrLines.count,"rejections":reasons,"items":traces,
            "outsideOwnerUnconfirmedUnits":unconfirmedOutsideUnits,"cachedOCRPresent":page.savedEvidence["originalOCR"] != nil,
            "missingSourceGeometryItems":page.items.filter { !preserved($0) && ($0["text"] as? String)?.isEmpty == false && bounds($0,w,h) == nil }.count,
            "restoredPixelsRead":false,"labelsRead":false,"evidence":"outside expansion requires independently covered source CCs; mask proximity is not ownership",
            "colorAuthority":"original source RGB only; reconstruction is never read"]
        guard changed > 0 else { return result }
        guard let image=maskImage(output,w,h) else {
            result.audit["agent06Terminal2"]="mask-allocation-failed-original-preserved";result.audit["changedPixels"]=0;return result
        }
        result.replacementMask=image; result.requiresRestoration=true
        return result
    }

    /// Conservative bounding-component/ring observation, not a glyph label.
    /// A one-pixel moat avoids comparing antialias fringes with themselves.
    /// Exposed internally so offline full-inventory probes use the SAME code.
    static func localPointContrast(original: CGImage, box: CGRect) -> Double? {
        guard valid(box), box.width <= 64, box.height <= 64 else { return nil }
        let canvas = CGRect(x: 0, y: 0, width: original.width, height: original.height)
        let inner = box.integral
        guard canvas.contains(inner) else { return nil }
        let outer = inner.insetBy(dx: -4, dy: -4).intersection(canvas).integral
        guard let bytes = rgba(original, outer) else { return nil }
        let moat = inner.insetBy(dx: -1, dy: -1)
        var center: [RGB] = [], ring: [RGB] = []
        let width = Int(outer.width)
        for y in 0..<Int(outer.height) { for x in 0..<width {
            let point = CGPoint(x: outer.minX + Double(x) + 0.5, y: outer.minY + Double(y) + 0.5)
            let value = color(bytes, y * width + x)
            if inner.contains(point) { center.append(value) }
            else if !moat.contains(point) { ring.append(value) }
        } }
        guard !center.isEmpty, ring.count >= 8 else { return nil }
        let a = RGB(r: median(center.map(\.r)), g: median(center.map(\.g)), b: median(center.map(\.b)))
        let b = RGB(r: median(ring.map(\.r)), g: median(ring.map(\.g)), b: median(ring.map(\.b)))
        return a.gap(b)
    }

    private static func itemPolygon(_ item:[String:Any],_ w:Int,_ h:Int)->[CGPoint] {
        let pairs=item["sourcePolygon"] as? [[Double]] ?? []
        guard pairs.allSatisfy({ $0.count == 2 }) else { return [] }
        return ring(pairs.map { CGPoint(x:$0[0],y:$0[1]) },w,h)
    }
    private static func owns(_ point:CGPoint,_ owner:Owner)->Bool {
        owner.box.contains(point) && (owner.polygon.isEmpty || contains(point,owner.polygon))
    }
    private static func cachedOCRLines(_ value:Any?,_ w:Int,_ h:Int)->[Region] {
        guard let data=value as? [String:Any] else { return [] }
        let rows=(data["regions"] as? [[String:Any]] ?? [])+(data["lines"] as? [[String:Any]] ?? [])
        var result:[Region]=[]
        for row in rows {
            let source=row["source"] as? String ?? row["text"] as? String ?? ""
            guard !source.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
                  let confidence=row["confidence"] as? Double,confidence.isFinite,confidence >= 0.5 else { continue }
            let normalized:CGRect
            if let r=row["rect"] as? [String:Double],let x=r["x"],let y=r["y"],let width=r["width"],let height=r["height"] {
                normalized=CGRect(x:x,y:y,width:width,height:height)
            } else if let r=row["sourceBounds"] as? [Double],r.count == 4,r.allSatisfy(\.isFinite) {
                normalized=CGRect(x:r[0],y:r[1],width:r[2],height:r[3])
            } else { continue }
            guard let box=scaled(normalized,w,h),!result.contains(where:{ $0.box.equalTo(box) }) else { continue }
            let pairs=row["polygon"] as? [[Double]] ?? []
            let outer=pairs.allSatisfy({ $0.count == 2 }) ? ring(pairs.map { CGPoint(x:$0[0],y:$0[1]) },w,h) : []
            result.append(Region(kind:4,box:box,outer:outer,holes:[]))
        }
        return result
    }
    /// A source-pixel surface witness inside an independent RF polygon. Its raster is never an erasure mask.
    private static func connectedSurface(_ region:Region,anchor:CGRect,unit:CGRect,rgb:[UInt8],labels:[Int],blocked:[UInt8],roi:CGRect,
        glyph:Double,tolerance:Double,coverage:Double,work:inout Int,limit:Int)throws->Int {
        guard let interior=protect([Region(kind:1,box:region.box,outer:region.outer,holes:region.holes)],[],roi,edges:false) else {
            throw Stop(message:"surface-raster-allocation")
        }
        let w=Int(roi.width),h=Int(roi.height),x0=Int(roi.minX),y0=Int(roi.minY)
        let pad=max(2,min(8,glyph*0.12))
        func samples(_ box:CGRect)->[Int] {
            let points=[CGPoint(x:box.minX-pad,y:box.midY),CGPoint(x:box.maxX+pad,y:box.midY),
                CGPoint(x:box.minX-pad,y:box.minY),CGPoint(x:box.maxX+pad,y:box.minY),
                CGPoint(x:box.minX-pad,y:box.maxY),CGPoint(x:box.maxX+pad,y:box.maxY),
                CGPoint(x:box.midX,y:box.minY-pad),CGPoint(x:box.midX,y:box.maxY+pad)]
            return Set(points.compactMap { point->Int? in
                let x=Int(floor(point.x))-x0,y=Int(floor(point.y))-y0
                guard x >= 0,y >= 0,x < w,y < h else { return nil }
                let i=y*w+x
                return labels[i] == -1 && blocked[i] == 0 && interior[i] != 0 ? i : nil
            }).sorted()
        }
        let a=samples(anchor),b=samples(unit)
        guard a.count >= 4,b.count >= 4 else { return 0 }
        let colors=a.map { color(rgb,$0) }
        let background=RGB(r:median(colors.map(\.r)),g:median(colors.map(\.g)),b:median(colors.map(\.b)))
        func compatible(_ i:Int)->Bool { color(rgb,i).gap(background) <= tolerance }
        guard Double(a.filter(compatible).count)/Double(a.count) >= coverage,
              Double(b.filter(compatible).count)/Double(b.count) >= coverage,let start=a.first(where:compatible) else { return 0 }
        let window=anchor.union(unit).insetBy(dx:-glyph*0.35,dy:-glyph*0.35).intersection(roi)
        let minX=max(0,Int(floor(window.minX))-x0),maxX=min(w,Int(ceil(window.maxX))-x0)
        let minY=max(0,Int(floor(window.minY))-y0),maxY=min(h,Int(ceil(window.maxY))-y0)
        var seen=[UInt8](repeating:0,count:w*h),queue=[start],cursor=0
        seen[start]=1
        while cursor < queue.count {
            let i=queue[cursor],x=i%w,y=i/w;cursor += 1;work += 1
            guard work <= limit else { throw Stop(message:"source-surface-work-budget") }
            for (dx,dy) in [(-1,0),(1,0),(0,-1),(0,1)] {
                let xx=x+dx,yy=y+dy
                guard xx >= minX,yy >= minY,xx < maxX,yy < maxY else { continue }
                let j=yy*w+xx
                if seen[j] == 0 && interior[j] != 0 && blocked[j] == 0 && labels[j] == -1 && compatible(j) {
                    seen[j]=1;queue.append(j)
                }
            }
        }
        return Double(a.filter({ seen[$0] != 0 }).count)/Double(a.count) >= coverage &&
            Double(b.filter({ seen[$0] != 0 }).count)/Double(b.count) >= coverage ? queue.count : 0
    }

    private static func preserved(_ item:[String:Any])->Bool { item["keptLettering"] as? Bool == true || item["sourceTextOnly"] as? Bool == true }
    private static func rect(_ r:CGRect)->[Double] { [Double(r.minX),Double(r.minY),Double(r.width),Double(r.height)] }
    private static func color(_ a:[UInt8],_ i:Int)->RGB { RGB(r:Int(a[i*4]),g:Int(a[i*4+1]),b:Int(a[i*4+2])) }
    private static func median(_ a:[Int])->Int { a.sorted()[(a.count-1)/2] }
    private static func valid(_ r:CGRect)->Bool { !r.isNull && rect(r).allSatisfy(\.isFinite) && r.width > 0 && r.height > 0 }
    private static func area(_ r:CGRect)->Double { valid(r) ? Double(r.width*r.height) : 0 }
    private static func scaled(_ r:CGRect,_ w:Int,_ h:Int)->CGRect? {
        guard valid(r),r.minX >= -1,r.minY >= -1,r.maxX <= 2,r.maxY <= 2 else { return nil }
        let box=CGRect(x:r.minX*Double(w),y:r.minY*Double(h),width:r.width*Double(w),height:r.height*Double(h))
            .intersection(CGRect(x:0,y:0,width:w,height:h))
        return valid(box) ? box : nil
    }
    private static func bounds(_ item:[String:Any],_ w:Int,_ h:Int)->CGRect? {
        guard let a=item["sourceBounds"] as? [Double],a.count == 4,a.allSatisfy(\.isFinite) else { return nil }
        return scaled(CGRect(x:a[0],y:a[1],width:a[2],height:a[3]),w,h)
    }
    private static func ring(_ a:[CGPoint],_ w:Int,_ h:Int)->[CGPoint] {
        guard a.count >= 3,a.allSatisfy({ $0.x.isFinite && $0.y.isFinite && (0...1).contains($0.x) && (0...1).contains($0.y) }) else { return [] }
        return a.map { CGPoint(x:$0.x*Double(w),y:$0.y*Double(h)) }
    }
    private static func glyphSize(_ owner:Owner,_ page:Ensemble100Page)->Double {
        var value=Double(min(owner.box.width,owner.box.height))
        if let s=owner.item["sourceFontSize"] as? Double,s.isFinite,s > 0,page.viewport.width.isFinite,page.viewport.width > 0 {
            value=min(value,s*Double(page.original.width)/page.viewport.width)
        }
        return min(120,max(4,value))
    }
    private static func pointGap(_ p:CGPoint,_ r:CGRect)->Double {
        hypot(max(0,max(r.minX-p.x,p.x-r.maxX)),max(0,max(r.minY-p.y,p.y-r.maxY)))
    }
    private static func contains(_ p:CGPoint,_ ring:[CGPoint])->Bool {
        var hit=false
        for i in ring.indices {
            let a=ring[i],b=ring[(i+1)%ring.count]
            if (a.y > p.y) != (b.y > p.y),p.x < a.x+(p.y-a.y)*(b.x-a.x)/(b.y-a.y) { hit.toggle() }
        }
        return hit
    }
    private static func inside(_ p:CGPoint,_ r:Region)->Bool {
        r.box.contains(p) && (r.outer.isEmpty || contains(p,r.outer)) && !r.holes.contains { contains(p,$0) }
    }
    private static func protect(_ regions:[Region],_ boxes:[CGRect],_ roi:CGRect,edges:Bool)->[UInt8]? {
        let w=Int(roi.width),h=Int(roi.height)
        var out=[UInt8](repeating:0,count:w*h)
        let ok=out.withUnsafeMutableBytes { raw->Bool in
            guard let c=CGContext(data:raw.baseAddress,width:w,height:h,bitsPerComponent:8,bytesPerRow:w,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0) else { return false }
            c.setShouldAntialias(false);c.setFillColor(gray:1,alpha:1);c.setStrokeColor(gray:1,alpha:1)
            c.translateBy(x:-roi.minX,y:roi.maxY);c.scaleBy(x:1,y:-1);c.setLineWidth(4);c.setLineJoin(.round)
            for box in boxes { c.fill(box.insetBy(dx:-1,dy:-1)) }
            for r in regions {
                guard edges ? (r.kind == 2 || r.kind == 3) && !r.outer.isEmpty : r.kind == 1 else { continue }
                if r.outer.isEmpty { c.fill(r.box);continue }
                c.beginPath()
                for polygon in [r.outer]+r.holes where polygon.count >= 3 {
                    c.move(to:polygon[0]);for p in polygon.dropFirst() { c.addLine(to:p) };c.closePath()
                }
                c.drawPath(using:edges ? .stroke : .eoFill)
            }
            return true
        }
        return ok ? out : nil
    }
    private static func rgba(_ image:CGImage,_ roi:CGRect)->[UInt8]? {
        guard let crop=image.cropping(to:roi) else { return nil }
        var out=[UInt8](repeating:0,count:crop.width*crop.height*4)
        let ok=out.withUnsafeMutableBytes { raw->Bool in
            guard let c=CGContext(data:raw.baseAddress,width:crop.width,height:crop.height,bitsPerComponent:8,bytesPerRow:crop.width*4,
                space:CGColorSpace(name:CGColorSpace.sRGB)!,bitmapInfo:CGBitmapInfo.byteOrder32Big.rawValue|CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            let r=CGRect(x:0,y:0,width:crop.width,height:crop.height)
            c.setFillColor(gray:1,alpha:1);c.fill(r);c.interpolationQuality = .none;c.draw(crop,in:r);return true
        }
        return ok ? out : nil
    }
    private static func gray(_ image:CGImage)->[UInt8]? {
        var out=[UInt8](repeating:0,count:image.width*image.height)
        let ok=out.withUnsafeMutableBytes { raw->Bool in
            guard let c=CGContext(data:raw.baseAddress,width:image.width,height:image.height,bitsPerComponent:8,bytesPerRow:image.width,
                space:CGColorSpaceCreateDeviceGray(),bitmapInfo:0) else { return false }
            c.interpolationQuality = .none;c.draw(image,in:CGRect(x:0,y:0,width:image.width,height:image.height));return true
        }
        return ok ? out : nil
    }
    private static func maskImage(_ out:[UInt8],_ w:Int,_ h:Int)->CGImage? {
        guard let provider=CGDataProvider(data:Data(out) as CFData) else { return nil }
        return CGImage(width:w,height:h,bitsPerComponent:8,bitsPerPixel:8,bytesPerRow:w,space:CGColorSpaceCreateDeviceGray(),
            bitmapInfo:CGBitmapInfo(rawValue:0),provider:provider,decode:nil,shouldInterpolate:false,intent:.defaultIntent)
    }
}
