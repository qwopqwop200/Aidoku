import CoreFoundation
import CoreGraphics
import Foundation

/// Optional, packet-wide positive CC projection. Does not modify the frozen
/// original-axis grouping helper, existing complete-component channel, source
/// rows, accepted-primary ancestry, masks or translated text.
enum NativeCausalPartialSourceProjector {
    struct Projection {
        /// Keys are ORIGINAL INPUT row ordinals, before clipping/filtering or
        /// accepted-primary reordering. Parent attaches while projecting that row.
        let sourceObservedExclusiveSubcolumnsByRow: [Int: [String: Any]]
        let audit: [String: Any]
    }

    static func project(_ originalRows: [[String: Any]], sourceIdentity: String,
                        originalSize: CGSize, enabled: Bool = false) -> Projection {
        func empty(_ status: String) -> Projection {
            Projection(sourceObservedExclusiveSubcolumnsByRow: [:],
                audit: ["enabled": enabled, "status": status, "completeInkCoverageCertified": false,
                        "newErasureAuthority": false])
        }
        guard enabled else { return empty("disabled") }
        let prefix = "canonical-rgb8:"
        guard sourceIdentity.hasPrefix(prefix) else { return empty("invalid-source-binding") }
        let digest = sourceIdentity.dropFirst(prefix.count)
        guard digest.utf8.count == 64,
              digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              originalSize.width.isFinite, originalSize.height.isFinite,
              originalSize.width.rounded() == originalSize.width, originalSize.height.rounded() == originalSize.height,
              (1...32768).contains(originalSize.width), (1...32768).contains(originalSize.height),
              originalRows.count <= 256 else { return empty("invalid-binding-or-row-budget") }

        var summaries: [Int: [String: Any]] = [:]
        var ownersByClaim: [String: Set<Int>] = [:]
        var consumedRuns = 0, deferredRows: [Int] = []
        for (index, row) in originalRows.enumerated() {
            guard let seeds = row["detectorSeedEvidence"] as? [[String: Any]], seeds.count <= 64 else { continue }
            // Count only explicitly exclusive run records; NEVER read, copy or
            // serialize sourceProbabilityROI/maps/ambiguous/candidate payloads.
            var rowRuns = 0
            for seed in seeds {
                guard let components = seed["components"] as? [[String: Any]], components.count <= 16 else { continue }
                for component in components {
                    if let runs = component["runs"] as? [Any] { rowRuns += min(runs.count, 8193) }
                }
            }
            guard rowRuns <= 8192, consumedRuns + rowRuns <= 131072 else {
                deferredRows.append(index); continue
            }
            consumedRuns += rowRuns
            guard let summary = NativeCausalParagraphAxisGrouping.compactObservedExclusiveSubset(
                seeds, originalSize: originalSize) else { continue }
            summaries[index] = summary
            for component in summary["components"] as? [[String: Any]] ?? [] {
                guard let claim = physicalClaim(component) else { continue }
                ownersByClaim[claim, default: []].insert(index)
            }
        }
        // A v2 component explicitly owned in TWO final OCR rows is uncertain
        // packet ancestry, not two independent anchors. Quarantine BOTH claims,
        // not a winner selected by iteration order or source rectangle overlap.
        let shared = Set(ownersByClaim.filter { $0.value.count > 1 }.keys)
        var attachments: [Int: [String: Any]] = [:], quarantineCount = 0, retainedCount = 0
        for index in summaries.keys.sorted() {
            var summary = summaries[index]!
            let before = summary["components"] as? [[String: Any]] ?? []
            let after = before.filter { component in
                guard let claim = physicalClaim(component) else { return false }
                return !shared.contains(claim)
            }
            quarantineCount += before.count - after.count; retainedCount += after.count
            summary["components"] = after
            summary["sourceIdentity"] = sourceIdentity
            summary["originalOCRRowIndex"] = index
            summary["sharedClaimQuarantinedComponents"] = before.count - after.count
            summary["packetWideExclusiveClaimCheck"] = true
            summary["complete"] = false
            summary["status"] = "observed-exclusive-subset"
            summary["omittedComponentCount"] = NSNull()
            // Preserve an empty attachment as explicit uncertainty, rather than
            // letting a caller accidentally retain a stale positive attachment.
            attachments[index] = summary
        }
        let examples = shared.sorted().prefix(32).map { claim -> [String: Any] in
            ["physicalComponentIdentity": claim, "originalOCRRowIndices": ownersByClaim[claim]!.sorted()]
        }
        return Projection(sourceObservedExclusiveSubcolumnsByRow: attachments,
            audit: ["enabled": true, "status": "packet-positive-exclusive-subcolumns-projected",
                "sourceIdentity": sourceIdentity, "inputRows": originalRows.count,
                "rowsWithAttachments": attachments.count, "retainedExclusiveComponents": retainedCount,
                "sharedPhysicalClaims": shared.count, "quarantinedComponentInstances": quarantineCount,
                "sharedClaimExamples": examples, "sharedClaimExamplesTruncated": shared.count > 32,
                "sourceRunRecordsInspectedUpperBound": consumedRuns, "sourceRunRecordBudget": 131072,
                "budgetDeferredOriginalRows": deferredRows,
                "completeInkCoverageCertified": false, "newErasureAuthority": false,
                "originalSourceOrTargetChanged": false])
    }

