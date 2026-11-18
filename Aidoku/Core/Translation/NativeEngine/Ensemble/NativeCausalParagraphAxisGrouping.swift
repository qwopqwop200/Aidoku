import CoreGraphics
import CoreFoundation
import Foundation

/// A source paragraph is a collection of observed runs, not a display orientation,
/// target script cohort, or removal rectangle. Projections are comparison-only.
/// No OCR read/target is suppressed, including uncertain overlapping observations.
enum NativeCausalParagraphAxisGrouping {
    struct RecognitionQuad {
        let sourceIdentity: String
        /// Final/native observation row ordinal, NOT an accepted-primary ordinal.
        let originalOCRRowIndex: Int
        let originalSourceBounds: [Double]
        let originalPixelQuad: [CGPoint]
        /// TL,TR,BR,BL on the ORIGINAL image. Parent recognizer rectifies this
        /// quadrilateral; never interpret comparison coordinates as image pixels.
        let recognitionPixelQuad: [CGPoint]
        let sourceComponents: [[String: Any]]
        let overlappingOriginalRows: [Int]
        /// Forwarded only if actually supplied by accepted-source ingress. Never
        /// infer primary packet membership from OCR row or detector box indices.
        let acceptedSourceAffiliation: Any?
        let reason: String

        var audit: [String: Any] {
            ["sourceIdentity": sourceIdentity, "originalOCRRowIndex": originalOCRRowIndex,
             "originalSourceBounds": originalSourceBounds,
             "originalPixelQuad": originalPixelQuad.map { [$0.x, $0.y] },
             "recognitionPixelQuad": recognitionPixelQuad.map { [$0.x, $0.y] },
             "sourceComponents": sourceComponents, "overlappingOriginalRows": overlappingOriginalRows,
             "acceptedPrimaryAffiliationAvailable": acceptedSourceAffiliation != nil,
             "reason": reason, "coordinateSpace": "original-pixels-top-left",
             "componentBboxesAreGlyphTruth": false, "completeInkCoverageCertified": false,
             "grantsErasureAuthority": false, "sourceCorrectionOrNewTranslationEstablished": false]
        }
    }

    /// BEFORE TRANSLATION: proposals depend only on original source evidence,
    /// not target strings/height/rotation, paper colour, alpha or display style.
    /// Parent runs its recognizer on these source quads, validates observations,
    /// commits a real source transaction and only then translates the new source.
    static func recognitionQuads(evidence: [String: Any], imageSize: CGSize,
                                 sourceRowIndices: Set<Int>? = nil, enabled: Bool = false) -> [RecognitionQuad] {
        guard enabled, imageSize.width > 0, imageSize.height > 0,
              imageSize.width <= 131_072, imageSize.height <= 131_072,
              let identity = evidence["sourceSHA256"] as? String,
              let content = evidence["ocrSourceContentIdentity"] as? String, !content.isEmpty,
              identity == "canonical-rgb8:" + content,
              let ocr = evidence["originalOCR"] as? [String: Any],
              ocr["coordinateSpace"] as? String == "normalized-top-left",
              number(ocr["width"]) == imageSize.width, number(ocr["height"]) == imageSize.height,
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096 else { return [] }
        var proposals: [RecognitionQuad] = []
        let boxes = rows.map { rect($0["sourceBounds"] ?? $0["rect"]) }
        for (index, row) in rows.enumerated() {
            if let sourceRowIndices, !sourceRowIndices.contains(index) { continue }
            guard proposals.count < 256, let box = boxes[index], let q = points(row["polygon"]),
                  close(envelope(q), box),
                  let observation = row["sourceGeometryObservation"] as? [String: Any],
                  observation["rectClipped"] as? Bool == false, observation["polygonClipped"] as? Bool == false,
                  (row["clippedUnitMemberIndices"] as? [Int] ?? []).isEmpty else { continue }
            let parts = recognitionComponents(row, size: imageSize, sourceBox: box)
            let byOwner = Dictionary(grouping: parts) { Int(number($0["parentBoxIndex"])!) }
            let tallOwners = byOwner.values.filter { components in
                components.contains { component in
                    guard let r = rect(component["bounds"]) else { return false }
                    return r.height * imageSize.height >= r.width * imageSize.width * 1.5
                }
            }.count
            // A fused envelope can be wider than tall and labelled horizontal.
            // Its OWN distinct tall DB owners can still nominate column rereads.
            guard row["sourceOrientation"] as? String == "vertical" || tallOwners >= 2 else { continue }
            let p = q.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
            guard p[1].x > p[0].x, p[2].x > p[3].x, p[3].y > p[0].y, p[2].y > p[1].y else { continue }
            guard (0..<4).allSatisfy({ i in
                let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
                return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 1e-8
            }) else { continue }
            let single = row["sourceSingleVerticalColumn"] as? Bool == true
            let axis = single ? atan2(p[3].x - p[0].x + p[2].x - p[1].x,
                p[3].y - p[0].y + p[2].y - p[1].y) : 0
            guard abs(axis) <= 0.35 else { continue }
            let overlaps = boxes.indices.filter { other in
                other != index && boxes[other].map { coverage($0, box) >= 0.5 || coverage(box, $0) >= 0.5 } == true
            }
            func append(_ quad: [CGPoint], _ components: [[String: Any]], _ reason: String) {
                guard proposals.count < 256 else { return }
                proposals.append(RecognitionQuad(sourceIdentity: identity, originalOCRRowIndex: index,
                    originalSourceBounds: [box.minX, box.minY, box.width, box.height], originalPixelQuad: p,
                    recognitionPixelQuad: quad, sourceComponents: components, overlappingOriginalRows: overlaps,
                    acceptedSourceAffiliation: row["acceptedSourceAffiliation"], reason: reason))
            }
            // Keep the exact skewed source quad as an alternate recognizer view.
            // No fabricated component membership when compact evidence is absent.
            if single && abs(axis) >= 0.03 { append(p, parts, "exactSkewedSourceQuadReference") }
            guard byOwner.count >= 2 || (single && !parts.isEmpty) else { continue }
            let frame = projected(p, axis: axis)
            guard frame.width > 0, frame.height > 0 else { continue }
            for owner in byOwner.keys.sorted() {
                let components = byOwner[owner]!
                let ink = components.compactMap { rect($0["bounds"]) }.map { r -> CGRect in
                    let b = pixels(r, imageSize)
                    return projected([CGPoint(x: b.minX, y: b.minY), CGPoint(x: b.maxX, y: b.minY),
                        CGPoint(x: b.maxX, y: b.maxY), CGPoint(x: b.minX, y: b.maxY)], axis: axis)
                }.reduce(CGRect.null) { $0.union($1) }
                guard !ink.isNull, ink.height > ink.width * 1.4 else { continue }
                let margin = max(2, ink.width * 0.35)
                let u0 = max(0, min(1, (ink.minX - margin - frame.minX) / frame.width))
                let u1 = max(0, min(1, (ink.maxX + margin - frame.minX) / frame.width))
                guard u1 > u0, single || (u1 - u0) <= 0.75 else { continue }
                func mix(_ a: CGPoint, _ b: CGPoint, _ u: Double) -> CGPoint {
                    CGPoint(x: a.x + (b.x - a.x) * u, y: a.y + (b.y - a.y) * u)
                }
                // Bilinear strip stays inside the actual convex source quad;
                // preserve full source-column height for missing/ambiguous ink.
                let crop = [mix(p[0], p[1], u0), mix(p[0], p[1], u1), mix(p[3], p[2], u1), mix(p[3], p[2], u0)]
                append(crop, components, "ownedDBColumnOriginalPixelReread")
            }
        }
        return proposals
    }

    private static func recognitionComponents(_ row: [String: Any], size: CGSize, sourceBox: CGRect) -> [[String: Any]] {
        guard let summary = row["sourceOwnedDetectorComponents"] as? [String: Any],
              number(summary["version"]) == 1,
              summary["originalSourceSize"] as? [Double] == [size.width, size.height],
              let components = summary["components"] as? [[String: Any]], components.count <= 256 else { return [] }
        var identities = Set<String>()
        return components.filter { component in
            guard let parent = number(component["parentBoxIndex"]), parent >= 0, parent < 4096, parent.rounded() == parent,
                  let seed = number(component["componentSeed"]), seed >= 0, seed.rounded() == seed,
                  let count = number(component["pixels"]), count > 0,
                  let confidence = number(component["meanProbability"]), (0.9...1).contains(confidence),
                  let box = rect(component["bounds"]), coverage(box, sourceBox) >= 0.99,
                  identities.insert("\(parent):\(seed)").inserted else { return false }
            return true
        }
    }

    struct Result {
        let items: [[String: Any]]
        let audit: [String: Any]
        /// Parent must continue erasing these ORIGINAL owners, never merged bbox.
        let maskSourceItems: [[String: Any]]
    }

    private struct Run {
        let index: Int
        let row: [String: Any]
        let bounds: CGRect
        let quad: [CGPoint]
        let axis: Double
        let em: Double // comparison scale only; never an original font estimate
        let anchor: Bool
        let source: String
        let target: String
    }

