import CoreGraphics
import Foundation

/// In-memory replacement for cached balloon annotation. The caller supplies
/// upright original pixels and regions obtained from the identity-bound RF
/// result beside OCR. No detector, file path, cache, environment or page ID.
enum NativeMainBalloonContours {
    struct Contour {
        let rect: CGRect // Viewport coordinates, top-left origin.
        let spans: [(CGFloat, CGFloat)] // Equal-height bands over rect.
        var exactPlacement: NativeSimpleRFBalloonPlacement.Constraint? = nil

        var center: CGPoint {
            guard let maximum = spans.map({ $0.1 - $0.0 }).max(), maximum > 0 else {
                return CGPoint(x: rect.midX, y: rect.midY)
            }
            var mass: CGFloat = 0, weightedX: CGFloat = 0, weightedY: CGFloat = 0
            for (i, span) in spans.enumerated() where span.1 - span.0 >= maximum * 0.65 {
                let width = span.1 - span.0
                mass += width
                weightedX += (span.0 + span.1) * 0.5 * width
                weightedY += (rect.minY + (CGFloat(i) + 0.5) * rect.height / CGFloat(spans.count)) * width
            }
            return CGPoint(x: weightedX / mass, y: weightedY / mass)
        }

        /// Check the entire retained glyph/halo rectangle across every touched
        /// band. A row at the next band's exact boundary does not touch it.
        func contains(_ glyph: CGRect) -> Bool {
            if let exactPlacement {
                return exactPlacement.contains(viewportRect:glyph,viewport:exactPlacement.viewport)
            }
            guard !spans.isEmpty, rect.height > 0, !glyph.isEmpty, !glyph.isNull,
                  !glyph.isInfinite, [glyph.minX, glyph.minY, glyph.maxX, glyph.maxY].allSatisfy(\.isFinite),
                  rect.contains(glyph) else { return false }
            let step = rect.height / CGFloat(spans.count)
            guard step.isFinite, step > 0 else { return false }
            let first = max(0, Int(floor((glyph.minY - rect.minY) / step)))
            let last = min(spans.count - 1, Int(ceil((glyph.maxY - rect.minY) / step)) - 1)
            return first <= last && (first...last).allSatisfy {
                glyph.minX >= spans[$0].0 && glyph.maxX <= spans[$0].1
            }
        }
    }

