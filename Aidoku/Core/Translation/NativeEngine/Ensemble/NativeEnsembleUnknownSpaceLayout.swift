import CoreGraphics
import Foundation

/// Optional pre04 display-frame seed, not a balloon detector or fit certificate.
/// Source geometry bounds uncertainty, never establishes free background space.
/// promptVersion: technical-review-v1. No image scan, inference or text changes.
enum NativeEnsembleUnknownSpaceLayout: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 0, "widthGrowth": 1.5, "heightGrowth": 1.25,
        "minimumSourceAspect": 1.5, "inflationTrigger": 1.5,
        "bodyMargin": 0.25, "bodyMinConfidence": 0.78, "minimumRepeatedCells": 6,
        "safetyPixels": 1, "neighborGapPixels": 2, "maxStartDriftFraction": 0.5,
        "assumed04MaximumWidthGrowth": 2, "minimumSeedSourceFraction": 0.35,
        "maxItems": 512
    ]

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        var p = defaults
        let limits: [String: ClosedRange<Double>] = ["enabled": 0...1, "widthGrowth": 1...2.5,
            "heightGrowth": 1...2, "minimumSourceAspect": 1.2...4, "inflationTrigger": 1.1...3,
            "bodyMargin": 0...0.75, "bodyMinConfidence": 0.70...0.87, "minimumRepeatedCells": 4...24,
            "safetyPixels": 0...4, "neighborGapPixels": 0...8, "maxStartDriftFraction": 0...1,
            "assumed04MaximumWidthGrowth": 1...3, "minimumSeedSourceFraction": 0.2...1, "maxItems": 1...1024]
        for (key, range) in limits {
            if let value = parameters[key], value.isFinite { p[key] = min(range.upperBound, max(range.lowerBound, value)) }
        }
        var output = page.items, records: [[String: Any]] = [], changed = 0
        let viewport = page.viewport, pageRect = CGRect(origin: .zero, size: viewport)
        let validPage = viewport.width.isFinite && viewport.height.isFinite && viewport.width > 0 && viewport.height > 0
        let scale = validPage ? min(CGFloat(page.original.width) / viewport.width, CGFloat(page.original.height) / viewport.height) : 0
        let supportedPage = validPage && scale.isFinite && scale > 0 && page.items.count <= Int(p["maxItems"]!)
        let sources = page.items.map { normalized($0["sourceBounds"], viewport: viewport) }
        let frames = page.items.map(frame)
        let ids = page.items.compactMap { $0["id"] as? String }
        let counts = Dictionary(ids.map { ($0, 1) }, uniquingKeysWith: +)
        let protectedKeys = Set(page.savedEvidence["unknownSpaceProtectedOwnerKeys"] as? [String] ?? [])
        for index in page.items.indices {
            let raw = page.items[index]
            var record: [String: Any] = ["index": index, "status": "unchanged", "qualityAccepted": false]
            func keep(_ reason: String) { record["reason"] = reason; records.append(record) }
            guard p["enabled"]! > 0 else { keep("disabled"); continue }
            guard supportedPage else { keep("invalid-viewport-or-item-budget"); continue }
            guard raw["keptLettering"] as? Bool != true, raw["sourceTextOnly"] as? Bool != true,
                  let text = raw["text"] as? String, !text.isEmpty else { keep("preserved-or-untranslated"); continue }
            guard let id = raw["id"] as? String, !id.isEmpty, counts[id] == 1 else { keep("ambiguous-owner"); continue }
            if protectedKeys.contains(id) || joint(raw) { keep("explicit-joint-or-hierarchy-contract"); continue }
            if raw["ensembleLockLayout"] as? Bool == true { keep("already-certified-layout"); continue }
            if let alignment = raw["textAlign"] as? String, alignment != "center" { keep("explicit-noncenter-alignment"); continue }
            if raw["rotation"] != nil && number(raw["rotation"]) == nil { keep("invalid-rotation"); continue }
            guard raw["sourceVertical"] as? Bool == true, raw["vertical"] as? Bool != true,
                  abs(number(raw["rotation"]) ?? 0) < 0.001 else { keep("nonvertical-source-or-rotated-display"); continue }
            if let kind = raw["sourceLettering"] as? String,
               ["title", "display", "caption", "sfx"].contains(kind.lowercased()) { keep("explicit-lettering-role"); continue }
            guard let source = sources[index], let base = frames[index], pageRect.contains(source), pageRect.contains(base) else {
                keep("missing-or-outside-source-display-geometry"); continue
            }
            guard source.height / source.width >= CGFloat(p["minimumSourceAspect"]!),
                  base.width / source.width >= CGFloat(p["inflationTrigger"]!) else { keep("ordinary-or-not-materially-inflated"); continue }
            // Any supplied plausible native/model contour is left to03/04. A
            // malformed declared contour is ambiguous, not permission to shrink.
            if raw["balloonInterior"] != nil || (raw["balloonUnit"] as? [String: Any])?["interior"] != nil {
                keep("declared-contour-preserved-or-ambiguous"); continue
            }
            var allowed = source.insetBy(dx: -source.width * CGFloat(p["widthGrowth"]! - 1) / 2,
                dy: -source.height * CGFloat(p["heightGrowth"]! - 1) / 2).intersection(pageRect)
            let observedBody = body(raw, page: page, parameters: p)
            // The observation is glyph BODY width, not calibrated font em.
            // If unavailable, the body margin is zero; bbox/raw/sourceFont never
            // fill that measurement slot. Pixel safety remains in source units.
            let bodyMargin = (observedBody ?? 0) * CGFloat(p["bodyMargin"]!)
            let safety = CGFloat(p["safetyPixels"]!) / scale
            allowed = allowed.insetBy(dx: -bodyMargin - safety, dy: -bodyMargin - safety).intersection(pageRect)
            let widthBudget = allowed.width
            if let nearValue = raw["sourceNearLayout"] {
                guard let near = nearValue as? [String: Any], number(near["version"]) == 1,
                      near["coordinateSpace"] as? String == "viewport-top-left", near["feasible"] as? Bool == true,
                      near["mergeParagraphs"] as? Bool == false, near["paragraphsRemainSeparate"] as? Bool == true,
                      number(near["outputIndex"]) == CGFloat(index), near["boundsIncludeHalo"] as? Bool == true,
                      let declared = normalized(near["sourceBoundsNormalized"], viewport: viewport), equal(declared, source),
                      let anchor = rectangle(near["anchorRect"]), equal(anchor, source),
                      let domain = rectangle(near["allowedRect"]), pageRect.contains(domain), domain.contains(source),
                      let neighbors = near["protectedNeighbors"] as? [[String: Any]], neighbors.count <= page.items.count,
                      let owner = near["paragraphOwnerKey"] as? String, !owner.isEmpty,
                      let halo = number(near["haloMargin"]), halo >= 0, halo <= min(domain.width, domain.height) / 2,
                      let drift = number(near["maxCenterDrift"]), drift >= 0,
                      drift <= max(viewport.width, viewport.height),
                      abs(base.midX - anchor.midX) <= drift + 0.001 else { keep("ambiguous-source-near-contract"); continue }
                if near["rfPolygonFinalCheckRequired"] as? Bool == true ||
                    (near["rfPolygonsNormalized"] != nil && (near["rfPolygonsNormalized"] as? [Any])?.isEmpty != true) {
                    keep("explicit-polygon-domain-preserved"); continue
                }
                allowed = allowed.intersection(domain)
                var invalid = page.items.indices.contains { peer in
                    peer != index && (page.items[peer]["sourceNearLayout"] as? [String: Any])?["paragraphOwnerKey"] as? String == owner
                }
                for neighbor in neighbors {
                    guard let position = number(neighbor["itemIndex"]), position >= 0, position < CGFloat(page.items.count),
                          position.rounded(.down) == position, Int(position) != index,
                          let key = neighbor["paragraphOwnerKey"] as? String, !key.isEmpty, key != owner,
                          let rect = rectangle(neighbor["anchorRect"]), let actual = sources[Int(position)],
                          let bound = normalized(neighbor["sourceBoundsNormalized"], viewport: viewport),
                          equal(rect, actual), equal(bound, actual), let margin = number(neighbor["haloMargin"]), margin >= 0,
                          margin <= max(viewport.width, viewport.height), let axis = neighbor["separationAxis"] as? String,
                          axis == "x" || axis == "y", let separator = number(neighbor["separator"]),
                          let clearance = number(neighbor["clearance"]), clearance >= 0 else { invalid = true; break }
                    if let otherKey = (page.items[Int(position)]["sourceNearLayout"] as? [String: Any])?["paragraphOwnerKey"] as? String,
                       otherKey != key { invalid = true; break }
                    if axis == "x" {
                        allowed = anchor.midX < rect.midX ? clip(allowed, right: separator - clearance / 2)
                            : clip(allowed, left: separator + clearance / 2)
                    } else {
                        allowed = anchor.midY < rect.midY ? clip(allowed, bottom: separator - clearance / 2)
                            : clip(allowed, top: separator + clearance / 2)
                    }
                }
                if invalid { keep("ambiguous-source-near-neighbors"); continue }
            }
            var blocked = false, neighbors = 0
            let gap = CGFloat(p["neighborGapPixels"]!) / scale
            for peer in page.items.indices where peer != index {
                let other = page.items[peer]
                guard (other["text"] as? String)?.isEmpty == false || other["keptLettering"] as? Bool == true ||
                    other["sourceTextOnly"] as? Bool == true || other["pendingSourceComponent"] as? Bool == true else { continue }
                guard let anchor = sources[peer] ?? frames[peer] else { blocked = true; break }
                // Reserve both source and existing display space. We do not
                // move another paragraph or assume an oversized peer will fit.
                let obstacles = [anchor, frames[peer]].compactMap { $0 }
                for obstacle in obstacles where obstacle.insetBy(dx: -gap, dy: -gap).intersects(allowed) {
                    neighbors += 1
                    let padded = obstacle.insetBy(dx: -gap, dy: -gap)
                    if padded.intersects(source) { blocked = true; break }
                    if padded.maxX <= source.minX { allowed = clip(allowed, left: padded.maxX) }
                    else if padded.minX >= source.maxX { allowed = clip(allowed, right: padded.minX) }
                    else if padded.maxY <= source.minY { allowed = clip(allowed, top: padded.maxY) }
                    else if padded.minY >= source.maxY { allowed = clip(allowed, bottom: padded.minY) }
                    else { blocked = true; break }
                }
                if blocked { break }
            }
            guard !blocked, !allowed.isEmpty, allowed.contains(source) else { keep("ambiguous-or-dense-neighbor-protection"); continue }
            let startDrift = abs(base.minY - source.minY) / source.height
            guard startDrift <= CGFloat(p["maxStartDriftFraction"]!), base.minY >= allowed.minY, base.minY < allowed.maxY else {
                keep("original-start-outside-source-near-bounds"); continue
            }
            // Keep horizontal alignment (raw center) and the original raw top.
            // 04 re-expands seed.width by maximumWidthGrowth. Counter that
            // declared factor here, rather than quietly widening the budget.
            let centeredWidth = 2 * min(base.midX - allowed.minX, allowed.maxX - base.midX)
            let finalWidthBudget = min(widthBudget, centeredWidth)
            let seedWidth = min(base.width, finalWidthBudget / CGFloat(p["assumed04MaximumWidthGrowth"]!))
            let height = min(base.height, allowed.maxY - base.minY)
            guard seedWidth >= source.width * CGFloat(p["minimumSeedSourceFraction"]!), height > 0,
                  seedWidth < base.width * 0.98 else { keep("no-useful-safe-bounded-seed"); continue }
            let proposed = CGRect(x: base.midX - seedWidth / 2, y: base.minY, width: seedWidth, height: height)
            guard allowed.contains(proposed) else { keep("proposal-outside-uncertain-bounds"); continue }
            output[index]["x"] = Double(proposed.minX); output[index]["y"] = Double(proposed.minY)
            output[index]["width"] = Double(proposed.width); output[index]["height"] = Double(proposed.height)
            changed += 1
            record.merge(["status": "proposed-uncertain-source-space", "reason": "inflated-vertical-source-proxy-without-contour",
                "before": array(base), "after": array(proposed), "sourceProxy": array(source), "uncertainBounds": array(allowed),
                "anticipated04MaxWidth": Double(finalWidthBudget), "assumed04MaximumWidthGrowth": p["assumed04MaximumWidthGrowth"]!,
                "bodyWidthViewport": observedBody.map(Double.init) as Any? ?? NSNull(), "bodyMarginViewport": Double(bodyMargin),
                "calibratedSourceEm": NSNull(), "bodyMeasurement": observedBody == nil ? "unavailable-no-bbox-or-font-substitution" : "bound-repeated-original-glyph-body-not-em",
                "neighborObstacleChecks": neighbors, "rawCenterXAndStartYUnchanged": true,
                "sourceBoundsAreBalloonTruth": false, "fitsCertified": false,
                "downstreamHeightMayOverrideSeed": true, "requiresCompleteGlyphAndMandatoryStrokeCheck": true]) { _, new in new }
            records.append(record)
        }
        return .init(items: output, audit: ["unknownSpaceLayout": records, "inputItemCount": page.items.count,
            "outputItemCount": output.count, "proposedItems": changed, "parameters": p,
            "measurementAuthority": "source/display geometry proxy plus optional prior pixel observation; no image inspection or inference",
            "sourceOrTextMutation": false, "qualityAccepted": false, "promptVersion": "technical-review-v1"])
    }

    private static func joint(_ raw: [String: Any]) -> Bool {
        let keys = ["sourceRelativeTypography", "jointGroupKey", "paragraphGroupKey", "jointLayoutGroupKey",
            "sourceAlignedCaptionLane", "sourceAnnotationRelation", "sourceParagraphGroup", "ensembleParagraphGroup"]
        if keys.contains(where: { raw[$0] != nil }) { return true }
        if let near = raw["sourceNearLayout"] as? [String: Any],
           let members = near["inputMemberIndices"] as? [Int], members.count > 1 { return true }
        return false
    }
    private static func body(_ raw: [String: Any], page: Ensemble100Page, parameters p: [String: Double]) -> CGFloat? {
        guard !page.sourceSHA256.isEmpty, let o = raw["sourceGlyphBodyObservation"] as? [String: Any],
              number(o["version"]) == 1, o["status"] as? String == "supported", o["sourceSHA256"] as? String == page.sourceSHA256,
              let confidence = number(o["confidence"]), confidence >= CGFloat(p["bodyMinConfidence"]!), confidence <= 1,
              let expected = normalized(raw["sourceBounds"], viewport: page.viewport),
              let bound = normalized(o["sourceBoundsNormalized"], viewport: page.viewport), equal(expected, bound),
              let e = o["sourceEvidence"] as? [String: Any], e["rawFontAndSourceFontAreNotTruth"] as? Bool == true,
              e["sourceBBoxUsedForSizeVote"] as? Bool == false, let m = e["pixelMeasurement"] as? [String: Any],
              let count = number(m["mainRepeatedCells"]), count >= CGFloat(p["minimumRepeatedCells"]!),
              let width = number(e["observedGlyphWidthViewport"]), width > 0, width <= expected.width * 1.5 else { return nil }
        return width
    }
    private static func number(_ value: Any?) -> CGFloat? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return CGFloat(n.doubleValue)
    }
    private static func rectangle(_ value: Any?) -> CGRect? {
        guard let a = value as? [Any], a.count == 4 else { return nil }
        let n = a.compactMap(number)
        guard n.count == 4, n[2] > 0, n[3] > 0 else { return nil }
        return CGRect(x: n[0], y: n[1], width: n[2], height: n[3])
    }
    private static func normalized(_ value: Any?, viewport: CGSize) -> CGRect? {
        guard let r = rectangle(value), CGRect(x: 0, y: 0, width: 1, height: 1).contains(r),
              viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0 else { return nil }
        return r.applying(CGAffineTransform(scaleX: viewport.width, y: viewport.height))
    }
    private static func frame(_ raw: [String: Any]) -> CGRect? {
        guard let x = number(raw["x"]), let y = number(raw["y"]), let w = number(raw["width"]), let h = number(raw["height"]),
              w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
    private static func array(_ r: CGRect) -> [Double] { [Double(r.minX), Double(r.minY), Double(r.width), Double(r.height)] }
    private static func equal(_ a: CGRect, _ b: CGRect) -> Bool {
        zip(array(a), array(b)).allSatisfy { abs($0 - $1) <= 0.000001 }
    }
    private static func clip(_ r: CGRect, left: CGFloat? = nil, right: CGFloat? = nil,
                             top: CGFloat? = nil, bottom: CGFloat? = nil) -> CGRect {
        let x0 = max(r.minX, left ?? r.minX), x1 = min(r.maxX, right ?? r.maxX)
        let y0 = max(r.minY, top ?? r.minY), y1 = min(r.maxY, bottom ?? r.maxY)
        return x1 > x0 && y1 > y0 ? CGRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0) : .null
    }
}