    /// Run on the currently retained raw owners after accepted baseline grouping
    /// and ownership recovery, before mask creation/typography. Keep this OFF until
    /// centrally rendered. Palette/model admission still uses original members;
    /// labels and historical page IDs are never inputs. Absent admission retains.
    static func apply(_ items: [[String: Any]], evidence: [String: Any], imageSize: CGSize,
                      enabled: Bool = false, admitGroup: ([String: Any]) -> Bool = { _ in false }) -> Result {
        func result(_ output: [[String: Any]], _ audit: [String: Any]) -> Result {
            Result(items: output, audit: audit, maskSourceItems: items)
        }
        guard enabled else { return result(items, ["enabled": false]) }
        guard items.count <= 512, imageSize.width > 0, imageSize.height > 0,
              imageSize.width <= 131_072, imageSize.height <= 131_072,
              imageSize.width.isFinite, imageSize.height.isFinite,
              let identity = evidence["sourceSHA256"] as? String,
              let content = evidence["ocrSourceContentIdentity"] as? String,
              identity == "canonical-rgb8:" + content, !content.isEmpty,
              let ocr = evidence["originalOCR"] as? [String: Any],
              number(ocr["width"]) == imageSize.width, number(ocr["height"]) == imageSize.height,
              ocr["coordinateSpace"] as? String == "normalized-top-left",
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096 else {
            return result(items, ["enabled": true, "reason": "missingBoundOriginalOCR"])
        }
        var rejected: [[String: Any]] = [], runs: [Run] = []
        for i in items.indices {
            let item = items[i]
            // Preserve accepted baseline paragraphs as indivisible owners.
            guard (item["agent02MemberItems"] as? [Any] ?? []).isEmpty,
                  item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                  item["vertical"] as? Bool != true,
                  !["title", "sfx"].contains(item["sourceLettering"] as? String ?? ""),
                  let target = item["text"] as? String, !target.isEmpty, target.utf16.count <= 8192,
                  !target.contains("\n\n"), !target.contains("\u{2029}"),
                  let box = rect(item["sourceBounds"]) else { continue }
            let matches = rows.filter { rect($0["sourceBounds"] ?? $0["rect"]).map { close($0, box) } == true }
            guard matches.count == 1, let row = matches.first,
                  let source = row["source"] as? String, !source.isEmpty,
                  let saved = row["translation"] as? String,
                  exact(target, saved) || (exact(item["sourceOwnerCanonicalTranslation"] as? String ?? "", saved)
                    && exact(compact(target), compact(saved))),
                  let confidence = number(row["confidence"]), (0.65...1).contains(confidence),
                  let observed = row["sourceGeometryObservation"] as? [String: Any],
                  observed["rectClipped"] as? Bool == false, observed["polygonClipped"] as? Bool == false,
                  (row["clippedUnitMemberIndices"] as? [Int] ?? []).isEmpty,
                  let quad = points(row["polygon"]), close(envelope(quad), box),
                  points(item["sourcePolygon"]).map({ current in
                      zip(current, quad).allSatisfy { distance($0, $1) <= 1e-8 }
                  }) ?? true else {
                rejected.append(["index": i, "reason": "nonexactOrClippedSourceTargetProvenance"]); continue
            }
            let p = quad.map { CGPoint(x: $0.x * imageSize.width, y: $0.y * imageSize.height) }
            let pixelBox = pixels(box, imageSize)
            let vertical = row["sourceOrientation"] as? String == "vertical"
            let single = row["sourceSingleVerticalColumn"] as? Bool == true
            let axis = single ? atan2((p[3].x - p[0].x + p[2].x - p[1].x) / 2,
                (p[3].y - p[0].y + p[2].y - p[1].y) / 2) : 0
            guard abs(axis) <= 0.35 else {
                rejected.append(["index": i, "reason": "intentionalLargeSourceRotation"]); continue
            }
            let widths = ownInkWidths(row, size: imageSize)
            let scale: Double
            if !widths.isEmpty { scale = widths.sorted()[widths.count / 2] * 1.8 }
            else { scale = single ? (distance(p[0], p[1]) + distance(p[3], p[2])) / 2 : pixelBox.width }
            let anchor = vertical && source.count >= 5 && pixelBox.height >= pixelBox.width * 1.25
            runs.append(Run(index: i, row: row, bounds: pixelBox, quad: p, axis: axis,
                em: max(1, min(scale, pixelBox.width)), anchor: anchor, source: source, target: target))
        }
        guard runs.count <= 128 else { return result(items, ["enabled": true, "reason": "paragraphSearchBudgetExceeded"]) }
        var groups: [[Run]] = [], edges: [[String: Any]] = []
        // Whole-group constraints are re-evaluated for every extension; pairwise
        // unknown metadata must not bridge two different explicit paragraphs.
        for run in runs.filter(\.anchor).sorted(by: { $0.bounds.midX > $1.bounds.midX }) {
            var attached = false
            for g in groups.indices {
                let proposed = groups[g] + [run]
                if compatible(proposed, items: items) {
                    groups[g] = proposed; attached = true; break
                }
            }
            if !attached { groups.append([run]) }
        }
        // Direction of a tiny glyph is intrinsically uncertain. Only a unique
        // existing paragraph envelope can lend it a comparison axis; keep the
        // original observation, acceptedSource and ownership uncertainty intact.
        for run in runs.filter({ !$0.anchor }) {
            guard run.source.count <= 4 else { continue }
            let owners = groups.indices.filter { g in
                let members = groups[g]
                let box = members.reduce(CGRect.null) { $0.union($1.bounds) }
                let overlap = coverage(run.bounds, box)
                let em = members.map(\.em).sorted()[members.count / 2]
                let top = abs(run.bounds.minY - box.minY)
                return overlap >= 0.7 && (run.bounds.height <= em * 2.5 || top <= em)
                    && !conflict(members + [run], items: items)
            }
            if owners.count == 1 { groups[owners[0]].append(run) }
        }
        var replacements: [Int: [String: Any]] = [:], consumed = Set<Int>()
        for group in groups where group.count > 1 {
            guard group.count <= 12, !conflict(group, items: items), let joined = joined(group, items: items, size: imageSize) else { continue }
            let members = group.map(\.index).sorted()
            // Source correction must precede translation. A layout merge cannot
            // repair nested/fused words, so never concatenate these old targets
            // as a substitute for the parent's recognizer/source transaction.
            if group.contains(where: { !$0.anchor || $0.row["requiresSourceCorrection"] as? Bool == true }) ||
                hasProjectedSourceOverlap(group) {
                rejected.append(["indices": members, "reason": "sourceCorrectionBeforeRetranslationRequired",
                    "recognizerGeometryAPI": "recognitionQuads(evidence:imageSize:enabled:)"])
                continue
            }
            let union = group.reduce(CGRect.null) { $0.union($1.bounds) }
            let intervening = items.indices.contains { i in
                guard !members.contains(i), let box = rect(items[i]["sourceBounds"]) else { return false }
                return coverage(pixels(box, imageSize), union) >= 0.5
            }
            guard !intervening else {
                rejected.append(["indices": members, "reason": "interveningOriginalOwnerRetained"]); continue
            }
            let accepted = admitGroup(joined)
            edges.append(["indices": members, "accepted": accepted,
                "reason": accepted ? "sourceParagraphRepresentationAndOriginalAdmission" : "originalPaletteOrModelAdmissionRejected",
                "uncertainNestedOwnershipRetained": group.contains { !$0.anchor }])
            guard accepted else { continue }
            let slot = members[0]
            replacements[slot] = joined; consumed.formUnion(members)
        }
        let output = items.indices.compactMap { i -> [String: Any]? in
            replacements[i] ?? (consumed.contains(i) ? nil : items[i])
        }
        return result(output, ["enabled": true, "inputCount": items.count, "outputCount": output.count,
            "groups": edges, "rejected": rejected, "sourceIdentity": identity,
            "maskDelta": ["originalSourceOwnerArrayUnchanged": true, "newErasureAuthority": false,
                "rasterPixelDeltaMeasured": false, "authority": "original maskSourceItems retained; no raster mutation"],
            "requiresFreshShaping": true, "actualRasterOrQualityCertified": false])
    }

    private static func compatible(_ group: [Run], items: [[String: Any]]) -> Bool {
        guard group.count <= 12, !conflict(group, items: items),
              (group.map(\.axis).max()! - group.map(\.axis).min()!) <= 0.35 else { return false }
        let axis = group.map(\.axis).reduce(0, +) / Double(group.count)
        let boxes = group.map { projected($0.quad, axis: axis) }
        let em = group.map(\.em).sorted()[group.count / 2]
        guard boxes.map(\.minY).max()! - boxes.map(\.minY).min()! <= em * 1.1 else { return false }
        let ordered = boxes.sorted { $0.midX > $1.midX }
        for i in 1..<ordered.count {
            let a = ordered[i - 1], b = ordered[i]
            let gap = a.minX - b.maxX
            guard gap <= em * 1.2,
                  min(a.maxY, b.maxY) - max(a.minY, b.minY) >= min(a.height, b.height) * 0.7 else { return false }
            // Overlapping envelopes can represent different observed columns.
            // They never prove deduplication or grant additional erasure pixels.
            if gap < -em * 0.4 {
                let sources = group.map(\.source)
                guard Set(sources).count == sources.count,
                      !sources.indices.contains(where: { x in sources.indices.contains { y in x != y && sources[x].contains(sources[y]) } })
                else { return false }
            }
        }
        return true
    }

    private static func hasProjectedSourceOverlap(_ group: [Run]) -> Bool {
        let anchors = group.filter(\.anchor)
        guard !anchors.isEmpty else { return true }
        let axis = anchors.map(\.axis).reduce(0, +) / Double(anchors.count)
        let boxes = group.map { projected($0.quad, axis: axis) }
        return boxes.indices.contains { i in boxes.indices.contains { j in
            i < j && max(coverage(boxes[i], boxes[j]), coverage(boxes[j], boxes[i])) >= 0.5
        } }
    }

    private static func conflict(_ group: [Run], items: [[String: Any]]) -> Bool {
        for key in ["paragraphID", "paragraphIndex", "rfBodyIndex", "lightSurface", "fontName"] {
            let values = group.compactMap { items[$0.index][key] }
            if let first = values.first, values.dropFirst().contains(where: {
                !NSDictionary(dictionary: ["v": first]).isEqual(to: ["v": $0])
            }) { return true }
            let original = group.compactMap { $0.row[key] }
            if let first = original.first, original.dropFirst().contains(where: {
                !NSDictionary(dictionary: ["v": first]).isEqual(to: ["v": $0])
            }) { return true }
        }
        // `piece`/`display` are generated presentation roles, not observed
        // paragraph boundaries. Only ORIGINAL source role evidence may veto.
        let observedRoles = group.compactMap { $0.row["sourceLettering"] as? String }
        if Set(observedRoles).count > 1 { return true }
        return false
    }

