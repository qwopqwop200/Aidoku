import CoreGraphics
import CoreText
import Foundation

/// Gives EACH upstream paragraph an independent local placement contract.
/// Compile alongside Agent02.swift. No inference, labels, file access or page-specific behavior.
enum EnsembleCandidate02Next: Ensemble100Candidate {
    static var defaults: [String: Double] {
        EnsembleCandidate02.defaults.merging([
            "placementEnabled": 1, "reanchor": 1,
            "reachXEm": 3, "reachYEm": 0.75, "preferredWidthEm": 6,
            "centerDriftEm": 0.75, "neighborGapEm": 0.45, "haloEm": 0.22,
            "sourceTopAnchorWithoutBalloon": 1, "sourceTopDriftEm": 0.25,
            "sourceTopOpenSurfaceWitness": 1, "sourceTopOpenReachEm": 3, "sourceTopSurfaceTolerance": 36,
            "closedSourceSurfaceCapacity": 0
        ]) { _, new in new }
    }

    private struct Item {
        let index: Int
        let raw: [String: Any]
        let source: CGRect
        let anchor: CGRect
        let font: Double
        let em: Double
        let line: Double
        let halo: Double
        let originalFrame: CGRect?
        let movable: Bool
        var key: String { "paragraph:\(index):\(raw["id"] as? String ?? "")" }
    }
    private struct Ownership {
        var query: Int?
        var polygons: [Ensemble100RFRegion] = []
        var status = "missing-polygon;OCR-local-fallback"
    }

    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func rect(_ value: Any?) -> CGRect? {
        guard let a = value as? [Any], a.count == 4 else { return nil }
        let v = a.compactMap(number)
        guard v.count == 4, v[2] > 0, v[3] > 0 else { return nil }
        return CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
    }
    private static func array(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    private static func scale(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }
    private static func frame(_ raw: [String: Any]) -> CGRect? {
        guard let x = number(raw["x"]), let y = number(raw["y"]),
              let w = number(raw["width"]), let h = number(raw["height"]), w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
    private static func inside(_ p: CGPoint, _ ring: [CGPoint]) -> Bool {
        guard ring.count >= 3, ring.allSatisfy({ $0.x.isFinite && $0.y.isFinite }) else { return false }
        var hit = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { hit.toggle() }
        }
        return hit
    }
    private static func inside(_ p: CGPoint, _ regions: [Ensemble100RFRegion]) -> Bool {
        regions.contains { $0.bounds.contains(p) && inside(p, $0.exterior) && !$0.holes.contains { inside(p, $0) } }
    }
    private static func ownership(_ item: Item, regions: [Ensemble100RFRegion], confidence: Double) -> Ownership {
        let polygons = regions.filter { $0.classID == 2 && $0.exterior.count >= 3 && $0.confidence.isFinite && $0.confidence >= confidence }
        var scores: [(Int, Double)] = []
        for id in Set(polygons.map(\.queryID)) {
            let parts = polygons.filter { $0.queryID == id }
            var hits = 0
            for y in 0..<7 { for x in 0..<7 {
                let point = CGPoint(x: item.source.minX + (Double(x) + 0.5) / 7 * item.source.width,
                                    y: item.source.minY + (Double(y) + 0.5) / 7 * item.source.height)
                if inside(point, parts) { hits += 1 }
            } }
            scores.append((id, Double(hits) / 49))
        }
        scores.sort { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 > $1.1 }
        guard let best = scores.first, best.1 >= 0.9 else {
            return Ownership(status: (scores.first?.1 ?? 0) >= 0.35 ? "partial-polygon;OCR-local-fallback" : "missing-polygon;OCR-local-fallback")
        }
        guard !scores.dropFirst().contains(where: { $0.1 >= 0.8 }) else {
            return Ownership(status: "conflicting-polygons;OCR-local-fallback")
        }
        return Ownership(query: best.0, polygons: polygons.filter { $0.queryID == best.0 }, status: "polygon-supported;not-paragraph-ownership")
    }
    private static func measuredHeight(_ text: String, width: Double, item: Item) -> Double? {
        guard width > 0, width.isFinite else { return nil }
        let font = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, item.font, nil)
        var pitch = item.line
        let para = withUnsafePointer(to: &pitch) { pointer in
            let settings = [CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<Double>.size, value: pointer),
                            CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<Double>.size, value: pointer)]
            return CTParagraphStyleCreate(settings, settings.count)
        }
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): para
        ])
        let setter = CTFramesetterCreateWithAttributedString(attributed)
        var fit = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: text.utf16.count),
            nil, CGSize(width: width, height: 1_000_000), &fit)
        guard fit.length == text.utf16.count, size.height.isFinite else { return nil }
        return ceil(max(item.line, size.height))
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String) -> Double {
            let fallback = defaults[key] ?? 0
            guard let n = parameters[key], n.isFinite else { return fallback }
            return max(0, min(n, 4_194_304))
        }
        guard p("enabled") > 0 else { return Ensemble100Proposal(items: page.items, audit: ["candidate": "02Next", "status": "disabled"]) }
        let sourcePalette = NativeOriginalSourcePalette(original: page.original)
        // Paragraph membership is finalized before translation. Rendering may
        // place owners independently, but never fuse or reconstruct their text.
        var result = Ensemble100Proposal(items: page.items, audit: [:])
        let fusionAudit: [String: Any] = ["status": "removed;upstream-owners-preserved", "joins": []]
        guard p("placementEnabled") > 0, page.viewport.width.isFinite, page.viewport.height.isFinite,
              page.viewport.width > 0, page.viewport.height > 0, result.items.count <= Int(min(1024, p("maxItems"))) else {
            result.audit = ["candidate": "02Next", "status": "placement-disabled-or-invalid-budget", "fusion": fusionAudit]
            return result
        }
        let pageRect = CGRect(origin: .zero, size: page.viewport)
        let items: [Item?] = result.items.enumerated().map { index, raw in
            guard let source = rect(raw["sourceBounds"]), CGRect(x: 0, y: 0, width: 1, height: 1).contains(source) else { return nil }
            let f = number(raw["fontSize"]) ?? 10
            guard f > 0, f <= max(page.viewport.width, page.viewport.height) else { return nil }
            let em = min(max(f * 0.5, number(raw["sourceFontSize"]) ?? f), f * 2)
            let halo = max(p("haloEm") * f, max(0, number(raw["typesettingOutlineWidth"]) ?? 0),
                           2 * page.viewport.width / Double(page.original.width))
            let line = max(f, number(raw["lineHeight"]) ?? f * 1.2)
            let movable = number(raw["fontSize"]) != nil && (number(raw["lineHeight"]) ?? 0) > 0 &&
                raw["keptLettering"] as? Bool != true && raw["sourceTextOnly"] as? Bool != true &&
                raw["vertical"] as? Bool != true && raw["uprightQuadText"] as? Bool != true &&
                raw["drawsUprightQuadText"] as? Bool != true && abs(number(raw["rotation"]) ?? 0) < 0.01 &&
                !(raw["text"] as? String ?? "").isEmpty
            return Item(index: index, raw: raw, source: source, anchor: scale(source, page.viewport), font: f,
                em: em, line: line, halo: halo, originalFrame: frame(raw), movable: movable)
        }
        let owners = items.map { $0.map { ownership($0, regions: page.rfRegions, confidence: p("rfConfidence")) } }
        let domains: [CGRect?] = items.map { item in
            guard let item else { return nil }
            var domain = item.anchor.insetBy(dx: -min(8, p("reachXEm")) * item.em,
                                           dy: -min(4, p("reachYEm")) * item.em).intersection(pageRect)
            if let owner = owners[item.index], owner.query != nil {
                let bounds = owner.polygons.reduce(CGRect.null) { $0.union(scale($1.bounds, page.viewport)) }
                let cap = domain.intersection(bounds)
                if cap.contains(item.anchor) { domain = cap }
            }
            return domain
        }
        var records: [[String: Any]] = []
        var closedSurfaces=[[String:Any]]()
        for item in items.compactMap({ $0 }) where item.movable {
            guard var domain = domains[item.index], domain.contains(item.anchor) else { continue }
            var neighbors: [[String: Any]] = [], conflicts: [Int] = []
            let owner = owners[item.index]!
            for other in items.compactMap({ $0 }) where other.index != item.index {
                guard let otherDomain = domains[other.index], domain.intersects(otherDomain) else { continue }
                let xGap = max(item.anchor.minX, other.anchor.minX) - min(item.anchor.maxX, other.anchor.maxX)
                let yGap = max(item.anchor.minY, other.anchor.minY) - min(item.anchor.maxY, other.anchor.maxY)
                var neighbor: [String: Any] = ["itemIndex": other.index, "itemID": other.raw["id"] as? String ?? "",
                    "paragraphOwnerKey": other.key, "sourceBoundsNormalized": array(other.source), "anchorRect": array(other.anchor),
                    "haloMargin": other.halo, "kind": other.movable ? "translation" : "preserved-source",
                    "sharedRFIsNotMergePermission": true]
                if xGap < 0 && yGap < 0 {
                    conflicts.append(other.index); neighbor["separationAxis"] = "overlapping-source;defer"
                } else {
                    let horizontal = xGap >= 0 && (yGap < 0 || xGap >= yGap)
                    let sourceGap = horizontal ? xGap : yGap
                    let clearance = min(sourceGap * 0.5, min(2, p("neighborGapEm")) * max(item.em, other.em))
                    let before = horizontal ? item.anchor.midX < other.anchor.midX : item.anchor.midY < other.anchor.midY
                    let near = horizontal ? min(item.anchor.maxX, other.anchor.maxX) : min(item.anchor.maxY, other.anchor.maxY)
                    let far = horizontal ? max(item.anchor.minX, other.anchor.minX) : max(item.anchor.minY, other.anchor.minY)
                    let mid = (near + far) / 2
                    if horizontal {
                        if before { domain.size.width = min(domain.maxX, mid - clearance / 2) - domain.minX }
                        else { let right = domain.maxX; domain.origin.x = max(domain.minX, mid + clearance / 2); domain.size.width = right - domain.minX }
                    } else {
                        if before { domain.size.height = min(domain.maxY, mid - clearance / 2) - domain.minY }
                        else { let bottom = domain.maxY; domain.origin.y = max(domain.minY, mid + clearance / 2); domain.size.height = bottom - domain.minY }
                    }
                    neighbor["separationAxis"] = horizontal ? "x" : "y"
                    neighbor["separator"] = mid; neighbor["clearance"] = clearance
                }
                neighbors.append(neighbor)
            }
            let feasible = conflicts.isEmpty && domain.width > 0 && domain.height > 0 && domain.contains(item.anchor)
            var sourceTop = feasible && p("sourceTopAnchorWithoutBalloon")==1 &&
                owner.status=="missing-polygon;OCR-local-fallback" && item.raw["sourceVertical"] as? Bool==true &&
                item.raw["balloonInterior"]==nil && item.raw["balloonUnit"]==nil
            var sourceTopWitness:[String:Any]?
            if sourceTop,p("sourceTopOpenSurfaceWitness")==1 {
                let observation=sourcePalette.observeCached(context:NativeMainEnsembleCacheContext.from(page),originalGeometry:item.raw)
                let prediction=observation.rawPrediction
                let confidence=(prediction?["confidence"] as? [String:Any])?["background"] as? Double ?? 0
                if let background=prediction?["background"] as? [Double],confidence>=0.75 {
                    sourceTopWitness=NativeSourceTopSurfaceWitness.measure(original:page.original,
                        source:scale(item.source,CGSize(width:page.original.width,height:page.original.height)),
                        fontPixels:CGFloat(item.em*Double(page.original.width)/Double(page.viewport.width)),background:background,
                        reachEm:p("sourceTopOpenReachEm"),tolerance:p("sourceTopSurfaceTolerance"),
                        closedCapacityMask:p("closedSourceSurfaceCapacity")==1 ? page.removalMask : nil)
                    if let capacity=sourceTopWitness?["closedSurfaceCapacity"] as? [String:Any],capacity["accepted"] as? Bool==true {
                        closedSurfaces.append(capacity)
                    }
                } else {
                    sourceTopWitness=["accepted":false,"originalPixelsMeasured":false,"reason":"original-background-prediction-unknown-or-uncertain"]
                }
                sourceTop=sourceTopWitness?["accepted"] as? Bool==true
            }
            let originalMembers = item.raw["agent02MemberIndices"] as? [Int] ?? [item.index]
            var metadata: [String: Any] = ["version": 1, "coordinateSpace": "viewport-top-left",
                "paragraphOwnerKey": item.key, "outputIndex": item.index, "inputMemberIndices": originalMembers,
                "sourceBoundsNormalized": array(item.source), "anchorRect": array(item.anchor),
                "protectedNeighbors": neighbors, "paragraphsRemainSeparate": true, "mergeParagraphs": false,
                "boundsIncludeHalo": true, "haloMargin": item.halo, "feasible": feasible,
                "rfStatus": owner.status, "sharedRFDoesNotShareParagraphOwner": true,
                "conflictingSourceIndices": conflicts, "maxCenterDrift": min(3, p("centerDriftEm")) * item.em,
                "requiresRetainedInkAndHaloCheck": true, "requiresCompleteUTF16": true]
            if let original = item.originalFrame { metadata["savedDisplayRect"] = array(original) }
            if let sourceTopWitness {metadata["sourceTopSurfaceWitness"]=sourceTopWitness}
            if sourceTop {
                metadata["version"]=2
                metadata["verticalAnchorMetric"]="source-top"
                metadata["maxTopDrift"]=min(1,p("sourceTopDriftEm"))*item.em
                metadata["verticalAnchorEvidence"]="no supported balloon; original OCR top placement proxy, not proof of absent balloon"
            }
            if let query = owner.query {
                metadata["rfQueryID"] = query
                metadata["rfPolygonsNormalized"] = owner.polygons.map { region -> [String: Any] in
                    ["exterior": region.exterior.map { [$0.x, $0.y] }, "holes": region.holes.map { $0.map { [$0.x, $0.y] } }]
                }
                metadata["rfPolygonFinalCheckRequired"] = true // A bounds cap is not an inscribed polygon.
            }
            if feasible {
                metadata["allowedRect"] = array(domain)
                let drift = min(3, p("centerDriftEm")) * item.em
                let maxCenteredWidth = 2 * min(item.anchor.midX - domain.minX + drift, domain.maxX - item.anchor.midX + drift)
                let width = min(domain.width, maxCenteredWidth, max(item.anchor.width, min(16, p("preferredWidthEm")) * item.font))
                let leftPadding = number(item.raw["paddingLeft"]) ?? 0
                let rightPadding = number(item.raw["paddingRight"]) ?? 0
                let topPadding = number(item.raw["paddingTop"]) ?? 0
                let bottomPadding = number(item.raw["paddingBottom"]) ?? 0
                let needed = measuredHeight(item.raw["text"] as? String ?? "", width: width - 2 * item.halo - leftPadding - rightPadding, item: item)
                    .map { $0 + 2 * item.halo + topPadding + bottomPadding }
                let maxCenteredHeight = 2 * min(item.anchor.midY - domain.minY + drift, domain.maxY - item.anchor.midY + drift)
                let height = min(domain.height, maxCenteredHeight, max(item.line + 2 * item.halo, needed ?? domain.height))
                let x = max(domain.minX, min(item.anchor.midX - width / 2, domain.maxX - width))
                let y = max(domain.minY, min(sourceTop ? item.anchor.minY : item.anchor.midY - height / 2, domain.maxY - height))
                let preferred = CGRect(x: x, y: y, width: width, height: height)
                let fits = needed.map { $0 <= height } ?? false
                metadata["preferredRect"] = array(preferred)
                metadata["capacity"] = fits ? "estimated-full-text-fit;final-check-required" : "insufficient;coordinate-peers-without-merging"
                metadata["needsJointLayout"] = !fits
                metadata["measurementAuthority"] = "CoreText estimate at unchanged font;not rendered completeness"
                if p("reanchor") > 0 {
                    result.items[item.index]["x"] = Double(preferred.minX); result.items[item.index]["y"] = Double(preferred.minY)
                    result.items[item.index]["width"] = Double(preferred.width); result.items[item.index]["height"] = Double(preferred.height)
                }
            } else {
                metadata["capacity"] = "unresolved-source-overlap;retain-item-and-report"
                metadata["needsJointLayout"] = true
            }
            result.items[item.index]["sourceNearLayout"] = metadata
            records.append(["outputIndex": item.index, "paragraphOwnerKey": item.key, "feasible": feasible,
                            "neighborCount": neighbors.count, "capacity": metadata["capacity"]!])
        }
        if p("closedSourceSurfaceCapacity")==1 {
            let originalSize=CGSize(width:page.original.width,height:page.original.height)
            for item in items.compactMap({$0}) where item.movable && owners[item.index]?.query==nil {
                guard let near=result.items[item.index]["sourceNearLayout"] as? [String:Any],
                      near["rfStatus"] as? String=="missing-polygon;OCR-local-fallback",
                      let allowed=rect(near["allowedRect"]),item.raw["balloonInterior"]==nil,item.raw["balloonUnit"]==nil else{continue}
                var candidates=[CGRect]()
                for cap in closedSurfaces {
                    guard let pixels=rect(cap["rectOutputPixels"]) else{continue}
                    let body=CGRect(x:pixels.minX/originalSize.width*page.viewport.width,
                        y:pixels.minY/originalSize.height*page.viewport.height,
                        width:pixels.width/originalSize.width*page.viewport.width,
                        height:pixels.height/originalSize.height*page.viewport.height)
                    guard body.contains(item.anchor),!candidates.contains(body) else{continue}
                    candidates.append(body)
                }
                guard candidates.count==1 else{continue}
                let body=candidates[0],slot=body.intersection(allowed)
                guard slot.contains(item.anchor),slot.width>0,slot.height>0 else{continue}
                if near["version"] as? Int==2 {
                    var centered=near
                    centered["version"]=1
                    centered.removeValue(forKey:"verticalAnchorMetric");centered.removeValue(forKey:"maxTopDrift")
                    centered["sourceTopVeto"]="independent closed original surface overrides locally open top proposal"
                    if let preferred=rect(near["preferredRect"]) {
                        let y=max(allowed.minY,min(item.anchor.midY-preferred.height/2,allowed.maxY-preferred.height))
                        let frame=CGRect(x:preferred.minX,y:y,width:preferred.width,height:preferred.height)
                        centered["preferredRect"]=array(frame);result.items[item.index]["y"]=Double(y)
                    }
                    result.items[item.index]["sourceNearLayout"]=centered
                }
                result.items[item.index]["originalClosedSurfaceCapacity"]=[
                    "version":1,"slotNormalized":[slot.minX/page.viewport.width,slot.minY/page.viewport.height,
                        slot.width/page.viewport.width,slot.height/page.viewport.height],
                    "bodyNormalized":[body.minX/page.viewport.width,body.minY/page.viewport.height,
                        body.width/page.viewport.width,body.height/page.viewport.height],
                    "authority":"original uniform rectangular enclosure plus independent source-near paragraph slot; not semantic/RF balloon; no sentence merge"] as [String:Any]
            }
        }
        result.audit = ["candidate": "02Next", "fusion": fusionAudit, "placement": records,
            "closedOriginalSurfaceCandidates":closedSurfaces,
            "originalOCR": page.savedEvidence["originalOCR"] == nil ? "missing;raw-geometry-used;no-inference" : "cached;raw-geometry-used",
            "invalidSourceIndices": items.indices.filter { items[$0] == nil },
            "interface": ["consumer": "Agent04Next", "rawKey": "sourceNearLayout", "version": 1,
                "geometry": "viewport-top-left except explicitly normalized sourceBounds/polygons",
                "require": "constrain final retained glyphs+halo to allowedRect and RF polygon, honor separators and center drift; preserve text/order",
                "jointLayout": "coordinate protectedNeighbors;never union paragraph sourceBounds, owners or text",
                "failure": "report unresolved capacity/overlap;no clipping, token omission, invisible stroke or unconstrained page-edge fallback"],
            "evidence": "synthetic/component-ready;parent owns actual-page evaluation"]
        return result
    }
}
