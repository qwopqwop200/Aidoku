import CoreGraphics
import Foundation

/// Frozen Next2 scores with a hard fill/stroke eligibility gate; no width or source-policy experiment.
enum EnsembleCandidate07Next: Ensemble100Candidate {
    static let defaults: [String: Double] = {
        var values = EnsembleCandidate07Next2.defaults
        values["minimumFillStrokeContrast"] = 3
        values["extraWidth1"] = 0; values["extraWidth2"] = 0
        return values
    }()
    static let ranges: [String: ClosedRange<Double>] = {
        var values = EnsembleCandidate07Next2.ranges
        // At <=4.5 at least one BW endpoint is feasible for every valid sRGB fill.
        values["minimumFillStrokeContrast"] = 3...4.5
        values["extraWidth1"] = 0...0; values["extraWidth2"] = 0...0
        return values
    }()
    private static func number(_ value: Any?) -> Double? {
        guard let v = (value as? NSNumber)?.doubleValue, v.isFinite else { return nil }; return v
    }
    private static func rgb(_ value: Any?) -> [Double]? {
        guard let a = value as? [Any], a.count == 3 else { return nil }
        let v = a.compactMap(number)
        return v.count == 3 && v.allSatisfy({ (0...255).contains($0) }) ? v : nil
    }
    private static func isBW(_ value: [Double]?) -> Bool { value == [0, 0, 0] || value == [255, 255, 255] }
    private static func contrast(_ a: [Double], _ b: [Double]) -> Double {
        func luminance(_ c: [Double]) -> Double {
            let v = c.map { $0 / 255 }.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
            return v[0] * 0.2126 + v[1] * 0.7152 + v[2] * 0.0722
        }
        let x = luminance(a), y = luminance(b)
        return (max(x, y) + 0.05) / (min(x, y) + 0.05)
    }
    static func apply(_ page: Ensemble100Page, parameters: [String: Double]) throws -> Ensemble100Proposal {
        var effective = defaults
        for key in defaults.keys {
            let proposed = parameters[key] ?? defaults[key]!, r = ranges[key]!
            effective[key] = min(r.upperBound, max(r.lowerBound, proposed.isFinite ? proposed : defaults[key]!))
        }
        guard effective["enabled"]! > 0 else {
            return Ensemble100Proposal(items: page.items, audit: ["agent07Next3": "disabled"])
        }
        let floor = effective["minimumFillStrokeContrast"]!
        // Keep the exact frozen scoring/source/paint path and fixed base width. Gate only its BW endpoints.
        var proposal = try EnsembleCandidate07Next2.apply(page, parameters: effective)
        var records: [[String: Any]] = []
        for index in page.items.indices {
            let raw = page.items[index]
            var audit = proposal.items[index]["ensembleStrokeAudit"] as? [String: Any] ?? [:]
            var paint = proposal.items[index]["ensembleStrokePaintPolicy"] as? [String: Any] ?? [:]
            let oldChoice = rgb(proposal.items[index]["ensembleDisplayStroke"])!
            let scores = audit["scores"] as? [[String: Any]] ?? []
            let fill = rgb(raw["ensembleDisplayFill"])
            audit["frozenWeightedChoice"] = oldChoice
            audit["minimumFillStrokeContrast"] = floor
            audit["widthPolicy"] = "fixed Next2 legal base; extraWidth1/2 forced zero"
            audit["sourcePredictionsChanged"] = false; audit["displayFillChanged"] = false
            var chosen = oldChoice, candidates: [[String: Any]] = []
            if let fill {
                for endpoint in [[0.0, 0, 0], [255.0, 255, 255]] {
                    let ratio = contrast(fill, endpoint), eligible = ratio + 1e-12 >= floor
                    let score = scores.first { rgb($0["stroke"]) == endpoint }
                    candidates.append(["stroke": endpoint, "actualFillStrokeContrast": ratio, "eligible": eligible,
                        "weightedScore": score?["score"] ?? NSNull(),
                        "reason": eligible ? "meets endpoint contrast floor; may compete by frozen score" :
                            "below fill/stroke contrast floor; rejected regardless of background/source weight"])
                }
                let feasible = candidates.filter { $0["eligible"] as? Bool == true }
                // Clamping floor <=4.5 guarantees at least one feasible BW colour; no relaxed-floor fallback.
                guard !feasible.isEmpty else {
                    throw NSError(domain: "Agent07Next3ContrastInvariant", code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "valid sRGB fill has no feasible BW endpoint at clamped floor"])
                }
                if !feasible.contains(where: { rgb($0["stroke"]) == oldChoice }) {
                    chosen = rgb(feasible.max { (number($0["weightedScore"]) ?? -.infinity) <
                        (number($1["weightedScore"]) ?? -.infinity) }!["stroke"])!
                    audit["decision"] = "weighted winner ineligible; select feasible BW endpoint; no weight can override gate"
                } else {
                    // Both-feasible source counterpart and tie policies are exactly the frozen Next2 decisions.
                    audit["decision"] = feasible.count == 2 ? "both feasible; frozen source/background score and tie policy unchanged" :
                        "frozen weighted winner is the only feasible BW endpoint"
                }
                audit["actualChosenFillStrokeContrast"] = contrast(fill, chosen)
                audit["eligibilityStatus"] = "verified against explicit current ensembleDisplayFill endpoint"
                paint["endpointContrastEligible"] = true
                paint["requiresResolvedFillContrastCheck"] = false
            } else {
                let existing = rgb(raw["ensembleDisplayStroke"])
                chosen = isBW(existing) ? existing! : [255, 255, 255]
                audit["decision"] = isBW(existing) ? "unknown display fill; preserve existing valid BW; contrast unverified" :
                    "unknown display fill and no valid existing BW; explicit mandatory white fallback; contrast unverified"
                audit["eligibilityStatus"] = "unknown; resolve actual displayed fill and rerun gate before accepting retained paint"
                audit["actualChosenFillStrokeContrast"] = NSNull()
                audit["weightedScoresInactive"] = true
                audit["sourceHierarchyConfidence"] = 0.0
                audit["sourceUncertainty"] = "actual display fill unknown; no source endpoint treated as resolved display fill"
                // Keep frozen measurements available, but never present their source/contrast terms as active decisions.
                audit["scores"] = []
                for endpoint in [[0.0, 0, 0], [255.0, 255, 255]] {
                    candidates.append(["stroke": endpoint, "actualFillStrokeContrast": NSNull(), "eligible": NSNull(),
                        "reason": "actual display fill unavailable; no contrast or source-role evidence fabricated"])
                }
                paint["endpointContrastEligible"] = false
                paint["requiresResolvedFillContrastCheck"] = true
            }
            audit["eligibilityCandidates"] = candidates
            audit["rejectedColors"] = candidates.filter { $0["eligible"] as? Bool == false }
            audit["selectedStroke"] = chosen
            paint["minimumFillStrokeContrast"] = floor
            paint["actualChosenFillStrokeContrast"] = audit["actualChosenFillStrokeContrast"]
            paint["retainedRasterCertified"] = false
            proposal.items[index]["ensembleDisplayStroke"] = chosen
            proposal.items[index]["ensembleStrokePaintPolicy"] = paint
            audit["paintPolicy"] = paint
            proposal.items[index]["ensembleStrokeAudit"] = audit
            records.append(audit)
        }
        proposal.audit = ["agent07Next3": records, "inputItems": page.items.count, "outputItems": proposal.items.count,
            "minimumFillStrokeContrast": floor, "widthSearch": false, "sourcePredictionsChanged": false,
            "actualImagesInspected": 0, "qualityAcceptance": "not established by source-counterpart proxy or synthetic invariants"]
        return proposal
    }
}