    private static func joined(_ group: [Run], items: [[String: Any]], size: CGSize) -> [String: Any]? {
        let axis = group.filter(\.anchor).map(\.axis).reduce(0, +) / Double(group.filter(\.anchor).count)
        let ordered = group.sorted {
            let a = projected($0.quad, axis: axis), b = projected($1.quad, axis: axis)
            // A pair-dependent epsilon can make sort non-transitive. Preserve a
            // total geometric order, and explicitly retain nested-order doubt.
            if a.midX != b.midX { return a.midX > b.midX }
            if a.minY != b.minY { return a.minY < b.minY }
            return $0.index < $1.index
        }
        let targets = ordered.map(\.target), text = targets.joined(separator: " ")
        guard let scripts = scripts(text) else { return nil }
        let originals = ordered.map { items[$0.index] }
        var item = originals[0]
        let union = group.reduce(CGRect.null) { $0.union($1.bounds) }
        item["id"] = "source-axis:" + originals.compactMap { $0["id"] as? String }.joined(separator: "+")
        item["text"] = text
        item["sourceBounds"] = [union.minX / size.width, union.minY / size.height, union.width / size.width, union.height / size.height]
        item["x"] = union.minX; item["y"] = union.minY; item["width"] = union.width; item["height"] = union.height
        item["rotation"] = 0.0; item["vertical"] = false; item["uprightQuadText"] = false; item["drawsUprightQuadText"] = false
        item["sourceVertical"] = true; item["sourceSingleColumn"] = false
        item["fontScript"] = scripts.0; item["wrappingScript"] = scripts.1
        item["agent02MemberItems"] = originals
        item["agent02MemberIDs"] = originals.compactMap { $0["id"] as? String }
        item["agent02MemberIndices"] = ordered.map(\.index)
        item["sourceAxisSourceRows"] = ordered.map(\.row)
        item["sourceAxisAcceptedSourceAvailability"] = ordered.map { $0.row["acceptedSource"] == nil ? "unavailable" : "observed" }
        item["sourceAxisTargetUTF16"] = targets.map { Array($0.utf16) }
        item["sourceAxisOriginalPresentationRoles"] = originals.map { $0["sourceLettering"] ?? NSNull() }
        item["sourceAxisOriginalScriptDeclarations"] = originals.map {
            ["fontScript": $0["fontScript"] ?? NSNull(), "wrappingScript": $0["wrappingScript"] ?? NSNull()]
        }
        item["sourceAxisNestedOwnershipUnresolved"] = ordered.filter { !$0.anchor }.map(\.index)
        item["sourceAxisNestedTargetInsertionUncertain"] = ordered.contains { !$0.anchor }
        item["sourceAxisTargetOrderAuthority"] = "projected original columns right-to-left; nested lexical insertion not certified"
        item["sourceAxisOverlapRelations"] = ordered.indices.flatMap { i in
            ordered.indices.compactMap { j -> [String: Any]? in
                guard i < j, max(coverage(ordered[i].bounds, ordered[j].bounds),
                    coverage(ordered[j].bounds, ordered[i].bounds)) >= 0.5 else { return nil }
                return ["memberIndices": [ordered[i].index, ordered[j].index],
                    "physicalDeduplication": "unknown; both source and target observations retained"]
            }
        }
        item["sourceAxisMaskSourceItems"] = originals
        item["sourceAxisMaskGeometryUnchanged"] = true
        item["sourceAxisComparisonRadians"] = axis
        item["sourceAxisRequiresFreshShaping"] = true
        item["sourceAxisSourceUncertaintyPreserved"] = true
        // An envelope/ink-component comparison scale is not a paragraph font.
        // Keep each original estimate inside member provenance, not the first
        // fragment's inherited skew-fit size as a purported group observation.
        item.removeValue(forKey: "sourceFontSize")
        item["sourceAxisParagraphSourceFontUnknown"] = true
        item["sourceAxisTargetScriptAuthority"] = "reclassify complete retained Unicode scalar stream; original declarations retained"
        let fonts = originals.compactMap { number($0["fontSize"]) }.filter { $0 > 0 }
        guard let font = fonts.min() else { return nil }
        item["fontSize"] = font; item["lineHeight"] = max(font, originals.compactMap { number($0["lineHeight"]) }.min() ?? font * 1.3)
        // Display policy is separate from original palette/pen-width evidence.
        let fill = item["ensembleDisplayFill"] as? [Double] ?? [0, 0, 0]
        let dark = fill.count == 3 && fill.reduce(0, +) < 384
        item["ensembleDisplayStroke"] = dark ? [255, 255, 255] : [0, 0, 0]
        item["ensembleStrokeRatio"] = max(0.12, number(item["ensembleStrokeRatio"]) ?? 0.16)
        item["sourceAxisMandatoryBWStrokeReplan"] = true
        for key in ["sourcePolygon", "sourceQuad", "sourceNearLayout", "smallTextReference", "columnLayout", "uprightAlternative",
                    "unitPlannedCard", "typesettingText", "typesettingPreformattedRows", "balloonUnit", "rotationPlannedFontSize",
                    "ensembleLockLayout", "ensemblePaletteAudit", "ensembleDominantColorEvidenceV2Audit", "ensembleStrokeAudit",
                    "sourceLettering"] {
            item.removeValue(forKey: key)
        }
        return item
    }

    private static func ownInkWidths(_ row: [String: Any], size: CGSize) -> [Double] {
        guard let summary = row["sourceOwnedDetectorComponents"] as? [String: Any],
              number(summary["version"]) == 1,
              summary["originalSourceSize"] as? [Double] == [size.width, size.height],
              let components = summary["components"] as? [[String: Any]], components.count <= 256 else { return [] }
        // Positive exclusive observations remain useful in a partial packet.
        // Completeness is NOT inferred and this never controls mask authority.
        return components.compactMap {
            guard let pixels = number($0["pixels"]), pixels >= 32,
                  let confidence = number($0["meanProbability"]), (0.9...1).contains(confidence),
                  let box = rect($0["bounds"]), box.height * size.height >= box.width * size.width * 1.5 else { return nil }
            return box.width * size.width
        }
    }

    private static func scripts(_ text: String) -> (String, String)? {
        var hangul = 0, other = 0, kana = 0, han = 0
        for s in text.unicodeScalars {
            switch s.value {
            case 0x1100...0x11FF, 0x3130...0x318F, 0xAC00...0xD7AF: hangul += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF: kana += 1
            case 0x3400...0x9FFF, 0xF900...0xFAFF: han += 1
            case 0x0590...0x08FF, 0x202A...0x202E, 0x2066...0x2069: return nil
            default: if s.properties.isAlphabetic { other += 1 }
            }
        }
        let wrap = hangul > 0 && hangul >= kana + han && hangul >= other ? "korean" : kana + han > 0 && kana + han >= other ? "cjk" : "word"
        return (kana > 0 ? "japanese" : wrap == "cjk" ? "han" : wrap, wrap)
    }
    private static func projected(_ p: [CGPoint], axis: Double) -> CGRect {
        envelope(p.map { CGPoint(x: cos(axis) * $0.x - sin(axis) * $0.y, y: sin(axis) * $0.x + cos(axis) * $0.y) })
    }
    private static func pixels(_ r: CGRect, _ size: CGSize) -> CGRect {
        CGRect(x: r.minX * size.width, y: r.minY * size.height, width: r.width * size.width, height: r.height * size.height)
    }
    private static func rect(_ value: Any?) -> CGRect? {
        let a: [Double]
        if let v = value as? [Double] { a = v }
        else if let v = value as? [String: Double], let x = v["x"], let y = v["y"], let w = v["width"], let h = v["height"] { a = [x, y, w, h] }
        else { return nil }
        guard a.count == 4, a.allSatisfy(\.isFinite), a[0] >= 0, a[1] >= 0, a[2] > 0, a[3] > 0,
              a[0] + a[2] <= 1.00000001, a[1] + a[3] <= 1.00000001 else { return nil }
        return CGRect(x: a[0], y: a[1], width: a[2], height: a[3])
    }
    private static func points(_ value: Any?) -> [CGPoint]? {
        let values: [[Double]]
        if let v = value as? [[Double]] { values = v }
        else if let v = value as? [[String: Double]] { values = v.compactMap { p in
            guard let x = p["x"], let y = p["y"] else { return nil }; return [x, y]
        } } else { return nil }
        guard values.count == 4, values.allSatisfy({ $0.count == 2 && $0.allSatisfy({ $0.isFinite && (0...1).contains($0) }) }) else { return nil }
        return values.map { CGPoint(x: $0[0], y: $0[1]) }
    }
    private static func envelope(_ p: [CGPoint]) -> CGRect {
        CGRect(x: p.map(\.x).min()!, y: p.map(\.y).min()!,
            width: p.map(\.x).max()! - p.map(\.x).min()!, height: p.map(\.y).max()! - p.map(\.y).min()!)
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func coverage(_ a: CGRect, _ b: CGRect) -> Double {
        let i = a.intersection(b); return i.isNull ? 0 : i.width * i.height / (a.width * a.height)
    }
    private static func close(_ a: CGRect, _ b: CGRect) -> Bool {
        zip([a.minX, a.minY, a.width, a.height], [b.minX, b.minY, b.width, b.height]).allSatisfy { abs($0 - $1) <= 1e-8 }
    }
    private static func exact(_ a: String, _ b: String) -> Bool { Array(a.utf16) == Array(b.utf16) }
    private static func compact(_ text: String) -> String { String(text.filter { !$0.isWhitespace }) }
    private static func distance(_ a: CGPoint, _ b: CGPoint) -> Double { hypot(a.x - b.x, a.y - b.y) }
}

// MARK: - Source-bound comparison and unsealed shaping contract (v75)

extension NativeCausalParagraphAxisGrouping {
    /// These intervals describe possible INK endpoints inside an observed source
    /// envelope, not nominal glyph size. Complete DB scanning is not glyph truth.
    struct AxisExtentInterval {
        let possibleStart: ClosedRange<Double>
        let possibleEnd: ClosedRange<Double>
        let observedPositiveSupport: ClosedRange<Double>?
        let envelope: ClosedRange<Double>
        let glyphExtentCertified = false
    }

    struct SourceAxisMember {
        let itemIndex: Int
        let originalOCRRowIndex: Int
        let originalItem: [String: Any]
        let originalRow: [String: Any]
        let originalPixelQuad: [CGPoint]
        /// Nil for a fused/multicolumn rectangle. The common reference axis is
        /// then a comparison hypothesis, NOT an observation of this member.
        let ownQuadAxisRadians: ClosedRange<Double>?
        let projectedEnvelope: CGRect
        let across: AxisExtentInterval
        let along: AxisExtentInterval
        let exclusiveComponents: [[String: Any]]
        let componentStatus: String
        let componentScanComplete: Bool
    }

