import CoreGraphics
import CoreText
import Foundation

/// Layout relations only. Never merges, removes, rewrites, or classifies lexical text.
enum EnsembleCandidate05: Ensemble100Candidate {
    static let defaults: [String: Double] = [
        "enabled": 1, "rfConfidence": 0.72, "ownerCoverage": 0.88, "ownerMargin": 0.08,
        "startTolerance": 0.35, "neighborGap": 1.5, "maxShift": 0.65,
        "fontBlend": 0.65, "maxFontChange": 0.12, "spacingBlend": 0.5,
        "maxHeightGrowth": 0.25, "haloFraction": 0.20, "fallbackEnabled": 1
    ]

    private struct Entry {
        let index: Int
        let id: String
        let text: String
        let source: CGRect // viewport units, top-left
        let frame: CGRect
        let font: CGFloat
        let sourceFont: CGFloat
        let pitch: CGFloat
        let vertical: Bool
        let owner: Int?
        let frames: Set<Int>
        let blocked: String?
    }
    private struct Relation {
        let a: Int
        let b: Int
        let kind: String
        let authority: String
        let score: CGFloat
    }
    private static func number(_ item: [String: Any], _ key: String) -> CGFloat? {
        guard let n = item[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
        return CGFloat(n.doubleValue)
    }
    private static func rect(_ values: Any?) -> CGRect? {
        guard let v = values as? [NSNumber], v.count == 4 else { return nil }
        let a = v.map { CGFloat($0.doubleValue) }
        guard a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
    private static func display(_ item: [String: Any]) -> CGRect? {
        guard let x = number(item, "x"), let y = number(item, "y"),
              let w = number(item, "width"), let h = number(item, "height"), w > 0, h > 0 else { return nil }
        return CGRect(x: x, y: y, width: w, height: h)
    }
    private static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : max(0, r.width) * max(0, r.height) }
    private static func samples(_ r: CGRect) -> [CGPoint] {
        [CGFloat(0), 0.5, 1].flatMap { y in
            [CGFloat(0), 0.5, 1].map { x in CGPoint(x: r.minX + r.width * x, y: r.minY + r.height * y) }
        }
    }
    private static func inRing(_ p: CGPoint, _ ring: [CGPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var inside = false
        var j = ring.count - 1
        for i in ring.indices {
            let a = ring[i], b = ring[j]
            if (a.y > p.y) != (b.y > p.y),
               p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inside.toggle() }
            j = i
        }
        return inside
    }
    private static func contains(_ p: CGPoint, _ region: Ensemble100RFRegion) -> Bool {
        // A bbox alone is insufficient ownership/containment evidence.
        region.bounds.contains(p) && inRing(p, region.exterior) && !region.holes.contains { inRing(p, $0) }
    }
    private static func coverage(_ r: CGRect, _ region: Ensemble100RFRegion) -> CGFloat {
        CGFloat(samples(r).filter { contains($0, region) }.count) / 9
    }
    private static func segmentsCross(_ a: CGPoint, _ b: CGPoint, _ c: CGPoint, _ d: CGPoint) -> Bool {
        func cross(_ p: CGPoint, _ q: CGPoint, _ r: CGPoint) -> CGFloat {
            (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x)
        }
        return cross(a, b, c) * cross(a, b, d) < 0 && cross(c, d, a) * cross(c, d, b) < 0
    }
    private static func rectangleCorners(_ r: CGRect) -> [CGPoint] {
        [CGPoint(x: r.minX, y: r.minY), CGPoint(x: r.maxX, y: r.minY),
         CGPoint(x: r.maxX, y: r.maxY), CGPoint(x: r.minX, y: r.maxY)]
    }
    private static func ringIntersects(_ r: CGRect, _ ring: [CGPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        let corners = rectangleCorners(r)
        if ring.contains(where: { r.contains($0) }) || corners.contains(where: { inRing($0, ring) }) { return true }
        for i in ring.indices { for j in corners.indices {
            if segmentsCross(ring[i], ring[(i + 1) % ring.count], corners[j], corners[(j + 1) % 4]) { return true }
        } }
        return false
    }
    private static func fullyContained(_ r: CGRect, _ region: Ensemble100RFRegion) -> Bool {
        guard coverage(r, region) == 1 else { return false }
        // Reject narrow holes/concave notches even when nine samples miss them.
        if region.holes.contains(where: { ringIntersects(r, $0) }) { return false }
        if region.exterior.contains(where: { r.insetBy(dx: 0.0000001, dy: 0.0000001).contains($0) }) { return false }
        let corners = rectangleCorners(r)
        for i in region.exterior.indices { for j in corners.indices {
            if segmentsCross(region.exterior[i], region.exterior[(i + 1) % region.exterior.count],
                             corners[j], corners[(j + 1) % 4]) { return false }
        } }
        return true
    }
    private static func normalized(_ r: CGRect, _ viewport: CGSize) -> CGRect {
        CGRect(x: r.minX / viewport.width, y: r.minY / viewport.height,
               width: r.width / viewport.width, height: r.height / viewport.height)
    }
    private static func frameEvidence(_ r: CGRect, _ region: Ensemble100RFRegion) -> (inside: Bool, crosses: Bool) {
        // RF frame contours may have an interior hole: frame enclosure uses the exterior.
        // Box-only frames are conservative enclosure/border proxies, never segmentation.
        let count = samples(r).filter { region.exterior.isEmpty ? region.bounds.contains($0) : inRing($0, region.exterior) }.count
        return (count == 9, count > 0 && count < 9)
    }
    private static func serial(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height].map(Double.init) }

    /// Small original-pixel corridor diagnostic, not OCR or a semantic/visual quality verdict.
    private static func corridor(_ a: CGRect, _ b: CGRect, image: CGImage, viewport: CGSize,
                                 sameStart: Bool) -> [String: Any]? {
        let first = sameStart ? (a.minX < b.minX ? a : b) : (a.minY < b.minY ? a : b)
        let last = first == a ? b : a
        let r: CGRect
        if sameStart {
            r = CGRect(x: first.maxX, y: max(a.minY, b.minY), width: last.minX - first.maxX,
                       height: min(a.maxY, b.maxY) - max(a.minY, b.minY))
        } else {
            r = CGRect(x: max(a.minX, b.minX), y: first.maxY,
                       width: min(a.maxX, b.maxX) - max(a.minX, b.minX), height: last.minY - first.maxY)
        }
        guard r.width > 0, r.height > 0 else { return nil }
        let pixel = CGRect(x: r.minX / viewport.width * CGFloat(image.width),
                           y: r.minY / viewport.height * CGFloat(image.height),
                           width: r.width / viewport.width * CGFloat(image.width),
                           height: r.height / viewport.height * CGFloat(image.height)).integral
        guard pixel.width >= 2, pixel.height >= 2, let crop = image.cropping(to: pixel) else { return nil }
        let side = 24
        var bytes = [UInt8](repeating: 0, count: side * side)
        let ok = bytes.withUnsafeMutableBytes { ptr -> Bool in
            guard let c = CGContext(data: ptr.baseAddress, width: side, height: side, bitsPerComponent: 8,
                                    bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: 0) else { return false }
            c.interpolationQuality = .low
            c.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        let mean = Double(bytes.reduce(0) { $0 + Int($1) }) / Double(bytes.count) / 255
        let dark = Double(bytes.filter { $0 < 160 }.count) / Double(bytes.count)
        var barrier = 0
        for axis in 0..<side {
            let n = (0..<side).filter { cross in bytes[sameStart ? cross * side + axis : axis * side + cross] < 120 }.count
            barrier = max(barrier, n)
        }
        return ["meanLuma": mean, "darkFraction": dark, "barrierFraction": Double(barrier) / Double(side),
                "sourceCorridorViewport": serial(r), "authority": "24x24 original-pixel proxy; not glyph segmentation"]
    }

    /// Same font/pitch family as the frozen raw painter; capacity proxy only, never quality acceptance.
    private static func fittedHeight(_ text: String, width: CGFloat, font: CGFloat, pitch: CGFloat,
                                     halo: CGFloat) -> CGFloat? {
        guard width > 2 * halo + font else { return nil }
        let face = CTFontCreateWithName("AppleSDGothicNeo-Medium" as CFString, font, nil)
        var minimum = pitch, maximum = pitch
        let paragraph = withUnsafePointer(to: &minimum) { low in
            withUnsafePointer(to: &maximum) { high in
                let settings = [CTParagraphStyleSetting(spec: .minimumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: low),
                                CTParagraphStyleSetting(spec: .maximumLineHeight, valueSize: MemoryLayout<CGFloat>.size, value: high)]
                return CTParagraphStyleCreate(settings, settings.count)
            }
        }
        let value = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): face,
            NSAttributedString.Key(kCTParagraphStyleAttributeName as String): paragraph
        ])
        let setter = CTFramesetterCreateWithAttributedString(value)
        var fitted = CFRange()
        let size = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: text.utf16.count),
            nil, CGSize(width: width - 2 * halo, height: 100_000), &fitted)
        guard fitted.length == text.utf16.count, size.height.isFinite, size.height > 0 else { return nil }
        return ceil(size.height) + 2 * halo + 1
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String, _ low: Double, _ high: Double) -> CGFloat {
            let v = parameters[key] ?? defaults[key] ?? low
            return CGFloat(min(high, max(low, v.isFinite ? v : defaults[key] ?? low)))
        }
        guard p("enabled", 0, 1) > 0 else {
            return .init(items: page.items, audit: ["candidate": "05", "status": "disabled"])
        }
        let viewport = page.viewport
        guard viewport.width.isFinite, viewport.height.isFinite, viewport.width > 0, viewport.height > 0,
              page.items.count <= 512 else {
            return .init(items: page.items, audit: ["candidate": "05", "status": "invalid-viewport-or-item-budget", "items": page.items.count])
        }
        let bounds = CGRect(origin: .zero, size: viewport)
        let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
        let rf = page.rfRegions.filter { region in
            region.confidence.isFinite && region.confidence >= Double(p("rfConfidence", 0.5, 0.99)) &&
            (region.exterior.isEmpty || region.exterior.count >= 3) && region.exterior.allSatisfy { $0.x.isFinite && $0.y.isFinite } &&
            region.holes.allSatisfy { $0.count >= 3 && $0.allSatisfy { $0.x.isFinite && $0.y.isFinite } } &&
            area(region.bounds) > 0 && unit.contains(region.bounds)
        }
        var entries: [Entry] = [], itemAudit: [[String: Any]] = [], decisions: [[String: Any]] = []
        for (index, item) in page.items.enumerated() {
            let id = item["id"] as? String ?? "index:\(index)"
            guard let source = rect(item["sourceBounds"]), unit.contains(source), let frame = display(item),
                  let font = number(item, "fontSize"), font > 0,
                  let pitch = number(item, "lineHeight"), pitch > 0,
                  let text = item["text"] as? String, !text.isEmpty,
                  let vertical = item["sourceVertical"] as? Bool else {
                itemAudit.append(["index": index, "id": id, "status": "unchanged-invalid-or-missing-layout-evidence"])
                continue
            }
            let balloonRegions = rf.filter { $0.classID == 2 && !$0.exterior.isEmpty }
            var owners: [(Ensemble100RFRegion, CGFloat)] = []
            for region in balloonRegions {
                let fraction = coverage(source, region)
                if fraction >= p("ownerCoverage", 0.7, 1) { owners.append((region, fraction)) }
            }
            owners.sort { left, right in left.1 * CGFloat(left.0.confidence) > right.1 * CGFloat(right.0.confidence) }
            var reason: String?
            var owner = owners.first?.0.queryID
            if owners.count > 1,
               owners[0].1 * CGFloat(owners[0].0.confidence) - owners[1].1 * CGFloat(owners[1].0.confidence) < p("ownerMargin", 0, 0.3) {
                reason = "ambiguous-balloon-ownership"; owner = nil
            }
            if let cached = number(item, "rfBodyIndex"), let owner, cached != CGFloat(owner) { reason = "cached-live-owner-conflict" }
            if owner == nil && item["rfBodyIndex"] != nil { reason = reason ?? "unverified-cached-owner" }
            if item["keptLettering"] as? Bool == true || item["sourceTextOnly"] as? Bool == true { reason = "preserved-source-item" }
            if item["sourceLettering"] as? String == "display" || abs(number(item, "rotation") ?? 0) > 3 ||
               item["uprightQuadText"] as? Bool == true || item["vertical"] as? Bool == true ||
               item["drawsUprightQuadText"] as? Bool == true { reason = "display-or-rotated-lettering-protection" }
            if rf.contains(where: {
                guard $0.classID == 1 else { return false }
                let support = $0.exterior.isEmpty ? area(source.intersection($0.bounds)) / area(source) : coverage(source, $0)
                return support >= 2.0 / 9
            }) { reason = "rf-sfx-protection" }
            let frames = rf.filter { $0.classID == 3 }
            if frames.contains(where: { frameEvidence(source, $0).crosses }) { reason = "source-crosses-frame-exterior" }
            let sourceFont = number(item, "sourceFontSize") ?? 0
            if sourceFont <= 0 { reason = reason ?? "missing-relative-source-font-evidence" }
            let sourceDisplay = CGRect(x: source.minX * viewport.width, y: source.minY * viewport.height,
                                       width: source.width * viewport.width, height: source.height * viewport.height)
            entries.append(.init(index: index, id: id, text: text, source: sourceDisplay, frame: frame, font: font,
                                 sourceFont: sourceFont, pitch: pitch, vertical: vertical, owner: owner,
                                 frames: Set(frames.filter { frameEvidence(source, $0).inside }.map(\.queryID)), blocked: reason))
            itemAudit.append(["index": index, "id": id, "status": reason ?? "relation-eligible",
                              "owner": owner as Any? ?? NSNull(), "authority": "OCR/source geometry plus RF; not labels"])
        }
        // Relations are local and disjoint; avoid transitive ownership-only paragraph chains.
        var relations: [Relation] = []
        var distant = 0
        for i in entries.indices { for j in entries.indices where j > i {
            let a = entries[i], b = entries[j], g = min(a.sourceFont, b.sourceFont)
            guard g > 0 else { continue }
            let xGap = max(a.source.minX, b.source.minX) - min(a.source.maxX, b.source.maxX)
            let yGap = max(a.source.minY, b.source.minY) - min(a.source.maxY, b.source.maxY)
            guard xGap <= g * p("neighborGap", 0.25, 3), yGap <= g * p("neighborGap", 0.25, 3) else { distant += 1; continue }
            var record: [String: Any] = ["members": [a.id, b.id], "indices": [a.index, b.index]]
            func reject(_ reason: String) { record["status"] = "rejected"; record["reason"] = reason; decisions.append(record) }
            if let reason = a.blocked ?? b.blocked { reject(reason); continue }
            guard a.vertical == b.vertical else { reject("conflicting-source-orientation"); continue }
            guard a.frames == b.frames else { reject("different-frame-enclosures"); continue }
            guard a.owner == b.owner else { reject("different-or-partial-balloon-ownership"); continue }
            guard a.sourceFont / b.sourceFont >= 0.55, a.sourceFont / b.sourceFont <= 1.82 else {
                reject("large-hierarchy-difference-protected"); continue
            }
            let yOverlap = min(a.source.maxY, b.source.maxY) - max(a.source.minY, b.source.minY)
            let xOverlap = min(a.source.maxX, b.source.maxX) - max(a.source.minX, b.source.minX)
            let sameStart = xGap >= 0 && abs(a.source.minY - b.source.minY) <= g * p("startTolerance", 0.05, 0.7) &&
                yOverlap >= min(a.source.height, b.source.height) * 0.55
            let stacked = !a.vertical && yGap >= 0 && xOverlap >= min(a.source.width, b.source.width) * 0.65
            guard sameStart || stacked else { reject("ambiguous-start-spacing-relation"); continue }
            let pixels = corridor(a.source, b.source, image: page.original, viewport: viewport, sameStart: sameStart)
            record["pixels"] = pixels as Any? ?? NSNull()
            if let barrier = pixels?["barrierFraction"] as? Double, barrier >= 0.8 { reject("source-corridor-line-barrier"); continue }
            let authority: String
            if a.owner != nil { authority = "RF-polygon-owner+OCR-start-font-spacing" }
            else {
                guard p("fallbackEnabled", 0, 1) > 0,
                      page.items[a.index]["lightSurface"] as? Bool == true,
                      page.items[b.index]["lightSurface"] as? Bool == true,
                      let mean = pixels?["meanLuma"] as? Double, mean >= 0.88,
                      let dark = pixels?["darkFraction"] as? Double, dark <= 0.04,
                      xGap <= g * 0.8, yGap <= g * 0.8 else { reject("no-owner-and-insufficient-pixel-corridor-evidence"); continue }
                // An RF miss never deletes OCR; fallback needs independent positive geometry and pixels.
                authority = "OCR-source-neighbors+light-original-pixel-corridor; RF-missing"
            }
            let kind = sameStart ? "same-start" : "stacked"
            record["status"] = "proposed"; record["kind"] = kind; record["authority"] = authority
            decisions.append(record)
            relations.append(.init(a: i, b: j, kind: kind, authority: authority,
                                   score: (a.owner == nil ? 1 : 2) - abs(a.source.minY - b.source.minY) / max(g, 1) * 0.01))
        } }
        var output = page.items, used = Set<Int>(), changed = 0, readOrders: [[Int]] = []
        for relation in relations.sorted(by: { $0.score == $1.score ? ($0.a, $0.b) < ($1.a, $1.b) : $0.score > $1.score }) {
            let a = entries[relation.a], b = entries[relation.b]
            var record: [String: Any] = ["members": [a.id, b.id], "kind": relation.kind, "authority": relation.authority]
            if used.contains(a.index) || used.contains(b.index) {
                record["status"] = "rejected"; record["reason"] = "already-in-disjoint-joint-cohort"; decisions.append(record); continue
            }
            let pair = [a, b]
            let ratio = (a.font / a.sourceFont + b.font / b.sourceFont) / 2
            let deltaLimit = p("maxFontChange", 0, 0.3)
            let fonts = pair.map { e -> CGFloat in
                let wanted = e.font + (ratio * e.sourceFont - e.font) * p("fontBlend", 0, 1)
                return min(e.font * (1 + deltaLimit), max(e.font * (1 - deltaLimit), wanted))
            }
            let pitches = pair.indices.map { max(fonts[$0], pair[$0].pitch * fonts[$0] / pair[$0].font) }
            let pixelScale = max(CGFloat(page.original.width) / viewport.width, 0.01)
            let halos = fonts.map { max(2 / pixelScale, $0 * p("haloFraction", 0.14, 0.3)) + 1 / pixelScale }
            var frames = pair.map(\.frame), failure: String?
            for k in pair.indices {
                if let h = fittedHeight(pair[k].text, width: frames[k].width, font: fonts[k], pitch: pitches[k], halo: halos[k]),
                   h <= pair[k].frame.height * (1 + p("maxHeightGrowth", 0, 0.75)) {
                    frames[k].size.height = max(frames[k].height, h)
                } else { failure = "translated-capacity-or-height-growth-limit" }
            }
            if relation.kind == "same-start" {
                let anchor = ((a.frame.minY - a.source.minY) + (b.frame.minY - b.source.minY)) / 2
                for k in pair.indices { frames[k].origin.y = anchor + pair[k].source.minY }
            } else {
                let top = a.source.minY < b.source.minY ? 0 : 1, bottom = 1 - top
                let sourceGap = pair[bottom].source.minY - pair[top].source.maxY
                let desired = max(max(halos[top], halos[bottom]) * 2, min(sourceGap, min(fonts[0], fonts[1]) * 1.5))
                let existing = frames[bottom].minY - frames[top].maxY
                let correction = (desired - existing) * p("spacingBlend", 0, 1)
                frames[top].origin.y -= correction / 2; frames[bottom].origin.y += correction / 2
            }
            for k in pair.indices {
                let e = pair[k], f = frames[k]
                if abs(f.minY - e.frame.minY) > e.font * p("maxShift", 0, 1.5) { failure = "source-near-shift-limit" }
                if !bounds.contains(f) { failure = "viewport-clipping-risk" }
                let norm = normalized(f, viewport)
                if let owner = e.owner, let region = rf.first(where: { $0.classID == 2 && $0.queryID == owner && !$0.exterior.isEmpty }),
                   !fullyContained(norm, region) { failure = "proposed-box-outside-balloon-polygon-or-in-hole" }
                for sfx in rf where sfx.classID == 1 {
                    let before = normalized(e.frame, viewport).intersection(sfx.bounds)
                    if area(norm.intersection(sfx.bounds)) > area(before) + 0.000001 {
                        failure = "new-or-increased-rf-sfx-contact"
                    }
                }
                let framesRF = rf.filter { $0.classID == 3 }
                let proposedFrames = Set(framesRF.filter { frameEvidence(norm, $0).inside }.map(\.queryID))
                if proposedFrames != e.frames || framesRF.contains(where: { frameEvidence(norm, $0).crosses }) {
                    failure = "proposed-box-crosses-frame"
                }
                for other in output.indices where other != e.index {
                    let member = pair.firstIndex { $0.index == other }
                    if member == nil, let s = rect(page.items[other]["sourceBounds"]),
                       page.items[other]["keptLettering"] as? Bool == true || page.items[other]["sourceTextOnly"] as? Bool == true {
                        let protected = CGRect(x: s.minX * viewport.width, y: s.minY * viewport.height,
                                               width: s.width * viewport.width, height: s.height * viewport.height)
                        if area(f.intersection(protected)) > area(e.frame.intersection(protected)) + 0.25 {
                            failure = "preserved-source-contact"
                        }
                    }
                    guard let beforePeer = display(page.items[other]),
                          let peer = member.map({ frames[$0] }) ?? display(output[other]) else { continue }
                    let old = area(e.frame.intersection(beforePeer))
                    if area(f.intersection(peer)) > old + 0.25 { failure = "new-or-increased-peer-box-overlap" }
                }
            }
            if let failure { record["status"] = "rejected"; record["reason"] = failure; decisions.append(record); continue }
            let order = pair.indices.sorted {
                relation.kind == "stacked" ? pair[$0].source.minY < pair[$1].source.minY :
                    (a.vertical ? pair[$0].source.midX > pair[$1].source.midX : pair[$0].source.midX < pair[$1].source.midX)
            }
            for k in pair.indices {
                var item = output[pair[k].index]
                item["x"] = Double(frames[k].minX); item["y"] = Double(frames[k].minY)
                item["width"] = Double(frames[k].width); item["height"] = Double(frames[k].height)
                item["fontSize"] = Double(fonts[k]); item["lineHeight"] = Double(pitches[k])
                output[pair[k].index] = item
                used.insert(pair[k].index)
                if frames[k] != pair[k].frame || abs(fonts[k] - pair[k].font) > 0.001 { changed += 1 }
            }
            // Apply unambiguous read order only within the two original occupied slots.
            readOrders.append(order.map { pair[$0].index })
            record["status"] = "applied"; record["before"] = pair.map { serial($0.frame) }
            record["after"] = frames.map(serial); record["fontsBefore"] = pair.map { Double($0.font) }
            record["fontsAfter"] = fonts.map(Double.init); record["readOrder"] = order.map { pair[$0].id }
            record["sentenceMerge"] = false; decisions.append(record)
        }
        for order in readOrders {
            let orderedItems = order.map { output[$0] }
            for (slot, item) in zip(order.sorted(), orderedItems) { output[slot] = item }
        }
        return .init(items: output, audit: ["candidate": "05", "status": "complete", "itemCount": page.items.count,
            "changedGeometryItems": changed, "itemAccounting": itemAudit, "relations": decisions,
            "distantPairsNotProposed": distant, "rfInputRegions": page.rfRegions.count, "rfUsableRegions": rf.count,
            "rfBoxOnlyRegions": rf.filter { $0.exterior.isEmpty }.count,
            "boxOnlyRFUse": "SFX protection/frame enclosure proxy only; never balloon ownership or segmentation",
            "originalOCRAvailable": page.savedEvidence["originalOCR"] != nil,
            "missingOCRPolicy": "uses saved item OCR-derived sourceBounds/sourceFontSize; missing evidence unchanged; no new inference",
            "sentenceMerging": false, "textUTF16UnchangedPerItem": true,
            "evidence": "runtime geometry/RF/original-pixel proxies and CoreText capacity; no real-page visual review or quality acceptance"])
    }
}