    private static func physicalClaim(_ component: [String: Any]) -> String? {
        func pair(_ value: Any?) -> [Int]? {
            guard let values = value as? [Any], values.count == 2 else { return nil }
            let parsed = values.compactMap(integer)
            return parsed.count == 2 ? parsed : nil
        }
        guard let grid = pair(component["detectorGridSize"]), let origin = pair(component["detectorGridOrigin"]),
              let seed = integer(component["componentSeed"]) else { return nil }
        return "\(grid[0])x\(grid[1]):\(origin[0]),\(origin[1]):\(seed)"
    }

    /// Live PRETRANSLATION ingress. Source strings occupy a private matching
    /// slot only; no target is fabricated or returned as a provider translation.
    /// Original rows must explicitly carry normalized geometry observations.
    static func pretranslationRequests(_ originalRows: [[String: Any]], sourceIdentity: String,
                                       originalSize: CGSize, enabled: Bool = false) -> [[String: Any]] {
        guard enabled, originalRows.count <= 256,
              originalRows.allSatisfy({ $0["translation"] == nil }),
              sourceIdentity.hasPrefix("canonical-rgb8:") else { return [] }
        let partial = project(originalRows, sourceIdentity: sourceIdentity, originalSize: originalSize, enabled: true)
        var rows: [[String: Any]] = [], items: [[String: Any]] = []
        for (index, raw) in originalRows.enumerated() {
            guard let text = raw["source"] as? String, !text.isEmpty,
                  let b = raw["sourceBounds"] as? [Double], b.count == 4 else { return [] }
            var row = raw.filter { ["source", "confidence", "sourceBounds", "sourceOrientation", "polygon",
                "sourceSingleVerticalColumn", "sourceGeometryObservation", "acceptedSourceAffiliation"].contains($0.key) }
            row["translation"] = text
            row["sourceObservedExclusiveSubcolumns"] = partial.sourceObservedExclusiveSubcolumnsByRow[index]
            rows.append(row)
            items.append(["id": "source-owner-ordinal:\(index)", "text": text, "sourceBounds": b])
        }
        let digest = String(sourceIdentity.dropFirst("canonical-rgb8:".count))
        let evidence: [String: Any] = ["sourceSHA256": sourceIdentity, "ocrSourceContentIdentity": digest,
            "originalOCR": ["width": Double(originalSize.width), "height": Double(originalSize.height),
                "coordinateSpace": "normalized-top-left", "authority": "observed-final-regions", "regions": rows]]
        return recognitionRequests(evidence: evidence, activeItems: items, originalSize: originalSize, enabled: true).map {
            var request = $0
            request["lexicalProvenanceDomain"] = "pretranslation-source-only; not target text"
            request["members"] = ($0["members"] as! [[String: Any]]).map { raw -> [String: Any] in
                var member = raw; member.removeValue(forKey: "target"); return member
            }
            return request
        }
    }