    enum ParagraphContinuityBasis: String {
        case originalPixelContinuity
        case acceptedSourceTransaction
    }

    /// Parent supplies an independently validated source-continuity observation.
    /// Shared RF boxes, common colour, display script and labels are NOT bases.
    /// The helper validates binding, not the truth of the parent's observation.
    struct ParagraphContinuity {
        let sourceIdentity: String
        let originalOCRRowIndices: Set<Int>
        let basis: ParagraphContinuityBasis
        let observationID: String
    }

    struct TargetMemberRange {
        let itemIndex: Int
        let originalOCRRowIndex: Int
        let utf16Range: Range<Int>
        let exactText: String
        let originalFontScript: String?
        let originalWrappingScript: String?
    }

    struct MixedTargetScriptDecision {
        let fontScript: String?
        let wrappingScript: String?
        let scalarCounts: [String: Int]
        let originalDeclarationsDiffer: Bool
        /// Parent must explicitly accept this decision and perform fresh shaping;
        /// no inherited font/layout/paint certificate is valid for the new text.
        let requiresFreshShaping = true
        let requiresSpecializedShaper: Bool
    }

    struct ParagraphShapingPlan {
        let sourceIdentity: String
        let exactCombinedText: String
        let membersInSourceOrder: [TargetMemberRange]
        let scriptDecision: MixedTargetScriptDecision
        /// Layout search envelope only; must NEVER become mask/sourceBounds.
        let originalPixelLayoutSearchEnvelope: CGRect
        let continuity: ParagraphContinuity
        let requiresOriginalMemberPaletteAdmission = true
        let requiresFinalNonzeroBWStroke = true
        let originalSourceFontUnknown = true
    }

    enum PairPreparationStatus: String {
        case disabled
        case invalidEvidence
        case unsupportedSourceGeometry
        case independentParagraphEvidenceRequired
        case sourceRecognitionRequired
        case specializedTargetShaperRequired
        case readyForFreshShaping
    }

    struct PairPreparation {
        let status: PairPreparationStatus
        let reason: String
        let sourceIdentity: String?
        /// Deskew is exclusively a projection. No input dictionary is mutated.
        let commonComparisonRadians: Double?
        let observedAxisRange: ClosedRange<Double>?
        let members: [SourceAxisMember]
        let projectedAcrossGap: Double?
        let recognitionRequests: [RecognitionQuad]
        let shapingPlan: ParagraphShapingPlan?
        let originalMaskSourceItems: [[String: Any]]
        let grantsErasureAuthority = false
    }

    /// Production integration seam. Use this API, NOT the legacy experimental
    /// `apply` above. Feed CURRENT retained raw owners and the source-bound compact
    /// OCR packet before grouping/shaping; never feed labels or target answers.
    /// Incomplete ownership returns useful projections/reread geometry but never
    /// a concatenation of stale translations masquerading as a source repair.
    static func preparePair(_ items: [[String: Any]], indices: [Int],
                            evidence: [String: Any], originalSize: CGSize,
                            continuity: ParagraphContinuity? = nil,
                            enabled: Bool = false) -> PairPreparation {
        var identity: String?
        var reference: Double?
        var axisRange: ClosedRange<Double>?
        var members: [SourceAxisMember] = []
        var requests: [RecognitionQuad] = []
        var gap: Double?
        func finish(_ status: PairPreparationStatus, _ reason: String,
                    _ plan: ParagraphShapingPlan? = nil) -> PairPreparation {
            PairPreparation(status: status, reason: reason, sourceIdentity: identity,
                commonComparisonRadians: reference, observedAxisRange: axisRange,
                members: members, projectedAcrossGap: gap, recognitionRequests: requests,
                shapingPlan: plan, originalMaskSourceItems: items)
        }
        guard enabled else { return finish(.disabled, "default-off") }
        guard items.count <= 256, indices.count == 2, Set(indices).count == 2,
              indices.allSatisfy({ items.indices.contains($0) }),
              originalSize.width.isFinite, originalSize.height.isFinite,
              originalSize.width > 0, originalSize.height > 0,
              originalSize.width <= 32768, originalSize.height <= 32768,
              let content = evidence["ocrSourceContentIdentity"] as? String,
              content.utf8.count == 64, content.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              let packetID = evidence["sourceSHA256"] as? String, packetID == "canonical-rgb8:" + content,
              let ocr = evidence["originalOCR"] as? [String: Any],
              ocr["coordinateSpace"] as? String == "normalized-top-left",
              ["observed-final-regions", "explicitly-normalized-native-lines"].contains(ocr["authority"] as? String ?? ""),
              number(ocr["width"]) == originalSize.width, number(ocr["height"]) == originalSize.height,
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096 else {
            return finish(.invalidEvidence, "invalid-packet-or-pair-binding")
        }
        identity = packetID
        var inputs: [(Int, Int, [String: Any], [CGPoint], ClosedRange<Double>?)] = []
        for index in indices {
            let item = items[index]
            guard item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                  item["vertical"] as? Bool != true,
                  (item["agent02MemberItems"] as? [Any] ?? []).isEmpty,
                  !(item["id"] as? String ?? "").contains("+"),
                  !["sfx", "title"].contains(item["sourceLettering"] as? String ?? ""),
                  let bounds = rect(item["sourceBounds"]),
                  let target = item["text"] as? String, !target.isEmpty, target.utf16.count <= 8192,
                  !target.contains("\n\n"), !target.contains("\u{2029}"),
                  let itemQuad = points(item["sourcePolygon"]) else {
                return finish(.invalidEvidence, "unsupported-or-already-grouped-owner")
            }
            let matches = rows.indices.filter { rect(rows[$0]["sourceBounds"] ?? rows[$0]["rect"]).map { close($0, bounds) } == true }
            guard matches.count == 1, let rowIndex = matches.first else {
                return finish(.invalidEvidence, "nonunique-original-source-footprint")
            }
            let row = rows[rowIndex]
            guard row["sourceOrientation"] as? String == "vertical",
                  !["sfx", "title"].contains(row["sourceLettering"] as? String ?? ""),
                  let source = row["source"] as? String, !source.isEmpty, source.utf16.count <= 8192,
                  !source.contains("\n\n"), !source.contains("\u{2029}"),
                  let targetAtSource = row["translation"] as? String, exact(target, targetAtSource),
                  let confidence = number(row["confidence"]), (0...1).contains(confidence),
                  let geometry = row["sourceGeometryObservation"] as? [String: Any],
                  geometry["rectClipped"] as? Bool == false, geometry["polygonClipped"] as? Bool == false,
                  (row["clippedUnitMemberIndices"] as? [Int] ?? []).isEmpty,
                  let quad = points(row["polygon"]), close(envelope(quad), bounds),
                  zip(itemQuad, quad).allSatisfy({ distance($0, $1) <= 1e-8 }) else {
                return finish(.invalidEvidence, "nonexact-source-target-quad-or-clipped-observation")
            }
            let p = quad.map { CGPoint(x: $0.x * originalSize.width, y: $0.y * originalSize.height) }
            guard (0..<4).allSatisfy({ i in
                let a = p[i], b = p[(i + 1) % 4], c = p[(i + 2) % 4]
                return (b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) > 1e-8
            }), p[3].y > p[0].y, p[2].y > p[1].y else {
                return finish(.unsupportedSourceGeometry, "nonconvex-or-unordered-original-quad")
            }
            var ownAxis: ClosedRange<Double>?
            if row["sourceSingleVerticalColumn"] as? Bool == true {
                let left = atan2(p[3].x - p[0].x, p[3].y - p[0].y)
                let right = atan2(p[2].x - p[1].x, p[2].y - p[1].y)
                guard abs(left - right) <= 0.05, max(abs(left), abs(right)) <= 0.35 else {
                    return finish(.unsupportedSourceGeometry, "source-quad-axis-not-narrow-parallel-vertical")
                }
                ownAxis = min(left, right)...max(left, right)
            }
            inputs.append((index, rowIndex, row, p, ownAxis))
        }
        // Explicit source/paragraph disagreement remains a hard veto; absent
        // metadata is unknown, never proof that both belong to one paragraph.
        for key in ["paragraphID", "paragraphIndex", "rfBodyIndex", "lightSurface"] {
            let declared = inputs.flatMap { input in [items[input.0][key], input.2[key]].compactMap { $0 } }
            if let first = declared.first, declared.dropFirst().contains(where: {
                !NSDictionary(dictionary: ["v": first]).isEqual(to: ["v": $0])
            }) { return finish(.invalidEvidence, "different-explicit-" + key) }
        }
        let observedAxes = inputs.compactMap { $0.4 }
        guard let low = observedAxes.map(\.lowerBound).min(), let high = observedAxes.map(\.upperBound).max(),
              high - low <= 0.1 else {
            return finish(.unsupportedSourceGeometry, "missing-or-disagreeing-original-column-axes")
        }
        axisRange = low...high
        let axis = (low + high) / 2
        reference = axis
        for (index, rowIndex, row, quad, ownAxis) in inputs {
            let box = projected(quad, axis: axis)
            let summary = comparisonComponents(row, size: originalSize)
            var observed = CGRect.null
            for component in summary.components {
                guard let b = rect(component["bounds"]) else { continue }
                let p = pixels(b, originalSize)
                let projection = projected([CGPoint(x: p.minX, y: p.minY), CGPoint(x: p.maxX, y: p.minY),
                    CGPoint(x: p.maxX, y: p.maxY), CGPoint(x: p.minX, y: p.maxY)], axis: axis)
                // A component bbox can extend outside a skew quad even when
                // its cells are owned. Intersect ONLY this comparison interval;
                // the exact component/provenance and original mask stay intact.
                let intersection = projection.intersection(box)
                if !intersection.isNull { observed = observed.union(intersection) }
            }
            func interval(_ start: Double, _ end: Double, _ a: Double, _ b: Double) -> AxisExtentInterval {
                let support: ClosedRange<Double>? = observed.isNull ? nil : max(start, a)...min(end, b)
                return AxisExtentInterval(possibleStart: start...(support?.lowerBound ?? end),
                    possibleEnd: (support?.upperBound ?? start)...end,
                    observedPositiveSupport: support, envelope: start...end)
            }
            members.append(SourceAxisMember(itemIndex: index, originalOCRRowIndex: rowIndex,
                originalItem: items[index], originalRow: row, originalPixelQuad: quad,
                ownQuadAxisRadians: ownAxis, projectedEnvelope: box,
                across: interval(box.minX, box.maxX, observed.minX, observed.maxX),
                along: interval(box.minY, box.maxY, observed.minY, observed.maxY),
                exclusiveComponents: summary.components, componentStatus: summary.status,
                componentScanComplete: summary.complete))
        }
        let ordered = members.sorted {
            if $0.projectedEnvelope.midX != $1.projectedEnvelope.midX {
                return $0.projectedEnvelope.midX > $1.projectedEnvelope.midX
            }
            return $0.itemIndex < $1.itemIndex
        }
        gap = ordered[0].projectedEnvelope.minX - ordered[1].projectedEnvelope.maxX
        let needsRecognition = members.contains {
            !$0.componentScanComplete || $0.ownQuadAxisRadians == nil ||
                $0.across.observedPositiveSupport == nil || $0.along.observedPositiveSupport == nil ||
                (number($0.originalRow["confidence"]) ?? 0) < 0.8 ||
                $0.originalRow["requiresSourceCorrection"] as? Bool == true
        }
        if needsRecognition {
            // Exact original quad is always available, even when DB components
            // are missing. It does not invent a narrow sub-column for a fused
            // rectangle. Parent can add validated narrow recognizer proposals.
            requests = members.map { member in
                RecognitionQuad(sourceIdentity: packetID, originalOCRRowIndex: member.originalOCRRowIndex,
                    originalSourceBounds: [Double](member.originalItem["sourceBounds"] as? [Double] ?? []),
                    originalPixelQuad: member.originalPixelQuad, recognitionPixelQuad: member.originalPixelQuad,
                    sourceComponents: member.exclusiveComponents, overlappingOriginalRows: members.filter {
                        $0.itemIndex != member.itemIndex && coverage(envelope($0.originalPixelQuad), envelope(member.originalPixelQuad)) > 0
                    }.map(\.originalOCRRowIndex),
                    acceptedSourceAffiliation: member.originalRow["acceptedSourceAffiliation"],
                    reason: "incomplete-source-interval-requires-real-recognition-before-retranslation")
            }
            return finish(.sourceRecognitionRequired, "incomplete-source-support-or-unobserved-fused-axis; no-stale-target-merge")
        }
        let right = ordered[0].projectedEnvelope, left = ordered[1].projectedEnvelope
        let alongOverlap = min(right.maxY, left.maxY) - max(right.minY, left.minY)
        guard alongOverlap >= min(right.height, left.height) * 0.35,
              gap! <= max(right.width, left.width) * 1.2,
              max(coverage(right, left), coverage(left, right)) < 0.7 else {
            return finish(.unsupportedSourceGeometry, "nonlocal-or-deeply-overlapping-source-projections")
        }
        guard let continuity, continuity.sourceIdentity == packetID,
              continuity.originalOCRRowIndices == Set(members.map(\.originalOCRRowIndex)),
              !continuity.observationID.isEmpty, continuity.observationID.utf8.count <= 256 else {
            return finish(.independentParagraphEvidenceRequired, "projection-is-not-paragraph-membership")
        }
        var text = "", ranges: [TargetMemberRange] = []
        for member in ordered {
            if !text.isEmpty { text += " " }
            let target = member.originalItem["text"] as! String
            let start = text.utf16.count
            text += target
            ranges.append(TargetMemberRange(itemIndex: member.itemIndex, originalOCRRowIndex: member.originalOCRRowIndex,
                utf16Range: start..<text.utf16.count, exactText: target,
                originalFontScript: member.originalItem["fontScript"] as? String,
                originalWrappingScript: member.originalItem["wrappingScript"] as? String))
        }
        let decision = mixedTargetScripts(text, ranges: ranges)
        let plan = ParagraphShapingPlan(sourceIdentity: packetID, exactCombinedText: text,
            membersInSourceOrder: ranges, scriptDecision: decision,
            originalPixelLayoutSearchEnvelope: members.reduce(CGRect.null) { $0.union(envelope($1.originalPixelQuad)) },
            continuity: continuity)
        return finish(decision.requiresSpecializedShaper ? .specializedTargetShaperRequired : .readyForFreshShaping,
            "unsealed-plan; parent-must-admit-original-palette-and-recompute-layout-and-final-BWstroke", plan)
    }