    /// Call once per page, then pass returned items to the normal renderer.
    /// Exterior/holes go directly into Candidate03's polygon scanlines and
    /// original-RGB refinement, without reconstructing a thresholded RF mask.
    /// Optional identities compare provenance already established by the main
    /// evidence store; strings supplied here are not a fresh pixel hash proof.
    static func annotate(_ items: [[String: Any]], original: CGImage,
                         regions: [Ensemble100RFRegion], viewport: CGSize,
                         parameters: [String: Double] = [:],
                         texturedParameters: [String: Double] = [:],
                         sourceIdentity: String? = nil, regionsSourceIdentity: String? = nil,
                         simplePlacement: NativeSimpleRFBalloonPlacement? = nil)
        -> (items: [[String: Any]], audit: [String: Any]) {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else {
            return (items, ["status": "invalid-viewport-preserved", "inputItems": items.count])
        }
        if let sourceIdentity, let regionsSourceIdentity, sourceIdentity != regionsSourceIdentity {
            return (items, ["status": "source-identity-mismatch-preserved", "inputItems": items.count])
        }
        // Candidate03 reads ONLY original, items and RF regions. These unused
        // image slots alias original to satisfy the shared proposal contract;
        // no restoration, mask sampling or image allocation is performed here.
        let page = Ensemble100Page(sourceSHA256: sourceIdentity ?? "", original: original,
            restored: original, removalMask: original, viewport: viewport,
            items: items, rfRegions: regions, savedEvidence: [:])
        do {
            try simplePlacement?.validate(original:original,viewport:viewport)
            let proposal = try EnsembleCandidate03.apply(page, parameters: parameters)
            let decisions = proposal.audit["items"] as? [[String: Any]] ?? []
            var result = proposal.items, associated = 0, attached = 0, nativeFallbacks = 0
            for decision in decisions {
                guard let index = decision["itemIndex"] as? Int, result.indices.contains(index),
                      decision["status"] as? String == "attached-estimated-interior" else { continue }
                attached += 1
                // These are supporting model-association fields from the
                // frozen API, never permission to merge distinct paragraphs.
                if let query = decision["rfQueryID"] as? Int {
                    let confidence = regions.filter { $0.classID == 2 && $0.queryID == query && !$0.exterior.isEmpty }
                        .map(\.confidence).filter(\.isFinite).max()
                    if let confidence {
                        result[index]["rfBodyIndex"] = query
                        result[index]["rfBodyConfidence"] = confidence
                        associated += 1
                    }
                } else {
                    nativeFallbacks += 1
                }
            }
            var texturedAudit: [String: Any] = ["status": "disabled"]
            var texturedDecisions: [[String: Any]] = []
            if parameters["enabled"] != 0 && texturedParameters["enabled"] == 1 {
                let fallbackPage = Ensemble100Page(sourceSHA256: sourceIdentity ?? "", original: original,
                    restored: original, removalMask: original, viewport: viewport,
                    items: result, rfRegions: regions, savedEvidence: [:])
                do {
                    let fallback = try NativeEnsembleTexturedContours.apply(fallbackPage, parameters: texturedParameters)
                    result = fallback.items; texturedAudit = fallback.audit
                    texturedDecisions = fallback.audit["decisions"] as? [[String: Any]] ?? []
                } catch {
                    // A new optional fallback must not discard earlier supported contours.
                    texturedAudit = ["status": "failed-preserved-base-contours",
                        "error": String(reflecting: error), "qualitySuccess": false]
                }
            }
            let addedTexture = texturedDecisions.filter { $0["status"] as? String == "added-textured-model-estimate" }
            let texturedByIndex = Dictionary(addedTexture.compactMap { row -> (Int, [String: Any])? in
                guard let index = row["itemIndex"] as? Int else { return nil }
                return (index, row)
            }, uniquingKeysWith: { first, _ in first })
            let finalDecisions = decisions.map { row -> [String: Any] in
                guard let index = row["itemIndex"] as? Int, var replacement = texturedByIndex[index] else { return row }
                replacement["baseStatus"] = row["status"]
                return replacement
            }
            var audit = proposal.audit
            audit["status"] = proposal.audit["status"] ?? "supplied-regions-original-rgb"
            audit["inputItems"] = items.count
            audit["outputItems"] = result.count
            audit["associatedItems"] = associated + addedTexture.count
            audit["addedModelContours"] = attached + addedTexture.count
            audit["nativeFallbackContours"] = nativeFallbacks
            audit["baseDecisions"] = decisions
            audit["decisions"] = finalDecisions
            audit["items"] = finalDecisions
            audit["textured"] = texturedAudit
            audit["texturedAddedModelContours"] = addedTexture.count
            audit["sourceBinding"] = sourceIdentity != nil && regionsSourceIdentity != nil
                ? "caller-identities-match; upstream-store-verifies-original" : "caller-bound-inputs; no-local-identity-proof"
            audit["authority"] = "RF exterior/holes with original-RGB boundary support; estimated placement capacity only"
            audit["removalMaskRead"] = false
            if let simplePlacement {
                // Only placement policies change. Do not serialize the typed
                // mask, manufacture a contour receipt, replace source native
                // interiors, or pass alternate regions to the erasure stages.
                result = try NativeOperationalRenderExpansion.reannotateGenerated(items:result,
                    viewport:viewport,source:original,regions:regions,simplePlacement:simplePlacement)
                result = try NativeOperationalRenderExpansion.annotate(items:result,viewport:viewport,
                    source:original,regions:regions,simplePlacement:simplePlacement)
                audit["simplePlacement"] = simplePlacement.audit
                audit["simplePlacementCapacityItems"] = result.filter {
                    $0["renderExpansionBoundaryAuthority"]as?String == "raw-rf-core-model-estimated-placement-only"
                }.count
                audit["simplePlacementAuthority"] = "typed model estimate; exact final pixel predicate required, no source/RGB certificate"
            }
            return (result, audit)
        } catch {
            return (items, ["status": "contour-refinement-error-preserved", "inputItems": items.count,
                            "error": String(reflecting: error)])
        }
    }