    /// Runtime consumer of the projected packet. Produces actual bounded
    /// original-pixel recognizer arguments, not whole-packet merge permission.
    /// Call AFTER incumbent graph grouping so accepted groups are not consumed.
    static func recognitionRequests(evidence: [String: Any], activeItems: [[String: Any]],
                                    originalSize: CGSize, enabled: Bool = false) -> [[String: Any]] {
        guard enabled, activeItems.count <= 256,
              let identity = evidence["sourceSHA256"] as? String,
              let ocr = evidence["originalOCR"] as? [String: Any],
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096 else { return [] }
        func bounds(_ value: Any?) -> [Double]? {
            let values: [Any]
            if let a = value as? [Any] { values = a }
            else if let d = value as? [String: Any] { values = ["x", "y", "width", "height"].compactMap { d[$0] } }
            else { return nil }
            let a = values.compactMap { ($0 as? NSNumber)?.doubleValue }
            guard a.count == 4, a.allSatisfy(\.isFinite), a[2] > 0, a[3] > 0 else { return nil }
            return a
        }
        var eligible = Set<Int>(), activeByRow: [Int: [String: Any]] = [:]
        for (index, row) in rows.enumerated() {
            guard let summary = row["sourceObservedExclusiveSubcolumns"] as? [String: Any],
                  summary["sourceIdentity"] as? String == identity,
                  summary["packetWideExclusiveClaimCheck"] as? Bool == true,
                  let b = bounds(row["sourceBounds"] ?? row["rect"]),
                  let target = row["translation"] as? String else { continue }
            let matches = activeItems.filter { item in
                guard item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                      (item["agent02MemberItems"] as? [Any] ?? []).isEmpty,
                      !(item["id"] as? String ?? "").contains("+"),
                      let t = item["text"] as? String, Array(t.utf16) == Array(target.utf16),
                      let a = bounds(item["sourceBounds"]) else { return false }
                return zip(a, b).allSatisfy { abs($0 - $1) < 1e-8 }
            }
            guard matches.count == 1 else { continue }
            eligible.insert(index); activeByRow[index] = matches[0]
        }
        let anchors = NativeCausalParagraphAxisGrouping.observedExclusiveSubcolumns(evidence: evidence,
            originalSize: originalSize, sourceRowIndices: eligible, enabled: true)
        let edges = NativeCausalParagraphAxisGrouping.observedAnchorEdges(anchors)
        var requests: [[String: Any]] = []
        for edge in edges where edge.requiresSourceRecognition {
            guard requests.count < 32, let crop = NativeCausalParagraphAxisGrouping.recognitionForObservedAnchor(
                edge, originalSize: originalSize) else { continue }
            let indices = crop.originalOCRRowIndices
            // An explicit source/paragraph disagreement remains a hard veto.
            var conflict = false
            for key in ["paragraphID", "paragraphIndex", "rfBodyIndex"] {
                let values = indices.compactMap { rows[$0][key] } + indices.compactMap { activeByRow[$0]?[key] }
                if let first = values.first, values.dropFirst().contains(where: {
                    !NSDictionary(dictionary: ["v": first]).isEqual(to: ["v": $0])
                }) { conflict = true }
            }
            if conflict { continue }
            let provenance = indices.map { index -> [String: Any] in
                let row = rows[index], summary = row["sourceObservedExclusiveSubcolumns"] as! [String: Any]
                var member: [String: Any] = ["projectedOCRRowIndex": index,
                    "originalInputOCRRowIndex": summary["originalOCRRowIndex"] ?? NSNull(),
                    "activeOwnerID": activeByRow[index]?["id"] ?? NSNull(),
                    "sourceBounds": bounds(row["sourceBounds"] ?? row["rect"]) ?? [],
                    "source": row["source"] ?? NSNull(), "target": row["translation"] ?? NSNull()]
                if let affiliation = row["acceptedSourceAffiliation"] { member["acceptedSourceAffiliation"] = affiliation }
                return member
            }
            requests.append(["sourceIdentity": identity, "originalSourceSize": [Double(originalSize.width), Double(originalSize.height)],
                "coordinateSpace": "original-pixels-top-left",
                "recognitionPixelQuad": crop.originalPixelQuad.map { [Double($0.x), Double($0.y)] },
                "members": provenance, "anchorKind": edge.kind,
                "observedGapOriginalPixels": edge.observedGapOriginalPixels,
                "anchors": crop.observedAnchors.map { anchor in
                    ["projectedOCRRowIndex": anchor.originalOCRRowIndex, "ownerID": anchor.ownerID,
                     "parentBoxIndex": anchor.parentBoxIndex, "componentSeeds": anchor.componentSeeds] as [String: Any]
                }, "requiresAcceptedPrimaryUnionValidation": true, "requiresRecognitionBeforeRetranslation": true,
                "missingInkIntervalCertified": false, "wholePacketUnionAuthorized": false,
                "sourceOrTargetRevisionApplied": false, "newErasureAuthority": false])
        }
        return requests
    }

    private static func integer(_ value: Any?) -> Int? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(),
              n.doubleValue.isFinite, n.doubleValue >= 0, n.doubleValue <= 1_073_741_824,
              n.doubleValue.rounded() == n.doubleValue else { return nil }
        return n.intValue
    }
}