    private static func comparisonComponents(_ row: [String: Any], size: CGSize)
        -> (components: [[String: Any]], status: String, complete: Bool) {
        guard let s = row["sourceOwnedDetectorComponents"] as? [String: Any], number(s["version"]) == 1,
              let dimensions = numericPair(s["originalSourceSize"]), dimensions == [size.width, size.height],
              s["coordinateSpace"] as? String == "normalized-top-left",
              let status = s["status"] as? String,
              ["complete-exclusive-components", "partial-exclusive-components", "observed-exclusive-subset"].contains(status),
              let components = s["components"] as? [[String: Any]], !components.isEmpty, components.count <= 16 else {
            return ([], "absent-or-invalid", false)
        }
        var identities = Set<String>()
        for c in components {
            guard let parent = number(c["parentBoxIndex"]), parent.rounded() == parent, (0..<4096).contains(parent),
                  let seed = number(c["componentSeed"]), seed.rounded() == seed, seed >= 0,
                  let owner = c["ownerID"] as? String, !owner.isEmpty, owner.utf8.count <= 160,
                  let grid = numericPair(c["detectorGridSize"]),
                  grid.allSatisfy({ $0.rounded() == $0 && (1...32768).contains($0) }),
                  seed < grid[0] * grid[1],
                  let origin = numericPair(c["detectorGridOrigin"]),
                  zip(origin, grid).allSatisfy({ $0.rounded() == $0 && $0 >= 0 && $0 < $1 }),
                  owner == "db:\(Int(grid[0]))x\(Int(grid[1])):\(Int(origin[0])),\(Int(origin[1])):\(Int(parent))",
                  let count = number(c["pixels"]), count.rounded() == count, (1...262144).contains(count),
                  let probability = number(c["meanProbability"]), (0.9...1).contains(probability), rect(c["bounds"]) != nil,
                  identities.insert("\(grid):\(origin):\(owner):\(parent):\(seed)").inserted else {
                return ([], "invalid-component-binding", false)
            }
        }
        let complete = status == "complete-exclusive-components" && s["complete"] as? Bool == true &&
            number(s["omittedComponentCount"]) == 0 && number(s["omittedSeedCount"] ?? 0) == 0
        return (components, status, complete)
    }

    private static func numericPair(_ value: Any?) -> [Double]? {
        guard let array = value as? [Any], array.count == 2,
              let a = number(array[0]), let b = number(array[1]) else { return nil }
        return [a, b]
    }

    private static func mixedTargetScripts(_ text: String, ranges: [TargetMemberRange]) -> MixedTargetScriptDecision {
        var counts = ["hangul": 0, "latin": 0, "kana": 0, "han": 0, "otherAlphabetic": 0]
        var special = false
        for scalar in text.unicodeScalars {
            switch scalar.value {
            case 0x1100...0x11FF, 0x3130...0x318F, 0xA960...0xA97F, 0xAC00...0xD7FF: counts["hangul", default: 0] += 1
            case 0x0041...0x005A, 0x0061...0x007A, 0x00C0...0x024F: counts["latin", default: 0] += 1
            case 0x3040...0x30FF, 0x31F0...0x31FF: counts["kana", default: 0] += 1
            case 0x3400...0x9FFF, 0xF900...0xFAFF, 0x20000...0x323AF: counts["han", default: 0] += 1
            case 0x202A...0x202E, 0x2066...0x2069: special = true
            default:
                if scalar.properties.isAlphabetic { counts["otherAlphabetic", default: 0] += 1; special = true }
            }
        }
        let hangul = counts["hangul"]!, cjk = counts["kana"]! + counts["han"]!
        let wrap = hangul > 0 && hangul >= cjk && hangul >= counts["latin"]! ? "korean" : cjk > 0 ? "cjk" : "word"
        let font = counts["kana"]! > 0 ? "japanese" : wrap == "cjk" ? "han" : wrap
        return MixedTargetScriptDecision(fontScript: special ? nil : font, wrappingScript: special ? nil : wrap,
            scalarCounts: counts, originalDeclarationsDiffer: Set(ranges.map {
                ($0.originalFontScript ?? "<unknown>") + "/" + ($0.originalWrappingScript ?? "<unknown>")
            }).count > 1, requiresSpecializedShaper: special)
    }
}

extension NativeCausalParagraphAxisGrouping {
    struct ObservedExclusiveSubcolumn {
        let sourceIdentity: String
        let originalOCRRowIndex: Int
        let ownerID: String
        let parentBoxIndex: Int
        let componentSeeds: [Int]
        let originalPixelObservedEnvelope: CGRect
        let originalSourceEnvelope: CGRect
        let packetComplete: Bool
        let wholePacketAxisCertified = false
        let grantsErasureAuthority = false
    }

    struct ObservedAnchorEdge {
        let first: ObservedExclusiveSubcolumn
        let second: ObservedExclusiveSubcolumn
        let kind: String
        let observedGapOriginalPixels: Double
        let observedOverlapOriginalPixels: Double
        /// Graph must keep the edge's OWNED segment endpoints. This edge is NOT
        /// permission to union all missing/ambiguous columns of either packet.
        let wholePacketUnionAuthorized = false
        let requiresOriginalPixelCorridor = true
        var requiresSourceRecognition: Bool { kind == "incomplete-same-axis-observed-anchors" }
    }

    struct AnchoredSourceRecognition {
        let sourceIdentity: String
        let originalOCRRowIndices: [Int]
        let originalPixelQuad: [CGPoint]
        let observedAnchors: [ObservedExclusiveSubcolumn]
        let missingInkIntervalCertified = false
        let grantsErasureAuthority = false
    }