    /// Interpret either a retained native contour or a model estimate using the
    /// same normalized rect/spans representation as the frozen contour reader.
    /// This function does not certify the source, shape text or move any item.
    static func contour(raw: [String: Any], viewport: CGSize,
                        simplePlacement: NativeSimpleRFBalloonPlacement? = nil) -> Contour? {
        guard viewport.width.isFinite, viewport.height.isFinite,
              viewport.width > 0, viewport.height > 0 else { return nil }
        if let simplePlacement {
            do {
                if let exact = try simplePlacement.constraint(for:raw,viewport:viewport) {
                    let r=exact.capacity.rectNormalized,s=exact.capacity.primarySpans(owner:exact.sourceOwnerBoundsNormalized)
                    let pairs=stride(from:0,to:s.count,by:2).map{(CGFloat(s[$0])*viewport.width,CGFloat(s[$0+1])*viewport.width)}
                    return Contour(rect:CGRect(x:r[0]*viewport.width,y:r[1]*viewport.height,width:r[2]*viewport.width,height:r[3]*viewport.height),
                        spans:pairs,exactPlacement:exact)
                }
            } catch { return nil }
        }
        let unit = raw["balloonUnit"] as? [String: Any]
        let native = unit?["interior"] as? [String: Any]
        let primary = raw["balloonInterior"] as? [String: Any]
        if let primary, let result = decode(primary, viewport: viewport) { return result }
        // A verified native-unit contour may still be available if a top-level
        // model record is malformed. Never promote an unverified unit record.
        if let native, native["contourVerified"] as? Bool == true {
            return decode(native, viewport: viewport)
        }
        return nil
    }

    private static func decode(_ object: [String: Any], viewport: CGSize) -> Contour? {
        guard object["contourVerified"] as? Bool == true || object["modelEstimated"] as? Bool == true,
              let r = object["rect"] as? [Double], r.count == 4,
              let values = object["spans"] as? [Double], values.count >= 4,
              values.count <= 4096, values.count % 2 == 0,
              (r + values).allSatisfy(\.isFinite), r[2] > 0, r[3] > 0 else { return nil }
        let normalized = CGRect(x: r[0], y: r[1], width: r[2], height: r[3])
        guard CGRect(x: 0, y: 0, width: 1, height: 1).contains(normalized) else { return nil }
        var spans: [(CGFloat, CGFloat)] = []
        for i in stride(from: 0, to: values.count, by: 2) {
            guard values[i] >= r[0] - 1e-9, values[i + 1] <= r[0] + r[2] + 1e-9,
                  values[i] < values[i + 1] else { return nil }
            let left = max(r[0], values[i]) * viewport.width
            let right = min(r[0] + r[2], values[i + 1]) * viewport.width
            guard left.isFinite, right.isFinite, left < right else { return nil }
            spans.append((left, right))
        }
        guard zip(spans, spans.dropFirst()).allSatisfy({ min($0.0.1, $0.1.1) > max($0.0.0, $0.1.0) }) else { return nil }
        let rect = CGRect(x: r[0] * viewport.width, y: r[1] * viewport.height,
            width: r[2] * viewport.width, height: r[3] * viewport.height)
        guard rect.width > 0, rect.height > 0, rect.height / CGFloat(spans.count) > 0,
              [rect.minX, rect.minY, rect.maxX, rect.maxY].allSatisfy(\.isFinite) else { return nil }
        return Contour(rect: rect, spans: spans)
    }
}
