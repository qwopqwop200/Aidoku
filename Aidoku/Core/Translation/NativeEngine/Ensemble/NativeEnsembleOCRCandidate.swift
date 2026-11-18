import CoreGraphics
import Foundation

/// Missing-owner triage, not OCR, glyph segmentation, or a new translation source.
/// No files, labels, page identifiers, inference runtimes, or removal-mask writes.
enum EnsembleCandidate01: Ensemble100Candidate {
    static var defaults: [String: Double] { [
        "enabled": 1, "recoverSaved": 1, "rfConfidence": 0.55,
        "ocrConfidence": 0.60, "requestScore": 0.24, "ownerOverlap": 0.10, "minMaskSupport": 0.98,
        "minPixelRange": 0.18, "minEdgeFraction": 0.025, "gridSide": 32,
        "maxPixelProbes": 256
    ] }

    private struct Alternative {
        let path: String
        let row: [String: Any]
        let layout: [String: Any]?
        let bounds: CGRect?
        let trustedTranslation: Bool
    }

    private static let unit = CGRect(x: 0, y: 0, width: 1, height: 1)
    private static func number(_ object: [String: Any], _ key: String) -> Double? {
        guard let n = object[key] as? NSNumber, n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func rect(_ value: Any?) -> CGRect? {
        let v: [Double]
        if let a = value as? [Double] { v = a }
        else if let d = value as? [String: Any],
                let x = number(d, "x"), let y = number(d, "y"),
                let w = number(d, "width"), let h = number(d, "height") { v = [x, y, w, h] }
        else { return nil }
        guard v.count == 4, v.allSatisfy(\.isFinite), v[2] > 0, v[3] > 0 else { return nil }
        let r = CGRect(x: v[0], y: v[1], width: v[2], height: v[3])
        return unit.contains(r) ? r : nil
    }
    private static func array(_ r: CGRect) -> [Double] { [r.minX, r.minY, r.width, r.height] }
    private static func area(_ r: CGRect) -> Double { r.isNull ? 0 : r.width * r.height }
    private static func overlap(_ r: CGRect, _ owners: [CGRect]) -> Double {
        // Union, not max/sum: several existing fragments can already own the whole saved paragraph.
        let clips = owners.map { r.intersection($0) }.filter { !$0.isNull && !$0.isEmpty }
        let xs = Array(Set(clips.flatMap { [$0.minX, $0.maxX] })).sorted()
        guard xs.count > 1 else { return 0 }
        var total: Double = 0
        for i in 1..<xs.count {
            let mid = (xs[i - 1] + xs[i]) / 2
            let strips = clips.filter { $0.minX <= mid && $0.maxX >= mid }.sorted { $0.minY < $1.minY }
            var end = -Double.infinity, length: Double = 0
            for strip in strips {
                length += max(0, strip.maxY - max(end, strip.minY))
                end = max(end, strip.maxY)
            }
            total += length * (xs[i] - xs[i - 1])
        }
        return min(1, total / area(r))
    }
    private static func nonempty(_ value: Any?) -> Bool {
        (value as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    }
    private static func layoutValid(_ item: [String: Any], viewport: CGSize) -> Bool {
        guard nonempty(item["text"]), rect(item["sourceBounds"]) != nil,
              item["sourceTextOnly"] as? Bool != true, item["keptLettering"] as? Bool != true,
              let x = number(item, "x"), let y = number(item, "y"),
              let w = number(item, "width"), let h = number(item, "height"),
              let font = number(item, "fontSize"), let line = number(item, "lineHeight"),
              w > 0, h > 0, font > 0, line > 0 else { return false }
        return CGRect(origin: .zero, size: viewport).contains(CGRect(x: x, y: y, width: w, height: h))
    }

    /// Only explicit containers are read. Arbitrary dictionaries are never recursively mined for text.
    /// Native layout `text` is a translation; OCR region `text` is NOT a translation.
    private static func alternatives(_ evidence: [String: Any]) -> [Alternative] {
        var result: [Alternative] = []
        func appendLayout(_ root: [String: Any], path: String) {
            guard let layout = root["nativeLayout"] as? [String: Any],
                  let items = layout["items"] as? [[String: Any]] else { return }
            for (i, item) in items.enumerated() {
                result.append(.init(path: "\(path).nativeLayout.items[\(i)]", row: item, layout: item,
                    bounds: rect(item["sourceBounds"]), trustedTranslation: true))
            }
        }
        appendLayout(evidence, path: "savedEvidence")
        if let value = evidence["value"] as? [String: Any] { appendLayout(value, path: "savedEvidence.value") }
        if let payload = evidence["originalPayload"] as? [String: Any] {
            appendLayout(payload, path: "savedEvidence.originalPayload")
            if let value = payload["value"] as? [String: Any] {
                appendLayout(value, path: "savedEvidence.originalPayload.value")
            }
        }
        for (i, item) in (evidence["originalItems"] as? [[String: Any]] ?? []).enumerated() {
            result.append(.init(path: "savedEvidence.originalItems[\(i)]", row: item, layout: item,
                bounds: rect(item["sourceBounds"]), trustedTranslation: true))
        }
        for key in ["ocrAlternatives", "regions"] {
            for (i, row) in (evidence[key] as? [[String: Any]] ?? []).enumerated() {
                // Parent may attach a full saved native item to its corresponding OCR alternative.
                let layout = row["layoutItem"] as? [String: Any]
                result.append(.init(path: "savedEvidence.\(key)[\(i)]", row: row, layout: layout,
                    bounds: rect(row["sourceBounds"] ?? row["rect"] ?? layout?["sourceBounds"]),
                    trustedTranslation: layout != nil && nonempty(row["translation"])))
            }
        }
        // Final ReaderTranslationRegion caches use normalized rect + source + translation.
        // Native recognizer stages use source-pixel geometry and must not be silently reinterpreted.
        if let ocr = evidence["originalOCR"] as? [String: Any],
           ocr["stage"] == nil, let regions = ocr["regions"] as? [[String: Any]] {
            for (i, row) in regions.enumerated() {
                result.append(.init(path: "savedEvidence.originalOCR.regions[\(i)]", row: row, layout: nil,
                    bounds: rect(row["rect"] ?? row["sourceBounds"]), trustedTranslation: false))
            }
        }
        return result
    }

    private static func inside(_ point: CGPoint, ring: [CGPoint]) -> Bool {
        guard ring.count >= 3 else { return false }
        var result = false
        for i in ring.indices {
            let a = ring[i], b = ring[(i + 1) % ring.count]
            if (a.y > point.y) != (b.y > point.y),
               point.x < (b.x - a.x) * (point.y - a.y) / (b.y - a.y) + a.x { result.toggle() }
        }
        return result
    }
    private static func validRing(_ ring: [CGPoint]) -> Bool {
        ring.count >= 3 && ring.allSatisfy { $0.x.isFinite && $0.y.isFinite && unit.contains($0) }
    }
    private static func patch(_ image: CGImage, rect: CGRect, side: Int) -> [UInt8]? {
        let pixels = CGRect(x: rect.minX * Double(image.width), y: rect.minY * Double(image.height),
            width: rect.width * Double(image.width), height: rect.height * Double(image.height))
        guard let crop = image.cropping(to: pixels.integral) else { return nil }
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let ok = rgba.withUnsafeMutableBytes { bytes -> Bool in
            guard let c = CGContext(data: bytes.baseAddress, width: side, height: side, bitsPerComponent: 8,
                bytesPerRow: side * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            c.interpolationQuality = .low
            c.draw(crop, in: CGRect(x: 0, y: 0, width: side, height: side))
            return true
        }
        guard ok else { return nil }
        return (0..<(side * side)).map { i -> UInt8 in
            let red = Int(rgba[4 * i]) * 54
            let green = Int(rgba[4 * i + 1]) * 183
            let blue = Int(rgba[4 * i + 2]) * 19
            return UInt8((red + green + blue) / 256)
        }
    }
    private struct Pixels {
        let range: Double
        let edgeFraction: Double
        let missingArea: Double
        let missingEdge: Double
        let maskSupport: Double?
        let polygonUsed: Bool
    }
    private static func measure(_ page: Ensemble100Page, bounds: CGRect, owners: [CGRect],
                                side: Int, region: Ensemble100RFRegion? = nil) -> Pixels? {
        guard let ink = patch(page.original, rect: bounds, side: side) else { return nil }
        let aligned = page.removalMask.width == page.original.width && page.removalMask.height == page.original.height
        let maskAvailable = page.savedEvidence["removalMaskAvailable"] as? Bool != false
        let mask = aligned && maskAvailable ? patch(page.removalMask, rect: bounds, side: side) : nil
        let polygonUsed = region.map { validRing($0.exterior) && $0.holes.allSatisfy(validRing) } ?? false
        var samples = 0, missing = 0, edges = 0, missingEdges = 0, maskedEdges = 0
        var low = 255, high = 0
        for y in 1..<(side - 1) { for x in 1..<(side - 1) {
            let p = CGPoint(x: bounds.minX + (Double(x) + 0.5) / Double(side) * bounds.width,
                y: bounds.minY + (Double(y) + 0.5) / Double(side) * bounds.height)
            if polygonUsed, let region,
               !inside(p, ring: region.exterior) || region.holes.contains(where: { inside(p, ring: $0) }) { continue }
            let i = y * side + x, v = Int(ink[i])
            low = min(low, v); high = max(high, v); samples += 1
            let owned = owners.contains { $0.contains(p) }
            if !owned { missing += 1 }
            // Both dark-on-light and light-on-dark strokes contribute identically.
            let edge = max(abs(v - Int(ink[i - 1])), abs(v - Int(ink[i + 1])),
                abs(v - Int(ink[i - side])), abs(v - Int(ink[i + side]))) >= 32
            if edge {
                edges += 1
                if !owned { missingEdges += 1 }
                if let mask, mask[i] >= 250 { maskedEdges += 1 }
            }
        } }
        guard samples > 0 else { return nil }
        return .init(range: Double(high - low) / 255, edgeFraction: Double(edges) / Double(samples),
            missingArea: Double(missing) / Double(samples), missingEdge: Double(missingEdges) / Double(max(1, edges)),
            maskSupport: mask == nil || edges == 0 ? nil : Double(maskedEdges) / Double(edges), polygonUsed: polygonUsed)
    }

    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        func p(_ key: String, _ low: Double, _ high: Double) -> Double {
            let value = parameters[key] ?? defaults[key]!
            return value.isFinite ? min(high, max(low, value)) : defaults[key]!
        }
        guard p("enabled", 0, 1) > 0 else { return .init(items: page.items) }
        var items = page.items
        var owners = page.items.compactMap { rect($0["sourceBounds"]) }
        var audit: [[String: Any]] = [], requests: [[String: Any]] = [], recoveries: [[String: Any]] = []
        let alternatives = alternatives(page.savedEvidence)
        let rawOCR = page.savedEvidence["originalOCR"] as? [String: Any]
        let ocrAvailable = page.savedEvidence["originalOCR"] != nil && !(page.savedEvidence["originalOCR"] is NSNull)
        let normalizedOCR = rawOCR?["stage"] == nil && rawOCR?["regions"] is [[String: Any]]
        let ocrStatus = !ocrAvailable ? "missing-cached-OCR" :
            (normalizedOCR ? "normalized-final-regions-parsed" : "unsupported-cached-OCR-schema-parent-coordinate-adapter-required")
        let side = Int(p("gridSide", 16, 64)), budget = Int(p("maxPixelProbes", 0, 1024))
        var probes = 0, invalid = 0, deferred = 0
        let digest = page.savedEvidence["sourceSHA256"] as? String
        let sourceMatches = digest == page.sourceSHA256 && !page.sourceSHA256.isEmpty
        func pixels(_ b: CGRect, region: Ensemble100RFRegion? = nil) -> Pixels? {
            guard probes < budget else { deferred += 1; return nil }
            probes += 1
            return measure(page, bounds: b, owners: owners, side: side, region: region)
        }
        func evidence(_ m: Pixels) -> [String: Any] { [
            "missingAreaFraction": m.missingArea, "missingEdgeFraction": m.missingEdge,
            "pixelRange": m.range, "edgeFraction": m.edgeFraction,
            "maskEdgeSupport": m.maskSupport as Any? ?? NSNull(), "polygonUsed": m.polygonUsed
        ] }
        func request(_ b: CGRect, score: Double, origin: String, reason: String) {
            requests.append(["bounds": array(b), "score": score, "origin": origin, "reason": reason,
                "action": "selective-saved-OCR-reinspection", "mayErase": false,
                "requiresCompleteSourceAndTargetCheck": true])
        }
        // Saved translations get first use of the small pixel budget; RF misses never block OCR recovery.
        for alt in alternatives {
            var record: [String: Any] = ["origin": alt.path]
            guard sourceMatches else {
                record["status"] = digest == nil ? "source-digest-missing" : "source-digest-mismatch"
                audit.append(record); continue
            }
            guard let b = alt.bounds else {
                invalid += 1; record["status"] = "invalid-normalized-OCR-bounds"; audit.append(record); continue
            }
            record["bounds"] = array(b)
            let ownerOverlap = overlap(b, owners)
            record["ownerOverlap"] = ownerOverlap
            if ownerOverlap > p("ownerOverlap", 0, 0.5) {
                record["status"] = "existing-or-conflicting-owner"; audit.append(record); continue
            }
            guard let m = pixels(b) else {
                record["status"] = "pixel-evidence-unavailable-or-budget"; audit.append(record); continue
            }
            record.merge(evidence(m)) { _, new in new }
            let confidence = min(1, max(0, number(alt.row, "confidence") ?? 0.65))
            let hasOCR = nonempty(alt.row["source"]) || nonempty(alt.row["text"]) || alt.layout != nil
            let pixelSupport = m.range >= p("minPixelRange", 0.05, 1) && m.edgeFraction >= p("minEdgeFraction", 0.005, 0.5)
            let score = hasOCR && pixelSupport ? confidence * m.missingEdge : 0
            record["reinspectionScore"] = score
            let layout = alt.layout
            let sameBounds = layout.flatMap { rect($0["sourceBounds"]) } == b
            let translationMatches = alt.row["translation"] == nil ||
                (alt.row["translation"] as? String).map { Array($0.utf16) == Array((layout?["text"] as? String ?? "").utf16) } == true
            // A first-hit traversal must not choose between competing saved targets.
            let target = layout?["text"] as? String ?? ""
            let conflictingTargets = alternatives.contains { other in
                guard other.trustedTranslation, let otherBounds = other.bounds,
                      overlap(b, [otherBounds]) > p("ownerOverlap", 0, 0.5),
                      let otherText = other.layout?["text"] as? String else { return false }
                return Array(otherText.utf16) != Array(target.utf16)
            }
            let canRecover = p("recoverSaved", 0, 1) > 0 && pixelSupport && hasOCR &&
                confidence >= p("ocrConfidence", 0, 1) && alt.trustedTranslation && sameBounds && translationMatches && !conflictingTargets &&
                layout.map { layoutValid($0, viewport: page.viewport) } == true &&
                (m.maskSupport ?? 0) >= p("minMaskSupport", 0.9, 1)
            if canRecover, var restored = layout {
                // Only append exact saved lexical text and style/geometry. No merged or reconstructed translation.
                let savedID = restored["id"] as? String ?? ""
                let id = savedID.isEmpty ? "ensemble01-recovered-\(recoveries.count)" : savedID
                if items.contains(where: { ($0["id"] as? String) == id }) {
                    record["status"] = "saved-ID-conflict"
                    request(b, score: score, origin: alt.path, reason: "saved-ID-conflict")
                } else {
                    restored["id"] = id
                    restored["ensemble01Recovery"] = ["origin": alt.path, "savedID": savedID,
                        "maskUnchanged": true, "textUTF16Unchanged": true] as [String: Any]
                    items.append(restored); owners.append(b)
                    recoveries.append(["id": id, "origin": alt.path, "bounds": array(b)])
                    record["status"] = "recovered-exact-saved-layout"
                }
            } else {
                record["status"] = "preserved-request-only"
                if score >= p("requestScore", 0, 1) {
                    let reason = conflictingTargets ? "conflicting-saved-targets" : (!alt.trustedTranslation ? "no-complete-saved-translation-layout" :
                        ((m.maskSupport ?? 0) < p("minMaskSupport", 0.9, 1) ? "source-strokes-not-safely-removed" : "ambiguous-layout-or-translation")
                    )
                    request(b, score: score, origin: alt.path, reason: reason)
                }
            }
            audit.append(record)
        }
        for region in page.rfRegions where region.classID == 0 || region.classID == 1 {
            let origin = "rf.query.\(region.queryID)"
            var record: [String: Any] = ["origin": origin, "classID": region.classID]
            guard let b = rect(array(region.bounds)), region.confidence.isFinite else {
                invalid += 1; record["status"] = "invalid-RF-geometry-or-confidence"; audit.append(record); continue
            }
            record["bounds"] = array(b)
            guard region.confidence >= p("rfConfidence", 0, 1) else {
                record["status"] = "low-RF-confidence"; audit.append(record); continue
            }
            guard let m = pixels(b, region: region) else {
                record["status"] = "pixel-evidence-unavailable-or-budget"; audit.append(record); continue
            }
            record.merge(evidence(m)) { _, new in new }
            let pixelSupport = m.range >= p("minPixelRange", 0.05, 1) && m.edgeFraction >= p("minEdgeFraction", 0.005, 0.5)
            let score = pixelSupport ? min(1, max(0, region.confidence)) * m.missingEdge : 0
            record["reinspectionScore"] = score
            record["status"] = pixelSupport ? "RF-plus-pixel-proxy" : "RF-unconfirmed-by-pixels"
            if score >= p("requestScore", 0, 1) {
                request(b, score: score, origin: origin, reason: "unowned-RF-text-edges-no-translation-invented")
            }
            audit.append(record)
        }
        return .init(items: items, audit: ["candidate": "01", "version": 1,
            "authority": "automated geometric/contrast proxy; not visual inspection, OCR truth, or quality acceptance",
            "inputItemCount": page.items.count, "outputItemCount": items.count,
            "savedAlternativeCount": alternatives.count, "rfRegionCount": page.rfRegions.count,
            "originalOCRAvailable": ocrAvailable, "originalOCRStatus": ocrStatus,
            "originalOCRPolicy": "only normalized final regions parsed; raw pixel-coordinate stages require explicit parent adapter",
            "removalMaskAvailable": page.savedEvidence["removalMaskAvailable"] as? Bool != false,
            "maskGeometryAligned": page.removalMask.width == page.original.width && page.removalMask.height == page.original.height,
            "rfBoxOnlyCount": page.rfRegions.filter { !validRing($0.exterior) }.count,
            "rfNontextCount": page.rfRegions.filter { $0.classID != 0 && $0.classID != 1 }.count,
            "pixelProbes": probes, "budgetDeferredCount": deferred, "invalidEvidenceCount": invalid,
            "sourceAssociation": digest == nil ? "digest-missing-recovery-blocked" : (sourceMatches ? "digest-matched" : "digest-mismatch"),
            "records": audit, "reinspectionRequests": requests, "recoveries": recoveries,
            "maskChanged": false, "preservedInputUTF16": true])
    }
}