    /// Compact ingress adapter for ORIGINAL v2 CC seeds. Unlike the legacy
    /// projector, a mixed seed's explicitly EXCLUSIVE `components` are retained;
    /// ambiguous/candidate components and ROI bytes are never imported. Call at
    /// packet projection, BEFORE those source observations have been dropped.
    /// No source text, display state, labels or font estimates enter this method.
    static func compactObservedExclusiveSubset(_ value: Any?, originalSize: CGSize) -> [String: Any]? {
        guard originalSize.width.isFinite, originalSize.height.isFinite,
              let seeds = value as? [[String: Any]], !seeds.isEmpty, seeds.count <= 64 else { return nil }
        func integer(_ v: Any?, _ limit: Double) -> Double? {
            guard let n = number(v), n >= 0, n < limit, n.rounded() == n else { return nil }; return n
        }
        var accepted: [[String: Any]] = [], claims: [String: Int] = [:]
        var excluded = 0, ambiguous = 0, candidates = 0, totalRuns = 0
        for seed in seeds {
            guard seed["provenance"] as? String == "db-complete-cc-candidates-v2",
                  number(seed["ownershipVersion"]) == 2, seed["completeCCScan"] as? Bool == true,
                  number(seed["sourceWidth"]) == originalSize.width, number(seed["sourceHeight"]) == originalSize.height,
                  number(seed["threshold"]) == 0.9,
                  let w = integer(seed["mapFullWidth"], 32769), w > 0,
                  let h = integer(seed["mapFullHeight"], 32769), h > 0,
                  let ox = integer(seed["mapOriginX"], w), let oy = integer(seed["mapOriginY"], h),
                  let parent = integer(seed["parentBoxIndex"], 4096),
                  let owner = seed["ownerID"] as? String,
                  owner == "db:\(Int(w))x\(Int(h)):\(Int(ox)),\(Int(oy)):\(Int(parent))",
                  let a = seed["ambiguousComponents"] as? [Any], let c = seed["candidateComponents"] as? [Any],
                  let components = seed["components"] as? [[String: Any]], components.count <= 16 else { excluded += 1; continue }
            ambiguous += a.count; candidates += c.count
            for component in components {
                guard accepted.count < 64, let id = integer(component["seed"], w * h),
                      let count = integer(component["pixelCount"], 262145), count > 0,
                      let mean = number(component["meanProbability"]), (0.9...1).contains(mean),
                      let runs = component["runs"] as? [[String: Any]], !runs.isEmpty,
                      runs.count <= 4096, totalRuns + runs.count <= 8192 else { excluded += 1; continue }
                totalRuns += runs.count
                var left = w, right = 0.0, top = h, bottom = 0.0, pixels = 0.0, previousY = -1.0, previousEnd = -1.0
                var valid = true
                for (index, run) in runs.enumerated() {
                    guard let x = integer(run["x"], w), x >= ox, let y = integer(run["y"], h), y >= oy,
                          let length = integer(run["count"], w + 1), length > 0, x + length <= w,
                          y > previousY || (y == previousY && x >= previousEnd),
                          index != 0 || id == y * w + x else { valid = false; break }
                    pixels += length
                    if pixels > count { valid = false; break }
                    left = min(left, x); right = max(right, x + length); top = min(top, y); bottom = max(bottom, y + 1)
                    previousY = y; previousEnd = x + length
                }
                guard valid, pixels == count, right > left, bottom > top else { excluded += 1; continue }
                // Duplicate claims across parents are NOT independent anchors.
                let claim = "\(Int(w)):\(Int(h)):\(Int(ox)):\(Int(oy)):\(Int(id))"
                claims[claim, default: 0] += 1
                accepted.append(["bounds": [left / w, top / h, (right - left) / w, (bottom - top) / h],
                    "pixels": count, "meanProbability": mean, "parentBoxIndex": parent, "componentSeed": id,
                    "ownerID": owner, "detectorGridSize": [w, h], "detectorGridOrigin": [ox, oy], "claimIdentity": claim])
            }
        }
        accepted = accepted.filter { claims[$0["claimIdentity"] as! String] == 1 }.map {
            var c = $0; c.removeValue(forKey: "claimIdentity"); return c
        }
        guard !accepted.isEmpty else { return nil }
        return ["version": 1, "originalSourceSize": [originalSize.width, originalSize.height],
            "coordinateSpace": "normalized-top-left", "status": "observed-exclusive-subset", "complete": false,
            "omittedComponentCount": NSNull(), "excludedInvalidRecords": excluded,
            "ambiguousComponentCount": ambiguous, "candidateComponentCount": candidates,
            "components": accepted, "authority": "positive exclusive v2 CC observations only; packet coverage unknown"]
    }

    static func observedExclusiveSubcolumns(evidence: [String: Any], originalSize: CGSize,
                                            sourceRowIndices: Set<Int>? = nil,
                                            enabled: Bool = false) -> [ObservedExclusiveSubcolumn] {
        guard enabled, let identity = evidence["sourceSHA256"] as? String,
              let content = evidence["ocrSourceContentIdentity"] as? String, content.utf8.count == 64,
              content.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              identity == "canonical-rgb8:" + content,
              let ocr = evidence["originalOCR"] as? [String: Any], ocr["coordinateSpace"] as? String == "normalized-top-left",
              number(ocr["width"]) == originalSize.width, number(ocr["height"]) == originalSize.height,
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096 else { return [] }
        var result: [ObservedExclusiveSubcolumn] = []
        for (index, raw) in rows.enumerated() where sourceRowIndices?.contains(index) ?? true {
            guard result.count < 256, raw["sourceOrientation"] as? String == "vertical",
                  let box = rect(raw["sourceBounds"] ?? raw["rect"]),
                  let g = raw["sourceGeometryObservation"] as? [String: Any],
                  g["rectClipped"] as? Bool == false, g["polygonClipped"] as? Bool == false else { continue }
            var row = raw
            if let positive = raw["sourceObservedExclusiveSubcolumns"] { row["sourceOwnedDetectorComponents"] = positive }
            let summary = comparisonComponents(row, size: originalSize)
            let owners = Dictionary(grouping: summary.components) { $0["ownerID"] as! String }
            for owner in owners.keys.sorted() {
                let components = owners[owner]!
                let observed = components.compactMap { rect($0["bounds"]) }.map { pixels($0, originalSize) }
                    .reduce(CGRect.null) { $0.union($1) }
                // This is an observed subcolumn, not all source ink. Do not
                // extend its y interval to the full OCR packet envelope.
                guard !observed.isNull, observed.height >= observed.width * 1.5,
                      coverage(observed, pixels(box, originalSize)) >= 0.5 else { continue }
                result.append(ObservedExclusiveSubcolumn(sourceIdentity: identity, originalOCRRowIndex: index,
                    ownerID: owner, parentBoxIndex: Int(number(components[0]["parentBoxIndex"])!),
                    componentSeeds: components.map { Int(number($0["componentSeed"])!) },
                    originalPixelObservedEnvelope: observed, originalSourceEnvelope: pixels(box, originalSize),
                    packetComplete: summary.complete))
                if result.count >= 256 { break }
            }
        }
        return result
    }

    /// Candidate graph edge geometry ONLY on observed owned segments. Caller
    /// still checks RF/pixel corridors, boundaries, palette and exact provenance.
    static func observedAnchorEdges(_ anchors: [ObservedExclusiveSubcolumn]) -> [ObservedAnchorEdge] {
        guard anchors.count <= 256 else { return [] }
        var edges: [ObservedAnchorEdge] = []
        for i in anchors.indices { for j in anchors.indices where i < j {
            let a = anchors[i], b = anchors[j]
            guard a.sourceIdentity == b.sourceIdentity, a.originalOCRRowIndex != b.originalOCRRowIndex,
                  a.ownerID != b.ownerID else { continue }
            let x = a.originalPixelObservedEnvelope, y = b.originalPixelObservedEnvelope
            let width = min(x.width, y.width), overlap = min(x.maxY, y.maxY) - max(x.minY, y.minY)
            if abs(x.midX - y.midX) <= width * 0.5 {
                let gap = max(x.minY, y.minY) - min(x.maxY, y.maxY)
                if gap >= -width * 0.25 && gap <= width * 0.75 {
                    edges.append(ObservedAnchorEdge(first: a, second: b, kind: "observed-same-axis-fragments",
                        observedGapOriginalPixels: gap, observedOverlapOriginalPixels: overlap))
                } else if gap > 0, !a.packetComplete || !b.packetComplete {
                    // Positive anchors can be separated by unobserved ink in a
                    // partial packet. The interval is NOT blank and not an
                    // admitted continuation. Nominate a source reread only when
                    // the ORIGINAL packet envelopes connect this same axis.
                    let first = x.minY < y.minY ? a : b, second = x.minY < y.minY ? b : a
                    let connected = first.originalSourceEnvelope.intersects(second.originalSourceEnvelope)
                    let corridor = CGRect(x: min(x.minX, y.minX), y: min(x.maxY, y.maxY),
                        width: max(x.maxX, y.maxX) - min(x.minX, y.minX), height: gap)
                    let sourceUnion = first.originalSourceEnvelope.union(second.originalSourceEnvelope)
                    if connected && sourceUnion.contains(corridor) {
                        edges.append(ObservedAnchorEdge(first: first, second: second,
                            kind: "incomplete-same-axis-observed-anchors", observedGapOriginalPixels: gap,
                            observedOverlapOriginalPixels: overlap))
                    }
                }
            } else {
                let gap = max(x.minX, y.minX) - min(x.maxX, y.maxX)
                if gap >= -width * 0.45 && gap <= max(x.width, y.width) * 1.4 &&
                    overlap >= min(x.height, y.height) * 0.35 && overlap >= width * 0.5 {
                    edges.append(ObservedAnchorEdge(first: a, second: b, kind: "observed-adjacent-subcolumns",
                        observedGapOriginalPixels: gap, observedOverlapOriginalPixels: overlap))
                }
            }
            if edges.count >= 512 { return edges }
        } }
        return edges
    }

    /// Concrete original recognizer input for uncertain same-axis edges. This
    /// is a union of two owned anchors, not a union of entire OCR packets. Parent
    /// validates accepted-primary ancestry/actual read before source revision.
    static func recognitionForObservedAnchor(_ edge: ObservedAnchorEdge,
                                             originalSize: CGSize) -> AnchoredSourceRecognition? {
        guard edge.requiresSourceRecognition, edge.first.sourceIdentity == edge.second.sourceIdentity else { return nil }
        let a = edge.first.originalPixelObservedEnvelope, b = edge.second.originalPixelObservedEnvelope
        let width = max(a.width, b.width), margin = max(2, width * 0.35)
        let source = edge.first.originalSourceEnvelope.union(edge.second.originalSourceEnvelope)
        let strip = a.union(b).insetBy(dx: -margin, dy: -margin).intersection(source)
        guard !strip.isNull, strip.width > 0, strip.height > strip.width,
              strip.width * strip.height <= 262144,
              CGRect(x: 0, y: 0, width: originalSize.width, height: originalSize.height).contains(strip) else { return nil }
        return AnchoredSourceRecognition(sourceIdentity: edge.first.sourceIdentity,
            originalOCRRowIndices: [edge.first.originalOCRRowIndex, edge.second.originalOCRRowIndex],
            originalPixelQuad: [CGPoint(x: strip.minX, y: strip.minY), CGPoint(x: strip.maxX, y: strip.minY),
                CGPoint(x: strip.maxX, y: strip.maxY), CGPoint(x: strip.minX, y: strip.maxY)],
            observedAnchors: [edge.first, edge.second])
    }
}

// MARK: - Concrete original-image continuation adapter

extension NativeCausalParagraphAxisGrouping {
    struct OriginalTextSupport {
        let queryID: Int
        let normalizedBounds: CGRect
        let confidence: Double
    }

    struct ContinuationAdapterResult {
        let preparation: PairPreparation
        let originalPixelEvidence: [String: Any]
        /// Executable original-image recognizer inputs, not requests to invent
        /// a continuity token. Parent commits accepted source BEFORE translation.
        let sourceCorrectionRequests: [RecognitionQuad]
        /// Filled only after concrete source continuity AND caller's actual
        /// member-palette admission. Every untouched incumbent remains intact.
        let proposedDisplayItems: [[String: Any]]
        let originalRemovalItems: [[String: Any]]
        let groupApplied: Bool
    }

    /// Parent passes its already content-bound ORIGINAL CGImage and RF text
    /// rows. This performs bounded CPU pixel sampling; no OCR/model/render work.
    /// There is no externally fabricated ParagraphContinuity placeholder here.
    /// RF adapters: regions.filter { $0.classID == 0 }.map {
    ///   OriginalTextSupport(queryID:$0.queryID, normalizedBounds:$0.bounds, confidence:$0.confidence)
    /// }. Main evidence store supplies evidence.rfSourceSHA256 == sourceSHA256.
    static func originalAxisContinuation(_ items: [[String: Any]], indices: [Int],
                                         evidence: [String: Any], original: CGImage,
                                         rfText: [OriginalTextSupport], viewport: CGSize? = nil, enabled: Bool = false,
                                         admitOriginalMemberPalette: ([String: Any]) -> Bool = { _ in false })
        -> ContinuationAdapterResult {
        let size = CGSize(width: original.width, height: original.height)
        // Source quads/probes stay in original pixels. Raw member font metrics
        // already use the caller's viewport and MUST NOT be scaled again.
        let displaySize = viewport ?? size
        var preparation = preparePair(items, indices: indices, evidence: evidence, originalSize: size, enabled: enabled)
        var audit: [String: Any] = ["enabled": enabled, "authority": "original-source-axis-and-local-RGB-corridor",
                                  "maskChanged": false, "newOCRorModelInference": false]
        var requests = preparation.recognitionRequests
        func result(_ proposed: [[String: Any]]? = nil) -> ContinuationAdapterResult {
            ContinuationAdapterResult(preparation: preparation, originalPixelEvidence: audit,
                sourceCorrectionRequests: requests, proposedDisplayItems: proposed ?? items,
                originalRemovalItems: items, groupApplied: proposed != nil)
        }
        guard enabled, indices.count == 2, Set(indices).count == 2,
              indices.allSatisfy({ items.indices.contains($0) }), rfText.count <= 512 else { return result() }
        guard displaySize.width.isFinite, displaySize.height.isFinite,
              displaySize.width > 0, displaySize.height > 0 else {
            audit["status"] = "retained-invalid-display-viewport"; return result()
        }

        // The source-first route also handles a tiny horizontal read inside a
        // fused vertical source packet. It does NOT change that read's direction
        // or concatenate its translation. All original affiliations survive.
        if preparation.status == .sourceRecognitionRequired || preparation.status == .unsupportedSourceGeometry ||
            preparation.status == .invalidEvidence {
            if requests.isEmpty {
                requests = exactSourceCorrectionRequests(items, indices: indices, evidence: evidence, size: size)
            }
            audit["status"] = requests.isEmpty ? "retained-invalid-or-independent-source" : "source-correction-ready-for-recognizer"
            audit["recognizerRequests"] = requests.map(\.audit)
            return result()
        }
        guard preparation.status == .independentParagraphEvidenceRequired,
              let identity = preparation.sourceIdentity, evidence["rfSourceSHA256"] as? String == identity,
              preparation.members.count == 2, let axis = preparation.commonComparisonRadians else {
            audit["status"] = "retained-missing-bound-source-or-RF"; return result()
        }
        let members = preparation.members.sorted { $0.projectedEnvelope.midX > $1.projectedEnvelope.midX }
        let firstSource = (members[0].originalRow["source"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard let last = firstSource.last, !".!?。！？…」』”\"".contains(last) else {
            audit["status"] = "retained-explicit-original-source-boundary"; return result()
        }
        var queries: [Int] = []
        for member in members {
            guard let b = rect(member.originalItem["sourceBounds"]) else { return result() }
            let matches = rfText.filter {
                $0.confidence.isFinite && $0.confidence >= 0.55 && $0.confidence <= 1 &&
                    !$0.normalizedBounds.isNull && $0.normalizedBounds.width > 0 && $0.normalizedBounds.height > 0 &&
                    CGRect(x: 0, y: 0, width: 1, height: 1).contains($0.normalizedBounds) && coverage(b, $0.normalizedBounds) >= 0.75
            }.sorted { $0.normalizedBounds.width * $0.normalizedBounds.height < $1.normalizedBounds.width * $1.normalizedBounds.height }
            guard let best = matches.first, !matches.dropFirst().contains(where: {
                $0.queryID != best.queryID && $0.normalizedBounds.width * $0.normalizedBounds.height <=
                    best.normalizedBounds.width * best.normalizedBounds.height * 1.1
            }) else { audit["status"] = "retained-missing-or-ambiguous-text-support"; return result() }
            queries.append(best.queryID)
        }
        guard queries[0] == queries[1] else { audit["status"] = "retained-different-RF-text-owners"; return result() }
        let boxes = members.map(\.projectedEnvelope), minWidth = boxes.map(\.width).min()!
        guard minWidth > 0, boxes.map(\.width).max()! <= minWidth * 1.8,
              abs(boxes[0].minY - boxes[1].minY) <= minWidth * 1.1 else {
            audit["status"] = "retained-nonmatching-original-column-grid"; return result()
        }
        let projected = members.map { member in
            member.originalPixelQuad.map { CGPoint(x: cos(axis) * $0.x - sin(axis) * $0.y,
                                                   y: sin(axis) * $0.x + cos(axis) * $0.y) }
        }
        let top = max(boxes[0].minY, boxes[1].minY), bottom = min(boxes[0].maxY, boxes[1].maxY)
        guard bottom - top >= min(boxes[0].height, boxes[1].height) * 0.7 else {
            audit["status"] = "retained-insufficient-original-axis-overlap"; return result()
        }
        var samples: [CGPoint] = []
        func crossSection(_ quad: [CGPoint], y: Double) -> ClosedRange<Double>? {
            var x: [Double] = []
            for i in quad.indices {
                let a = quad[i], b = quad[(i + 1) % 4]
                if abs(b.y - a.y) > 1e-9 && y >= min(a.y, b.y) && y <= max(a.y, b.y) {
                    x.append(a.x + (b.x - a.x) * (y - a.y) / (b.y - a.y))
                }
            }
            guard let lo = x.min(), let hi = x.max(), hi > lo else { return nil }
            return lo...hi
        }
        // Follow actual quadrilateral edges, not overlapping axis-aligned boxes.
        // A tiny band at their midpoint is a conservative continuity observation,
        // not a statement that all ink between source columns was recognized.
        for row in 0..<32 {
            let y = top + (bottom - top) * (0.1 + 0.8 * (Double(row) + 0.5) / 32)
            guard let right = crossSection(projected[0], y: y), let left = crossSection(projected[1], y: y) else { continue }
            let middle = (right.lowerBound + left.upperBound) / 2
            for column in 0..<5 {
                let x = middle + (Double(column) - 2) * max(0.5, minWidth * 0.02)
                samples.append(CGPoint(x: cos(axis) * x + sin(axis) * y, y: -sin(axis) * x + cos(axis) * y))
            }
        }
        guard samples.count == 160 else { audit["status"] = "retained-incomplete-original-corridor"; return result() }
        let corridorBounds = envelope(samples).insetBy(dx: -1, dy: -1)
        let intervening = items.indices.contains { index in
            guard !indices.contains(index), let b = rect(items[index]["sourceBounds"]) else { return false }
            return coverage(corridorBounds, pixels(b, size)) > 0.05
        }
        guard !intervening else { audit["status"] = "retained-intervening-original-owner"; return result() }
        let pixelAudit = sampleOriginalCorridor(original, samples: samples)
        audit["pixelProbe"] = pixelAudit; audit["rfTextQuery"] = queries[0]
        guard pixelAudit["accepted"] as? Bool == true else {
            audit["status"] = "retained-original-corridor-uncertain"; return result()
        }
        let observation = ParagraphContinuity(sourceIdentity: identity,
            originalOCRRowIndices: Set(members.map(\.originalOCRRowIndex)), basis: .originalPixelContinuity,
            observationID: "original-axis-RGB-corridor:\(members[0].originalOCRRowIndex):\(members[1].originalOCRRowIndex):160")
        preparation = preparePair(items, indices: indices, evidence: evidence, originalSize: size,
            continuity: observation, enabled: true)
        guard preparation.status == .readyForFreshShaping, let plan = preparation.shapingPlan else {
            audit["status"] = preparation.status.rawValue; return result()
        }
        let seed = unsealedDisplaySeed(plan, preparation: preparation, size: size, viewport: displaySize)
        audit["displayViewport"] = [displaySize.width, displaySize.height]
        guard admitOriginalMemberPalette(seed) else {
            audit["status"] = "retained-original-member-palette-not-admitted"; return result()
        }
        let slot = indices.min()!
        let output = items.indices.compactMap { i in i == slot ? seed : indices.contains(i) ? nil : items[i] }
        audit["status"] = "source-axis-continuation-proposed-for-fresh-shaping"
        audit["targetScriptRecomputed"] = true; audit["actualRasterOrQualityCertified"] = false
        return result(output)
    }

    private static func sampleOriginalCorridor(_ original: CGImage, samples: [CGPoint]) -> [String: Any] {
        let bounds = envelope(samples).insetBy(dx: -1, dy: -1).integral
        guard CGRect(x: 0, y: 0, width: original.width, height: original.height).contains(bounds),
              bounds.width * bounds.height <= 131072, let crop = original.cropping(to: bounds) else {
            return ["accepted": false, "reason": "original-ROI-budget-or-boundary"]
        }
        let w = crop.width, h = crop.height
        var bytes = [UInt8](repeating: 0, count: w * h * 4)
        let valid = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8,
                bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            context.setBlendMode(.copy); context.draw(crop, in: CGRect(x: 0, y: 0, width: w, height: h)); return true
        }
        guard valid else { return ["accepted": false, "reason": "original-RGB-unavailable"] }
        var colors: [[Int]] = []
        for p in samples {
            let x = Int(floor(p.x - bounds.minX)), y = Int(floor(p.y - bounds.minY))
            guard x >= 0, x < w, y >= 0, y < h else { return ["accepted": false, "reason": "sample-outside-original-ROI"] }
            let i = (y * w + x) * 4
            guard bytes[i + 3] == 255 else { return ["accepted": false, "reason": "transparent-source-corridor-unknown"] }
            colors.append([Int(bytes[i]), Int(bytes[i + 1]), Int(bytes[i + 2])])
        }
        let median = (0..<3).map { c in colors.map { $0[c] }.sorted()[colors.count / 2] }
        let deviations = colors.map { rgb in (0..<3).map { abs(rgb[$0] - median[$0]) }.max()! }
        let outliers = deviations.filter { $0 > 30 }.count
        var longest = 0, current = 0
        for row in 0..<32 {
            if deviations[(row * 5)..<(row * 5 + 5)].filter({ $0 > 30 }).count >= 3 { current += 1 }
            else { current = 0 }
            longest = max(longest, current)
        }
        // Surface constancy is measured from the original corridor itself; no
        // white-paper/color/font assumptions or peer palette truth are used.
        return ["accepted": outliers <= 16 && longest <= 2, "samples": samples.count,
                "outlierSamples": outliers, "maximumOutlierSamples": 16,
                "longestMajorityOutlierRows": longest, "maximumMajorityOutlierRows": 2,
                "channelDeviationThreshold": 30, "originalMedianRGB": median,
                "originalPixelROI": [bounds.minX, bounds.minY, bounds.width, bounds.height],
                "maximumROIPixels": 131072, "glyphCompletenessCertified": false]
    }

    private static func unsealedDisplaySeed(_ plan: ParagraphShapingPlan, preparation: PairPreparation,
                                           size: CGSize, viewport: CGSize) -> [String: Any] {
        let members = plan.membersInSourceOrder.compactMap { target in preparation.members.first { $0.itemIndex == target.itemIndex } }
        let originals = members.map(\.originalItem), bounds = plan.originalPixelLayoutSearchEnvelope
        let fonts = originals.compactMap { number($0["fontSize"]) }.filter { $0 > 0 }
        let font = fonts.min() ?? 1
        let sourceFonts = originals.compactMap { number($0["sourceFontSize"]) }.filter { $0 > 0 }
        let sx = viewport.width / size.width, sy = viewport.height / size.height
        // Fresh display owner, not a mutated original. Source geometry remains
        // in member arrays and the distinct originalRemovalItems channel.
        return ["id": "source-axis:" + originals.compactMap { $0["id"] as? String }.joined(separator: "+"),
                "text": plan.exactCombinedText, "sourceBounds": [Double(bounds.minX / size.width), Double(bounds.minY / size.height),
                    Double(bounds.width / size.width), Double(bounds.height / size.height)],
                "sourceFrame": [0.0, 0.0, Double(viewport.width), Double(viewport.height)],
                "x": Double(bounds.minX * sx), "y": Double(bounds.minY * sy),
                "width": Double(bounds.width * sx), "height": Double(bounds.height * sy),
                "rotation": 0, "vertical": false, "sourceVertical": true,
                "fontSize": font, "lineHeight": max(font, originals.compactMap { number($0["lineHeight"]) }.min() ?? font * 1.3),
                "sourceFontSize": sourceFonts.min() ?? font,
                "sourceAxisSourceFontSizeAuthority": sourceFonts.isEmpty
                    ? "display-seed-fallback; source-font-unmeasured"
                    : "minimum-retained-member-estimate; viewport-layout-seed-not-new-source-measurement",
                "fontScript": plan.scriptDecision.fontScript ?? "word", "wrappingScript": plan.scriptDecision.wrappingScript ?? "word",
                "agent02MemberItems": originals, "agent02MemberIDs": originals.compactMap { $0["id"] as? String },
                "agent02MemberIndices": members.map(\.itemIndex), "sourceTextBlockMemberPalette": true,
                "sourceAxisMaskSourceItems": originals, "sourceAxisMaskGeometryUnchanged": true,
                "sourceAxisSourceRows": members.map(\.originalRow), "sourceAxisRequiresFreshShaping": true,
                "sourceAxisTargetUTF16": plan.membersInSourceOrder.map { Array($0.exactText.utf16) },
                "sourceAxisOriginalScriptDeclarations": plan.membersInSourceOrder.map {
                    ["fontScript": $0.originalFontScript ?? "unknown", "wrappingScript": $0.originalWrappingScript ?? "unknown"] },
                "sourceAxisParagraphSourceFontUnknown": true,
                "sourceAxisComparisonRadians": preparation.commonComparisonRadians ?? 0,
                "sourceAxisMandatoryBWStrokeReplan": true, "ensembleDisplayStroke": [0, 0, 0], "ensembleStrokeRatio": 0.2]
    }

    private static func exactSourceCorrectionRequests(_ items: [[String: Any]], indices: [Int],
                                                       evidence: [String: Any], size: CGSize) -> [RecognitionQuad] {
        guard let identity = evidence["sourceSHA256"] as? String,
              let content = evidence["ocrSourceContentIdentity"] as? String, content.utf8.count == 64,
              content.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              identity == "canonical-rgb8:" + content,
              let ocr = evidence["originalOCR"] as? [String: Any], ocr["coordinateSpace"] as? String == "normalized-top-left",
              ["observed-final-regions", "explicitly-normalized-native-lines"].contains(ocr["authority"] as? String ?? ""),
              number(ocr["width"]) == size.width, number(ocr["height"]) == size.height,
              let rows = ocr["regions"] as? [[String: Any]], rows.count <= 4096 else { return [] }
        var matched: [(Int, [String: Any], CGRect, [CGPoint])] = []
        for i in indices {
            let item = items[i]
            guard item["keptLettering"] as? Bool != true, item["sourceTextOnly"] as? Bool != true,
                  (item["agent02MemberItems"] as? [Any] ?? []).isEmpty,
                  !["sfx", "title"].contains(item["sourceLettering"] as? String ?? ""),
                  let b = rect(item["sourceBounds"]), let q = points(item["sourcePolygon"]) else { return [] }
            let matches = rows.indices.filter { rect(rows[$0]["sourceBounds"] ?? rows[$0]["rect"]).map { close($0, b) } == true }
            guard matches.count == 1, let j = matches.first,
                  let saved = rows[j]["translation"] as? String, let target = item["text"] as? String, exact(saved, target),
                  let source = rows[j]["source"] as? String, !source.isEmpty,
                  !source.contains("\n\n"), !source.contains("\u{2029}"),
                  !["sfx", "title"].contains(rows[j]["sourceLettering"] as? String ?? ""),
                  let rq = points(rows[j]["polygon"]), close(envelope(rq), b), zip(q, rq).allSatisfy({ distance($0, $1) < 1e-8 }),
                  let observation = rows[j]["sourceGeometryObservation"] as? [String: Any],
                  observation["rectClipped"] as? Bool == false, observation["polygonClipped"] as? Bool == false,
                  (rows[j]["clippedUnitMemberIndices"] as? [Int] ?? []).isEmpty else { return [] }
            matched.append((j, rows[j], b, rq.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }))
        }
        guard matched.contains(where: { $0.1["sourceOrientation"] as? String == "vertical" }),
              max(coverage(matched[0].2, matched[1].2), coverage(matched[1].2, matched[0].2)) >= 0.3 else { return [] }
        // Independent explicit paragraphs must not become source reread groups.
        for key in ["paragraphID", "paragraphIndex", "rfBodyIndex"] {
            let values = indices.compactMap { items[$0][key] } + matched.compactMap { $0.1[key] }
            if let first = values.first, values.dropFirst().contains(where: {
                !NSDictionary(dictionary: ["v": first]).isEqual(to: ["v": $0])
            }) { return [] }
        }
        return matched.map { j, row, b, q in
            RecognitionQuad(sourceIdentity: identity, originalOCRRowIndex: j,
                originalSourceBounds: [b.minX, b.minY, b.width, b.height], originalPixelQuad: q, recognitionPixelQuad: q,
                sourceComponents: comparisonComponents(row, size: size).components,
                overlappingOriginalRows: matched.filter { $0.0 != j }.map { $0.0 },
                acceptedSourceAffiliation: row["acceptedSourceAffiliation"],
                reason: "overlapping-original-source-correction-before-translation; full-quad-not-certified-narrow-column")
        }
    }
}
